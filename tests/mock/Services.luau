--[[
    Mock/Services
    The scheduler and the service singletons: a deterministic virtual clock driving task.*, a
    Heartbeat that only advances when a test says so, an in-memory DataStoreService with injectable
    faults, and the handful of other services the game touches.

    The clock is the important part. `task.wait` inside a coroutine yields and resumes when the
    virtual clock reaches its deadline; on the main thread it fast-forwards instead, so a test can
    call a yielding API directly and still finish.
]]

local Instances = M.Instances
local Json = M.Json
local newInstance = Instances.newInstance
local newSignal = Instances.newSignal
local Methods = Instances.Methods

local Services = {}
local ENV = getfenv(1)

-------------------------------------------------------------------------------
-- Virtual clock + task library
-------------------------------------------------------------------------------
local EPOCH = 1735689600 -- 2025-01-01T00:00:00Z, fixed so os.time() is reproducible.
local scheduler = {
    now = 0,
    timers = {},
    deferred = {},
    advancing = false,
    stepSize = 1 / 30,
}
Services.scheduler = scheduler

-- Threads the scheduler created and is therefore allowed to park. The luau CLI runs the whole
-- chunk inside a coroutine, so `coroutine.isyieldable()` is true even on what is logically the
-- main thread — yielding there would abort the run with "thread yielded unexpectedly". Tracking
-- ownership explicitly is the reliable test.
local ownedThreads = setmetatable({}, { __mode = "k" })
scheduler.ownedThreads = ownedThreads

local function own(thread)
    ownedThreads[thread] = true
    return thread
end

local function insertTimer(at, thread, args)
    table.insert(scheduler.timers, { At = at, Thread = thread, Args = args or {} })
end

local function resumeThread(thread, args)
    local ok, err = coroutine.resume(thread, table.unpack(args or {}))
    if not ok then
        print(("[mock] task thread errored: %s"):format(tostring(err)))
    end
end

local function runDeferred()
    -- Drain in FIFO order, allowing handlers to defer more work into the same step.
    local guard = 0
    while #scheduler.deferred > 0 and guard < 10000 do
        local batch = scheduler.deferred
        scheduler.deferred = {}
        for _, entry in ipairs(batch) do
            guard += 1
            resumeThread(entry.Thread, entry.Args)
        end
    end
end

local function runDueTimers()
    local due = {}
    local remaining = {}
    for _, timer in ipairs(scheduler.timers) do
        if timer.At <= scheduler.now + 1e-9 then
            table.insert(due, timer)
        else
            table.insert(remaining, timer)
        end
    end
    scheduler.timers = remaining
    table.sort(due, function(a, b) return a.At < b.At end)
    for _, timer in ipairs(due) do
        resumeThread(timer.Thread, timer.Args)
    end
end

function Services.advance(seconds, step)
    if scheduler.advancing then
        -- Re-entrant advance (a Heartbeat handler called task.wait on the main thread). Running
        -- the clock forward from inside a step would double-fire Heartbeat, so treat it as a
        -- zero-length wait; the outer advance keeps time moving.
        return 0
    end
    scheduler.advancing = true
    local remaining = math.max(seconds or 0, 0)
    step = step or scheduler.stepSize
    runDeferred()
    repeat
        local dt = math.min(step, remaining)
        if dt <= 0 then dt = 0 end
        scheduler.now += dt
        runDueTimers()
        runDeferred()
        if Services.RunService then
            Services.heartbeat:Fire(dt)
            Services.stepped:Fire(scheduler.now, dt)
            runDeferred()
        end
        remaining -= dt
    until remaining <= 1e-9
    scheduler.advancing = false
    return seconds
end

local task = {}

function task.wait(duration)
    duration = math.max(tonumber(duration) or 0, 0)
    local current = coroutine.running()
    if current and ownedThreads[current] then
        insertTimer(scheduler.now + duration, current)
        coroutine.yield()
        return duration
    end
    -- Waiting on the test thread fast-forwards the world instead of parking, so a spec can call a
    -- yielding API (ProfileService:LoadAsync, say) directly and still return.
    Services.advance(duration)
    return duration
end

function task.spawn(target, ...)
    local thread = own(type(target) == "thread" and target or coroutine.create(target))
    resumeThread(thread, { ... })
    return thread
end

function task.defer(target, ...)
    local thread = own(type(target) == "thread" and target or coroutine.create(target))
    table.insert(scheduler.deferred, { Thread = thread, Args = { ... } })
    return thread
end

function task.delay(duration, target, ...)
    local thread = own(type(target) == "thread" and target or coroutine.create(target))
    insertTimer(scheduler.now + math.max(tonumber(duration) or 0, 0), thread, { ... })
    return thread
end

function task.cancel(thread)
    for index, timer in ipairs(scheduler.timers) do
        if timer.Thread == thread then
            table.remove(scheduler.timers, index)
            return
        end
    end
