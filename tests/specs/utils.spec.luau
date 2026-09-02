--[[
    utils.spec
    The leaf utilities. Everything above them assumes these are total functions that never throw on
    hostile input, so the tests lean hard on nil, NaN, cycles and wrong types.
]]

local Format = loadModule("ReplicatedStorage/Modules/Format")
local Validate = loadModule("ReplicatedStorage/Modules/Validate")
local TableUtil = loadModule("ReplicatedStorage/Modules/TableUtil")
local Signal = loadModule("ReplicatedStorage/Modules/Signal")
local GameConfig = loadModule("ReplicatedStorage/Modules/GameConfig")

-------------------------------------------------------------------------------
-- Format
-------------------------------------------------------------------------------
t.test("Format.abbreviate is exact below 1000 and suffixed above", function()
    t.eq(Format.abbreviate(0), "0")
    t.eq(Format.abbreviate(7), "7")
    t.eq(Format.abbreviate(999), "999")
    t.eq(Format.abbreviate(1000), "1K")
    t.eq(Format.abbreviate(1500), "1.5K")
    t.eq(Format.abbreviate(1234567), "1.23M")
    t.eq(Format.abbreviate(1e9), "1B")
    t.eq(Format.abbreviate(2.5e12), "2.5T")
    t.eq(Format.abbreviate(-1500), "-1.5K")
    t.eq(Format.abbreviate(12.5), "12.5")
end)

