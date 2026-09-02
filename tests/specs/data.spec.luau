--[[
    data.spec
    Cross-references every shared data table. Content lives in six separate modules, so nothing but
    a test stops one of them drifting from the others — a dropper gated behind a wing that no longer
    exists would only show up in-game as an unbuyable pad.
]]

local DropperData = loadModule("ReplicatedStorage/Modules/DropperData")
local UpgradeData = loadModule("ReplicatedStorage/Modules/UpgradeData")
local SectionData = loadModule("ReplicatedStorage/Modules/SectionData")
local EvolutionData = loadModule("ReplicatedStorage/Modules/EvolutionData")
local AffinityData = loadModule("ReplicatedStorage/Modules/AffinityData")
local RebirthData = loadModule("ReplicatedStorage/Modules/RebirthData")
local GameConfig = loadModule("ReplicatedStorage/Modules/GameConfig")

local function idSet(list)
    local set = {}
    for _, entry in ipairs(list) do set[entry.Id] = entry end
    return set
end

t.test("every data list has matching List and ById views", function()
    for label, data in pairs({ Dropper = DropperData, Upgrade = UpgradeData, Section = SectionData, Affinity = AffinityData }) do
        t.truthy(#data.List > 0, label .. "Data.List is populated")
        for _, entry in ipairs(data.List) do
            t.eq(data.ById[entry.Id], entry, ("%s %s is reachable via ById"):format(label, entry.Id))
            t.eq(data.get(entry.Id), entry, ("%s.get(%q) works"):format(label, entry.Id))
        end
        t.eq(data.get("does_not_exist"), nil, label .. ".get returns nil for unknown ids")
    end
end)

t.test("ids are unique, lowercase and stable", function()
    for label, data in pairs({ Dropper = DropperData, Upgrade = UpgradeData, Section = SectionData, Affinity = AffinityData }) do
        local seen = {}
        for _, entry in ipairs(data.List) do
            t.falsy(seen[entry.Id], ("duplicate %s id %q"):format(label, tostring(entry.Id)))
            seen[entry.Id] = true
            t.truthy(entry.Id:match("^[a-z0-9_]+$"), ("%s id %q must be lowercase snake_case"):format(label, tostring(entry.Id)))
            t.truthy(#entry.Name > 0, label .. " " .. entry.Id .. " needs a display name")
            t.truthy(#entry.Description > 0, label .. " " .. entry.Id .. " needs a description")
        end
    end
end)

t.test("droppers reference real sections and reachable stages", function()
    local sections = idSet(SectionData.List)
    for _, dropper in ipairs(DropperData.List) do
        t.truthy(sections[dropper.RequiredSection],
            ("dropper %s requires unknown section %q"):format(dropper.Id, tostring(dropper.RequiredSection)))
        t.truthy(dropper.RequiredStage >= 1 and dropper.RequiredStage <= EvolutionData.MaxStage,
            ("dropper %s has out-of-range RequiredStage"):format(dropper.Id))
        t.gt(dropper.BaseCost, 0, dropper.Id .. " BaseCost")
        t.gt(dropper.BaseValue, 0, dropper.Id .. " BaseValue")
        t.gt(dropper.Interval, 0, dropper.Id .. " Interval")
        t.gt(dropper.MaxOwned, 0, dropper.Id .. " MaxOwned")
        t.truthy(dropper.CostGrowth > 1 and dropper.CostGrowth < 2,
            ("dropper %s CostGrowth %s should sit between 1 and 2"):format(dropper.Id, tostring(dropper.CostGrowth)))
    end
end)

t.test("upgrades reference real sections and cover every effect kind", function()
    local sections = idSet(SectionData.List)
    local kinds = {}
    for _, upgrade in ipairs(UpgradeData.List) do
        t.truthy(sections[upgrade.RequiredSection],
            ("upgrade %s requires unknown section %q"):format(upgrade.Id, tostring(upgrade.RequiredSection)))
        t.gt(upgrade.MaxLevel, 0, upgrade.Id .. " MaxLevel")
        t.gt(upgrade.BaseCost, 0, upgrade.Id .. " BaseCost")
        kinds[upgrade.Kind] = true
    end
    for _, kind in ipairs({ "RailSpeed", "FontYield", "SpawnRate", "MoteCapacity", "GlobalIncome" }) do
        t.truthy(kinds[kind], "no upgrade provides the " .. kind .. " effect")
    end
end)

t.test("sections form a valid unlock chain rooted at the free base wing", function()
    local sections = idSet(SectionData.List)
    t.truthy(sections[SectionData.Base], "SectionData.Base names a real section")
    t.eq(sections[SectionData.Base].Cost, 0, "the base wing is free")
    for _, section in ipairs(SectionData.List) do
        if section.RequiredSection then
            t.truthy(sections[section.RequiredSection],
                ("section %s requires unknown section %q"):format(section.Id, tostring(section.RequiredSection)))
            t.neq(section.RequiredSection, section.Id, "a section cannot require itself")
        end
        if section.Id ~= SectionData.Base then
            t.gt(section.Cost, 0, section.Id .. " should cost something")
        end
    end
end)

t.test("sections do not overlap in world space", function()
    for indexA, a in ipairs(SectionData.List) do
        for indexB, b in ipairs(SectionData.List) do
            if indexA < indexB then
                local gapX = math.abs(a.Offset.X - b.Offset.X) - (a.Size.X + b.Size.X) / 2
                local gapZ = math.abs(a.Offset.Z - b.Offset.Z) - (a.Size.Z + b.Size.Z) / 2
                t.truthy(gapX > -0.001 or gapZ > -0.001,
                    ("sections %s and %s overlap"):format(a.Id, b.Id))
            end
        end
    end
end)

t.test("evolution stages are ordered, monotonic and only unlock ids that exist", function()
    local droppers, upgrades, sections = idSet(DropperData.List), idSet(UpgradeData.List), idSet(SectionData.List)
    t.eq(#EvolutionData.Stages, 6, "six stages, per the design brief")
    t.eq(EvolutionData.MaxStage, #EvolutionData.Stages)
    t.eq(EvolutionData.Stages[1].RequiredEssence, 0, "stage 1 is where every sanctum starts")

    local previous
    for index, stage in ipairs(EvolutionData.Stages) do
        t.eq(stage.Index, index, "stage Index matches its position")
        t.eq(EvolutionData.get(index), stage)
        if previous then
            t.gt(stage.RequiredEssence, previous.RequiredEssence, "attunement cost rises with stage " .. index)
            t.gt(stage.IncomeMultiplier, previous.IncomeMultiplier, "income multiplier rises with stage " .. index)
            t.truthy(stage.RequiredLifetimeEssence >= previous.RequiredLifetimeEssence,
                "lifetime requirement never falls at stage " .. index)
        end
        for _, id in ipairs(stage.UnlockedDroppers) do
            t.truthy(droppers[id], ("stage %d unlocks unknown dropper %q"):format(index, id))
            t.truthy(droppers[id].RequiredStage <= index,
                ("stage %d unlocks %s but that dropper is gated at stage %d"):format(index, id, droppers[id].RequiredStage))
        end
        for _, id in ipairs(stage.UnlockedUpgrades) do
            t.truthy(upgrades[id], ("stage %d unlocks unknown upgrade %q"):format(index, id))
        end
        for _, id in ipairs(stage.UnlockedSections) do
            t.truthy(sections[id], ("stage %d unlocks unknown section %q"):format(index, id))
        end
        previous = stage
    end
    t.eq(EvolutionData.next(EvolutionData.MaxStage), nil, "there is nothing past the final stage")
    t.eq(EvolutionData.next(1), EvolutionData.Stages[2])
end)

t.test("every dropper and upgrade becomes reachable at some stage", function()
    local unlockedDroppers, unlockedUpgrades, unlockedSections = {}, {}, {}
    for _, stage in ipairs(EvolutionData.Stages) do
        for _, id in ipairs(stage.UnlockedDroppers) do unlockedDroppers[id] = true end
        for _, id in ipairs(stage.UnlockedUpgrades) do unlockedUpgrades[id] = true end
        for _, id in ipairs(stage.UnlockedSections) do unlockedSections[id] = true end
    end
    for _, dropper in ipairs(DropperData.List) do
        t.truthy(unlockedDroppers[dropper.Id], ("dropper %s is never unlocked by any stage"):format(dropper.Id))
    end
    for _, upgrade in ipairs(UpgradeData.List) do
        t.truthy(unlockedUpgrades[upgrade.Id], ("upgrade %s is never unlocked by any stage"):format(upgrade.Id))
    end
    for _, section in ipairs(SectionData.List) do
        t.truthy(unlockedSections[section.Id], ("section %s is never unlocked by any stage"):format(section.Id))
    end
end)

t.test("affinity unlock stage is inside the stage range", function()
    t.truthy(EvolutionData.AffinityUnlockStage >= 1 and EvolutionData.AffinityUnlockStage <= EvolutionData.MaxStage)
    t.eq(#AffinityData.List, 4, "four elemental lines")
    for _, affinity in ipairs(AffinityData.List) do
        t.truthy(AffinityData.isValid(affinity.Id))
        for _, field in ipairs({ "IncomeMultiplier", "SpawnRateMultiplier", "MoteValueMultiplier", "RailSpeedMultiplier" }) do
            t.gt(affinity[field], 0, ("%s.%s must be positive"):format(affinity.Id, field))
        end
    end
    t.falsy(AffinityData.isValid("plasma"), "unknown affinities are rejected")
    t.falsy(AffinityData.isValid(nil))
    t.falsy(AffinityData.isValid(42))
end)

t.test("affinities are balanced on raw income", function()
    -- Only these three axes compound into Essence per second. RailSpeed and WalkSpeed are texture:
    -- they change how the Sanctum feels (motes in flight, traversal) without changing the rate.
    local min, max = math.huge, -math.huge
    for _, affinity in ipairs(AffinityData.List) do
        local income = affinity.IncomeMultiplier * affinity.SpawnRateMultiplier * affinity.MoteValueMultiplier
        min = math.min(min, income)
        max = math.max(max, income)
    end
    t.lt(max / min, 1.05, "the best and worst income affinity are within 5% of each other")
end)

t.test("no affinity strictly dominates another", function()
    -- The real balance property: for every pair there must be an axis where each one wins, so the
    -- choice is a trade-off rather than a right answer.
    local AXES = { "IncomeMultiplier", "SpawnRateMultiplier", "MoteValueMultiplier",
        "RailSpeedMultiplier", "WalkSpeedBonus" }
    for _, a in ipairs(AffinityData.List) do
        for _, b in ipairs(AffinityData.List) do
            if a.Id ~= b.Id then
                local aWinsSomewhere = false
                for _, axis in ipairs(AXES) do
                    if a[axis] > b[axis] then
                        aWinsSomewhere = true
                        break
                    end
                end
                t.truthy(aWinsSomewhere, ("%s is strictly dominated by %s"):format(a.Id, b.Id))
            end
        end
    end
end)

t.test("rebirth badges are ordered and awarded correctly", function()
    t.eq(RebirthData.RequiredStage, EvolutionData.MaxStage, "transcendence is gated on the final stage")
    t.truthy(#RebirthData.Badges >= 5, "at least five milestone badges")
    local previous = -1
    for _, badge in ipairs(RebirthData.Badges) do
        t.gt(badge.Rebirths, previous, "badges are listed in ascending order")
        previous = badge.Rebirths
    end
    t.deepEq(RebirthData.badgesFor(0), {}, "nothing is awarded before the first transcendence")
    local first = RebirthData.Badges[1]
    t.truthy(RebirthData.badgesFor(first.Rebirths)[first.Id], "the first badge is awarded at its threshold")
    t.eq(RebirthData.highestBadge(0), nil)
    t.eq(RebirthData.highestBadge(10000), RebirthData.Badges[#RebirthData.Badges], "the top badge caps out")
end)

t.test("GameConfig exposes the tunables the rest of the game reads", function()
    t.eq(GameConfig.Plot.SlotsPerSanctum, 2, "two-player plots")
    t.gt(GameConfig.Plot.SanctumCount, 0)
    t.gt(GameConfig.Mote.MaxLivePerSanctum, 0)
    t.gt(GameConfig.Save.AutosaveSeconds, 0)
    t.gt(GameConfig.Session.LockStaleSeconds, GameConfig.Save.AutosaveSeconds,
        "a stale-lock timeout shorter than the autosave interval would steal live sessions")
    t.gt(GameConfig.Rebirth.VoteWindowSeconds, 0)
    t.truthy(GameConfig.Mote.MinTravelSeconds < GameConfig.Mote.BaseTravelSeconds)
    t.falsy(GameConfig.Debug.Enabled, "debug mode must ship off")
    t.falsy(GameConfig.Debug.FastMode, "fast mode must ship off")
end)
