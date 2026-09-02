--!strict
--[[
    DataStoreWrapper
    The single choke point for every DataStore call the server makes. It memoises store handles,
    waits for request budget, retries transient failures on a jittered exponential backoff and
    classifies everything else as fatal -- and it NEVER throws: each entry point answers
    (ok, valueOrError) so a DataStore outage cannot escape into a PlayerRemoving handler or a
    BindToClose save and take the rest of the shutdown down with it.
    Owner: server/Services  |  Consumers: ProfileService (and any future service that persists data)
]]

local DataStoreService = game:GetService("DataStoreService")

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local GameConfig = require(Modules:WaitForChild("GameConfig"))

-- A GlobalDataStore handle. Kept opaque: the harness supplies a stand-in with the same four
-- methods, and pinning a Roblox-only type here would make this module unloadable headlessly.
type Store = any

type Counters = {
	Attempts: number, -- individual DataStore calls issued
	FailedAttempts: number, -- calls that threw, transient or fatal
	Failures: number, -- OPERATIONS that ran out of retries and returned false
	Retries: number, -- backoff sleeps taken, i.e. attempts beyond the first
	BudgetWaits: number, -- polls spent waiting for request budget to refill
}

local BACKOFF: { number } = GameConfig.Save.RetryBackoff -- { 1, 2, 4, 8, 16 }
local JITTER: number = GameConfig.Save.RetryJitter -- +/-20%
local DEFAULT_MAX_ATTEMPTS = 5

-- Poll rather than sleep the whole budget: Roblox refills continuously. The CAP is the important
-- half -- a permanently starved budget must not park a shutdown save forever, so past it the
-- attempt is spent anyway and the call fails honestly, still inside BindToClose's 30s kill.
local BUDGET_POLL_SECONDS = 0.5
local MAX_BUDGET_WAIT_SECONDS = 4

-- Roblox rejects keys over 50 UTF-8 bytes with a fatal error; catching it here costs no request.
local MAX_KEY_LENGTH = 50

-- Substrings (case-insensitive, plain -- not Lua patterns) marking a failure worth retrying.
-- Everything else -- an unserialisable value, a size limit, a bug in a caller's transform -- is
-- deterministic: five attempts fail five times and burn budget the OTHER players' saves need.
local TRANSIENT_PATTERNS = {
	"throttl", -- "Number of requests exceeded limit" family
	"timeout",
	"request was queued", -- Roblox's own "please retry" wording
	"internal", -- "InternalError" / "internal server error"
	"502",
	"503",
	"temporarily",
	-- A bare "request failed" with no further detail is the generic transport-level error Roblox
	-- reports for a dropped HTTP call to the DataStore backend; that is transient by definition.
	"request failed",
}

local REQUEST_GET = Enum.DataStoreRequestType.GetAsync
-- SetAsync, IncrementAsync and RemoveAsync all draw from the same SetIncrementAsync pool.
local REQUEST_SET = Enum.DataStoreRequestType.SetIncrementAsync
local REQUEST_UPDATE = Enum.DataStoreRequestType.UpdateAsync

local Service = {}
Service.Name = "DataStoreWrapper"

-- Attempts and FailedAttempts count individual round trips; Failures counts OPERATIONS that ran
-- out of retries and returned false. Failures is the number worth alerting on -- a server that
-- retried 400 times and never lost a save is healthy, one with a single Failure is not.
Service.Stats = {
	Attempts = 0,
	FailedAttempts = 0,
	Failures = 0,
	Retries = 0,
	BudgetWaits = 0,
} :: Counters

Service.MaxAttempts = DEFAULT_MAX_ATTEMPTS

local stores: { [string]: Store } = {}
-- Own RNG so jitter never perturbs the global math.random sequence other systems (mote paths,
-- autosave jitter) draw from, which would make their tests non-reproducible.
local rng = Random.new(os.time())
local warnedStoreFailure = false

