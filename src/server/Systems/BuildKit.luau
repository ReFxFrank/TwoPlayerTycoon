--!strict
--[[
    BuildKit
    The construction primitives PlotBuilder assembles a Sanctum from: one Part factory that cannot
    forget to anchor, one billboard-sign factory, one folder helper, and the shared geometry and
    material constants they use.

    Split out of PlotBuilder purely to keep both files inside the project's 300-line budget. It has
    no game knowledge -- nothing here reads a data table or a PlotState.
    Owner: server  |  Consumers: PlotBuilder
]]

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local Theme = require(Modules:WaitForChild("Theme"))

local BuildKit = {}

type PartProps = { Name: string, Size: Vector3, CFrame: CFrame, Color: Color3, Parent: Instance,
	Material: Enum.Material, Transparency: number?, CanCollide: boolean? }

-- PlotLayout owns every POSITION; these are the extents that fill the space it reserves. Its pad
-- line spacing is 12 studs so a 6-stud pad leaves a walkway, and a 2-tall pad centred on its
-- PAD_HEIGHT of 1.5 rests on the 0.5 slab top rather than hovering.
local PAD_SIZE = Vector3.new(6, 2, 6)
local FONT_SIZE, MARKER_SIZE = Vector3.new(12, 6, 12), Vector3.new(8, 0.2, 8)
local MARKER_DROP = -3.4 -- spawn CFrames float at head clearance; the decal belongs on the floor
local MAX_CONFLUX_SIZE = 60 -- keeps a corrupt stage entry from producing a Sanctum-filling cube
local MAX_LIGHT_RANGE = 60 -- PointLight.Range is hard-capped at 60 by the engine
local RAIL_WIDTH, RAIL_THICKNESS, MIN_RAIL_LENGTH = 2.2, 0.4, 0.5 -- below MIN a segment is degenerate

-- Theme has materials for the Conflux and the Affinities but none for static architecture, so a
-- Sanctum's structural materials are named once here. NEON covers rails and the Font: both glow, so
-- they read as live ley-work rather than as more masonry.
local FLOOR_MATERIAL, PAD_MATERIAL = Enum.Material.Slate, Enum.Material.Metal
local NEON, MARKER_MATERIAL = Enum.Material.Neon, Enum.Material.ForceField

local function newFolder(name: string, parent: Instance): Folder
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function makePart(props: PartProps): Part
	local part = Instance.new("Part")
	part.Name = props.Name
	part.Size = props.Size
	part.CFrame = props.CFrame
	part.Color = props.Color
	part.Material = props.Material
	part.Anchored = true -- correctness, not optimisation: an unanchored slab falls out of the world
	part.CanCollide = if props.CanCollide == nil then true else props.CanCollide
	part.Transparency = props.Transparency or 0
	part.Parent = props.Parent
	return part
end

-- A blank billboard label. PurchaseService writes pad wording; the Font supplies its own up front.
local function makeSign(adornee: Instance, text: string, height: number): TextLabel
	local gui = Instance.new("BillboardGui")
	gui.Name = "Sign"
	gui.Size = UDim2.new(0, 220, 0, 70)
	gui.StudsOffset = Vector3.new(0, height, 0)
	gui.MaxDistance = 90 -- 6 Sanctums x ~25 signs = 150 billboards; cull the already-illegible ones
	gui.Parent = adornee
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.TextColor3 = Theme.Ui.Text
	label.TextStrokeTransparency = 0.4 -- pads glow; a stroke keeps the text off its own background
	label.TextScaled = true
	label.Text = text
	label.Parent = gui
	return label
end

BuildKit.PAD_SIZE = PAD_SIZE
BuildKit.FONT_SIZE = FONT_SIZE
BuildKit.MARKER_SIZE = MARKER_SIZE
BuildKit.MARKER_DROP = MARKER_DROP
BuildKit.MAX_CONFLUX_SIZE = MAX_CONFLUX_SIZE
BuildKit.MAX_LIGHT_RANGE = MAX_LIGHT_RANGE
BuildKit.RAIL_WIDTH = RAIL_WIDTH
BuildKit.RAIL_THICKNESS = RAIL_THICKNESS
BuildKit.MIN_RAIL_LENGTH = MIN_RAIL_LENGTH
BuildKit.newFolder = newFolder
BuildKit.makePart = makePart
BuildKit.makeSign = makeSign

return BuildKit
