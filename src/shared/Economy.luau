--!strict
--[[
    Economy
    Every number the game charges, pays out or gates on, in one pure module: it reads the static
    catalogues (Dropper/Upgrade/Section/Evolution/Affinity/Rebirth) plus a PlotState table and returns
    costs, multipliers, income rates and closed-set gate reasons. It holds no state, mutates nothing,
    touches no Instance and calls no service, so the server (truth), the client (prediction) and the
    headless test harness all compute byte-identical numbers.
    Owner: shared  |  Consumers: EconomyService, PurchaseService, EvolutionService, RebirthService,
                                 StateSchema, DropperSystem, MoteSystem, HudController, PromptController
]]
--[[ DEFENSIVE DOCTRINE -- why the reads below look paranoid. Every argument is untrusted: a
     PlotState may come from a corrupted DataStore, a def may be nil because a catalogue id was
     renamed in a live patch, a Multipliers table may have crossed a version boundary missing fields.
     So: every field read goes through num()/map(), collapsing nil/NaN/inf/string/userdata to a safe
     default (NaN is the dangerous one -- `NaN >= x` is false, so unguarded clamps silently fail);
     every divisor is clamped off zero, because an inf/NaN income is written straight back into the
     save and destroys the profile permanently; a missing or corrupt def is made INFINITELY
     EXPENSIVE, never free; and only catalogue ids are ever iterated, so an injected save key
     ("i_win" = 1e300) contributes exactly nothing to income, cost or totalDroppersOwned. ]]

local GameConfig = require(script.Parent.GameConfig)
local DropperData = require(script.Parent.DropperData)
local UpgradeData = require(script.Parent.UpgradeData)
local SectionData = require(script.Parent.SectionData)
local EvolutionData = require(script.Parent.EvolutionData)
local AffinityData = require(script.Parent.AffinityData)
local RebirthData = require(script.Parent.RebirthData)

-- Structurally identical to StateSchema.PlotState, duplicated rather than required because
-- StateSchema requires Economy (for the cached prestige multiplier) and a cycle would break both.
export type PlotState = {
	Essence: number, Stage: number, Affinity: string?,
	Droppers: { [string]: number }, Upgrades: { [string]: number }, Sections: { [string]: boolean },
	LifetimeEssence: number,
}
export type Multipliers = { Prestige: number, Stage: number, Affinity: number, Upgrades: number, Debug: number }

local Economy = {}

-- CLOSED SET of gate reasons. The client maps these codes to human text, so a reason is a protocol
-- value and must never carry free-form detail. locked_* are permanent, need_* are progress gates.
local Reason = {
	Ok = "ok",
	LockedStage = "locked_stage", LockedSection = "locked_section", -- stage gate / wing gate
	MaxOwned = "max_owned", MaxLevel = "max_level", AlreadyOwned = "already_owned",
	Insufficient = "insufficient", -- cannot afford
	MaxStage = "max_stage", -- already Primordial, nothing left to attune into
	NeedEssence = "need_essence", NeedLifetime = "need_lifetime", NeedDroppers = "need_droppers",
	NeedStage = "need_stage", -- transcend gate: below RebirthData.RequiredStage
	UnknownId = "unknown_id", -- def nil/corrupt; treated as permanently locked
}
Economy.Reason = Reason

-- 2^53 is the last exactly-representable integer double; staying well under it keeps essence
-- arithmetic exact and stops a runaway multiplier from serialising as inf.
local MAX_MULTIPLIER, MAX_VALUE = 1e12, 1e15
-- Above MAX_VALUE and above any balance StateSchema will store, so `canAfford` is always
-- false against it, while staying finite and printable.
local UNAFFORDABLE = 1e18
local MIN_INTERVAL = 0.15 -- spec floor; below this the mote pipeline just thrashes
local EMPTY: { [string]: any } = {}

local function isFinite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end
local function num(v: any, default: number): number
	return if isFinite(v) then v :: number else default
end
-- Never nil, so callers index unconditionally. EMPTY is shared and never written to.
local function map(v: any): { [string]: any }
	return if type(v) == "table" then v :: { [string]: any } else EMPTY
end
-- Finite, never negative (a negative multiplier would turn income into a debit) and small enough
-- that five of them multiplied together cannot overflow to inf.
local function mul(v: any): number
	return math.clamp(num(v, 1), 0, MAX_MULTIPLIER)
end
local function stageIndexOf(plot: any): number
	return math.clamp(math.floor(num(map(plot).Stage, 1)), 1, EvolutionData.MaxStage)
end
local function affinityOf(plot: any): AffinityData.Affinity?
	local id = map(plot).Affinity
	return if type(id) == "string" then AffinityData.get(id) else nil
