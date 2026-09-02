--!strict
--[[
	PlotService
	Owns every Sanctum on the server: it builds the six plots at boot, hands one to each arriving
	player, links a consenting second occupant in, holds a vacated plot through its grace window, and
	drives ALL of them from a SINGLE Heartbeat connection. It is the one authority on occupancy and
	the one place a live PlotState is mirrored back into a Profile.
	Three plain modules do the work under it, split out only to keep every file inside the 300-line
	budget: PlotRuntime is one Sanctum's machinery, PlotSession is a player's relationship to a plot
	(claim, link, release, grace), and PlotLinkController is the link offer book.
	Owner: server/Services  |  Consumers: EconomyService, PurchaseService, EvolutionService,
	                                      RebirthService, StateReplicator, LeaderboardService
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local GameConfig = require(Modules:WaitForChild("GameConfig"))
local Signal = require(Modules:WaitForChild("Signal"))

local Peers = script.Parent
local PlotLinkController = require(Peers:WaitForChild("PlotLinkController"))
local PlotRuntime = require(Peers:WaitForChild("PlotRuntime"))
local PlotSession = require(Peers:WaitForChild("PlotSession"))

type Occupant = { UserId: number, Player: any, Slot: number, JoinedAt: number, Contribution: number, Vote: boolean? }
type Sanctum = { Id: number, Model: Instance, State: any, Occupants: { [number]: Occupant },
	AnchorUserId: number?, Runtime: any, Dirty: boolean }
type Plot = any -- PlotRuntime's object; typed there, and naming it here would be a require cycle
type Connection = { Disconnect: (self: any) -> () }

-- Heartbeat is DECIMATED to GameConfig.Income.TickRate: DropperSystem's catch-up bound is sized off
-- a 0.1s step, and stepping six Sanctums at render rate buys nothing a Mote's flight can show.
local STEP_INTERVAL = 1 / math.max(1, GameConfig.Income.TickRate)
local MAX_STEP = 0.5 -- after a hitch the banked dt would teleport every Mote to the Font in one frame
local MIRROR_SECONDS = 1 -- how often a dirty Sanctum is copied into its occupants' Profiles
local WARN_SECONDS = 10 -- throttle on the per-Sanctum step-failure warning
local FOLDER_NAME = "Sanctums"

local Service = {}
Service.Name = "PlotService"
-- Built at module scope, never in Init: rebuilding them would silently drop every connection a peer
-- made at boot, and those peers are already running by the time a re-Init could happen.
Service.SanctumChanged = Signal.new()
Service.OccupantAdded = Signal.new()
Service.OccupantRemoved = Signal.new()
Service.Reason = PlotSession.Reason -- the closed set of link/claim gate codes (DECISIONS #11)

local plots: { Plot } = {}
local byId: { [number]: Plot } = {}
local connections: { Connection } = {}
local heartbeat: Connection? = nil
local links: any, profiles: any, economy: any, remotes: any = nil, nil, nil, nil
local purchases: any, registryRef: any = nil, nil
local accumulator, mirrorClock = 0, 0

--[[ Resolves a caller's Sanctum back to the plot that owns it. The IDENTITY check matters: a spec
     fixture (or a stale reference to a rebuilt plot) can share an Id with a live Sanctum, and
     driving the real one from it would move a live player's occupancy. ]]
local function plotOf(sanctum: any): Plot?
	if type(sanctum) ~= "table" then return nil end
	local id = (sanctum :: any).Id
	local plot = if type(id) == "number" then byId[id] else nil
	return if plot ~= nil and plot.Sanctum == sanctum then plot else nil
end

function Service:GetSanctum(id: any): Sanctum?
	local plot = if type(id) == "number" then byId[id] else nil
	return if plot ~= nil then plot.Sanctum else nil
end

function Service:GetSanctumForPlayer(player: any): Sanctum?
	local plot = PlotSession.plotFor(player)
	return if plot ~= nil then plot.Sanctum else nil
end

-- Read structurally rather than through plotOf, so a spec fixture's Sanctum works here too.
function Service:GetOccupants(sanctum: any): { Player }
	local list: { Player } = {}
	local occupants = if type(sanctum) == "table" then (sanctum :: any).Occupants else nil
	if type(occupants) ~= "table" then return list end
	local ordered: { Occupant } = {}
	for _, occupant in pairs(occupants :: { [any]: Occupant }) do table.insert(ordered, occupant) end
	-- Sorted by slot: `pairs` order is unspecified, and an unstable partner panel would flicker.
	table.sort(ordered, function(a: Occupant, b: Occupant): boolean return a.Slot < b.Slot end)
	for _, occupant in ipairs(ordered) do table.insert(list, occupant.Player) end
	return list
end

function Service:ForEachSanctum(fn: (Sanctum) -> ()): ()
	if type(fn) ~= "function" then return end
	for _, plot in ipairs(plots) do fn(plot.Sanctum) end
end

function Service:MarkDirty(sanctum: any): ()
	if type(sanctum) ~= "table" then return end
	local target = sanctum :: any
	target.Dirty = true
	local plot = plotOf(sanctum)
	if plot == nil then
		Service.SanctumChanged:Fire(sanctum) -- not one of ours; there is nothing to coalesce against
		return
	end
	--[[ COALESCED to one announcement per income tick. EconomyService calls this on EVERY credit --
	     dozens a second per Sanctum -- and Signal.Fire spawns a thread per handler, so an
	     uncoalesced version would spend more time waking listeners than earning. The flag is
	     re-armed at the top of each tick, so no change ever waits longer than one tick to be seen. ]]
	if plot.Announced then return end
	plot.Announced = true
	Service.SanctumChanged:Fire(plot.Sanctum)
end

--[[ Re-derives everything downstream of PlotState -- emit streams, Wing visibility, the multiplier
     cache and the pads' wording. Call it after a load, a link merge, a purchase, an attunement or a
     reset: anything that changes what the Sanctum owns. ]]
function Service:RebuildSanctum(sanctum: any): ()
	local plot = plotOf(sanctum)
	if plot == nil then return end
	PlotSession.ensureSeed(plot) -- the cold-start invariant, restored before anything reads the state
	plot:Rebuild()
	-- PurchaseService is registered AFTER this service, so it is resolved lazily; TryGet, never Get,
	-- because Get errors by design and this runs on paths that must not throw.
	if purchases == nil and registryRef ~= nil then purchases = registryRef:TryGet("PurchaseService") end
	if purchases ~= nil and type(purchases.RefreshPads) == "function" then
		purchases:RefreshPads(plot.Sanctum)
	end
	Service:MarkDirty(plot.Sanctum)
end

function Service:ClaimEmpty(player: any): Sanctum?
	local plot = PlotSession.claim(player)
	return if plot ~= nil then plot.Sanctum else nil
end

function Service:RequestLink(player: any, sanctum: any): (boolean, string)
	local plot = plotOf(sanctum)
	if plot == nil then return false, Service.Reason.UnknownSanctum end
	return PlotSession.requestLink(player, plot)
end

function Service:ResolveLink(player: any, sanctum: any, accept: boolean): (boolean, string)
	local plot = plotOf(sanctum)
	if plot == nil then return false, Service.Reason.UnknownSanctum end
	return PlotSession.resolveLink(player, plot, accept)
end

function Service:ReleaseOccupant(player: any): ()
	PlotSession.release(player)
end

--[[ Mirrors first, then hands every write to ProfileService: the shutdown budget and the session
     locking live there, and a second save loop here would double every player's write rate. ]]
function Service:SaveAll(release: boolean?): ()
	PlotSession.mirrorAll()
	if profiles ~= nil then profiles:SaveAll(release) end
end

-- PurchaseService needs the pads and signs, EvolutionService the Conflux. nil for a foreign Sanctum.
function Service:GetSanctumRuntime(sanctum: any): any
	local plot = plotOf(sanctum)
	return if plot ~= nil then plot.Sanctum.Runtime else nil
end

-- StateReplicator publishes MoteCount in the §7 snapshot; RebirthService clears the flight pool on a
-- reset, where crediting Motes still in the air would pay the pair for pressing the button.
function Service:GetMoteCount(sanctum: any): number
	local plot = plotOf(sanctum)
	return if plot ~= nil then plot:MoteCount() else 0
end

function Service:ClearMotes(sanctum: any): ()
	local plot = plotOf(sanctum)
	if plot ~= nil then plot:ClearMotes() end
end

--[[ The one loop -- one connection for the WHOLE service, never one per Sanctum. ]]

local function stepPlot(plot: Plot, dt: number, mirroring: boolean): ()
	plot:Step(dt)
	-- Cheap and non-yielding, so it rides the income tick: any save (autosave, release, shutdown)
	-- then finds a Profile at most MIRROR_SECONDS behind the live Sanctum, whoever triggered it.
	if mirroring and plot.Sanctum.Dirty then PlotSession.mirrorOne(plot) end
end

local function tick(dt: any): ()
	accumulator += if type(dt) == "number" and dt == dt then dt else 0
	if accumulator < STEP_INTERVAL then return end
	local step = math.min(accumulator, MAX_STEP)
	accumulator = 0
	mirrorClock += step
	local mirroring = mirrorClock >= MIRROR_SECONDS
	if mirroring then mirrorClock = 0 end
	for _, plot in ipairs(plots) do
		plot.Announced = false -- re-arm the coalesced SanctumChanged for this tick
		if next(plot.Sanctum.Occupants) ~= nil then
			--[[ Per-Sanctum pcall, not one around the whole loop: an error in plot 3 must not stop
			     plots 4-6 earning, and an unguarded error would kill this connection for every
			     player on the server for the rest of its life. ]]
			local ok, err = pcall(stepPlot, plot, step, mirroring)
			if not ok and os.clock() - plot.LastWarn >= WARN_SECONDS then
				plot.LastWarn = os.clock()
				warn(("[PlotService] sanctum %d step failed: %s"):format(plot.Sanctum.Id, tostring(err)))
			end
		end
	end
end

local function teardown(): ()
	for _, connection in ipairs(connections) do connection:Disconnect() end
	table.clear(connections)
	if heartbeat ~= nil then
		heartbeat:Disconnect()
		heartbeat = nil
	end
	PlotSession.reset()
	for _, plot in ipairs(plots) do plot:Destroy() end
	table.clear(plots)
	table.clear(byId)
end

--[[ ServiceRegistry contract ]]

function Service:Init(registry: any): ()
	registryRef = registry
	-- Resolved only: section 6 forbids cross-service calls during Init.
	profiles = registry:Get("ProfileService")
	economy = registry:Get("EconomyService")
	remotes = registry:Get("RemoteService")
	purchases = nil -- registered AFTER this service; resolved lazily in RebuildSanctum
	links = PlotLinkController.new({
		Remotes = remotes,
		OnAccepted = function(sanctum: any, joiner: any)
			local plot = plotOf(sanctum)
			if plot ~= nil then PlotSession.linkAccepted(plot, joiner) end
		end,
	})
	teardown() -- a re-Init must not leave the previous boot's models, runtimes or connections behind
	PlotSession.bind(Service, plots, profiles, links)
	accumulator, mirrorClock = 0, 0
	-- Rebuilt from scratch: a leftover folder would leave six abandoned Sanctums in the world, and
	-- their pads would still answer a ProximityPrompt.
	local previous = workspace:FindFirstChild(FOLDER_NAME)
	if previous ~= nil then previous:Destroy() end
	local created = Instance.new("Folder")
	created.Name = FOLDER_NAME
	created.Parent = workspace
	for id = 1, GameConfig.Plot.SanctumCount do
		local plot = PlotRuntime.new(id, created, economy)
		table.insert(plots, plot)
		byId[id] = plot
	end
end

function Service:Start(): ()
	purchases = if registryRef ~= nil then registryRef:TryGet("PurchaseService") else nil
	for _, plot in ipairs(plots) do
		if purchases ~= nil and type(purchases.BuildPads) == "function" then
			purchases:BuildPads(plot.Sanctum)
		end
		for _, connection in ipairs(links:AttachPads(plot.Sanctum, function(player: Player)
			Service:RequestLink(player, plot.Sanctum)
		end)) do
			table.insert(connections, connection)
		end
	end
	--[[ Claiming hangs off ProfileLoaded, not PlayerAdded: the claim reads the saved PlotState, and
	     claiming before it arrived would seed a blank Sanctum and merge the real save over it. ]]
	table.insert(connections, profiles.ProfileLoaded:Connect(function(player: Player)
		if Service:ClaimEmpty(player) == nil and remotes ~= nil then
			remotes:FireClient(player, "Notify", { Kind = "error", Text = "Every sanctum is occupied right now." })
		end
	end))
	table.insert(connections, profiles.ProfileReleasing:Connect(PlotSession.flush))
	table.insert(connections, Players.PlayerRemoving:Connect(function(player: Player)
		Service:ReleaseOccupant(player)
	end))
	if remotes ~= nil then
		remotes:On("LinkResponse", function(player: Player, payload: any)
			-- Never trust the client: the payload names a plot, never an outcome. Occupancy and the
			-- pending offer are both re-checked from live state inside ResolveLink.
			local id = if type(payload) == "table" then (payload :: any).PlotId else nil
			local plot = if type(id) == "number" then byId[id] else nil
			if plot ~= nil then Service:ResolveLink(player, plot.Sanctum, (payload :: any).Accept == true) end
		end)
	end
	heartbeat = RunService.Heartbeat:Connect(tick)
	-- A Profile that loaded before Start (a boot-order edge, or a spec) still needs its Sanctum.
	for _, player in ipairs(Players:GetPlayers()) do
		if profiles:IsLoaded(player) then Service:ClaimEmpty(player) end
	end
end

function Service:Stop(): ()
	teardown()
	if links ~= nil then links:Clear() end
end

return Service
