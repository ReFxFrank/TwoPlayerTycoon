--!strict
--[[
    RebirthData
    Constants and milestone badges for Transcendence. Transcending wipes the shared Sanctum PlotState
    but grants every consenting occupant a permanent, per-player prestige multiplier and any badges
    they have newly earned. PURE data -- no services, no Instances, and deliberately no requires, so
    that a corrupt sibling module can never stop the prestige gate from being evaluated.
    Owner: shared  |  Consumers: Economy, RebirthService, StateSchema, RebirthController, HudController
]]

--[[ BALANCE MODEL

    RequiredStage is 6 == EvolutionData.MaxStage (kept as a literal here purely to avoid a require
    from a data module; EvolutionData is the source of truth for the Stage list itself).

    RequiredLifetimeEssence is 3.5e9. Per the EvolutionData simulation, a first run enters Stage 6 at
    ~51.9 min with ~1.28 M Essence/s and climbs fast; banking the remaining Lifetime Essence takes
    another ~2.8 min, putting the first Transcendence at ~54.7 min -- inside the 45-75 min target.
    Note it is measured against LifetimeEssence (Essence credited SINCE the last Transcendence), not
    the wallet, so a player cannot stall at Stage 6 spending nothing and be locked out.

    MultiplierPerRebirth is 0.25, and Economy.getSanctumPrestigeMultiplier sums the occupants'
    bonuses rather than multiplying them: 1 + 0.25*Ra + 0.25*Rb. Summing is what makes a linked
    Sanctum meaningfully better than two solo ones without letting a single veteran trivialise the
    run for a brand-new partner.

    MaxTrackedRebirths caps the stored counter at 100 (a x26 multiplier). Past that the number stops
    being interesting and starts being a serialisation hazard, so it is clamped by sanitizeProfile.
]]

export type Badge = {
	Id: string,
	Name: string,
	Description: string,
	Rebirths: number, -- rebirth count at which the badge is awarded
	Color: Color3,
}

local RebirthData = {}

RebirthData.RequiredStage = 6 -- == EvolutionData.MaxStage
RebirthData.RequiredLifetimeEssence = 3500000000
RebirthData.MultiplierPerRebirth = 0.25 -- Economy.getPrestigeMultiplier(R) = 1 + 0.25 * R
RebirthData.MaxTrackedRebirths = 100

-- Ordered ascending by Rebirths; highestBadge relies on that ordering.
RebirthData.Badges = {
	{
		Id = "ember_initiate", Name = "Ember Initiate",
		Description = "Let the Conflux go once. The Sanctum remembers the heat it left behind.",
		Rebirths = 1, Color = Color3.fromRGB(255, 138, 64),
	},
	{
		Id = "wisp_walker", Name = "Wisp Walker",
		Description = "Three Transcendences. You know the road from spark to Primordial by heart.",
		Rebirths = 3, Color = Color3.fromRGB(160, 220, 255),
	},
	{
		Id = "sprite_sovereign", Name = "Sprite Sovereign",
		Description = "Five Sanctums raised and released. Affinities bend to you now.",
		Rebirths = 5, Color = Color3.fromRGB(150, 255, 190),
	},
	{
		Id = "elemental_adept", Name = "Elemental Adept",
		Description = "Ten cycles. Any partner who links with you inherits a frightening head start.",
		Rebirths = 10, Color = Color3.fromRGB(200, 150, 255),
	},
	{
		Id = "warden_eternal", Name = "Warden Eternal",
		Description = "Twenty-five. The Conflux answers before you finish asking.",
		Rebirths = 25, Color = Color3.fromRGB(255, 210, 110),
	},
	{
		Id = "primordial_ascendant", Name = "Primordial Ascendant",
		Description = "Fifty Transcendences. There is nothing left in the Sanctum that you have not already been.",
		Rebirths = 50, Color = Color3.fromRGB(255, 255, 235),
	},
} :: { Badge }

table.sort(RebirthData.Badges, function(a: Badge, b: Badge): boolean
	return a.Rebirths < b.Rebirths
end)

RebirthData.ById = {} :: { [string]: Badge }
for _, badge in ipairs(RebirthData.Badges) do
	RebirthData.ById[badge.Id] = badge
end

-- Returns the FULL earned set rather than only the newest badge, so RebirthService can simply
-- overwrite Prestige.Badges and self-heal a profile that missed an award through a failed save.
function RebirthData.badgesFor(rebirths: number): { [string]: boolean }
	local out: { [string]: boolean } = {}
	local count = if type(rebirths) == "number" and rebirths == rebirths then rebirths else 0
	for _, badge in ipairs(RebirthData.Badges) do
		if count >= badge.Rebirths then
			out[badge.Id] = true
		end
	end
	return out
end

function RebirthData.highestBadge(rebirths: number): Badge?
	local best: Badge? = nil
	for _, badge in ipairs(RebirthData.Badges) do
		if rebirths >= badge.Rebirths then
			best = badge
		end
	end
	return best
end

-- Human text for the Transcend button tooltip. Built locally (no Format require) to keep this module
-- dependency-free; the abbreviation only ever has to handle this one constant.
function RebirthData.requirementText(): string
	local amount = RebirthData.RequiredLifetimeEssence
	local short: string
	if amount >= 1e9 then
		short = string.format("%.1fB", amount / 1e9)
	elseif amount >= 1e6 then
		short = string.format("%.1fM", amount / 1e6)
	else
		short = tostring(amount)
	end
	return string.format(
		"Reach Stage %d and bank %s Essence since your last Transcendence.",
		RebirthData.RequiredStage,
		short
	)
end

return RebirthData
