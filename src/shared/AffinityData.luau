--!strict
--[[
    AffinityData
    The four elemental Affinities a Sanctum's Conflux can bind to at EvolutionData.AffinityUnlockStage.
    The choice is permanent for the run (it is cleared only by Transcendence) so each entry is a
    genuine trade-off rather than a strict upgrade. PURE data -- Color3 only, no services.
    Owner: shared  |  Consumers: Economy, EvolutionService, Theme, AffinityController, HudController
]]

--[[ BALANCE MODEL

    Three of the five fields feed income multiplicatively through Economy:
        effective income ~ IncomeMultiplier * SpawnRateMultiplier * MoteValueMultiplier
    The other two are texture: RailSpeedMultiplier changes how long a Mote spends in transit (it
    smooths income and keeps the live-Mote cap from clipping during a Stage spike) and WalkSpeedBonus
    is pure comfort for a 200x200 stud Sanctum.

    Income products, kept inside a 1% band so no pick is objectively correct:
        ember   1.22 * 1.00 * 1.00 = 1.2200
        tide    1.00 * 1.28 * 0.95 = 1.2160
        terra   1.00 * 0.88 * 1.38 = 1.2144
        zephyr  1.06 * 1.12 * 1.02 = 1.2109

    The tie is broken by feel, not by numbers:
      ember  - flat and boring on purpose; the safe pick and the one that scales best with prestige.
      tide   - many small Motes: lively rails, but it hits the Mote cap first, so it wants mote_lattice.
      terra  - few enormous Motes: slow, chunky, forgiving of a low cap, punished by a slow rail.
      zephyr - the mobility pick; the weakest raw income is repaid by the fastest rails (least income
               in flight at any moment) and by far the best traversal speed for a two-player Sanctum.
]]

export type Affinity = {
	Id: string,
	Name: string,
	Description: string,
	IncomeMultiplier: number,
	SpawnRateMultiplier: number, -- >1 shortens the Wellspring interval
	MoteValueMultiplier: number,
	RailSpeedMultiplier: number, -- >1 shortens Ley Rail travel time
	WalkSpeedBonus: number, -- added studs/s on top of the Stage WalkSpeed
	Color: Color3,
	Order: number,
}

local AffinityData = {}

AffinityData.List = {
	{
		Id = "ember", Name = "Ember",
		Description = "Steady heat. A flat lift to every Essence the Sanctum earns, at the cost of slightly sluggish rails.",
		IncomeMultiplier = 1.22, SpawnRateMultiplier = 1.00, MoteValueMultiplier = 1.00,
		RailSpeedMultiplier = 0.95, WalkSpeedBonus = 0,
		Color = Color3.fromRGB(255, 118, 46), Order = 1,
	},
	{
		Id = "tide", Name = "Tide",
		Description = "Relentless rhythm. Wellsprings condense far more often, though each Mote carries a little less.",
		IncomeMultiplier = 1.00, SpawnRateMultiplier = 1.28, MoteValueMultiplier = 0.95,
		RailSpeedMultiplier = 1.00, WalkSpeedBonus = 1,
		Color = Color3.fromRGB(58, 158, 255), Order = 2,
	},
	{
		Id = "terra", Name = "Terra",
		Description = "Patient weight. Rare, enormous Motes that shrug off a crowded rail -- but the Sanctum breathes slowly.",
		IncomeMultiplier = 1.00, SpawnRateMultiplier = 0.88, MoteValueMultiplier = 1.38,
		RailSpeedMultiplier = 0.92, WalkSpeedBonus = 2,
		Color = Color3.fromRGB(140, 205, 92), Order = 3,
	},
	{
		Id = "zephyr", Name = "Zephyr",
		Description = "Nothing stands still. The quickest rails and the quickest feet, with only a modest edge on raw yield.",
		IncomeMultiplier = 1.06, SpawnRateMultiplier = 1.12, MoteValueMultiplier = 1.02,
		RailSpeedMultiplier = 1.35, WalkSpeedBonus = 6,
		Color = Color3.fromRGB(196, 236, 255), Order = 4,
	},
} :: { Affinity }

table.sort(AffinityData.List, function(a: Affinity, b: Affinity): boolean
	return a.Order < b.Order
end)

AffinityData.ById = {} :: { [string]: Affinity }
for _, def in ipairs(AffinityData.List) do
	AffinityData.ById[def.Id] = def
end

function AffinityData.get(id: string): Affinity?
	return AffinityData.ById[id]
end

-- Guard for the ChooseAffinity remote: the client sends a raw string, so the type check lives here
-- rather than in the caller. Anything that is not one of the four literal ids is rejected.
function AffinityData.isValid(id: any): boolean
	return type(id) == "string" and AffinityData.ById[id] ~= nil
end

return AffinityData