local function isTransient(err: any): boolean
	if type(err) ~= "string" then
		-- A thrown table (only reachable through a caller's UpdateAsync transform) carries no
		-- message to classify. Retrying a deterministic bug 5x helps nobody, so: fatal.
		return false
	end
	local lowered = string.lower(err)
	for _, needle in ipairs(TRANSIENT_PATTERNS) do
		if string.find(lowered, needle, 1, true) ~= nil then
			return true
		end
	end
	return false
end

-- Delay AFTER attempt `attempt`, jittered so a server full of players whose saves failed on the
-- same outage does not stampede the backend in lockstep on every retry.
local function backoffFor(attempt: number): number
	local base = BACKOFF[math.min(attempt, #BACKOFF)] or 1
	local spread = base * JITTER
	return math.max(base + rng:NextNumber(-spread, spread), 0)
end

-- Returns the total seconds spent waiting so far, so the cap applies to the whole operation
-- rather than resetting on every attempt.
local function awaitBudget(requestType: any, alreadySpent: number): number
	local spent = alreadySpent
	while spent < MAX_BUDGET_WAIT_SECONDS do
		local ok, budget = pcall(function()
			return DataStoreService:GetRequestBudgetForRequestType(requestType)
		end)
		-- If the budget API itself is unavailable we proceed blind: a missing forecast is not a
		-- reason to refuse to save, and the call below will report the real error if there is one.
		if not ok or type(budget) ~= "number" or budget > 0 then
			return spent
		end
		Service.Stats.BudgetWaits += 1
		task.wait(BUDGET_POLL_SECONDS)
		spent += BUDGET_POLL_SECONDS
	end
	return spent
end

local function perform(requestType: any, call: () -> any): (boolean, any)
	local stats = Service.Stats
	local maxAttempts = math.max(Service.MaxAttempts, 1)
	local budgetSpent = 0
	local lastError: any = "DataStoreWrapper: no attempt was made"

	for attempt = 1, maxAttempts do
		budgetSpent = awaitBudget(requestType, budgetSpent)
		stats.Attempts += 1
		local ok, result = pcall(call)
		if ok then
			return true, result
		end
		stats.FailedAttempts += 1
		lastError = result
		if not isTransient(result) then
			stats.Failures += 1
			return false, result
		end
		-- No sleep after the final attempt: the caller is already out of retries and, on a
		-- shutdown path, every second of it is stolen from the next player's save.
		if attempt < maxAttempts then
			stats.Retries += 1
			task.wait(backoffFor(attempt))
		end
	end

	stats.Failures += 1
	return false, lastError
end

-- One guard for all four entry points: resolve the handle (a store NAME is accepted too, so a
-- caller holding only the configured name need not memoise it itself) and reject a key Roblox
-- would fatally refuse -- catching that here costs no request budget.
local function prepare(store: Store, key: any): (Store, string?)
	local ds = if type(store) == "string" then Service:GetStore(store) else store
	if ds == nil then
		return nil, "DataStoreWrapper: no datastore handle"
	end
	if type(key) ~= "string" or #key == 0 then
		return nil, "DataStoreWrapper: key must be a non-empty string"
	end
	if #key > MAX_KEY_LENGTH then
		return nil, ("DataStoreWrapper: key exceeds %d characters"):format(MAX_KEY_LENGTH)
	end
	return ds
end

--[[ Public API ]]

-- Memoised: DataStoreService:GetDataStore allocates a fresh handle per call, and ProfileService
-- asks for the same store on every join, save and release.
function Service:GetStore(name: string?): Store
	local storeName = if type(name) == "string" and #name > 0 then name else GameConfig.Save.DataStoreName
	local cached = stores[storeName]
	if cached ~= nil then
		return cached
	end
	-- GetDataStore throws in Studio without API access, and in a place where DataStores are
	-- disabled. Returning nil (instead of propagating) keeps that failure inside the (ok, err)
	-- contract below, where ProfileService already knows how to fall back to a no-save profile.
	local ok, store = pcall(function()
		return DataStoreService:GetDataStore(storeName)
	end)
	if not ok or store == nil then
		if not warnedStoreFailure then
			warnedStoreFailure = true -- once per server: this fails identically on every call
			warn(("[DataStoreWrapper] GetDataStore(%q) failed: %s"):format(storeName, tostring(store)))
		end
		return nil
	end
	stores[storeName] = store
	return store
end

function Service:Get(store: Store, key: string): (boolean, any)
	local ds, err = prepare(store, key)
	if ds == nil then
		return false, err
	end
	return perform(REQUEST_GET, function()
		return ds:GetAsync(key)
	end)
end

function Service:Set(store: Store, key: string, value: any): (boolean, any)
	local ds, err = prepare(store, key)
	if ds == nil then
		return false, err
	end
	if value == nil then
		-- SetAsync(nil) is a fatal error in Roblox; callers that mean "delete" want :Remove.
		return false, "DataStoreWrapper: value must not be nil (use :Remove)"
	end
	return perform(REQUEST_SET, function()
		return ds:SetAsync(key, value)
	end)
end

-- The transform runs once per ATTEMPT, so callers must keep it idempotent and free of side
-- effects outside the value it returns.
function Service:Update(store: Store, key: string, transform: (any) -> any): (boolean, any)
	local ds, err = prepare(store, key)
	if ds == nil then
		return false, err
	end
	if type(transform) ~= "function" then
		return false, "DataStoreWrapper: transform must be a function"
	end
	return perform(REQUEST_UPDATE, function()
		return ds:UpdateAsync(key, transform)
	end)
end

function Service:Remove(store: Store, key: string): (boolean, any)
	local ds, err = prepare(store, key)
	if ds == nil then
		return false, err
	end
	return perform(REQUEST_SET, function()
		return ds:RemoveAsync(key)
	end)
end

-- Lower this on the shutdown path. BindToClose has a HARD 30s budget (the server is killed
-- regardless of what the handler is doing) and the full 5-attempt schedule sleeps 15s for ONE key,
-- so a server full of failing saves needs a shorter schedule, not a longer wait.
function Service:SetMaxAttempts(n: number): ()
	if type(n) ~= "number" or n ~= n then -- n ~= n catches NaN, which would make math.clamp lie
		return
	end
	Service.MaxAttempts = math.clamp(math.floor(n), 1, #BACKOFF + 1)
end

-- A copy: callers (tests, telemetry) must not be able to reset the live counters by writing to
-- the table they were handed.
function Service:GetStats(): Counters
	local stats = Service.Stats
	return {
		Attempts = stats.Attempts,
		FailedAttempts = stats.FailedAttempts,
		Failures = stats.Failures,
		Retries = stats.Retries,
		BudgetWaits = stats.BudgetWaits,
	}
end

-- Dev/test affordance: zero the counters between cases without replacing the table itself, since
-- `perform` closes over Service.Stats.
function Service:ResetStats(): ()
	local stats = Service.Stats
	stats.Attempts = 0
	stats.FailedAttempts = 0
	stats.Failures = 0
	stats.Retries = 0
	stats.BudgetWaits = 0
end

-- ServiceRegistry contract. This service owns no events and no loops: it is a pure helper with a
-- cache, so there is nothing to wire up or tear down.
function Service:Init(_registry: any): ()
	Service.MaxAttempts = DEFAULT_MAX_ATTEMPTS
end

function Service:Start(): () end

function Service:Stop(): ()
	-- Drop handles so a rebuilt registry (the harness restarts the server between specs) does not
	-- hand out stores captured from a torn-down DataStoreService.
	stores = {}
end

return Service
