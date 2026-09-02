--!strict
--[[
	PurchaseService
	Every purchase in the game happens here and nowhere else. It hangs a ProximityPrompt on each pad
	PlotBuilder laid out and listens to Triggered ON THE SERVER -- there is no client->server purchase
	remote and DECISIONS #7 says there never will be one, because a Triggered event carries a player
	and a prompt the server already trusts and offers nothing to forge. Every trigger is then
	re-derived from live state: the pad still stands in this Sanctum, the sender is a live Player,
	that player occupies THIS Sanctum, the def still exists in its catalogue, Economy still says yes,
	and EconomyService is what actually moves the Essence. What a pad means and says is PurchasePads'
	answer (which is Economy's answer); this file owns the prompts, the gates and the money.
	Owner: server/Services  |  Consumers: PlotService (BuildPads / RefreshPads), and every pad
]]

local Players = game:GetService("Players")

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local Economy = require(Modules:WaitForChild("Economy"))
local Format = require(Modules:WaitForChild("Format"))

-- The pure half of this service: key parsing, per-kind verdicts and everything a pad displays.
local PurchasePads = require(script.Parent:WaitForChild("PurchasePads"))

type Connection = { Disconnect: (self: any) -> () }
-- Structurally identical to PurchasePads' Verdict, restated because `export type` is reserved for
-- src/shared. Only Ok, Reason, Cost and Name are read on this side.
type Verdict = { Ok: boolean, Reason: string, Cost: number, Name: string, Detail: string, Hidden: boolean }

local Service = {}
Service.Name = "PurchaseService"

local Reason = Economy.Reason
--[[ Economy's closed set covers every refusal it can SEE, but it never sees who pressed a prompt.
     These four are the refusals only this service can make. They are returned to callers and logged;
     none of them is ever written to a pad, so the client's reason table does not need them. ]]
local NO_PLAYER, NOT_OCCUPANT = "no_player", "not_occupant"
local UNKNOWN_SANCTUM, UNAVAILABLE = "unknown_sanctum", "unavailable"
-- Published so a caller (and a spec) compares against a name rather than a string literal.
local PadReason: { [string]: string } = { NoPlayer = NO_PLAYER, NotOccupant = NOT_OCCUPANT,
	UnknownSanctum = UNKNOWN_SANCTUM, Unavailable = UNAVAILABLE }
for key, value in pairs(Reason) do PadReason[key] = value end
Service.Reason = PadReason

local PROMPT_NAME = "PurchasePrompt"
-- Pad -> Pads folder -> Wing model -> Sanctum model is three hops; 8 leaves room for a deeper tree
-- while still terminating, which a `while parent do` walk over a corrupt chain would not.
local MAX_HOPS = 8

local economy: any, plots: any, remotes: any, registryRef: any = nil, nil, nil, nil
local connections: { Connection } = {}

--[[ Total readers. Every argument is untrusted: a Sanctum may be a spec fixture, a half-released
     plot, or a table whose State was replaced under us between two frames. ]]

-- Read structurally rather than through PlotService's accessors, so a fixture Sanctum (which
-- PlotService would disown) still builds and refreshes its pads identically.
local function tableField(sanctum: any, field: string): any?
	if type(sanctum) ~= "table" then return nil end
	local value = (sanctum :: any)[field]
	return if type(value) == "table" then value else nil
end

-- The same test RemoteService uses. Unparented from Players is how both the engine and the mock mark
-- a player gone, and a prompt press queued before a disconnect still lands after it.
local function isLivePlayer(player: any): boolean
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players
end

--[[ One walk over Occupants, answering both questions this service ever asks of it: who to send Fx
     and Notify to, and whether `player` is one of them -- THE gate that stops a hostile trigger, and
     the reason a player who walked over from another Sanctum cannot buy on this one's pads.
     Identity by object first (what matches under Roblox) and by UserId second (what matches a
     rejoined Player instance, or a harness table). The UserId read is pcall'd because a Player is
     userdata and reading a field off one who has already left can throw. ]]
local function survey(sanctum: any, player: any?): ({ any }, boolean)
	local list: { any }, found = {}, false
	local occupants = tableField(sanctum, "Occupants")
	if occupants == nil then return list, false end
	local ok, raw = pcall(function(): any return (player :: any).UserId end)
	local userId: number? = if ok and type(raw) == "number" and raw == raw then raw :: number else nil
	for _, occupant in pairs(occupants :: { [any]: any }) do
		if type(occupant) == "table" then
			if occupant.Player ~= nil then table.insert(list, occupant.Player) end
			-- `player ~= nil` guards the nil == nil case: an absent player must never match an
			-- occupant record whose Player field has already been cleared.
			if player ~= nil and (occupant.Player == player
				or (userId ~= nil and occupant.UserId == userId)) then found = true end
		end
	end
	return list, found
end

--[[ Walks up rather than calling IsDescendantOf, which is outside the allowed API surface. This is
     what keeps a LOCKED Wing's contents unbuyable: PlotBuilder reparents an unowned Wing into
     ServerStorage without destroying it, so its prompts are still connected and can still be fired
     by anything holding a reference to one. Under the live Sanctum model, or it is not a pad. ]]
local function isUnder(node: any, ancestor: any): boolean
	if typeof(node) ~= "Instance" or typeof(ancestor) ~= "Instance" then return false end
	local current: any = node
	for _ = 1, MAX_HOPS do
		if current == nil then return false end
		if current == ancestor then return true end
		current = current.Parent
	end
	return false
end

function Service:RefreshPads(sanctum: any): ()
	local state, runtime = tableField(sanctum, "State"), tableField(sanctum, "Runtime")
	if state == nil or runtime == nil or type(runtime.Pads) ~= "table" then return end
	local signs = if type(runtime.Signs) == "table" then runtime.Signs else nil
	local occupants = #(survey(sanctum))
	for key, pad in pairs(runtime.Pads :: { [any]: any }) do
		local kind, id = PurchasePads.split(key)
		if kind ~= nil and typeof(pad) == "Instance" then
			local label = if signs ~= nil then signs[key] else nil
			PurchasePads.publish(pad, label, pad:FindFirstChild(PROMPT_NAME), kind, id,
				PurchasePads.evaluate(state, kind, id, occupants))
		end
	end
end

function Service:BuildPads(sanctum: any): ()
	local runtime = tableField(sanctum, "Runtime")
	if runtime == nil or type(runtime.Pads) ~= "table" then return end
	for key, pad in pairs(runtime.Pads :: { [any]: any }) do
		local kind, id = PurchasePads.split(key)
		--[[ An unrecognised key is a pad this service has not been taught to sell; it is left inert
		     rather than given a prompt whose handler would have nothing to do. The FindFirstChild is
		     what makes BuildPads idempotent -- PlotService may rebuild a Sanctum, and a second prompt
		     on one pad would charge the pair twice for one keypress. ]]
		if kind ~= nil and typeof(pad) == "Instance" and pad:FindFirstChild(PROMPT_NAME) == nil then
			local prompt = Instance.new("ProximityPrompt")
			prompt.Name = PROMPT_NAME
			prompt.RequiresLineOfSight = false -- pads stand in the open; a stray part must not blind one
			prompt.MaxActivationDistance = 10
			prompt.HoldDuration = 0
			prompt.ActionText = ""
			prompt.ObjectText = ""
			prompt.Parent = pad
			-- Connected on the SERVER (DECISIONS #7). `pad`, `kind` and `id` are captured from the
			-- Runtime table here and never read back off the prompt, so nothing a later attribute
			-- write could corrupt decides what this prompt buys.
			table.insert(connections, prompt.Triggered:Connect(function(player: any)
				-- pcall'd: an error would unwind the engine's prompt thread and, worse, leave the
				-- pair unsure whether they were charged. A failure is a refusal, and it is logged.
				local ok, err = pcall(Service._Trigger, Service, sanctum, pad, prompt, kind :: string, id, player)
				if not ok then warn(("[PurchaseService] %s pad failed: %s"):format(tostring(key), tostring(err))) end
			end))
		end
	end
	Service:RefreshPads(sanctum)
end

--[[ Re-derives everything downstream of PlotState and republishes the pads. RebuildSanctum no-ops
     for a Sanctum PlotService does not own (a spec fixture), so the two steps this purchase genuinely
     owes -- the dirty flag and the pad refresh -- are made unconditionally rather than left to it. ]]
local function commit(sanctum: any): ()
	if plots ~= nil then
		if type(plots.RebuildSanctum) == "function" then plots:RebuildSanctum(sanctum) end
		if type(plots.MarkDirty) == "function" then plots:MarkDirty(sanctum) end
	end
	Service:RefreshPads(sanctum)
end

local function announce(sanctum: any, player: any, v: Verdict): ()
	if remotes == nil then return end
	local recipients = survey(sanctum)
	if #recipients == 0 then return end
	local id = (sanctum :: any).Id
	remotes:FireClients(recipients, "Fx", { Kind = "purchase", Data = { Name = v.Name, Cost = v.Cost },
		PlotId = if type(id) == "number" and id == id then math.floor(id) else 0 })
	-- Sent to BOTH occupants: the wallet is shared (§1.2), so a partner spending from it is news.
	remotes:FireClients(recipients, "Notify", { Kind = "success",
		Text = string.format("%s bought %s for %s", tostring(player), v.Name, Format.essence(v.Cost)) })
end

--[[ Writes the goods. A missing bucket is REPAIRED rather than refused, because this runs after the
     debit: a PlotState with no Droppers map is a corrupt fixture, and charging the pair for a write
     that then landed on the floor is the one outcome worse than a repaired table. ]]
local BUCKET: { [string]: string } = { dropper = "Droppers", upgrade = "Upgrades", section = "Sections" }
local function apply(state: any, kind: string, id: string): ()
	local field = BUCKET[kind]
	if field == nil then return end
	if type(state[field]) ~= "table" then state[field] = {} end
	-- Counts are re-derived from live state rather than incremented from the label the pad showed.
	state[field][id] = if kind == "dropper" then PurchasePads.owned(state, id) + 1
		elseif kind == "upgrade" then Economy.upgradeLevel(state, id) + 1
		else true
end

--[[ The whole purchase path, in the one order that is safe, with no shortcut for a check the client
     or the prompt has "already done". Nothing before TryDebit mutates anything, so every refusal
     leaves the Sanctum exactly as it was. ]]
local function buy(player: any, sanctum: any, kind: string, id: any): (boolean, string)
	if not isLivePlayer(player) then return false, NO_PLAYER end
	local state = tableField(sanctum, "State")
	if state == nil then return false, UNKNOWN_SANCTUM end
	local occupants, isOccupant = survey(sanctum, player)
	if not isOccupant then return false, NOT_OCCUPANT end
	if type(id) ~= "string" then return false, Reason.UnknownId end
	-- The def is re-read from its catalogue and re-gated against LIVE state inside evaluate: the pad
	-- was labelled at some earlier moment, and the wallet, the Stage and the Wing may all have moved
	-- since -- including by the partner, on this very frame.
	local v = PurchasePads.evaluate(state, kind, id, #occupants)
	if not v.Ok then return false, v.Reason end
	if economy == nil then return false, UNAVAILABLE end
	--[[ EconomyService is the only writer of Essence, and TryDebit re-reads the balance inside
	     itself, which is what stops two pads triggered on the same frame spending it twice. A lost
	     race reads as insufficient, which is exactly what it was by the time the debit ran. ]]
	if not economy:TryDebit(sanctum, v.Cost) then return false, Reason.Insufficient end
	apply(state, kind, id)
	commit(sanctum)
	announce(sanctum, player, v)
	return true, Reason.Ok
end

function Service:PurchaseDropper(player: any, sanctum: any, id: any): (boolean, string)
	return buy(player, sanctum, "dropper", id)
end
function Service:PurchaseUpgrade(player: any, sanctum: any, id: any): (boolean, string)
	return buy(player, sanctum, "upgrade", id)
end
function Service:PurchaseSection(player: any, sanctum: any, id: any): (boolean, string)
	return buy(player, sanctum, "section", id)
end

--[[ One trigger, from a player who should be assumed hostile and standing somewhere they should not
     be. Underscored because it is the prompt's entry point, not part of the spec's API. ]]
function Service:_Trigger(sanctum: any, pad: any, prompt: any, kind: string, id: string,
	player: any): (boolean, string)
	-- 1. The prompt must still BE this pad's prompt, and the pad must still stand in this Sanctum.
	-- A pad on a Wing that has been reparented into ServerStorage fails here, which is what keeps a
	-- locked Wing's contents unbuyable even for something holding a stale prompt reference.
	if prompt.Parent ~= pad or not isUnder(pad, (sanctum :: any).Model) then return false, UNKNOWN_SANCTUM end
	if not isLivePlayer(player) then return false, NO_PLAYER end
	if kind == "link" then
		--[[ The ONE pad no occupancy check may gate: its entire purpose is a player from ANOTHER
		     Sanctum asking to join this one. PlotService:RequestLink re-checks everything that
		     matters -- who they are, whether leaving would strand a partner, whether a slot is free,
		     whether their save has even loaded -- and the occupants still have to consent. ]]
		if plots == nil then return false, UNAVAILABLE end
		return plots:RequestLink(player, sanctum)
	end
	local _, isOccupant = survey(sanctum, player)
	if not isOccupant then return false, NOT_OCCUPANT end
	if kind == "attune" or kind == "transcend" then
		--[[ Resolved LAZILY, never at Init: both services are registered AFTER this one, so a Get in
		     Init would error and abort the whole boot. Absent (a spec that booted neither) refuses
		     the ritual rather than erroring inside a prompt handler. ]]
		local peer = if registryRef ~= nil
			then registryRef:TryGet(if kind == "attune" then "EvolutionService" else "RebirthService")
			else nil
		if peer == nil then return false, UNAVAILABLE end
		-- Both re-validate from live state themselves; the pad is only the doorbell.
		return if kind == "attune" then peer:Attune(player, sanctum) else peer:BeginVote(player, sanctum)
	end
	--[[ Deliberately routed through the public method, which re-runs the live-player and occupancy
	     checks this handler just made. The duplication is the point: the public API is reachable
	     without a prompt, so it can never rely on a caller having gated for it. ]]
	return buy(player, sanctum, kind, id)
end

--[[ ServiceRegistry contract ]]

local function teardown(): ()
	for _, connection in ipairs(connections) do connection:Disconnect() end
	table.clear(connections)
end

function Service:Init(registry: any): ()
	registryRef = registry
	-- Resolved only: section 6 forbids cross-service calls during Init. All three are registered
	-- BEFORE this service, so Get is right here and a missing one is a Bootstrap bug worth erroring on.
	economy = registry:Get("EconomyService")
	plots = registry:Get("PlotService")
	remotes = registry:Get("RemoteService")
	-- A re-Init must not leave the previous boot's Triggered handlers alive: they capture the old
	-- Sanctums and would keep charging players against plots that no longer exist.
	teardown()
end

function Service:Start(): ()
	--[[ PlotService:Start runs first (registration order) and calls BuildPads for every Sanctum, so
	     this sweep normally finds every pad already prompted and only refreshes wording. It exists so
	     the pads are this service's own responsibility rather than a favour from its caller. ]]
	if plots ~= nil and type(plots.ForEachSanctum) == "function" then
		plots:ForEachSanctum(function(sanctum: any) Service:BuildPads(sanctum) end)
	end
end

function Service:Stop(): ()
	-- StopAll runs in reverse registration order, so this disconnects while PlotService's Sanctums
	-- (and their prompts) are still standing; PlotService then destroys the models themselves.
	teardown()
end

return Service