end
local function ownedOf(plot: any, id: any): number
	return math.max(0, math.floor(num(map(map(plot).Droppers)[id], 0)))
end
local function sectionUnlocked(plot: any, id: any): boolean
	if type(id) ~= "string" then return false end -- corrupt RequiredSection stays LOCKED
	if id == SectionData.Base then return true end -- core wing is unlocked by definition
	return map(map(plot).Sections)[id] and true or false
end

-- The one choke point every cost passes through. FastMode is a dev switch that divides costs so a
-- tester can walk the whole curve in minutes; a non-finite cost becomes huge (never free).
local function finalCost(cost: number): number
	local value = cost
	if GameConfig.Debug.FastMode then
		value /= math.max(1, num(GameConfig.Debug.FastCostDivisor, 1))
	end
	-- An overflowing curve (a corrupt save claiming 1e300 owned) collapses to UNAFFORDABLE, a
	-- finite ceiling above any reachable Essence balance -- NOT math.huge. inf would survive into
	-- the client snapshot, and Format renders a non-finite number as "0", so an impossible cost
	-- would read as "free" on the pad. Finite keeps every downstream comparison and label honest.
	return if isFinite(value) then math.max(0, math.floor(value)) else UNAFFORDABLE
end

-- cost = floor(BaseCost * CostGrowth^n), shared by wellsprings and upgrades. Growth is clamped to
-- >= 1 because growth below 1 makes each copy cheaper than the last: an infinite-money curve. A nil
-- BaseCost defaults to huge, so a renamed or corrupt def is unaffordable rather than free.
local function curveCost(d: { [string]: any }, n: number): number
	local growth = math.clamp(num(d.CostGrowth, 1), 1, 10)
	local steps = math.clamp(math.floor(num(n, 0)), 0, 10000)
	return finalCost(math.max(0, num(d.BaseCost, math.huge)) * growth ^ steps)
end

function Economy.getPrestigeMultiplier(rebirths: number): number
	-- clamped to MaxTrackedRebirths so a tampered profile claiming 1e300 rebirths gets the cap
	return 1 + RebirthData.MultiplierPerRebirth
		* math.clamp(math.floor(num(rebirths, 0)), 0, RebirthData.MaxTrackedRebirths)
end

-- SUM of bonuses, not product (§1.5 co-op design): a veteran lifts their partner's sanctum without
-- squaring the pair's output. 1 + 0.25*Ra + 0.25*Rb.
function Economy.getSanctumPrestigeMultiplier(rebirthsList: { number }): number
	local total = 1
	if type(rebirthsList) == "table" then
		for _, r in ipairs(rebirthsList) do
			total += Economy.getPrestigeMultiplier(r) - 1
		end
	end
	return math.clamp(num(total, 1), 1, MAX_MULTIPLIER)
end

function Economy.upgradeLevel(plot: PlotState, upgradeId: string): number
	local def = if type(upgradeId) == "string" then UpgradeData.get(upgradeId) else nil
	if def == nil then return 0 end -- a tampered save cannot invent an upgrade to farm effects from
	return math.clamp(math.floor(num(map(map(plot).Upgrades)[upgradeId], 0)), 0,
		math.max(0, math.floor(num(def.MaxLevel, 0))))
end

-- Summed PerLevel * level over every upgrade of `kind`. Iterating the CATALOGUE (never the save) is
-- what makes injected ids inert.
function Economy.upgradeEffect(plot: PlotState, kind: string): number
	local total = 0
	for _, def in ipairs(UpgradeData.List) do
		if def.Kind == kind then
			total += num(def.PerLevel, 0) * Economy.upgradeLevel(plot, def.Id)
		end
	end
	return math.clamp(num(total, 0), 0, MAX_MULTIPLIER)
end

function Economy.getMultipliers(plot: PlotState, rebirthsList: { number }): Multipliers
	local stage, affinity = EvolutionData.get(stageIndexOf(plot)), affinityOf(plot)
	return {
		Prestige = mul(Economy.getSanctumPrestigeMultiplier(rebirthsList)),
		Stage = mul(if stage then stage.IncomeMultiplier else 1),
		Affinity = mul(if affinity then affinity.IncomeMultiplier else 1),
		Upgrades = mul(1 + Economy.upgradeEffect(plot, "GlobalIncome")),
		-- FastMode's income half; its cost half lives in finalCost
		Debug = mul(if GameConfig.Debug.FastMode then math.max(1, num(GameConfig.Debug.FastIncomeMultiplier, 1)) else 1),
	}
end

