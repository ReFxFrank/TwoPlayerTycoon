--!strict
--[[
    Theme
    The visual identity of Sanctum of Embers in one place: the dark-slate + warm-ember UI palette,
    a colour/material set per Affinity, a colour/size/material set per Attunement Stage, and the
    blend rule that decides what the Conflux actually looks like right now.
    Pure data + one pure function: only Color3/Enum constructors, no services, no Instances.
    Owner: shared  |  Consumers: UiBuilder, HudController, PromptController, EvolutionFxController,
                                 PlotBuilder, EvolutionService
]]

export type AffinityTheme = {
	Primary: Color3,
	Secondary: Color3,
	Material: Enum.Material,
}

export type StageTheme = {
	Color: Color3,
	Size: number,
	Material: Enum.Material,
}

export type ConfluxAppearance = {
	Color: Color3,
	Size: number,
	Material: Enum.Material,
}

type Rgb = { number }

-- WHY raw RGB triples are kept alongside the Color3 values: getConfluxAppearance blends a stage
-- colour with an affinity colour, and doing that on plain numbers avoids reading Color3 components
-- (keeping this module to constructors only, exactly as the purity rule requires).
local STAGE_DEFS: { { Rgb: Rgb, Size: number, Material: Enum.Material } } = {
	-- 1 Mote: a timid spark. Small, pale, warm.
	{ Rgb = { 255, 196, 120 }, Size = 6.0, Material = Enum.Material.Neon },
	-- 2 Wisp: brighter and hungrier.
	{ Rgb = { 255, 158, 84 }, Size = 7.5, Material = Enum.Material.Neon },
	-- 3 Sprite: the stage where an Affinity is chosen, so the base colour is a strong ember.
	{ Rgb = { 255, 122, 58 }, Size = 9.0, Material = Enum.Material.Glass },
	-- 4 Elemental: the ember starts burning through into raw energy.
	{ Rgb = { 255, 92, 96 }, Size = 11.0, Material = Enum.Material.Neon },
	-- 5 Warden: arcane violet, visibly "not fire any more".
	{ Rgb = { 206, 120, 255 }, Size = 13.0, Material = Enum.Material.ForceField },
	-- 6 Primordial: near-white starlight; the transcendence-ready look.
	{ Rgb = { 255, 244, 222 }, Size = 16.0, Material = Enum.Material.Neon },
}

local AFFINITY_DEFS: { [string]: { Primary: Rgb, Secondary: Rgb, Material: Enum.Material } } = {
	-- Ember: aggressive orange, the "default" flavour of the sanctum.
	ember = { Primary = { 255, 112, 40 }, Secondary = { 122, 30, 12 }, Material = Enum.Material.Neon },
	-- Tide: deep water blue, glassy so it reads as liquid rather than flame.
	tide = { Primary = { 58, 168, 255 }, Secondary = { 14, 58, 122 }, Material = Enum.Material.Glass },
	-- Terra: mossy green over stone; the dense, heavy affinity.
	terra = { Primary = { 128, 198, 90 }, Secondary = { 58, 92, 44 }, Material = Enum.Material.Slate },
	-- Zephyr: pale cyan mist, ForceField so it looks barely-there and fast.
	zephyr = { Primary = { 168, 240, 236 }, Secondary = { 60, 120, 132 }, Material = Enum.Material.ForceField },
}

-- How strongly the chosen Affinity tints the Conflux. Below 0.5 on purpose: the stage progression
-- must still read at a glance, the affinity is a flavour on top of it.
local AFFINITY_TINT = 0.45

local function lerpChannel(a: number, b: number, alpha: number): number
	local blended = a + (b - a) * alpha
	return math.clamp(math.floor(blended + 0.5), 0, 255)
end

local Theme = {}

--[[ UI palette: dark slate panels so the glowing sanctum stays the brightest thing on screen, with
     a single warm ember accent used for anything actionable. ]]
