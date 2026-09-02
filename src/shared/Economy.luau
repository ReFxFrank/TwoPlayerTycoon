--!strict
--[[
    Economy
    Every number the game charges, pays out or gates on, gathered into one pure module. It reads the
    static catalogues (Dropper/Upgrade/Section/Evolution/Affinity/Rebirth) plus a PlotState table and
    returns costs, multipliers, income rates and closed-set gate reasons. It holds no state, mutates
    nothing, touches no Instance and calls no service, so the server (truth), the client (prediction)
    and the headless test harness all compute byte-identical numbers.
    Owner: shared  |  Consumers: EconomyService, PurchaseService, EvolutionService, RebirthService,
                                 StateSchema, DropperSystem, MoteSystem, HudController, PromptController
]]

--[[ DEFENSIVE DOCTRINE (why this module looks paranoid)

    Every argument here is untrusted. A PlotState may have come from a DataStore that was corrupted,
    hand-edited by an exploited server, or truncated mid-write; a def may be nil because a catalogue
    entry was renamed in a live patch; a multiplier table may be missing fields because it crossed a
    version boundary. So:

      * every field read goes through num()/map(), which collapse nil, NaN, +/-inf, strings, tables
        and userdata to an explicit safe default;
      * every divisor is clamped away from zero (a 0 or NaN divisor yields inf/NaN income, which
        would then be written back into the save and destroy the profile permanently);
      * a missing or corrupt def is made INFINITELY EXPENSIVE, never free -- the failure mode of a
        bad table must never be a free purchase;
      * only ids present in the catalogues are ever iterated, so an injected id ("i_win": 1e300)
        contributes exactly nothing to income or to totalDroppersOwned.
]]

local GameConfig = require(script.Parent.GameConfig)
local DropperData = require(script.Parent.DropperData)
local UpgradeData = require(script.Parent.UpgradeData)
local SectionData = require(script.Parent.SectionData)
local EvolutionData = require(script.Parent.EvolutionData)
local AffinityData = require(script.Parent.AffinityData)
local RebirthData = require(script.Parent.RebirthData)

-- Structurally identical to StateSchema.PlotState. It is duplicated rather than required because
-- StateSchema requires Economy (for the cached prestige multiplier) and a cycle would break both.
export type PlotState = {
	Essence: number,
	Stage: number,
	Affinity: string?,
	Droppers: { [string]: number },
	Upgrades: { [string]: number },
	Sections: { [string]: boolean },
	LifetimeEssence: number,
}

export type Multipliers = {
	Prestige: number,
	Stage: number,
	Affinity: number,
	Upgrades: number,
	Debug: number,
}

local Economy = {}

--[[ CLOSED SET of gate reasons. The client maps these codes to human text, so they must never carry
     free-form detail: a reason string is a protocol value, not a message. ]]
local Reason = {
	Ok = "ok",
	LockedStage = "locked_stage", -- sanctum Stage is below def.RequiredStage
	LockedSection = "locked_section", -- the Wing hosting/prerequisite for this purchase is not owned
	MaxOwned = "max_owned", -- wellspring count is at MaxOwned
	MaxLevel = "max_level", -- upgrade is at MaxLevel
	AlreadyOwned = "already_owned", -- wing already unlocked
	Insufficient = "insufficient", -- cannot afford
	MaxStage = "max_stage", -- already Primordial, nothing left to attune into
	NeedEssence = "need_essence",
	NeedLifetime = "need_lifetime",
	NeedDroppers = "need_droppers",
	NeedStage = "need_stage", -- transcend gate: not at RebirthData.RequiredStage yet
	UnknownId = "unknown_id", -- def is nil/corrupt; treated as permanently locked
}
Economy.Reason = Reason

-- Hard ceilings. 2^53 is the last integer a double represents exactly; staying well under it keeps
-- essence arithmetic exact and stops a runaway multiplier from serialising as inf.
local MAX_MULTIPLIER = 1e12
local MAX_VALUE = 1e15
local MIN_INTERVAL = 0.15 -- spec floor: faster than this and the mote pipeline just thrashes
local EMPTY: { [string]: any } = {}

local function isFinite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function num(v: any, default: number): number
	return if isFinite(v) then v :: number else default
