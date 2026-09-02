--!strict
--[[
    RateLimiter
    Token buckets keyed by (player, key). Every client->server remote spends a token before its
    handler is allowed to run, so a flooding client is throttled at the edge instead of inside
    gameplay code. Buckets refill continuously from elapsed clock time rather than from a timer:
    there is no per-bucket task to schedule, the service costs nothing while idle, and a bucket that
    has been quiet for a minute is simply full again when it is next read.
    Owner: server/Services  |  Consumers: RemoteService (every C2S remote), Bootstrap.server.luau
]]

local Players = game:GetService("Players")

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local Validate = require(Modules:WaitForChild("Validate"))

-- Spec section 3.1: a connection is anything with :Disconnect(). Typed structurally so the module
-- behaves identically under Roblox's RBXScriptConnection and under the headless test mock.
type Connection = { Disconnect: (self: any) -> () }

type Bucket = {
	Tokens: number, -- fractional: refill is continuous, so partial tokens are normal
	Capacity: number, -- burst size, and the ceiling refill clamps to
	Rate: number, -- tokens restored per second (Capacity / Interval)
	Stamp: number, -- clock reading at the last refill
}

type PlayerBuckets = { [string]: Bucket }

type RateLimiterService = {
	Name: string,
	Clock: () -> number,
	_buckets: { [Player]: PlayerBuckets },
	_connection: Connection?,
	Init: (self: RateLimiterService, registry: any) -> (),
	Start: (self: RateLimiterService) -> (),
	Stop: (self: RateLimiterService) -> (),
	Consume: (
		self: RateLimiterService,
		player: Player,
		key: string,
		tokens: number,
		interval: number
	) -> boolean,
	Reset: (self: RateLimiterService, player: Player) -> (),
	Stats: (self: RateLimiterService, player: Player) -> { [string]: number },
}

local Service = {} :: RateLimiterService
Service.Name = "RateLimiter"

--[[ os.clock is a monotonic process clock. os.time would be wrong here: it can jump backwards or
     forwards when the host's wall clock is corrected, which would hand a client either a free
     refill or an hours-long lockout. Exposed as a field purely so tests can substitute a
     deterministic clock -- production code must never reassign it. ]]
Service.Clock = os.clock

Service._buckets = {}

--[[ Advance `bucket` to `now`. Refill happens on read rather than on a schedule, which is what keeps
     an idle server free of timers: elapsed time IS the refill. ]]
local function refill(bucket: Bucket, now: number): ()
	local elapsed = now - bucket.Stamp
	if elapsed <= 0 then
		-- Non-positive elapsed means two calls landed in the same clock tick, or the clock moved
		-- backwards. Granting tokens for negative time would be a free refill, and leaving a Stamp
		-- in the future would grant a huge one on the next call, so re-anchor without crediting.
		bucket.Stamp = math.min(bucket.Stamp, now)
		return
	end

	bucket.Stamp = now
	bucket.Tokens = math.min(bucket.Capacity, bucket.Tokens + elapsed * bucket.Rate)
end

function Service:Init(_registry: any): ()
	-- Rebuilt here rather than trusted from module scope so a re-Init (tests, a soft restart) never
	-- inherits buckets belonging to players from a previous run.
	self._buckets = {}
	self._connection = nil
end

function Service:Start(): ()
	--[[ Without this the bucket table grows by one entry per (player, remote key) for the lifetime
	     of the server. Worse than the table itself: a Player instance is a strong key, so every
	     leaked entry also pins a departed Player -- and whatever it still references -- in memory
	     forever. ]]
	self._connection = Players.PlayerRemoving:Connect(function(player: Player)
		self:Reset(player)
	end)
end

function Service:Stop(): ()
	if self._connection ~= nil then
		self._connection:Disconnect()
		self._connection = nil
	end
	table.clear(self._buckets)
end

--[[ Spend one token from (player, key), refilling from elapsed time first. Returns true when the
     call is allowed.

     `tokens` and `interval` describe the BUDGET, not the amount to spend: they are
     RemoteSchema's `RateLimit = { Tokens = 4, Interval = 5 }` passed straight through, meaning
     "4 calls per 5 seconds, burstable to 4". Each Consume costs exactly one token.

     Every rejection path returns false instead of erroring. This runs on the remote edge, where a
     thrown error is itself the denial of service the limiter exists to prevent. ]]
function Service:Consume(player: Player, key: string, tokens: number, interval: number): boolean
	-- typeof, not a nil check: a non-Instance player is a caller bug (a UserId or a name passed by
	-- mistake), and letting it through would open a bucket table keyed by something that no
	-- PlayerRemoving will ever clean up.
	if typeof(player) ~= "Instance" then
		return false
	end
	-- A non-string key means the caller built it wrong (a nil remote name, an Instance, a number).
	-- Hard deny: coercing to a shared fallback key would let unrelated remotes drain each other's
	-- budget, and the cheapest way to bypass a limiter is to make its key collide.
	if not Validate.isString(key) or key == "" then
		return false
	end
	if not Validate.isFiniteNumber(tokens) or tokens <= 0 then
		return false
	end
	-- interval <= 0 makes the refill rate infinite (or nan), silently disabling the limiter for
	-- this key. Deny instead of trusting arithmetic to fail safe.
	if not Validate.isFiniteNumber(interval) or interval <= 0 then
		return false
	end

	local buckets = self._buckets[player]
	if buckets == nil then
		buckets = {}
		self._buckets[player] = buckets
	end

	local now = Service.Clock()
	local rate = tokens / interval
	local bucket = buckets[key]

	if bucket == nil then
		-- A fresh bucket starts FULL, so a player's first call after joining is never throttled.
		bucket = { Tokens = tokens, Capacity = tokens, Rate = rate, Stamp = now }
		buckets[key] = bucket
	else
		if bucket.Capacity ~= tokens or bucket.Rate ~= rate then
			-- The budget for this key changed (a config reload, or two call sites disagreeing).
			-- Adopt the new one and clamp, rather than honouring a stale rate for the whole
			-- session; clamping stops a shrunk budget from carrying over a bigger old balance.
			bucket.Capacity = tokens
			bucket.Rate = rate
			bucket.Tokens = math.min(bucket.Tokens, tokens)
		end
		refill(bucket, now)
	end

	if bucket.Tokens < 1 then
		return false
	end

	bucket.Tokens -= 1
	return true
end

-- Drops every bucket for `player`. Called on PlayerRemoving, and safe to call for a player who has
-- never consumed anything.
function Service:Reset(player: Player): ()
	if typeof(player) ~= "Instance" then
		return
	end
	self._buckets[player] = nil
end

--[[ key -> tokens remaining, refilled to the current clock reading first so a caller sees the same
     numbers Consume would. Values are fractional by design (continuous refill); tests wanting exact
     figures should substitute Service.Clock. Read-only: it never creates a bucket, so asking about
     a player cannot itself allocate one. ]]
function Service:Stats(player: Player): { [string]: number }
	local stats: { [string]: number } = {}
	if typeof(player) ~= "Instance" then
		return stats
	end

	local buckets = self._buckets[player]
	if buckets == nil then
		return stats
	end

	local now = Service.Clock()
	for key, bucket in pairs(buckets) do
		refill(bucket, now)
		stats[key] = bucket.Tokens
	end
	return stats
end

return Service
