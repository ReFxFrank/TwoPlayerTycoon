--!strict
--[[
    AffinityController
    The Stage 3 elemental choice: it opens the Affinity modal when the snapshot says the gate is
    open and nothing has been chosen, renders the four elements straight out of AffinityData, and
    forwards one press as ChooseAffinity { Affinity = id }. It closes only when the store reports a
    Chosen affinity, so the modal never claims a commitment the server has not made.
    Owner: client  |  Consumers: ClientBootstrap (lifecycle)
]]
--[[ WHY EVERY NUMBER ON A BUTTON IS READ FROM AffinityData. The choice is permanent for the run and
     the four options are deliberately within 1% of each other on raw income (see the balance model
     in AffinityData), so the trade-off numbers ARE the decision. Restating them here would let the
     UI drift from the balance table, and a player would be choosing on a lie. Every figure below is
     pulled from the def and formatted; not one is typed out.

     WHY THERE IS A REMINDER CHIP. "Later" has to exist -- this is a shared, irreversible choice and
     the pair should be able to talk about it -- but Observe only fires on a genuine change, so a
     dismissed modal would never reopen on its own and the Affinity would become unreachable. The
     chip is the standing way back in, and it is visible for exactly as long as the gate is open. ]]

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local AffinityData = require(Modules:WaitForChild("AffinityData"))
local EvolutionData = require(Modules:WaitForChild("EvolutionData"))
local Format = require(Modules:WaitForChild("Format"))
local RemoteSchema = require(Modules:WaitForChild("RemoteSchema"))
local Theme = require(Modules:WaitForChild("Theme"))

type Context = { Store: any, Remotes: { [string]: any }, Player: any, PlayerGui: any, Ui: any }

local Controller = {}
Controller.Name = "AffinityController"

local BODY = table.concat({
	"The Conflux has reached Stage " .. tostring(EvolutionData.AffinityUnlockStage)
		.. " and will bind to one element.",
	"The Sanctum has ONE Affinity, not one each -- either occupant can make this choice, and it"
		.. " applies to both of you.",
	"It is permanent until your next Transcendence: it cannot be changed, re-rolled or undone.",
}, "\n")

-- If the server never answers a choice (rate limited, or the gate closed underneath us) the button
-- must not stay stuck on "Binding". Long enough that a normal round trip always wins the race.
local ANSWER_GRACE = 3

local connections: { any } = {}
local remotes: { [string]: any } = {}
local store: any = nil
local modal: any = nil
local chip: any = nil
local strokes: { [string]: any } = {}
local selected: string? = nil
local pendingToken = 0

local function new(className: string, properties: { [string]: any }, parent: Instance?): any
	local instance = Instance.new(className)
	for key, value in pairs(properties) do
		(instance :: any)[key] = value
	end
	instance.Parent = parent -- parent last: one replication step instead of a dozen
	return instance
end

--[[ The five trade-off figures, always all five and always in the same order, so the four buttons
     read as one comparable table rather than four adverts. A neutral value prints as x1 / +0 on
     purpose: "this element gives up nothing here" is information. ]]
local function statsText(def: AffinityData.Affinity): string
	return table.concat({
		"Income   " .. Format.multiplier(def.IncomeMultiplier),
		"Rate       " .. Format.multiplier(def.SpawnRateMultiplier),
		"Mote      " .. Format.multiplier(def.MoteValueMultiplier),
		"Rails      " .. Format.multiplier(def.RailSpeedMultiplier),
		string.format("Speed    %+d", math.floor(def.WalkSpeedBonus)),
	}, "\n")
end

--[[ Turns the builder's plain coloured button into a card: name, flavour, numbers. Done here rather
     than in UiModals because it is entirely about what an Affinity MEANS, and the builder is inert
     by design -- it does not know that AffinityData has a balance model. ]]
local function decorate(button: any, def: AffinityData.Affinity): ()
	button.Text = ""
	-- The stroke is the selection marker, so the hover flash is turned off: two competing
	-- highlights on the most consequential button in the game is one too many.
	button.AutoButtonColor = false

	local ink = Theme.Ui.Background -- dark ink on the element's own colour, which is always bright
	new("TextLabel", {
		Name = "NameLabel", BackgroundTransparency = 1, Font = Enum.Font.GothamBold,
		Position = UDim2.fromScale(0.05, 0.03), Size = UDim2.fromScale(0.9, 0.14),
		Text = def.Name, TextColor3 = ink, TextScaled = true, ZIndex = 24,
	}, button)
	new("TextLabel", {
		Name = "DescLabel", BackgroundTransparency = 1, Font = Enum.Font.Gotham,
		Position = UDim2.fromScale(0.07, 0.19), Size = UDim2.fromScale(0.86, 0.36),
		Text = def.Description, TextColor3 = ink, TextSize = 10, TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
		ZIndex = 24,
	}, button)
	new("TextLabel", {
		Name = "StatsLabel", BackgroundTransparency = 1, Font = Enum.Font.Code,
		Position = UDim2.fromScale(0.07, 0.57), Size = UDim2.fromScale(0.86, 0.4),
		Text = statsText(def), TextColor3 = ink, TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
		ZIndex = 24,
	}, button)

	strokes[def.Id] = button:FindFirstChildOfClass("UIStroke")
