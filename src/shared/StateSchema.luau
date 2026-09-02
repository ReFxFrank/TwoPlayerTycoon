--!strict
--[[
    StateSchema
    The authoritative shape of everything saved, merged or replicated: PlotState, Prestige, Settings,
    Stats and the Profile wrapping them. It builds fresh state, repairs arbitrary input into a legal
    Profile, version-migrates old saves, max-merges two Sanctum states when a partner links in (§1.5)
    and max-merges two Sanctum states when a partner links in (§1.5). PURE -- no services and no
    Instances -- so ProfileService,
    PlotService, StateReplicator and the headless tests all share one definition.
    Rendering the StateSync payload lives next door in Snapshot.luau.
    Owner: shared  |  Consumers: Snapshot, ProfileService, PlotService, RebirthService, tests
]]
--[[ THREAT MODEL. Input to sanitizeProfile is whatever a DataStore returned: nil, a string, an
     array, a cyclic table, NaN/inf/negative numbers, or a profile forged on an older build. It must
     ALWAYS return a legal Profile and NEVER error -- an error here is a failed load, and a failed
     load ends as a kicked player or, far worse, a blank profile overwriting a real save. Every read
     is depth-bounded (no recursive walk) so a self-referencing table cannot spin, and every value is
     clamped or dropped rather than merely coerced. ]]

local Validate = require(script.Parent.Validate)
local Economy = require(script.Parent.Economy)
local GameConfig = require(script.Parent.GameConfig)
local DropperData = require(script.Parent.DropperData)
local UpgradeData = require(script.Parent.UpgradeData)
local SectionData = require(script.Parent.SectionData)
local EvolutionData = require(script.Parent.EvolutionData)
local AffinityData = require(script.Parent.AffinityData)
local RebirthData = require(script.Parent.RebirthData)

export type PlotState = {
	Essence: number, Stage: number, Affinity: string?,
	Droppers: { [string]: number }, Upgrades: { [string]: number }, Sections: { [string]: boolean },
	LifetimeEssence: number,
}
export type Prestige = { Rebirths: number, Multiplier: number, Badges: { [string]: boolean }, TotalTranscended: number }
export type Settings = { Music: boolean, Sfx: boolean }
export type Stats = { TotalEssenceEarned: number, Playtime: number, JoinCount: number, FirstJoin: number, LastSave: number }
export type Profile = { SchemaVersion: number, Plot: PlotState, Prestige: Prestige, Settings: Settings, Stats: Stats }

local StateSchema = {}
StateSchema.VERSION = 1
-- Currency ceilings sit below 2^53 so every stored balance stays an exact integer; past that,
-- addition rounds and a shared wallet silently drifts. MAX_TIME is seconds since the epoch.
local MAX_CURRENCY, MAX_TIME = 1e15, 1e11
local EMPTY: { [string]: any } = {}
local clamp = Validate.clampNumber -- (v, min, max, default); total, NaN/inf safe

local function tbl(v: any): { [string]: any }
	return if type(v) == "table" then v :: { [string]: any } else EMPTY
end
local function int(v: any, min: number, max: number, default: number): number
	return math.floor(clamp(v, min, max, default))
end
-- Only catalogue ids survive, each count clamped to that def's own ceiling: the single barrier
-- between a hand-edited save ({ god_mode = 1e300 }) and the income loop. Zeroes are dropped so the
-- table stays small and `next(Droppers) == nil` means "owns nothing".
local function sanitizeCounts(raw: any, get: (string) -> any, ceilingField: string): { [string]: number }
	local out: { [string]: number } = {}
	if type(raw) ~= "table" then return out end
	for id, value in pairs(raw :: { [any]: any }) do
		local def = if type(id) == "string" then get(id) else nil
		if def ~= nil then
			local n = int(value, 0, clamp(tbl(def)[ceilingField], 0, 1e6, 0), 0)
			if n > 0 then out[id] = n end
		end
	end
	return out
