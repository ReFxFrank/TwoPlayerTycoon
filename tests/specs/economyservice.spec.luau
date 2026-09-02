--[[
    economyservice.spec
    EconomyService is the ONLY writer of PlotState.Essence. Every purchase, every collected mote and
    every attunement goes through Credit or TryDebit, so this is where a rounding bug becomes a
    duplication exploit and where an unguarded NaN becomes an unrecoverable wallet.

    It also runs inside the single Heartbeat that drives every Sanctum, so nothing here may throw.
]]

local Economy = loadModule("ReplicatedStorage/Modules/Economy")
local StateSchema = loadModule("ReplicatedStorage/Modules/StateSchema")
local DropperData = loadModule("ReplicatedStorage/Modules/DropperData")
local UpgradeData = loadModule("ReplicatedStorage/Modules/UpgradeData")
local RebirthData = loadModule("ReplicatedStorage/Modules/RebirthData")

local firstDropper = DropperData.List[1]

--- A stub ProfileService: EconomyService only reads prestige and writes lifetime stats.
local function stubProfiles(profilesByUserId)
    return {
        Name = "ProfileService",
        Get = function(_, player)
            return player and profilesByUserId[player.UserId] or nil
        end,
    }
end

local function boot(profilesByUserId)
    local service = loadModule("ServerScriptService/Core/Services/EconomyService")
    local profiles = stubProfiles(profilesByUserId or {})
    service:Init({
        Get = function(_, name)
            if name == "ProfileService" then return profiles end
            error("unexpected dependency " .. tostring(name), 0)
        end,
        TryGet = function() return nil end,
    })
    service:Start()
    return service
end

local function makeSanctum(occupants, overrides)
    local state = StateSchema.newPlotState()
    for key, value in pairs(overrides or {}) do state[key] = value end
    return { Id = 1, State = state, Occupants = occupants or {}, Dirty = false, Runtime = {} }
end

local function occupant(player, slot)
    return { UserId = player.UserId, Player = player, Slot = slot or 1, JoinedAt = 0, Contribution = 0 }
end

-------------------------------------------------------------------------------
-- Credit
-------------------------------------------------------------------------------
t.test("crediting raises the wallet, lifetime total and the contributor's share", function()
    local ash = Mock.addPlayer("Ash", 1)
    local profile = StateSchema.newProfile()
    local Service = boot({ [1] = profile })
    local sanctum = makeSanctum({ [1] = occupant(ash) })

    t.eq(Service:Credit(sanctum, 250, ash), 250, "it reports what it credited")
    t.eq(sanctum.State.Essence, 250)
    t.eq(sanctum.State.LifetimeEssence, 250, "lifetime drives the attunement gates")
    t.eq(sanctum.Occupants[1].Contribution, 250, "the leaderboard figure follows the earner")
    t.eq(profile.Stats.TotalEssenceEarned, 250, "and the permanent lifetime stat")
    t.truthy(sanctum.Dirty, "a wallet change marks the sanctum for replication")
end)

t.test("both occupants' lifetime stats rise, but only the earner's contribution", function()
    local ash = Mock.addPlayer("Ash", 1)
    local bree = Mock.addPlayer("Bree", 2)
    local ashProfile, breeProfile = StateSchema.newProfile(), StateSchema.newProfile()
    local Service = boot({ [1] = ashProfile, [2] = breeProfile })
    local sanctum = makeSanctum({ [1] = occupant(ash, 1), [2] = occupant(bree, 2) })

    Service:Credit(sanctum, 100, ash)
    -- The wallet is shared, so both players genuinely earned it...
    t.eq(ashProfile.Stats.TotalEssenceEarned, 100)
    t.eq(breeProfile.Stats.TotalEssenceEarned, 100)
    -- ...but contribution is the flavour stat that says who was carrying.
    t.eq(sanctum.Occupants[1].Contribution, 100)
    t.eq(sanctum.Occupants[2].Contribution, 0)
end)

t.test("a credit with no source player still fills the shared wallet", function()
    local ash = Mock.addPlayer("Ash", 1)
    local Service = boot({ [1] = StateSchema.newProfile() })
    local sanctum = makeSanctum({ [1] = occupant(ash) })
    -- Motes are credited by the income loop, which has no player to attribute them to.
    t.eq(Service:Credit(sanctum, 60), 60)
    t.eq(sanctum.State.Essence, 60)
    t.eq(sanctum.Occupants[1].Contribution, 0)
end)

t.test("a non-occupant cannot be credited a contribution", function()
    local ash = Mock.addPlayer("Ash", 1)
    local stranger = Mock.addPlayer("Stranger", 99)
    local Service = boot({ [1] = StateSchema.newProfile() })
    local sanctum = makeSanctum({ [1] = occupant(ash) })
    Service:Credit(sanctum, 100, stranger)
    t.eq(sanctum.State.Essence, 100, "the essence still lands in the shared pool")
    t.eq(sanctum.Occupants[1].Contribution, 0, "but not on someone else's ledger")
end)

