--!strict
--[[
    NotifyController
    The toast stack. It is the client's only reader of the Notify remote: it renders at most four
    messages at a time in the bottom-left corner, colour-coded by Kind, each fading out on its own
    timer. Nothing else in the UI may invent a toast, because a message the server did not send is a
    claim about state the client has no way to know.
    Owner: client  |  Consumers: ClientBootstrap (lifecycle)
]]
--[[ WHY A TOKEN BUCKET AND NOT A QUEUE. GameConfig.Network.MaxNotifyPerSecond is the server's own
     Notify budget, and matching it here means a burst -- a Transcendence firing one message per
     unlocked Wing, a bugged loop, a hostile server -- can never paper over the game. An unbounded
     queue would only defer the damage: the player would then sit through a minute of stale toasts
     draining while the Sanctum kept running. Over budget the message is DROPPED, and dropping the
     NEWEST is the honest choice: the toasts already on screen are the ones being read, and a toast
     that arrives during a flood is the least likely one to be the important one.

     WHY THE CAP AND THE BUDGET ARE BOTH NEEDED. The budget bounds the RATE; the four-slot cap
     bounds what is on screen at once, because six per second held for five seconds each would
     still stack thirty toasts up the side of the screen. ]]

local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local GameConfig = require(Modules:WaitForChild("GameConfig"))
local RemoteSchema = require(Modules:WaitForChild("RemoteSchema"))
local Theme = require(Modules:WaitForChild("Theme"))

type Context = { Store: any, Remotes: { [string]: any }, Player: any, PlayerGui: any, Ui: any }
type Toast = { Frame: any, Label: any, Stroke: any, Dismissed: boolean }

local Controller = {}
Controller.Name = "NotifyController"

local MAX_VISIBLE = 4
local HOLD_SECONDS = 5 -- long enough to read a sentence, short enough not to own the corner
local FADE_SECONDS = 0.35
-- A toast is a glance, not a document. Truncating here means a pathological Text cannot resize the
-- stack or push the older toasts off screen.
local MAX_TEXT = 140

-- Kind -> Theme colour. Unknown kinds fall back to Accent rather than being dropped: a message the
-- server bothered to send is worth showing even if this build does not recognise its severity.
local KIND_COLOUR: { [string]: Color3 } = {
	info = Theme.Ui.Accent,
	success = Theme.Ui.Positive,
	warn = Theme.Ui.Warning,
	error = Theme.Ui.Negative,
}

