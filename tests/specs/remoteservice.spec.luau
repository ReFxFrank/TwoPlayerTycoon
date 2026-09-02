--[[
    remoteservice.spec
    Every client->server message in the game passes through one dispatcher. This spec attacks it the
    way an exploiter would: Mock.fireServer bypasses all client-side checks, so anything that gets
    through here gets through in production.

    The gates, in order: live sender -> rate limit -> payload validation -> registered handler ->
    pcall'd call. Each is tested independently, and each rejection must be silent to the client.
]]

local RemoteSchema = loadModule("ReplicatedStorage/Modules/RemoteSchema")
local AffinityData = loadModule("ReplicatedStorage/Modules/AffinityData")

local function boot()
    local limiter = loadModule("ServerScriptService/Core/Services/RateLimiter")
    local remotes = loadModule("ServerScriptService/Core/Services/RemoteService")
    limiter:Init({})
    limiter:Start()
    remotes:Init({
        Get = function(_, name)
            if name == "RateLimiter" then return limiter end
            error("unexpected dependency " .. tostring(name), 0)
        end,
    })
    remotes:Start()
    return remotes, limiter
end

local function folder()
    return game:GetService("ReplicatedStorage"):FindFirstChild(RemoteSchema.FolderName)
end

-------------------------------------------------------------------------------
-- Wiring
-------------------------------------------------------------------------------
t.test("every remote in the schema exists under one folder, in list order", function()
    local RemoteService = boot()
    local created = folder()
    t.truthy(created, "the remotes folder was created")

    local children = created:GetChildren()
    t.eq(#children, #RemoteSchema.List, "one RemoteEvent per schema entry, no extras")
    for _, def in ipairs(RemoteSchema.List) do
        local remote = created:FindFirstChild(def.Name)
        t.truthy(remote, ("remote %s is missing"):format(def.Name))
        t.truthy(remote:IsA("RemoteEvent"))
        t.eq(RemoteService:GetRemote(def.Name), remote)
    end
end)

t.test("a second Init reuses the existing folder instead of orphaning client references", function()
    boot()
    local first = folder()
    local second = boot()
    t.eq(folder(), first, "clients already holding a reference must keep working across a restart")
    t.eq(#folder():GetChildren(), #RemoteSchema.List, "and no duplicate remotes appear")
    t.truthy(second:GetRemote("StateSync"))
end)

-------------------------------------------------------------------------------
-- The dispatcher
-------------------------------------------------------------------------------
t.test("a legal payload reaches the handler with the sending player", function()
    local RemoteService = boot()
    local seen = {}
    RemoteService:On("RebirthVote", function(player, payload)
        table.insert(seen, { player.Name, payload.Accept })
    end)
    local player = Mock.addPlayer("Ash", 1)
    Mock.fireServer("RebirthVote", player, { Accept = true })
    t.eq(#seen, 1)
    t.eq(seen[1][1], "Ash")
    t.eq(seen[1][2], true)
end)

t.test("an invalid payload never reaches the handler", function()
    local RemoteService = boot()
    local calls = 0
    RemoteService:On("ChooseAffinity", function() calls += 1 end)
    local player = Mock.addPlayer("Ash", 1)

    for _, payload in ipairs({
        { Affinity = "plasma" },              -- outside the closed set
        { Affinity = 1 },                     -- wrong type
        { Affinity = "ember", Essence = 1e9 } -- extra key: the classic probe
    }) do
        Mock.fireServer("ChooseAffinity", player, payload)
    end
    Mock.fireServer("ChooseAffinity", player, nil)
    t.eq(calls, 0, "four hostile payloads, zero handler calls")

    -- Those four still cost rate-limit tokens (the limit is checked BEFORE validation, so junk
    -- cannot be flooded for free), which is why the clock has to move before the legal one.
    Mock.advance(RemoteSchema.Remotes.ChooseAffinity.RateLimit.Interval * 2)
    Mock.fireServer("ChooseAffinity", player, { Affinity = AffinityData.List[1].Id })
    t.eq(calls, 1, "and the legal one still works")
end)

t.test("rejected messages still cost rate-limit budget", function()
    local RemoteService = boot()
    local calls = 0
    RemoteService:On("ChooseAffinity", function() calls += 1 end)
    local player = Mock.addPlayer("Ash", 1)
    local budget = RemoteSchema.Remotes.ChooseAffinity.RateLimit

    -- Spend the entire budget on payloads that will be rejected...
    for _ = 1, budget.Tokens do
        Mock.fireServer("ChooseAffinity", player, { Affinity = "bogus" })
    end
    -- ...then send a perfectly legal one. It must be throttled too.
    Mock.fireServer("ChooseAffinity", player, { Affinity = AffinityData.List[1].Id })
    t.eq(calls, 0, "otherwise an attacker floods with junk at zero cost to their budget")
end)

t.test("rate limiting cuts a flood off, and it recovers", function()
    local RemoteService = boot()
    local calls = 0
    RemoteService:On("RebirthVote", function() calls += 1 end)
    local player = Mock.addPlayer("Ash", 1)
    local budget = RemoteSchema.Remotes.RebirthVote.RateLimit

    for _ = 1, budget.Tokens * 10 do
        Mock.fireServer("RebirthVote", player, { Accept = true })
    end
    t.eq(calls, budget.Tokens, ("a %dx flood delivered exactly the budget"):format(10))

    Mock.advance(budget.Interval * 2)
    Mock.fireServer("RebirthVote", player, { Accept = true })
    t.eq(calls, budget.Tokens + 1, "the bucket refills, so a limited player is not banned")
end)

t.test("one player's flood does not throttle another", function()
    local RemoteService = boot()
    local byPlayer = {}
    RemoteService:On("RebirthVote", function(player)
        byPlayer[player.Name] = (byPlayer[player.Name] or 0) + 1
    end)
    local ash = Mock.addPlayer("Ash", 1)
    local bree = Mock.addPlayer("Bree", 2)
    for _ = 1, 50 do Mock.fireServer("RebirthVote", ash, { Accept = true }) end
    Mock.fireServer("RebirthVote", bree, { Accept = true })
    t.eq(byPlayer.Bree, 1, "buckets are per player, so one exploiter cannot deny service to a partner")
end)

t.test("a remote with no registered handler is a silent rejection, not an error", function()
    local RemoteService = boot()
    local player = Mock.addPlayer("Ash", 1)
    t.noThrow(function() Mock.fireServer("SetSetting", player, { Key = "Music", Value = true }) end)
    t.gt(RemoteService:GetRejectionStats()[player.UserId].SetSetting or 0, 0,
        "but it is counted, so a dead feature is visible in telemetry")
end)

t.test("an erroring handler cannot kill the connection for everyone else", function()
    local RemoteService = boot()
    local reached = 0
    RemoteService:On("RebirthVote", function()
        reached += 1
        error("handler bug")
    end)
    local player = Mock.addPlayer("Ash", 1)
    t.noThrow(function() Mock.fireServer("RebirthVote", player, { Accept = true }) end)
    Mock.advance(RemoteSchema.Remotes.RebirthVote.RateLimit.Interval * 2)
    t.noThrow(function() Mock.fireServer("RebirthVote", player, { Accept = true }) end)
    t.eq(reached, 2, "the second message still arrived after the first one blew up")
end)

t.test("nothing is sent back to the client explaining a rejection", function()
    local RemoteService = boot()
    RemoteService:On("ChooseAffinity", function() end)
    local player = Mock.addPlayer("Ash", 1)
    Mock.clearOutbox()
    for _ = 1, 20 do
        Mock.fireServer("ChooseAffinity", player, { Affinity = "plasma" })
    end
    t.eq(#Mock.outbox, 0,
        "a specific rejection reason is free reconnaissance; the client learns nothing")
end)

t.test("rejection stats are counted and cleared when the player leaves", function()
    local RemoteService = boot()
    RemoteService:On("ChooseAffinity", function() end)
    local player = Mock.addPlayer("Ash", 1)
    for _ = 1, 3 do Mock.fireServer("ChooseAffinity", player, { Affinity = "bogus" }) end
    t.gt(RemoteService:GetRejectionStats()[player.UserId].ChooseAffinity, 0)

    Mock.removePlayer(player)
    -- Otherwise the table grows by one entry per player who ever joined, for the server's lifetime.
    t.eq(RemoteService:GetRejectionStats()[player.UserId], nil, "the entry is released on leave")
end)

-------------------------------------------------------------------------------
-- Registration discipline
-------------------------------------------------------------------------------
t.test("On refuses an unknown name or an outbound remote", function()
    local RemoteService = boot()
    t.throws(function() RemoteService:On("NotARemote", function() end) end,
        "a typo must fail at boot, not become a feature that silently never fires")
    t.throws(function() RemoteService:On("StateSync", function() end) end,
        "StateSync is outbound; nothing arrives on it")
end)

t.test("On refuses a second handler for the same remote", function()
    local RemoteService = boot()
    RemoteService:On("RebirthVote", function() end)
    t.throws(function() RemoteService:On("RebirthVote", function() end) end,
        "silently replacing a handler would leave half the game wired to the old one")
end)

t.test("Fire* refuses an unknown or inbound remote name", function()
    local RemoteService = boot()
    local player = Mock.addPlayer("Ash", 1)
    t.throws(function() RemoteService:FireClient(player, "NotARemote", {}) end)
    t.throws(function() RemoteService:FireClient(player, "RebirthVote", {}) end,
        "RebirthVote is inbound only")
    t.throws(function() RemoteService:FireAllClients("NotARemote", {}) end)
end)

-------------------------------------------------------------------------------
-- Outbound
-------------------------------------------------------------------------------
t.test("FireClient, FireClients and FireAllClients address the right people", function()
    local RemoteService = boot()
    local ash = Mock.addPlayer("Ash", 1)
    local bree = Mock.addPlayer("Bree", 2)
    Mock.clearOutbox()

    RemoteService:FireClient(ash, "Notify", { Kind = "info", Text = "hello" })
    t.eq(#Mock.outboxFor("Notify"), 1)
    t.eq(Mock.lastOutbox("Notify").Player, ash)

    RemoteService:FireClients({ ash, bree }, "Notify", { Kind = "info", Text = "both" })
    t.eq(#Mock.outboxFor("Notify"), 3)

    Mock.clearOutbox()
    RemoteService:FireAllClients("Fx", { Kind = "attune", PlotId = 1 })
    t.eq(#Mock.outboxFor("Fx"), 1)
end)

t.test("sending to a player who left between the decision and the send is not an error", function()
    local RemoteService = boot()
    local player = Mock.addPlayer("Ash", 1)
    Mock.removePlayer(player)
    -- An unavoidable race: the server decided to notify while they were still here.
    t.noThrow(function() RemoteService:FireClient(player, "Notify", { Kind = "info", Text = "bye" }) end)
    t.noThrow(function() RemoteService:FireClients({ player, nil }, "Notify", { Kind = "info", Text = "bye" }) end)
end)

-------------------------------------------------------------------------------
-- Fuzz
-------------------------------------------------------------------------------
t.test("fuzz: no inbound message can throw out of the dispatcher", function()
    local RemoteService = boot()
    local handled = 0
    for _, def in ipairs(RemoteSchema.List) do
        if def.Direction == "ClientToServer" then
            RemoteService:On(def.Name, function() handled += 1 end)
        end
    end

    local cyclic = {}
    cyclic.self = cyclic
    local booby = setmetatable({}, { __index = function() error("gotcha") end })
    local payloads = { nil, 0, -1, 0 / 0, math.huge, "", ("x"):rep(50000), true,
        {}, { 1, 2, 3 }, cyclic, booby, print, Vector3.new(1, 2, 3), Enum.Material.Neon }

    local player = Mock.addPlayer("Ash", 1)
    for _, def in ipairs(RemoteSchema.List) do
        if def.Direction == "ClientToServer" then
            for index = 1, 15 do
                t.noThrow(function() Mock.fireServer(def.Name, player, payloads[index]) end,
                    ("%s threw on fuzz payload %d"):format(def.Name, index))
            end
            Mock.advance(def.RateLimit.Interval * 2)
        end
    end
end)

t.test("fuzz: a forged sender is refused", function()
    local RemoteService = boot()
    local calls = 0
    RemoteService:On("RebirthVote", function() calls += 1 end)
    local remote = Mock.findRemote("RebirthVote")
    -- OnServerEvent's first argument is set by the engine in production, but the dispatcher must
    -- still refuse a stale or bogus one rather than indexing it.
    for _, sender in ipairs({ 42, "Ash", {}, Instance.new("Part") }) do
        t.noThrow(function()
            Mock.Instances.getSignal(remote, "OnServerEvent"):Fire(sender, { Accept = true })
        end)
    end
    Mock.advance(0)
    t.eq(calls, 0, "no forged sender reached the handler")
end)

t.test("a message from a player who already left is refused", function()
    local RemoteService = boot()
    local calls = 0
    RemoteService:On("RebirthVote", function() calls += 1 end)
    local player = Mock.addPlayer("Ash", 1)
    Mock.removePlayer(player)
    Mock.fireServer("RebirthVote", player, { Accept = true })
    t.eq(calls, 0, "a stale player reference must not reach a service")
end)

t.test("Stop disconnects handlers but leaves the remotes in place", function()
    local RemoteService = boot()
    local calls = 0
    RemoteService:On("RebirthVote", function() calls += 1 end)
    local player = Mock.addPlayer("Ash", 1)
    RemoteService:Stop()
    Mock.fireServer("RebirthVote", player, { Accept = true })
    t.eq(calls, 0, "handlers are disconnected")
    t.truthy(folder():FindFirstChild("RebirthVote"),
        "but the remotes survive, so live client references stay valid")
end)
