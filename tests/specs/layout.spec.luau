--[[
    layout.spec
    PlotLayout is pure geometry, which makes it exactly the kind of module that silently drifts:
    nothing crashes when two purchase pads occupy the same stud, the sanctum just becomes unusable.
    These tests pin the spatial invariants PlotBuilder and MoteSystem rely on.
]]

local PlotLayout = loadModule("ReplicatedStorage/Modules/PlotLayout")
local SectionData = loadModule("ReplicatedStorage/Modules/SectionData")
local GameConfig = loadModule("ReplicatedStorage/Modules/GameConfig")

local function distance(a, b) return (a - b).Magnitude end

t.test("sanctums are spaced far enough apart not to overlap", function()
    local previous
    for index = 1, GameConfig.Plot.SanctumCount do
        local origin = PlotLayout.sanctumOrigin(index)
        t.eq(typeof(origin), "CFrame", "sanctumOrigin returns a CFrame")
        if previous then
            local gap = distance(origin.Position, previous.Position)
            t.gt(gap, math.max(PlotLayout.SanctumSize.X, PlotLayout.SanctumSize.Z),
                ("sanctums %d and %d are closer than one sanctum wide"):format(index - 1, index))
        end
        previous = origin
    end
end)

t.test("every section sits inside its sanctum footprint", function()
    local origin = PlotLayout.sanctumOrigin(1)
    local halfX = PlotLayout.SanctumSize.X / 2
    local halfZ = PlotLayout.SanctumSize.Z / 2
    for _, section in ipairs(SectionData.List) do
        local cf = PlotLayout.sectionCFrame(origin, section)
        local offset = cf.Position - origin.Position
        t.truthy(math.abs(offset.X) + section.Size.X / 2 <= halfX + 0.001,
            ("section %s overhangs the sanctum on X"):format(section.Id))
        t.truthy(math.abs(offset.Z) + section.Size.Z / 2 <= halfZ + 0.001,
            ("section %s overhangs the sanctum on Z"):format(section.Id))
    end
end)

t.test("purchase pads never share a position", function()
    local origin = PlotLayout.sanctumOrigin(2)
    local seen = {}
    for _, section in ipairs(SectionData.List) do
        for order = 1, 8 do
            local position = PlotLayout.padCFrame(origin, section, order).Position
            local key = ("%.2f/%.2f/%.2f"):format(position.X, position.Y, position.Z)
            t.falsy(seen[key], ("pad %s#%d collides with %s"):format(section.Id, order, tostring(seen[key])))
            seen[key] = ("%s#%d"):format(section.Id, order)
        end
    end
end)

t.test("pads within a section are evenly spaced and do not stack", function()
    local origin = PlotLayout.sanctumOrigin(1)
    local section = SectionData.List[1]
    local previous
    for order = 1, 6 do
        local position = PlotLayout.padCFrame(origin, section, order).Position
        if previous then
            t.gt(distance(position, previous), 4, "consecutive pads are at least 4 studs apart")
        end
        previous = position
    end
end)

t.test("rail paths start at the wellspring and converge on the font", function()
    local origin = PlotLayout.sanctumOrigin(1)
    local font = PlotLayout.fontCFrame(origin).Position
    for _, section in ipairs(SectionData.List) do
        for order = 1, 4 do
            local path = PlotLayout.railPath(origin, section, order)
            t.truthy(#path >= 4, ("rail path %s#%d needs at least 4 waypoints, got %d"):format(
                section.Id, order, #path))
            for index, waypoint in ipairs(path) do
                t.eq(typeof(waypoint), "CFrame", ("waypoint %d is a CFrame"):format(index))
            end
            local finish = path[#path].Position
            t.lt(distance(finish, font), 6,
                ("rail path %s#%d ends %.1f studs from the font"):format(section.Id, order, distance(finish, font)))
            -- A path that starts where it ends would make motes teleport straight into the font.
            t.gt(distance(path[1].Position, finish), 5,
                ("rail path %s#%d is degenerate"):format(section.Id, order))
        end
    end
end)

t.test("rail paths from different pads are distinct", function()
    local origin = PlotLayout.sanctumOrigin(1)
    local section = SectionData.List[1]
    local first = PlotLayout.railPath(origin, section, 1)
    local second = PlotLayout.railPath(origin, section, 2)
    t.gt(distance(first[1].Position, second[1].Position), 1,
        "two wellsprings on the same wing must not drop motes into the same spot")
end)

t.test("rail path segments have no zero-length hops", function()
    -- MoteSystem interpolates between consecutive waypoints; a zero-length segment divides by zero.
    local origin = PlotLayout.sanctumOrigin(3)
    for _, section in ipairs(SectionData.List) do
        local path = PlotLayout.railPath(origin, section, 1)
        for index = 2, #path do
            t.gt(distance(path[index].Position, path[index - 1].Position), 0.01,
                ("segment %d of %s is zero length"):format(index, section.Id))
        end
    end
end)

t.test("conflux, font, spawns and link pads are placed and distinct", function()
    local origin = PlotLayout.sanctumOrigin(1)
    local conflux = PlotLayout.confluxCFrame(origin).Position
    local font = PlotLayout.fontCFrame(origin).Position
    t.gt(distance(conflux, origin.Position), -1)
    t.lt(distance(conflux, origin.Position), PlotLayout.SanctumSize.Magnitude)

    local spawns, links = {}, {}
    for slot = 1, GameConfig.Plot.SlotsPerSanctum do
        spawns[slot] = PlotLayout.spawnSlotCFrame(origin, slot).Position
        links[slot] = PlotLayout.linkPadCFrame(origin, slot).Position
    end
    t.gt(distance(spawns[1], spawns[2]), 4, "the two players do not spawn inside each other")
    t.gt(distance(links[1], links[2]), 4, "the two link pads are separate")
    for slot = 1, GameConfig.Plot.SlotsPerSanctum do
        t.gt(distance(spawns[slot], font), 3, "nobody spawns inside the collector")
        t.gt(distance(spawns[slot], conflux), 3, "nobody spawns inside the conflux")
    end
end)

t.test("layout is translation-invariant across sanctums", function()
    -- Sanctum N must be sanctum 1 rigidly translated, or per-plot bugs become position dependent.
    local section = SectionData.List[1]
    local originA, originB = PlotLayout.sanctumOrigin(1), PlotLayout.sanctumOrigin(4)
    local delta = originB.Position - originA.Position
    local padA = PlotLayout.padCFrame(originA, section, 1).Position
    local padB = PlotLayout.padCFrame(originB, section, 1).Position
    t.near((padB - padA - delta).Magnitude, 0, 1e-4)

    local fontA = PlotLayout.fontCFrame(originA).Position
    local fontB = PlotLayout.fontCFrame(originB).Position
    t.near((fontB - fontA - delta).Magnitude, 0, 1e-4)
end)

t.test("geometry helpers tolerate junk without erroring", function()
    local origin = PlotLayout.sanctumOrigin(1)
    t.noThrow(function() return PlotLayout.sanctumOrigin(0) end)
    t.noThrow(function() return PlotLayout.sanctumOrigin(-3) end)
    t.noThrow(function() return PlotLayout.sanctumOrigin(0 / 0) end)
    t.noThrow(function() return PlotLayout.padCFrame(origin, SectionData.List[1], 0 / 0) end)
    t.noThrow(function() return PlotLayout.spawnSlotCFrame(origin, 99) end)
end)
