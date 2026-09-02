--!strict
--[[
    EvolutionData
    The six Attunement Stages the shared Conflux grows through: their entry price, their gameplay
    gates, the income multiplier they confer, the appearance they give the Conflux, and the exact
    Wellsprings / Upgrades / Wings each Stage unlocks. PURE data (Color3 and Enum constructors only)
    so EvolutionService, Economy and the client HUD all read identical requirements.
    Owner: shared  |  Consumers: Economy, EvolutionService, StateSchema, Theme, HudController
]]

--[[ BALANCE MODEL -- how RequiredEssence was derived, and why it is reachable.

    Income is roughly `sum(count * BaseValue / Interval) * StageMultiplier * upgrades * prestige`.
    Wellspring tiers step ~7x per Stage (see DropperData) and the Stage multiplier adds ~1.4x on top,
    so raw income multiplies by roughly 10x per Stage. RequiredEssence therefore has to grow FASTER
    than 10x per Stage or every Attunement after the third would be instant. It grows 48x, 75x, 29x,
    23x across Stages 2->6, which lengthens the late game back out to a satisfying climb.

    Implied income curve at the moment each Stage is entered (greedy-purchase simulation, one player,
    prestige x1, no Affinity chosen):

        Stage 2   t =  4.3 min    ~7 Essence/s      RequiredEssence            250
        Stage 3   t = 18.2 min  ~617 Essence/s      RequiredEssence         12,000
        Stage 4   t = 26.4 min  ~14.7 K/s           RequiredEssence        900,000
        Stage 5   t = 34.3 min   ~136 K/s           RequiredEssence     26,000,000
        Stage 6   t = 51.9 min   ~1.28 M/s          RequiredEssence    600,000,000
        Transcend t = 54.7 min  ~12.5 M/s           RebirthData.RequiredLifetimeEssence

    Targets hit: Stage 2 in 3-5 min, Stage 6 in 45-75 min. At 4 rebirths the same run takes 22.8 min
    solo and 15.1 min for two 4-rebirth occupants (sanctum multiplier 3.0) -- about a third, as asked.

    RequiredLifetimeEssence is set to ~2.3x RequiredEssence at every Stage. It is deliberately a
    SOFT gate: it is satisfied naturally on the way to affording the Attunement, and only bites if a
    player tries to skip a tier by hoarding a windfall. RequiredDroppers does the same job in the
    other direction -- it forces the Sanctum to actually be built out, not just rich.
]]

export type Stage = {
	Index: number,
	Name: string,
	Title: string,
	Description: string,
	RequiredEssence: number, -- spent (debited) to attune INTO this Stage
	RequiredLifetimeEssence: number,
	RequiredDroppers: number, -- minimum total Wellsprings owned
	IncomeMultiplier: number,
	WalkSpeed: number,
	ConfluxSize: number,
	Color: Color3,
	Material: Enum.Material,
	UnlockedDroppers: { string },
	UnlockedUpgrades: { string },
	UnlockedSections: { string },
}

local EvolutionData = {}

-- Every id below is cross-checked against DropperData / UpgradeData / SectionData; the four modules
-- are authored together and must stay in lockstep.
EvolutionData.Stages = {
	{
		Index = 1, Name = "Mote", Title = "The First Spark",
		Description = "A single ember hangs in the empty Sanctum. It is barely aware, and it is entirely yours.",
		RequiredEssence = 0, RequiredLifetimeEssence = 0, RequiredDroppers = 0,
		IncomeMultiplier = 1.0, WalkSpeed = 16, ConfluxSize = 3,
		Color = Color3.fromRGB(255, 176, 96), Material = Enum.Material.Neon,
		UnlockedDroppers = { "ember_vent", "dew_font" },
		UnlockedUpgrades = { "ley_flow" },
		UnlockedSections = { "wing_core" },
	},
	{
		Index = 2, Name = "Wisp", Title = "Kindled Wisp",
		Description = "The spark has learned to drift. It follows whoever fed it last, and it wants the Forge lit.",
		RequiredEssence = 250, RequiredLifetimeEssence = 600, RequiredDroppers = 4,
		IncomeMultiplier = 1.4, WalkSpeed = 17, ConfluxSize = 5,
		Color = Color3.fromRGB(160, 220, 255), Material = Enum.Material.Neon,
		UnlockedDroppers = { "loam_seep", "gale_flue" },
		UnlockedUpgrades = { "font_resonance", "wellspring_cadence" },
		UnlockedSections = { "wing_ember_forge" },
	},
	{
		Index = 3, Name = "Sprite", Title = "Awakened Sprite",
		Description = "Aware enough to choose. At this Stage the Conflux accepts an Affinity and takes on its element for good.",
		RequiredEssence = 12000, RequiredLifetimeEssence = 28000, RequiredDroppers = 10,
		IncomeMultiplier = 2.0, WalkSpeed = 18, ConfluxSize = 7,
		Color = Color3.fromRGB(150, 255, 190), Material = Enum.Material.Neon,
		UnlockedDroppers = { "cinder_forge", "tidal_weir" },
		UnlockedUpgrades = { "mote_lattice", "conflux_attunement" },
		UnlockedSections = { "wing_tide_basin" },
	},
	{
		Index = 4, Name = "Elemental", Title = "Bound Elemental",
		Description = "The Conflux now holds a shape of its own and bends the Sanctum's rails to serve it.",
		RequiredEssence = 900000, RequiredLifetimeEssence = 2000000, RequiredDroppers = 18,
		IncomeMultiplier = 2.8, WalkSpeed = 20, ConfluxSize = 9.5,
		Color = Color3.fromRGB(200, 150, 255), Material = Enum.Material.Neon,
		UnlockedDroppers = { "quartz_bloom", "storm_coil" },
		UnlockedUpgrades = {},
		UnlockedSections = { "wing_terra_vault" },
	},
	{
		Index = 5, Name = "Warden", Title = "Sanctum Warden",
		Description = "It guards the pair who raised it. The Vault can hold a caged core now, and the Spire can be raised.",
		RequiredEssence = 26000000, RequiredLifetimeEssence = 60000000, RequiredDroppers = 26,
		IncomeMultiplier = 3.9, WalkSpeed = 22, ConfluxSize = 12,
		Color = Color3.fromRGB(255, 210, 110), Material = Enum.Material.Neon,
		UnlockedDroppers = { "magma_heart" },
		UnlockedUpgrades = { "primordial_echo" },
		UnlockedSections = { "wing_zephyr_spire" },
	},
	{
		Index = 6, Name = "Primordial", Title = "Primordial Ascendant",
		Description = "The final Stage. Bank enough Essence here and the pair may Transcend together, keeping the power and losing the Sanctum.",
		RequiredEssence = 600000000, RequiredLifetimeEssence = 1400000000, RequiredDroppers = 34,
		IncomeMultiplier = 5.5, WalkSpeed = 24, ConfluxSize = 15,
		Color = Color3.fromRGB(255, 255, 235), Material = Enum.Material.Neon,
		UnlockedDroppers = { "aether_spire" },
		UnlockedUpgrades = {},
		UnlockedSections = {},
	},
} :: { Stage }

EvolutionData.MaxStage = #EvolutionData.Stages

-- The Stage at which the Affinity modal opens. Placed at 3 (mid-run) so the choice is made with
-- enough information to feel considered, but early enough that its multipliers still matter.
EvolutionData.AffinityUnlockStage = 3

function EvolutionData.get(index: number): Stage?
	return EvolutionData.Stages[index]
end

function EvolutionData.next(index: number): Stage?
	return EvolutionData.Stages[index + 1]
end

return EvolutionData
