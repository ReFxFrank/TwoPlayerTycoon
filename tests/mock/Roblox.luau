--[[
    Mock/Roblox
    The control surface tests drive: build the module tree, require modules, advance the virtual
    clock, add/remove players, trigger ProximityPrompts, fire client->server remotes, inject
    DataStore faults, and simulate a server restart with the datastore contents intact.
]]

local Instances = M.Instances
local Services = M.Services
local newInstance = Instances.newInstance
local services = Services.services

local Mock = {}
Mock.Services = Services
Mock.Instances = Instances

local moduleOrder = {}
local moduleDefs = {}
local moduleCache = {}
local moduleLoading = {}
local instanceByPath = {}
local pathByInstance = setmetatable({}, { __mode = "k" })

-- Every FireClient/FireAllClients is recorded so tests can assert on replication without
-- standing up a client.
Mock.outbox = {}
local localPlayer = nil

Instances.hooks.getLocalPlayer = function() return localPlayer end
Instances.hooks.recordRemote = function(remoteName, player, args)
    table.insert(Mock.outbox, { Remote = remoteName, Player = player, Args = args })
end

-------------------------------------------------------------------------------
-- Module tree
-------------------------------------------------------------------------------
local ROOT_SEGMENTS = {
    ReplicatedStorage = "ReplicatedStorage",
    ServerScriptService = "ServerScriptService",
    ServerStorage = "ServerStorage",
    StarterPlayer = "StarterPlayer",
    Workspace = "Workspace",
}

local function ensureFolder(parent, name)
    local existing = parent:FindFirstChild(name)
    if existing then return existing end
    local folder = newInstance("Folder", name)
    folder.Parent = parent
    return folder
end

local function buildModuleTree()
    instanceByPath = {}
    for _, entry in ipairs(moduleOrder) do
        local segments = string.split(entry.Path, "/")
        local rootName = table.remove(segments, 1)
        local node = services[ROOT_SEGMENTS[rootName] or rootName]
        if not node then
            node = Services.service(rootName, rootName)
        end
        local leafName = table.remove(segments)
        for _, segment in ipairs(segments) do
            node = ensureFolder(node, segment)
        end
        local scriptInstance = newInstance(entry.Class, leafName)
        scriptInstance.Parent = node
        instanceByPath[entry.Path] = scriptInstance
        pathByInstance[scriptInstance] = entry.Path
    end
end

local function requireShim(target)
    if type(target) == "string" then
        error(("mock require: string requires are not supported (got %q)"):format(target), 2)
    end
    local path = pathByInstance[target]
    if not path then
        error(("mock require: %s is not a bundled ModuleScript"):format(
            target and target.GetFullName and target:GetFullName() or tostring(target)), 2)
    end
    if moduleCache[path] ~= nil then
        return moduleCache[path]
    end
    if moduleLoading[path] then
        error(("mock require: circular require of %s"):format(path), 2)
    end
    moduleLoading[path] = true
    local ok, result = pcall(moduleDefs[path], target, requireShim)
    moduleLoading[path] = nil
    if not ok then
        error(("error loading module %s:\n%s"):format(path, tostring(result)), 0)
    end
    if result == nil then
        error(("module %s did not return a value"):format(path), 0)
    end
    moduleCache[path] = result
    return result
end

function Mock.installModules(order, defs)
    moduleOrder = order
    moduleDefs = defs
    buildModuleTree()
end

function Mock.loadModule(path)
    local instance = instanceByPath[path]
    if not instance then
        error(("mock: no module at %q. Known paths:\n  %s"):format(path, Mock.listModules()), 2)
    end
    return requireShim(instance)
end

function Mock.getInstanceForPath(path) return instanceByPath[path] end

function Mock.listModules()
    local paths = {}
    for _, entry in ipairs(moduleOrder) do table.insert(paths, entry.Path) end
    table.sort(paths)
    return table.concat(paths, "\n  ")
end

--- Executes a Script/LocalScript body (they return nothing, so they are not cached).
function Mock.runScript(path)
    local instance = instanceByPath[path]
    if not instance then
        error(("mock: no script at %q"):format(path), 2)
    end
    local ok, err = pcall(moduleDefs[path], instance, requireShim)
    if not ok then
        error(("error running script %s:\n%s"):format(path, tostring(err)), 0)
    end
end

-------------------------------------------------------------------------------
-- World control
-------------------------------------------------------------------------------
function Mock.advance(seconds, step) return Services.advance(seconds, step) end
function Mock.step() return Services.advance(0) end
function Mock.now() return Services.scheduler.now end

local nextUserId = 1000

function Mock.addPlayer(name, userId, withCharacter)
    nextUserId += 1
    local player = newInstance("Player", name or ("Player" .. nextUserId))
    player.UserId = userId or nextUserId
    player.DisplayName = player.Name
    player.Parent = services.Players
    if withCharacter ~= false then
        player:LoadCharacter()
    end
    Instances.getSignal(services.Players, "PlayerAdded"):Fire(player)
    -- PlayerAdded handlers commonly defer their real work.
    Services.advance(0)
    return player
end

function Mock.removePlayer(player)
    Instances.getSignal(services.Players, "PlayerRemoving"):Fire(player)
    Services.advance(0)
    player.Parent = nil
