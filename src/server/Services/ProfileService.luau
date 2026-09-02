--!strict
--[[
	ProfileService
	The only path between a Player and their saved Profile. Every load takes a JobId-stamped session
	lock through DataStoreWrapper:Update, every save refreshes it (or clears it on release), and
	everything read back goes through StateSchema.migrate, so a corrupt or forged record is repaired
	rather than fatal. A player whose lock is held by another LIVE server is refused (nil) so the
	caller can kick them honestly; a player the DataStore cannot serve at all still gets a playable
	session on a profile flagged __NoSave that is never written back.
	Owner: server/Services  |  Consumers: PlotService, EconomyService, RebirthService, LeaderboardService
]]

local Players = game:GetService("Players")

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local GameConfig = require(Modules:WaitForChild("GameConfig"))
local Signal = require(Modules:WaitForChild("Signal"))
local StateSchema = require(Modules:WaitForChild("StateSchema"))

local ProfileLock = require(script.Parent.ProfileLock)

type Profile = StateSchema.Profile
type Lock = { JobId: string, Stamp: number }
-- Spec section 3.1: a connection is anything with :Disconnect(). Structural, so this module behaves
-- identically under Roblox's RBXScriptConnection and under the headless mock.
type Connection = { Disconnect: (self: any) -> () }
type Entry = {
	Player: Player,
	Profile: Profile,
	Saving: boolean, -- a write is in flight; a second Save must not interleave with it
	LastSaveOk: boolean, -- result of the last write, handed back to coalesced callers
	Released: boolean, -- a release-write already cleared the lock; do not write again
	PlaytimeStamp: number, -- os.time() up to which Stats.Playtime has been accounted for
	Autosave: boolean, -- false tells the parked autosave thread to exit at its next wake
}

local SAVE = GameConfig.Save
local SESSION = GameConfig.Session

-- Studio reports an empty JobId. A constant stand-in is right there: Studio runs one server at a
-- time, so a restarted play-test reclaims its own lock immediately instead of waiting out
-- LockStaleSeconds. Live, JobId is unique per server, which is the entire mechanism.
-- ONE definition, shared with ProfileLock. Two fallbacks would differ in Studio (where JobId is
-- empty), and a server that writes one id while blocks() compares another would refuse to
-- recognise its own lock.
local JOB_ID: string = ProfileLock.JobId
-- Poll cadence and ceiling for a caller waiting on an in-flight save. The ceiling clears
-- DataStoreWrapper's full 1+2+4+8s backoff, so a slow-but-healthy save is waited out while one
-- wedged behind an outage cannot park a PlayerRemoving or a shutdown forever.
local SAVE_POLL_SECONDS, SAVE_WAIT_TIMEOUT = 0.1, 20
-- Floor on the autosave period: a hand-edited config (Jitter >= AutosaveSeconds) must not be able to
-- turn the loop into a DataStore flood.
local MIN_AUTOSAVE_SECONDS = 5

local Service = {}
Service.Name = "ProfileService"
-- Built at module scope, not in Init: recreating them would silently drop every connection a peer
-- has made. The harness re-requires modules per test, so they are fresh each run anyway.
Service.ProfileLoaded = Signal.new()
Service.ProfileReleasing = Signal.new()

local entries: { [Player]: Entry } = {}
local connections: { Connection } = {}
local wrapper: any = nil -- DataStoreWrapper, resolved in Init
local running = false
-- Own RNG so autosave jitter never perturbs the global math.random sequence mote paths and other
-- systems draw from, which would make their tests non-reproducible.
local rng = Random.new(os.time())

-- The lock protocol lives in ProfileLock; aliased so call sites below read unchanged.
local keyFor, unwrap, blocks = ProfileLock.keyFor, ProfileLock.unwrap, ProfileLock.blocks
local function startAutosave(entry: Entry): ()
	if entry.Autosave then return end -- a second thread would double this player's write rate
	entry.Autosave = true
	task.spawn(function()
		while entry.Autosave and running do
			-- The +/- jitter IS the stagger: players who joined on the same frame land up to 2 x
			-- AutosaveJitter (40s) apart, and re-rolling each cycle stops them re-converging. A
			-- fixed period would have all twelve occupants of a full server writing on one frame.
			local jitter = rng:NextNumber(-SAVE.AutosaveJitter, SAVE.AutosaveJitter)
			task.wait(math.max(SAVE.AutosaveSeconds + jitter, MIN_AUTOSAVE_SECONDS))
			-- Re-checked after the park: the player may have left (or the server stopped) while this
			-- thread slept, and saving a released profile would retake a lock nobody holds.
			if not entry.Autosave or not running or entries[entry.Player] ~= entry then break end
			Service:Save(entry.Player)
		end
		entry.Autosave = false
	end)
