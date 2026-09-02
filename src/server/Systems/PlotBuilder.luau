--!strict
--[[
    PlotBuilder
    Builds and tears down the Instance tree of one Sanctum: a floor slab per Wing, the purchase pads
    and their blank signs, the Ley Rail decks a Wellspring's Motes ride, the floating Conflux and its
    Font, the Motes folder, and the per-slot spawn and link markers. Placement comes from PlotLayout
    and every colour/material from Theme, so this module owns geometry and nothing else: no income,
    no affordability checks, no ProximityPrompts. PurchaseService owns every prompt and all pad
    wording -- PlotBuilder only leaves it an empty, correctly-placed, correctly-keyed pad to dress.
    Owner: server/Systems  |  Consumers: PlotService, which hands the Runtime on to PurchaseService,
                                         DropperSystem, MoteSystem and EvolutionService
]]

local ServerStorage = game:GetService("ServerStorage")

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local DropperData = require(Modules:WaitForChild("DropperData"))
local GameConfig = require(Modules:WaitForChild("GameConfig"))
local PlotLayout = require(Modules:WaitForChild("PlotLayout"))
local SectionData = require(Modules:WaitForChild("SectionData"))
local Theme = require(Modules:WaitForChild("Theme"))
local UpgradeData = require(Modules:WaitForChild("UpgradeData"))

type Section = SectionData.Section
type Appearance = Theme.ConfluxAppearance

-- One purchasable needing a pad, plus the Runtime.Pads/Signs key it answers to. Kind and Id are
-- published verbatim as the PadKind/PadId attributes PurchaseService reads back off the pad.
type PadEntry = { Key: string, Kind: string, Id: string }

type Runtime = {
	Model: Instance, Conflux: Instance, Font: Instance, MoteFolder: Instance, PlotId: number,
	Sections: { [string]: Instance }, Pads: { [string]: Instance }, Origin: CFrame,
	RailFolders: { [string]: Instance }, Signs: { [string]: TextLabel },
}

type PartProps = {
	Name: string, Size: Vector3, CFrame: CFrame, Color: Color3, Material: Enum.Material,
	Parent: Instance, Transparency: number?, CanCollide: boolean?,
}

-- PlotLayout owns every POSITION; these are the extents filling the space it reserves. Its pad line
-- spacing is 12 studs, so a 6-stud pad leaves a walkway, and a 2-tall pad centred on PlotLayout's
-- PAD_HEIGHT of 1.5 rests exactly on the 0.5 slab top instead of hovering above it.
local PAD_SIZE = Vector3.new(6, 2, 6)
local RAIL_WIDTH, RAIL_THICKNESS = 2.2, 0.4
local MIN_RAIL_LENGTH = 0.5 -- shorter than this is a degenerate invisible part; skip the segment
local FONT_SIZE = Vector3.new(12, 6, 12)
local MARKER_SIZE = Vector3.new(8, 0.2, 8)
local MARKER_DROP = -3.4 -- spawn CFrames float at head clearance; the decal belongs on the floor
local MAX_LIGHT_RANGE = 60 -- PointLight.Range is hard-capped at 60 by the engine

-- Theme publishes materials for the Conflux and the Affinities, but a Sanctum's static architecture
-- has no Theme entry, so its materials are named once here.
local FLOOR_MATERIAL = Enum.Material.Slate
local PAD_MATERIAL = Enum.Material.Metal
local NEON = Enum.Material.Neon -- rails and Font: both glow, so they read as live ley-work
local MARKER_MATERIAL = Enum.Material.ForceField
local HIDDEN_ROOT_NAME = "SanctumHiddenWings" -- where locked Wings wait; see setSectionVisible

local PlotBuilder = {}

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
	gui.LightInfluence = 0 -- pads sit in the Conflux glow; unlit text stays legible at every Stage
	-- Six Sanctums x ~25 signs is 150 billboards; culling the ones already unreadable (past ~90
	-- studs) is free and keeps a full server off the client's GUI budget.
	gui.MaxDistance = 90
	gui.Parent = adornee

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.TextColor3 = Theme.Ui.Text
	label.TextStrokeTransparency = 0.4 -- pads glow; a stroke keeps text off its own background
	label.TextScaled = true
	label.Text = text
	label.Parent = gui
	return label
