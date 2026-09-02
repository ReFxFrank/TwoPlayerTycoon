--[[
    plotbuilder.spec
    PlotBuilder is pure construction, which makes its failures quiet: a missing pad is a purchase
    nobody can make, an unanchored part is a Sanctum that falls into the void, and a plot that does
    not fully destroy is a leak that only shows up after an hour of joins and leaves.
]]

local PlotBuilder = loadModule("ServerScriptService/Core/Systems/PlotBuilder")
local PlotLayout = loadModule("ReplicatedStorage/Modules/PlotLayout")
local SectionData = loadModule("ReplicatedStorage/Modules/SectionData")
local DropperData = loadModule("ReplicatedStorage/Modules/DropperData")
local UpgradeData = loadModule("ReplicatedStorage/Modules/UpgradeData")
local GameConfig = loadModule("ReplicatedStorage/Modules/GameConfig")
local Theme = loadModule("ReplicatedStorage/Modules/Theme")

local function build(plotId)
    local parent = Instance.new("Folder", workspace)
    parent.Name = "Sanctums"
    local model, runtime = PlotBuilder.build(plotId or 1, parent)
    return model, runtime, parent
end

t.test("build returns a model and a runtime with every documented handle", function()
    local model, runtime = build(1)
    t.truthy(model, "a model was returned")
    t.eq(model.Parent.Name, "Sanctums")
    t.truthy(model.Name:find("1"), "the model names its plot: " .. model.Name)

    for _, key in ipairs({ "Model", "Sections", "Pads", "Conflux", "Font", "MoteFolder",
        "RailFolders", "Signs", "PlotId", "Origin" }) do
        t.truthy(runtime[key] ~= nil, ("runtime.%s is missing"):format(key))
    end
    t.eq(runtime.Model, model)
    t.eq(runtime.PlotId, 1)
    t.eq(typeof(runtime.Origin), "CFrame")
    t.truthy(runtime.MoteFolder:IsA("Folder"), "MoteSystem parents motes here")
end)

t.test("every section in the data gets a piece of world", function()
    local _, runtime = build(1)
    for _, section in ipairs(SectionData.List) do
        t.truthy(runtime.Sections[section.Id], ("section %s was not built"):format(section.Id))
        t.truthy(runtime.RailFolders[section.Id], ("section %s has no rail folder"):format(section.Id))
    end
end)

t.test("every purchasable thing has a pad and a sign", function()
    local _, runtime = build(1)
    for _, dropper in ipairs(DropperData.List) do
        local key = "dropper:" .. dropper.Id
        t.truthy(runtime.Pads[key], ("no pad for wellspring %s -- it could never be bought"):format(dropper.Id))
        t.truthy(runtime.Signs[key], ("no sign for %s"):format(key))
    end
    for _, upgrade in ipairs(UpgradeData.List) do
        t.truthy(runtime.Pads["upgrade:" .. upgrade.Id], "no pad for upgrade " .. upgrade.Id)
    end
    for _, section in ipairs(SectionData.List) do
        if section.Id ~= SectionData.Base then
            t.truthy(runtime.Pads["section:" .. section.Id], "no pad for wing " .. section.Id)
        end
    end
    t.truthy(runtime.Pads.attune, "no attunement pad")
    t.truthy(runtime.Pads.transcend, "no transcendence pad")
    for slot = 1, GameConfig.Plot.SlotsPerSanctum do
        t.truthy(runtime.Pads["link:" .. slot], ("no link pad for slot %d"):format(slot))
    end
end)

t.test("pads carry the attributes the client reads", function()
    local _, runtime = build(1)
    local pad = runtime.Pads["dropper:" .. DropperData.List[1].Id]
    t.eq(pad:GetAttribute("PadKind"), "dropper")
    t.eq(pad:GetAttribute("PadId"), DropperData.List[1].Id)
    t.eq(runtime.Pads.attune:GetAttribute("PadKind"), "attune")
end)

t.test("no pad shares a position with another", function()
    local _, runtime = build(1)
    local seen = {}
    for key, pad in pairs(runtime.Pads) do
        local position = pad.Position
        local at = ("%.1f/%.1f/%.1f"):format(position.X, position.Y, position.Z)
        t.falsy(seen[at], ("pad %s sits on top of %s"):format(key, tostring(seen[at])))
        seen[at] = key
    end
end)

t.test("every part is anchored -- an unanchored Sanctum falls into the void", function()
    local model = build(1)
    local parts = 0
    for _, descendant in ipairs(model:GetDescendants()) do
        if descendant:IsA("BasePart") then
            parts += 1
            t.truthy(descendant.Anchored, ("%s is not anchored"):format(descendant:GetFullName()))
        end
    end
    t.gt(parts, 20, "a Sanctum should be more than a handful of parts")
end)