end

-- Never returns nil, so callers can index the result unconditionally. EMPTY is never written to.
local function map(v: any): { [string]: any }
	return if type(v) == "table" then v :: { [string]: any } else EMPTY
end

-- A multiplier is always finite, never negative (a negative would turn income into a debit) and
-- never large enough to overflow when five of them are multiplied together.
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

local function ownedCount(plot: any, id: string): number
	return math.max(0, math.floor(num(map(map(plot).Droppers)[id], 0)))
end

local function sectionUnlocked(plot: any, id: any): boolean
	if type(id) ~= "string" then
		return false -- a def with a corrupt RequiredSection stays locked rather than opening up
	end
	if id == SectionData.Base then
		return true -- the core wing is unlocked by definition, even in a blank/corrupt state
	end
	return map(map(plot).Sections)[id] and true or false
end

-- FastMode is a dev switch: it divides purchase costs so a tester can walk the whole curve in
-- minutes. Applied at the single choke point every cost getter funnels through.
local function finalCost(cost: number): number
	local value = cost
	if GameConfig.Debug.FastMode then
		value /= math.max(1, num(GameConfig.Debug.FastCostDivisor, 1))
	end
	if not isFinite(value) then
		return math.huge -- unaffordable; see the doctrine note about corrupt defs
	end
	return math.max(0, math.floor(value))
end

function Economy.getPrestigeMultiplier(rebirths: number): number
	local count = math.clamp(math.floor(num(rebirths, 0)), 0, RebirthData.MaxTrackedRebirths)
	return 1 + RebirthData.MultiplierPerRebirth * count
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
	if def == nil then
		return 0 -- unknown id: a tampered save cannot invent an upgrade to farm effects from
	end
	local maxLevel = math.max(0, math.floor(num(def.MaxLevel, 0)))
	return math.clamp(math.floor(num(map(map(plot).Upgrades)[upgradeId], 0)), 0, maxLevel)
end

-- Summed PerLevel * level across every upgrade of `kind`. Iterating the CATALOGUE (not the save)
-- is what makes injected ids inert.
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
	local stage = EvolutionData.get(stageIndexOf(plot))
	local affinity = affinityOf(plot)
	local debugMultiplier = 1
	if GameConfig.Debug.FastMode then
		debugMultiplier = math.max(1, num(GameConfig.Debug.FastIncomeMultiplier, 1))
	end
	return {
		Prestige = mul(Economy.getSanctumPrestigeMultiplier(rebirthsList)),
		Stage = mul(if stage then stage.IncomeMultiplier else 1),
		Affinity = mul(if affinity then affinity.IncomeMultiplier else 1),
		Upgrades = mul(1 + Economy.upgradeEffect(plot, "GlobalIncome")),
		Debug = mul(debugMultiplier),
	}
end

-- Missing fields read as 1 (neutral) so an older/partial Multipliers table degrades instead of
-- zeroing a sanctum's entire income.
function Economy.totalMultiplier(m: Multipliers): number
	local t = map(m)
	local product = mul(t.Prestige) * mul(t.Stage) * mul(t.Affinity) * mul(t.Upgrades) * mul(t.Debug)
	return math.clamp(num(product, 1), 0, MAX_MULTIPLIER)
end

function Economy.getDropperCost(def: DropperData.Dropper, owned: number): number
	local d = map(def)
	-- default math.huge: a nil/renamed def is unaffordable, never free
	local base = math.max(0, num(d.BaseCost, math.huge))
	-- growth < 1 would make each copy CHEAPER than the last -- an infinite-money curve
	local growth = math.clamp(num(d.CostGrowth, 1), 1, 10)
	local count = math.clamp(math.floor(num(owned, 0)), 0, 10000)
	return finalCost(base * growth ^ count)
end

-- Same curve as UpgradeData.levelCost, re-derived here so nil defs and FastMode are handled in one
-- place. math.huge at max level means canAfford is false and no caller needs a special case.
function Economy.getUpgradeCost(def: UpgradeData.Upgrade, level: number): number
	local d = map(def)
	local maxLevel = math.max(0, math.floor(num(d.MaxLevel, 0)))
	local current = math.clamp(math.floor(num(level, 0)), 0, maxLevel)
	if current >= maxLevel then
		return math.huge
	end
	local base = math.max(0, num(d.BaseCost, math.huge))
	local growth = math.clamp(num(d.CostGrowth, 1), 1, 10)
	return finalCost(base * growth ^ current)
