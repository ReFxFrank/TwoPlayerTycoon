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
local PlotTick = require(Peers:WaitForChild("PlotTick"))

type Occupant = { UserId: number, Player: any, Slot: number, JoinedAt: number, Contribution: number, Vote: boolean? }
type Sanctum = { Id: number, Model: Instance, State: any, Occupants: { [number]: Occupant },
	AnchorUserId: number?, Runtime: any, Dirty: boolean }
type Plot = any -- PlotRuntime's object; typed there, and naming it here would be a require cycle
type Connection = { Disconnect: (self: any) -> () }

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
local purchases: any, evolution: any, registryRef: any = nil, nil, nil
-- The one loop. Built at module scope alongside `plots`, which it holds by reference.
local ticker = PlotTick.new(plots, PlotSession)

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
	--[[ Stage-derived presentation, re-asserted here rather than at each caller: attune, affinity and
	     rebirth applied it themselves but the CLAIM path never did, so a returning Stage 4 player got
	     a Stage 1 Conflux and Stage 1 walk speed all session. Doing it here is also ordering-proof --
	     claim fires OccupantAdded before the save is adopted, and this runs after both. ]]
	if evolution == nil and registryRef ~= nil then evolution = registryRef:TryGet("EvolutionService") end
	if evolution ~= nil then
		evolution:ApplyStageVisuals(plot.Sanctum)
		evolution:ApplyStageStats(plot.Sanctum)
	end
	Service:MarkDirty(plot.Sanctum)
end

--[[ Blanks a Sanctum in place, for the developer data reset. Re-announcing ProfileLoaded cannot do
     it: claim is idempotent, so a settled player gets their plot back without re-adopting, and the
     next mirror would write the old plot back over the blanked Profile. ]]
function Service:ResetSanctum(sanctum: any): ()
	local plot = plotOf(sanctum)
	if plot == nil then return end
	plot:Reset()
	Service:RebuildSanctum(plot.Sanctum)
end

--[[ A player turned away because every Sanctum was occupied has no second route: ClaimEmpty is
     reached only from the one-shot ProfileLoaded handler and the boot sweep, there is no client
     claim remote, and an empty Sanctum cannot be linked into. Without this they sit in the lobby
     all session while a plot stands free. Called ONLY where a plot has genuinely been recycled: a
     sweep on PlayerRemoving would hand the just-vacated plot to a stranger inside the grace window
     DECISIONS #6 exists to protect. ]]
function Service:SweepUnclaimed(): ()
	for _, player in ipairs(Players:GetPlayers()) do
		if profiles ~= nil and profiles:IsLoaded(player) and Service:GetSanctumForPlayer(player) == nil then
			if Service:ClaimEmpty(player) ~= nil and remotes ~= nil then
				remotes:FireClient(player, "Notify", { Kind = "success", Text = "A sanctum opened up. Welcome in." })
			end
		end
	end
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
	purchases, evolution = nil, nil -- registered AFTER this service; resolved lazily in RebuildSanctum
	links = PlotLinkController.new({
		Remotes = remotes,
		-- Returns the resulting roster so PlotLinkController can announce a link that actually
		-- landed; linkAccepted re-checks every gate and can decline silently.
		OnAccepted = function(sanctum: any, joiner: any): { any }?
			local plot = plotOf(sanctum)
			if plot == nil then return nil end
			PlotSession.linkAccepted(plot, joiner)
			return Service:GetOccupants(sanctum)
		end,
	})
	teardown() -- a re-Init must not leave the previous boot's models, runtimes or connections behind
	PlotSession.bind(Service, plots, profiles, links)
	ticker:Reset()
	PlotRuntime.buildAll(FOLDER_NAME, GameConfig.Plot.SanctumCount, plots, byId, economy)
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
	heartbeat = RunService.Heartbeat:Connect(function(dt: number)
		ticker:Step(dt)
	end)
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
