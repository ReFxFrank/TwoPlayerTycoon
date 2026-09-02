--!strict
--[[
	StateReplicator
	The only sender of StateSync. It runs ONE Heartbeat accumulator for the whole server and, at most
	every GameConfig.Network.SnapshotIntervalSeconds, gives each occupied Sanctum exactly one of two
	pushes: a FULL snapshot (spec section 7) when the Sanctum is marked Dirty, or an essence-only
	fast tick when only the shared wallet moved. Essence is the one field that changes many times a
	second; Stage, Occupants, Gates and the rest change on a purchase or an attunement, so sending
	them at essence cadence would be the same payload twenty times over for nothing.
	Snapshot.forClient is pure and cannot fetch a Profile, so the per-player Prestige/Settings/Stats
	it renders are gathered here from ProfileService and handed in.
	Owner: server/Services  |  Consumers: Bootstrap (registration), every client through StateSync
]]

local RunService = game:GetService("RunService")

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local GameConfig = require(Modules:WaitForChild("GameConfig"))
local Snapshot = require(Modules:WaitForChild("Snapshot"))
local StateSchema = require(Modules:WaitForChild("StateSchema"))

-- Spec section 3.1: a connection is anything with :Disconnect(). Structural, so this behaves the
-- same under Roblox's RBXScriptConnection and under the headless mock.
type Connection = { Disconnect: (self: any) -> () }
type ProfileMap = { [number]: any }
type NameMap = { [number]: string }

--[[ Floor on the push period. GameConfig.Debug is deliberately mutable and the rest of the config is
     hand-edited, so a 0 (or a NaN, which loses every comparison) would put a full snapshot per
     player on EVERY frame -- the exact bandwidth blowout this service exists to prevent. ]]
local MIN_INTERVAL = 1 / 30
local CONFIGURED = GameConfig.Network.SnapshotIntervalSeconds
local INTERVAL = if type(CONFIGURED) == "number" and CONFIGURED == CONFIGURED
	then math.max(CONFIGURED, MIN_INTERVAL)
	else 0.5
local WARN_SECONDS = 10 -- throttle on the per-Sanctum push-failure warning

local Service = {}
Service.Name = "StateReplicator"

local plots: any, profiles: any, remotes: any, economy: any = nil, nil, nil, nil
local heartbeat: Connection? = nil
local accumulator, tickCount, lastWarn = 0, 0, 0

--[[ Sanctum -> the Essence value its occupants were last told about. WEAK KEYS: PlotService rebuilds
     its Sanctums on a re-Init, and a strong key here would pin every discarded one (with its model,
     runtime and occupant table) alive for the life of the server. ]]
local function newEssenceCache(): { [any]: number }
	return (setmetatable({}, { __mode = "k" }) :: any) :: { [any]: number }
end
local lastEssence: { [any]: number } = newEssenceCache()

-- pcall'd: a Player is userdata, and reading a field off one who has already left can throw. A
-- failed read means "cannot identify this player", never an error inside the replication loop.
local function userIdOf(player: any): number?
	if player == nil then return nil end
	local ok, id = pcall(function(): any return (player :: any).UserId end)
	return if ok and type(id) == "number" and id == id then id else nil
end

local function nameOf(player: any): string?
	local ok, name = pcall(function(): any return (player :: any).Name end)
	return if ok and type(name) == "string" then name else nil
end

local function essenceOf(sanctum: any): number
	local state = (sanctum :: { [string]: any }).State
	local essence = if type(state) == "table" then (state :: { [string]: any }).Essence else nil
	-- NaN is deliberately NOT normalised away: `NaN ~= NaN` makes the change test fire every tick,
	-- which is the correct behaviour for a wallet that has been corrupted -- the client sees it.
	return if type(essence) == "number" then essence else 0
end

