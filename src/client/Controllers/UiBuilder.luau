--!strict
--[[
    UiBuilder
    Builds the whole SanctumHud ScreenGui in code and hands back a flat table of named references.
    Deliberately inert: no store, no remotes, no connections, no behaviour of any kind. Controllers
    bind to a layout they did not build, which is what keeps "where a widget lives" and "what a
    widget means" in two separate files -- and keeps the layout reviewable as a plain diff.
    Owner: client  |  Consumers: ClientBootstrap, HudController, and every other controller
]]
--[[ WHY EVERYTHING IS Scale-BASED. This HUD is read on a 1920px monitor and on a 380px phone.
     Offset sizing would make the phone HUD swallow the screen, so every position and size is a
     fraction of the viewport, text is TextScaled, and any panel whose readability depends on its
     shape carries a UIAspectRatioConstraint. Pixel offsets appear ONLY for corner radii and stroke
     thickness, which are surface detail rather than layout. ]]

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local Theme = require(Modules:WaitForChild("Theme"))
local Format = require(Modules:WaitForChild("Format"))

-- Modal construction lives next door purely for the 300-line rule; it is the same builder, and it
-- is handed this file's primitives so there is exactly one definition of "what a panel looks like".
local UiModals = require(script.Parent.UiModals)

type Props = { [string]: any }
type Region = { [string]: any }

export type Ui = {
	ScreenGui: Instance,
	Hud: Region,
	Partners: Region,
	ActionBar: Region,
	Modals: Region,
	Toasts: Region,
}

local UiBuilder = {}

local TITLE_FONT = Enum.Font.GothamBold
local BODY_FONT = Enum.Font.Gotham

-- Overwrite `base` in place with `overrides`. Every widget helper starts from a defaults table it
-- owns exclusively, so mutating it here can never leak into another widget.
local function with(base: Props, overrides: Props?): Props
	if overrides ~= nil then
		for key, value in pairs(overrides) do
			base[key] = value
		end
	end
	return base
end

local function new(className: string, props: Props, parent: Instance?): any
	local inst = Instance.new(className)
	for key, value in pairs(props) do
		(inst :: any)[key] = value
	end
	-- Parent last: each property write on an already-parented instance is a separate replication
	-- step, and this builder writes a dozen per widget.
	inst.Parent = parent
	return inst
end

local function corner(inst: Instance, radius: number): ()
	new("UICorner", { CornerRadius = UDim.new(0, radius) }, inst)
end

local function stroke(inst: Instance, color: Color3, thickness: number): ()
	new("UIStroke", { Color = color, Thickness = thickness, Transparency = 0.25 }, inst)
end

-- Scale padding, not offset: the inset has to shrink with the panel or a phone-sized panel is all
-- margin and no content.
local function padding(inst: Instance, scale: number): ()
	local amount = UDim.new(scale, 0)
	new("UIPadding", {
		PaddingTop = amount, PaddingBottom = amount, PaddingLeft = amount, PaddingRight = amount,
	}, inst)
end

local function listLayout(inst: Instance, gap: number, overrides: Props?): any
	return new("UIListLayout", with({
		FillDirection = Enum.FillDirection.Vertical,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(gap, 0),
		HorizontalAlignment = Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Top,
	}, overrides), inst)
end

local function aspect(inst: Instance, ratio: number): ()
	new("UIAspectRatioConstraint", { AspectRatio = ratio, DominantAxis = Enum.DominantAxis.Width }, inst)
end

local function label(props: Props, parent: Instance?): any
	return new("TextLabel", with({
		BackgroundTransparency = 1,
		Font = BODY_FONT,
		Text = "",
		TextColor3 = Theme.Ui.Text,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
	}, props), parent)
end

local function panel(props: Props, parent: Instance?): any
	local frame = new("Frame", with({
		BackgroundColor3 = Theme.Ui.Panel,
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
	}, props), parent)
	corner(frame, 10)
	stroke(frame, Theme.Ui.Stroke, 1.5)
	return frame
end

local function button(props: Props, parent: Instance?): any
	local btn = new("TextButton", with({
		AutoButtonColor = true,
		BackgroundColor3 = Theme.Ui.Panel,
		BorderSizePixel = 0,
		Font = TITLE_FONT,
		Text = "",
		TextColor3 = Theme.Ui.Text,
		TextScaled = true,
	}, props), parent)
	corner(btn, 8)
	stroke(btn, Theme.Ui.Stroke, 1.5)
	return btn