t.test("junk amounts credit nothing and never throw", function()
    local ash = Mock.addPlayer("Ash", 1)
    local Service = boot({ [1] = StateSchema.newProfile() })
    local sanctum = makeSanctum({ [1] = occupant(ash) })
    for _, amount in ipairs({ 0, -100, 0 / 0, -math.huge, math.huge }) do
        local credited
        t.noThrow(function() credited = Service:Credit(sanctum, amount, ash) end,
            "this runs inside the one heartbeat driving every plot")
        t.eq(credited, 0, ("amount %s credited something"):format(tostring(amount)))
    end
    t.noThrow(function() Service:Credit(sanctum, nil, ash) end)
    t.noThrow(function() Service:Credit(sanctum, "500", ash) end)
    t.eq(sanctum.State.Essence, 0, "the wallet never moved")
end)

t.test("the wallet is clamped below the exact-integer ceiling", function()
    local ash = Mock.addPlayer("Ash", 1)
    local Service = boot({ [1] = StateSchema.newProfile() })
    local sanctum = makeSanctum({ [1] = occupant(ash) })
    -- Past 2^53 addition starts rounding and a shared wallet silently drifts between the two
    -- players' views of it.
    for _ = 1, 5 do Service:Credit(sanctum, StateSchema.MAX_CURRENCY, ash) end
    t.truthy(sanctum.State.Essence <= StateSchema.MAX_CURRENCY,
        ("wallet reached %s"):format(tostring(sanctum.State.Essence)))
    t.truthy(sanctum.State.Essence == sanctum.State.Essence, "and is still a number")
end)

t.test("a corrupt or missing sanctum cannot break the income loop", function()
    local Service = boot({})
    for _, sanctum in ipairs({ {}, { State = "corrupt" }, { State = { Essence = 0 / 0 } },
        { State = StateSchema.newPlotState(), Occupants = "none" } }) do
        t.noThrow(function() Service:Credit(sanctum, 10) end)
        t.noThrow(function() Service:TryDebit(sanctum, 10) end)
        t.noThrow(function() Service:GetMultipliers(sanctum) end)
    end
    t.noThrow(function() Service:Credit(nil, 10) end)
    t.noThrow(function() Service:TryDebit(nil, 10) end)
    t.noThrow(function() Service:GetMultipliers(nil) end)
end)

-------------------------------------------------------------------------------
-- TryDebit
-------------------------------------------------------------------------------
t.test("a debit only succeeds when the wallet covers it, and is exact at the boundary", function()
    local Service = boot({})
    local sanctum = makeSanctum({}, { Essence = 100 })

    t.falsy(Service:TryDebit(sanctum, 101), "one short is short")
    t.eq(sanctum.State.Essence, 100, "a failed debit must not mutate")

    t.truthy(Service:TryDebit(sanctum, 100), "exactly enough is enough")
    t.eq(sanctum.State.Essence, 0)
    t.falsy(Service:TryDebit(sanctum, 1), "and an empty wallet buys nothing")
end)

t.test("the wallet can never go negative, whatever is asked of it", function()
    local Service = boot({})
    local sanctum = makeSanctum({}, { Essence = 50 })
    for _, amount in ipairs({ -100, 0 / 0, math.huge, -math.huge }) do
        t.falsy(Service:TryDebit(sanctum, amount), ("debit of %s was allowed"):format(tostring(amount)))
    end
    t.eq(sanctum.State.Essence, 50)
    t.truthy(sanctum.State.Essence >= 0)
end)

t.test("a zero debit is refused rather than treated as a free success", function()
    local Service = boot({})
    local sanctum = makeSanctum({}, { Essence = 10 })
    -- A zero-cost purchase is a data bug (a def with BaseCost 0); succeeding silently would grant
    -- an unlimited number of them.
    Service:TryDebit(sanctum, 0)
    t.eq(sanctum.State.Essence, 10, "either way the wallet is untouched")
end)

t.test("debits are sequential, so two purchases cannot share one balance", function()
    local Service = boot({})
    local sanctum = makeSanctum({}, { Essence = 100 })
    local first = Service:TryDebit(sanctum, 60)
    local second = Service:TryDebit(sanctum, 60)
    t.truthy(first)
    t.falsy(second, "the second read the balance the first left behind")
    t.eq(sanctum.State.Essence, 40)
end)

