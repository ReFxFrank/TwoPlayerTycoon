--[[
    harness.spec
    Tests the mock itself. If these fail, every other spec's result is meaningless.
]]

t.test("datatypes: Vector3 arithmetic and typeof", function()
    local a = Vector3.new(1, 2, 3)
    local b = Vector3.new(4, 5, 6)
    t.eq(typeof(a), "Vector3", "typeof recognises mock datatypes")
    t.eq((a + b).X, 5)
    t.eq((a * 2).Z, 6)
    t.near(Vector3.new(3, 4, 0).Magnitude, 5, 1e-9)
    t.near(a:Dot(b), 32, 1e-9)
    t.eq(a:Cross(b).X, 2 * 6 - 3 * 5)
end)

t.test("datatypes: CFrame composition, lookAt and Lerp", function()
    local base = CFrame.new(10, 0, 0)
    local moved = base * CFrame.new(0, 5, 0)
    t.near(moved.Position.Y, 5, 1e-9)
    t.near(moved.Position.X, 10, 1e-9)

    local look = CFrame.lookAt(Vector3.new(0, 0, 0), Vector3.new(0, 0, -10))
    t.near(look.LookVector.Z, -1, 1e-6, "lookAt points down -Z")

    local mid = CFrame.new(0, 0, 0):Lerp(CFrame.new(10, 20, 30), 0.5)
    t.near(mid.Position.X, 5, 1e-6)
    t.near(mid.Position.Z, 15, 1e-6)

    local inverse = base:Inverse()
    t.near((base * inverse).Position.Magnitude, 0, 1e-6, "cf * cf:Inverse() is the identity")
end)

t.test("datatypes: Color3 and Enum identity", function()
    t.near(Color3.fromRGB(255, 0, 0).R, 1, 1e-9)
    t.eq(Enum.Material.Neon, Enum.Material.Neon, "enum items are reference-stable")
    t.neq(Enum.Material.Neon, Enum.Material.Plastic)
    t.eq(Enum.Material.Neon.Name, "Neon")
end)