end

-- The primitives handed to UiModals. Passed as an argument rather than required back out of this
-- module, because UiBuilder already requires UiModals and a cycle would break both.
local Kit: Props = {
	with = with, new = new, corner = corner, stroke = stroke, padding = padding,
	listLayout = listLayout, aspect = aspect, label = label, panel = panel, button = button,
	TitleFont = TITLE_FONT, BodyFont = BODY_FONT,
}

--[[ HUD -- top-left. The one region that updates on every tick, so it is a flat stack of labels
     with no nested layouts to re-solve. ]]
local function buildHud(parent: Instance): Region
	local root = panel({
		Name = "Hud",
		Position = UDim2.fromScale(0.014, 0.02),
		Size = UDim2.fromScale(0.26, 0.19),
	}, parent)
	aspect(root, 2.1)
	padding(root, 0.055)
	listLayout(root, 0.03)

	local essence = label({
		Name = "EssenceLabel", LayoutOrder = 1, Size = UDim2.fromScale(1, 0.34),
		Font = TITLE_FONT, TextColor3 = Theme.Ui.Accent, Text = Format.essence(0),
	}, root)
	local income = label({
		Name = "IncomeLabel", LayoutOrder = 2, Size = UDim2.fromScale(1, 0.15),
		TextColor3 = Theme.Ui.Muted, Text = Format.essence(0) .. "/s",
	}, root)
	local stage = label({
		Name = "StageLabel", LayoutOrder = 3, Size = UDim2.fromScale(1, 0.17),
		Font = TITLE_FONT, Text = "Stage 1 / " .. tostring(#Theme.Stage),
	}, root)

	-- The bar is a track plus a Fill whose Size.X.Scale IS the progress: one assignment per update,
	-- no tween, no maths in the widget.
	local bar = new("Frame", {
		Name = "StageBar", LayoutOrder = 4, Size = UDim2.fromScale(1, 0.09),
		BackgroundColor3 = Theme.Ui.Background, BorderSizePixel = 0,
	}, root)
	corner(bar, 6)
	local fill = new("Frame", {
		Name = "Fill", Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = Theme.Ui.Accent, BorderSizePixel = 0,
	}, bar)
	corner(fill, 6)

	local chip = label({
		Name = "MultiplierChip", LayoutOrder = 5, Size = UDim2.fromScale(0.46, 0.14),
		BackgroundTransparency = 0.15, BackgroundColor3 = Theme.Ui.Background,
		Font = TITLE_FONT, TextColor3 = Theme.Ui.Warning, TextXAlignment = Enum.TextXAlignment.Center,
		Text = "x1",
	}, root)
	corner(chip, 6)

	return {
		Root = root, EssenceLabel = essence, IncomeLabel = income,
		StageLabel = stage, StageBar = bar, StageFill = fill, MultiplierChip = chip,
	}
end

--[[ Partner panel -- top-right. Two fixed rows, one per Sanctum slot, each carrying BOTH a filled
     state and an empty state. Building both up front means the occupant observer only ever toggles
     Visible, so a partner joining or leaving never allocates an Instance. ]]
local function buildPartnerRow(parent: Instance, slot: number): Region
	local row = new("Frame", {
		Name = "Slot" .. tostring(slot), LayoutOrder = slot, Size = UDim2.fromScale(1, 0.42),
		BackgroundColor3 = Theme.Ui.Background, BackgroundTransparency = 0.35, BorderSizePixel = 0,
	}, parent)
	corner(row, 8)
	local highlight = new("UIStroke", { Color = Theme.Ui.Accent, Thickness = 2, Transparency = 1 }, row)
	highlight.Name = "Highlight"

	local name = label({
		Name = "NameLabel", Position = UDim2.fromScale(0.05, 0.08), Size = UDim2.fromScale(0.62, 0.44),
		Font = TITLE_FONT, Visible = false,
	}, row)
	local contribution = label({
		Name = "ContributionLabel", Position = UDim2.fromScale(0.05, 0.54), Size = UDim2.fromScale(0.62, 0.36),
		TextColor3 = Theme.Ui.Muted, Visible = false,
	}, row)
	local rebirth = label({
		Name = "RebirthChip", AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(0.95, 0.5), Size = UDim2.fromScale(0.26, 0.5),
		BackgroundTransparency = 0.2, BackgroundColor3 = Theme.Ui.Panel,
		TextColor3 = Theme.Ui.Warning, TextXAlignment = Enum.TextXAlignment.Center, Visible = false,
	}, row)
	corner(rebirth, 6)

	-- Visible by default: before the first snapshot the honest answer is "nobody is here yet", and
	-- an open slot is the game's invitation to bring a friend.
	local empty = label({
		Name = "EmptyLabel", Position = UDim2.fromScale(0.05, 0.2), Size = UDim2.fromScale(0.9, 0.6),
		TextColor3 = Theme.Ui.Muted, Text = "Slot open -- bring a friend to the Sanctum",
	}, row)

	return {
		Row = row, Highlight = highlight, NameLabel = name,
		ContributionLabel = contribution, RebirthChip = rebirth, EmptyLabel = empty,
	}
end

local function buildPartners(parent: Instance): Region
	local root = panel({
		Name = "Partners", AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(0.986, 0.02), Size = UDim2.fromScale(0.26, 0.16),
	}, parent)
	aspect(root, 2.4)
	padding(root, 0.05)
	listLayout(root, 0.04)

	label({
		Name = "Title", LayoutOrder = 0, Size = UDim2.fromScale(1, 0.16),
		Font = TITLE_FONT, TextColor3 = Theme.Ui.Muted, Text = "SANCTUM",
	}, root)

	return {
		Root = root,
		Slots = { buildPartnerRow(root, 1), buildPartnerRow(root, 2) },
	}
end

--[[ Action bar -- bottom-centre, where a thumb reaches on a phone. Transparent: the buttons are the
     panel, so the bar itself never covers the world. ]]
local function buildActionBar(parent: Instance): Region
	local root = new("Frame", {
		Name = "ActionBar", AnchorPoint = Vector2.new(0.5, 1), BackgroundTransparency = 1,
		Position = UDim2.fromScale(0.5, 0.975), Size = UDim2.fromScale(0.46, 0.085),
	}, parent)
	listLayout(root, 0.015, {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
	})

	local attune = button({
		Name = "AttuneButton", LayoutOrder = 1, Size = UDim2.fromScale(0.44, 1),
		BackgroundColor3 = Theme.Ui.Accent, Text = "Attune",
	}, root)
	-- Hidden, not disabled: an ineligible Transcendence is not a button the pair should be looking
	-- at, and it only ever becomes reachable once Gates.Transcend.Ok says so.
	local transcend = button({
		Name = "TranscendButton", LayoutOrder = 2, Size = UDim2.fromScale(0.34, 1),
		BackgroundColor3 = Theme.Ui.Warning, TextColor3 = Theme.Ui.Background,
		Text = "Transcend", Visible = false,
	}, root)
	local settings = button({
		Name = "SettingsButton", LayoutOrder = 3, Size = UDim2.fromScale(0.14, 1), Text = "Settings",
	}, root)

	return { Root = root, AttuneButton = attune, TranscendButton = transcend, SettingsButton = settings }
end

--[[ Toast stack -- bottom-left, growing upward so a new toast never shifts the ones already being
     read. NotifyController owns what goes in it. ]]
local function buildToasts(parent: Instance): Region
	local root = new("Frame", {
		Name = "Toasts", AnchorPoint = Vector2.new(0, 1), BackgroundTransparency = 1,
		Position = UDim2.fromScale(0.014, 0.87), Size = UDim2.fromScale(0.24, 0.42),
	}, parent)
	local layout = listLayout(root, 0.02, {
		VerticalAlignment = Enum.VerticalAlignment.Bottom,
		SortOrder = Enum.SortOrder.LayoutOrder,
	})
	return { Root = root, Layout = layout }
end

--[[ Builds the tree and returns it UNPARENTED. ClientBootstrap owns the moment it becomes visible,
     so a half-built HUD is never on screen. ]]
function UiBuilder.build(): Ui
	local screen = new("ScreenGui", {
		Name = "SanctumHud",
		ResetOnSpawn = false, -- the HUD must survive a respawn; state lives in the store, not here
		IgnoreGuiInset = true,
		DisplayOrder = 10,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, nil)

	return {
		ScreenGui = screen,
		Hud = buildHud(screen),
		Partners = buildPartners(screen),
		ActionBar = buildActionBar(screen),
		Modals = UiModals.build(Kit, screen),
		Toasts = buildToasts(screen),
	}
end

return UiBuilder
