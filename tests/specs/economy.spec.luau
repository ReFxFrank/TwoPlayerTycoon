--[[
    economy.spec
    Economy is the pure rules engine both the server (to authorise) and the client (to grey out a
    button) read from. A disagreement between them is a duplicated bug, so these tests pin the
    contract: closed-set reason codes, monotonic cost curves, and total functions on hostile input.

    PlotStates are built inline rather than via StateSchema so a failure here points at Economy.
]]

local Economy = loadModule("ReplicatedStorage/Modules/Economy")
local DropperData = loadModule("ReplicatedStorage/Modules/DropperData")
local UpgradeData = loadModule("ReplicatedStorage/Modules/UpgradeData")
local SectionData = loadModule("ReplicatedStorage/Modules/SectionData")
local EvolutionData = loadModule("ReplicatedStorage/Modules/EvolutionData")
local AffinityData = loadModule("ReplicatedStorage/Modules/AffinityData")
local RebirthData = loadModule("ReplicatedStorage/Modules/RebirthData")

local R = Economy.Reason

local function plot(overrides)
    local base = {
        Essence = 0,
        Stage = 1,
        Affinity = nil,
        Droppers = {},
        Upgrades = {},
        Sections = { [SectionData.Base] = true },
        LifetimeEssence = 0,
    }
    for key, value in pairs(overrides or {}) do base[key] = value end
    return base
end

--- A plot at `stage` with every wing and dropper that stage allows, for gate tests.
local function plotAtStage(stage, essence)
    local sections, droppers = {}, {}
    for _, section in ipairs(SectionData.List) do
        if section.RequiredStage <= stage then sections[section.Id] = true end
    end
    for _, dropper in ipairs(DropperData.List) do
        if dropper.RequiredStage <= stage then droppers[dropper.Id] = 1 end
    end
    return plot({ Stage = stage, Essence = essence or 0, Sections = sections, Droppers = droppers,
        LifetimeEssence = essence or 0 })
end

local firstDropper = DropperData.List[1]

-------------------------------------------------------------------------------
-- Multipliers
-------------------------------------------------------------------------------
t.test("prestige multiplier grows linearly and ignores junk", function()
    t.eq(Economy.getPrestigeMultiplier(0), 1)
    t.near(Economy.getPrestigeMultiplier(4), 1 + 4 * RebirthData.MultiplierPerRebirth, 1e-9)
    t.eq(Economy.getPrestigeMultiplier(-5), 1, "negative rebirths cannot shrink income")
    t.eq(Economy.getPrestigeMultiplier(0 / 0), 1)
    t.eq(Economy.getPrestigeMultiplier(nil), 1)
    t.eq(Economy.getPrestigeMultiplier("10"), 1)
end)

t.test("a partner's prestige adds to the shared sanctum multiplier", function()
    local solo = Economy.getSanctumPrestigeMultiplier({ 4 })
    local pair = Economy.getSanctumPrestigeMultiplier({ 4, 4 })
    t.gt(pair, solo, "two veterans out-earn one — this is the co-op hook")
    t.near(pair, 1 + 2 * (4 * RebirthData.MultiplierPerRebirth), 1e-9)
    t.eq(Economy.getSanctumPrestigeMultiplier({}), 1, "an empty sanctum is neutral, not zero")
    t.eq(Economy.getSanctumPrestigeMultiplier(nil), 1)
    t.noThrow(function() return Economy.getSanctumPrestigeMultiplier({ 0 / 0, "x", -3 }) end)
end)

t.test("getMultipliers reflects stage, affinity and upgrades", function()
    local base = Economy.getMultipliers(plot(), {})
    t.eq(base.Stage, EvolutionData.Stages[1].IncomeMultiplier)
    t.eq(base.Affinity, 1, "no affinity chosen yet is neutral")
    t.eq(base.Debug, 1, "debug multiplier is off in shipping config")

    local late = Economy.getMultipliers(plot({ Stage = 5, Affinity = "ember" }), {})
    t.gt(late.Stage, base.Stage)
    t.eq(late.Affinity, AffinityData.ById.ember.IncomeMultiplier)
    t.gt(Economy.totalMultiplier(late), Economy.totalMultiplier(base))
end)

t.test("totalMultiplier degrades gracefully on a partial or corrupt table", function()
    t.eq(Economy.totalMultiplier({}), 1, "missing fields read as neutral, never zero")
    t.eq(Economy.totalMultiplier(nil), 1)
    t.gt(Economy.totalMultiplier({ Stage = 2 }), 1)
    local runaway = Economy.totalMultiplier({ Prestige = math.huge, Stage = math.huge })
    t.truthy(runaway == runaway and runaway ~= math.huge, "a runaway multiplier is clamped finite")
end)

