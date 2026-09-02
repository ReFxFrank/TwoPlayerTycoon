--[[
    stateschema.spec
    Two hostile inputs reach this module: a DataStore value (which may be corrupt, truncated, from an
    older build, or hand-edited) and a partner's PlotState arriving through a link. Everything here
    exists to prove neither can produce an illegal Profile or an error.
]]

local StateSchema = loadModule("ReplicatedStorage/Modules/StateSchema")
local Snapshot = loadModule("ReplicatedStorage/Modules/Snapshot")
local DropperData = loadModule("ReplicatedStorage/Modules/DropperData")
local UpgradeData = loadModule("ReplicatedStorage/Modules/UpgradeData")
local SectionData = loadModule("ReplicatedStorage/Modules/SectionData")
local EvolutionData = loadModule("ReplicatedStorage/Modules/EvolutionData")
local RebirthData = loadModule("ReplicatedStorage/Modules/RebirthData")
local Economy = loadModule("ReplicatedStorage/Modules/Economy")

local firstDropper = DropperData.List[1]
local secondDropper = DropperData.List[2]
local firstUpgrade = UpgradeData.List[1]

local function assertLegalProfile(profile)
    t.truthy(type(profile) == "table", "a Profile is always a table")
    t.eq(profile.SchemaVersion, StateSchema.VERSION)
    for _, key in ipairs({ "Plot", "Prestige", "Settings", "Stats" }) do
        t.truthy(type(profile[key]) == "table", key .. " is present")
    end
    local plot = profile.Plot
    t.truthy(plot.Essence == plot.Essence and plot.Essence >= 0 and plot.Essence < math.huge,
        "Essence is a finite non-negative number")
    t.truthy(plot.Stage >= 1 and plot.Stage <= EvolutionData.MaxStage and plot.Stage % 1 == 0,
        "Stage is a whole number inside the ladder")
    for _, field in ipairs({ "Droppers", "Upgrades", "Sections" }) do
        t.truthy(type(plot[field]) == "table", field .. " is a table")
    end
    for id, count in pairs(plot.Droppers) do
        t.truthy(DropperData.get(id) ~= nil, ("unknown dropper %q survived sanitising"):format(tostring(id)))
        t.truthy(type(count) == "number" and count > 0 and count % 1 == 0, "counts are positive integers")
    end
    for id in pairs(plot.Upgrades) do
        t.truthy(UpgradeData.get(id) ~= nil, ("unknown upgrade %q survived"):format(tostring(id)))
    end
    for id in pairs(plot.Sections) do
        t.truthy(SectionData.get(id) ~= nil, ("unknown section %q survived"):format(tostring(id)))
    end
    if plot.Affinity ~= nil then
        t.truthy(type(plot.Affinity) == "string")
    end
    t.truthy(profile.Prestige.Rebirths >= 0)
    t.truthy(type(profile.Settings.Music) == "boolean")
    t.truthy(type(profile.Settings.Sfx) == "boolean")
end

-------------------------------------------------------------------------------
-- Construction
-------------------------------------------------------------------------------
t.test("a new profile is legal, empty and versioned", function()
    local profile = StateSchema.newProfile()
    assertLegalProfile(profile)
    t.eq(profile.Plot.Essence, 0)
    t.eq(profile.Plot.Stage, 1)
    t.eq(profile.Plot.Affinity, nil)
    t.eq(profile.Prestige.Rebirths, 0)
    t.eq(profile.Prestige.Multiplier, 1)
    t.truthy(profile.Settings.Music, "settings default ON: a missing setting must not mute a player")
    t.truthy(profile.Settings.Sfx)
end)

t.test("two new profiles do not share nested tables", function()
    local a, b = StateSchema.newProfile(), StateSchema.newProfile()
    a.Plot.Droppers[firstDropper.Id] = 5
    t.eq(b.Plot.Droppers[firstDropper.Id], nil, "a shared table would link every player's save")
    t.neq(a.Plot, b.Plot)
end)

t.test("clonePlotState detaches and repairs in one step", function()
    local original = StateSchema.newPlotState()
    original.Droppers[firstDropper.Id] = 3
    original.Droppers.ghost_dropper = 99
    local copy = StateSchema.clonePlotState(original)
    copy.Droppers[firstDropper.Id] = 99
    t.eq(original.Droppers[firstDropper.Id], 3, "the original is untouched")
    t.eq(copy.Droppers.ghost_dropper, nil, "cloning also drops the unknown id")
end)

