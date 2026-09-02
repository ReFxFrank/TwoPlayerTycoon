--[[
    Mock/Testing
    A ~150 line test runner: registration, assertions, per-test isolation and a non-zero exit code
    on failure. Deliberately dependency-free so the bundle stays a single Luau chunk.
]]

local Testing = {}

local function pretty(value, depth)
    depth = depth or 0
    if type(value) ~= "table" or depth > 3 then
        if type(value) == "string" then
            return '"' .. value .. '"'
        end
        return tostring(value)
    end
    local keys = {}
    for key in pairs(value) do
        table.insert(keys, key)
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)
    local parts = {}
    for _, key in ipairs(keys) do
        table.insert(parts, ("%s = %s"):format(tostring(key), pretty(value[key], depth + 1)))
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
end

local function deepEquals(a, b)
    if a == b then
        return true
    end
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    for key, value in pairs(a) do
        if not deepEquals(value, b[key]) then
            return false
        end
    end
    for key in pairs(b) do
        if a[key] == nil then
            return false
        end
    end
    return true
end

local function newContext()
    local context = { tests = {} }

    function context.test(name: string, fn: () -> ())
        table.insert(context.tests, { Name = name, Fn = fn })
    end

    function context.fail(message: string)
        error(message, 0)
    end

    function context.truthy(value, message)
        if not value then
            error(("%s (got %s)"):format(message or "expected truthy", pretty(value)), 0)
        end
    end

    function context.falsy(value, message)
        if value then
            error(("%s (got %s)"):format(message or "expected falsy", pretty(value)), 0)
        end
    end

    function context.eq(actual, expected, message)
        if actual ~= expected then
            error(("%s\n    expected: %s\n    actual:   %s"):format(
                message or "values differ", pretty(expected), pretty(actual)), 0)
        end
    end

    function context.neq(actual, unexpected, message)
        if actual == unexpected then
            error(("%s (both %s)"):format(message or "values should differ", pretty(actual)), 0)
        end
    end

    function context.near(actual, expected, tolerance, message)
        tolerance = tolerance or 1e-6
        if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
            error(("%s\n    expected: ~%s (+/- %s)\n    actual:   %s"):format(
                message or "values differ", tostring(expected), tostring(tolerance), pretty(actual)), 0)
        end
    end

    function context.gt(actual, floor, message)
        if not (type(actual) == "number" and actual > floor) then
            error(("%s (expected > %s, got %s)"):format(message or "too small", tostring(floor), pretty(actual)), 0)
        end
    end

    function context.lt(actual, ceiling, message)
        if not (type(actual) == "number" and actual < ceiling) then
            error(("%s (expected < %s, got %s)"):format(message or "too large", tostring(ceiling), pretty(actual)), 0)
        end
    end

    function context.deepEq(actual, expected, message)
        if not deepEquals(actual, expected) then
            error(("%s\n    expected: %s\n    actual:   %s"):format(
                message or "tables differ", pretty(expected), pretty(actual)), 0)
        end
    end

    function context.throws(fn, message)
        local ok = pcall(fn)
        if ok then
            error(message or "expected the call to error", 0)
        end
    end

    function context.noThrow(fn, message)
        local ok, err = pcall(fn)
        if not ok then
            error(("%s: %s"):format(message or "unexpected error", tostring(err)), 0)
        end
        return err
    end

    return context
end

function Testing.runAll(specs, Mock, loadModule, runScript)
    local passed, failed = 0, 0
    local failures = {}
    -- os.clock is the mock's virtual clock; the runner wants real elapsed time.
    local wallClock = __realClock or os.clock
    local started = wallClock()

    for _, spec in ipairs(specs) do
        local context = newContext()
        local ok, err = pcall(spec.Run, context, Mock, loadModule, runScript)
        if not ok then
            failed += 1
            table.insert(failures, ("[%s] <registration> %s"):format(spec.Name, tostring(err)))
            print(("  x %s <registration failed>"):format(spec.Name))
            continue
        end

        print(("\n=== %s (%d tests) ==="):format(spec.Name, #context.tests))
        for _, test in ipairs(context.tests) do
            -- Every test starts from a clean mock world: no leaked instances, players or clock.
            Mock.reset()
            local testOk, testErr = pcall(test.Fn)
            if testOk then
                passed += 1
                print(("  . %s"):format(test.Name))
            else
                failed += 1
                print(("  x %s\n      %s"):format(test.Name, tostring(testErr):gsub("\n", "\n      ")))
                table.insert(failures, ("[%s] %s: %s"):format(spec.Name, test.Name, tostring(testErr)))
            end
        end
    end

    print(("\n%s\n%d passed, %d failed in %.2fs"):format(("-"):rep(60), passed, failed, wallClock() - started))
    if failed > 0 then
        print("\nFailures:")
        for _, failure in ipairs(failures) do
            print("  - " .. failure:gsub("\n", "\n    "))
        end
        error(("%d test(s) failed"):format(failed), 0)
    end
end

return Testing
