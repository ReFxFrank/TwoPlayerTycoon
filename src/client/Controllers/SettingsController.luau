--!strict
--[[
    SettingsController
    Owns the Settings modal and the action-bar button that opens it: the Music and Sfx toggles, and
    the developer-only "reset my save" control behind a two-second hold. It renders the Settings the
    snapshot reports and asks the server to change them; it keeps no preference of its own, so a
    setting the server refuses simply never appears to have changed.
    Owner: client  |  Consumers: ClientBootstrap (lifecycle)
]]
--[[ WHY THE TOGGLES ARE NOT OPTIMISTIC IN STATE. A click fires SetSetting and then does nothing
     else -- it does not touch the label. The label is rewritten only when "You.Settings" comes back
     changed. That costs one round trip of latency and buys the guarantee that the button never
     lies: a setting dropped by the rate limiter or refused by ProfileService snaps back on its own,
     with no reconciliation code and no second source of truth to drift out of sync. They still
     FEEL optimistic, because the snapshot that confirms them is already on a 0.5s cadence. ]]
--[[ CONFIRMED DECISION §9.5.6 -- THE RESET CONTROL. It exists only when GameConfig.Debug
     .AllowDataReset is set and, when DataResetStudioOnly is also set, only in Studio. Hiding the
     button here is a COURTESY, not the control: RemoteSchema refuses the payload and ProfileService
     refuses the action under exactly the same conditions, so a player who fabricates the remote
     call on a live server still gets nothing. This check exists so that a live server never shows a
     button that could not work, not so that the button is safe to show. ]]

local RunService = game:GetService("RunService")

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local GameConfig = require(Modules:WaitForChild("GameConfig"))
local RemoteSchema = require(Modules:WaitForChild("RemoteSchema"))
local Theme = require(Modules:WaitForChild("Theme"))

type Context = { Store: any, Remotes: { [string]: any }, Player: any, PlayerGui: any, Ui: any }

local Controller = {}
Controller.Name = "SettingsController"

local HOLD_SECONDS = 2
local RESET_LABEL = "Hold to reset my save" -- must match the wording UiModals builds the button with
local WARNING_TEXT = "Resetting deletes your save outright: every Wellspring, Wing, Stage,"
	.. " Transcendence and badge. There is no undo and no backup."

local connections: { any } = {}
local store: any
local remotes: { [string]: any }
local modal: any
local openButton: any
local fill: any
local warning: any
-- Hold state lives here rather than on the widget so cancelling is a single call from three
-- different signals (button up, pointer leave, modal close) that cannot disagree.
local held = 0
local holdConnection: any = nil

--[[ Both halves of the gate, in one place, so the Init-time visibility and the Start-time signal
     wiring can never be decided differently. ]]
local function resetAllowed(): boolean
	if GameConfig.Debug.AllowDataReset ~= true then
		return false
	end
	return GameConfig.Debug.DataResetStudioOnly ~= true or RunService:IsStudio()
end

-- Absent means on: a brand new profile has both enabled, and the pre-snapshot default must match
-- what the server will report rather than showing "Off" for half a second on every join.
local function settingOn(key: string): boolean
	return store:GetPath("You.Settings." .. key) ~= false
end

local function renderToggle(button: any, name: string, on: boolean): ()
	button.Text = name .. ": " .. (if on then "On" else "Off")
	button.BackgroundColor3 = if on then Theme.Ui.Positive else Theme.Ui.Background
	button.TextColor3 = if on then Theme.Ui.Background else Theme.Ui.Muted
end

local function renderSettings(value: any): ()
	local settings = if type(value) == "table" then value else {}
	renderToggle(modal.MusicToggle, "Music", settings.Music ~= false)
	renderToggle(modal.SfxToggle, "Sfx", settings.Sfx ~= false)
end

--[[ Fire and forget. The store is the only thing that decides what the toggle says, so there is
     nothing to roll back if the rate limiter drops this. The NEXT value is derived from the
     SNAPSHOT, never from the widget: two fast clicks then send the same intent twice instead of
     flip-flopping around a value the server never accepted. ]]
local function send(key: string): ()
	local remote = remotes[RemoteSchema.Remotes.SetSetting.Name]
	if remote == nil then
		return
	end
	remote:FireServer({ Key = key, Value = not settingOn(key) })
end

local function stopHold(): ()
	if holdConnection ~= nil then
		holdConnection:Disconnect()
		holdConnection = nil
	end
	held = 0
	if fill ~= nil then
		fill.Size = UDim2.fromScale(0, 1)
	end
