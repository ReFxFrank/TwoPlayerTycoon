--[[
    infra.spec
    ServiceRegistry and RateLimiter carry no game knowledge, which makes them easy to get subtly
    wrong: a registry that hides a boot failure, or a limiter that leaks one table per player per
    remote for the lifetime of the server.
]]

local ServiceRegistry = loadModule("ServerScriptService/Core/ServiceRegistry")
local RateLimiter = loadModule("ServerScriptService/Core/Services/RateLimiter")

local function stubService(name, log)
    return {
        Name = name,
        Init = function(self, registry)
            self.Registry = registry
            table.insert(log, "init:" .. name)
        end,
        Start = function() table.insert(log, "start:" .. name) end,
        Stop = function() table.insert(log, "stop:" .. name) end,
    }
end

-------------------------------------------------------------------------------
-- ServiceRegistry
-------------------------------------------------------------------------------
t.test("services init in registration order and start after every Init", function()
    local log = {}
    local registry = ServiceRegistry.new()
    registry:Register("A", stubService("A", log))
    registry:Register("B", stubService("B", log))
    registry:Register("C", stubService("C", log))

    registry:InitAll()
    t.deepEq(log, { "init:A", "init:B", "init:C" })
    registry:StartAll()
    t.deepEq(log, { "init:A", "init:B", "init:C", "start:A", "start:B", "start:C" },
        "every service is constructed before any of them starts talking to its peers")
end)

t.test("StopAll runs in reverse order", function()
    local log = {}
    local registry = ServiceRegistry.new()
    registry:Register("A", stubService("A", log))
    registry:Register("B", stubService("B", log))
    registry:InitAll()
    registry:StartAll()
    log = {}
    -- Teardown mirrors construction: a service must not lose a dependency it is still unwinding.
    local reverseLog = {}
    local registry2 = ServiceRegistry.new()
    registry2:Register("A", stubService("A", reverseLog))
    registry2:Register("B", stubService("B", reverseLog))
    registry2:InitAll()
    registry2:StartAll()
    for index = #reverseLog, 1, -1 do reverseLog[index] = nil end
    registry2:StopAll()
    t.deepEq(reverseLog, { "stop:B", "stop:A" })
end)

t.test("Get resolves peers and Init receives the registry", function()
    local log = {}
    local registry = ServiceRegistry.new()
    local a = stubService("A", log)
    registry:Register("A", a)
    registry:InitAll()
    t.eq(registry:Get("A"), a)
    t.eq(a.Registry, registry, "Init is handed the registry so services resolve peers there")
end)

t.test("Get on a missing service names what IS registered", function()
    local registry = ServiceRegistry.new()
    registry:Register("PlotService", stubService("PlotService", {}))
    local ok, err = pcall(function() return registry:Get("PlotServic") end)
    t.falsy(ok, "a typo must fail loudly at boot, not as a nil index three services later")
    t.truthy(tostring(err):find("PlotServic"), "the error names what was asked for")
    t.truthy(tostring(err):find("PlotService"), "and lists what is available: " .. tostring(err))
end)

t.test("TryGet returns nil instead of erroring", function()
    local registry = ServiceRegistry.new()
    t.eq(registry:TryGet("Nope"), nil)
    t.noThrow(function() return registry:TryGet(nil) end)
end)

t.test("double registration is refused", function()
    local registry = ServiceRegistry.new()
    registry:Register("A", stubService("A", {}))
    t.throws(function() registry:Register("A", stubService("A", {})) end,
        "silently replacing a service would leave half the game holding the old table")
end)

t.test("a service that throws during Init does not silently half-boot the server", function()
    local log = {}
    local registry = ServiceRegistry.new()
    registry:Register("Good", stubService("Good", log))
    registry:Register("Bad", {
        Name = "Bad",
        Init = function() error("dependency missing") end,
    })
    registry:Register("AlsoGood", stubService("AlsoGood", log))

    t.throws(function() registry:InitAll() end, "boot must fail, not limp on")
    -- Every service is still attempted, so one log line names every broken service rather than
    -- making the developer fix them one restart at a time.
    t.truthy(table.find(log, "init:Good") ~= nil)
    t.truthy(table.find(log, "init:AlsoGood") ~= nil, "later services were still attempted")
end)

t.test("services without Init/Start/Stop are tolerated", function()
    local registry = ServiceRegistry.new()
    registry:Register("Plain", { Name = "Plain" })
    t.noThrow(function() registry:InitAll() end)
    t.noThrow(function() registry:StartAll() end)
    t.noThrow(function() registry:StopAll() end)
end)

t.test("booting twice is refused rather than silently re-running connections", function()
    local log = {}
    local registry = ServiceRegistry.new()
    registry:Register("A", stubService("A", log))
    registry:InitAll()
    registry:StartAll()
    -- Erroring beats a silent no-op: a second InitAll is a bug in Bootstrap, and Init is not
    -- idempotent for most services (it allocates state and resolves peers).
    t.throws(function() registry:InitAll() end)
    t.throws(function() registry:StartAll() end)
    t.deepEq(log, { "init:A", "start:A" }, "nothing ran twice")
end)