-------------------------------------------------------------------------------
-- Sanitising
-------------------------------------------------------------------------------
t.test("sanitizeProfile turns any garbage into a legal profile without erroring", function()
    local cyclic = { Plot = {} }
    cyclic.Plot.self = cyclic
    local hostile = {
        nil, 42, "a string", true, {}, { 1, 2, 3 }, cyclic,
        { SchemaVersion = "one", Plot = "not a table" },
        { Plot = { Essence = 0 / 0, Stage = math.huge, Droppers = 5, Upgrades = true, Sections = "x" } },
        { Plot = { Essence = -1e30, Stage = -7, LifetimeEssence = 0 / 0 } },
        { Prestige = { Rebirths = 1e300, Multiplier = 0 / 0, Badges = "none" } },
        { Settings = { Music = "yes", Sfx = 1 } },
        { Stats = { TotalEssenceEarned = math.huge, Playtime = -5, JoinCount = "many" } },
    }
    for index = 1, 13 do
        local profile
        t.noThrow(function() profile = StateSchema.sanitizeProfile(hostile[index]) end,
            ("sanitizeProfile errored on hostile input %d"):format(index))
        assertLegalProfile(profile)
    end
end)

t.test("sanitizing keeps legitimate progress intact", function()
    local raw = {
        SchemaVersion = 1,
        Plot = {
            Essence = 12345.5, Stage = 4, Affinity = "tide",
            Droppers = { [firstDropper.Id] = 7, [secondDropper.Id] = 2 },
            Upgrades = { [firstUpgrade.Id] = 3 },
            Sections = { [SectionData.Base] = true, [SectionData.List[2].Id] = true },
            LifetimeEssence = 999999,
        },
        Prestige = { Rebirths = 6, Multiplier = 2.5, Badges = {}, TotalTranscended = 5e9 },
        Settings = { Music = false, Sfx = true },
        Stats = { TotalEssenceEarned = 1e10, Playtime = 3600, JoinCount = 12, FirstJoin = 1, LastSave = 2 },
    }
    local clean = StateSchema.sanitizeProfile(raw)
    assertLegalProfile(clean)
    t.eq(clean.Plot.Essence, 12345.5)
    t.eq(clean.Plot.Stage, 4)
    t.eq(clean.Plot.Affinity, "tide")
    t.eq(clean.Plot.Droppers[firstDropper.Id], 7)
    t.eq(clean.Plot.Upgrades[firstUpgrade.Id], 3)
    t.truthy(clean.Plot.Sections[SectionData.List[2].Id])
    t.eq(clean.Prestige.Rebirths, 6)
    t.eq(clean.Settings.Music, false, "an explicitly disabled setting is not reset to the default")
    t.eq(clean.Stats.JoinCount, 12)
end)

t.test("a hand-edited save cannot smuggle in progress it did not earn", function()
    local cheated = StateSchema.sanitizeProfile({
        Plot = {
            Essence = 1e300,
            Stage = 99,
            Affinity = "plasma",
            Droppers = { god_mode = 1e300, [firstDropper.Id] = 1e300 },
            Upgrades = { [firstUpgrade.Id] = 1e300, fake_upgrade = 50 },
            Sections = { every_wing = true, [SectionData.List[3].Id] = true },
        },
        Prestige = { Rebirths = 1e9, Multiplier = 1e30 },
    })
    assertLegalProfile(cheated)
    t.eq(cheated.Plot.Stage, EvolutionData.MaxStage, "stage clamps to the top of the ladder")
    t.eq(cheated.Plot.Affinity, nil, "an unknown affinity is dropped, not kept")
    t.eq(cheated.Plot.Droppers.god_mode, nil)
    t.eq(cheated.Plot.Droppers[firstDropper.Id], firstDropper.MaxOwned,
        "a dropper count clamps to that def's own ceiling")
    t.eq(cheated.Plot.Upgrades[firstUpgrade.Id], firstUpgrade.MaxLevel)
    t.eq(cheated.Plot.Upgrades.fake_upgrade, nil)
    t.eq(cheated.Plot.Sections.every_wing, nil)
    t.lt(cheated.Plot.Essence, math.huge)
    t.truthy(cheated.Prestige.Rebirths <= RebirthData.MaxTrackedRebirths,
        "rebirths clamp so the multiplier cannot run away")

    -- The clamped values must still be legal inputs to the live economy.
    t.noThrow(function() return Economy.estimateIncomePerSecond(cheated.Plot,
        Economy.getMultipliers(cheated.Plot, { cheated.Prestige.Rebirths })) end)
end)

t.test("badges are rebuilt from the rebirth count", function()
    local profile = StateSchema.sanitizeProfile({ Prestige = { Rebirths = 10, Badges = { made_up = true } } })
    t.eq(profile.Prestige.Badges.made_up, nil, "an unknown badge id is dropped")
    local expected = RebirthData.badgesFor(10)
    for id in pairs(expected) do
        t.truthy(profile.Prestige.Badges[id], ("badge %s should be rebuilt from the count"):format(id))
    end
end)

