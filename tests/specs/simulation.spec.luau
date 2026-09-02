--[[
    simulation.spec
    DropperSystem and MoteSystem are the income loop. Both are driven purely by Step(dt), so the
    virtual clock can run an hour of gameplay in milliseconds and assert on the Essence that came
    out the other end.

    The properties that matter: income is never lost (including at the mote cap), never
    double-credited, and never leaks parts.
]]

local Economy = loadModule("ReplicatedStorage/Modules/Economy")
local StateSchema = loadModule("ReplicatedStorage/Modules/StateSchema")
local GameConfig = loadModule("ReplicatedStorage/Modules/GameConfig")
local DropperData = loadModule("ReplicatedStorage/Modules/DropperData")
local UpgradeData = loadModule("ReplicatedStorage/Modules/UpgradeData")
local PlotLayout = loadModule("ReplicatedStorage/Modules/PlotLayout")

local firstDropper = DropperData.List[1]
local secondDropper = DropperData.List[2]

--- A Sanctum-shaped table with just the fields these systems read.
local function makeSanctum(droppers, overrides)
    local state = StateSchema.newPlotState()
    for id, count in pairs(droppers or {}) do state.Droppers[id] = count end
    for key, value in pairs(overrides or {}) do state[key] = value end
    local model = Instance.new("Model", workspace)
    local motes = Instance.new("Folder", model)
    motes.Name = "Motes"
    return {
        Id = 1,
        State = state,
        Occupants = {},
        Runtime = { Model = model, MoteFolder = motes, Origin = PlotLayout.sanctumOrigin(1) },
        Dirty = false,
    }
end

local function multipliersFor(sanctum)
    return Economy.getMultipliers(sanctum.State, {})
end

local function samplePath(sanctum)
    return PlotLayout.railPath(sanctum.Runtime.Origin, loadModule("ReplicatedStorage/Modules/SectionData").List[1], 1)
end

-------------------------------------------------------------------------------
-- DropperSystem
-------------------------------------------------------------------------------
t.test("a sanctum with no wellsprings emits nothing", function()
    local DropperSystem = loadModule("ServerScriptService/Core/Systems/DropperSystem")
    local sanctum = makeSanctum()
    local runtime = DropperSystem.new(sanctum)
    local spawns = 0
    runtime.OnSpawn:Connect(function() spawns += 1 end)
    for _ = 1, 600 do runtime:Step(1 / 30, multipliersFor(sanctum)) end
    Mock.advance(0)
    t.eq(spawns, 0)
end)

t.test("one wellspring emits at roughly its interval", function()
    local DropperSystem = loadModule("ServerScriptService/Core/Systems/DropperSystem")
    local sanctum = makeSanctum({ [firstDropper.Id] = 1 })
    local runtime = DropperSystem.new(sanctum)
    runtime:Rebuild()
    local spawns = 0
    runtime.OnSpawn:Connect(function() spawns += 1 end)

    local seconds = 60
    local multipliers = multipliersFor(sanctum)
    for _ = 1, seconds * 30 do runtime:Step(1 / 30, multipliers) end
    Mock.advance(0)

    local interval = Economy.getDropperInterval(firstDropper, sanctum.State, multipliers)
    local expected = seconds / interval
    t.gt(spawns, expected * 0.85, ("%d spawns in %ds, expected about %.0f"):format(spawns, seconds, expected))
    t.lt(spawns, expected * 1.15, ("%d spawns in %ds, expected about %.0f"):format(spawns, seconds, expected))
end)