end
local function sanitizePlotState(raw: any): PlotState
	local src = tbl(raw)
	-- the base wing is force-unlocked: a save that lost it would have no pads and no way back
	local sections: { [string]: boolean } = { [SectionData.Base] = true }
	if type(src.Sections) == "table" then
		for id, value in pairs(src.Sections :: { [any]: any }) do
			if value and type(id) == "string" and SectionData.get(id) ~= nil then sections[id] = true end
		end
	end
	return {
		Essence = clamp(src.Essence, 0, MAX_CURRENCY, 0),
		Stage = int(src.Stage, 1, EvolutionData.MaxStage, 1),
		-- an unknown affinity id becomes nil (unchosen), not a failed lookup on every income tick
		Affinity = if AffinityData.isValid(src.Affinity) then src.Affinity :: string else nil,
		Droppers = sanitizeCounts(src.Droppers, DropperData.get, "MaxOwned"),
		Upgrades = sanitizeCounts(src.Upgrades, UpgradeData.get, "MaxLevel"),
		Sections = sections, LifetimeEssence = clamp(src.LifetimeEssence, 0, MAX_CURRENCY, 0),
	}
end
-- Badges are rebuilt from the rebirth count, then unioned with any stored badge still in the
-- catalogue: rebuilding self-heals an award lost to a failed save, the union keeps a hand-granted
-- one, unknown ids are dropped.
local function sanitizePrestige(raw: any): Prestige
	local src = tbl(raw)
	local rebirths = int(src.Rebirths, 0, RebirthData.MaxTrackedRebirths, 0)
	local badges = RebirthData.badgesFor(rebirths)
	if type(src.Badges) == "table" then
		for id, value in pairs(src.Badges :: { [any]: any }) do
			if value and type(id) == "string" and RebirthData.ById[id] ~= nil then badges[id] = true end
		end
	end
	-- Multiplier is always recomputed: the stored field is a cache, and trusting it would turn one
	-- bad write into a permanent income multiplier.
	return {
		Rebirths = rebirths, Multiplier = Economy.getPrestigeMultiplier(rebirths),
		Badges = badges, TotalTranscended = clamp(src.TotalTranscended, 0, MAX_CURRENCY, 0),
	}
end
-- Both default ON: a missing setting must not silently mute a player who never opened the menu.
local function sanitizeSettings(raw: any): Settings
	local src = tbl(raw)
	return {
		Music = if type(src.Music) == "boolean" then src.Music :: boolean else true,
		Sfx = if type(src.Sfx) == "boolean" then src.Sfx :: boolean else true,
	}
end
local function sanitizeStats(raw: any): Stats
	local src, now = tbl(raw), os.time()
	return {
		TotalEssenceEarned = clamp(src.TotalEssenceEarned, 0, MAX_CURRENCY, 0),
		Playtime = clamp(src.Playtime, 0, MAX_TIME, 0),
		JoinCount = int(src.JoinCount, 0, 1e7, 0),
		FirstJoin = int(src.FirstJoin, 0, MAX_TIME, now), -- absent becomes now, never 1970
		LastSave = int(src.LastSave, 0, MAX_TIME, 0),
	}
end
function StateSchema.newPlotState(): PlotState
	return {
		Essence = clamp(GameConfig.Currency.StartingAmount, 0, MAX_CURRENCY, 0),
		Stage = 1, Affinity = nil, Droppers = {}, Upgrades = {},
		Sections = { [SectionData.Base] = true }, LifetimeEssence = 0,
	}
end
function StateSchema.newProfile(): Profile
	local now = os.time()
	return {
		SchemaVersion = StateSchema.VERSION,
		Plot = StateSchema.newPlotState(),
		Prestige = { Rebirths = 0, Multiplier = Economy.getPrestigeMultiplier(0), Badges = {}, TotalTranscended = 0 },
		Settings = { Music = true, Sfx = true },
		Stats = { TotalEssenceEarned = 0, Playtime = 0, JoinCount = 0, FirstJoin = now, LastSave = 0 },
	}
end
-- Cloning IS repairing: a copy that preserved corruption would spread it to the next save, so the
-- deep copy and the sanitiser are deliberately one operation.
function StateSchema.clonePlotState(state: PlotState): PlotState
	return sanitizePlotState(state)
