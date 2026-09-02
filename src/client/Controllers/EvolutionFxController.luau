--!strict
--[[
    EvolutionFxController
    The client's reaction to the Fx remote: a stage-tinted screen flash, a short camera shake and a
    banner for an Attunement, a longer and brighter version for a Transcendence, a cheap pulse for a
    purchase, and a banner naming the partner on a link. It renders celebration and nothing else --
    every fact it announces was decided by the server and already exists in the snapshot.
    Owner: client  |  Consumers: ClientBootstrap (lifecycle)
]]
--[[ WHY EVERY EFFECT IS NON-BLOCKING AND TOTAL. An error raised inside a remote handler kills the
     connection, so one malformed payload would silently end every later effect. The payload is
     therefore untrusted throughout: an unknown Kind, a missing Data table, a NaN stage and a nil
     camera all fall through to a no-op, and nothing here ever yields.

     WHY GENERATION TOKENS RATHER THAN WAITING ON A TWEEN. Two Attunements can land back to back,
     and a naive "hide when my tween finishes" would let the first effect's completion hide the
     second effect's banner. Each sequence claims a token; a hide applies only if it still holds. ]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local EvolutionData = require(Modules:WaitForChild("EvolutionData"))
local RemoteSchema = require(Modules:WaitForChild("RemoteSchema"))
local Theme = require(Modules:WaitForChild("Theme"))

-- Sibling require, not a context lookup: controllers are singletons, so this is the same instance
-- ClientBootstrap started, and every entry point into it is a guarded no-op if it never did.
local SoundController = require(script.Parent.SoundController)

type Context = { Store: any, Remotes: { [string]: any }, Player: any, PlayerGui: any, Ui: any }

local Controller = {}
Controller.Name = "EvolutionFxController"

-- Flash opacity at its peak (0 = opaque). Attune is a wash, Transcend nearly whites out the screen.
local ATTUNE_FLASH, ATTUNE_FADE = 0.35, 0.9
local TRANSCEND_FLASH, TRANSCEND_FADE = 0.08, 2.2
local BANNER_HOLD = 2.6
local BANNER_FADE = 0.35
local SHAKE_SMALL, SHAKE_BIG = { 0.35, 0.010 }, { 1.10, 0.022 } -- { seconds, radians }

local rng = Random.new()
local connections: { any } = {}
local store: any = nil
local remotes: { [string]: any } = {}
local flash: any = nil
local banner: any = nil
local hudStroke: any = nil
local flashToken, bannerToken = 0, 0
local shakeConnection: any = nil
local shakeUntil, shakeMagnitude, shakeSpan = 0, 0, 1

local function num(value: any, default: number): number
	if type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge then
		return value
	end
	return default
end

local function make(className: string, properties: { [string]: any }, parent: Instance): any
	local instance = Instance.new(className)
	for key, value in pairs(properties) do
		(instance :: any)[key] = value
	end
	instance.Parent = parent -- parent last: one replication step rather than one per property
	return instance
end

local function tween(instance: any, seconds: number, properties: { [string]: any }): ()
	-- Sine/Out: fast at the start so the peak is instant and the decay is what the eye follows.
	local info = TweenInfo.new(seconds, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
	TweenService:Create(instance, info, properties):Play()
end

-- Hidden rather than left transparent between flashes: an invisible frame still sits over the HUD.
local function playFlash(colour: Color3, peak: number, fade: number): ()
	if flash == nil then
		return
	end
	flashToken += 1
	local token = flashToken
	flash.BackgroundColor3 = colour
	flash.BackgroundTransparency = peak
	flash.Visible = true
	tween(flash, fade, { BackgroundTransparency = 1 })
	task.delay(fade, function()
		if token == flashToken and flash ~= nil then
			flash.Visible = false
		end
	end)
end

local function playBanner(text: string, colour: Color3): ()
	if banner == nil then
		return
	end
	bannerToken += 1
	local token = bannerToken
	banner.Text = text
	banner.TextColor3 = colour
	banner.TextTransparency = 1
	banner.Visible = true
	tween(banner, BANNER_FADE, { TextTransparency = 0 })
	task.delay(BANNER_HOLD, function()
		if token ~= bannerToken or banner == nil then
			return
		end
		tween(banner, BANNER_FADE, { TextTransparency = 1 })
		task.delay(BANNER_FADE, function()
			if token == bannerToken and banner ~= nil then
				banner.Visible = false
			end
		end)
	end)
end

--[[ Camera shake, so an Attunement is felt as well as seen. Applied as a per-frame angular nudge:
     Roblox's default camera script rewrites CFrame from its subject every frame, so the offset
     decays naturally instead of accumulating, and a nil camera degrades to no shake at all.
     MOCK-EXTRA: workspace.CurrentCamera and Camera.CFrame (the camera is the only handle on this). ]]
local function shake(seconds: number, magnitude: number): ()
	shakeSpan = math.max(seconds, 0.05)
	shakeUntil = os.clock() + shakeSpan
	shakeMagnitude = magnitude
	if shakeConnection ~= nil then
		return
	end
	shakeConnection = RunService.RenderStepped:Connect(function()
		-- MOCK-EXTRA: workspace.CurrentCamera (and Camera.CFrame written below)
		local camera = workspace.CurrentCamera
		local remaining = shakeUntil - os.clock()
		if remaining <= 0 or camera == nil then
			if shakeConnection ~= nil then
				shakeConnection:Disconnect()
				shakeConnection = nil
			end
			return
		end
		-- Linear falloff: the jolt is strongest on the first frame and settles, which reads as an
		-- impact rather than a wobble.
		local amount = shakeMagnitude * (remaining / shakeSpan)
		camera.CFrame = camera.CFrame
			* CFrame.Angles(rng:NextNumber(-amount, amount), rng:NextNumber(-amount, amount), 0)
	end)
end

-- The stage colour as the player actually sees it on the Conflux, affinity tint included: a flash
-- that did not match the thing it is celebrating would read as a different event.
local function stageColour(stage: number): Color3
	local affinity = if store ~= nil then store:GetPath("Plot.Affinity") else nil
	return Theme.getConfluxAppearance(stage, if type(affinity) == "string" then affinity else nil).Color
end

local function onAttune(data: { [string]: any }): ()
	-- Prefer the payload, fall back to the snapshot: a Full StateSync usually lands first, and
	-- either way the banner must name a real stage rather than guess.
	local fallback = if store ~= nil then store:GetPath("Plot.Stage") else 1
	local stage = math.clamp(math.floor(num(data.Stage, num(fallback, 1))), 1, EvolutionData.MaxStage)
	local def = EvolutionData.get(stage)
	local colour = stageColour(stage)
	playFlash(colour, ATTUNE_FLASH, ATTUNE_FADE)
	shake(SHAKE_SMALL[1], SHAKE_SMALL[2])
	playBanner(
		string.format(
			"%s  -  %s   (Stage %d of %d)",
			if def then def.Name else "Attuned",
			if def then def.Title else "the Conflux has grown",
			stage,
			EvolutionData.MaxStage
		),
		colour
	)
	SoundController:PlaySfx("Attune")
end

local function onTranscend(data: { [string]: any }): ()
	local fallback = if store ~= nil then store:GetPath("You.Rebirths") else 0
	local rebirths = math.max(0, math.floor(num(data.Rebirths, num(fallback, 0))))
	-- Primordial white regardless of affinity: the Sanctum has just been given up, so the tint that
	-- belonged to it is exactly what should not be on screen.
	local colour = Theme.Stage[EvolutionData.MaxStage].Color
	playFlash(colour, TRANSCEND_FLASH, TRANSCEND_FADE)
	shake(SHAKE_BIG[1], SHAKE_BIG[2])
	playBanner(string.format("TRANSCENDED  -  Rebirth %d", rebirths), colour)
	SoundController:PlaySfx("Transcend")
end

-- Cheap on purpose: a purchase happens every few seconds at a built-out Sanctum, so it gets one
-- stroke tween on the HUD panel and no flash, no shake and no banner.
local function onPurchase(): ()
	if hudStroke ~= nil then
		hudStroke.Color = Theme.Ui.Positive
		hudStroke.Transparency = 0
		tween(hudStroke, 0.45, { Transparency = 0.25 })
		task.delay(0.5, function()
			if hudStroke ~= nil then
				hudStroke.Color = Theme.Ui.Stroke
			end
		end)
	end
	SoundController:PlaySfx("Purchase")
end

local function onLink(data: { [string]: any }): ()
	local who = data.Name
	playBanner(
		(if type(who) == "string" and who ~= "" then who else "A partner") .. " joined the Sanctum",
		Theme.Ui.Positive
	)
	SoundController:PlaySfx("Notify")
end

local HANDLERS: { [string]: (data: { [string]: any }) -> () } = {
	attune = onAttune, transcend = onTranscend, purchase = function() onPurchase() end, link = onLink,
}

function Controller:Init(context: Context): ()
	store = context.Store
	remotes = context.Remotes
	local screen = context.Ui.ScreenGui

	-- Built here, not in UiBuilder: pure effect surfaces with no bound state, kept beside the code
	-- that animates them so a teardown cannot leave them behind.
	flash = make("Frame", {
		Name = "FxFlash", BackgroundColor3 = Theme.Ui.Accent, BackgroundTransparency = 1,
		BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 40,
	}, screen)

	banner = make("TextLabel", {
		Name = "FxBanner", AnchorPoint = Vector2.new(0.5, 0), BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold, Position = UDim2.fromScale(0.5, 0.14),
		Size = UDim2.fromScale(0.6, 0.08), Text = "", TextColor3 = Theme.Ui.Text,
		TextScaled = true, TextTransparency = 1, Visible = false, ZIndex = 41,
	}, screen)

	local hudRoot = context.Ui.Hud.Root
	hudStroke = if hudRoot ~= nil then hudRoot:FindFirstChildOfClass("UIStroke") else nil
end

function Controller:Start(): ()
	local fx = remotes[RemoteSchema.Remotes.Fx.Name]
	if fx == nil then
		return
	end

	table.insert(connections, fx.OnClientEvent:Connect(function(payload: any)
		if type(payload) ~= "table" then
			return
		end
		local handler = if type(payload.Kind) == "string" then HANDLERS[payload.Kind] else nil
		if handler == nil then
			return
		end
		--[[ Only reject a PlotId we can positively identify as somebody else's. Before the first
		     Full snapshot our own id is 0, and dropping the link/attune effects of the first minute
		     would be a worse bug than rendering a stray one. ]]
		local mine = num(if store ~= nil then store:GetPath("Plot.Id") else 0, 0)
		local theirs = num(payload.PlotId, mine)
		if mine > 0 and theirs > 0 and mine ~= theirs then
			return
		end
		handler(if type(payload.Data) == "table" then payload.Data else {})
	end))
end

function Controller:Stop(): ()
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
	if shakeConnection ~= nil then
		shakeConnection:Disconnect()
		shakeConnection = nil
	end
	-- Bump both tokens so any delayed hide still in flight becomes a no-op against a destroyed tree.
	flashToken += 1
	bannerToken += 1
	if flash ~= nil then
		flash:Destroy()
		flash = nil
	end
	if banner ~= nil then
		banner:Destroy()
		banner = nil
	end
	hudStroke = nil
end

return Controller
