--!strict
--[[
    SectionData
    Static catalogue of the Sanctum's Wings. A Wing is both an economic gate (it hosts the pads for a
    tier of Wellsprings and Upgrades) and a piece of geometry (PlotBuilder parents its floor at
    Offset and sizes it to Size, relative to the Sanctum origin). PURE data: Vector3 constructors
    only, no services and no Instances.
    Owner: shared  |  Consumers: PlotLayout, PlotBuilder, Economy, PurchaseService, EvolutionService
]]

--[[ GEOMETRY

    The Sanctum footprint is 200 x 200 studs, i.e. local X and Z both span -100..100. wing_core sits
    dead centre at (0, 0, 0) and the four purchasable Wings fan out on the cardinals, leaving a 5
    stud gap between every pair of slabs so PlotBuilder can drop a visible bridge/threshold in the
    seam and so no two floor parts ever z-fight.

        Wing               centre      half-extents     occupies X          occupies Z
        wing_core          (  0, 0)    40 x 40          -40 .. 40           -40 .. 40
        wing_ember_forge   (  0,-70)   40 x 25          -40 .. 40           -95 .. -45
        wing_tide_basin    ( 70, 0)    25 x 40           45 .. 95           -40 .. 40
        wing_terra_vault   (  0, 70)   40 x 25          -40 .. 40            45 .. 95
        wing_zephyr_spire  (-70, 0)    25 x 40          -95 .. -45          -40 .. 40

    No two ranges intersect in both axes, so there is no overlap; every slab stays inside +/-100.
    Y is always 0 -- Wings are floors, PlotLayout lifts pads and rails above them.

    COST: each Wing is priced just under the Attunement that unlocks the NEXT Stage, so the natural
    play pattern is "attune -> buy the new Wing -> fill it with Wellsprings -> attune again".
]]

export type Section = {
	Id: string,
	Name: string,
	Description: string,
	Cost: number,
	RequiredStage: number,
	RequiredSection: string?, -- prerequisite Wing; nil only for the base Wing
	Order: number,
	Offset: Vector3, -- centre of the floor slab, relative to the Sanctum origin
	Size: Vector3, -- full extents of the floor slab (Y is slab thickness)
}

local SectionData = {}

-- The Wing every Sanctum owns from the moment it is claimed. Never purchasable, never lockable.
SectionData.Base = "wing_core"

SectionData.List = {
	{
		Id = "wing_core", Name = "Conflux Core",
		Description = "The heart of the Sanctum. The Conflux floats here above the Font, and the first Wellsprings ring it.",
		Cost = 0, RequiredStage = 1, RequiredSection = nil, Order = 1,
		Offset = Vector3.new(0, 0, 0), Size = Vector3.new(80, 1, 80),
	},
	{
		Id = "wing_ember_forge", Name = "Ember Forge",
		Description = "A vaulted furnace hall to the north. Heat-hungry Wellsprings only work once the Forge is lit.",
		Cost = 2500, RequiredStage = 2, RequiredSection = "wing_core", Order = 2,
		Offset = Vector3.new(0, 0, -70), Size = Vector3.new(80, 1, 50),
	},
	{
		Id = "wing_tide_basin", Name = "Tide Basin",
		Description = "A sunken eastern reservoir. Its standing wave never settles, and the Weir taps that restlessness.",
		Cost = 45000, RequiredStage = 3, RequiredSection = "wing_ember_forge", Order = 3,
		Offset = Vector3.new(70, 0, 0), Size = Vector3.new(50, 1, 80),
	},
	{
		Id = "wing_terra_vault", Name = "Terra Vault",
		Description = "A southern strongroom cut into bedrock. Heavy enough to cage a storm, or a piece of the world's core.",
		Cost = 700000, RequiredStage = 4, RequiredSection = "wing_tide_basin", Order = 4,
		Offset = Vector3.new(0, 0, 70), Size = Vector3.new(80, 1, 50),
	},
	{
		Id = "wing_zephyr_spire", Name = "Zephyr Spire",
		Description = "A western needle that pierces the veil. The last Wing, and the only place the Aether can be reached.",
		Cost = 15000000, RequiredStage = 5, RequiredSection = "wing_terra_vault", Order = 5,
		Offset = Vector3.new(-70, 0, 0), Size = Vector3.new(50, 1, 80),
	},
} :: { Section }

table.sort(SectionData.List, function(a: Section, b: Section): boolean
	return a.Order < b.Order
end)

SectionData.ById = {} :: { [string]: Section }
for _, def in ipairs(SectionData.List) do
	SectionData.ById[def.Id] = def
end

function SectionData.get(id: string): Section?
	return SectionData.ById[id]
end

return SectionData
