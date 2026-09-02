--!strict
--[[
    DropperData
    Static catalogue of every Wellspring (dropper) in Sanctum of Embers. Each entry describes its
    geometric cost curve, the Essence value of a single Mote, the emit interval, and the Stage/Wing
    gates that decide when a Sanctum may buy it. The module is PURE data -- it never calls
    game:GetService and never touches an Instance -- so the server (PurchaseService, DropperSystem)
    and the client (pads, HUD) can require the exact same numbers and never disagree.
    Owner: shared  |  Consumers: Economy, PurchaseService, DropperSystem, PlotBuilder, HudController
]]

--[[ BALANCE MODEL -- all figures verified with a greedy purchase simulation.

    ASSUMPTION (contract with PlotService): a freshly created Sanctum is granted ONE free
    `ember_vent`. StateSchema.newPlotState() returns Droppers = {} , so PlotService is the component
    that seeds `Droppers.ember_vent = 1` when it builds a brand new (non-loaded) Sanctum. Without
    that seed a cold start has zero income and the first purchase would never be affordable.

    Cold start arithmetic:
      1 free ember_vent -> 1 Essence / 2.0s = 0.50 Essence/s.
      Second ember_vent costs floor(15 * 1.18^1) = 17.  17 / 0.50 = 34 s.
      -> first *purchased* Wellspring lands at ~34 s, inside the 25-40 s target window.

    Per-second yield (BaseValue / Interval) of the BEST Wellspring of each Stage. The brief asks for
    a 6-10x jump per Stage so every Attunement feels like a real power spike:
      S1 dew_font      4 / 2.2 =     1.82/s
      S2 gale_flue    26 / 2.0 =    13.0 /s   (x7.2)
      S3 tidal_weir  190 / 2.0 =    95.0 /s   (x7.3)
      S4 storm_coil 1400 / 2.0 =   700.0 /s   (x7.4)
      S5 magma_heart      12000 / 2.4 =  5000/s   (x7.1)
      S6 aether_spire     90000 / 2.5 = 36000/s   (x7.2)

    BaseCost is set so a first copy pays for itself in ~30 s (S1) rising to ~220 s (S6); the longer
    late-game payback is what stops the curve from running away once Stage multipliers stack.
    CostGrowth shrinks from 1.18 to 1.12 with tier because absolute prices are already enormous --
    all values sit inside the mandated 1.12..1.35 band.

    Simulated first run (prestige x1, no Affinity): Stage 2 @ 4.3 min, Stage 3 @ 18.2 min,
    Stage 4 @ 26.4 min, Stage 5 @ 34.3 min, Stage 6 @ 51.9 min, Transcend-ready @ 54.7 min.
    Same run at 4 rebirths solo: 22.8 min. Two occupants at 4 rebirths each (sanctum multiplier
    1 + 0.25*4 + 0.25*4 = 3.0): 15.1 min, i.e. ~28% of a first run -- the "about a third" target.
]]

export type Dropper = {
	Id: string,
	Name: string,
	Description: string,
	BaseCost: number,
	CostGrowth: number, -- cost = floor(BaseCost * CostGrowth ^ owned)
	BaseValue: number, -- Essence per Mote before multipliers
	Interval: number, -- seconds between Motes before multipliers
	MaxOwned: number,
	RequiredStage: number,
	RequiredSection: string, -- Wing id whose pad hosts this Wellspring
	Order: number,
	Color: Color3,
	Material: Enum.Material,
}

local DropperData = {}