end

local function fireReset(): ()
	-- Disconnect FIRST: this runs from inside the Heartbeat handler, and leaving it connected for
	-- even one more frame would fire a second ResetData that the rate limiter would then reject.
	stopHold()
	local remote = remotes[RemoteSchema.Remotes.ResetData.Name]
	if remote == nil then
		return
	end
	modal.ResetButton.Text = "Reset requested"
	remote:FireServer({ Confirm = true })
end

--[[ Accumulated dt rather than a start timestamp: it makes the fill and the threshold read the same
     clock, so the bar is never visibly full while the action has not fired (or the reverse). ]]
local function beginHold(): ()
	if holdConnection ~= nil then
		return
	end
	held = 0
	holdConnection = RunService.Heartbeat:Connect(function(delta: number)
		held += (if type(delta) == "number" and delta == delta then delta else 0)
		fill.Size = UDim2.fromScale(math.clamp(held / HOLD_SECONDS, 0, 1), 1)
		if held >= HOLD_SECONDS then
			fireReset()
		end
	end)
end

local function setOpen(open: boolean): ()
	modal.Root.Visible = open
	if not open then
		-- A modal closed mid-hold must not resume a destructive action when it is reopened.
		stopHold()
		modal.ResetButton.Text = RESET_LABEL
	end
end

function Controller:Init(context: Context): ()
	store = context.Store
	remotes = context.Remotes
	modal = context.Ui.Modals.Settings
	openButton = context.Ui.ActionBar.SettingsButton

	--[[ The hold meter is a CHILD of the button, not a sibling, so it tracks the button's size and
	     position for free. It is semi-transparent because a TextButton draws its own text underneath
	     its children: an opaque fill would hide the very label it is confirming. ]]
	fill = Instance.new("Frame")
	fill.Name = "HoldFill"
	fill.BackgroundColor3 = Theme.Ui.Negative
	fill.BackgroundTransparency = 0.45
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(0, 1)
	fill.ZIndex = modal.ResetButton.ZIndex
	fill.Parent = modal.ResetButton

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = fill

	--[[ Blunt, and built here rather than in UiModals: the warning only makes sense next to a button
	     that exists, and whether that button exists is this controller's decision. ]]
	warning = Instance.new("TextLabel")
	warning.Name = "ResetWarning"
	warning.LayoutOrder = 4 -- Content is a vertical UIListLayout; this sits under ResetButton
	warning.Size = UDim2.fromScale(0.9, 0.3)
	warning.BackgroundTransparency = 1
	warning.Font = Enum.Font.Gotham
	warning.TextScaled = false
	warning.TextSize = 13
	warning.TextWrapped = true
	warning.TextColor3 = Theme.Ui.Negative
	warning.TextXAlignment = Enum.TextXAlignment.Center
	warning.Text = WARNING_TEXT
	warning.ZIndex = modal.ResetButton.ZIndex
	warning.Parent = modal.Content

	local allowed = resetAllowed()
	modal.ResetButton.Visible = allowed
	warning.Visible = allowed
end

function Controller:Start(): ()
	local function track(connection: any): ()
		table.insert(connections, connection)
	end

	track(openButton.Activated:Connect(function()
		setOpen(true)
	end))
	-- Both footer buttons close: "Done" and "Close" mean the same thing here, because every setting
	-- was already committed the moment it was toggled. There is nothing left to confirm.
	track(modal.Confirm.Activated:Connect(function()
		setOpen(false)
	end))
	track(modal.Cancel.Activated:Connect(function()
		setOpen(false)
	end))

	track(modal.MusicToggle.Activated:Connect(function()
		send("Music")
	end))
	track(modal.SfxToggle.Activated:Connect(function()
		send("Sfx")
	end))
	track(store:Observe("You.Settings", renderSettings))

	--[[ The hold signals are wired ONLY when the reset is allowed. A hidden-but-live button would
	     still be reachable by anything that can flip Visible, and there is no reason to leave a
	     destructive path armed behind a boolean. MouseLeave is treated as a release because a
	     pointer dragged off the button never delivers MouseButton1Up to it. ]]
	if resetAllowed() then
		track(modal.ResetButton.MouseButton1Down:Connect(beginHold))
		track(modal.ResetButton.MouseButton1Up:Connect(stopHold))
		track(modal.ResetButton.MouseLeave:Connect(stopHold))
	end
end

function Controller:Stop(): ()
	stopHold()
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

return Controller