local FADE_TWEEN = TweenInfo.new(FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local active: { Toast } = {}
local connections: { any } = {}
local root: any
local remotes: { [string]: any }
-- Monotonic, never reset: the list is bottom-aligned and sorted by LayoutOrder, so an ever-growing
-- order keeps the newest toast at the bottom and stops a new arrival from shuffling the one above
-- it while it is still being read.
local order = 0

local budget = math.max(1, math.floor(GameConfig.Network.MaxNotifyPerSecond))
local tokens = budget
local lastRefill = os.clock()

--[[ A leaky bucket refilled from the clock rather than a loop: no Heartbeat connection, no timer,
     and it stays correct across a frame hitch that a per-frame refill would under-count. ]]
local function consume(): boolean
	local now = os.clock()
	local elapsed = now - lastRefill
	if elapsed > 0 then
		tokens = math.min(budget, tokens + elapsed * budget)
		lastRefill = now
	end
	if tokens < 1 then
		return false
	end
	tokens -= 1
	return true
end

local function fade(instance: any, properties: { [string]: any }): ()
	-- Tweens are created per surface because a Frame tween cannot reach its label's TextTransparency
	-- or its stroke's Transparency, and a toast that faded its background but kept crisp text would
	-- look like a rendering bug rather than a dismissal.
	TweenService:Create(instance, FADE_TWEEN, properties):Play()
end

local function dismiss(toast: Toast): ()
	if toast.Dismissed then
		return
	end
	toast.Dismissed = true
	for index, entry in ipairs(active) do
		if entry == toast then
			table.remove(active, index)
			break
		end
	end

	fade(toast.Frame, { BackgroundTransparency = 1 })
	fade(toast.Label, { TextTransparency = 1, TextStrokeTransparency = 1 })
	fade(toast.Stroke, { Transparency = 1 })
	-- Debris rather than task.delay + Destroy: the Instance is reclaimed even if this client tears
	-- the controller down before the tween finishes, and there is no dangling closure holding it.
	Debris:AddItem(toast.Frame, FADE_SECONDS)
end

local function buildToast(kind: string, text: string): Toast
	local colour = KIND_COLOUR[kind] or Theme.Ui.Accent
	order += 1

	local frame = Instance.new("Frame")
	frame.Name = "Toast"
	frame.LayoutOrder = order
	frame.Size = UDim2.fromScale(1, 0.155)
	frame.BackgroundColor3 = Theme.Ui.Panel
	frame.BackgroundTransparency = 0.08
	frame.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	-- The stroke carries the severity in colour; the text carries it too, so the toast still reads
	-- correctly for a player who cannot separate the two hues.
	local stroke = Instance.new("UIStroke")
	stroke.Color = colour
	stroke.Thickness = 2
	stroke.Parent = frame

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0.1, 0)
	padding.PaddingBottom = UDim.new(0.1, 0)
	padding.PaddingLeft = UDim.new(0.05, 0)
	padding.PaddingRight = UDim.new(0.05, 0)
	padding.Parent = frame

	local label = Instance.new("TextLabel")
	label.Name = "Message"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Gotham
	-- Wrapped at a fixed size rather than TextScaled: scaling to fill would make a three-word toast
	-- enormous next to a two-line one, and the stack would visibly jump between messages.
	label.TextScaled = false
	label.TextSize = 15
	label.TextWrapped = true
	label.TextColor3 = colour
	label.TextStrokeTransparency = 0.6
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.Text = text
	label.Parent = frame

	-- Parented last, so a half-built toast never appears in the stack.
	frame.Parent = root
	return { Frame = frame, Label = label, Stroke = stroke, Dismissed = false }
end

local function push(payload: any): ()
	if root == nil or type(payload) ~= "table" then
		return
	end
	local text = payload.Text
	if type(text) ~= "string" or text == "" then
		return
	end
	local kind = payload.Kind
	if type(kind) ~= "string" or KIND_COLOUR[kind] == nil then
		kind = "info"
	end
	if not consume() then
		return
	end

	-- Trim BEFORE building, and pop from the front (the oldest) so the stack never exceeds the cap
	-- even for a frame. table.remove first: dismiss() early-returns on an already-dismissed toast,
	-- so a search-and-remove inside the loop could otherwise spin forever.
	while #active >= MAX_VISIBLE do
		dismiss(table.remove(active, 1) :: Toast)
	end

	local toast = buildToast(kind, string.sub(text, 1, MAX_TEXT))
	table.insert(active, toast)
	-- Idempotent with the trim above and with Stop(): whichever dismissal happens first wins.
	task.delay(HOLD_SECONDS, function()
		dismiss(toast)
	end)
end

function Controller:Init(context: Context): ()
	remotes = context.Remotes
	root = context.Ui.Toasts.Root
end

function Controller:Start(): ()
	local remote = remotes[RemoteSchema.Remotes.Notify.Name]
	if remote == nil then
		-- Silent: ClientBootstrap already warned once per missing remote, and a second line per
		-- controller would bury the one that matters.
		return
	end
	table.insert(connections, remote.OnClientEvent:Connect(push))
end

function Controller:Stop(): ()
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
	-- Destroy outright rather than fade: Stop means the HUD is going away, and a toast tweening out
	-- over a torn-down interface is a leak with an animation.
	for _, toast in ipairs(active) do
		toast.Dismissed = true
		toast.Frame:Destroy()
	end
	table.clear(active)
end

return Controller