t.test("instances: parenting, lookup and IsA", function()
    local folder = Instance.new("Folder")
    folder.Name = "Root"
    folder.Parent = workspace
    local part = Instance.new("Part", folder)
    part.Name = "Block"

    t.eq(folder:FindFirstChild("Block"), part)
    t.eq(folder.Block, part, "child lookup by property access")
    t.truthy(part:IsA("BasePart"), "Part IsA BasePart")
    t.truthy(part:IsA("Instance"))
    t.falsy(part:IsA("Model"))
    t.eq(#folder:GetChildren(), 1)
    t.eq(part:GetFullName(), "Workspace.Root.Block")

    part:Destroy()
    t.eq(folder:FindFirstChild("Block"), nil, "Destroy unparents")
end)

t.test("instances: attributes and signals", function()
    local part = Instance.new("Part", workspace)
    local seen = {}
    part:GetAttributeChangedSignal("Cost"):Connect(function()
        table.insert(seen, part:GetAttribute("Cost"))
    end)
    part:SetAttribute("Cost", 25)
    part:SetAttribute("Cost", 50)
    t.deepEq(seen, { 25, 50 })

    local fired = 0
    local connection = part.ChildAdded:Connect(function() fired += 1 end)
    Instance.new("Part", part)
    connection:Disconnect()
    Instance.new("Part", part)
    t.eq(fired, 1, "Disconnect stops delivery")
end)

t.test("clock: task.delay, task.spawn and Heartbeat only run when time advances", function()
    local RunService = game:GetService("RunService")
    local order = {}
    task.delay(2, function() table.insert(order, "delayed-2") end)
    task.delay(1, function() table.insert(order, "delayed-1") end)
    task.spawn(function() table.insert(order, "spawned") end)

    local heartbeats = 0
    RunService.Heartbeat:Connect(function(dt)
        heartbeats += 1
        t.gt(dt, -1)
    end)

    t.deepEq(order, { "spawned" }, "task.spawn runs immediately, delays do not")
    Mock.advance(1.5)
    t.deepEq(order, { "spawned", "delayed-1" })
    Mock.advance(1)
    t.deepEq(order, { "spawned", "delayed-1", "delayed-2" })
    t.gt(heartbeats, 60, "Heartbeat fires ~30x per simulated second")
end)

t.test("clock: task.wait yields inside a coroutine and fast-forwards on the main thread", function()
    local resumed = false
    task.spawn(function()
        task.wait(3)
        resumed = true
    end)
    t.falsy(resumed, "the coroutine is parked until the clock reaches its deadline")
    Mock.advance(2)
    t.falsy(resumed)
    Mock.advance(1.5)
    t.truthy(resumed)

    local before = Mock.now()
    task.wait(5) -- main thread: fast-forwards
    t.near(Mock.now() - before, 5, 0.2)
end)

t.test("players: add, character and removal", function()
    local Players = game:GetService("Players")
    local joined, left = {}, {}
    Players.PlayerAdded:Connect(function(p) table.insert(joined, p.Name) end)
    Players.PlayerRemoving:Connect(function(p) table.insert(left, p.Name) end)

    local player = Mock.addPlayer("Ash", 501)
    t.eq(player.UserId, 501)
    t.truthy(player.Character, "LoadCharacter ran")
    t.truthy(player.Character:FindFirstChildOfClass("Humanoid"))
    t.eq(#Players:GetPlayers(), 1)
    t.eq(Players:GetPlayerFromCharacter(player.Character), player)

    Mock.removePlayer(player)
    t.deepEq(joined, { "Ash" })
    t.deepEq(left, { "Ash" })
    t.eq(#Players:GetPlayers(), 0)
end)

t.test("remotes: FireClient records to the outbox and reaches the local player only", function()
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local remote = Instance.new("RemoteEvent", ReplicatedStorage)
    remote.Name = "TestRemote"

    local alice = Mock.addPlayer("Alice", 1)
    local bob = Mock.addPlayer("Bob", 2)

    local received = {}
    Mock.setLocalPlayer(alice)
    remote.OnClientEvent:Connect(function(payload) table.insert(received, payload) end)

    remote:FireClient(bob, "for-bob")
    t.eq(#received, 0, "a message addressed to Bob does not reach Alice's client")
    remote:FireClient(alice, "for-alice")
    t.deepEq(received, { "for-alice" })

    t.eq(#Mock.outboxFor("TestRemote"), 2, "both sends were recorded")
    t.eq(Mock.lastOutbox("TestRemote", alice).Args[1], "for-alice")

    local serverSaw = {}
    remote.OnServerEvent:Connect(function(player, payload)
        table.insert(serverSaw, { player.Name, payload })
    end)
    Mock.fireServer("TestRemote", bob, { Accept = true })
    t.eq(serverSaw[1][1], "Bob")
    t.eq(serverSaw[1][2].Accept, true)
end)

t.test("proximity prompts: triggering reaches both the prompt and the service", function()
    local prompt = Instance.new("ProximityPrompt", workspace)
    local player = Mock.addPlayer("Cass", 9)
    local direct, viaService = 0, 0
    prompt.Triggered:Connect(function(p)
        t.eq(p, player)
        direct += 1
    end)
    game:GetService("ProximityPromptService").PromptTriggered:Connect(function() viaService += 1 end)
    Mock.triggerPrompt(prompt, player)
    t.eq(direct, 1)
    t.eq(viaService, 1)
end)

t.test("datastore: round-trips through JSON and detaches stored values", function()
    local store = game:GetService("DataStoreService"):GetDataStore("Test")
    local payload = { Essence = 1250.5, Droppers = { ember_vent = 3 }, Sections = { wing_core = true } }
    store:SetAsync("k", payload)

    payload.Essence = 0 -- mutating the caller's table must not change stored data
    local loaded = store:GetAsync("k")
    t.eq(loaded.Essence, 1250.5)
    t.eq(loaded.Droppers.ember_vent, 3)
    t.neq(loaded, payload)

    local updated = store:UpdateAsync("k", function(current)
        current.Essence += 100
        return current
    end)
    t.eq(updated.Essence, 1350.5)
    t.eq(store:GetAsync("k").Essence, 1350.5)

    t.eq(store:GetAsync("missing"), nil)
end)

t.test("datastore: injected faults surface as errors and can be exhausted", function()
    local store = game:GetService("DataStoreService"):GetDataStore("Faulty")
    Mock.DataStore.failNext(2)
    t.throws(function() store:GetAsync("k") end, "first call fails")
    t.throws(function() store:GetAsync("k") end, "second call fails")
    t.noThrow(function() store:GetAsync("k") end, "third call succeeds")

    Mock.DataStore.failAlways(true)
    t.throws(function() store:SetAsync("k", 1) end)
    Mock.DataStore.failAlways(false)
    t.noThrow(function() store:SetAsync("k", 1) end)
end)

t.test("datastore: non-serialisable values are rejected like Roblox rejects them", function()
    local store = game:GetService("DataStoreService"):GetDataStore("Strict")
    t.throws(function() store:SetAsync("nan", { value = 0 / 0 }) end, "NaN is not encodable")
    t.throws(function() store:SetAsync("fn", { value = print }) end, "functions are not encodable")
end)

t.test("reset isolates tests; restartServer keeps datastore contents", function()
    local store = game:GetService("DataStoreService"):GetDataStore("Persist")
    store:SetAsync("player_1", { Rebirths = 4 })
    Mock.restartServer()
    local after = game:GetService("DataStoreService"):GetDataStore("Persist"):GetAsync("player_1")
    t.eq(after.Rebirths, 4, "a simulated restart keeps saved data")
    t.eq(#game:GetService("Players"):GetPlayers(), 0, "but drops all runtime state")
end)

t.test("modules: shared modules load through require(script.Parent.X)", function()
    local TableUtil = loadModule("ReplicatedStorage/Modules/TableUtil")
    t.truthy(type(TableUtil) == "table", "TableUtil loaded")
    local Format = loadModule("ReplicatedStorage/Modules/Format")
    t.truthy(type(Format.abbreviate) == "function", "Format loaded")
    -- Requiring twice returns the cached table, exactly as Roblox does.
    t.eq(loadModule("ReplicatedStorage/Modules/TableUtil"), TableUtil)
end)