Theme.Ui = {
	Background = Color3.fromRGB(12, 14, 20), -- behind everything / modal scrim base
	Panel = Color3.fromRGB(24, 28, 38), -- HUD + modal panel fill
	Accent = Color3.fromRGB(255, 138, 61), -- ember accent: buttons, progress fill, highlights
	Text = Color3.fromRGB(236, 240, 248), -- primary label colour
	Muted = Color3.fromRGB(138, 148, 168), -- secondary/disabled label colour
	Positive = Color3.fromRGB(92, 214, 137), -- success toasts, affordable prompts
	Negative = Color3.fromRGB(232, 86, 86), -- errors, unaffordable prompts
	Warning = Color3.fromRGB(245, 196, 84), -- vote timers, "are you sure" states
	Stroke = Color3.fromRGB(52, 60, 78), -- UIStroke colour for panels (extra, non-spec)
	Overlay = Color3.fromRGB(6, 7, 11), -- full-screen modal dim (extra, non-spec)
}

Theme.Affinity = {} :: { [string]: AffinityTheme }
for id, def in pairs(AFFINITY_DEFS) do
	Theme.Affinity[id] = {
		Primary = Color3.fromRGB(def.Primary[1], def.Primary[2], def.Primary[3]),
		Secondary = Color3.fromRGB(def.Secondary[1], def.Secondary[2], def.Secondary[3]),
		Material = def.Material,
	}
end

Theme.Stage = {} :: { StageTheme }
for index, def in ipairs(STAGE_DEFS) do
	Theme.Stage[index] = {
		Color = Color3.fromRGB(def.Rgb[1], def.Rgb[2], def.Rgb[3]),
		Size = def.Size,
		Material = def.Material,
	}
end

--[[ The one place that decides how the Conflux looks. Returns a FRESH table each call so callers
     (PlotBuilder / EvolutionService) can hand it around without risk of mutating the palette.
     Out-of-range or nan stages clamp to a valid stage; an unknown affinity id is treated as "none"
     rather than erroring, because it can arrive from an old save. ]]
function Theme.getConfluxAppearance(stage: number, affinity: string?): ConfluxAppearance
	local index = 1
	if type(stage) == "number" and stage == stage then
		index = math.clamp(math.floor(stage), 1, #STAGE_DEFS)
	end

	local stageDef = STAGE_DEFS[index]
	local stageTheme = Theme.Stage[index]

	local affinityDef = if type(affinity) == "string" then AFFINITY_DEFS[affinity] else nil
	if affinityDef == nil then
		return {
			Color = stageTheme.Color,
			Size = stageTheme.Size,
			Material = stageTheme.Material,
		}
	end

	local base, tint = stageDef.Rgb, affinityDef.Primary
	return {
		Color = Color3.fromRGB(
			lerpChannel(base[1], tint[1], AFFINITY_TINT),
			lerpChannel(base[2], tint[2], AFFINITY_TINT),
			lerpChannel(base[3], tint[3], AFFINITY_TINT)
		),
		Size = stageTheme.Size,
		-- The affinity owns the material once chosen: it is the clearest non-colour signal of which
		-- element a sanctum committed to.
		Material = affinityDef.Material,
	}
end

-- Freeze the palette tables (see GameConfig for the same reasoning): a stray write here would
-- desync every UI element built after it.
-- table.freeze ERRORS on an already-frozen table, and shared sub-tables (or a cycle) would hit the
-- same table twice, so isfrozen doubles as the visited-set here.
local function deepFreeze(t: { [any]: any }): { [any]: any }
	if table.isfrozen(t) then
		return t
	end
	table.freeze(t)
	for _, value in pairs(t) do
		if type(value) == "table" then
			deepFreeze(value :: { [any]: any })
		end
	end
	return t
end

deepFreeze(Theme.Ui)
deepFreeze(Theme.Affinity :: any)
deepFreeze(Theme.Stage :: any)
table.freeze(Theme)

return Theme