end
function StateSchema.sanitizeProfile(raw: any): Profile
	local ok, profile = pcall(function(): Profile
		local src = tbl(raw)
		return {
			SchemaVersion = StateSchema.VERSION,
			Plot = sanitizePlotState(src.Plot), Prestige = sanitizePrestige(src.Prestige),
			Settings = sanitizeSettings(src.Settings), Stats = sanitizeStats(src.Stats),
		}
	end)
	-- last resort: a pathological input (protected metatable, __index that throws) still yields a
	-- playable profile instead of an error escaping into the load path
	return if ok then profile else StateSchema.newProfile()
end
-- from-version -> transform. Empty at VERSION 1; each future entry converts one step forward and
-- may assume nothing about its input beyond "it is whatever was stored".
local MIGRATIONS: { [number]: (any) -> any } = {}
function StateSchema.migrate(raw: any): Profile
	local working: any = raw
	local version = int(tbl(raw).SchemaVersion, 0, 1e6, 0)
	local steps = 0 -- bounds the loop even if a future step rewrites SchemaVersion backwards
	while version < StateSchema.VERSION and steps < 64 do
		local step = MIGRATIONS[version]
		if step ~= nil then
			-- a step that throws is skipped, not fatal: sanitizeProfile still salvages the fields it
			-- understands, which beats resetting a veteran's account to zero
			local ok, result = pcall(step, working)
			if ok then working = result end
		end
		version += 1
		steps += 1
	end
	-- A profile stamped NEWER than this server (a rollback) is sanitised down, not refused: unknown
	-- fields are lost, but the player is never locked out of their account.
	-- Exposed because Snapshot, PlotService and the specs all need to repair a fragment of state
-- without loading a whole Profile. They are the same functions the sanitiser uses internally, so
-- there is exactly one definition of "legal".
StateSchema.sanitizePlotState = sanitizePlotState
StateSchema.sanitizePrestige = sanitizePrestige
StateSchema.sanitizeSettings = sanitizeSettings
StateSchema.MAX_CURRENCY = MAX_CURRENCY
StateSchema.MAX_TIME = MAX_TIME

return StateSchema.sanitizeProfile(working)
end
--[[ Max-merge (§1.5): joining an occupied Sanctum must never cost the joiner something they owned,
     so every scalar takes the max and every set takes the union. Essence is MAXed, not summed --
     summing would let a pair relink over and over to duplicate their wallet. ]]
function StateSchema.mergePlotStates(a: PlotState, b: PlotState): PlotState
	local left, right = sanitizePlotState(a), sanitizePlotState(b)
	local out = StateSchema.newPlotState()
	out.Essence = math.max(left.Essence, right.Essence)
	out.Stage = math.max(left.Stage, right.Stage)
	out.LifetimeEssence = math.max(left.LifetimeEssence, right.LifetimeEssence)
	-- `a` wins the affinity: it is the LIVE sanctum, whose conflux visuals and multipliers are
	-- already running. A joiner never rewrites the element the pair has been playing.
	out.Affinity = left.Affinity or right.Affinity
	for _, field in ipairs({ "Droppers", "Upgrades" }) do
		local target = (out :: any)[field] :: { [string]: number }
		for id, count in pairs((left :: any)[field] :: { [string]: number }) do target[id] = count end
		for id, count in pairs((right :: any)[field] :: { [string]: number }) do
			target[id] = math.max(target[id] or 0, count)
		end
	end
	for id in pairs(left.Sections) do out.Sections[id] = true end
	for id in pairs(right.Sections) do out.Sections[id] = true end
	-- re-clamped: a union can exceed a def's MaxOwned if the catalogue shrank between the two saves
	return sanitizePlotState(out)
end

-- Exposed because Snapshot, PlotService and the specs all need to repair a fragment of state
-- without loading a whole Profile. They are the same functions the sanitiser uses internally, so
-- there is exactly one definition of "legal".
StateSchema.sanitizePlotState = sanitizePlotState
StateSchema.sanitizePrestige = sanitizePrestige
StateSchema.sanitizeSettings = sanitizeSettings
StateSchema.MAX_CURRENCY = MAX_CURRENCY
StateSchema.MAX_TIME = MAX_TIME

return StateSchema