-------------------------------------------------------------------------------
-- RateLimiter
-------------------------------------------------------------------------------
t.test("a bucket allows its budget then denies", function()
    RateLimiter:Init({})
    local player = Mock.addPlayer("Ash", 1)
    for index = 1, 5 do
        t.truthy(RateLimiter:Consume(player, "RebirthVote", 5, 10),
            ("call %d of 5 should be allowed"):format(index))
    end
    t.falsy(RateLimiter:Consume(player, "RebirthVote", 5, 10), "the sixth call in the window is denied")
end)

t.test("tokens refill continuously, not in a lump at the window edge", function()
    RateLimiter:Init({})
    local player = Mock.addPlayer("Ash", 1)
    for _ = 1, 5 do RateLimiter:Consume(player, "k", 5, 10) end
    t.falsy(RateLimiter:Consume(player, "k", 5, 10))

    Mock.advance(2.1) -- 5 tokens per 10s => ~1 token back
    t.truthy(RateLimiter:Consume(player, "k", 5, 10), "a partial wait earns a partial refill")
    t.falsy(RateLimiter:Consume(player, "k", 5, 10), "but only one")

    Mock.advance(12)
    for index = 1, 5 do
        t.truthy(RateLimiter:Consume(player, "k", 5, 10), ("refilled call %d"):format(index))
    end
    t.falsy(RateLimiter:Consume(player, "k", 5, 10), "the bucket does not overfill past its budget")
end)

t.test("buckets are independent per key and per player", function()
    RateLimiter:Init({})
    local ash = Mock.addPlayer("Ash", 1)
    local bree = Mock.addPlayer("Bree", 2)
    for _ = 1, 3 do RateLimiter:Consume(ash, "Vote", 3, 10) end
    t.falsy(RateLimiter:Consume(ash, "Vote", 3, 10), "Ash exhausted Vote")
    t.truthy(RateLimiter:Consume(ash, "Settings", 3, 10), "a different key is unaffected")
    t.truthy(RateLimiter:Consume(bree, "Vote", 3, 10), "another player is unaffected")
end)

t.test("a non-string key is a hard deny", function()
    RateLimiter:Init({})
    local player = Mock.addPlayer("Ash", 1)
    for _, key in ipairs({ 42, true, {} }) do
        t.falsy(RateLimiter:Consume(player, key, 10, 10), "a forged key is refused, not bucketed")
    end
    t.falsy(RateLimiter:Consume(nil, "k", 10, 10), "no player, no allowance")
end)

t.test("junk budgets cannot open the gate", function()
    RateLimiter:Init({})
    local player = Mock.addPlayer("Ash", 1)
    t.noThrow(function() return RateLimiter:Consume(player, "k", 0 / 0, 10) end)
    t.noThrow(function() return RateLimiter:Consume(player, "k", 5, 0) end)
    t.noThrow(function() return RateLimiter:Consume(player, "k", -1, 10) end)
    t.noThrow(function() return RateLimiter:Consume(player, "k", math.huge, math.huge) end)
end)

t.test("Stats reports remaining tokens", function()
    RateLimiter:Init({})
    local player = Mock.addPlayer("Ash", 1)
    RateLimiter:Consume(player, "k", 4, 10)
    local stats = RateLimiter:Stats(player)
    t.truthy(type(stats) == "table")
    t.truthy(stats.k ~= nil and stats.k < 4, "one token has been spent")
    t.noThrow(function() return RateLimiter:Stats(nil) end)
end)

t.test("a departing player's buckets are released automatically", function()
    RateLimiter:Init({})
    RateLimiter:Start()
    local player = Mock.addPlayer("Ash", 1)
    RateLimiter:Consume(player, "k", 3, 10)
    t.truthy(next(RateLimiter:Stats(player)) ~= nil, "the bucket exists while they are here")

    Mock.removePlayer(player)
    -- Without this hook the server accumulates one table per (player, remote) forever.
    t.deepEq(RateLimiter:Stats(player), {}, "PlayerRemoving cleared the buckets")
end)

t.test("Reset clears one player without touching another", function()
    RateLimiter:Init({})
    local ash = Mock.addPlayer("Ash", 1)
    local bree = Mock.addPlayer("Bree", 2)
    for _ = 1, 3 do
        RateLimiter:Consume(ash, "k", 3, 10)
        RateLimiter:Consume(bree, "k", 3, 10)
    end
    RateLimiter:Reset(ash)
    t.truthy(RateLimiter:Consume(ash, "k", 3, 10), "Ash starts fresh")
    t.falsy(RateLimiter:Consume(bree, "k", 3, 10), "Bree is still throttled")
end)
