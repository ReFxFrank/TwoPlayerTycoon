--[[
    clientstore.spec
    Every HUD element observes a path on this store, so a missed or spurious notification is either
    a stale number on screen or a per-frame UI rebuild. Both are worth a test.
]]

local ClientStore = loadModule("ReplicatedStorage/Modules/ClientStore")

t.test("a fresh store returns a usable default snapshot, never nil", function()
    local store = ClientStore.new()
    local snapshot = store:Get()
    t.truthy(type(snapshot) == "table", "Get() is total")
    t.eq(snapshot.Essence, 0)
    t.eq(snapshot.Full, false)
    t.eq(snapshot.Plot.Stage, 1, "the default has the right SHAPE so no controller needs a nil check")
    t.deepEq(snapshot.Plot.Sections, {}, "but claims nothing is unlocked yet")
    t.eq(store:GetPath("Nothing.Here.At.All"), nil, "unknown paths are nil, not an error")
end)

t.test("Set replaces the snapshot and fires Changed with old and new", function()
    local store = ClientStore.new()
    local seen = {}
    store.Changed:Connect(function(new, old)
        table.insert(seen, { New = new.Essence, Old = old and old.Essence })
    end)
    store:Set({ Full = true, Essence = 100, Plot = { Stage = 2 } })
    store:Set({ Full = true, Essence = 250, Plot = { Stage = 2 } })
    Mock.advance(0)

    t.eq(#seen, 2)
    t.eq(seen[2].New, 250)
    t.eq(seen[2].Old, 100, "the previous snapshot is passed through for diffing")
    t.eq(store:Get().Essence, 250)
end)

t.test("GetPath walks dotted paths and stops safely at a missing segment", function()
    local store = ClientStore.new()
    store:Set({ Essence = 5, Plot = { Stage = 3, Droppers = { ember_vent = 2 } } })
    t.eq(store:GetPath("Essence"), 5)
    t.eq(store:GetPath("Plot.Stage"), 3)
    t.eq(store:GetPath("Plot.Droppers.ember_vent"), 2)
    t.eq(store:GetPath("Plot.Missing.Deep"), nil)
    t.eq(store:GetPath("Essence.Nope"), nil, "indexing through a scalar is nil, not an error")
    t.noThrow(function() return store:GetPath("") end)
    t.noThrow(function() return store:GetPath(nil) end)
end)

t.test("Observe fires immediately with the current value", function()
    local store = ClientStore.new()
    store:Set({ Essence = 42 })
    local seen = {}
    store:Observe("Essence", function(value) table.insert(seen, value) end)
    Mock.advance(0)
    t.deepEq(seen, { 42 }, "an observer sees the current value without waiting for a change")
end)

t.test("Observe only re-fires when the observed value actually changes", function()
    local store = ClientStore.new()
    store:Set({ Essence = 1, Plot = { Stage = 1 } })
    local stageUpdates = {}
    store:Observe("Plot.Stage", function(value) table.insert(stageUpdates, value) end)
    Mock.advance(0)

    -- Essence ticks every replication frame; a stage observer must ignore all of it.
    for essence = 2, 20 do
        store:Set({ Essence = essence, Plot = { Stage = 1 } })
    end
    Mock.advance(0)
    t.deepEq(stageUpdates, { 1 }, "19 essence updates produced no stage rebuilds")

    store:Set({ Essence = 21, Plot = { Stage = 2 } })
    Mock.advance(0)
    t.deepEq(stageUpdates, { 1, 2 })
end)

t.test("Observe compares tables by value, not by identity", function()
    local store = ClientStore.new()
    store:Set({ Plot = { Droppers = { ember_vent = 1 } } })
    local updates = 0
    store:Observe("Plot.Droppers", function() updates += 1 end)
    Mock.advance(0)
    t.eq(updates, 1)

    -- A fresh table with identical contents arrives every snapshot; that is not a change.
    store:Set({ Plot = { Droppers = { ember_vent = 1 } } })
    Mock.advance(0)
    t.eq(updates, 1, "an equal-but-distinct table must not retrigger the observer")

    store:Set({ Plot = { Droppers = { ember_vent = 2 } } })
    Mock.advance(0)
    t.eq(updates, 2)
end)

t.test("Observe returns a connection that stops delivery", function()
    local store = ClientStore.new()
    store:Set({ Essence = 1 })
    local updates = 0
    local connection = store:Observe("Essence", function() updates += 1 end)
    Mock.advance(0)
    connection:Disconnect()
    store:Set({ Essence = 2 })
    Mock.advance(0)
    t.eq(updates, 1)
end)

t.test("a partial (essence-only) snapshot does not erase the last full one", function()
    -- StateReplicator sends Full=false ticks between full snapshots. If those wiped Plot, the HUD
    -- would flicker back to defaults twice a second.
    local store = ClientStore.new()
    store:Set({ Full = true, Essence = 100, Plot = { Stage = 4 }, Occupants = { { Name = "Ash" } } })
    store:Set({ Full = false, Essence = 140 })
    Mock.advance(0)
    t.eq(store:GetPath("Essence"), 140, "the fast field updates")
    t.eq(store:GetPath("Plot.Stage"), 4, "the last full payload survives a partial tick")
    t.eq(store:GetPath("Occupants.1.Name"), "Ash")
end)

t.test("a malformed snapshot cannot break the store", function()
    local store = ClientStore.new()
    for _, junk in ipairs({ 5, "text", true }) do
        t.noThrow(function() store:Set(junk) end)
        t.truthy(type(store:Get()) == "table", "Get() stays total after junk input")
    end
    t.noThrow(function() store:Set(nil) end)
    t.truthy(type(store:Get()) == "table")
end)
