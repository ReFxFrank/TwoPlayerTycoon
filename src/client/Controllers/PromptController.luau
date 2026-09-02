--!strict
--[[
    PromptController
    Makes every in-world purchase pad readable at a glance. It finds each pad's ProximityPrompt,
    reads the pad's server-published attributes (PadKind, PadId, PadCost, PadLocked), and writes
    ObjectText, ActionText and the sign colour. It buys nothing and judges nothing: what a pad means
    is PadVerdict's answer (which is Economy's answer), and how a refusal is worded is
    HudController's one reason-code table.
    Owner: client  |  Consumers: ClientBootstrap (lifecycle)
]]
--[[ WHY DISCOVERY AND RENDERING ARE TWO SEPARATE PASSES. A Sanctum carries ~40 pads and StateSync
     pushes Essence twice a second, so anything done per pad per tick runs ~80 times a second per
     Sanctum -- and six Sanctums stand in the same Workspace. So discovery (walk the tree, resolve
     the attribute holder, find the sign, wire the signals) happens ONCE per prompt and is never
     redone on a tick; the Essence observer only walks the ALREADY-BOUND table and writes two
     strings and a colour per pad. Rebuilding the binding table on every tick would re-resolve
     hundreds of Instances and allocate a table per pad, twice a second, for a number that moved by
     one -- and it would drop every attribute connection on the floor while doing it. ]]

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local Format = require(Modules:WaitForChild("Format"))
local Theme = require(Modules:WaitForChild("Theme"))

-- The reason-code -> English table lives in exactly one file (§11 of DECISIONS). Restating any of
-- it here is what would let a pad say "Locked" while the HUD says "Not enough Essence" about the
-- same refusal, so this controller borrows the resolver rather than owning a second table.
local HudController = require(script.Parent.HudController)
-- The pure half of this controller: the PlotState view and the per-kind verdicts.
local PadVerdict = require(script.Parent.PadVerdict)

type Context = { Store: any, Remotes: { [string]: any }, Player: any, PlayerGui: any, Ui: any }

-- Holder is the Instance the four Pad* attributes are read from; Label is the sign's TextLabel.
type Binding = {
	Prompt: any,
	Holder: Instance,
	Label: any,
	Kind: string,
	Id: string,
	Connections: { any },
}

local Controller = {}
Controller.Name = "PromptController"

-- A prompt normally sits directly on its pad; two hops covers a prompt nested one level deeper
-- (inside an Attachment, say) without walking the whole Sanctum for every unrelated prompt.
local MAX_ANCESTOR_HOPS = 2

local bindings: { [any]: Binding } = {}
local connections: { any } = {}
local store: any
local plot = PadVerdict.new()

-- Local rather than shared: a NaN PadCost must not survive into a comparison, and HudController
-- keeps its own copy of this same three-line guard for the same reason.
local function num(value: any, default: number): number
	if type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge then
		return value
	end
	return default
end

-- BuildKit parents a BillboardGui named "Sign" to each pad with a single TextLabel inside it.
local function signLabel(holder: Instance): any
	local sign = holder:FindFirstChild("Sign")
	return if sign ~= nil then sign:FindFirstChildOfClass("TextLabel") else nil
end

--[[ PadKind is published on the pad Part by PlotBuilder, but a prompt is allowed to carry its own
     copy, so the first Instance up the chain that has one wins and becomes the SINGLE place this
     binding reads all four attributes from. Reading Kind off one Instance and Cost off another is
     exactly how a pad ends up quoting a price for something it is not selling. ]]
local function holderFor(prompt: any): Instance?
	local node: Instance? = prompt
	for _ = 0, MAX_ANCESTOR_HOPS do
		if node == nil then
			return nil
		end
		if type(node:GetAttribute("PadKind")) == "string" then
			return node
		end
		node = node.Parent
	end
	return nil
end

local function render(binding: Binding): ()
	local holder = binding.Holder
	local locked = holder:GetAttribute("PadLocked") == true
	local name, ok, reason, cost = PadVerdict.evaluate(plot, binding.Kind, binding.Id)
	-- The server's published price outranks the one derived here: PurchaseService rewrites PadCost
	-- on every refresh, and if the two ever disagree the pad must quote what it will actually
	-- charge. The Economy figure is the fallback for the window before the first refresh lands.
	cost = num(holder:GetAttribute("PadCost"), cost)

	local prompt = binding.Prompt
	prompt.ObjectText = name

	if locked then
		-- PadLocked is the server's word and it outranks affordability: a Wing that has not been
		-- unlocked must never read "Buy for X", however much Essence is in the shared wallet. The
		-- fallback covers the disagreement case, where the pad is locked but Economy says "ok".
		prompt.Enabled = false
		prompt.ActionText = HudController.reasonText(if ok then PadVerdict.Reason.LockedSection else reason)
	else
		-- Enabled is driven from PadLocked ALONE, and only ever locally: a client-side write does
		-- not replicate, and PurchaseService re-checks occupancy and affordability on every trigger,
		-- so the worst this can do is offer a prompt the server then refuses.
		prompt.Enabled = true
		if ok then
			local verb = PadVerdict.verb(binding.Kind)
			prompt.ActionText = if cost > 0 then (verb .. " " .. Format.essence(cost)) else verb
		else
			prompt.ActionText = HudController.reasonText(reason)
		end
	end

	local label = binding.Label
	if label ~= nil then
		-- Three states, three colours, legible from across the Sanctum: Negative reads "you cannot
		-- be here yet", Muted reads "come back with more Essence", Positive reads "press E".
		label.TextColor3 = if locked
			then Theme.Ui.Negative
			elseif ok then Theme.Ui.Positive
			else Theme.Ui.Muted
	end