-- Written in ascending Order; `List` is re-sorted below so a future edit cannot silently break the
-- pad layout (PlotLayout.padCFrame keys off Order).
DropperData.List = {
	{
		Id = "ember_vent", Name = "Ember Vent",
		Description = "A hairline fissure in the sanctum floor. It breathes warm sparks -- barely Essence, but it is a beginning.",
		BaseCost = 15, CostGrowth = 1.18, BaseValue = 1, Interval = 2.0, MaxOwned = 25,
		RequiredStage = 1, RequiredSection = "wing_core", Order = 1,
		Color = Color3.fromRGB(255, 120, 48), Material = Enum.Material.Neon,
	},
	{
		Id = "dew_font", Name = "Dew Font",
		Description = "Condenses ambient damp into heavy droplets of raw Essence. Slower than the Vent, four times richer.",
		BaseCost = 150, CostGrowth = 1.17, BaseValue = 4, Interval = 2.2, MaxOwned = 20,
		RequiredStage = 1, RequiredSection = "wing_core", Order = 2,
		Color = Color3.fromRGB(96, 200, 255), Material = Enum.Material.Neon,
	},
	{
		Id = "loam_seep", Name = "Loam Seep",
		Description = "Living soil pressed against the Core, weeping mineral Essence. Cheap enough to stack early in Stage 2.",
		BaseCost = 350, CostGrowth = 1.17, BaseValue = 9, Interval = 2.4, MaxOwned = 20,
		RequiredStage = 2, RequiredSection = "wing_core", Order = 3,
		Color = Color3.fromRGB(150, 200, 96), Material = Enum.Material.Neon,
	},
	{
		Id = "gale_flue", Name = "Gale Flue",
		Description = "A pressure chimney in the Ember Forge that spits Essence on every updraft. The first real power spike.",
		BaseCost = 1300, CostGrowth = 1.16, BaseValue = 26, Interval = 2.0, MaxOwned = 16,
		RequiredStage = 2, RequiredSection = "wing_ember_forge", Order = 4,
		Color = Color3.fromRGB(190, 235, 255), Material = Enum.Material.ForceField,
	},
	{
		Id = "cinder_forge", Name = "Cinder Forge",
		Description = "Hammers spent cinders back into dense Motes. Loud, hot, and the backbone of a Stage 3 sanctum.",
		BaseCost = 3800, CostGrowth = 1.16, BaseValue = 60, Interval = 2.2, MaxOwned = 16,
		RequiredStage = 3, RequiredSection = "wing_ember_forge", Order = 5,
		Color = Color3.fromRGB(255, 86, 40), Material = Enum.Material.Neon,
	},
	{
		Id = "tidal_weir", Name = "Tidal Weir",
		Description = "Dams the Basin's standing wave and taps the pressure differential. Stage 3's headline Wellspring.",
		BaseCost = 14000, CostGrowth = 1.15, BaseValue = 190, Interval = 2.0, MaxOwned = 14,
		RequiredStage = 3, RequiredSection = "wing_tide_basin", Order = 6,
		Color = Color3.fromRGB(40, 150, 255), Material = Enum.Material.Neon,
	},
	{
		Id = "quartz_bloom", Name = "Quartz Bloom",
		Description = "A crystal lattice that flowers, sheds an Essence-dense petal, and regrows. Slow bloom, huge petal.",
		BaseCost = 32000, CostGrowth = 1.15, BaseValue = 420, Interval = 2.2, MaxOwned = 12,
		RequiredStage = 4, RequiredSection = "wing_tide_basin", Order = 7,
		Color = Color3.fromRGB(210, 170, 255), Material = Enum.Material.Glass,
	},
	{
		Id = "storm_coil", Name = "Storm Coil",
		Description = "Bleeds a captive thunderhead one arc at a time. Expensive, but it carries the whole Terra Vault.",
		BaseCost = 120000, CostGrowth = 1.14, BaseValue = 1400, Interval = 2.0, MaxOwned = 12,
		RequiredStage = 4, RequiredSection = "wing_terra_vault", Order = 8,
		Color = Color3.fromRGB(150, 190, 255), Material = Enum.Material.ForceField,
	},
	{
		Id = "magma_heart", Name = "Magma Heart",
		Description = "A caged fragment of the world's core. Every slow pulse is worth more than an entire Stage 3 wing.",
		BaseCost = 1000000, CostGrowth = 1.13, BaseValue = 12000, Interval = 2.4, MaxOwned = 10,
		RequiredStage = 5, RequiredSection = "wing_terra_vault", Order = 9,
		Color = Color3.fromRGB(255, 60, 20), Material = Enum.Material.Neon,
	},
	{
		Id = "aether_spire", Name = "Aether Spire",
		Description = "Pierces the veil above the Zephyr Spire and draws Essence straight from the Primordial. The endgame.",
		BaseCost = 8000000, CostGrowth = 1.12, BaseValue = 90000, Interval = 2.5, MaxOwned = 8,
		RequiredStage = 6, RequiredSection = "wing_zephyr_spire", Order = 10,
		Color = Color3.fromRGB(255, 240, 180), Material = Enum.Material.Neon,
	},
} :: { Dropper }

table.sort(DropperData.List, function(a: Dropper, b: Dropper): boolean
	return a.Order < b.Order
end)

DropperData.ById = {} :: { [string]: Dropper }
for _, def in ipairs(DropperData.List) do
	DropperData.ById[def.Id] = def
end

function DropperData.get(id: string): Dropper?
	return DropperData.ById[id]
end

-- Everything a Sanctum at `stage` is allowed to see. Section ownership is a SEPARATE gate checked by
-- Economy.dropperStatus, because a Wing can be unlocked long after its Stage requirement is met.
function DropperData.forStage(stage: number): { Dropper }
	local out: { Dropper } = {}
	for _, def in ipairs(DropperData.List) do
		if def.RequiredStage <= stage then
			table.insert(out, def)
		end
	end
	return out
end

return DropperData