end

local function register(player: Player, profile: Profile): Profile
	local entry: Entry = { Player = player, Profile = profile, Saving = false, LastSaveOk = false,
		Released = false, PlaytimeStamp = os.time(), Autosave = false }
	entries[player] = entry
	if running then startAutosave(entry) end
	Service.ProfileLoaded:Fire(player, profile)
	return profile
end

--[[ WHY this profile is never written back: the DataStore being unreachable says nothing about what
     is stored in it, so persisting this one would replace a veteran's real save with zeroes on the
     strength of a transient outage. That is far worse than losing one session, so Save skips it. ]]
local function unsavable(player: Player): Profile
	local profile: any = StateSchema.newProfile()
	profile.__NoSave = true
	warn(("[ProfileService] %s is on an unsaved profile: the DataStore is unreachable"):format(player.Name))
	return register(player, profile :: Profile)
end

local function writeProfile(entry: Entry, release: boolean): boolean
	local profile, now = entry.Profile, os.time()
	-- Playtime accrues here rather than on a timer, and the stamp advances only once the seconds it
	-- covers are in the payload: a failed write leaves them in memory for the next save instead of
	-- double-counting or dropping them.
	profile.Stats.Playtime += math.max(now - entry.PlaytimeStamp, 0)
	entry.PlaytimeStamp = now
	profile.Stats.LastSave = now
	local stolen = false
	local ok = wrapper:Update(SAVE.DataStoreName, keyFor(entry.Player), function(current: any): any
		-- Runs once per DataStoreWrapper attempt and recomputes from `current` alone; `stolen` is a
		-- last-write-wins status flag, never an accumulator.
		local lock = unwrap(current)
		if lock ~= nil and lock.JobId ~= JOB_ID then
			-- Another server holds this player's lock, so it has already LOADED their profile: ours
			-- is a stale fork now, and writing it would erase their live session.
			stolen = true
			return nil -- abort the write
		end
		stolen = false
		return { Lock = if release then nil else { JobId = JOB_ID, Stamp = os.time() }, Data = profile }
	end)
	if stolen then
		warn(("[ProfileService] abandoned save for %s: another server owns the session lock"):format(entry.Player.Name))
		return false
	end
	if not ok then warn(("[ProfileService] save failed for %s after all retries"):format(entry.Player.Name)) end
	return ok
end

function Service:LoadAsync(player: Player): Profile?
	local existing = entries[player]
	if existing ~= nil then return existing.Profile end -- a second load would take a second lock
	local key, attempts = keyFor(player), math.max(SESSION.LockRetries, 1)
	local loaded: Profile? = nil
	for attempt = 1, attempts do
		local claimed = false
		local ok = wrapper:Update(SAVE.DataStoreName, key, function(current: any): any
			claimed = false -- recomputed per attempt; the wrapper may run this more than once
			local now = os.time()
			local lock, data = unwrap(current)
			if blocks(lock, now) then return nil end -- a live server owns it: nothing is written
			-- migrate sanitises, so `data` may be nil, a string or a tampered table and what comes
			-- back is still a legal Profile. A corrupt save is therefore a non-event.
			local profile = StateSchema.migrate(data)
			profile.Stats.JoinCount += 1
			claimed, loaded = true, profile
			return { Lock = { JobId = JOB_ID, Stamp = now }, Data = profile }
		end)
		if not ok then
			-- The wrapper already exhausted its own retry schedule, so this is not contention: the
			-- DataStore is unreachable. Five more lock attempts would only delay the join.
			return unsavable(player)
		end
		local profile = loaded
		if claimed and profile ~= nil then return register(player, profile) end
		if attempt < attempts then task.wait(SESSION.LockRetryDelay) end
	end
	--[[ Give up with nil, NOT a blank profile. The caller kicks the player with a clear message and
	     they rejoin in seconds; handing back an empty profile would let the next save overwrite a
	     real one, which is unrecoverable. A lost session beats a lost account. ]]
	warn(("[ProfileService] no session lock for %s after %d attempts"):format(player.Name, attempts))
	return nil
end

function Service:Get(player: Player): Profile?
	local entry = entries[player]
	return if entry ~= nil then entry.Profile else nil
end

function Service:IsLoaded(player: Player): boolean
	return entries[player] ~= nil
end

