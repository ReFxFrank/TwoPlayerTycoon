--!strict
--[[
    ServiceRegistry
    The server's dependency container and boot orchestrator. Services register themselves by name in
    Bootstrap and are then driven through three ordered phases: Init (resolve peers, build state),
    Start (connect events, start loops) and Stop (tear down, in reverse). Splitting Init from Start
    is what lets two services depend on each other without a circular require -- Init may only store
    references, so by the time any Start runs every peer already exists and is initialised.
    Owner: server  |  Consumers: Bootstrap.server.luau and every module under src/server/Services
]]

-- A service is a plain table (spec section 6) and the registry deliberately knows nothing about what
-- is inside one, so every lifecycle method is optional and resolved dynamically at call time.
type Service = { [string]: any }

local Registry = {}
Registry.__index = Registry

type Registry = typeof(setmetatable(
	{} :: {
		_services: { [string]: Service },
		_order: { string }, -- registration order IS boot order; StopAll walks it backwards
		_initialised: boolean,
		_started: boolean,
		_stopped: boolean,
	},
	Registry
))

-- Rendered into every "missing service" error, so the fix is visible without opening Bootstrap.
local function describe(self: Registry): string
	if #self._order == 0 then
		return "<nothing registered>"
	end
	return table.concat(self._order, ", ")
end

--[[ Runs one lifecycle method across `names`, in the order given, and returns the failures.
     Every call is pcall'd because the alternative -- letting the first broken service throw --
     hides every later failure behind it, turning a boot into a whack-a-mole restart loop. One run
     should report everything that is wrong. ]]
local function runPhase(self: Registry, methodName: string, names: { string }, argument: any): { string }
	local failures: { string } = {}

	for _, name in ipairs(names) do
		local service = self._services[name]
		local method = service[methodName]

		if type(method) == "function" then
			local ok, err = pcall(method, service, argument)
			if not ok then
				local detail = string.format("%s:%s() -> %s", name, methodName, tostring(err))
				warn("[ServiceRegistry] " .. detail)
				table.insert(failures, detail)
			end
		elseif method ~= nil then
			-- A non-function Init/Start is always a typo (`Service.Start = true`), never intent.
			-- Silently skipping it would leave the service permanently unstarted.
			local detail = string.format("%s.%s is a %s, not a function", name, methodName, typeof(method))
			warn("[ServiceRegistry] " .. detail)
			table.insert(failures, detail)
		end
	end

	return failures
end

local function raiseIfFailed(phase: string, failures: { string }): ()
	if #failures == 0 then
		return
	end
	-- Re-raised AFTER every service has been given its chance: a half-booted server (a live
	-- PlotService with no EconomyService behind it) corrupts saves, which is strictly worse than a
	-- server that refuses to start. Level 0 because the useful position is in the list, not here.
	local list = table.concat(failures, "\n  ")
	error(string.format("ServiceRegistry:%s failed for %d service(s):\n  %s", phase, #failures, list), 0)
end

function Registry.new(): Registry
	return setmetatable({
		_services = {},
		_order = {},
		_initialised = false,
		_started = false,
		_stopped = false,
	}, Registry)
end

--[[ Registration order is the boot order, so this call site is also where a service declares its
     position in the dependency chain. ]]
function Registry.Register(self: Registry, name: string, service: any): ()
	if type(name) ~= "string" or name == "" then
		-- An empty or non-string name registers a service that nothing can ever Get back.
		error("ServiceRegistry:Register expects a non-empty string name, got " .. typeof(name), 2)
	end
	if type(service) ~= "table" then
		error(string.format("ServiceRegistry:Register('%s') expects a table, got %s", name, typeof(service)), 2)
	end
	if self._services[name] ~= nil then
		-- Overwriting would leave the first copy in _order and already wired into whichever peers
		-- resolved it, so two live instances of one service would run side by side forever.
		error(string.format("ServiceRegistry: '%s' is already registered", name), 2)
	end
	if self._initialised then
		-- A late registration never receives Init or Start, so its state stays nil and the mistake
		-- surfaces much later as an unrelated nil index in gameplay code. Fail at the cause.
		error(string.format("ServiceRegistry: cannot register '%s' after InitAll", name), 2)
	end

	-- Service.Name is cosmetic (it only appears in logs), so a mismatch warns rather than stops --
	-- but it almost always means a service module was copy-pasted and its Name left behind.
	local declared = (service :: Service).Name
	if type(declared) == "string" and declared ~= name then
		warn(string.format("[ServiceRegistry] registered '%s' but it declares Name = '%s'", name, declared))
	end

	self._services[name] = service
	table.insert(self._order, name)
end

--[[ Errors instead of returning nil: a mistyped dependency name would otherwise surface as a nil
     index deep inside gameplay code, minutes after boot and nowhere near the typo. ]]
function Registry.Get(self: Registry, name: string): any
	local service = if type(name) == "string" then self._services[name] else nil
	if service == nil then
		error(
			string.format(
				"ServiceRegistry: no service named '%s'. Registered (in boot order): %s",
				tostring(name),
				describe(self)
			),
			2
		)
	end
	return service
end

--[[ The nil-tolerant twin, for genuinely optional peers (a service that enhances another when it is
     present). Never use it to paper over a missing required dependency -- that is what Get is for,
     and swallowing that mistake is exactly what Get's error message exists to prevent. ]]
function Registry.TryGet(self: Registry, name: string): any?
	if type(name) ~= "string" then
		return nil
	end
	return self._services[name]
end

--[[ A second InitAll is refused, not absorbed. Init allocates state and resolves peers, so it is
     not idempotent for most services -- a silent no-op would hide a genuine Bootstrap bug, and
     re-running would hand every service a second copy of its own state. Nothing is re-run either
     way; the error is what makes the mistake visible. ]]
function Registry.InitAll(self: Registry): ()
	if self._initialised then
		error("ServiceRegistry:InitAll called twice -- Init is not idempotent for most services", 2)
	end
	-- Flagged BEFORE the phase runs: if a service throws, a retry would re-Init everything that
	-- already succeeded, which is the double-Init this flag exists to prevent.
	self._initialised = true

	raiseIfFailed("InitAll", runPhase(self, "Init", self._order, self))
end

function Registry.StartAll(self: Registry): ()
	if not self._initialised then
		-- Not the same case as a double call: Start may talk to peers, and a peer that never ran
		-- Init has nil state. A phase ordering mistake in Bootstrap must be loud.
		error("ServiceRegistry:StartAll called before InitAll", 2)
	end
	if self._started then
		-- Start connects events and opens loops; a replay would double-wire every one of them.
		error("ServiceRegistry:StartAll called twice -- Start connects events and would double-wire", 2)
	end
	self._started = true

	raiseIfFailed("StartAll", runPhase(self, "Start", self._order, nil))
end

--[[ Reverse order, so a service is stopped before anything it depends on: the last-registered (most
     dependent) service gets its chance to flush while its peers are still alive.
     Unlike Init/Start this never re-raises. StopAll runs from BindToClose, where throwing would
     abort whatever the caller still has to do -- ProfileService's final SaveAll runs from the same
     shutdown path, and losing player data to a tidy error report is a bad trade. ]]
function Registry.StopAll(self: Registry): ()
	if self._stopped then
		-- Shutdown is racy: BindToClose and an explicit teardown can both reach here. A second call
		-- is a no-op rather than an error, because erroring during shutdown helps nobody.
		return
	end
	self._stopped = true

	local reversed: { string } = {}
	for index = #self._order, 1, -1 do
		table.insert(reversed, self._order[index])
	end

	runPhase(self, "Stop", reversed, nil)
end

return Registry