t.test("upgradeLevel and upgradeEffect only count known upgrades", function()
    local upgrade = UpgradeData.List[1]
    local state = plot({ Upgrades = { [upgrade.Id] = 3, not_a_real_upgrade = 999 } })
    t.eq(Economy.upgradeLevel(state, upgrade.Id), 3)
    t.eq(Economy.upgradeLevel(state, "not_a_real_upgrade"), 0, "unknown ids contribute nothing")
    t.eq(Economy.upgradeLevel(state, nil), 0)
    t.near(Economy.upgradeEffect(state, upgrade.Kind), upgrade.PerLevel * 3, 1e-9)
    t.eq(Economy.upgradeEffect(state, "NotAKind"), 0)
end)

-------------------------------------------------------------------------------
-- Cost curves
-------------------------------------------------------------------------------
t.test("dropper cost grows geometrically and is always a positive integer", function()
    local previous = 0
    for owned = 0, 12 do
        local cost = Economy.getDropperCost(firstDropper, owned)
        t.gt(cost, previous, "cost strictly rises with the number owned")
        t.eq(cost, math.floor(cost), "costs are whole numbers")
        previous = cost
    end
    t.eq(Economy.getDropperCost(firstDropper, 0), math.floor(firstDropper.BaseCost))
end)

t.test("cost helpers never return NaN, inf or a negative for junk input", function()
    for _, owned in ipairs({ -5, 0 / 0, math.huge, 1e308 }) do
        local cost = Economy.getDropperCost(firstDropper, owned)
        t.truthy(cost == cost, "not NaN")
        t.truthy(cost >= 0 and cost < math.huge, ("cost stayed finite and non-negative: %s"):format(tostring(cost)))
    end
    t.noThrow(function() return Economy.getDropperCost(nil, 0) end)
    t.noThrow(function() return Economy.getUpgradeCost(nil, 0) end)
    t.noThrow(function() return Economy.getSectionCost(nil) end)
    t.eq(Economy.getSectionCost(SectionData.ById[SectionData.Base]), 0)
end)

t.test("upgrade cost rises per level", function()
    local upgrade = UpgradeData.List[1]
    t.gt(Economy.getUpgradeCost(upgrade, 1), Economy.getUpgradeCost(upgrade, 0))
    t.gt(Economy.getUpgradeCost(upgrade, 5), Economy.getUpgradeCost(upgrade, 1))
end)

-------------------------------------------------------------------------------
-- Rates
-------------------------------------------------------------------------------
t.test("mote value scales with multipliers and stays finite", function()
    local state = plot()
    local neutral = Economy.getMoteValue(firstDropper, state, Economy.getMultipliers(state, {}))
    t.gt(neutral, 0)

    local boostedState = plot({ Stage = 5 })
    local boosted = Economy.getMoteValue(firstDropper, boostedState,
        Economy.getMultipliers(boostedState, { 10, 10 }))
    t.gt(boosted, neutral, "stage and prestige raise mote value")
    t.truthy(boosted < math.huge)
    t.noThrow(function() return Economy.getMoteValue(nil, state, nil) end)
end)

t.test("dropper interval and rail time are clamped to sane floors", function()
    local state = plot()
    local multipliers = Economy.getMultipliers(state, {})
    t.gt(Economy.getDropperInterval(firstDropper, state, multipliers), 0.14)
    t.noThrow(function() return Economy.getDropperInterval(nil, state, multipliers) end)

    local GameConfig = loadModule("ReplicatedStorage/Modules/GameConfig")
    local slow = Economy.getRailTravelTime(state, multipliers)
    t.truthy(slow <= GameConfig.Mote.BaseTravelSeconds + 1e-9)
    t.truthy(slow >= GameConfig.Mote.MinTravelSeconds - 1e-9)

    -- Max out every rail-speed upgrade: travel time must fall but never reach zero.
    local upgrades = {}
    for _, upgrade in ipairs(UpgradeData.List) do upgrades[upgrade.Id] = upgrade.MaxLevel end
    local fastState = plot({ Upgrades = upgrades, Affinity = "zephyr" })
    local fast = Economy.getRailTravelTime(fastState, Economy.getMultipliers(fastState, {}))
    t.truthy(fast >= GameConfig.Mote.MinTravelSeconds - 1e-9, "rails never become instant")
    t.truthy(fast <= slow)
end)