end

local function renderAll(): ()
	for _, binding in pairs(bindings) do
		render(binding)
	end
end

local function unbind(prompt: any): ()
	local binding = bindings[prompt]
	if binding == nil then
		return
	end
	bindings[prompt] = nil
	for _, connection in ipairs(binding.Connections) do
		connection:Disconnect()
	end
end

local function bind(prompt: any): ()
	if bindings[prompt] ~= nil then
		return
	end
	local holder = holderFor(prompt)
	if holder == nil then
		return -- not a purchase pad; every other prompt in the world is somebody else's business
	end
	local kind = holder:GetAttribute("PadKind")
	local id = holder:GetAttribute("PadId")
	if type(kind) ~= "string" or type(id) ~= "string" then
		return
	end

	local binding: Binding = {
		Prompt = prompt,
		Holder = holder,
		Label = signLabel(holder),
		Kind = kind,
		Id = id,
		Connections = {},
	}
	bindings[prompt] = binding

	--[[ Only PadCost and PadLocked earn a signal. PadKind/PadId are the pad's identity, written once
	     at build time, so watching them would cost a connection per pad per Sanctum for an event
	     that never fires. These two are what PurchaseService:RefreshPads rewrites. ]]
	table.insert(binding.Connections, holder:GetAttributeChangedSignal("PadCost"):Connect(function()
		render(binding)
	end))
	table.insert(binding.Connections, holder:GetAttributeChangedSignal("PadLocked"):Connect(function()
		render(binding)
	end))
	-- MOCK-EXTRA: Instance.Destroying. Without it a Transcendence -- which tears the Sanctum down
	-- and rebuilds every pad -- would leave this table holding dead prompts and their attribute
	-- connections for the rest of the session, and every rebuild would leak another ~40.
	table.insert(binding.Connections, prompt.Destroying:Connect(function()
		unbind(prompt)
	end))

	render(binding)
end

local function bindDescendants(root: Instance): ()
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("ProximityPrompt") then
			bind(descendant)
		end
	end
end

function Controller:Init(context: Context): ()
	store = context.Store
	-- Seed from whatever the store already holds so the sweep in Start renders real numbers instead
	-- of a zeroed default that the next snapshot would immediately overwrite.
	PadVerdict.update(plot, store:GetPath("Plot"))
	PadVerdict.setEssence(plot, store:GetPath("Essence"))
end

function Controller:Start(): ()
	local function track(connection: any): ()
		table.insert(connections, connection)
	end

	--[[ PlotBuilder does not tag pads with CollectionService, so discovery is the plain pair: one
	     sweep for the Sanctums that already exist when this client joins, plus DescendantAdded for
	     everything built afterwards. Both funnel into bind(), which is idempotent, so overlap
	     between the two is free. ]]
	bindDescendants(workspace)
	-- MOCK-EXTRA: workspace.DescendantAdded.
	track(workspace.DescendantAdded:Connect(function(descendant: Instance)
		if descendant:IsA("ProximityPrompt") then
			bind(descendant)
		elseif descendant:IsA("Model") or descendant:IsA("Folder") then
			-- A whole Wing arriving at once (an unlock reparents it back into the world) is one
			-- container add, so scan it. Restricted to containers because scanning the descendants
			-- of every Part that ever streams in would be an unbounded cost on a hot signal.
			bindDescendants(descendant)
		end
	end))

	--[[ Two observers, deliberately asymmetric. "Plot" only changes on a Full snapshot -- the server
	     marks a Sanctum dirty -- so rebuilding the PlotState view there is rare and cheap. "Essence"
	     arrives twice a second and writes ONE field before re-rendering the bound pads: no
	     allocation, no attribute walk, no re-resolution of a sign. ]]
	track(store:Observe("Plot", function(value: any)
		PadVerdict.update(plot, value)
		renderAll()
	end))
	track(store:Observe("Essence", function(value: any)
		PadVerdict.setEssence(plot, value)
		renderAll()
	end))
end

function Controller:Stop(): ()
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
	for prompt in pairs(bindings) do
		unbind(prompt)
	end
end

return Controller