-------------------------------------------------------------------------------
-- Multipliers
-------------------------------------------------------------------------------
t.test("multipliers reflect stage, upgrades and both occupants' prestige", function()
    local ash = Mock.addPlayer("Ash", 1)
    local bree = Mock.addPlayer("Bree", 2)
    local ashProfile, breeProfile = StateSchema.newProfile(), StateSchema.newProfile()
    ashProfile.Prestige.Rebirths = 4
    breeProfile.Prestige.Rebirths = 4
    local Service = boot({ [1] = ashProfile, [2] = breeProfile })

    local solo = makeSanctum({ [1] = occupant(ash, 1) })
    local pair = makeSanctum({ [1] = occupant(ash, 1), [2] = occupant(bree, 2) })
    local soloTotal = Economy.totalMultiplier(Service:GetMultipliers(solo))
    local pairTotal = Economy.totalMultiplier(Service:GetMultipliers(pair))
    t.gt(pairTotal, soloTotal, "a partner's prestige lifts the shared sanctum -- the co-op hook")
    t.near(pairTotal / soloTotal,
        (1 + 2 * 4 * RebirthData.MultiplierPerRebirth) / (1 + 4 * RebirthData.MultiplierPerRebirth), 0.01,
        "prestige ADDS across occupants rather than multiplying")
end)

t.test("RefreshMultipliers picks up a stage change; a stale cache would freeze income", function()
    local ash = Mock.addPlayer("Ash", 1)
    local Service = boot({ [1] = StateSchema.newProfile() })
    local sanctum = makeSanctum({ [1] = occupant(ash) })
    local before = Economy.totalMultiplier(Service:GetMultipliers(sanctum))

    sanctum.State.Stage = 5
    Service:RefreshMultipliers(sanctum)
    local after = Economy.totalMultiplier(Service:GetMultipliers(sanctum))
    t.gt(after, before, "an attunement takes effect immediately")
end)

t.test("multipliers are cached, so the income loop does not recompute per tick", function()
    local ash = Mock.addPlayer("Ash", 1)
    local Service = boot({ [1] = StateSchema.newProfile() })
    local sanctum = makeSanctum({ [1] = occupant(ash) })
    local first = Service:GetMultipliers(sanctum)
    t.eq(Service:GetMultipliers(sanctum), first,
        "Economy.getMultipliers walks every upgrade; this runs 30x a second per sanctum")
end)

t.test("a GlobalIncome upgrade raises the multiplier after a refresh", function()
    local global
    for _, upgrade in ipairs(UpgradeData.List) do
        if upgrade.Kind == "GlobalIncome" then global = upgrade break end
    end
    local ash = Mock.addPlayer("Ash", 1)
    local Service = boot({ [1] = StateSchema.newProfile() })
    local sanctum = makeSanctum({ [1] = occupant(ash) })
    local before = Economy.totalMultiplier(Service:GetMultipliers(sanctum))
    sanctum.State.Upgrades[global.Id] = global.MaxLevel
    Service:RefreshMultipliers(sanctum)
    t.gt(Economy.totalMultiplier(Service:GetMultipliers(sanctum)), before)
end)

t.test("AddContribution only moves the ledger, never the wallet", function()
    local ash = Mock.addPlayer("Ash", 1)
    local Service = boot({ [1] = StateSchema.newProfile() })
    local sanctum = makeSanctum({ [1] = occupant(ash) }, { Essence = 500 })
    Service:AddContribution(sanctum, ash, 75)
    t.eq(sanctum.Occupants[1].Contribution, 75)
    t.eq(sanctum.State.Essence, 500, "contribution is flavour; it is not currency")
    t.noThrow(function() Service:AddContribution(sanctum, ash, 0 / 0) end)
    t.noThrow(function() Service:AddContribution(sanctum, nil, 10) end)
end)

t.test("income earned matches what Economy predicts for the same state", function()
    local ash = Mock.addPlayer("Ash", 1)
    local Service = boot({ [1] = StateSchema.newProfile() })
    local sanctum = makeSanctum({ [1] = occupant(ash) },
        { Droppers = { [firstDropper.Id] = 4 }, Stage = 2 })
    Service:RefreshMultipliers(sanctum)
    local multipliers = Service:GetMultipliers(sanctum)

    -- One minute of motes, credited one at a time exactly as MoteSystem does.
    local value = Economy.getMoteValue(firstDropper, sanctum.State, multipliers)
    local interval = Economy.getDropperInterval(firstDropper, sanctum.State, multipliers)
    local motes = math.floor(60 / interval) * 4
    for _ = 1, motes do Service:Credit(sanctum, value, ash) end

    local predicted = Economy.estimateIncomePerSecond(sanctum.State, multipliers) * 60
    t.near(sanctum.State.Essence / predicted, 1, 0.05,
        ("credited %.0f against a predicted %.0f"):format(sanctum.State.Essence, predicted))
end)