end

function Economy.getSectionCost(def: SectionData.Section): number
	return finalCost(math.max(0, num(map(def).Cost, math.huge)))
end

-- Essence paid per collected Mote. FontYield is applied here rather than in the global stack because
-- it is a property of the Font swallowing a mote, and overflow credits must match rail credits.
function Economy.getMoteValue(def: DropperData.Dropper, plot: PlotState, m: Multipliers): number
	local base = math.max(0, num(map(def).BaseValue, 0))
	local affinity = affinityOf(plot)
	local affinityValue = if affinity then mul(affinity.MoteValueMultiplier) else 1
	local font = math.max(0, 1 + Economy.upgradeEffect(plot, "FontYield"))
	return math.clamp(num(base * Economy.totalMultiplier(m) * affinityValue * font, 0), 0, MAX_VALUE)
end

-- `m` is accepted for signature stability but deliberately unused: FastMode/prestige already scale
-- mote VALUE, and scaling the interval too would compound the same bonus twice.
function Economy.getDropperInterval(def: DropperData.Dropper, plot: PlotState, m: Multipliers): number
	local base = math.clamp(num(map(def).Interval, 1), MIN_INTERVAL, 3600)
	local affinity = affinityOf(plot)
	local rate = (1 + Economy.upgradeEffect(plot, "SpawnRate"))
		* (if affinity then mul(affinity.SpawnRateMultiplier) else 1)
	-- clamped away from 0: rate is a divisor, and 0/NaN here would spawn infinite motes per frame
	rate = math.clamp(num(rate, 1), 0.01, 100)
	return math.max(MIN_INTERVAL, base / rate)
end

function Economy.getRailTravelTime(plot: PlotState, m: Multipliers): number
	local base = math.max(0.05, num(GameConfig.Mote.BaseTravelSeconds, 6))
	local floor = math.clamp(num(GameConfig.Mote.MinTravelSeconds, 1.25), 0.05, base)
	local affinity = affinityOf(plot)
	local speed = (1 + Economy.upgradeEffect(plot, "RailSpeed"))
		* (if affinity then mul(affinity.RailSpeedMultiplier) else 1)
	speed = math.clamp(num(speed, 1), 0.01, 100) -- divisor guard, as above
	-- Never longer than base: upgrades may only speed rails up, so a negative-effect corruption
	-- cannot be used to park motes in flight forever and dodge the live-mote cap.
	return math.clamp(base / speed, floor, base)
end

function Economy.getMoteCapacity(plot: PlotState): number
	local base = num(GameConfig.Mote.MaxLivePerSanctum, 60)
	return math.clamp(math.floor(base + Economy.upgradeEffect(plot, "MoteCapacity")), 1, 1000)
end

function Economy.getWalkSpeed(plot: PlotState): number
	local stage = EvolutionData.get(stageIndexOf(plot))
	local base = if stage then num(stage.WalkSpeed, 16) else 16
	local affinity = affinityOf(plot)
	local bonus = if affinity then num(affinity.WalkSpeedBonus, 0) else 0
	-- clamped so a corrupt stage table can never freeze (0) or fling (1e9) a character
	return math.clamp(base + bonus, 8, 100)
end

function Economy.estimateIncomePerSecond(plot: PlotState, m: Multipliers): number
	local owned = map(map(plot).Droppers)
	local total = 0
	for _, def in ipairs(DropperData.List) do
		local count = math.max(0, math.floor(num(owned[def.Id], 0)))
		if count > 0 then
			total += count * Economy.getMoteValue(def, plot, m) / Economy.getDropperInterval(def, plot, m)
		end
	end
	return math.clamp(num(total, 0), 0, MAX_VALUE)
end

function Economy.canAfford(plot: PlotState, cost: number): boolean
	if not isFinite(cost) then
		return false -- math.huge (max level / corrupt def) and NaN are never affordable
	end
	return math.max(0, num(map(plot).Essence, 0)) >= math.max(0, cost)
