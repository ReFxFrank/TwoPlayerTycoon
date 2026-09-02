--[[
    datastore.spec
    DataStoreWrapper is the only place in the game that touches Roblox's least reliable API. The
    behaviour that matters is what it does when the call FAILS, so every test here injects a fault:
    the mock clock makes five seconds of exponential backoff cost nothing to run.
]]

local Wrapper = loadModule("ServerScriptService/Core/Services/DataStoreWrapper")

local function fresh()
    -- The wrapper is a singleton service table, and Mock.reset() re-requires it, so counters start
    -- clean for every test. ResetStats is belt and braces.
    Wrapper:ResetStats()
    Wrapper:SetMaxAttempts(5)
    return Wrapper:GetStore("SpecStore")
end

t.test("a healthy call round-trips and reports success", function()
    local store = fresh()
    local ok, err = Wrapper:Set(store, "k", { Essence = 42 })
    t.truthy(ok, tostring(err))

    local gotOk, value = Wrapper:Get(store, "k")
    t.truthy(gotOk)
    t.eq(value.Essence, 42)
    t.eq(Wrapper:GetStats().Failures, 0)
    t.eq(Wrapper:GetStats().Retries, 0, "a healthy call retries zero times")
end)

t.test("GetStore memoises so repeated saves reuse one DataStore handle", function()
    fresh()
    t.eq(Wrapper:GetStore("Memo"), Wrapper:GetStore("Memo"))
    t.neq(Wrapper:GetStore("Memo"), Wrapper:GetStore("Other"))
end)

t.test("a transient failure is retried and eventually succeeds", function()
    local store = fresh()
    Mock.DataStore.failNext(3) -- three throttles, then the write lands
    local ok, err = Wrapper:Set(store, "k", { Essence = 7 })
    t.truthy(ok, "the wrapper should have ridden out three transient failures: " .. tostring(err))
    t.eq(Wrapper:GetStats().Retries, 3)
    t.eq(Wrapper:GetStore("SpecStore"):GetAsync("k").Essence, 7, "the value really landed")
end)

t.test("retries back off exponentially rather than hammering the backend", function()
    local store = fresh()
    Mock.DataStore.failNext(3)
    local before = Mock.now()
    Wrapper:Set(store, "k", 1)
    local elapsed = Mock.now() - before
    -- Nominal 1 + 2 + 4 = 7s of backoff, +/-20% jitter each. A wrapper that retried instantly would
    -- land near zero; one that waited a flat 5s per attempt would land near 15.
    t.gt(elapsed, 4, ("backoff was only %.2fs -- retries are not spaced out"):format(elapsed))
    t.lt(elapsed, 11, ("backoff was %.2fs -- longer than exponential from 1s"):format(elapsed))
end)

t.test("a permanent failure gives up and reports it instead of throwing", function()
    local store = fresh()
    Mock.DataStore.failAlways(true)
    local ok, err
    t.noThrow(function() ok, err = Wrapper:Set(store, "k", 1) end,
        "a DataStore outage must never propagate into a PlayerRemoving handler")
    t.falsy(ok)
    t.truthy(err ~= nil, "the caller is told why")
    t.eq(Wrapper:GetStats().Attempts, 5, "it used its whole retry budget")
    t.eq(Wrapper:GetStats().FailedAttempts, 5, "every round trip threw")
    t.eq(Wrapper:GetStats().Failures, 1,
        "but only ONE operation failed -- Failures is the number worth alerting on")
end)

t.test("a FATAL error is not retried -- five doomed attempts would burn the shutdown budget", function()
    local store = fresh()
    Mock.DataStore.setMessage("cannot store Instance in data store")
    Mock.DataStore.failAlways(true)
    local ok = Wrapper:Set(store, "k", 1)
    t.falsy(ok)
    t.eq(Wrapper:GetStats().Attempts, 1, "a serialisation failure fails the same way every time")
    t.eq(Wrapper:GetStats().Retries, 0)
end)

t.test("transient wording is recognised across the phrasings Roblox uses", function()
    for _, message in ipairs({
        "Number of requests exceeded limit, throttling",
        "Request timeout",
        "The request was queued",
        "InternalError: something broke",
        "HTTP 502 Bad Gateway",
        "503 Service Unavailable",
        "The service is temporarily unavailable",
        "DataStore request failed",
    }) do
        local store = fresh()
        Mock.DataStore.setMessage(message)
        Mock.DataStore.failNext(1)
        local ok = Wrapper:Get(store, "k")
        t.truthy(ok, ("%q should have been treated as transient and retried"):format(message))
        t.eq(Wrapper:GetStats().Retries, 1)
    end
end)

