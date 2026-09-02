--!strict
--[[
    Snapshot
    Renders the StateSync payload (spec section 7) that the server pushes to clients. Split out of
    StateSchema so each file stays inside the 300-line budget, and because this is the only piece of
    shared state handling that is about REPLICATION rather than PERSISTENCE.

    PURE: it takes a Sanctum-shaped table plus the per-player Profiles the caller looked up, so it
    can be unit tested with plain tables and never touches a service.
    Owner: shared  |  Consumers: StateReplicator (server), tests
]]

local Validate = require(script.Parent.Validate)
local Economy = require(script.Parent.Economy)
local GameConfig = require(script.Parent.GameConfig)
local EvolutionData = require(script.Parent.EvolutionData)
local StateSchema = require(script.Parent.StateSchema)

type Prestige = StateSchema.Prestige

-- Options for snapshotForClient. Prestige/Settings/Stats live in per-player Profiles, which a pure
-- module cannot fetch, so the caller passes them in keyed by UserId.
export type SnapshotOpts = {
	Full: boolean?, -- false = essence-only fast tick; anything else = full snapshot
	Tick: number?, MoteCount: number?,
	Profiles: { [number]: any }?, -- UserId -> Profile
	Names: { [number]: string }?, -- UserId -> display name
	Multipliers: any?, -- EconomyService's cached Multipliers; recomputed when absent
}

local Snapshot = {}

local EMPTY: { [string]: any } = {}
local MAX_CURRENCY, MAX_TIME = StateSchema.MAX_CURRENCY, StateSchema.MAX_TIME
local clamp = Validate.clampNumber

local function tbl(v: any): { [string]: any }
	return if type(v) == "table" then v :: { [string]: any } else EMPTY
end
local function int(v: any, min: number, max: number, default: number): number
	return math.floor(clamp(v, min, max, default))
end
local sanitizePlotState = StateSchema.sanitizePlotState
local sanitizePrestige = StateSchema.sanitizePrestige
local sanitizeSettings = StateSchema.sanitizeSettings

-- UserId from a number, a plain table (tests) or a Player-like object. pcall'd because the value can
-- be userdata with a protective metatable; a failed read simply means "not you".
local function userIdOf(v: any): number
	if type(v) == "number" then return int(v, 0, 1e18, 0) end
	local ok, id = pcall(function(): any return (v :: any).UserId end)
	return if ok and type(id) == "number" then int(id, 0, 1e18, 0) else 0
end
local function nameOf(opts: { [string]: any }, uid: number, occupant: { [string]: any }): string
	local given = tbl(opts.Names)[uid :: any]
	if type(given) == "string" and #given > 0 then return given end
	if type(occupant.Name) == "string" then return occupant.Name :: string end
	-- read-only fallback off a Player-like field; the pcall keeps this total for plain-table tests
	local ok, name = pcall(function(): any return (occupant.Player :: any).Name end)
	return if ok and type(name) == "string" then name else "Occupant " .. tostring(uid)
end
local function prestigeOf(opts: { [string]: any }, uid: number): Prestige
	return sanitizePrestige(tbl(tbl(opts.Profiles)[uid :: any]).Prestige)
end
local function buildSnapshot(sanctum: any, forPlayer: any, opts: any): { [string]: any }
	local o, root = tbl(opts), tbl(sanctum)
	-- accepts a Sanctum or a bare PlotState, so unit tests can drive it with a plain table
	local plot = sanitizePlotState(if type(root.State) == "table" then root.State else root)
	-- Essence rides every tick, everything else only when Full: §7's bandwidth split
	local snapshotTick = clamp(o.Tick, 0, MAX_TIME, 0)
	if o.Full == false then return { Full = false, Tick = snapshotTick, Essence = plot.Essence } end

	local youId = userIdOf(forPlayer)
	local occupants: { any }, rebirthsList: { number }, yourSlot = {}, {}, 0
	for _, entry in pairs(tbl(root.Occupants)) do
		local occ = tbl(entry)
		local uid = userIdOf(if occ.UserId ~= nil then occ.UserId else occ.Player)
		local prestige = prestigeOf(o, uid)
		local isYou = uid ~= 0 and uid == youId
		local slot = int(occ.Slot, 0, GameConfig.Plot.SlotsPerSanctum, 0)
		if isYou then yourSlot = slot end
		table.insert(rebirthsList, prestige.Rebirths)
		table.insert(occupants, {
			UserId = uid, Name = nameOf(o, uid, occ), Slot = slot,
			Contribution = clamp(occ.Contribution, 0, MAX_CURRENCY, 0),
			Rebirths = prestige.Rebirths, Multiplier = prestige.Multiplier, IsYou = isYou,
		})
	end
	-- sorted by slot: `pairs` order is unspecified, and an unstable partner panel would flicker
	table.sort(occupants, function(x, y): boolean
		return if x.Slot == y.Slot then x.UserId < y.UserId else x.Slot < y.Slot
	end)

	local m = if type(o.Multipliers) == "table" then o.Multipliers else Economy.getMultipliers(plot, rebirthsList)
	local you, yourProfile = prestigeOf(o, youId), tbl(tbl(o.Profiles)[youId :: any])
	local attuneOk, attuneReason = Economy.attuneStatus(plot)
	local transcendOk, transcendReason = Economy.transcendStatus(plot)
	local nextStage = EvolutionData.next(plot.Stage)
	return {
		Full = true, Tick = snapshotTick, Essence = plot.Essence,
		Plot = {
			Id = int(root.Id, 0, 1e6, 0), Stage = plot.Stage, Affinity = plot.Affinity,
			-- fresh tables straight from sanitizePlotState, so a queued payload can never be mutated
			-- out from under the client by the next server tick
			Droppers = plot.Droppers, Upgrades = plot.Upgrades, Sections = plot.Sections,
			LifetimeEssence = plot.LifetimeEssence,
			IncomePerSecond = Economy.estimateIncomePerSecond(plot, m),
			Multiplier = Economy.totalMultiplier(m),
			MoteCount = int(o.MoteCount, 0, 1e6, 0), MoteCapacity = Economy.getMoteCapacity(plot),
		},
		Occupants = occupants,
		You = {
			Rebirths = you.Rebirths, Multiplier = you.Multiplier, Badges = you.Badges,
			Settings = sanitizeSettings(yourProfile.Settings), Slot = yourSlot,
			TotalEssenceEarned = clamp(tbl(yourProfile.Stats).TotalEssenceEarned, 0, MAX_CURRENCY, 0),
		},
		Gates = {
			Attune = { Ok = attuneOk, Reason = attuneReason, -- Cost is 0 at max stage, never nil
				Cost = if nextStage then clamp(nextStage.RequiredEssence, 0, MAX_CURRENCY, 0) else 0,
				NextStage = if nextStage then nextStage.Index else nil },
			Transcend = { Ok = transcendOk, Reason = transcendReason },
			-- Available means "the modal may open" (stage gate only); Chosen stays nil until the
			-- pair picks, and the client uses the pair to choose prompt vs. read-only chip.
			Affinity = { Available = plot.Stage >= EvolutionData.AffinityUnlockStage, Chosen = plot.Affinity },
		},
	}
end
-- Degrades to a harmless fast tick rather than throwing: it runs inside the replication loop, whose
-- single Heartbeat connection drives every sanctum.
function Snapshot.forClient(sanctum: any, forPlayer: any, opts: any): { [string]: any }
	local ok, snapshot = pcall(buildSnapshot, sanctum, forPlayer, opts)
	return if ok then snapshot else { Full = false, Tick = 0, Essence = 0 }
end

return Snapshot