end

function Economy.totalDroppersOwned(plot: PlotState): number
	local owned = map(map(plot).Droppers)
	local total = 0
	for _, def in ipairs(DropperData.List) do
		total += math.max(0, math.floor(num(owned[def.Id], 0)))
	end
	return total
end

--[[ Gate checks. Each returns (ok, reasonCode) and is ordered cheapest-and-most-permanent first, so
     the UI shows "locked" rather than "can't afford" for something the player cannot buy at all. ]]

function Economy.dropperStatus(plot: PlotState, def: DropperData.Dropper): (boolean, string)
	local d = map(def)
	if type(d.Id) ~= "string" or DropperData.get(d.Id) == nil then
		return false, Reason.UnknownId
	end
	if stageIndexOf(plot) < num(d.RequiredStage, math.huge) then
		return false, Reason.LockedStage
	end
	if not sectionUnlocked(plot, d.RequiredSection) then
		return false, Reason.LockedSection
	end
	local owned = ownedCount(plot, d.Id :: string)
	if owned >= math.max(0, math.floor(num(d.MaxOwned, 0))) then
		return false, Reason.MaxOwned
	end
	if not Economy.canAfford(plot, Economy.getDropperCost(def, owned)) then
		return false, Reason.Insufficient
	end
	return true, Reason.Ok
end

function Economy.upgradeStatus(plot: PlotState, def: UpgradeData.Upgrade): (boolean, string)
	local d = map(def)
	if type(d.Id) ~= "string" or UpgradeData.get(d.Id) == nil then
		return false, Reason.UnknownId
	end
	if stageIndexOf(plot) < num(d.RequiredStage, math.huge) then
		return false, Reason.LockedStage
	end
	if not sectionUnlocked(plot, d.RequiredSection) then
		return false, Reason.LockedSection
	end
	local level = Economy.upgradeLevel(plot, d.Id :: string)
	if level >= math.max(0, math.floor(num(d.MaxLevel, 0))) then
		return false, Reason.MaxLevel
	end
	if not Economy.canAfford(plot, Economy.getUpgradeCost(def, level)) then
		return false, Reason.Insufficient
	end
	return true, Reason.Ok
end

function Economy.sectionStatus(plot: PlotState, def: SectionData.Section): (boolean, string)
	local d = map(def)
	if type(d.Id) ~= "string" or SectionData.get(d.Id) == nil then
		return false, Reason.UnknownId
	end
	if sectionUnlocked(plot, d.Id) then
		-- checked before every other gate so a double-trigger of the same pad (two players hitting
		-- it on the same frame) reports already_owned instead of debiting twice
		return false, Reason.AlreadyOwned
	end
	if stageIndexOf(plot) < num(d.RequiredStage, math.huge) then
		return false, Reason.LockedStage
	end
	if d.RequiredSection ~= nil and not sectionUnlocked(plot, d.RequiredSection) then
		return false, Reason.LockedSection
	end
	if not Economy.canAfford(plot, Economy.getSectionCost(def)) then
		return false, Reason.Insufficient
	end
	return true, Reason.Ok
end

--[[ Attunement gate. NOTE: FastMode does NOT discount RequiredEssence. EvolutionService debits
     `stage.RequiredEssence` straight from the catalogue, so discounting it here would let the gate
     open on essence the debit then fails to take -- a soft-locked attune button. ]]
function Economy.attuneStatus(plot: PlotState): (boolean, string)
	local nextStage = EvolutionData.next(stageIndexOf(plot))
	if nextStage == nil then
		return false, Reason.MaxStage
	end
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
-- pair cannot be locked out by having spent their essence on the sanctum that earned it.
function Economy.transcendStatus(plot: PlotState): (boolean, string)
	if stageIndexOf(plot) < num(RebirthData.RequiredStage, math.huge) then
		return false, Reason.NeedStage
	end
	if math.max(0, num(map(plot).LifetimeEssence, 0)) < num(RebirthData.RequiredLifetimeEssence, math.huge) then
		return false, Reason.NeedLifetime
	end
	return true, Reason.Ok
end

return Economy