t.test("Format.abbreviate survives every non-finite and out-of-range input", function()
    t.eq(Format.abbreviate(0 / 0), "0", "NaN")
    -- Infinity must NOT render as "0": a pad labelled "Buy for 0" that cannot be bought is worse
    -- than an obviously-wrong symbol.
    t.neq(Format.abbreviate(math.huge), "0", "infinity is not zero")
    t.truthy(#Format.abbreviate(math.huge) <= 3)
    t.truthy(Format.abbreviate(-math.huge):find("-", 1, true), "-infinity keeps its sign")
    t.eq(Format.comma(math.huge), Format.abbreviate(math.huge))
    t.noThrow(function() return Format.abbreviate(nil) end)
    t.noThrow(function() return Format.abbreviate("nonsense") end)
    -- Past the last suffix it must still produce something short, never "inf" or a 40-digit run.
    local huge = Format.abbreviate(1e40)
    t.lt(#huge, 12, "very large numbers stay short: " .. huge)
    t.falsy(huge:find("inf"), "no 'inf' leaks into the HUD")
end)

t.test("Format.abbreviate never renders a rounded-up 1000.00 prefix", function()
    -- 999999 rounds to 1000.00K at two decimals; it must promote to the next suffix instead.
    for _, value in ipairs({ 999999, 999999999, 999999999999 }) do
        local text = Format.abbreviate(value)
        t.falsy(text:find("^1000"), ("%d rendered as %s"):format(value, text))
    end
end)

t.test("Format.comma, time, multiplier, percent and essence", function()
    t.eq(Format.comma(0), "0")
    t.eq(Format.comma(999), "999")
    t.eq(Format.comma(1000), "1,000")
    t.eq(Format.comma(1234567), "1,234,567")
    t.eq(Format.comma(-1234), "-1,234")
    t.eq(Format.comma(0 / 0), "0")
    t.eq(Format.comma(nil), "0")

    t.eq(Format.time(0), "0s")
    t.eq(Format.time(12), "12s")
    t.eq(Format.time(-5), "0s", "negative durations clamp rather than render backwards")
    t.truthy(Format.time(200):find("m"), "minutes appear past 60s")
    t.truthy(Format.time(3840):find("h"), "hours appear past 3600s")

    t.eq(Format.multiplier(2.35), "x2.35")
    t.eq(Format.percent(0.25), "25%")
    t.truthy(Format.essence(1500):find("1.5K"), "essence formatting wraps abbreviate")
    t.truthy(Format.essence(1500):find(GameConfig.Currency.Symbol, 1, true), "and carries the symbol")
end)

-------------------------------------------------------------------------------
-- Validate
-------------------------------------------------------------------------------
t.test("Validate type guards reject the wrong types instead of erroring", function()
    t.truthy(Validate.isNumber(1))
    t.falsy(Validate.isNumber("1"))
    t.truthy(Validate.isFiniteNumber(1.5))
    t.falsy(Validate.isFiniteNumber(0 / 0))
    t.falsy(Validate.isFiniteNumber(math.huge))
    t.truthy(Validate.isString("a"))
    t.falsy(Validate.isString(nil))
    t.truthy(Validate.isBoolean(false))
    t.falsy(Validate.isBoolean(0), "0 is not false")
    t.truthy(Validate.isTable({}))
    t.truthy(Validate.isArray({ 1, 2, 3 }))
    t.falsy(Validate.isArray({ a = 1 }))
    t.truthy(Validate.isArray({}), "an empty table counts as an empty array")
end)

t.test("Validate.isId accepts only safe identifier strings", function()
    t.truthy(Validate.isId("ember_vent"))
    t.truthy(Validate.isId("wing_core"))
    t.falsy(Validate.isId(""))
    t.falsy(Validate.isId("has spaces"))
    t.falsy(Validate.isId("../../etc/passwd"))
    t.falsy(Validate.isId(("x"):rep(65)), "over-long ids are rejected")
    t.falsy(Validate.isId(123))
    t.falsy(Validate.isId(nil))
    t.falsy(Validate.isId({}))
end)

t.test("Validate.clampNumber falls back to the default for junk", function()
    t.eq(Validate.clampNumber(5, 0, 10, 1), 5)
    t.eq(Validate.clampNumber(-5, 0, 10, 1), 0)
    t.eq(Validate.clampNumber(50, 0, 10, 1), 10)
    -- Non-finite input collapses to the default rather than clamping to the bound. That matters
    -- for save repair: a tampered `Essence = inf` must become 0, not "the maximum allowed".
    t.eq(Validate.clampNumber(0 / 0, 0, 10, 1), 1, "NaN falls back")
    t.eq(Validate.clampNumber(math.huge, 0, 10, 1), 1, "infinity falls back, it does not clamp up")
    t.eq(Validate.clampNumber(-math.huge, 0, 10, 1), 1)
    t.eq(Validate.clampNumber(5, 10, 0, 1), 5, "swapped bounds are tolerated")
    t.eq(Validate.clampNumber("7", 0, 10, 1), 1, "strings are not coerced")
    t.eq(Validate.clampNumber(nil, 0, 10, 1), 1)
    t.eq(Validate.clampNumber({}, 0, 10, 1), 1)
end)

t.test("Validate.payload rejects missing, mistyped AND extra fields", function()
    local shape = { Key = "string", Value = "boolean" }
    t.truthy(Validate.payload({ Key = "Music", Value = true }, shape))
    t.falsy(Validate.payload({ Key = "Music" }, shape), "missing field")
    t.falsy(Validate.payload({ Key = "Music", Value = 1 }, shape), "wrong type")
    t.falsy(Validate.payload({ Key = "Music", Value = true, Extra = 1 }, shape),
        "an unexpected key is how an exploiter probes a handler")
    t.falsy(Validate.payload(nil, shape))
    t.falsy(Validate.payload("string", shape))
    t.falsy(Validate.payload({ 1, 2, 3 }, shape))
end)

t.test("Validate.payload never errors, whatever it is handed", function()
    local cyclic = {}
    cyclic.self = cyclic
    for _, hostile in ipairs({ 0 / 0, math.huge, print, coroutine.create(print), cyclic,
        setmetatable({}, { __index = function() error("gotcha") end }) }) do
        t.noThrow(function() return Validate.payload(hostile, { A = "number" }) end)
    end
    t.noThrow(function() return Validate.payload({ A = 1 }, nil) end)
end)

-------------------------------------------------------------------------------
-- TableUtil
-------------------------------------------------------------------------------
t.test("TableUtil.deepCopy detaches nested tables and survives cycles", function()
    local source = { a = 1, nested = { list = { 1, 2, 3 } } }
    local copy = TableUtil.deepCopy(source)
    copy.nested.list[1] = 99
    t.eq(source.nested.list[1], 1, "the original is untouched")
    t.deepEq(TableUtil.deepCopy({}), {})

    local cyclic = { name = "root" }
    cyclic.self = cyclic
    local cyclicCopy = TableUtil.noThrow ~= nil and nil or TableUtil.deepCopy(cyclic)
    t.eq(cyclicCopy.name, "root")
    t.eq(cyclicCopy.self, cyclicCopy, "the cycle is preserved, not infinitely expanded")
end)

t.test("TableUtil.deepCopy keeps Roblox datatypes by reference", function()
    local source = { colour = Color3.fromRGB(10, 20, 30), position = Vector3.new(1, 2, 3) }
    local copy = TableUtil.deepCopy(source)
    t.eq(copy.colour, source.colour)
    t.eq(copy.position, source.position)
end)

t.test("TableUtil.merge overlays a patch without mutating the base", function()
    local base = { a = 1, nested = { x = 1, y = 2 } }
    local merged = TableUtil.merge(base, { b = 2, nested = { y = 9 } })
    t.eq(merged.a, 1)
    t.eq(merged.b, 2)
    t.eq(merged.nested.y, 9)
    t.eq(base.nested.y, 2, "the base is untouched")
    t.deepEq(TableUtil.merge(nil, nil), {})
end)

t.test("TableUtil collection helpers", function()
    t.eq(TableUtil.count({ a = 1, b = 2 }), 2)
    t.eq(TableUtil.count(nil), 0)
    t.truthy(TableUtil.isEmpty({}))
    t.falsy(TableUtil.isEmpty({ a = 1 }))
    t.deepEq(TableUtil.sortedKeys({ b = 1, a = 1, c = 1 }), { "a", "b", "c" })
    t.deepEq(TableUtil.map({ 1, 2, 3 }, function(v) return v * 2 end), { 2, 4, 6 })
    t.deepEq(TableUtil.filter({ 1, 2, 3, 4 }, function(v) return v % 2 == 0 end), { 2, 4 })
    t.eq(TableUtil.reduce({ 1, 2, 3 }, function(acc, v) return acc + v end, 0), 6)
    local found, index = TableUtil.find({ "a", "b", "c" }, function(v) return v == "b" end)
    t.eq(found, "b")
    t.eq(index, 2)
    t.eq(TableUtil.find({ "a" }, function() return false end), nil)
end)

t.test("TableUtil.deepEquals compares by value and handles cycles", function()
    t.truthy(TableUtil.deepEquals({ a = { 1, 2 } }, { a = { 1, 2 } }))
    t.falsy(TableUtil.deepEquals({ a = { 1, 2 } }, { a = { 1, 3 } }))
    t.falsy(TableUtil.deepEquals({ a = 1 }, { a = 1, b = 2 }), "extra keys count")
    t.truthy(TableUtil.deepEquals(1, 1))
    t.falsy(TableUtil.deepEquals(1, "1"))
    local a, b = {}, {}
    a.self, b.self = a, b
    t.noThrow(function() return TableUtil.deepEquals(a, b) end, "cycles must not blow the stack")
end)

-------------------------------------------------------------------------------
-- Signal
-------------------------------------------------------------------------------
t.test("Signal delivers to every handler and honours Disconnect", function()
    local signal = Signal.new()
    local received = {}
    local first = signal:Connect(function(value) table.insert(received, "a" .. value) end)
    signal:Connect(function(value) table.insert(received, "b" .. value) end)

    signal:Fire(1)
    Mock.advance(0)
    t.eq(#received, 2)

    first:Disconnect()
    signal:Fire(2)
    Mock.advance(0)
    t.eq(#received, 3, "only the remaining handler ran")
end)

t.test("Signal.Once fires exactly once", function()
    local signal = Signal.new()
    local count = 0
    signal:Once(function() count += 1 end)
    signal:Fire()
    signal:Fire()
    Mock.advance(0)
    t.eq(count, 1)
end)

t.test("one erroring handler cannot stop the others", function()
    local signal = Signal.new()
    local reached = false
    signal:Connect(function() error("handler blew up") end)
    signal:Connect(function() reached = true end)
    t.noThrow(function() signal:Fire() end, "Fire itself must not propagate handler errors")
    Mock.advance(0)
    t.truthy(reached, "the second handler still ran")
end)

t.test("disconnecting during a Fire is safe", function()
    local signal = Signal.new()
    local calls = 0
    local second
    signal:Connect(function()
        calls += 1
        if second then second:Disconnect() end
    end)
    second = signal:Connect(function() calls += 1 end)
    t.noThrow(function() signal:Fire() end)
    Mock.advance(0)
    t.gt(calls, 0)
end)

t.test("DisconnectAll and Destroy clear every handler", function()
    local signal = Signal.new()
    local calls = 0
    signal:Connect(function() calls += 1 end)
    signal:DisconnectAll()
    signal:Fire()
    Mock.advance(0)
    t.eq(calls, 0)
    t.noThrow(function() signal:Destroy() end)
end)