end

--[[ The per-Wing pad numbering, assigned in exactly one place.
     PlotLayout.padCFrame and PlotLayout.railPath take a PER-WING running index, not a catalogue
     Order -- DropperData and UpgradeData both number from 1, so reusing Order would stack an Upgrade
     pad on a Wellspring. Wellsprings are numbered FIRST so they always occupy 1..N: rails are built
     for exactly those indices, and PlotLayout cycles rail lanes every 3 orders, so keeping
     Wellsprings low keeps their rails inside that tight lane set. ]]
local function padPlan(sectionId: string): { PadEntry }
	local plan: { PadEntry } = {}
	local function collect(kind: string, list: { any })
		for _, def in ipairs(list) do
			-- Read on a Wing, RequiredSection means "my prerequisite": an unlock pad must stand on
			-- the Wing you can already reach, never inside the room it sells.
			if def.RequiredSection == sectionId then
				table.insert(plan, { Key = kind .. ":" .. def.Id, Kind = kind, Id = def.Id })
			end
		end
	end
	collect("dropper", DropperData.List)
	collect("upgrade", UpgradeData.List)
	collect("section", SectionData.List)
	if sectionId == SectionData.Base then
		-- Both Sanctum-wide rituals act on the Conflux, so they stand on the Wing that holds it.
		table.insert(plan, { Key = "attune", Kind = "attune", Id = "attune" })
		table.insert(plan, { Key = "transcend", Kind = "transcend", Id = "transcend" })
	end
	return plan
end

local function makePad(parent: Instance, cf: CFrame, entry: PadEntry, sectionId: string, order: number): Part
	local pad = makePart({
		Name = string.format("Pad_%s_%s", entry.Kind, entry.Id), Size = PAD_SIZE, CFrame = cf,
		Color = Theme.Ui.Panel, Material = PAD_MATERIAL, Parent = parent,
	})
	pad:SetAttribute("PadKind", entry.Kind)
	pad:SetAttribute("PadId", entry.Id)
	-- EXTRA beyond the spec's PadKind/PadId: MoteSystem needs (section, order) to recompute a
	-- Wellspring's rail path and that order is invented here, so publish it rather than have every
	-- consumer re-derive padPlan and silently drift away from the pad it is aiming at.
	pad:SetAttribute("PadSection", sectionId)
	pad:SetAttribute("PadOrder", order)
	return pad
end

-- One Ley Rail: thin decks joining consecutive PlotLayout.railPath waypoints.
local function buildRail(parent: Instance, origin: CFrame, section: Section, order: number, id: string)
	local def = DropperData.get(id)
	local colour = if def ~= nil then def.Color else Theme.Ui.Accent
	local path = PlotLayout.railPath(origin, section, order)
	local folder = newFolder("Rail_" .. id, parent)
	for i = 1, #path - 1 do
		local a, b = path[i].Position, path[i + 1].Position
		local dx, dz = b.X - a.X, b.Z - a.Z
		-- Length is measured in the XZ plane and the deck is left level: waypoint heights change
		-- between legs (nozzle -> deck -> Font), and a level deck at the mean height reads as a
		-- stepped rail instead of a twisted one. Motes still fly the true 3D path.
		local length = math.sqrt(dx * dx + dz * dz)
		if length >= MIN_RAIL_LENGTH then
			makePart({
				Name = string.format("Segment_%d", i),
				Size = Vector3.new(RAIL_WIDTH, RAIL_THICKNESS, length),
				-- Identity looks down -Z, so yaw = atan2(-dx, -dz) aims the long axis along the leg,
				-- the same convention PlotLayout uses to orient its own waypoints.
				CFrame = CFrame.new((a.X + b.X) * 0.5, (a.Y + b.Y) * 0.5, (a.Z + b.Z) * 0.5)
					* CFrame.Angles(0, math.atan2(-dx, -dz), 0),
				Color = colour, Material = NEON, Parent = folder, Transparency = 0.25,
				CanCollide = false, -- a player must never be able to stand on or snag a rail
			})
		end
	end
