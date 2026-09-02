--[[
    profile.spec
    Session locking is the highest-risk logic in the game: get it wrong in one direction and a
    crashed server locks a player out of their own save forever; get it wrong in the other and two
    servers write one profile. Both directions are tested here, along with the outage path, because
    the worst outcome available to this module is overwriting a real save with a blank one.

    NOTE for anyone adding to this file: stateful services must be loaded INSIDE a test, never at
    registration time. Mock.reset() clears the module cache between tests, so a reference captured
    at the top of the file would keep pointing at the previous test's service -- complete with its
    loaded profiles and its memoised (now detached) DataStore handle.
]]

local StateSchema = loadModule("ReplicatedStorage/Modules/StateSchema")
local GameConfig = loadModule("ReplicatedStorage/Modules/GameConfig")
local DropperData = loadModule("ReplicatedStorage/Modules/DropperData")

local JOB_ID = game.JobId
local STORE = GameConfig.Save.DataStoreName
local firstDropper = DropperData.List[1]

--- Fresh service instances on a clean world. ProfileService only resolves DataStoreWrapper.
local function boot()
    local wrapper = loadModule("ServerScriptService/Core/Services/DataStoreWrapper")
    local profiles = loadModule("ServerScriptService/Core/Services/ProfileService")
    profiles:Init({
        Get = function(_, name)
            if name == "DataStoreWrapper" then return wrapper end
            error("unexpected dependency " .. tostring(name), 0)
        end,
    })
    profiles:Start()
    return profiles, wrapper
end

local function rawStore()
    return game:GetService("DataStoreService"):GetDataStore(STORE)
end

local function keyFor(userId)
    return GameConfig.Save.KeyPrefix .. tostring(userId)
end

local function seedStored(userId, value)
    rawStore():SetAsync(keyFor(userId), value)
end

local function readStored(userId)
    return rawStore():GetAsync(keyFor(userId))
end

-------------------------------------------------------------------------------
-- Happy path
-------------------------------------------------------------------------------
t.test("a first-time player gets a fresh legal profile and takes the lock", function()
    local ProfileService = boot()
    local player = Mock.addPlayer("Ash", 501)
    local profile = ProfileService:LoadAsync(player)

    t.truthy(profile, "a first join must always succeed")
    t.eq(profile.SchemaVersion, StateSchema.VERSION)
    t.eq(profile.Plot.Essence, 0)
    t.eq(profile.Stats.JoinCount, 1)
    t.truthy(ProfileService:IsLoaded(player))
    t.eq(ProfileService:Get(player), profile)

    local stored = readStored(501)
    t.truthy(stored, "the load itself claims the lock, so the record exists immediately")
    t.eq(stored.Lock.JobId, JOB_ID)
    t.truthy(stored.Data ~= nil, "data lives under Data, alongside the lock")
end)