end

function Mock.setLocalPlayer(player)
    localPlayer = player
    services.Players.LocalPlayer = player
end

--- Runs `fn` with RunService reporting a client context (and a LocalPlayer set), then restores.
function Mock.asClient(player, fn)
    local previous = { Server = Services.context.Server, Client = Services.context.Client }
    local previousLocal = localPlayer
    Services.context.Server = false
    Services.context.Client = true
    Mock.setLocalPlayer(player)
    local ok, err = pcall(fn)
    Services.context.Server = previous.Server
    Services.context.Client = previous.Client
    Mock.setLocalPlayer(previousLocal)
    if not ok then error(err, 0) end
end

function Mock.findRemote(name)
    for _, descendant in ipairs(services.ReplicatedStorage:GetDescendants()) do
        if descendant.Name == name and descendant:IsA("RemoteEvent") then
            return descendant
        end
    end
    return nil
end

--- Simulates a client firing a remote. Bypasses no server-side validation on purpose: this is
--- exactly the path an exploiter uses, so tests can send hostile payloads through it.
function Mock.fireServer(remoteName, player, ...)
    local remote = Mock.findRemote(remoteName)
    if not remote then
        error(("mock: no RemoteEvent named %q under ReplicatedStorage"):format(remoteName), 2)
    end
    Instances.getSignal(remote, "OnServerEvent"):Fire(player, ...)
    Services.advance(0)
end

function Mock.findPrompt(root, predicate)
    for _, descendant in ipairs(root:GetDescendants()) do
        if descendant:IsA("ProximityPrompt") and predicate(descendant) then
            return descendant
        end
    end
    return nil
end

function Mock.triggerPrompt(prompt, player)
    Instances.getSignal(prompt, "Triggered"):Fire(player)
    Instances.getSignal(services.ProximityPromptService, "PromptTriggered"):Fire(prompt, player)
    Services.advance(0)
end

function Mock.outboxFor(remoteName, player)
    local matches = {}
    for _, entry in ipairs(Mock.outbox) do
        if entry.Remote == remoteName and (player == nil or entry.Player == player or entry.Player == nil) then
            table.insert(matches, entry)
        end
    end
    return matches
end

function Mock.lastOutbox(remoteName, player)
    local matches = Mock.outboxFor(remoteName, player)
    return matches[#matches]
end

function Mock.clearOutbox() Mock.outbox = {} end

--- Runs every BindToClose callback the way Roblox does at shutdown, then gives them a generous
--- simulated window to finish their saves.
function Mock.shutdown(budgetSeconds)
    for _, callback in ipairs(Services.bindToClose) do
        task.spawn(callback)
    end
    Services.advance(budgetSeconds or 60)
end

-------------------------------------------------------------------------------
-- DataStore controls
-------------------------------------------------------------------------------
Mock.DataStore = {}
function Mock.DataStore.failNext(count) Services.dsControl.FailNext = count end
function Mock.DataStore.failAlways(enabled) Services.dsControl.FailAlways = enabled and true or false end
function Mock.DataStore.setLatency(seconds) Services.dsControl.Latency = seconds or 0 end
function Mock.DataStore.setBudget(budget) Services.dsControl.Budget = budget end
function Mock.DataStore.calls() return Services.dsControl.Calls end
function Mock.DataStore.raw(name, scope)
    local store = Services.dataStores[("%s/%s"):format(name, scope or "global")]
    return store and store.__data or nil
end
function Mock.DataStore.wipe()
    for key in pairs(Services.dataStores) do Services.dataStores[key] = nil end
end

-------------------------------------------------------------------------------
-- Reset
-------------------------------------------------------------------------------
local function resetRuntime()
    local scheduler = Services.scheduler
    scheduler.now = 0
    scheduler.timers = {}
    scheduler.deferred = {}
    scheduler.advancing = false

    for _, instance in pairs(services) do
        instance:ClearAllChildren()
        for _, signal in pairs(rawget(instance, "_signals") or {}) do
            signal:DisconnectAll()
        end
    end
    -- StarterPlayerScripts is a child of StarterPlayer, so ClearAllChildren above removed it.
    local starterScripts = newInstance("StarterPlayerScripts", "StarterPlayerScripts")
    starterScripts.Parent = services.StarterPlayer

    for key in pairs(Services.tags) do Services.tags[key] = nil end
    for index = #Services.bindToClose, 1, -1 do Services.bindToClose[index] = nil end

    Services.context.Server = true
    Services.context.Client = false
    Services.context.Studio = true
    localPlayer = nil
    services.Players.LocalPlayer = nil

    Mock.outbox = {}
    moduleCache = {}
    moduleLoading = {}
    buildModuleTree()
end

--- Full isolation between tests: fresh world AND fresh datastores.
function Mock.reset()
    Mock.DataStore.wipe()
    Services.dsControl.FailNext = 0
    Services.dsControl.FailAlways = false
    Services.dsControl.Latency = 0
    Services.dsControl.Budget = 100
    Services.dsControl.Calls = 0
    resetRuntime()
end

--- Drops every runtime object and re-requires all modules, but keeps datastore contents — the
--- test-side equivalent of the server shutting down and a new one starting.
function Mock.restartServer()
    resetRuntime()
end

M.Mock = Mock