t.test("everything built lives under the model, so destroy really is complete", function()
    local model, runtime, parent = build(1)
    local strays = 0
    for _, child in ipairs(parent:GetChildren()) do
        if child ~= model then strays += 1 end
    end
    t.eq(strays, 0, "nothing was parented outside the sanctum model")

    -- The one legitimate exception is a hidden holder for locked wings; if the builder uses one it
    -- must still be cleaned up by destroy.
    local before = #workspace:GetDescendants()
    PlotBuilder.destroy(model)
    Mock.advance(0)
    t.eq(model.Parent, nil, "the model is unparented")
    t.lt(#workspace:GetDescendants(), before, "and its contents are gone")
end)

t.test("the conflux and font are placed where PlotLayout says", function()
    local _, runtime = build(3)
    local origin = PlotLayout.sanctumOrigin(3)
    t.lt((runtime.Conflux.Position - PlotLayout.confluxCFrame(origin).Position).Magnitude, 1)
    t.lt((runtime.Font.Position - PlotLayout.fontCFrame(origin).Position).Magnitude, 1)
end)

t.test("setConfluxAppearance applies colour, size and material", function()
    local _, runtime = build(1)
    local appearance = Theme.getConfluxAppearance(5, "tide")
    PlotBuilder.setConfluxAppearance(runtime, appearance)
    t.eq(runtime.Conflux.Color, appearance.Color)
    t.eq(runtime.Conflux.Material, appearance.Material)
    t.near(runtime.Conflux.Size.X, appearance.Size, 0.001)
    t.noThrow(function() PlotBuilder.setConfluxAppearance(runtime, nil) end)
    t.noThrow(function() PlotBuilder.setConfluxAppearance(runtime, { Color = "red" }) end)
end)

t.test("setSectionVisible hides and restores a locked wing", function()
    local _, runtime = build(1)
    local lockable
    for _, section in ipairs(SectionData.List) do
        if section.Id ~= SectionData.Base then lockable = section break end
    end
    local built = runtime.Sections[lockable.Id]
    local parentWhenVisible = built.Parent

    PlotBuilder.setSectionVisible(runtime, lockable.Id, false)
    -- Either reparented out of the world or made invisible and non-collidable; both are legitimate,
    -- but a locked wing must not be standable.
    local hidden = built.Parent ~= parentWhenVisible
    if not hidden then
        for _, descendant in ipairs(built:GetDescendants()) do
            if descendant:IsA("BasePart") then
                t.falsy(descendant.CanCollide, "a locked wing must not be walkable")
            end
        end
    end

    PlotBuilder.setSectionVisible(runtime, lockable.Id, true)
    t.eq(built.Parent, parentWhenVisible, "and it comes back")
    t.noThrow(function() PlotBuilder.setSectionVisible(runtime, "no_such_wing", false) end)
end)

t.test("two sanctums are built apart and do not share instances", function()
    local modelA, runtimeA, parent = build(1)
    local modelB, runtimeB = PlotBuilder.build(2, parent)
    t.neq(modelA, modelB)
    t.neq(runtimeA.Conflux, runtimeB.Conflux)
    t.neq(runtimeA.MoteFolder, runtimeB.MoteFolder)
    local gap = (runtimeA.Conflux.Position - runtimeB.Conflux.Position).Magnitude
    t.gt(gap, PlotLayout.SanctumSize.X / 2, ("sanctums are only %.0f studs apart"):format(gap))
end)

t.test("building every sanctum the config asks for does not explode", function()
    local parent = Instance.new("Folder", workspace)
    local runtimes = {}
    for index = 1, GameConfig.Plot.SanctumCount do
        local _, runtime = PlotBuilder.build(index, parent)
        table.insert(runtimes, runtime)
    end
    t.eq(#parent:GetChildren(), GameConfig.Plot.SanctumCount)
    -- Rough part-budget sanity: six sanctums should not be tens of thousands of instances.
    t.lt(#parent:GetDescendants(), 20000,
        ("a full server builds %d instances"):format(#parent:GetDescendants()))
end)

t.test("build tolerates junk arguments", function()
    local parent = Instance.new("Folder", workspace)
    t.noThrow(function() PlotBuilder.build(0, parent) end)
    t.noThrow(function() PlotBuilder.build(-1, parent) end)
    t.noThrow(function() PlotBuilder.destroy(nil) end)
    t.noThrow(function() PlotBuilder.destroy(Instance.new("Part")) end)
end)