end

local function hiddenHolder(model: Instance): Instance
	local root = ServerStorage:FindFirstChild(HIDDEN_ROOT_NAME) or newFolder(HIDDEN_ROOT_NAME, ServerStorage)
	local name = model.Name .. "_Hidden"
	return root:FindFirstChild(name) or newFolder(name, root)
end

function PlotBuilder.buildSection(sanctumModel: Instance, section: Section): Instance
	-- The origin is recovered from the Model because the spec's signature has nowhere to pass it.
	-- Defaulting to plot 1 on a missing or non-numeric attribute keeps a hand-built test Model
	-- buildable instead of erroring on arithmetic-on-nil deep inside PlotLayout.
	local plotId = sanctumModel:GetAttribute("PlotId")
	local origin = PlotLayout.sanctumOrigin(if type(plotId) == "number" then plotId else 1)

	local model = Instance.new("Model")
	model.Name = section.Id
	makePart({
		Name = "Floor", Size = section.Size, CFrame = PlotLayout.sectionCFrame(origin, section),
		-- The base Wing is tinted apart so the Core reads as the heart of the Sanctum.
		Color = if section.Id == SectionData.Base then Theme.Ui.Stroke else Theme.Ui.Panel,
		Material = FLOOR_MATERIAL, Parent = model,
	})
	newFolder("Pads", model)
	newFolder("Rails", model)
	model.Parent = sanctumModel
	return model
end

function PlotBuilder.build(plotId: number, parent: Instance): (Instance, Runtime)
	local origin = PlotLayout.sanctumOrigin(plotId)
	local model = Instance.new("Model")
	model.Name = string.format("Sanctum_%d", plotId)
	model:SetAttribute("PlotId", plotId) -- read back by buildSection, and handy in Studio

	local sections: { [string]: Instance } = {}
	local railFolders: { [string]: Instance } = {}
	local pads: { [string]: Instance } = {}
	local signs: { [string]: TextLabel } = {}
	for _, section in ipairs(SectionData.List) do
		local sectionModel = PlotBuilder.buildSection(model, section)
		local padFolder = sectionModel:FindFirstChild("Pads") :: Instance
		local railFolder = sectionModel:FindFirstChild("Rails") :: Instance
		sections[section.Id] = sectionModel
		railFolders[section.Id] = railFolder
		for order, entry in ipairs(padPlan(section.Id)) do
			local pad = makePad(padFolder, PlotLayout.padCFrame(origin, section, order), entry, section.Id, order)
			pads[entry.Key] = pad
			signs[entry.Key] = makeSign(pad, "", 3.5)
			if entry.Kind == "dropper" then
				buildRail(railFolder, origin, section, order, entry.Id)
			end
		end
	end

	-- Stage 1 unattuned is the only look PlotBuilder knows; EvolutionService pushes every later one
	-- through setConfluxAppearance.
	local look = Theme.getConfluxAppearance(1, nil)
	local size = math.max(1, look.Size)
	local conflux = makePart({
		Name = "Conflux", Size = Vector3.new(size, size, size), CFrame = PlotLayout.confluxCFrame(origin),
		Color = look.Color, Material = look.Material, Parent = model, Transparency = 0.15,
		CanCollide = false, -- it floats 20 studs up, but a solid Conflux would block arriving Motes
	})
	local light = Instance.new("PointLight")
	light.Name = "ConfluxGlow"
	light.Color = look.Color
	light.Range = math.min(MAX_LIGHT_RANGE, size * 3)
	light.Brightness = 2.5
	light.Parent = conflux

	local font = makePart({
		Name = "ConfluxFont", Size = FONT_SIZE, CFrame = PlotLayout.fontCFrame(origin),
		Color = Theme.Ui.Accent, Material = NEON, Parent = model,
		CanCollide = false, -- every rail ends inside it; nothing may be deflected on the way in
	})
	makeSign(font, string.format("Sanctum %d", plotId), 6)

	local motes = newFolder("Motes", model)
	local markers = newFolder("Markers", model)
	for slot = 1, GameConfig.Plot.SlotsPerSanctum do
		makePart({
			Name = string.format("SpawnMarker_%d", slot), Size = MARKER_SIZE, Transparency = 0.5,
			CFrame = PlotLayout.spawnSlotCFrame(origin, slot) * CFrame.new(0, MARKER_DROP, 0),
			Color = Theme.Ui.Positive, Material = MARKER_MATERIAL, Parent = markers,
			CanCollide = false, -- a spawning character must not be shoved off its own marker
		})
		-- Link pads are Sanctum furniture, not Wing furniture: PlotLayout places them separately, so
		-- they carry order 0 -- a value that never indexes a Wing pad line.
		local key = "link:" .. slot
		local entry: PadEntry = { Key = key, Kind = "link", Id = tostring(slot) }
		local pad = makePad(markers, PlotLayout.linkPadCFrame(origin, slot), entry, SectionData.Base, 0)
		pads[key] = pad
		signs[key] = makeSign(pad, "", 3.5)
	end

	-- Parented LAST so the Sanctum replicates in one burst rather than as ~200 separate part
	-- additions streaming to every client while it is still half-assembled.
	model.Parent = parent
	return model, {
		Model = model, Sections = sections, Pads = pads, Conflux = conflux, Font = font,
		MoteFolder = motes, RailFolders = railFolders, Signs = signs, PlotId = plotId, Origin = origin,
	}
