--!strict
--[[
    UiModals
    The four full-screen dialogs of the SanctumHud -- link offer, affinity choice, transcendence
    vote and settings -- built from the primitives UiBuilder hands in. Split out of UiBuilder for
    the 300-line rule alone: it is the same builder, equally inert, and knows nothing about the
    store, the remotes or when any of these should be shown.
    Owner: client  |  Consumers: UiBuilder (only)
]]
--[[ WHY EVERY MODAL SHARES ONE SHELL. Four dialogs that each invented their own backdrop, title
     and button row would drift apart the first time one of them was edited. makeShell builds the
     identical frame every time and returns a Content frame for the part that genuinely differs, so
     a controller can show any modal by flipping exactly one Visible. ]]

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local Theme = require(Modules:WaitForChild("Theme"))
local AffinityData = require(Modules:WaitForChild("AffinityData"))

type Kit = { [string]: any }
type Region = { [string]: any }

local UiModals = {}

--[[ Backdrop + panel + title + body + a Content frame + a Confirm/Cancel row.
     The backdrop is Active so it swallows clicks aimed at the world behind it: a modal that can be
     clicked through is a modal a player can dismiss by accident. ]]
local function makeShell(kit: Kit, parent: Instance, name: string, title: string, confirm: string, cancel: string): Region
	local root = kit.new("Frame", {
		Name = name, Active = true, BackgroundColor3 = Theme.Ui.Overlay, BackgroundTransparency = 0.4,
		BorderSizePixel = 0, Position = UDim2.fromScale(0, 0), Size = UDim2.fromScale(1, 1),
		Visible = false, ZIndex = 20,
	}, parent)

	local panel = kit.panel({
		Name = "Panel", AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 0,
		Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.46, 0.44), ZIndex = 21,
	}, root)
	-- Aspect-locked so the panel stays a readable card in portrait instead of a full-height column.
	kit.aspect(panel, 1.45)
	kit.padding(panel, 0.045)
	kit.listLayout(panel, 0.03, { HorizontalAlignment = Enum.HorizontalAlignment.Center })

	local titleLabel = kit.label({
		Name = "Title", LayoutOrder = 1, Size = UDim2.fromScale(1, 0.14), Font = kit.TitleFont,
		TextColor3 = Theme.Ui.Accent, TextXAlignment = Enum.TextXAlignment.Center, Text = title,
		ZIndex = 22,
	}, panel)
	-- TextWrapped + a fixed TextSize, not TextScaled: body copy is several lines, and scaling it to
	-- fill the frame would make a one-line message enormous next to a three-line one.
	local body = kit.label({
		Name = "Body", LayoutOrder = 2, Size = UDim2.fromScale(1, 0.34), TextColor3 = Theme.Ui.Muted,
		TextScaled = false, TextSize = 16, TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Top,
		ZIndex = 22,
	}, panel)

	local content = kit.new("Frame", {
		Name = "Content", BackgroundTransparency = 1, LayoutOrder = 3,
		Size = UDim2.fromScale(1, 0.32), ZIndex = 22,
	}, panel)

	local row = kit.new("Frame", {
		Name = "Actions", BackgroundTransparency = 1, LayoutOrder = 4,
		Size = UDim2.fromScale(1, 0.16), ZIndex = 22,
	}, panel)
	kit.listLayout(row, 0.03, {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
	})
	local cancelButton = kit.button({
		Name = "Cancel", LayoutOrder = 1, Size = UDim2.fromScale(0.44, 1),
		BackgroundColor3 = Theme.Ui.Background, TextColor3 = Theme.Ui.Muted, Text = cancel, ZIndex = 23,
	}, row)
	local confirmButton = kit.button({
		Name = "Confirm", LayoutOrder = 2, Size = UDim2.fromScale(0.44, 1),
		BackgroundColor3 = Theme.Ui.Accent, TextColor3 = Theme.Ui.Background, Text = confirm, ZIndex = 23,
	}, row)

	return {
		Root = root, Panel = panel, Title = titleLabel, Body = body, Content = content,
		Actions = row, Confirm = confirmButton, Cancel = cancelButton,
	}
end

local function buildLinkOffer(kit: Kit, parent: Instance): Region
	local shell = makeShell(kit, parent, "LinkOffer", "Share this Sanctum?", "Accept", "Decline")
	shell.Body.Text = "Linking merges both Sanctums, keeping the better of every value. Nobody loses"
		.. " anything they already own."
	-- Named so LinkOffer's controller has one label for "who is asking" separate from the fixed
	-- explanation of what linking does -- the explanation must not be overwritten by a name.
	shell.FromLabel = kit.label({
		Name = "FromLabel", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 0.6), Font = kit.TitleFont,
		TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 23,
	}, shell.Content)
	return shell
