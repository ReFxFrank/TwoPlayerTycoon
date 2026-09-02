--!strict
--[[
    UpgradeData
    Static catalogue of the six Sanctum Upgrades. Each Upgrade is a levelled purchase whose `Kind`
    tells Economy which part of the pipeline it bends: Ley Rail travel time, Conflux Font yield,
    Wellspring spawn rate, live Mote capacity, or a flat global income multiplier. PURE data -- no
    services, no Instances -- so the pad text on the client and the debit on the server are computed
    from one identical table.
    Owner: shared  |  Consumers: Economy, PurchaseService, MoteSystem, DropperSystem, HudController
]]

--[[ BALANCE MODEL

    Economy treats PerLevel as a FRACTION for the four multiplicative Kinds (0.06 = +6% per level)
    and as a FLAT COUNT for MoteCapacity (10 = +10 live Motes per level). Fully levelled, the
    multiplicative stack is deliberately capped at roughly:
        GlobalIncome  1 + (15 * 0.04) + (20 * 0.06) = x2.80
        FontYield     1 + (12 * 0.05)               = x1.60
        SpawnRate     1 + (12 * 0.04)               = x1.48
        -> combined income ceiling ~x6.6
    That ceiling matters: Wellspring tiers already grow ~7x per Stage, so an uncapped upgrade stack
    would compress Stages 4-6 into a couple of minutes. x6.6 across a whole run is roughly "one free
    extra Stage", which is a satisfying reward without collapsing the curve.

    CostGrowth is HIGHER than the Wellspring curves (1.24..1.35 vs 1.12..1.18) on purpose: an Upgrade
    level is strictly better than an extra Wellspring at equal price because it scales the entire
    Sanctum, so it has to price itself out faster or nothing else would ever be bought.

    RailSpeed and MoteCapacity are quality-of-life rather than raw income -- they stop Motes queueing
    up at the cap during a Stage spike, which is where income is silently lost. They are cheap early
    for exactly that reason.
]]

export type UpgradeKind = "RailSpeed" | "FontYield" | "SpawnRate" | "MoteCapacity" | "GlobalIncome"

export type Upgrade = {
	Id: string,
	Name: string,
	Description: string,
	Kind: UpgradeKind,
	MaxLevel: number,
	BaseCost: number,
	CostGrowth: number, -- cost of the NEXT level = floor(BaseCost * CostGrowth ^ currentLevel)
	PerLevel: number, -- fraction for multiplicative Kinds, flat count for MoteCapacity
	RequiredStage: number,
	RequiredSection: string, -- Wing id whose pad hosts this Upgrade
	Order: number,
}

local UpgradeData = {}

UpgradeData.List = {
	{
		Id = "ley_flow", Name = "Ley Flow",
		Description = "Polishes the Ley Rails so Motes slide to the Font faster. Less time in transit, less income sitting still.",
		Kind = "RailSpeed", MaxLevel = 10, BaseCost = 500, CostGrowth = 1.30, PerLevel = 0.06,
		RequiredStage = 1, RequiredSection = "wing_core", Order = 1,
	},
	{
		Id = "font_resonance", Name = "Font Resonance",
		Description = "Tunes the Conflux Font to the Sanctum's key, so every Mote it swallows yields more Essence.",
		Kind = "FontYield", MaxLevel = 12, BaseCost = 900, CostGrowth = 1.28, PerLevel = 0.05,
		RequiredStage = 2, RequiredSection = "wing_core", Order = 2,
	},
	{
		Id = "wellspring_cadence", Name = "Wellspring Cadence",
		Description = "Shortens the pause between condensations. Every Wellspring in the Sanctum emits more often.",
		Kind = "SpawnRate", MaxLevel = 12, BaseCost = 2500, CostGrowth = 1.32, PerLevel = 0.04,
		RequiredStage = 2, RequiredSection = "wing_ember_forge", Order = 3,
	},
	{
		Id = "mote_lattice", Name = "Mote Lattice",
		Description = "Widens the rails so more Motes can ride at once. Raises the live cap by ten per level.",
		Kind = "MoteCapacity", MaxLevel = 8, BaseCost = 6000, CostGrowth = 1.35, PerLevel = 10,
		RequiredStage = 3, RequiredSection = "wing_ember_forge", Order = 4,
	},
	{
		Id = "conflux_attunement", Name = "Conflux Attunement",
		Description = "Teaches the Conflux to draw on the whole Sanctum at once. A flat boost to all Essence earned.",
		Kind = "GlobalIncome", MaxLevel = 15, BaseCost = 15000, CostGrowth = 1.26, PerLevel = 0.04,
		RequiredStage = 3, RequiredSection = "wing_tide_basin", Order = 5,
	},
	{
		Id = "primordial_echo", Name = "Primordial Echo",
		Description = "Late-run capstone: the Conflux remembers every Stage it has worn and echoes them all at once.",
		Kind = "GlobalIncome", MaxLevel = 20, BaseCost = 2500000, CostGrowth = 1.24, PerLevel = 0.06,
		RequiredStage = 5, RequiredSection = "wing_terra_vault", Order = 6,
	},
} :: { Upgrade }

table.sort(UpgradeData.List, function(a: Upgrade, b: Upgrade): boolean
	return a.Order < b.Order
end)

UpgradeData.ById = {} :: { [string]: Upgrade }
for _, def in ipairs(UpgradeData.List) do
	UpgradeData.ById[def.Id] = def
end

function UpgradeData.get(id: string): Upgrade?
	return UpgradeData.ById[id]
end

function UpgradeData.forStage(stage: number): { Upgrade }
	local out: { Upgrade } = {}
	for _, def in ipairs(UpgradeData.List) do
		if def.RequiredStage <= stage then
			table.insert(out, def)
		end
	end
	return out
end

-- Cost of buying level `currentLevel + 1`. Floored so the UI, the pad text and the debit can never
-- disagree by a fraction of an Essence. Returns math.huge at max level so `canAfford` is always
-- false there and no caller needs a special case.
function UpgradeData.levelCost(def: Upgrade, currentLevel: number): number
	if currentLevel >= def.MaxLevel then
		return math.huge
	end
	local level = math.max(0, math.floor(currentLevel))
	return math.floor(def.BaseCost * def.CostGrowth ^ level)
end

return UpgradeData