t.test("mote capacity and walkspeed respond to upgrades and stage", function()
    local GameConfig = loadModule("ReplicatedStorage/Modules/GameConfig")
    t.eq(Economy.getMoteCapacity(plot()), GameConfig.Mote.MaxLivePerSanctum)
    local upgrades = {}
    for _, upgrade in ipairs(UpgradeData.List) do upgrades[upgrade.Id] = upgrade.MaxLevel end
    t.gt(Economy.getMoteCapacity(plot({ Upgrades = upgrades })), Economy.getMoteCapacity(plot()))

    t.eq(Economy.getWalkSpeed(plot()), EvolutionData.Stages[1].WalkSpeed)
    t.gt(Economy.getWalkSpeed(plot({ Stage = 6, Affinity = "zephyr" })), Economy.getWalkSpeed(plot()))
end)

t.test("income estimate rises with droppers and is zero for an empty sanctum", function()
    local empty = plot()
    t.eq(Economy.estimateIncomePerSecond(empty, Economy.getMultipliers(empty, {})), 0)

    local one = plot({ Droppers = { [firstDropper.Id] = 1 } })
    local two = plot({ Droppers = { [firstDropper.Id] = 2 } })
    local rateOne = Economy.estimateIncomePerSecond(one, Economy.getMultipliers(one, {}))
    local rateTwo = Economy.estimateIncomePerSecond(two, Economy.getMultipliers(two, {}))
    t.gt(rateOne, 0)
    t.near(rateTwo / rateOne, 2, 0.01, "income is linear in dropper count")

    -- Unknown ids in a tampered save must not contribute income.
    local tampered = plot({ Droppers = { [firstDropper.Id] = 1, hacked_dropper = 1e9 } })
    t.near(Economy.estimateIncomePerSecond(tampered, Economy.getMultipliers(tampered, {})), rateOne, 1e-6)
end)

-------------------------------------------------------------------------------
-- Gates: every reason is a closed-set code
-------------------------------------------------------------------------------
local function assertClosedSet(reason)
    for _, known in pairs(R) do
        if reason == known then return end
    end
    t.fail(("reason %q is not in Economy.Reason"):format(tostring(reason)))
end

t.test("dropperStatus reports the correct blocking reason", function()
    local lateDropper
    for _, dropper in ipairs(DropperData.List) do
        if dropper.RequiredStage > 1 then lateDropper = dropper break end
    end
    t.truthy(lateDropper, "the data should gate at least one dropper behind a later stage")

    local ok, reason = Economy.dropperStatus(plot(), lateDropper)
    t.falsy(ok)
    t.eq(reason, R.LockedStage)

    local broke = plotAtStage(lateDropper.RequiredStage, 0)
    broke.Droppers = {}
    ok, reason = Economy.dropperStatus(broke, lateDropper)
    t.falsy(ok)
    t.eq(reason, R.Insufficient, "unlocked but unaffordable")

    local rich = plotAtStage(lateDropper.RequiredStage, 1e12)
    rich.Droppers = {}
    ok, reason = Economy.dropperStatus(rich, lateDropper)
    t.truthy(ok)
    t.eq(reason, R.Ok)

    local capped = plotAtStage(lateDropper.RequiredStage, 1e12)
    capped.Droppers[lateDropper.Id] = lateDropper.MaxOwned
    ok, reason = Economy.dropperStatus(capped, lateDropper)
    t.falsy(ok)
    t.eq(reason, R.MaxOwned)

    ok, reason = Economy.dropperStatus(rich, nil)
    t.falsy(ok, "a nil def is never purchasable")
    assertClosedSet(reason)
end)

t.test("upgradeStatus and sectionStatus use the same closed reason set", function()
    local upgrade = UpgradeData.List[1]
    local rich = plotAtStage(EvolutionData.MaxStage, 1e15)
    local ok, reason = Economy.upgradeStatus(rich, upgrade)
    t.truthy(ok)
    t.eq(reason, R.Ok)

    rich.Upgrades[upgrade.Id] = upgrade.MaxLevel
    ok, reason = Economy.upgradeStatus(rich, upgrade)
    t.falsy(ok)
    t.eq(reason, R.MaxLevel)

    local owned = plotAtStage(EvolutionData.MaxStage, 1e15)
    ok, reason = Economy.sectionStatus(owned, SectionData.ById[SectionData.Base])
    t.falsy(ok)
    t.eq(reason, R.AlreadyOwned, "the base wing is unlocked from the start")

    for _, status in ipairs({ { Economy.upgradeStatus(plot(), nil) }, { Economy.sectionStatus(plot(), nil) } }) do
        t.falsy(status[1])
        assertClosedSet(status[2])
    end
end)