t.test("owning three wellsprings triples output and staggers them", function()
    local DropperSystem = loadModule("ServerScriptService/Core/Systems/DropperSystem")
    local one = makeSanctum({ [firstDropper.Id] = 1 })
    local three = makeSanctum({ [firstDropper.Id] = 3 })

    local function run(sanctum)
        local runtime = DropperSystem.new(sanctum)
        runtime:Rebuild()
        local times = {}
        local elapsed = 0
        runtime.OnSpawn:Connect(function() table.insert(times, elapsed) end)
        local multipliers = multipliersFor(sanctum)
        for _ = 1, 60 * 30 do
            elapsed += 1 / 30
            runtime:Step(1 / 30, multipliers)
        end
        Mock.advance(0)
        return times
    end

    local single, triple = run(one), run(three)
    t.near(#triple / #single, 3, 0.35, ("%d vs %d spawns"):format(#triple, #single))

    -- Staggered, not synchronised: three copies firing on the same frame would arrive in bursts of
    -- three with a full interval of silence between them.
    local simultaneous = 0
    for index = 2, #triple do
        if math.abs(triple[index] - triple[index - 1]) < 0.05 then simultaneous += 1 end
    end
    t.lt(simultaneous, #triple * 0.25, "wellsprings fire in a stream, not in bursts")
end)

t.test("a purchase takes effect immediately and does not reset existing timers", function()
    local DropperSystem = loadModule("ServerScriptService/Core/Systems/DropperSystem")
    local sanctum = makeSanctum({ [firstDropper.Id] = 1 })
    local runtime = DropperSystem.new(sanctum)
    runtime:Rebuild()
    local spawns = 0
    runtime.OnSpawn:Connect(function() spawns += 1 end)

    local multipliers = multipliersFor(sanctum)
    for _ = 1, 30 * 30 do runtime:Step(1 / 30, multipliers) end
    Mock.advance(0)
    local before = spawns

    sanctum.State.Droppers[firstDropper.Id] = 4
    runtime:Rebuild()
    for _ = 1, 30 * 30 do runtime:Step(1 / 30, multipliers) end
    Mock.advance(0)

    t.gt(spawns - before, before * 2, "four wellsprings out-produce one over the same window")
end)

t.test("an upgrade raises the rate without a Rebuild", function()
    local DropperSystem = loadModule("ServerScriptService/Core/Systems/DropperSystem")
    local cadence
    for _, upgrade in ipairs(UpgradeData.List) do
        if upgrade.Kind == "SpawnRate" then cadence = upgrade break end
    end
    t.truthy(cadence, "the data should provide a SpawnRate upgrade")

    local function countSpawns(sanctum)
        local runtime = DropperSystem.new(sanctum)
        runtime:Rebuild()
        local spawns = 0
        runtime.OnSpawn:Connect(function() spawns += 1 end)
        local multipliers = multipliersFor(sanctum)
        for _ = 1, 120 * 30 do runtime:Step(1 / 30, multipliers) end
        Mock.advance(0)
        return spawns
    end

    local plain = countSpawns(makeSanctum({ [firstDropper.Id] = 1 }))
    local upgraded = countSpawns(makeSanctum({ [firstDropper.Id] = 1 },
        { Upgrades = { [cadence.Id] = cadence.MaxLevel } }))
    t.gt(upgraded, plain, "the interval is re-read every Step, so upgrades apply at once")
end)

t.test("a long frame cannot produce an unbounded catch-up burst", function()
    local DropperSystem = loadModule("ServerScriptService/Core/Systems/DropperSystem")
    local sanctum = makeSanctum({ [firstDropper.Id] = 2 })
    local runtime = DropperSystem.new(sanctum)
    runtime:Rebuild()
    local spawns = 0
    runtime.OnSpawn:Connect(function() spawns += 1 end)
    -- A one-hour hitch. Without a bound this is thousands of motes in a single frame, which turns a
    -- hitch into a freeze.
    runtime:Step(3600, multipliersFor(sanctum))
    Mock.advance(0)
    t.lt(spawns, 100, ("a single lagging frame emitted %d motes"):format(spawns))
end)

t.test("junk state cannot break the loop", function()
    local DropperSystem = loadModule("ServerScriptService/Core/Systems/DropperSystem")
    local sanctum = makeSanctum({ ghost_dropper = 5, [firstDropper.Id] = -3 })
    local runtime = DropperSystem.new(sanctum)
    local spawns = 0
    runtime.OnSpawn:Connect(function() spawns += 1 end)
    t.noThrow(function() runtime:Rebuild() end)
    for _, dt in ipairs({ 1 / 30, 0, -1, 0 / 0, math.huge }) do
        t.noThrow(function() runtime:Step(dt, multipliersFor(sanctum)) end,
            "this runs inside the one heartbeat driving every plot")
    end
    Mock.advance(0)
    t.eq(spawns, 0, "an unknown id and a negative count both produce nothing")
end)

-------------------------------------------------------------------------------
-- MoteSystem
-------------------------------------------------------------------------------
t.test("a mote travels the rail and credits exactly once on arrival", function()
    local MoteSystem = loadModule("ServerScriptService/Core/Systems/MoteSystem")
    local sanctum = makeSanctum({ [firstDropper.Id] = 1 })
    local runtime = MoteSystem.new(sanctum)
    local credited, calls = 0, 0
    runtime.OnCollected:Connect(function(value)
        credited += value
        calls += 1
    end)

    t.truthy(runtime:Spawn(firstDropper, 25, samplePath(sanctum), 4))
    t.eq(runtime:Count(), 1)
    t.eq(calls, 0, "nothing is credited on spawn")

    for _ = 1, 2 * 30 do runtime:Step(1 / 30) end
    Mock.advance(0)
    t.eq(calls, 0, "still in transit halfway along the rail")
    t.eq(runtime:Count(), 1)

    for _ = 1, 3 * 30 do runtime:Step(1 / 30) end
    Mock.advance(0)
    t.eq(calls, 1, "credited exactly once")
    t.eq(credited, 25)
    t.eq(runtime:Count(), 0, "and removed from the world")
end)

t.test("a mote actually moves along the path rather than teleporting", function()
    local MoteSystem = loadModule("ServerScriptService/Core/Systems/MoteSystem")
    local sanctum = makeSanctum()
    local runtime = MoteSystem.new(sanctum)
    local path = samplePath(sanctum)
    runtime:Spawn(firstDropper, 1, path, 4)

    local part = sanctum.Runtime.MoteFolder:GetChildren()[1]
    t.truthy(part, "a part was created for the mote")
    local start = part.Position
    for _ = 1, 30 do runtime:Step(1 / 30) end
    local middle = part.Position
    t.gt((middle - start).Magnitude, 1, "it moved")
    t.lt((middle - path[#path].Position).Magnitude, (start - path[#path].Position).Magnitude,
        "and moved TOWARDS the font")
end)

t.test("income is never lost at the mote cap -- only the visual is", function()
    local MoteSystem = loadModule("ServerScriptService/Core/Systems/MoteSystem")
    local sanctum = makeSanctum()
    local runtime = MoteSystem.new(sanctum)
    local credited = 0
    runtime.OnCollected:Connect(function(value) credited += value end)

    local capacity = Economy.getMoteCapacity(sanctum.State)
    local path = samplePath(sanctum)
    for _ = 1, capacity do runtime:Spawn(firstDropper, 10, path, 30) end
    Mock.advance(0)
    t.eq(runtime:Count(), capacity)
    t.eq(credited, 0, "everything so far is still in flight")

    -- Past the cap: no part, but the Essence still lands.
    local overflowed = runtime:Spawn(firstDropper, 10, path, 30)
    Mock.advance(0)
    t.falsy(overflowed, "Spawn reports that no part was created")
    t.eq(runtime:Count(), capacity, "the cap holds")
    t.eq(credited, 10, "and the player was paid anyway")
end)

t.test("a mote destroyed from outside is dropped without being credited", function()
    local MoteSystem = loadModule("ServerScriptService/Core/Systems/MoteSystem")
    local sanctum = makeSanctum()
    local runtime = MoteSystem.new(sanctum)
    local credited = 0
    runtime.OnCollected:Connect(function(value) credited += value end)
    runtime:Spawn(firstDropper, 99, samplePath(sanctum), 5)

    sanctum.Runtime.MoteFolder:GetChildren()[1]:Destroy()
    for _ = 1, 30 do runtime:Step(1 / 30) end
    Mock.advance(0)
    t.eq(credited, 0, "a part that vanished was never delivered, so it must not pay out")
    t.eq(runtime:Count(), 0, "but the runtime must not keep a dead reference either")
end)

t.test("motes have a Debris lifetime so nothing can leak forever", function()
    local MoteSystem = loadModule("ServerScriptService/Core/Systems/MoteSystem")
    local sanctum = makeSanctum()
    local runtime = MoteSystem.new(sanctum)
    -- A travel time far longer than the mote lifetime: Debris must reap it.
    runtime:Spawn(firstDropper, 5, samplePath(sanctum), GameConfig.Mote.LifetimeSeconds * 10)
    t.eq(#sanctum.Runtime.MoteFolder:GetChildren(), 1)
    Mock.advance(GameConfig.Mote.LifetimeSeconds + 2)
    t.eq(#sanctum.Runtime.MoteFolder:GetChildren(), 0, "Debris cleaned it up")
end)

t.test("Clear and Destroy remove every live part", function()
    local MoteSystem = loadModule("ServerScriptService/Core/Systems/MoteSystem")
    local sanctum = makeSanctum()
    local runtime = MoteSystem.new(sanctum)
    local path = samplePath(sanctum)
    for _ = 1, 10 do runtime:Spawn(firstDropper, 1, path, 20) end
    t.eq(runtime:Count(), 10)

    runtime:Clear()
    t.eq(runtime:Count(), 0)
    t.eq(#sanctum.Runtime.MoteFolder:GetChildren(), 0,
        "releasing a plot that leaks 60 parts is a slow memory leak")

    for _ = 1, 5 do runtime:Spawn(firstDropper, 1, path, 20) end
    runtime:Destroy()
    t.eq(#sanctum.Runtime.MoteFolder:GetChildren(), 0)
end)

t.test("malformed spawns are refused rather than creating a broken mote", function()
    local MoteSystem = loadModule("ServerScriptService/Core/Systems/MoteSystem")
    local sanctum = makeSanctum()
    local runtime = MoteSystem.new(sanctum)
    local path = samplePath(sanctum)
    local credited = 0
    runtime.OnCollected:Connect(function(value) credited += value end)

    -- A bad VALUE or a bad PATH is a bug upstream (a corrupt def, a NaN multiplier, a broken
    -- layout). Those are refused outright and NOT credited: paying for them would hide the bug
    -- behind income that still looks plausible.
    for _, case in ipairs({
        { firstDropper, 0 / 0, path, 5 },
        { firstDropper, -5, path, 5 },
        { firstDropper, 0, path, 5 },
        { firstDropper, math.huge, path, 5 },
        { firstDropper, 10, { path[1] }, 5 },
        { firstDropper, 10, {}, 5 },
        { firstDropper, 10, nil, 5 },
        { firstDropper, 10, { path[1], "not a cframe" }, 5 },
    }) do
        t.falsy(runtime:Spawn(case[1], case[2], case[3], case[4]), "Spawn reports the refusal")
    end
    Mock.advance(0)
    t.eq(runtime:Count(), 0, "no broken mote entered the world")
    t.eq(credited, 0, "and none of them paid out")
end)

t.test("a degenerate travel time is clamped, not refused", function()
    -- Different call: the value and the rail are fine, only the timing is nonsense. Dropping the
    -- mote here would charge the player for a caller's mistake, so it is clamped to the rail
    -- minimum and delivered normally.
    local MoteSystem = loadModule("ServerScriptService/Core/Systems/MoteSystem")
    local sanctum = makeSanctum()
    local runtime = MoteSystem.new(sanctum)
    local path = samplePath(sanctum)
    local credited = 0
    runtime.OnCollected:Connect(function(value) credited += value end)

    for _, travel in ipairs({ 0, -1, 0 / 0, math.huge }) do
        t.truthy(runtime:Spawn(firstDropper, 10, path, travel),
            ("travel time %s should clamp, not drop the essence"):format(tostring(travel)))
    end
    t.eq(runtime:Count(), 4)

    for _ = 1, GameConfig.Mote.BaseTravelSeconds * 2 * 30 do runtime:Step(1 / 30) end
    Mock.advance(0)
    t.eq(credited, 40, "every one of them still arrived and paid out")
    t.eq(runtime:Count(), 0)
end)

t.test("Step tolerates junk dt", function()
    local MoteSystem = loadModule("ServerScriptService/Core/Systems/MoteSystem")
    local sanctum = makeSanctum()
    local runtime = MoteSystem.new(sanctum)
    runtime:Spawn(firstDropper, 1, samplePath(sanctum), 5)
    for _, dt in ipairs({ 0, -1, 0 / 0, math.huge, 1e9 }) do
        t.noThrow(function() runtime:Step(dt) end)
    end
end)

-------------------------------------------------------------------------------
-- The two together
-------------------------------------------------------------------------------
t.test("twenty minutes of simulated income lands within 10% of Economy's estimate", function()
    -- This is the end-to-end check that the spawn scheduler, the rail transport and the pure income
    -- formula all agree. If they drift, either the balance doc or the loop is lying.
    local DropperSystem = loadModule("ServerScriptService/Core/Systems/DropperSystem")
    local MoteSystem = loadModule("ServerScriptService/Core/Systems/MoteSystem")
    local sanctum = makeSanctum({ [firstDropper.Id] = 5, [secondDropper.Id] = 3 })
    local droppers = DropperSystem.new(sanctum)
    local motes = MoteSystem.new(sanctum)
    droppers:Rebuild()

    local multipliers = multipliersFor(sanctum)
    local travel = Economy.getRailTravelTime(sanctum.State, multipliers)
    local path = samplePath(sanctum)
    droppers.OnSpawn:Connect(function(def)
        motes:Spawn(def, Economy.getMoteValue(def, sanctum.State, multipliers), path, travel)
    end)
    local earned = 0
    motes.OnCollected:Connect(function(value) earned += value end)

    local seconds = 1200 -- long enough to average out spawn phase, short enough to keep the suite fast
    for _ = 1, seconds * 20 do
        droppers:Step(1 / 20, multipliers)
        motes:Step(1 / 20)
    end
    Mock.advance(0)

    local predicted = Economy.estimateIncomePerSecond(sanctum.State, multipliers) * seconds
    t.gt(earned, predicted * 0.9,
        ("simulated %.0f essence vs predicted %.0f"):format(earned, predicted))
    t.lt(earned, predicted * 1.1,
        ("simulated %.0f essence vs predicted %.0f"):format(earned, predicted))
end)