end

task.synchronize = function() end
task.desynchronize = function() end

ENV.task = task
ENV.wait = function(d) return task.wait(d) end
ENV.tick = function() return EPOCH + scheduler.now end
ENV.time = function() return scheduler.now end
ENV.elapsedTime = ENV.time
ENV.warn = function(...)
    local parts = {}
    for index = 1, select("#", ...) do
        parts[index] = tostring((select(index, ...)))
    end
    print("[warn] " .. table.concat(parts, " "))
end

local realOs = os
ENV.os = setmetatable({
    time = function() return EPOCH + math.floor(scheduler.now) end,
    clock = function() return realOs.clock() end,
    date = realOs.date,
    difftime = realOs.difftime,
}, { __index = realOs })

-------------------------------------------------------------------------------
-- Service registry
-------------------------------------------------------------------------------
local services = {}
local bindToClose = {}
Services.services = services
Services.bindToClose = bindToClose

local function service(className, name)
    local instance = newInstance(className, name or className)
    services[name or className] = instance
    return instance
end

local ReplicatedStorage = service("ReplicatedStorage")
local ServerScriptService = service("ServerScriptService")
local ServerStorage = service("ServerStorage")
local Workspace = service("Workspace")
local Lighting = service("Lighting")
local SoundService = service("SoundService")
local StarterGui = service("StarterGui")
local StarterPlayer = service("StarterPlayer")
local TextService = service("TextService")
local Teams = service("Teams")
local MarketplaceService = service("MarketplaceService")
local UserInputService = service("UserInputService")
local ProximityPromptService = service("ProximityPromptService")
local CollectionService = service("CollectionService")
local Debris = service("Debris")
local TweenService = service("TweenService")
local HttpService = service("HttpService")
local RunService = service("RunService")
local DataStoreService = service("DataStoreService")
local Players = service("Players")

local StarterPlayerScripts = newInstance("StarterPlayerScripts", "StarterPlayerScripts")
StarterPlayerScripts.Parent = StarterPlayer

Services.ReplicatedStorage = ReplicatedStorage
Services.ServerScriptService = ServerScriptService
Services.Workspace = Workspace
Services.Players = Players
Services.RunService = RunService
Services.ProximityPromptService = ProximityPromptService

-- RunService --------------------------------------------------------------
Services.heartbeat = Instances.getSignal(RunService, "Heartbeat")
Services.stepped = Instances.getSignal(RunService, "Stepped")
local context = { Server = true, Client = false, Studio = true }
Services.context = context
RunService.IsServer = function() return context.Server end
RunService.IsClient = function() return context.Client end
RunService.IsStudio = function() return context.Studio end
RunService.IsRunning = function() return true end
RunService.IsRunMode = function() return false end
Methods.BindToRenderStep = function() end
Methods.UnbindFromRenderStep = function() end

-- Players -----------------------------------------------------------------
Methods.Kick = function(self, message)
    self:SetAttribute("__Kicked", message or "")
    Instances.getSignal(Players, "PlayerRemoving"):Fire(self)
    self.Parent = nil
end
Methods.LoadCharacter = function(self)
    if self.Character then self.Character:Destroy() end
    local character = newInstance("Model", self.Name)
    local root = newInstance("Part", "HumanoidRootPart")
    root.Parent = character
    local humanoid = newInstance("Humanoid", "Humanoid")
    humanoid.Parent = character
    character.PrimaryPart = root
    character.Parent = Services.Workspace
    self.Character = character
    Instances.getSignal(self, "CharacterAdded"):Fire(character)
    return character
end
Methods.IsFriendsWith = function() return false end
Methods.GetRankInGroup = function() return 0 end

Players.GetPlayers = function(self)
    local list = {}
    for _, child in ipairs(self:GetChildren()) do
        if child:IsA("Player") then table.insert(list, child) end
    end
    return list
end
Players.GetPlayerFromCharacter = function(self, character)
    for _, player in ipairs(self:GetPlayers()) do
        if player.Character == character then return player end
    end
    return nil
end
Players.GetPlayerByUserId = function(self, userId)
    for _, player in ipairs(self:GetPlayers()) do
        if player.UserId == userId then return player end
    end
    return nil
end

-- Debris / Tween / Http / Collection ---------------------------------------
Debris.AddItem = function(_, instance, lifetime)
    task.delay(lifetime or 0, function()
        if instance then instance:Destroy() end
    end)
end

TweenService.Create = function(_, instance, info, properties)
    local tween = newInstance("Tween", "Tween")
    tween.Play = function()
        -- Property tweening has no observable effect in tests, so land on the goal immediately
        -- and report completion after the nominal duration.
        for key, value in pairs(properties) do
            instance[key] = value
        end
        task.delay(info and info.Time or 0, function()
            Instances.getSignal(tween, "Completed"):Fire(Enum.PlaybackState.Completed)
        end)
    end
    tween.Cancel = function() end
    tween.Pause = function() end
    return tween