-- Missing fields read as 1 (neutral), so a partial Multipliers table degrades gracefully instead of
-- zeroing a sanctum's whole income.
function Economy.totalMultiplier(m: Multipliers): number
	local t = map(m)
	local product = mul(t.Prestige) * mul(t.Stage) * mul(t.Affinity) * mul(t.Upgrades) * mul(t.Debug)
	return math.clamp(num(product, 1), 0, MAX_MULTIPLIER)
end

function Economy.getDropperCost(def: DropperData.Dropper, owned: number): number
	return curveCost(map(def), owned)
end

-- Same curve as UpgradeData.levelCost, re-derived so nil defs and FastMode are handled in one place.
-- math.huge at max level keeps canAfford false, so no caller needs a special case.
function Economy.getUpgradeCost(def: UpgradeData.Upgrade, level: number): number
	local d = map(def)
	local maxLevel = math.max(0, math.floor(num(d.MaxLevel, 0)))
	local current = math.clamp(math.floor(num(level, 0)), 0, maxLevel)
	return if current >= maxLevel then math.huge else curveCost(d, current)
end

function Economy.getSectionCost(def: SectionData.Section): number
	return finalCost(math.max(0, num(map(def).Cost, math.huge)))
end

-- Essence per collected Mote. FontYield applies here rather than in the global stack because it is a
-- property of the Font swallowing a mote -- and because overflow credits must match rail credits.
function Economy.getMoteValue(def: DropperData.Dropper, plot: PlotState, m: Multipliers): number
	local affinity = affinityOf(plot)
	local value = math.max(0, num(map(def).BaseValue, 0)) * Economy.totalMultiplier(m)
		* (if affinity then mul(affinity.MoteValueMultiplier) else 1)
		* math.max(0, 1 + Economy.upgradeEffect(plot, "FontYield"))
	return math.clamp(num(value, 0), 0, MAX_VALUE)
end

-- `m` is accepted for signature stability but deliberately unused: prestige/stage/FastMode already
-- scale mote VALUE, and scaling the interval too would compound the same bonus twice.
function Economy.getDropperInterval(def: DropperData.Dropper, plot: PlotState, m: Multipliers): number
	local base = math.clamp(num(map(def).Interval, 1), MIN_INTERVAL, 3600)
	local affinity = affinityOf(plot)
	-- clamped off zero: rate is a divisor, and 0/NaN here would spawn infinite motes in one frame
	local rate = math.clamp(num((1 + Economy.upgradeEffect(plot, "SpawnRate"))
		* (if affinity then mul(affinity.SpawnRateMultiplier) else 1), 1), 0.01, 100)
	return math.max(MIN_INTERVAL, base / rate)
end

function Economy.getRailTravelTime(plot: PlotState, m: Multipliers): number
	local base = math.max(0.05, num(GameConfig.Mote.BaseTravelSeconds, 6))
	local floor = math.clamp(num(GameConfig.Mote.MinTravelSeconds, 1.25), 0.05, base)
	local affinity = affinityOf(plot)
	local speed = math.clamp(num((1 + Economy.upgradeEffect(plot, "RailSpeed"))
		* (if affinity then mul(affinity.RailSpeedMultiplier) else 1), 1), 0.01, 100) -- divisor guard
	-- Clamped to <= base as well: upgrades may only speed rails UP, so corruption cannot park motes
	-- in flight forever to dodge the live-mote cap.
	return math.clamp(base / speed, floor, base)
end

function Economy.getMoteCapacity(plot: PlotState): number
	-- ceiling of 1000 parts per sanctum: the cap is a render/memory budget as well as a game rule
	return math.clamp(math.floor(num(GameConfig.Mote.MaxLivePerSanctum, 60)
		+ Economy.upgradeEffect(plot, "MoteCapacity")), 1, 1000)
end

function Economy.getWalkSpeed(plot: PlotState): number
	local stage, affinity = EvolutionData.get(stageIndexOf(plot)), affinityOf(plot)
	-- clamped so a corrupt stage table can neither freeze (0) nor fling (1e9) a character
	return math.clamp((if stage then num(stage.WalkSpeed, 16) else 16)
		+ (if affinity then num(affinity.WalkSpeedBonus, 0) else 0), 8, 100)
end

function Economy.estimateIncomePerSecond(plot: PlotState, m: Multipliers): number
	local total = 0
	for _, def in ipairs(DropperData.List) do
		local count = ownedOf(plot, def.Id)
		if count > 0 then
			total += count * Economy.getMoteValue(def, plot, m) / Economy.getDropperInterval(def, plot, m)
		end
	end
	return math.clamp(num(total, 0), 0, MAX_VALUE)
end

function Economy.canAfford(plot: PlotState, cost: number): boolean
	-- math.huge (max level / corrupt def) and NaN must never read as affordable
	if not isFinite(cost) then return false end
	return math.max(0, num(map(plot).Essence, 0)) >= math.max(0, cost)