t.test("migrate stamps the current version and repairs on the way through", function()
    local migrated = StateSchema.migrate({ SchemaVersion = 0, Plot = { Essence = 500 } })
    t.eq(migrated.SchemaVersion, StateSchema.VERSION)
    t.eq(migrated.Plot.Essence, 500, "a version bump must not discard real progress")
    assertLegalProfile(migrated)

    -- A save from a FUTURE build (a rolled-back server) must not crash the load.
    local fromFuture = StateSchema.migrate({ SchemaVersion = 999, Plot = { Essence = 700 } })
    assertLegalProfile(fromFuture)
    t.noThrow(function() return StateSchema.migrate(nil) end)
    t.noThrow(function() return StateSchema.migrate("garbage") end)
end)

-------------------------------------------------------------------------------
-- Max-merge (the link rule)
-------------------------------------------------------------------------------
t.test("mergePlotStates takes the maximum of every field", function()
    local a = StateSchema.newPlotState()
    a.Essence, a.Stage, a.LifetimeEssence = 500, 3, 9000
    a.Droppers = { [firstDropper.Id] = 5, [secondDropper.Id] = 1 }
    a.Upgrades = { [firstUpgrade.Id] = 2 }
    a.Sections = { [SectionData.Base] = true, [SectionData.List[2].Id] = true }
    a.Affinity = "ember"

    local b = StateSchema.newPlotState()
    b.Essence, b.Stage, b.LifetimeEssence = 200, 4, 12000
    b.Droppers = { [firstDropper.Id] = 2, [DropperData.List[3].Id] = 4 }
    b.Upgrades = { [firstUpgrade.Id] = 6 }
    b.Sections = { [SectionData.Base] = true, [SectionData.List[3].Id] = true }

    local merged = StateSchema.mergePlotStates(a, b)
    t.eq(merged.Essence, 500, "the larger wallet wins")
    t.eq(merged.Stage, 4, "the further stage wins")
    t.eq(merged.LifetimeEssence, 12000)
    t.eq(merged.Droppers[firstDropper.Id], 5, "per-id maximum")
    t.eq(merged.Droppers[secondDropper.Id], 1, "an id only one side owns is kept")
    t.eq(merged.Droppers[DropperData.List[3].Id], 4)
    t.eq(merged.Upgrades[firstUpgrade.Id], 6)
    t.truthy(merged.Sections[SectionData.List[2].Id], "sections union")
    t.truthy(merged.Sections[SectionData.List[3].Id])
end)

t.test("merging is commutative and never loses anything either side owned", function()
    local a = StateSchema.newPlotState()
    a.Essence, a.Stage = 900, 2
    a.Droppers = { [firstDropper.Id] = 9 }
    local b = StateSchema.newPlotState()
    b.Essence, b.Stage = 100, 5
    b.Droppers = { [secondDropper.Id] = 3 }

    local ab, ba = StateSchema.mergePlotStates(a, b), StateSchema.mergePlotStates(b, a)
    t.deepEq(ab, ba, "link order must not change the outcome")
    for _, merged in ipairs({ ab, ba }) do
        t.truthy(merged.Essence >= a.Essence and merged.Essence >= b.Essence)
        t.truthy(merged.Stage >= a.Stage and merged.Stage >= b.Stage)
        t.eq(merged.Droppers[firstDropper.Id], 9)
        t.eq(merged.Droppers[secondDropper.Id], 3)
    end
end)

t.test("merging is idempotent and total", function()
    local a = StateSchema.newPlotState()
    a.Essence = 4242
    a.Droppers = { [firstDropper.Id] = 2 }
    t.deepEq(StateSchema.mergePlotStates(a, a), StateSchema.clonePlotState(a),
        "merging a state with itself changes nothing")

    for _, junk in ipairs({ 5, "text", true, { Essence = 0 / 0, Droppers = 7 } }) do
        t.noThrow(function() return StateSchema.mergePlotStates(a, junk) end)
        t.noThrow(function() return StateSchema.mergePlotStates(junk, a) end)
    end
    local fromNil = StateSchema.mergePlotStates(nil, nil)
    t.eq(fromNil.Essence, 0)
    t.eq(fromNil.Stage, 1)
end)

t.test("merging does not mutate either input", function()
    local a, b = StateSchema.newPlotState(), StateSchema.newPlotState()
    a.Essence, b.Essence = 10, 20
    a.Droppers[firstDropper.Id] = 1
    StateSchema.mergePlotStates(a, b)
    t.eq(a.Essence, 10)
    t.eq(b.Essence, 20)
    t.eq(b.Droppers[firstDropper.Id], nil, "the merge must not leak a's droppers into b")
end)