t.test("ProfileLoaded fires with the player and profile", function()
    local ProfileService = boot()
    local seen = {}
    ProfileService.ProfileLoaded:Connect(function(player, profile)
        table.insert(seen, { player.Name, profile.Stats.JoinCount })
    end)
    local player = Mock.addPlayer("Ash", 501)
    ProfileService:LoadAsync(player)
    Mock.advance(0)
    t.eq(#seen, 1)
    t.eq(seen[1][1], "Ash")
end)

t.test("progress survives a save, a server restart and a rejoin", function()
    local ProfileService = boot()
    local player = Mock.addPlayer("Ash", 501)
    local profile = ProfileService:LoadAsync(player)
    profile.Plot.Essence = 12345
    profile.Plot.Stage = 4
    profile.Plot.Droppers[firstDropper.Id] = 6
    profile.Prestige.Rebirths = 3
    t.truthy(ProfileService:Save(player, { Release = true }))

    -- restartServer drops all runtime state but keeps datastore contents, exactly like a real
    -- shutdown followed by a fresh server starting up.
    Mock.restartServer()
    local Reloaded = boot()
    local rejoined = Mock.addPlayer("Ash", 501)
    local after = Reloaded:LoadAsync(rejoined)

    t.truthy(after, "the released lock lets the next server in")
    t.eq(after.Plot.Essence, 12345)
    t.eq(after.Plot.Stage, 4)
    t.eq(after.Plot.Droppers[firstDropper.Id], 6)
    t.eq(after.Prestige.Rebirths, 3)
    t.eq(after.Stats.JoinCount, 2, "join count accumulates across sessions")
end)

t.test("a second LoadAsync for the same player returns the same profile, not a second lock", function()
    local ProfileService = boot()
    local player = Mock.addPlayer("Ash", 501)
    local first = ProfileService:LoadAsync(player)
    local second = ProfileService:LoadAsync(player)
    t.eq(first, second)
    t.eq(first.Stats.JoinCount, 1, "the second call did not re-run the load")
end)

-------------------------------------------------------------------------------
-- Locking
-------------------------------------------------------------------------------
t.test("a LIVE lock held by another server blocks the load", function()
    local ProfileService = boot()
    seedStored(501, {
        Lock = { JobId = "some-other-live-server", Stamp = os.time() },
        Data = StateSchema.newProfile(),
    })
    local player = Mock.addPlayer("Ash", 501)
    local profile = ProfileService:LoadAsync(player)

    t.eq(profile, nil, "nil, NOT a blank profile -- a lost session beats a lost account")
    t.falsy(ProfileService:IsLoaded(player))
    t.eq(readStored(501).Lock.JobId, "some-other-live-server", "the foreign lock is untouched")
end)

t.test("a STALE lock is stolen, because a crashed server never releases one", function()
    local ProfileService = boot()
    local existing = StateSchema.newProfile()
    existing.Plot.Essence = 777
    seedStored(501, {
        -- Older than LockStaleSeconds: the server that wrote it is gone. Without the steal this
        -- account would be unloadable forever.
        Lock = { JobId = "crashed-server", Stamp = os.time() - GameConfig.Session.LockStaleSeconds - 60 },
        Data = existing,
    })
    local player = Mock.addPlayer("Ash", 501)
    local profile = ProfileService:LoadAsync(player)

    t.truthy(profile, "the stale lock was stolen")
    t.eq(profile.Plot.Essence, 777, "and the real save came with it")
    t.eq(readStored(501).Lock.JobId, JOB_ID)
end)

t.test("the stale window sits far above the autosave interval", function()
    -- If it did not, a live session's lock (refreshed every autosave) could be stolen by another
    -- server and two servers would write one profile: the exact corruption the lock prevents.
    local worstCaseAge = GameConfig.Save.AutosaveSeconds + GameConfig.Save.AutosaveJitter
    t.gt(GameConfig.Session.LockStaleSeconds, worstCaseAge * 4,
        "a laggy but living server must never be mistaken for a dead one")
end)

t.test("our own lock does not block us (a rejoin to the same server)", function()
    local ProfileService = boot()
    local existing = StateSchema.newProfile()
    existing.Plot.Essence = 42
    seedStored(501, { Lock = { JobId = JOB_ID, Stamp = os.time() }, Data = existing })
    local player = Mock.addPlayer("Ash", 501)
    local profile = ProfileService:LoadAsync(player)
    t.truthy(profile, "a player who rejoined the same server must not be locked out by themselves")
    t.eq(profile.Plot.Essence, 42)
end)

t.test("a legacy unwrapped profile is adopted, not mistaken for garbage", function()
    local ProfileService = boot()
    local legacy = StateSchema.newProfile()
    legacy.Plot.Essence = 999
    seedStored(501, legacy) -- written by a build predating the lock wrapper
    local player = Mock.addPlayer("Ash", 501)
    local profile = ProfileService:LoadAsync(player)
    t.truthy(profile)
    t.eq(profile.Plot.Essence, 999, "an old save is upgraded in place, never overwritten")
end)

t.test("a malformed lock record is treated as no lock", function()
    local ProfileService = boot()
    local data = StateSchema.newProfile()
    data.Plot.Essence = 55
    for index, badLock in ipairs({ "not a table", { JobId = 12 }, { Stamp = "soon" }, {} }) do
        local userId = 700 + index
        seedStored(userId, { Lock = badLock, Data = data })
        local player = Mock.addPlayer("Ash" .. index, userId)
        local profile = ProfileService:LoadAsync(player)
        t.truthy(profile, "a half-written lock must not strand a player for 15 minutes")
        t.eq(profile.Plot.Essence, 55)
    end
end)

t.test("a corrupt stored value loads as a repaired profile", function()
    local ProfileService = boot()
    seedStored(501, { Lock = { JobId = "old", Stamp = 0 }, Data = {
        Plot = { Essence = "lots", Stage = 99, Droppers = { god_mode = 1e9 } },
        Prestige = { Rebirths = 1e300 },
    } })
    local player = Mock.addPlayer("Ash", 501)
    local profile = ProfileService:LoadAsync(player)
    t.truthy(profile, "a corrupt save is a non-event, not a failed join")
    t.eq(profile.Plot.Droppers.god_mode, nil)
    t.truthy(profile.Plot.Essence == profile.Plot.Essence and profile.Plot.Essence >= 0)
end)

-------------------------------------------------------------------------------
-- Saving
-------------------------------------------------------------------------------
t.test("saving refreshes the lock stamp so a live session is never seen as stale", function()
    local ProfileService = boot()
    local player = Mock.addPlayer("Ash", 501)
    ProfileService:LoadAsync(player)
    local firstStamp = readStored(501).Lock.Stamp
    Mock.advance(200)
    ProfileService:Save(player)
    t.gt(readStored(501).Lock.Stamp, firstStamp)
end)

t.test("releasing clears the lock so the next server can load immediately", function()
    local ProfileService = boot()
    local player = Mock.addPlayer("Ash", 501)
    ProfileService:LoadAsync(player)
    ProfileService:Save(player, { Release = true })
    local stored = readStored(501)
    t.truthy(stored.Lock == nil or stored.Lock.JobId == nil or stored.Lock.Stamp == 0,
        "a released record must not block the next join")
end)

t.test("a save is abandoned when another server has taken the lock", function()
    local ProfileService = boot()
    local player = Mock.addPlayer("Ash", 501)
    local profile = ProfileService:LoadAsync(player)
    profile.Plot.Essence = 500
    -- Simulate our lock being stolen while we were playing.
    seedStored(501, { Lock = { JobId = "other-server", Stamp = os.time() }, Data = { Plot = { Essence = 1 } } })
    local ok = ProfileService:Save(player)
    t.falsy(ok, "writing here would clobber the server that now owns this player")
    t.eq(readStored(501).Lock.JobId, "other-server")
end)

t.test("playtime accumulates across saves", function()
    local ProfileService = boot()
    local player = Mock.addPlayer("Ash", 501)
    local profile = ProfileService:LoadAsync(player)
    Mock.advance(300)
    ProfileService:Save(player)
    t.gt(profile.Stats.Playtime, 0)
    t.gt(profile.Stats.LastSave, 0)
end)

t.test("autosave writes on its own without being asked", function()
    local ProfileService = boot()
    local player = Mock.addPlayer("Ash", 501)
    local profile = ProfileService:LoadAsync(player)
    profile.Plot.Essence = 4242
    local before = readStored(501).Data.Plot.Essence

    -- One autosave period plus the maximum jitter.
    Mock.advance(GameConfig.Save.AutosaveSeconds + GameConfig.Save.AutosaveJitter + 5)
    local after = readStored(501).Data.Plot.Essence
    t.neq(after, before)
    t.eq(after, 4242, "the autosave published the live table")
end)

t.test("autosave stops when the player leaves", function()
    local ProfileService = boot()
    local player = Mock.addPlayer("Ash", 501)
    ProfileService:LoadAsync(player)
    ProfileService:Release(player)
    Mock.removePlayer(player)
    local callsBefore = Mock.DataStore.calls()
    Mock.advance(GameConfig.Save.AutosaveSeconds * 3)
    t.eq(Mock.DataStore.calls(), callsBefore, "a released profile must not keep retaking the lock")
end)

t.test("concurrent saves coalesce instead of racing", function()
    local ProfileService = boot()
    Mock.DataStore.setLatency(2)
    local player = Mock.addPlayer("Ash", 501)
    ProfileService:LoadAsync(player)
    local callsBefore = Mock.DataStore.calls()
    task.spawn(function() ProfileService:Save(player) end)
    task.spawn(function() ProfileService:Save(player) end)
    Mock.advance(10)
    t.lt(Mock.DataStore.calls() - callsBefore, 3, "two overlapping saves must not both round-trip")
end)

-------------------------------------------------------------------------------
-- Outage
-------------------------------------------------------------------------------
t.test("a dead DataStore still lets the player in, on a profile that is never written back", function()
    local ProfileService = boot()
    Mock.DataStore.failAlways(true)
    local player = Mock.addPlayer("Ash", 501)
    local profile = ProfileService:LoadAsync(player)

    t.truthy(profile, "an outage must not stop people playing")
    t.truthy(ProfileService:IsLoaded(player))
    Mock.DataStore.failAlways(false)
    local callsBefore = Mock.DataStore.calls()
    t.falsy(ProfileService:Save(player),
        "and must NEVER be persisted: it would replace a real save with zeroes")
    t.eq(Mock.DataStore.calls(), callsBefore, "no write was even attempted")
end)

t.test("a DataStore that fails then recovers loads normally", function()
    local ProfileService = boot()
    Mock.DataStore.failNext(3) -- inside DataStoreWrapper's retry budget
    local player = Mock.addPlayer("Ash", 501)
    local profile = ProfileService:LoadAsync(player)
    t.truthy(profile)
    t.falsy(rawget(profile, "__NoSave"), "a transient blip is not an outage")
    t.truthy(ProfileService:Save(player))
end)

-------------------------------------------------------------------------------
-- Shutdown
-------------------------------------------------------------------------------
t.test("SaveAll releases every loaded profile", function()
    local ProfileService = boot()
    local ash = Mock.addPlayer("Ash", 501)
    local bree = Mock.addPlayer("Bree", 502)
    ProfileService:LoadAsync(ash).Plot.Essence = 100
    ProfileService:LoadAsync(bree).Plot.Essence = 200
    ProfileService:SaveAll(true)
    t.eq(readStored(501).Data.Plot.Essence, 100)
    t.eq(readStored(502).Data.Plot.Essence, 200)
end)

t.test("a shutdown save is bounded so one bad player cannot eat everyone's budget", function()
    local ProfileService = boot()
    Mock.DataStore.setLatency(20) -- every write is slower than the whole shutdown window
    for index = 1, 5 do
        ProfileService:LoadAsync(Mock.addPlayer("P" .. index, 600 + index))
    end
    local before = Mock.now()
    ProfileService:SaveAll(true)
    local spent = Mock.now() - before
    t.lt(spent, GameConfig.Save.ShutdownBudgetSeconds * 3,
        ("SaveAll ran for %.1fs; Roblox hard-kills the server around %ds"):format(
            spent, GameConfig.Save.ShutdownBudgetSeconds))
end)

t.test("BindToClose is registered and drives the shutdown save", function()
    local ProfileService = boot()
    local player = Mock.addPlayer("Ash", 501)
    ProfileService:LoadAsync(player).Plot.Essence = 8888
    Mock.shutdown()
    t.eq(readStored(501).Data.Plot.Essence, 8888, "progress is not lost when the server closes")
end)

t.test("a player leaving is saved and released automatically", function()
    local ProfileService = boot()
    local player = Mock.addPlayer("Ash", 501)
    ProfileService:LoadAsync(player).Plot.Essence = 313
    Mock.removePlayer(player)
    Mock.advance(1)
    t.eq(readStored(501).Data.Plot.Essence, 313)
    t.falsy(ProfileService:IsLoaded(player), "the in-memory profile is dropped")
end)

t.test("joining loads a profile without anyone asking -- the first domino", function()
    -- Regression guard. Every downstream system hangs off ProfileLoaded: PlotService claims a
    -- Sanctum on it, LeaderboardService builds leaderstats, StateReplicator starts pushing. Nothing
    -- else in the game calls LoadAsync, so without a PlayerAdded hook a joining player would stand
    -- in an empty world with a blank HUD -- while every module's own tests still passed.
    local ProfileService = boot()
    local loaded = {}
    ProfileService.ProfileLoaded:Connect(function(player) table.insert(loaded, player.Name) end)

    local ash = Mock.addPlayer("Ash", 501)
    Mock.advance(1)
    t.truthy(ProfileService:IsLoaded(ash), "the join alone loaded the profile")
    t.deepEq(loaded, { "Ash" }, "and announced it exactly once")
end)

t.test("a player already in game when Start runs is admitted too", function()
    -- A fresh server can fill before the first Heartbeat, so the connection alone is not enough.
    local wrapper = loadModule("ServerScriptService/Core/Services/DataStoreWrapper")
    local profiles = loadModule("ServerScriptService/Core/Services/ProfileService")
    local early = Mock.addPlayer("Early", 777)
    profiles:Init({ Get = function() return wrapper end })
    profiles:Start()
    Mock.advance(1)
    t.truthy(profiles:IsLoaded(early), "the join beat the script and was still picked up")
end)

t.test("a player whose lock is held elsewhere is kicked, not given a blank profile", function()
    local ProfileService = boot()
    seedStored(501, {
        Lock = { JobId = "some-other-live-server", Stamp = os.time() },
        Data = StateSchema.newProfile(),
    })
    local ash = Mock.addPlayer("Ash", 501)
    Mock.advance(GameConfig.Session.LockRetries * GameConfig.Session.LockRetryDelay + 5)
    -- Letting them play on a blank profile would end with the next save overwriting a real one.
    t.falsy(ProfileService:IsLoaded(ash))
    t.truthy(ash:GetAttribute("__Kicked") ~= nil, "they were kicked with a reason")
end)

t.test("every entry point tolerates a player it has never seen", function()
    local ProfileService = boot()
    -- Deliberately NOT parented to Players, so PlayerAdded never fires: this is the stale-reference
    -- case, a handler still holding a player who has already gone.
    local stranger = Instance.new("Player")
    stranger.Name = "Stranger"
    stranger.UserId = 999
    t.eq(ProfileService:Get(stranger), nil)
    t.falsy(ProfileService:IsLoaded(stranger))
    t.falsy(ProfileService:Save(stranger))
    t.noThrow(function() ProfileService:Release(stranger) end)
    t.noThrow(function() ProfileService:Save(nil) end)
    t.noThrow(function() ProfileService:Get(nil) end)
end)