t.test("SetMaxAttempts lowers the budget, as a shutdown path needs", function()
    local store = fresh()
    Wrapper:SetMaxAttempts(2)
    Mock.DataStore.failAlways(true)
    local before = Mock.now()
    Wrapper:Set(store, "k", 1)
    t.eq(Wrapper:GetStats().Attempts, 2)
    t.lt(Mock.now() - before, 4, "two attempts cannot spend the full five-step backoff")
    t.noThrow(function() Wrapper:SetMaxAttempts(0) end)
    Wrapper:ResetStats()
    Wrapper:Set(store, "k", 1)
    t.gt(Wrapper:GetStats().Attempts, 0, "a zero budget still makes one attempt rather than none")
end)

t.test("a starved request budget is waited out, not burned through", function()
    local store = fresh()
    Mock.DataStore.setBudget(0)
    -- Restore the budget shortly after the call starts; the wrapper should poll, notice, and go.
    task.delay(3, function() Mock.DataStore.setBudget(50) end)
    local ok = Wrapper:Get(store, "k")
    t.truthy(ok, "the read should have waited for budget and then succeeded")
    t.gt(Wrapper:GetStats().BudgetWaits, 0, "it actually waited rather than calling blind")
    t.eq(Wrapper:GetStats().Retries, 0, "waiting for budget is not a retry")
end)

t.test("a permanently starved budget still terminates", function()
    local store = fresh()
    Mock.DataStore.setBudget(0)
    local ok
    -- The cap matters: without it, BindToClose would hang until Roblox killed the server, losing
    -- every other player's save too.
    t.noThrow(function() ok = Wrapper:Get(store, "k") end)
    t.truthy(ok ~= nil, "it returned rather than hanging forever")
end)

t.test("Update applies a transform atomically and returns the new value", function()
    local store = fresh()
    Wrapper:Set(store, "k", { Essence = 100 })
    local ok, updated = Wrapper:Update(store, "k", function(current)
        current = current or {}
        current.Essence = (current.Essence or 0) + 50
        return current
    end)
    t.truthy(ok)
    t.eq(updated.Essence, 150)
    t.eq(select(2, Wrapper:Get(store, "k")).Essence, 150)
end)

t.test("Update on a missing key sees nil and can create the value", function()
    local store = fresh()
    local ok, created = Wrapper:Update(store, "brand_new", function(current)
        t.eq(current, nil, "a first-time load sees nil, not an empty table")
        return { Essence = 1 }
    end)
    t.truthy(ok)
    t.eq(created.Essence, 1)
end)

t.test("a transform that returns nil aborts the write", function()
    local store = fresh()
    Wrapper:Set(store, "k", { Essence = 10 })
    local ok = Wrapper:Update(store, "k", function() return nil end)
    t.truthy(ok ~= nil)
    t.eq(select(2, Wrapper:Get(store, "k")).Essence, 10, "the stored value is unchanged")
end)

t.test("a transform that throws is reported, not swallowed or retried forever", function()
    local store = fresh()
    local calls = 0
    local ok, err
    t.noThrow(function()
        ok, err = Wrapper:Update(store, "k", function()
            calls += 1
            error("bug in the transform")
        end)
    end)
    t.falsy(ok)
    t.truthy(err ~= nil)
    t.lt(calls, 3, "a deterministic bug in the caller's transform is not worth five round trips")
end)

t.test("Remove deletes and reports the previous value", function()
    local store = fresh()
    Wrapper:Set(store, "k", { Essence = 5 })
    local ok = Wrapper:Remove(store, "k")
    t.truthy(ok)
    t.eq(select(2, Wrapper:Get(store, "k")), nil)
end)

t.test("every entry point survives junk arguments without throwing", function()
    local store = fresh()
    for _, call in ipairs({
        function() return Wrapper:Get(nil, "k") end,
        function() return Wrapper:Get(store, nil) end,
        function() return Wrapper:Set(store, nil, 1) end,
        function() return Wrapper:Set(store, ("x"):rep(200), 1) end,
        function() return Wrapper:Update(store, "k", nil) end,
        function() return Wrapper:Update(store, "k", "not a function") end,
        function() return Wrapper:Remove(store, 42) end,
        function() return Wrapper:GetStore(nil) end,
    }) do
        t.noThrow(call, "the wrapper is a boundary: it reports failures, it does not raise them")
    end
end)

t.test("an over-long key is rejected without spending a request", function()
    local store = fresh()
    local before = Mock.DataStore.calls()
    local ok = Wrapper:Set(store, ("k"):rep(120), 1)
    t.falsy(ok, "Roblox caps keys at 50 bytes; catching it locally costs nothing")
    t.eq(Mock.DataStore.calls(), before, "no request was made")
end)

t.test("GetStats returns a copy that cannot corrupt the live counters", function()
    local store = fresh()
    Wrapper:Get(store, "k")
    local stats = Wrapper:GetStats()
    stats.Attempts = 99999
    t.neq(Wrapper:GetStats().Attempts, 99999)
end)