function Service:Save(player: Player, opts: { Release: boolean? }?): boolean
	local entry = entries[player]
	if entry == nil then return false end -- nothing loaded: no state to write, no lock to refresh
	local release = if opts ~= nil then opts.Release == true else false
	if (entry.Profile :: any).__NoSave == true then return false end -- see `unsavable`
	if entry.Saving then
		local waited = 0
		while entry.Saving and waited < SAVE_WAIT_TIMEOUT do
			task.wait(SAVE_POLL_SECONDS)
			waited += SAVE_POLL_SECONDS
		end
		-- Coalesce: the in-flight write publishes the same live table this call would send, so a
		-- second round trip buys nothing. A Release must clear the lock, so it instead falls through
		-- and writes after the first call -- unless that one is still stuck, when racing it is worse.
		if not release or entry.Saving then return entry.LastSaveOk end
	end
	entry.Saving = true
	local ok = writeProfile(entry, release)
	entry.Saving = false
	entry.LastSaveOk = ok
	if ok and release then entry.Released = true end
	return ok
end

function Service:SaveAll(release: boolean?): ()
	--[[ Bounded by the shutdown budget: Roblox hard-kills the server ~30s into BindToClose whatever
	     the handler is doing, so a queue of failing saves must be abandoned in time for the players
	     behind it. os.clock is monotonic: a wall clock correction cannot stretch or collapse it. ]]
	local deadline = os.clock() + SAVE.ShutdownBudgetSeconds
	local doRelease = release == true
	for player in pairs(entries) do
		if os.clock() >= deadline then
			warn("[ProfileService] shutdown budget exhausted; the remaining profiles were not saved")
			break
		end
		Service:Save(player, { Release = doRelease })
	end
end

function Service:Release(player: Player): ()
	local entry = entries[player]
	if entry == nil then return end
	-- Fired before the final write so a consumer can flush last-moment state into the profile. A
	-- handler that yields may miss that window, which is why every other service writes through on
	-- mutation instead of hoarding state until release.
	Service.ProfileReleasing:Fire(player, entry.Profile)
	-- The release-write is what clears the session lock; skipping it would strand the player behind
	-- their own lock until it aged out at LockStaleSeconds.
	if not entry.Released then Service:Save(player, { Release = true }) end
	entry.Autosave = false -- the parked autosave thread exits at its next wake
	entries[player] = nil
end

function Service:Init(registry: any): ()
	wrapper = registry:Get("DataStoreWrapper") -- resolved only: section 6 forbids calls during Init
	running = false
	-- Rebuilt: a re-Init inheriting entries would leave two autosave loops writing through one lock.
	entries = {}
end

--[[ The first domino. Every downstream system hangs off ProfileLoaded -- PlotService claims a
     Sanctum on it, LeaderboardService builds leaderstats, StateReplicator starts pushing -- so
     without this connection a joining player loads no profile, claims no plot and stands in an
     empty world with a blank HUD. Nothing else in the game calls LoadAsync. ]]
local function admit(player: Player): ()
	if Service:IsLoaded(player) then return end
	local profile = Service:LoadAsync(player)
	if profile ~= nil then return end
	--[[ nil means the session lock belongs to a live server after every retry. Kicking is the only
	     safe answer: letting them play on a blank profile would end with the next save overwriting
	     a real one. They rejoin in seconds, usually onto the server that holds the lock. ]]
	if player.Parent ~= nil then
		player:Kick("Your sanctum is still saving on another server. Please rejoin in a moment.")
	end
end

function Service:Start(): ()
	running = true
	table.insert(connections, Players.PlayerAdded:Connect(function(player: Player)
		task.spawn(admit, player) -- LoadAsync yields; PlayerAdded must not block on a DataStore
	end))
	-- A player whose join beat this script (a fresh server fills before the first Heartbeat) still
	-- needs admitting, so the connection alone is not enough.
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(admit, player)
	end
	local leaving = Players.PlayerRemoving:Connect(function(player: Player)
		Service:Release(player) -- saves with Release = true, then drops the in-memory profile
	end)
	table.insert(connections, leaving)
	game:BindToClose(function() -- prescribed by spec section 6 for exactly this
		-- Shorter retry schedule FIRST: the wrapper's full backoff sleeps 1+2+4+8 = 15s on a single
		-- failing key, so one unlucky player would eat most of the budget and everyone behind them
		-- would be saved by nothing at all.
		if wrapper ~= nil and type(wrapper.SetMaxAttempts) == "function" then
			wrapper:SetMaxAttempts(2)
		end
		Service:SaveAll(true)
	end)
	-- A profile loaded before Start (a boot-order edge, or a test) still gets its loop.
	for _, entry in pairs(entries) do startAutosave(entry) end
end

function Service:Stop(): ()
	running = false -- every autosave thread exits at its next wake
	for _, connection in ipairs(connections) do connection:Disconnect() end
	table.clear(connections)
	for _, entry in pairs(entries) do entry.Autosave = false end
	-- Deliberately does NOT save: BindToClose owns the shutdown write, and a second pass here would
	-- either double-write every profile or race the first one mid-flight.
end

return Service
