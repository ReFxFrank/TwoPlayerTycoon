--!strict
--[[
    PlotLayout
    Pure geometry for a Sanctum. It answers every "where does this go?" question exactly once: where
    each Sanctum sits in the world, where a Wing's floor slab lands, where purchase pads line up,
    where the Conflux and its Font float, which waypoints a Mote rides from a Wellspring nozzle to
    the Font, and where players spawn / stand to link. No services, no Instances -- every function is
    a pure function of its arguments plus static config, so PlotBuilder, MoteSystem and the headless
    test harness all agree on one map.
    Owner: shared  |  Consumers: PlotBuilder, MoteSystem, PlotService, PurchaseService
]]

--[[ SANCTUM LAYOUT

    WORLD: Sanctums are a single row marching along +X from GameConfig.Plot.Origin, one every
    GameConfig.Plot.Spacing studs. Spacing (240) exceeds SanctumSize.X (200), so neighbouring
    Sanctums never touch and a stray Mote can never visit the wrong plot.

        Origin        +Spacing       +2*Spacing              ->  +X
          #1            #2             #3            #4  ...
        [======]      [======]       [======]      [======]

    LOCAL SPACE of one Sanctum (200 x 200; the origin CFrame sits at the centre of the floor,
    +X right, +Z "south", -Z "north"). Wing slabs come from SectionData.Offset/Size:

                                  -Z   (north)
        +-----------------------------------------------------------+  z = -100
        |             [ wing_ember_forge   80 x 50 ]                 |
        |              o  o  o  o  o  o    pad row 0, z = -51        |
        +-----------------------------------------------------------+  z = -45
        |                                                           |
        | [wing_    ]  o  o  o  o  o  o    core pads, z = -28        |
        | [zephyr_  ]                                    [wing_     ]
   -X   | [spire    ]         ( ( (  C O N F L U X  ) ) )  [tide_   ]  +X
        |  p            \___ y = 20 ___/                   [basin   ]
        |  p                  ( CONFLUX FONT )  (0, 3, 0)      p     |
        |  p                                                   p     |
        |  x = -51                                        x = +51    |
        |                    S1        S2      spawn slots, z = +30  |
        +-----------------------------------------------------------+  z = +45
        |              o  o  o  o  o  o    pad row 0, z = +51        |
        |             [ wing_terra_vault   80 x 50 ]                 |
        +-----------------------------------------------------------+  z = +100
                                  +Z   (south)

    PADS: every Wing gets one pad line inset just behind its edge facing the middle, pads spaced
    PAD_SPACING apart along that edge and wrapping into extra rows that grow AWAY from the middle
    (into the Wing's own floor). The core is the exception -- the Font and the Conflux own its
    centre, so its rows grow inward from the north edge. Because every line sits on a different
    plane (|51| for the four Wings, -28 for the core) pads can never overlap between Wings.

    RAILS: five waypoints -- nozzle -> rail deck -> trunk corner -> font approach -> Font. The pad's
    lateral position, a per-order rail lane height and a per-order fan offset keep two rails from
    ever being the same line, but every path ends on the Font.
]]

local GameConfig = require(script.Parent.GameConfig)
local SectionData = require(script.Parent.SectionData)

type Section = SectionData.Section

local PlotLayout = {}

-- Footprint of one Sanctum. Y is generous head-room for the Conflux, not a solid volume.
PlotLayout.SanctumSize = Vector3.new(200, 60, 200)

-- Vertical stack (studs above the Wing floor slabs, which sit at local Y = 0).
local PAD_HEIGHT = 1.5 -- centre of a purchase pad; the slab top is at 0.5
local NOZZLE_HEIGHT = 7 -- where a Wellspring's nozzle sits above its pad
local MOTE_SPAWN_DROP = 1 -- Motes appear this far UNDER the nozzle, so they read as "condensed"
local RAIL_HEIGHT = 5 -- height of rail lane 0
local FONT_HEIGHT = 3 -- centre of the Conflux Font
local CONFLUX_HEIGHT = 20 -- the Conflux floats here, well clear of players and rails
local SPAWN_HEIGHT = 4 -- character spawn height (half a Humanoid clears the slab)

-- Pad line packing.
local PAD_SPACING = 12 -- studs between pad centres along a line (spec: 12)
local PAD_ROW_SPACING = 12 -- studs between wrapped rows
local PAD_END_MARGIN = 8 -- keep pads this far from the ends of a Wing so they read as "on" it
local WING_PAD_INSET = 6 -- how far behind a Wing's inner edge its pad line sits
local CORE_PAD_INSET = 12 -- how far inside the core's north edge its pad line sits

-- Rail shaping.
local RAIL_LANES = 3 -- number of stacked rail decks; adjacent pads use different lanes
local RAIL_LANE_STEP = 1.1 -- vertical gap between lanes, so parallel rails never z-fight
local FONT_APPROACH = 14 -- radius of the ring where every rail lines up on the Font
local APPROACH_FRACTION = 0.6 -- short rail runs shrink their approach ring instead of overshooting
local RAIL_FAN = 3 -- lateral spread of the approach points, so rails stay distinguishable

-- Player furniture, placed on the open (south) half of the core so pads never collide with it.
local SPAWN_Z = 30
local SPAWN_X = 9 -- half the gap between the two slot spawns
local SPAWN_PAIR_STEP = 6 -- extra spread if SlotsPerSanctum is ever raised above 2
local LINK_PAD_Z = 22 -- link pads sit between the spawns and the Font

-- Identity rotation looks down -Z, so a yaw of atan2(-dx, -dz) aims the CFrame at (dx, dz).
-- WHY orient at all: pads must face the player walking in from the middle, and Mote waypoints must
-- face along travel so MoteSystem can CFrame-lerp without computing its own headings.
local function facing(position: Vector3, target: Vector3): CFrame
	local dx = target.X - position.X
	local dz = target.Z - position.Z
	if dx * dx + dz * dz < 1e-6 then
		return CFrame.new(position)
	end
	return CFrame.new(position) * CFrame.Angles(0, math.atan2(-dx, -dz), 0)
end

-- How many pads fit on one row of a Wing edge of `extent` studs.
local function perRowFor(extent: number): number
	return math.max(1, math.floor((extent - 2 * PAD_END_MARGIN) / PAD_SPACING) + 1)
end

-- A Wing's pad line, expressed in Sanctum-local space.
--   Base   = centre of row 0 (the pad at column index (PerRow-1)/2 sits exactly here)
--   Run    = unit axis pads march along
--   Row    = unit axis wrapped rows grow along
--   Inward = unit axis pointing from the line toward the Sanctum centre (where the Font is)
type PadLine = {
	Base: Vector3,
	Run: Vector3,
	Row: Vector3,
	Inward: Vector3,
	PerRow: number,
}

local function padLine(section: Section): PadLine
	local offset = section.Offset
	local halfX = section.Size.X * 0.5
	local halfZ = section.Size.Z * 0.5

	if section.Id == SectionData.Base then
		-- The core's middle is spoken for (Font + Conflux + spawns), so its pads hug the north edge
		-- and extra rows step INWARD -- there is no outward space to grow into.
		return {
			Base = Vector3.new(offset.X, PAD_HEIGHT, offset.Z - halfZ + CORE_PAD_INSET),
			Run = Vector3.new(1, 0, 0),
			Row = Vector3.new(0, 0, 1),
			Inward = Vector3.new(0, 0, 1),
			PerRow = perRowFor(section.Size.X),
		}
	end

	if math.abs(offset.X) >= math.abs(offset.Z) then
		-- East/west Wing: the edge facing the middle is a plane of constant X, so pads run along Z.
		local sign = if offset.X >= 0 then 1 else -1
		local x = offset.X - sign * halfX + sign * WING_PAD_INSET
		return {
			Base = Vector3.new(x, PAD_HEIGHT, offset.Z),
			Run = Vector3.new(0, 0, 1),
			Row = Vector3.new(sign, 0, 0),
			Inward = Vector3.new(-sign, 0, 0),
			PerRow = perRowFor(section.Size.Z),
		}
	end

	-- North/south Wing: the inner edge is a plane of constant Z, so pads run along X.
	local sign = if offset.Z >= 0 then 1 else -1
	local z = offset.Z - sign * halfZ + sign * WING_PAD_INSET
	return {
		Base = Vector3.new(offset.X, PAD_HEIGHT, z),
		Run = Vector3.new(1, 0, 0),
		Row = Vector3.new(0, 0, sign),
		Inward = Vector3.new(0, 0, -sign),
		PerRow = perRowFor(section.Size.X),
	}
end

-- Local-space centre of the pad at `order` (1-based) on `section`.
-- NOTE: `order` is a PER-WING pad index. Wellsprings, Upgrades and Wing-unlock pads share one Wing,
-- so PurchaseService must hand out one running index per Wing rather than reusing DropperData.Order
-- (whose numbering restarts per catalogue and would stack two pads on the same stud).
local function padPosition(section: Section, order: number): Vector3
	local line = padLine(section)
	local index = math.max(0, math.floor(order) - 1)
	local column = index % line.PerRow
	local row = math.floor(index / line.PerRow)
	local along = column * PAD_SPACING - (line.PerRow - 1) * PAD_SPACING * 0.5
	local depth = row * PAD_ROW_SPACING
	return Vector3.new(
		line.Base.X + line.Run.X * along + line.Row.X * depth,
		line.Base.Y,
		line.Base.Z + line.Run.Z * along + line.Row.Z * depth
	)
end

function PlotLayout.sanctumOrigin(plotIndex: number): CFrame
	-- One row along +X: trivially collision-free, keeps plot N's world position derivable from N
	-- alone, and makes the "which Sanctum is that?" question answerable at a glance in Studio.
	local index = math.max(1, math.floor(plotIndex))
	local base = GameConfig.Plot.Origin
	return CFrame.new(base + Vector3.new((index - 1) * GameConfig.Plot.Spacing, 0, 0))
end

function PlotLayout.sectionCFrame(origin: CFrame, section: Section): CFrame
	-- SectionData.Offset is already Sanctum-local, so the Wing slab is just a local translation.
	return origin * CFrame.new(section.Offset)
end

function PlotLayout.padCFrame(origin: CFrame, section: Section, order: number): CFrame
	local position = padPosition(section, order)
	-- Pads face the middle of the Sanctum, i.e. the player approaching from the Conflux.
	return origin * facing(position, Vector3.new(0, position.Y, 0))
end

function PlotLayout.confluxCFrame(origin: CFrame): CFrame
	return origin * CFrame.new(0, CONFLUX_HEIGHT, 0)
end

function PlotLayout.fontCFrame(origin: CFrame): CFrame
	return origin * CFrame.new(0, FONT_HEIGHT, 0)
end

function PlotLayout.railPath(origin: CFrame, section: Section, order: number): { CFrame }
	local line = padLine(section)
	local pad = padPosition(section, order)
	local index = math.max(0, math.floor(order) - 1)

	-- Per-order lane height and fan offset: two Wellsprings on the same Wing must not share a rail
	-- line (they would z-fight and their Motes would visually collide), but both must still land on
	-- the Font. Lane/fan cycle every RAIL_LANES pads, and the pad's own lateral position separates
	-- the rest, so no two pads on a Wing produce the same path.
	local railY = RAIL_HEIGHT + (index % RAIL_LANES) * RAIL_LANE_STEP
	local fan = ((index % RAIL_LANES) - 1) * RAIL_FAN

	-- Distance from the Sanctum centre out to the pad (and to the rail deck entry just inside it),
	-- measured along the inward axis.
	local outward = -(pad.X * line.Inward.X + pad.Z * line.Inward.Z)
	local entry = math.max(1, outward - WING_PAD_INSET)
	-- WHY derive the ring radii from `entry` instead of using fixed constants: the radius must
	-- decrease monotonically along the path or a Mote would visibly back up. A short run (the core's
	-- inner pad rows, only ~10 studs out) then behaves exactly like a long one from a far Wing.
	local approach = math.min(FONT_APPROACH, entry * APPROACH_FRACTION)
	local trunk = (entry + approach) * 0.5
	local lateral = pad.X * line.Run.X + pad.Z * line.Run.Z

	local function ringPoint(radius: number, side: number, height: number): Vector3
		-- centre + (-Inward) * radius + Run * side
		return Vector3.new(
			-line.Inward.X * radius + line.Run.X * side,
			height,
			-line.Inward.Z * radius + line.Run.Z * side
		)
	end

	local points = {
		Vector3.new(pad.X, NOZZLE_HEIGHT - MOTE_SPAWN_DROP, pad.Z), -- 1: born under the nozzle
		Vector3.new(
			pad.X + line.Inward.X * WING_PAD_INSET,
			railY,
			pad.Z + line.Inward.Z * WING_PAD_INSET
		), -- 2: lands on its rail deck
		ringPoint(trunk, lateral, railY), -- 3: trunk corner, still in the pad's own lane
		ringPoint(approach, fan, railY), -- 4: approach ring, fanned so lanes stay readable
		Vector3.new(0, FONT_HEIGHT, 0), -- 5: swallowed by the Conflux Font
	}

	-- Orient each waypoint along the direction of travel; the last inherits the second-to-last's
	-- heading because there is nothing after it to look at.
	local path: { CFrame } = table.create(#points)
	for i, point in ipairs(points) do
		local target = points[i + 1]
		if target ~= nil then
			path[i] = origin * facing(point, target)
		else
			path[i] = origin * facing(point, point + (point - points[i - 1]))
		end
	end
	return path
end

function PlotLayout.spawnSlotCFrame(origin: CFrame, slot: number): CFrame
	-- Slots alternate left/right of the centre line; pairs beyond the first step further out, so a
	-- future GameConfig.Plot.SlotsPerSanctum > 2 still lands everyone on the core floor.
	local index = math.max(1, math.floor(slot))
	local pair = math.floor((index - 1) / 2)
	local side = if index % 2 == 1 then -1 else 1
	local position = Vector3.new(side * (SPAWN_X + pair * SPAWN_PAIR_STEP), SPAWN_HEIGHT, SPAWN_Z)
	-- Face the Conflux: the first thing a player sees on spawn is the thing they are here to grow.
	return origin * facing(position, Vector3.new(0, SPAWN_HEIGHT, 0))
end

function PlotLayout.linkPadCFrame(origin: CFrame, slot: number): CFrame
	local index = math.max(1, math.floor(slot))
	local pair = math.floor((index - 1) / 2)
	local side = if index % 2 == 1 then -1 else 1
	local position = Vector3.new(side * (SPAWN_X + pair * SPAWN_PAIR_STEP), PAD_HEIGHT, LINK_PAD_Z)
	return origin * facing(position, Vector3.new(0, PAD_HEIGHT, 0))
end

return PlotLayout
