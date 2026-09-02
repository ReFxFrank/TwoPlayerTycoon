--!strict
--[[
    GameConfig
    The single table of tunables for Sanctum of Embers: currency identity, sanctum/plot geometry,
    mote flight, income cadence, persistence, session locking, rebirth voting, networking and dev
    switches. Pure data -- it touches no services and no Instances, so client, server and the
    headless test harness can all require it safely.
    Owner: shared  |  Consumers: Economy, PlotLayout, every server service, every client controller
]]

-- WHY a single flat config: balance passes and live tuning should never require hunting through a
-- dozen modules. Anything a designer might want to change at 2am lives here with a comment.

local GameConfig = {
	Currency = {
		Name = "Essence", -- display name of the shared wallet
		Symbol = "\u{2726}", -- four-pointed star, prefixed to every essence readout
		StartingAmount = 0, -- essence granted to a brand new profile
	},

	Plot = {
		SlotsPerSanctum = 2, -- co-op pair; slot 1 is the claimer, slot 2 stays open to a late joiner
		SanctumCount = 6, -- how many sanctums the server builds (12 players max at 2 slots each)
		ReleaseGraceSeconds = 45, -- keep a vacated sanctum reserved this long before recycling it
		LinkConfirmSeconds = 30, -- how long a LinkOffer stays valid before it auto-declines
		Origin = Vector3.new(0, 0, 0), -- world position of sanctum #1
		Spacing = 240, -- studs between sanctum origins (must exceed SanctumSize on both axes)
		PerRow = 3, -- sanctums per grid row; keeps the map squarish instead of one long strip
	},

	Mote = {
		MaxLivePerSanctum = 60, -- hard cap on rendered motes; overflow is credited instantly instead
		LifetimeSeconds = 30, -- Debris backstop so a leaked mote part can never linger forever
		BaseTravelSeconds = 6, -- rail flight time before RailSpeed upgrades / affinity bonuses
		MinTravelSeconds = 1.25, -- floor, so motes stay visible and the collector cannot be spammed
		Size = Vector3.new(1.4, 1.4, 1.4), -- mote part size
		SpawnHeight = 3, -- studs above the wellspring pad where a mote appears
	},

	Income = {
		TickRate = 10, -- MoteSystem/DropperSystem steps per second (Heartbeat is decimated to this)
		MinCredit = 0.0001, -- ignore absurdly small credits; guards against float dust loops
	},

	Save = {
		AutosaveSeconds = 120, -- base autosave period per profile
		AutosaveJitter = 20, -- +/- seconds of jitter so 12 players never save on the same frame
		ShutdownBudgetSeconds = 25, -- BindToClose budget; Roblox hard-kills the server at ~30s
		DataStoreName = "SanctumOfEmbers_Profiles_v1", -- bump the suffix to wipe live data
		KeyPrefix = "player_", -- final key is KeyPrefix .. UserId
		RetryBackoff = { 1, 2, 4, 8, 16 }, -- exponential backoff schedule for DataStoreWrapper
		RetryJitter = 0.2, -- +/-20% jitter applied to each backoff step
	},

	Session = {
		LockStaleSeconds = 900, -- a session lock older than this is assumed dead and is stolen
		LockRetries = 5, -- attempts to acquire a live lock before kicking the player
		LockRetryDelay = 6, -- seconds between lock acquisition attempts
	},

	Rebirth = {
		VoteWindowSeconds = 30, -- every occupant must vote yes inside this window (spec 1.8)
	},

	Network = {
		SnapshotIntervalSeconds = 0.5, -- max StateSync rate; essence-only ticks ride this cadence
		MaxNotifyPerSecond = 6, -- server-side Notify throttle, protects the client toast stack
	},

	Debug = {
		Enabled = false, -- verbose server logging
		FastMode = false, -- income x FastIncomeMultiplier, costs / FastCostDivisor (Economy honours it)
		AllowDataReset = true, -- gates the ResetData remote entirely
		FastIncomeMultiplier = 25, -- magnitude of the FastMode income boost
		FastCostDivisor = 10, -- magnitude of the FastMode cost reduction
	},
}

-- WHY freeze: config is read by ~30 modules; an accidental write anywhere would desync balance
-- between client prediction and server truth. Nested tables are frozen too, since freezing only the
-- top level would still allow `GameConfig.Plot.Spacing = 1`.
-- EXCEPTION: `Debug` stays mutable on purpose -- dev commands and the test harness flip FastMode /
-- AllowDataReset at runtime, and that is the whole point of those flags.
-- table.freeze ERRORS on an already-frozen table, and shared sub-tables (or a cycle) would hit the
-- same table twice, so isfrozen doubles as the visited-set here.
local function deepFreeze(t: { [any]: any }): { [any]: any }
	if table.isfrozen(t) then
		return t
	end
	table.freeze(t)
	for _, value in pairs(t) do
		if type(value) == "table" then
			deepFreeze(value :: { [any]: any })
		end
	end
	return t
end

for key, value in pairs(GameConfig) do
	if key ~= "Debug" and type(value) == "table" then
		deepFreeze(value :: { [any]: any })
	end
end
table.freeze(GameConfig)

return GameConfig