end

local function renderSelection(): ()
	for id, stroke in pairs(strokes) do
		if stroke ~= nil then
			local chosen = id == selected
			stroke.Color = if chosen then Theme.Ui.Text else Theme.Ui.Stroke
			stroke.Thickness = if chosen then 4 else 1.5
			stroke.Transparency = if chosen then 0 else 0.6
		end
	end
end

local function renderConfirm(pending: boolean): ()
	local def = if selected ~= nil then AffinityData.get(selected) else nil
	local button = modal.Confirm
	local ready = def ~= nil and not pending
	if pending then
		button.Text = "Binding..."
	elseif def ~= nil then
		button.Text = "Bind " .. def.Name .. " forever"
	else
		button.Text = "Pick an element"
	end
	button.BackgroundColor3 = if ready and def then def.Color else Theme.Ui.Panel
	button.TextColor3 = if ready then Theme.Ui.Background else Theme.Ui.Muted
	button.Active = ready
	button.AutoButtonColor = ready
end

local function setSelected(id: string?): ()
	selected = id
	renderSelection()
	renderConfirm(false)
end

function Controller:Init(context: Context): ()
	remotes = context.Remotes
	store = context.Store
	modal = context.Ui.Modals.Affinity

	modal.Body.Text = BODY
	modal.Body.TextSize = 13
	modal.Root.Visible = false

	for _, def in ipairs(AffinityData.List) do
		local button = modal.Buttons[def.Id]
		if button ~= nil then
			decorate(button, def)
		end
	end
	setSelected(nil)

	--[[ Parented to the ScreenGui rather than added to the action bar: the bar is a fixed
	     UIListLayout whose three buttons already fill it, and a fourth entry would resize the
	     Attune button every time the gate opened. ]]
	chip = new("TextButton", {
		Name = "AffinityChip", AnchorPoint = Vector2.new(0.5, 1), AutoButtonColor = true,
		BackgroundColor3 = Theme.Ui.Warning, BorderSizePixel = 0, Font = Enum.Font.GothamBold,
		Position = UDim2.fromScale(0.5, 0.885), Size = UDim2.fromScale(0.22, 0.045),
		Text = "Choose the Sanctum's Affinity", TextColor3 = Theme.Ui.Background, TextScaled = true,
		Visible = false, ZIndex = 12,
	}, context.Ui.ScreenGui)
	new("UICorner", { CornerRadius = UDim.new(0, 8) }, chip)
end

function Controller:Start(): ()
	local function track(connection: any): ()
		table.insert(connections, connection)
	end

	for _, def in ipairs(AffinityData.List) do
		local button = modal.Buttons[def.Id]
		if button ~= nil then
			track(button.Activated:Connect(function()
				setSelected(def.Id)
			end))
		end
	end

	track(chip.Activated:Connect(function()
		modal.Root.Visible = true
	end))

	track(modal.Confirm.Activated:Connect(function()
		local id = selected
		local remote = remotes[RemoteSchema.Remotes.ChooseAffinity.Name]
		if id == nil or remote == nil then
			return
		end
		-- The id is the whole payload and it is one of four literal strings; the server re-checks it
		-- against the catalogue and against the gate before committing anything.
		remote:FireServer({ Affinity = id })
		renderConfirm(true)

		pendingToken += 1
		local token = pendingToken
		task.delay(ANSWER_GRACE, function()
			-- Still ours and still unanswered: hand the button back rather than leave a dead modal.
			if token == pendingToken then
				renderConfirm(false)
			end
		end)
	end))

	-- "Later" hides the modal and nothing more. It sends no remote, because declining to choose is
	-- not a choice the server needs to hear about -- the gate simply stays open.
	track(modal.Cancel.Activated:Connect(function()
		modal.Root.Visible = false
	end))

	--[[ The single source of truth for whether this whole surface exists. Available is the server's
	     answer (Stage >= AffinityUnlockStage), Chosen is the commitment; the client computes
	     neither. Observe fires once immediately, so a player who logs in already past Stage 3 with
	     no Affinity gets the modal on the first Full snapshot. ]]
	track(store:Observe("Gates.Affinity", function(gate: any)
		local g = if type(gate) == "table" then gate else {}
		local chosen = if type(g.Chosen) == "string" then g.Chosen else nil
		local open = g.Available == true and chosen == nil

		chip.Visible = open
		if open then
			modal.Root.Visible = true
			return
		end

		-- Either the gate closed or an Affinity was bound. Both mean the same thing here: this
		-- surface is done, and the confirmation of it came from the server, not from the click.
		pendingToken += 1
		modal.Root.Visible = false
		if chosen ~= nil then
			setSelected(chosen)
		end
	end))
end

function Controller:Stop(): ()
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
	pendingToken += 1
	if modal ~= nil then
		modal.Root.Visible = false
	end
	if chip ~= nil then
		chip:Destroy()
		chip = nil
	end
end

return Controller
