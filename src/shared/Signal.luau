--!strict
--[[
    Signal
    A tiny dependency-free event object (Connect / Once / Fire / Wait / DisconnectAll / Destroy).
    Handlers are dispatched through task.spawn so a single erroring listener can never abort the
    dispatch loop or the code that fired the signal, and Fire iterates a snapshot so listeners may
    disconnect (or connect) themselves from inside a handler.
    Owner: shared  |  Consumers: ClientStore, ProfileService, PlotService, DropperSystem, MoteSystem
]]

type Handler = (...any) -> ()

local Connection = {}
Connection.__index = Connection

export type Connection = typeof(setmetatable(
	{} :: {
		Connected: boolean,
		_signal: any, -- back-reference to the owning Signal (any, to avoid a recursive type)
		_fn: Handler,
	},
	Connection
))

-- Disconnecting is idempotent: services tear down in arbitrary order and double-disconnects are
-- normal, so this must never error.
function Connection.Disconnect(self: Connection): ()
	if not self.Connected then
		return
	end
	self.Connected = false
	local signal = self._signal
	if signal ~= nil then
		local handlers = signal._handlers
		local index = table.find(handlers, self)
		if index ~= nil then
			table.remove(handlers, index)
		end
		self._signal = nil
	end
end

local Signal = {}
Signal.__index = Signal

export type Signal = typeof(setmetatable(
	{} :: {
		_handlers: { Connection },
		_destroyed: boolean,
	},
	Signal
))

function Signal.new(): Signal
	return setmetatable({
		_handlers = {},
		_destroyed = false,
	}, Signal)
end

function Signal.Connect(self: Signal, fn: Handler): Connection
	assert(type(fn) == "function", "Signal:Connect expects a function")
	local connection: Connection = setmetatable({
		Connected = true,
		_signal = self,
		_fn = fn,
	}, Connection)
	-- A destroyed signal hands back an already-dead connection instead of erroring: callers racing
	-- against shutdown should degrade quietly.
	if self._destroyed then
		connection.Connected = false
		connection._signal = nil
		return connection
	end
	table.insert(self._handlers, connection)
	return connection
end

function Signal.Once(self: Signal, fn: Handler): Connection
	assert(type(fn) == "function", "Signal:Once expects a function")
	local connection: Connection
	connection = self:Connect(function(...)
		-- Disconnect BEFORE invoking so a re-entrant Fire from inside fn cannot run it twice.
		connection:Disconnect()
		fn(...)
	end)
	return connection
end

function Signal.Fire(self: Signal, ...: any): ()
	-- Snapshot: handlers may Disconnect (or Connect) during dispatch, which mutates _handlers.
	local snapshot = table.clone(self._handlers)
	for _, connection in ipairs(snapshot) do
		-- Re-check Connected: an earlier handler in this same dispatch may have killed this one,
		-- and a disconnected listener must not observe the event.
		if connection.Connected then
			-- task.spawn isolates errors AND matches Roblox event semantics (handlers may yield
			-- without stalling the firer).
			task.spawn(connection._fn, ...)
		end
	end
end

-- Yields the calling thread until the next Fire and returns its arguments.
function Signal.Wait(self: Signal): ...any
	local thread = coroutine.running()
	local resumed = false
	self:Once(function(...)
		if resumed then
			return
		end
		resumed = true
		-- We are already inside a task.spawn'd thread here, so resuming the waiter directly is safe
		-- and avoids a polling loop (which would add a frame of latency to every Wait).
		local ok, err = coroutine.resume(thread, ...)
		if not ok then
			warn("[Signal] error after Wait resumed: " .. tostring(err))
		end
	end)
	return coroutine.yield()
end

function Signal.DisconnectAll(self: Signal): ()
	local snapshot = table.clone(self._handlers)
	table.clear(self._handlers)
	for _, connection in ipairs(snapshot) do
		connection.Connected = false
		connection._signal = nil
	end
end

function Signal.Destroy(self: Signal): ()
	self._destroyed = true
	self:DisconnectAll()
end

return Signal