end

HttpService.JSONEncode = function(_, value) return Json.encode(value) end
HttpService.JSONDecode = function(_, text) return Json.decode(text) end
local guidCounter = 0
HttpService.GenerateGUID = function(_, braces)
    guidCounter += 1
    local body = ("%08x-0000-4000-8000-%012x"):format(guidCounter, guidCounter)
    return braces == false and body or ("{%s}"):format(body)
end

local tags = {}
CollectionService.AddTag = function(_, instance, tag)
    tags[tag] = tags[tag] or setmetatable({}, { __mode = "k" })
    tags[tag][instance] = true
end
CollectionService.RemoveTag = function(_, instance, tag)
    if tags[tag] then tags[tag][instance] = nil end
end
CollectionService.HasTag = function(_, instance, tag)
    return tags[tag] ~= nil and tags[tag][instance] == true
end
CollectionService.GetTagged = function(_, tag)
    local list = {}
    for instance in pairs(tags[tag] or {}) do table.insert(list, instance) end
    return list
end
Services.tags = tags

TextService.FilterStringAsync = function(_, text) return { GetNonChatStringForBroadcastAsync = function() return text end } end
MarketplaceService.PromptProductPurchase = function() error("v1 must not touch MarketplaceService", 0) end
MarketplaceService.UserOwnsGamePassAsync = function() return false end

-------------------------------------------------------------------------------
-- DataStoreService: in-memory, JSON round-tripped, fault injectable
-------------------------------------------------------------------------------
local dataStores = {}
local dsControl = {
    FailNext = 0,          -- number of upcoming calls that should throw
    FailAlways = false,
    Latency = 0,           -- simulated seconds per call
    Budget = 100,
    Calls = 0,
    Message = "DataStore request failed: mock fault",
}
Services.dsControl = dsControl
Services.dataStores = dataStores

local function serialize(value)
    -- Roblox rejects anything DataStores cannot represent; a JSON round-trip reproduces that
    -- (and hands back a detached copy so callers cannot mutate stored state by reference).
    if value == nil then return nil end
    return Json.decode(Json.encode(value))
end

local function guard()
    dsControl.Calls += 1
    if dsControl.Latency > 0 then task.wait(dsControl.Latency) end
    if dsControl.FailAlways or dsControl.FailNext > 0 then
        if dsControl.FailNext > 0 then dsControl.FailNext -= 1 end
        error(dsControl.Message, 0)
    end
end

DataStoreService.GetDataStore = function(_, name, scope)
    local key = ("%s/%s"):format(name, scope or "global")
    if dataStores[key] then return dataStores[key] end
    local data = {}
    local store = newInstance("GlobalDataStore", name)
    store.__data = data
    store.GetAsync = function(_, entryKey)
        guard()
        return serialize(data[entryKey])
    end
    store.SetAsync = function(_, entryKey, value)
        guard()
        data[entryKey] = serialize(value)
        return entryKey
    end
    store.UpdateAsync = function(_, entryKey, transform)
        guard()
        local current = serialize(data[entryKey])
        local updated = transform(current)
        if updated == nil then
            return nil
        end
        data[entryKey] = serialize(updated)
        return serialize(data[entryKey])
    end
    store.RemoveAsync = function(_, entryKey)
        guard()
        local previous = data[entryKey]
        data[entryKey] = nil
        return serialize(previous)
    end
    store.IncrementAsync = function(_, entryKey, delta)
        guard()
        data[entryKey] = (data[entryKey] or 0) + (delta or 1)
        return data[entryKey]
    end
    dataStores[key] = store
    return store
end
DataStoreService.GetRequestBudgetForRequestType = function() return dsControl.Budget end

-------------------------------------------------------------------------------
-- game
-------------------------------------------------------------------------------
local game = {
    JobId = "mock-job-0000000000000000",
    PlaceId = 0,
    GameId = 0,
    PlaceVersion = 1,
    Name = "Game",
    ClassName = "DataModel",
}
function game:GetService(name)
    local existing = services[name]
    if existing then return existing end
    -- Unknown services are created lazily so an unexpected GetService is visible in the tree
    -- rather than a nil-index crash mid-test.
    return service(name, name)
end
game.FindService = game.GetService
game.service = game.GetService
function game:BindToClose(callback) table.insert(bindToClose, callback) end
function game:GetChildren() return {} end
function game:IsA(className) return className == "DataModel" or className == "Instance" end
setmetatable(game, {
    __index = function(_, key) return services[key] end,
    __type = "Instance",
})

ENV.game = game
ENV.workspace = Workspace
ENV.Workspace = Workspace
ENV.Game = game

Services.game = game
Services.EPOCH = EPOCH
Services.service = service
M.Services = Services