end

--[[ Affinity: the four elements are read from AffinityData rather than written out here, so adding
     a fifth element is a data change and this file never learns their names. ]]
local function buildAffinity(kit: Kit, parent: Instance): Region
	local shell = makeShell(kit, parent, "Affinity", "Choose an Affinity", "Confirm", "Later")
	shell.Body.Text = "The Conflux is ready to commit to an element. This choice is permanent until"
		.. " your next Transcendence."
	kit.listLayout(shell.Content, 0.02, {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
	})

	local buttons: { [string]: any } = {}
	for index, def in ipairs(AffinityData.List) do
		buttons[def.Id] = kit.button({
			Name = def.Id, LayoutOrder = index, Size = UDim2.fromScale(0.23, 0.9),
			-- The element's own colour is the label: four same-coloured buttons would make the
			-- choice read as arbitrary when it is the most flavourful decision in the run.
			BackgroundColor3 = def.Color, TextColor3 = Theme.Ui.Background, Text = def.Name,
			ZIndex = 23,
		}, shell.Content)
	end
	shell.Buttons = buttons
	return shell
end

--[[ Transcendence: the vote list is pre-built at SlotsPerSanctum rows and left invisible, so the
     live vote only ever toggles Visible and rewrites text -- no allocation inside a 30s countdown
     that is already the tensest moment in the game. ]]
local function buildTranscend(kit: Kit, parent: Instance): Region
	local shell = makeShell(kit, parent, "Transcend", "Transcend the Sanctum?", "Vote yes", "Vote no")
	shell.Body.Text = "Everything in the Sanctum resets. Every occupant must agree, and everyone who"
		.. " votes yes keeps the permanent multiplier."

	local list = kit.new("Frame", {
		Name = "VoteList", BackgroundTransparency = 1, Position = UDim2.fromScale(0, 0),
		Size = UDim2.fromScale(1, 0.72), ZIndex = 22,
	}, shell.Content)
	kit.listLayout(list, 0.04, { HorizontalAlignment = Enum.HorizontalAlignment.Center })

	local rows: { any } = {}
	for slot = 1, 2 do
		rows[slot] = kit.label({
			Name = "Vote" .. tostring(slot), LayoutOrder = slot, Size = UDim2.fromScale(0.9, 0.42),
			BackgroundTransparency = 0.35, BackgroundColor3 = Theme.Ui.Background,
			TextXAlignment = Enum.TextXAlignment.Center, Visible = false, ZIndex = 23,
		}, list)
		kit.corner(rows[slot], 6)
	end

	shell.VoteList = list
	shell.VoteRows = rows
	-- Separate from Body so the countdown can be rewritten every second without reflowing the
	-- wrapped explanation above it.
	shell.TimerLabel = kit.label({
		Name = "TimerLabel", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.fromScale(1, 0.24), TextColor3 = Theme.Ui.Warning,
		TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 23,
	}, shell.Content)
	return shell
end

--[[ Settings. The toggles are TextButtons whose Text carries their state, so SettingsController
     renders "Music: On" straight from Settings in the snapshot with no widget state of its own.
     ResetButton starts hidden: it is gated on Debug.AllowDataReset and, when
     Debug.DataResetStudioOnly is set, on RunService:IsStudio() -- checks that belong to the
     controller, not to a builder. ]]
local function buildSettings(kit: Kit, parent: Instance): Region
	local shell = makeShell(kit, parent, "Settings", "Settings", "Done", "Close")
	shell.Body.Text = "Audio preferences are saved to your profile and follow you between servers."
	kit.listLayout(shell.Content, 0.03, { HorizontalAlignment = Enum.HorizontalAlignment.Center })

	local function toggle(name: string, order: number, text: string): any
		return kit.button({
			Name = name, LayoutOrder = order, Size = UDim2.fromScale(0.8, 0.26),
			BackgroundColor3 = Theme.Ui.Background, Text = text, ZIndex = 23,
		}, shell.Content)
	end

	shell.MusicToggle = toggle("MusicToggle", 1, "Music: On")
	shell.SfxToggle = toggle("SfxToggle", 2, "Sfx: On")
	shell.ResetButton = kit.button({
		Name = "ResetButton", LayoutOrder = 3, Size = UDim2.fromScale(0.8, 0.26),
		BackgroundColor3 = Theme.Ui.Negative, Text = "Hold to reset my save", Visible = false,
		ZIndex = 23,
	}, shell.Content)
	return shell
end

function UiModals.build(kit: Kit, parent: Instance): Region
	return {
		LinkOffer = buildLinkOffer(kit, parent),
		Affinity = buildAffinity(kit, parent),
		Transcend = buildTranscend(kit, parent),
		Settings = buildSettings(kit, parent),
	}
end

return UiModals