t.test("attuneStatus walks the whole stage ladder", function()
    local ok, reason = Economy.attuneStatus(plot())
    t.falsy(ok, "a fresh sanctum cannot afford stage 2")
    assertClosedSet(reason)

    for index = 1, EvolutionData.MaxStage - 1 do
        local nextStage = EvolutionData.Stages[index + 1]
        local ready = plotAtStage(index, nextStage.RequiredEssence)
        ready.LifetimeEssence = math.max(nextStage.RequiredLifetimeEssence, nextStage.RequiredEssence)
        -- plotAtStage grants one of each unlocked dropper; top up if the stage wants more.
        local needed = nextStage.RequiredDroppers
        local firstId = DropperData.List[1].Id
        ready.Droppers[firstId] = math.max(ready.Droppers[firstId] or 0, needed)
        local canAttune, why = Economy.attuneStatus(ready)
        t.truthy(canAttune, ("stage %d -> %d should be reachable (blocked by %s)"):format(index, index + 1, tostring(why)))
    end

    local maxed = plotAtStage(EvolutionData.MaxStage, 1e18)
    ok, reason = Economy.attuneStatus(maxed)
    t.falsy(ok)
    t.eq(reason, R.MaxStage)
end)

t.test("transcendStatus requires the final stage", function()
    local ok, reason = Economy.transcendStatus(plotAtStage(1, 1e18))
    t.falsy(ok)
    t.eq(reason, R.NeedStage)

    local ready = plotAtStage(RebirthData.RequiredStage, 1e18)
    ready.LifetimeEssence = math.max(RebirthData.RequiredLifetimeEssence, 1e18)
    ok, reason = Economy.transcendStatus(ready)
    t.truthy(ok, "blocked by " .. tostring(reason))
end)

t.test("canAfford is exact at the boundary and rejects junk costs", function()
    t.truthy(Economy.canAfford(plot({ Essence = 100 }), 100), "exactly enough is enough")
    t.falsy(Economy.canAfford(plot({ Essence = 99.999 }), 100))
    t.falsy(Economy.canAfford(plot({ Essence = 100 }), 0 / 0), "a NaN cost is never affordable")
    t.falsy(Economy.canAfford(plot({ Essence = 100 }), math.huge))
    t.falsy(Economy.canAfford(plot({ Essence = 0 / 0 }), 1), "a corrupt wallet buys nothing")
    t.noThrow(function() return Economy.canAfford(nil, 1) end)
end)

t.test("every gate function survives a completely corrupt plot state", function()
    local hostile = { Essence = 0 / 0, Stage = -3, Droppers = "not a table",
        Upgrades = { [1] = 2 }, Sections = 5, LifetimeEssence = math.huge }
    for _, call in ipairs({
        function() return Economy.attuneStatus(hostile) end,
        function() return Economy.transcendStatus(hostile) end,
        function() return Economy.dropperStatus(hostile, firstDropper) end,
        function() return Economy.upgradeStatus(hostile, UpgradeData.List[1]) end,
        function() return Economy.sectionStatus(hostile, SectionData.List[2]) end,
        function() return Economy.totalDroppersOwned(hostile) end,
        function() return Economy.getMultipliers(hostile, { "x" }) end,
        function() return Economy.estimateIncomePerSecond(hostile, {}) end,
        function() return Economy.getMoteCapacity(hostile) end,
        function() return Economy.getWalkSpeed(hostile) end,
    }) do
        t.noThrow(call, "Economy must be total: a corrupt save cannot crash the server loop")
    end
    for _, state in ipairs({ {}, { Essence = 5 } }) do
        t.noThrow(function() return Economy.attuneStatus(state) end)
    end
end)

t.test("totalDroppersOwned counts only real droppers", function()
    t.eq(Economy.totalDroppersOwned(plot()), 0)
    t.eq(Economy.totalDroppersOwned(plot({ Droppers = { [firstDropper.Id] = 3 } })), 3)
    t.eq(Economy.totalDroppersOwned(plot({ Droppers = { [firstDropper.Id] = 3, fake = 100 } })), 3)
    t.eq(Economy.totalDroppersOwned(plot({ Droppers = { [firstDropper.Id] = -5 } })), 0,
        "a negative count cannot subtract from the total")
end)