--[[ Prestige, Settings and Stats live in per-player Profiles. Snapshot.forClient is pure and takes
     them as `opts.Profiles` / `opts.Names` keyed by UserId, so they are collected here. A player
     with no loaded profile is simply absent from the map: Snapshot then renders a zeroed You block
     for them rather than borrowing somebody else's prestige. ]]
local function gather(players: { Player }): (ProfileMap, NameMap)
	local profileById: ProfileMap, nameById: NameMap = {}, {}
	for _, player in ipairs(players) do
		local userId = userIdOf(player)
		if userId ~= nil then
			profileById[userId] = if profiles ~= nil then profiles:Get(player) else nil
			local name = nameOf(player)
			if name ~= nil then nameById[userId] = name end
		end
	end
	return profileById, nameById
end

--[[ ONE payload per player, not one per Sanctum: a full snapshot carries `IsYou` on each occupant
     and a private `You` block (that player's badges, settings and lifetime earnings), so two
     occupants of the same Sanctum must never be sent the same table. ]]
local function pushFull(sanctum: any, players: { Player }): ()
	local profileById, nameById = gather(players)
	local opts = {
		Full = true,
		Tick = tickCount,
		MoteCount = plots:GetMoteCount(sanctum),
		Profiles = profileById,
		Names = nameById,
		-- EconomyService's cached (and frozen) Multipliers. Passing them keeps Snapshot from walking
		-- the whole upgrade catalogue once per occupant per push.
		Multipliers = economy:GetMultipliers(sanctum),
	}
	for _, player in ipairs(players) do
		remotes:FireClient(player, "StateSync", Snapshot.forClient(sanctum, player, opts))
	end
end

-- The fast tick is identical for every occupant -- the wallet is shared and the payload carries
-- nothing player-specific -- so it is built once and broadcast.
local function pushFast(sanctum: any, players: { Player }): ()
	local payload = Snapshot.forClient(sanctum, nil, { Full = false, Tick = tickCount })
	remotes:FireClients(players, "StateSync", payload)
end

--[[ Public API ]]

--[[ An immediate FULL snapshot for one player, whatever the accumulator is doing. This answers
     RequestSnapshot, so it must be total: a client that just respawned is exactly the case where
     the server's own state may be unusual. ]]
function Service:PushTo(player: any): ()
	if remotes == nil then return end
	tickCount += 1
	local sanctum = if plots ~= nil then plots:GetSanctumForPlayer(player) else nil
	if sanctum ~= nil then
		pushFull(sanctum, { player :: Player })
		return
	end
	--[[ No Sanctum yet -- the profile is still loading, every plot is full, or their plot's grace
	     window expired. They still get a VALID snapshot rather than nothing: the client's controllers
	     all read the store, and leaving them on ClientStore's zeroed default forever would show a
	     HUD that never acknowledges the player exists. Their own prestige and settings are real; the
	     plot half is an empty Sanctum, which is the honest answer. ]]
	local userId = userIdOf(player)
	local empty = { Id = 0, State = StateSchema.newPlotState(), Occupants = {} }
	local profileById: ProfileMap, nameById: NameMap = {}, {}
	if userId ~= nil then
		profileById[userId] = if profiles ~= nil then profiles:Get(player) else nil
		local name = nameOf(player)
		if name ~= nil then nameById[userId] = name end
	end
	remotes:FireClient(player, "StateSync", Snapshot.forClient(empty, player, {
		Full = true, Tick = tickCount, MoteCount = 0, Profiles = profileById, Names = nameById,
	}))
end

--[[ An immediate FULL snapshot to every occupant of one Sanctum -- for a caller that has just made
     a change too important to wait out the accumulator (an attunement, a transcendence). ]]
function Service:PushSanctum(sanctum: any): ()
	if plots == nil or remotes == nil or type(sanctum) ~= "table" then return end
	local players = plots:GetOccupants(sanctum)
	if #players == 0 then return end
	tickCount += 1
	--[[ The flag is cleared because this push IS the full snapshot the flag asks for; leaving it set
	     would send the identical payload again on the very next accumulator tick. Essence is recorded
	     for the same reason -- a full snapshot already carries it. ]]
	local record = sanctum :: { [string]: any }
	record.Dirty = false
	lastEssence[sanctum] = essenceOf(sanctum)
	pushFull(sanctum, players)
end

--[[ The loop ]]

local function replicate(sanctum: any): ()
	local players = plots:GetOccupants(sanctum)
	--[[ Nobody to tell. The Dirty flag is deliberately LEFT SET: an empty Sanctum can still be
	     mutated (its grace window expires and PlotService resets it), and clearing the flag with no
	     audience would mean the next player to claim this plot never receives that change. ]]
	if #players == 0 then return end

	local record = sanctum :: { [string]: any }
	local essence = essenceOf(sanctum)
	if record.Dirty == true then
		-- Cleared BEFORE the push: pushFull cannot yield, but clearing first means a re-entrant
		-- MarkDirty (a credit landing inside a handler) survives into the next tick instead of
		-- being wiped by this one.
		record.Dirty = false
		lastEssence[sanctum] = essence
		pushFull(sanctum, players)
	elseif lastEssence[sanctum] ~= essence then
		--[[ Only reachable when the wallet moved WITHOUT a dirty flag. Nothing in the shipped server
		     does that (EconomyService marks dirty on every credit and debit), so this branch is the
		     safety net that keeps the HUD's essence counter live if that ever stops being true. ]]
		lastEssence[sanctum] = essence
		pushFast(sanctum, players)
	end
end

local function onHeartbeat(dt: any): ()
	-- A non-number or NaN dt would poison the accumulator permanently: every later comparison
	-- against NaN is false, so the loop would never push again.
	accumulator += if type(dt) == "number" and dt == dt then dt else 0
	if accumulator < INTERVAL then return end
	-- Reset rather than subtract: after a server hitch the banked time would otherwise fire several
	-- pushes back to back, which is the burst the throttle exists to prevent.
	accumulator = 0
	tickCount += 1
	plots:ForEachSanctum(function(sanctum: any)
		--[[ Per-Sanctum pcall, not one around the whole sweep: a failure on plot 3 must not stop
		     plots 4-6 replicating, and an unguarded error would kill this connection -- and with it
		     every client's HUD -- for the rest of the server's life. ]]
		local ok, err = pcall(replicate, sanctum)
		if not ok and os.clock() - lastWarn >= WARN_SECONDS then
			lastWarn = os.clock()
			warn(("[StateReplicator] snapshot push failed: %s"):format(tostring(err)))
		end
	end)
end

--[[ ServiceRegistry contract ]]

function Service:Init(registry: any): ()
	-- Resolved only: section 6 forbids cross-service calls during Init. This service is registered
	-- LAST, so every peer already exists and Get is right -- a missing one is a Bootstrap bug.
	plots = registry:Get("PlotService")
	profiles = registry:Get("ProfileService")
	remotes = registry:Get("RemoteService")
	economy = registry:Get("EconomyService")
	-- A re-Init must not leave the previous boot's Heartbeat running: it would push snapshots built
	-- from Sanctums PlotService has already destroyed.
	if heartbeat ~= nil then
		heartbeat:Disconnect()
		heartbeat = nil
	end
	accumulator, tickCount, lastWarn = 0, 0, 0
	-- Rebuilt so a re-Init never compares a fresh Sanctum's wallet against a previous boot's reading.
	lastEssence = newEssenceCache()
end

function Service:Start(): ()
	-- The client asks for this on join and on every respawn: the HUD survives a respawn, and a quiet
	-- plot may not go dirty again for minutes, so without an on-demand full push a respawned player
	-- could sit on a stale snapshot indefinitely. RemoteService rate-limits it at 4 per 5s.
	remotes:On("RequestSnapshot", function(player: Player)
		Service:PushTo(player)
	end)
	heartbeat = RunService.Heartbeat:Connect(onHeartbeat)
end

function Service:Stop(): ()
	if heartbeat ~= nil then
		heartbeat:Disconnect()
		heartbeat = nil
	end
	lastEssence = newEssenceCache()
end

return Service