-------------------------------------------------------------------------------
-- Snapshot
-------------------------------------------------------------------------------
local function sanctum(overrides)
    local state = StateSchema.newPlotState()
    state.Essence, state.Stage = 5000, 3
    state.Droppers[firstDropper.Id] = 4
    local base = {
        Id = 2,
        State = state,
        Occupants = {
            [11] = { UserId = 11, Slot = 1, Contribution = 3000, Name = "Ash" },
            [22] = { UserId = 22, Slot = 2, Contribution = 2000, Name = "Bree" },
        },
    }
    for key, value in pairs(overrides or {}) do base[key] = value end
    return base
end

local function profilesFor()
    local ash = StateSchema.newProfile()
    ash.Prestige.Rebirths, ash.Prestige.Multiplier = 4, Economy.getPrestigeMultiplier(4)
    ash.Settings.Music = false
    ash.Stats.TotalEssenceEarned = 5e8
    local bree = StateSchema.newProfile()
    bree.Prestige.Rebirths, bree.Prestige.Multiplier = 1, Economy.getPrestigeMultiplier(1)
    return { [11] = ash, [22] = bree }
end

t.test("a full snapshot carries everything the HUD needs", function()
    local payload = Snapshot.forClient(sanctum(), { UserId = 11 },
        { Full = true, Tick = 7, MoteCount = 12, Profiles = profilesFor() })

    t.eq(payload.Full, true)
    t.eq(payload.Tick, 7)
    t.eq(payload.Essence, 5000)
    t.eq(payload.Plot.Id, 2)
    t.eq(payload.Plot.Stage, 3)
    t.eq(payload.Plot.MoteCount, 12)
    t.gt(payload.Plot.MoteCapacity, 0)
    t.gt(payload.Plot.IncomePerSecond, 0)
    t.gt(payload.Plot.Multiplier, 1, "two veterans lift the shared multiplier above 1")

    t.eq(#payload.Occupants, 2)
    t.eq(payload.Occupants[1].Slot, 1, "occupants are ordered by slot, so the panel cannot flicker")
    t.eq(payload.Occupants[1].Name, "Ash")
    t.truthy(payload.Occupants[1].IsYou)
    t.falsy(payload.Occupants[2].IsYou)
    t.eq(payload.Occupants[2].Contribution, 2000)
    t.eq(payload.Occupants[1].Rebirths, 4)

    t.eq(payload.You.Rebirths, 4)
    t.eq(payload.You.Slot, 1)
    t.eq(payload.You.Settings.Music, false, "your own settings ride the snapshot")
    t.eq(payload.You.TotalEssenceEarned, 5e8)

    t.truthy(type(payload.Gates.Attune.Ok) == "boolean")
    t.eq(payload.Gates.Attune.NextStage, 4)
    t.eq(payload.Gates.Attune.Cost, EvolutionData.Stages[4].RequiredEssence)
    t.truthy(payload.Gates.Affinity.Available, "affinity unlocks at stage 3")
    t.eq(payload.Gates.Affinity.Chosen, nil)
end)

t.test("a fast tick carries essence only", function()
    local payload = Snapshot.forClient(sanctum(), { UserId = 11 }, { Full = false, Tick = 9 })
    t.eq(payload.Full, false)
    t.eq(payload.Essence, 5000)
    t.eq(payload.Tick, 9)
    t.eq(payload.Plot, nil, "the expensive half is omitted from the twice-a-second tick")
    t.eq(payload.Occupants, nil)
    t.eq(payload.Gates, nil)
end)

t.test("the snapshot is a detached copy the server cannot mutate later", function()
    local live = sanctum()
    local payload = Snapshot.forClient(live, { UserId = 11 }, { Full = true, Profiles = profilesFor() })
    live.State.Droppers[firstDropper.Id] = 99
    t.eq(payload.Plot.Droppers[firstDropper.Id], 4,
        "a queued payload must not change under the client between tick and send")
end)

t.test("snapshotting never throws, whatever the sanctum looks like", function()
    for _, junk in ipairs({ 5, "text", true, {}, { State = "corrupt" },
        { State = { Essence = 0 / 0 }, Occupants = "none" },
        { Occupants = { { UserId = "not a number" } } } }) do
        local payload
        t.noThrow(function() payload = Snapshot.forClient(junk, nil, { Full = true }) end)
        t.truthy(type(payload) == "table")
    end
    t.noThrow(function() return Snapshot.forClient(nil, nil, nil) end)
end)

t.test("an occupant with no profile still renders", function()
    -- A partner whose profile is mid-load must not blank the whole partner panel.
    local payload = Snapshot.forClient(sanctum(), { UserId = 11 }, { Full = true, Profiles = { [11] = StateSchema.newProfile() } })
    t.eq(#payload.Occupants, 2)
    t.eq(payload.Occupants[2].Rebirths, 0, "a missing profile reads as zero prestige, not nil")
    t.eq(payload.Occupants[2].Multiplier, 1)
end)