end

--[[ Locked Wings are REPARENTED out of the world, not made transparent.
     A transparent slab is still a rendered part with a physics record, still streamed to every
     client, and its pads would still be reachable by a ProximityPrompt -- so PurchaseService would
     have to re-check the lock on every trigger. Parking the Wing in ServerStorage costs the client
     literally nothing (ServerStorage never replicates) and makes an unowned Wing's pads unreachable
     by construction rather than by a check someone could forget. The trade: those Instances still
     exist, so PlotBuilder.destroy has to sweep both places. ]]
function PlotBuilder.setSectionVisible(runtime: Runtime, sectionId: string, visible: boolean)
	local section = runtime.Sections[sectionId]
	if section == nil then
		-- A sanitised save can still name a Wing this build does not have; ignoring a stale id beats
		-- taking down the whole Sanctum rebuild with it.
		return
	end
	section.Parent = if visible then runtime.Model else hiddenHolder(runtime.Model)
end

function PlotBuilder.setConfluxAppearance(runtime: Runtime, appearance: Appearance)
	local conflux = runtime.Conflux :: Part
	-- Clamped because a zero or negative Size would make the Conflux vanish, which reads as a bug
	-- rather than as an Attunement.
	local size = math.max(1, appearance.Size)
	conflux.Size = Vector3.new(size, size, size)
	conflux.Color = appearance.Color
	conflux.Material = appearance.Material
	local light = conflux:FindFirstChildOfClass("PointLight")
	if light ~= nil then
		light.Color = appearance.Color
		light.Range = math.min(MAX_LIGHT_RANGE, size * 3)
	end
end

function PlotBuilder.destroy(model: Instance)
	-- Locked Wings live OUTSIDE this Model (setSectionVisible), so Model:Destroy() on its own would
	-- leak every Wing the Sanctum never unlocked for the remaining life of the server.
	local root = ServerStorage:FindFirstChild(HIDDEN_ROOT_NAME)
	if root ~= nil then
		local holder = root:FindFirstChild(model.Name .. "_Hidden")
		if holder ~= nil then
			holder:Destroy()
		end
	end
	model:Destroy()
end

return PlotBuilder