end

function Economy.totalDroppersOwned(plot: PlotState): number
	local total = 0
	for _, def in ipairs(DropperData.List) do
		total += ownedOf(plot, def.Id)
	end
	return total
end

-- Gate checks return (ok, reasonCode), ordered most-permanent-first so the UI says "locked" rather
-- than "can't afford" for something the pair cannot buy at all. Shared prelude: identity, stage
-- gate, hosting-wing gate. A def missing from its catalogue is unknown_id, so a forged pad id can
-- never reach a debit.
local function lockReason(plot: PlotState, d: { [string]: any }, known: boolean): string?
	if type(d.Id) ~= "string" or not known then return Reason.UnknownId end
	if stageIndexOf(plot) < num(d.RequiredStage, math.huge) then return Reason.LockedStage end
	if not sectionUnlocked(plot, d.RequiredSection) then return Reason.LockedSection end
	return nil
end

function Economy.dropperStatus(plot: PlotState, def: DropperData.Dropper): (boolean, string)
	local d = map(def)
	local locked = lockReason(plot, d, type(d.Id) == "string" and DropperData.get(d.Id) ~= nil)
	if locked then return false, locked end
	local owned = ownedOf(plot, d.Id)
	if owned >= math.max(0, math.floor(num(d.MaxOwned, 0))) then return false, Reason.MaxOwned end
	if not Economy.canAfford(plot, Economy.getDropperCost(def, owned)) then return false, Reason.Insufficient end
	return true, Reason.Ok
end

function Economy.upgradeStatus(plot: PlotState, def: UpgradeData.Upgrade): (boolean, string)
	local d = map(def)
	local locked = lockReason(plot, d, type(d.Id) == "string" and UpgradeData.get(d.Id) ~= nil)
	if locked then return false, locked end
	local level = Economy.upgradeLevel(plot, d.Id :: string)
	if level >= math.max(0, math.floor(num(d.MaxLevel, 0))) then return false, Reason.MaxLevel end
	if not Economy.canAfford(plot, Economy.getUpgradeCost(def, level)) then return false, Reason.Insufficient end
	return true, Reason.Ok
end

function Economy.sectionStatus(plot: PlotState, def: SectionData.Section): (boolean, string)
	local d = map(def)
	if type(d.Id) ~= "string" or SectionData.get(d.Id) == nil then return false, Reason.UnknownId end
	-- ownership is checked FIRST so two players triggering one pad on the same frame get
	-- already_owned back instead of paying for the same wing twice
	if sectionUnlocked(plot, d.Id) then return false, Reason.AlreadyOwned end
	if stageIndexOf(plot) < num(d.RequiredStage, math.huge) then return false, Reason.LockedStage end
	if d.RequiredSection ~= nil and not sectionUnlocked(plot, d.RequiredSection) then
		return false, Reason.LockedSection
	end
	if not Economy.canAfford(plot, Economy.getSectionCost(def)) then return false, Reason.Insufficient end
	return true, Reason.Ok
end

-- Attunement gate. NOTE: FastMode does NOT discount RequiredEssence -- EvolutionService debits
-- stage.RequiredEssence straight from the catalogue, so a discount here would open the gate on
-- essence the debit then fails to take, soft-locking the Attune button. Requirements default to
-- huge when a stage table is corrupt: the gate shuts, it never falls wide open.
function Economy.attuneStatus(plot: PlotState): (boolean, string)
	local nextStage = EvolutionData.next(stageIndexOf(plot))
	if nextStage == nil then return false, Reason.MaxStage end
	local p = map(plot)
	if math.max(0, num(p.Essence, 0)) < num(nextStage.RequiredEssence, math.huge) then
		return false, Reason.NeedEssence
	end
	if math.max(0, num(p.LifetimeEssence, 0)) < num(nextStage.RequiredLifetimeEssence, math.huge) then
		return false, Reason.NeedLifetime
	end
	if Economy.totalDroppersOwned(plot) < num(nextStage.RequiredDroppers, math.huge) then
		return false, Reason.NeedDroppers
	end
	return true, Reason.Ok
end

-- Measured against LifetimeEssence (earned since the last Transcendence), never the wallet, so a
-- pair cannot be locked out by having spent the essence on the sanctum that earned it.
function Economy.transcendStatus(plot: PlotState): (boolean, string)
	if stageIndexOf(plot) < num(RebirthData.RequiredStage, math.huge) then return false, Reason.NeedStage end
	if math.max(0, num(map(plot).LifetimeEssence, 0)) < num(RebirthData.RequiredLifetimeEssence, math.huge) then
		return false, Reason.NeedLifetime
	end
	return true, Reason.Ok
end

return Economy
