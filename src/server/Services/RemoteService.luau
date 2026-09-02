--!strict
--[[
    RemoteService
    The one door a client -> server message walks through. It builds the SanctumRemotes folder and
    every RemoteEvent RemoteSchema declares, then funnels every inbound event into a single guarded
    dispatcher: check the sender, spend a rate-limit token, validate the payload, and only then call
    the registered handler -- inside a pcall, so one service erroring on one player's payload cannot
    take the remote down for everybody else. Outbound sends are name- and direction-checked against
    the same schema, so a typo is a boot-time error, not a message that silently never arrives.
    Owner: server/Services  |  Consumers: every service that talks to a client, RateLimiter, tests
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local RemoteSchema = require(Modules:WaitForChild("RemoteSchema"))

-- Spec section 3.1: a connection is anything with :Disconnect(). Structural, so this behaves
-- identically under RBXScriptConnection and under the headless mock.
type Connection = { Disconnect: (self: any) -> () }
type Handler = (player: Player, payload: any) -> ()

-- A local mirror of RemoteSchema.RemoteDef rather than an import: the test bundler strips `export`
-- from type aliases, so a cross-module type reference would not resolve inside the harness.
type RemoteDef = {
	Name: string,
	Direction: string,
	RateLimit: { Tokens: number, Interval: number }?,
	Validate: ((payload: any) -> (boolean, string?))?,
}

local C2S = "ClientToServer"
local S2C = "ServerToClient"

--[[ A rejected call is one an exploiter can repeat as fast as the network allows. Counting each is
     cheap; PRINTING each is not -- an unthrottled warn turns a spam loop into a log flood, a denial
     of service against the server's own output. The counter always increments; only the line is
     rationed, to one per player per this many seconds. ]]
local WARN_INTERVAL = 10

--[[ Rejection bucket for anything that is not a live player: a garbage first argument, or a stale
     Player whose PlayerRemoving has already run. Neither can be cleaned up later, so keying them by
     real UserId would re-create entries nothing ever removes -- one slow leak per departed player.
     One shared bucket is bounded by the closed set of remote names instead. ]]
local UNKNOWN_SENDER = 0

local Service = {}
Service.Name = "RemoteService"

-- The clock behind the warn throttle, read through this field so tests can substitute it. tick() is
-- the clock the headless harness can advance; its backwards jumps are handled in noteRejection.
Service.Clock = tick

Service._rateLimiter = nil :: any
Service._folder = nil :: any
Service._remotes = {} :: { [string]: any }
Service._handlers = {} :: { [string]: Handler }
Service._connections = {} :: { Connection }
Service._rejections = {} :: { [number]: { [string]: number } }
Service._lastWarn = {} :: { [number]: number }

--[[ True only for a player the server can still reach. `Parent ~= Players` is the O(1) form of
     "still in Players" -- engine and mock both unparent a Player after PlayerRemoving. The
     typeof/IsA pair in front is what makes it total: Mock.fireServer will hand this a nil, a string
     or a table, and indexing .Parent on those would throw inside the dispatcher. ]]
local function isLivePlayer(player: any): boolean
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players
end

-- Record one rejection and, at most once per player per WARN_INTERVAL, say so. `reason` is for the
-- SERVER log only: telling an exploiter which gate stopped them is free reconnaissance.
local function noteRejection(self: any, userId: number, remoteName: string, reason: string): ()
	local byRemote = self._rejections[userId]
	if byRemote == nil then
		byRemote = {}
		self._rejections[userId] = byRemote
	end
	byRemote[remoteName] = (byRemote[remoteName] or 0) + 1

	local now = Service.Clock()
	local last = self._lastWarn[userId]
	-- `now < last` means the clock jumped backwards (tick() follows the host wall clock); warn and
	-- re-anchor, because a bare `now - last < WARN_INTERVAL` would mute the log for the whole jump.
	if last ~= nil and now >= last and now - last < WARN_INTERVAL then
		return
	end
	self._lastWarn[userId] = now
	warn(string.format("[RemoteService] rejected %s from userId %d: %s", remoteName, userId, reason))
end

-- The guarded path every inbound message takes. It NEVER errors (an error unwinds the shared
-- OnServerEvent thread) and NEVER replies (a reply leaks which gate closed).
local function dispatch(self: any, def: RemoteDef, player: any, payload: any): ()
	-- 1. Sender. The engine supplies this argument, but a stale reference still arrives: an event
	-- queued just before a disconnect is delivered just after it, and passing that on would hand a
	-- service a Player with no profile, no sanctum and no character to act on.
	if not isLivePlayer(player) then
		noteRejection(self, UNKNOWN_SENDER, def.Name, "sender is not a live player")
		return
	end
	-- A non-number UserId cannot happen on a real Player, but the rejection table is keyed by it and
	-- `t[nil] = v` throws -- exactly the crash this dispatcher exists to prevent.
	local raw = player.UserId
	local userId: number = if type(raw) == "number" then raw else UNKNOWN_SENDER

	-- An inbound def missing either piece is a RemoteSchema bug. Fail closed rather than skipping
	-- the missing check: a visibly dead feature beats an unthrottled or unvalidated front door.
	local budget, validate = def.RateLimit, def.Validate
	if budget == nil or validate == nil then
		noteRejection(self, userId, def.Name, "schema entry has no rate limit or validator")
		return
	end

	-- 2. Rate limit BEFORE validation: validation is the more expensive of the two, so a flood is
	-- dropped at the cheapest point on the path.
	if not self._rateLimiter:Consume(player, def.Name, budget.Tokens, budget.Interval) then
		noteRejection(self, userId, def.Name, "rate limited")
		return
	end

	-- 3. Payload. RemoteSchema already wraps every validator so it cannot throw; the pcall is here
	-- because RemoteService must not depend on another module keeping that promise -- an error
	-- escaping a validator would abort this thread and skip the accounting below.
	local ran, accepted, why = pcall(validate, payload)
	if not ran then
		noteRejection(self, userId, def.Name, "validator errored")
		return
	elseif accepted ~= true then
		noteRejection(self, userId, def.Name, if type(why) == "string" then why else "invalid payload")
		return
	end

	-- 4. Nothing has claimed this remote. Counted rather than ignored: during boot that is normal
	-- (RemoteService starts before its consumers), but forever is a dead feature worth seeing.
	local handler = self._handlers[def.Name]
	if handler == nil then
		noteRejection(self, userId, def.Name, "no handler registered")
		return
	end

	-- 5. The handler is another service's code reached from the network edge. Isolate it. Not
	-- throttled like the rejection warns: an erroring handler is a server bug worth seeing every
	-- time, and step 2 already caps how often one player can provoke it.
	local ok, err = pcall(handler, player, payload)
	if not ok then
		warn(string.format("[RemoteService] handler for %s errored: %s", def.Name, tostring(err)))
	end
end

--[[ Resolve an outbound remote, erroring on a name that is unknown or inbound. Outbound names are
     server-authored constants, so a wrong one is a typo, and the ServiceRegistry:Get reasoning
     applies: returning nil would make it a message that silently never reaches the client and is
     noticed days later. Level 3 puts the blame on Fire*'s caller. ]]
local function outbound(self: any, name: string, caller: string): any
	local def: RemoteDef? = RemoteSchema.get(name)
	if def == nil or def.Direction ~= S2C then
		local why = if def == nil then "no such remote in RemoteSchema" else "that remote is inbound"
		error(string.format("RemoteService:%s('%s'): %s", caller, tostring(name), why), 3)
	end
	local remote = self._remotes[name]
	if remote == nil then
		error(string.format("RemoteService:%s('%s'): remote missing -- Init has not run", caller, name), 3)
	end
	return remote
end

--[[ `parent`'s child of `className` named `name`, created only if it is not already there.
     Reuse is the point: after a soft restart every connected client still holds references to these
     instances, and rebuilding them would leave those clients listening to dead remotes with nothing
     to signal the change. A squatter of the wrong class is destroyed instead -- it would make the
     client's WaitForChild resolve to something unusable, presenting as a hung client. ]]
local function ensureChild(parent: any, className: string, name: string): any
	local existing = parent:FindFirstChild(name)
	if existing ~= nil then
		if existing:IsA(className) then
			return existing
		end
		existing:Destroy()
	end
	local created = Instance.new(className)
	created.Name = name
	-- Parented last, so a client's WaitForChild can only ever resolve a fully built instance.
	created.Parent = parent
	return created
end

function Service:_disconnectAll(): ()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	table.clear(self._connections)
end

function Service:Init(registry: any): ()
	self._rateLimiter = registry:Get("RateLimiter")
	-- A re-Init must not inherit live connections from the previous run: an orphaned OnServerEvent
	-- handler would keep dispatching into the discarded handler table forever.
	self:_disconnectAll()
	self._handlers = {}
	self._rejections = {}
	self._lastWarn = {}
	self._remotes = {}

	self._folder = ensureChild(ReplicatedStorage, "Folder", RemoteSchema.FolderName)
	--[[ ipairs over RemoteSchema.List, never pairs over .Remotes: `pairs` order is unspecified, and
	     the List is sorted so every server -> client remote is created FIRST, so a client already
	     listening cannot miss an early push while the inbound events are still being made. ]]
	for _, def in ipairs(RemoteSchema.List :: { RemoteDef }) do
		self._remotes[def.Name] = ensureChild(self._folder, "RemoteEvent", def.Name)
	end
end

function Service:Start(): ()
	for _, def in ipairs(RemoteSchema.List :: { RemoteDef }) do
		local remote = self._remotes[def.Name]
		if def.Direction ~= C2S or remote == nil then
			continue
		end
		-- Arguments past the first are dropped rather than rejected: the handler signature is fixed
		-- at (player, payload), so a smuggled extra has nowhere to arrive.
		local connection = remote.OnServerEvent:Connect(function(player: any, payload: any)
			dispatch(self, def, player, payload)
		end)
		table.insert(self._connections, connection)
	end

	-- Without this the rejection and warn-throttle tables keep one entry per departed player for the
	-- lifetime of the server.
	local removing = Players.PlayerRemoving:Connect(function(player: Player)
		local userId = player.UserId
		if type(userId) == "number" then
			self._rejections[userId] = nil
			self._lastWarn[userId] = nil
		end
	end)
	table.insert(self._connections, removing)
end

-- Disconnects only. The folder and its remotes deliberately survive, so a Stop/Init cycle does not
-- invalidate the references every connected client is already holding.
function Service:Stop(): ()
	self:_disconnectAll()
end

--[[ Claim a client -> server remote. Every refusal here is a mistake made at boot by trusted code,
     so it errors rather than returning false: a silent no-op would leave a feature permanently
     unreachable with nothing in the log to say why. ]]
function Service:On(name: string, handler: Handler): ()
	local def: RemoteDef? = RemoteSchema.get(name)
	if def == nil or def.Direction ~= C2S then
		local why = if def == nil then "no such remote in RemoteSchema" else "that remote is outbound"
		error(string.format("RemoteService:On('%s'): %s", tostring(name), why), 2)
	end
	if type(handler) ~= "function" then
		error(string.format("RemoteService:On('%s') expects a function, got %s", name, typeof(handler)), 2)
	end
	if self._handlers[name] ~= nil then
		-- Two handlers on one remote has no good reading: either the second replaces the first (a
		-- feature stops working) or both run (every payload processed twice, once per service).
		error(string.format("RemoteService:On('%s'): a handler is already registered", name), 2)
	end
	self._handlers[name] = handler
end

--[[ A player can leave between the decision to send and the send -- a reply to their own remote, a
     queued notification, a broadcast to a list built a frame ago. That race is unavoidable, so a
     departed target is skipped silently; only a bad NAME is an error. ]]
function Service:FireClient(player: Player, name: string, payload: any): ()
	local remote = outbound(self, name, "FireClient")
	if not isLivePlayer(player) then
		return
	end
	remote:FireClient(player, payload)
end

function Service:FireClients(players: { Player }, name: string, payload: any): ()
	local remote = outbound(self, name, "FireClients")
	-- A non-table list is a caller reading an empty sanctum; nothing to send is not an error.
	if type(players) ~= "table" then
		return
	end
	for _, player in ipairs(players) do
		if isLivePlayer(player) then
			remote:FireClient(player, payload)
		end
	end
end

function Service:FireAllClients(name: string, payload: any): ()
	outbound(self, name, "FireAllClients"):FireAllClients(payload)
end

-- nil for an unknown name rather than an error: "does this remote exist" is a fair question, and
-- this is the lookup tests and client-facing code use to answer it.
function Service:GetRemote(name: string): RemoteEvent?
	if type(name) ~= "string" then
		return nil
	end
	return self._remotes[name]
end

--[[ userId -> remote name -> rejection count. Copied, not handed out live: a telemetry reader that
     mutated the table would corrupt the counters it is reading. userId 0 collects everything not
     attributable to a live player -- see UNKNOWN_SENDER. ]]
function Service:GetRejectionStats(): { [number]: { [string]: number } }
	local copy: { [number]: { [string]: number } } = {}
	for userId, byRemote in pairs(self._rejections) do
		copy[userId] = table.clone(byRemote)
	end
	return copy
end

-- The warn throttle is cleared alongside the counters: a stale timestamp would otherwise mute the
-- first warning of the next test or telemetry window for up to WARN_INTERVAL seconds.
function Service:ResetRejectionStats(): ()
	table.clear(self._rejections)
	table.clear(self._lastWarn)
end

return Service
