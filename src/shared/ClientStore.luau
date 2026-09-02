--!strict
--[[
    ClientStore
    The client's single copy of the server's StateSync snapshot (spec section 7), wrapped in an
    observable. Controllers never read a remote directly: they Observe("Plot.Stage") and get called
    once with the current value and again only when that value genuinely changes, which keeps the
    UI from rebuilding itself twice a second on essence-only ticks.
    Owner: shared (client-consumed)  |  Consumers: ClientBootstrap and every client Controller
]]

local Signal = require(script.Parent.Signal)
local TableUtil = require(script.Parent.TableUtil)

export type Snapshot = { [string]: any }

local ClientStore = {}
ClientStore.__index = ClientStore

export type Store = typeof(setmetatable(
	{} :: {
		Changed: Signal.Signal, -- (newSnapshot, oldSnapshot)
		_state: Snapshot,
	},
	ClientStore
))

-- WHY a hand-built default instead of `{}`: every controller runs its first layout pass BEFORE the
-- first StateSync arrives. Handing them a snapshot of the correct SHAPE (section 7, with Full=false
-- and Essence=0) means no controller needs a nil check, and the HUD renders a clean zeroed state
-- instead of flickering placeholder text. Nothing here is a claim about the real save -- it is
-- deliberately the emptiest legal snapshot.
local function defaultSnapshot(): Snapshot
	return {
		Full = false, -- nothing authoritative has arrived yet
		Tick = 0,
		Essence = 0,
		Plot = {
			Id = 0,
			Stage = 1,
			Affinity = nil,
			-- Empty, NOT pre-seeded with the base Wing: before the first snapshot the client knows
			-- nothing, and pretending a Wing is unlocked would light up pads the server may reject.
			Droppers = {},
			Upgrades = {},
			Sections = {},
			LifetimeEssence = 0,
			IncomePerSecond = 0,
			Multiplier = 1,
			MoteCount = 0,
			MoteCapacity = 0,
		},
		Occupants = {},
		You = {
			Rebirths = 0,
			Multiplier = 1,
			Badges = {},
			Settings = { Music = true, Sfx = true },
			TotalEssenceEarned = 0,
			Slot = 0,
		},
		Gates = {
			-- Reason codes are the closed set Economy returns. "need_essence"/"need_stage" are the
			-- honest pre-connection answer: we have no essence and no stage yet.
			Attune = { Ok = false, Reason = "need_essence", Cost = 0, NextStage = nil },
			Transcend = { Ok = false, Reason = "need_stage" },
			Affinity = { Available = false, Chosen = nil },
		},
	}
end

function ClientStore.new(): Store
	return setmetatable({
		Changed = Signal.new(),
		_state = defaultSnapshot(),
	}, ClientStore)
end

-- Split "Plot.Stage" into { "Plot", "Stage" }. An empty path means "the whole snapshot"; a
-- non-string path yields no segments rather than erroring, so GetPath stays total.
local function splitPath(path: any): { string }
	local parts: { string } = {}
	if type(path) ~= "string" then
		return parts
	end
	for segment in string.gmatch(path, "[^%.]+") do
		table.insert(parts, segment)
	end
	return parts
end

local function resolve(root: any, parts: { string }): any
	local node: any = root
	for _, segment in ipairs(parts) do
		if type(node) ~= "table" then
			-- A missing branch is normal (Gates only exists on Full snapshots), never an error.
			return nil
		end
		local child = node[segment]
		if child == nil then
			-- Occupants is an array, so "Occupants.1.Name" arrives with a string "1". Fall back to
			-- the numeric key so array paths are observable like any other.
			local index = tonumber(segment)
			child = if index ~= nil then node[index] else nil
		end
		node = child
	end
	return node
end

-- Scalars compare with ==; tables need a structural compare because the server rebuilds the
-- Droppers/Upgrades/Sections tables on every Full snapshot, so identity always differs.
local function sameValue(a: any, b: any): boolean
	if type(a) == "table" and type(b) == "table" then
		return TableUtil.deepEquals(a, b)
	end
	return a == b
end

-- Cached observer values must be immune to later mutation of the snapshot they came from, so table
-- values are stored as a deep copy. Scalars are already immutable and copy for free.
local function cacheValue(value: any): any
	if type(value) == "table" then
		return TableUtil.deepCopy(value)
	end
	return value
end

--[[
    Replace the current snapshot and notify observers.

    SPEC NOTE: section 7 splits StateSync into a Full snapshot and an essence-only fast tick
    (Full=false). Literally replacing the state with a fast tick would wipe Plot/Occupants/Gates
    twice a second and thrash every observer, so: a Full payload REPLACES the snapshot (the server
    is the sole authority on what exists), while a delta is layered over the retained snapshot by
    top-level key. Either way the old table is never mutated, so `oldSnapshot` stays valid for
    Changed listeners and for cached observer values.
]]
function ClientStore.Set(self: Store, snapshot: Snapshot): ()
	if type(snapshot) ~= "table" then
		-- Loud but not fatal. This only happens if the server sends a malformed StateSync, and a
		-- frozen HUD would be a worse outcome than a stale one plus a log line.
		warn("[ClientStore] ignoring a non-table snapshot of type " .. typeof(snapshot))
		return
	end

	local old = self._state
	local new: Snapshot
	if snapshot.Full == true then
		-- Copy so a caller that recycles its payload table cannot mutate our state behind our back.
		new = TableUtil.deepCopy(snapshot)
	else
		new = TableUtil.shallowCopy(old)
		for key, value in pairs(snapshot) do
			new[key] = value
		end
		new.Full = false
	end

	self._state = new
	self.Changed:Fire(new, old)
end

-- Never nil. Callers must treat the result as read-only: it is the live table, not a copy, because
-- copying it on every HUD frame would be pure garbage churn.
function ClientStore.Get(self: Store): Snapshot
	return self._state
end

function ClientStore.GetPath(self: Store, path: string): any
	return resolve(self._state, splitPath(path))
end

--[[
    Observe one dotted path. `fn` is called immediately with the current value, then again only when
    the value at that path actually changes.

    The immediate call is SYNCHRONOUS on purpose: a controller must be able to build its widgets
    from the current value before Observe returns. Subsequent calls ride Signal:Fire, which
    task.spawns each handler, so a slow or erroring observer cannot stall replication.
]]
function ClientStore.Observe(self: Store, path: string, fn: (value: any) -> ()): Signal.Connection
	assert(type(fn) == "function", "ClientStore:Observe expects a function")

	local parts = splitPath(path)
	local last = resolve(self._state, parts)
	local cached = cacheValue(last)

	local connection = self.Changed:Connect(function(newSnapshot: Snapshot)
		local value = resolve(newSnapshot, parts)
		if sameValue(value, cached) then
			return
		end
		cached = cacheValue(value)
		fn(value)
	end)

	-- Mirror Signal's error isolation for the immediate call: one bad controller must not prevent
	-- the rest of the UI from being wired up.
	local ok, err = pcall(fn, last)
	if not ok then
		warn("[ClientStore] observer for '" .. path .. "' errored on its first call: " .. tostring(err))
	end

	return connection
end

function ClientStore.Destroy(self: Store): ()
	self.Changed:Destroy()
end

return ClientStore
