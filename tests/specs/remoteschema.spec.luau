--[[
    remoteschema.spec
    The client->server remotes are the only bytes an exploiter can put on the wire. Their validators
    are therefore the game's outer wall, and this spec attacks them: wrong types, extra keys, missing
    keys, cyclic tables, huge strings, metatables that error on read.

    The single most important assertion in the file is the last one: no client->server payload may
    carry a quantity, price, id-to-purchase or balance. If one ever does, the design has regressed.
]]

local RemoteSchema = loadModule("ReplicatedStorage/Modules/RemoteSchema")
local AffinityData = loadModule("ReplicatedStorage/Modules/AffinityData")

local function c2s()
    local list = {}
    for _, def in ipairs(RemoteSchema.List) do
        if def.Direction == "ClientToServer" then table.insert(list, def) end
    end
    return list
end

local function accepts(def, payload)
    local ok = def.Validate(payload)
    return ok == true
end

t.test("the remote catalogue matches the protocol", function()
    t.truthy(#RemoteSchema.List > 0)
    local expected = { "StateSync", "Notify", "Fx", "LinkOffer", "RebirthVoteState",
        "RequestSnapshot", "RebirthVote", "ChooseAffinity", "SetSetting", "LinkResponse", "ResetData" }
    for _, name in ipairs(expected) do
        local def = RemoteSchema.get(name)
        t.truthy(def, ("remote %s is missing"):format(name))
        t.eq(def.Name, name, "Name matches the key it is registered under")
    end
    t.eq(RemoteSchema.get("NotARemote"), nil)
    t.eq(RemoteSchema.get(nil), nil)
    t.eq(RemoteSchema.get(42), nil)
    t.truthy(#RemoteSchema.FolderName > 0)
end)

t.test("List and Remotes agree, and List is deterministically ordered", function()
    local seen = {}
    for _, def in ipairs(RemoteSchema.List) do
        t.eq(RemoteSchema.Remotes[def.Name], def)
        t.falsy(seen[def.Name], "no duplicates in List")
        seen[def.Name] = true
    end
    for name in pairs(RemoteSchema.Remotes) do
        t.truthy(seen[name], ("%s is in Remotes but missing from List"):format(name))
    end
    -- RemoteService creates instances by walking List. `pairs` order is unspecified in Luau, so
    -- without the sort the creation order would differ between server boots. The order is
    -- deliberate: every ServerToClient remote is created first, so a client that is already
    -- listening cannot miss an early push while the inbound events are still being made.
    local seenInbound = false
    for index, def in ipairs(RemoteSchema.List) do
        if def.Direction == "ClientToServer" then
            seenInbound = true
        else
            t.falsy(seenInbound,
                ("outbound remote %s is created after an inbound one (position %d)"):format(def.Name, index))
        end
        local previous = RemoteSchema.List[index - 1]
        if previous and previous.Direction == def.Direction then
            t.truthy(previous.Name < def.Name,
                ("%s and %s are out of alphabetical order"):format(previous.Name, def.Name))
        end
    end
end)

t.test("every client->server remote is rate limited AND validated", function()
    local defs = c2s()
    t.truthy(#defs >= 6, "the protocol has at least six inbound remotes")
    for _, def in ipairs(defs) do
        t.truthy(type(def.Validate) == "function", def.Name .. " has no validator")
        t.truthy(type(def.RateLimit) == "table", def.Name .. " has no rate limit")
        t.gt(def.RateLimit.Tokens, 0, def.Name .. " token budget")
        t.gt(def.RateLimit.Interval, 0, def.Name .. " interval")
        t.lt(def.RateLimit.Tokens, 100, def.Name .. " budget is too generous to be a limit")
    end
end)

t.test("server->client remotes carry no inbound validator or limit", function()
    for _, def in ipairs(RemoteSchema.List) do
        if def.Direction == "ServerToClient" then
            t.eq(def.RateLimit, nil, def.Name .. " is outbound; a rate limit there means nothing")
            t.eq(def.Validate, nil, def.Name .. " is outbound; nothing arrives on it to validate")
        end
    end
end)

t.test("validators accept exactly the legal payloads", function()
    t.truthy(accepts(RemoteSchema.Remotes.RequestSnapshot, nil), "RequestSnapshot takes no payload")
    t.truthy(accepts(RemoteSchema.Remotes.RebirthVote, { Accept = true }))
    t.truthy(accepts(RemoteSchema.Remotes.RebirthVote, { Accept = false }))
    for _, affinity in ipairs(AffinityData.List) do
        t.truthy(accepts(RemoteSchema.Remotes.ChooseAffinity, { Affinity = affinity.Id }),
            affinity.Id .. " is a legal choice")
    end
    t.truthy(accepts(RemoteSchema.Remotes.SetSetting, { Key = "Music", Value = false }))
    t.truthy(accepts(RemoteSchema.Remotes.SetSetting, { Key = "Sfx", Value = true }))
    t.truthy(accepts(RemoteSchema.Remotes.LinkResponse, { PlotId = 3, Accept = true }))
    t.truthy(accepts(RemoteSchema.Remotes.ResetData, { Confirm = true }))
end)

t.test("validators reject wrong types", function()
    t.falsy(accepts(RemoteSchema.Remotes.RebirthVote, { Accept = "true" }))
    t.falsy(accepts(RemoteSchema.Remotes.RebirthVote, { Accept = 1 }))
    t.falsy(accepts(RemoteSchema.Remotes.RebirthVote, { Accept = nil }))
    t.falsy(accepts(RemoteSchema.Remotes.ChooseAffinity, { Affinity = 1 }))
    t.falsy(accepts(RemoteSchema.Remotes.SetSetting, { Key = "Music", Value = "off" }))
    t.falsy(accepts(RemoteSchema.Remotes.LinkResponse, { PlotId = "3", Accept = true }))
end)

t.test("validators reject values outside their closed set", function()
    t.falsy(accepts(RemoteSchema.Remotes.ChooseAffinity, { Affinity = "plasma" }),
        "an unknown affinity is refused at the wire, not deep inside EvolutionService")
    t.falsy(accepts(RemoteSchema.Remotes.ChooseAffinity, { Affinity = "" }))
    t.falsy(accepts(RemoteSchema.Remotes.SetSetting, { Key = "Invincible", Value = true }),
        "SetSetting must not become a generic profile writer")
    t.falsy(accepts(RemoteSchema.Remotes.SetSetting, { Key = "Essence", Value = true }))
    t.falsy(accepts(RemoteSchema.Remotes.ResetData, { Confirm = false }),
        "the confirm flag must be literally true")
end)

t.test("validators reject EXTRA keys -- the classic probe", function()
    t.falsy(accepts(RemoteSchema.Remotes.RebirthVote, { Accept = true, Amount = 1e9 }))
    t.falsy(accepts(RemoteSchema.Remotes.ChooseAffinity, { Affinity = "ember", Essence = 1e9 }))
    t.falsy(accepts(RemoteSchema.Remotes.SetSetting, { Key = "Music", Value = true, Stage = 6 }))
    t.falsy(accepts(RemoteSchema.Remotes.LinkResponse, { PlotId = 1, Accept = true, Force = true }))
    t.falsy(accepts(RemoteSchema.Remotes.ResetData, { Confirm = true, KeepPrestige = false }))
end)

t.test("validators reject missing keys", function()
    t.falsy(accepts(RemoteSchema.Remotes.SetSetting, { Key = "Music" }))
    t.falsy(accepts(RemoteSchema.Remotes.SetSetting, { Value = true }))
    t.falsy(accepts(RemoteSchema.Remotes.LinkResponse, { PlotId = 1 }))
    t.falsy(accepts(RemoteSchema.Remotes.LinkResponse, { Accept = true }))
    t.falsy(accepts(RemoteSchema.Remotes.ChooseAffinity, {}))
end)

t.test("a payload-taking validator rejects a bare value", function()
    for _, def in ipairs(c2s()) do
        if def.Name ~= "RequestSnapshot" then
            for _, junk in ipairs({ 5, "string", true, { 1, 2, 3 } }) do
                t.falsy(accepts(def, junk), ("%s accepted a bare %s"):format(def.Name, typeof(junk)))
            end
            t.falsy(accepts(def, nil), def.Name .. " accepted nil")
        end
    end
end)

t.test("fuzz: no validator errors, whatever arrives", function()
    local cyclic = { Accept = true }
    cyclic.self = cyclic
    local booby = setmetatable({}, { __index = function() error("gotcha") end })
    local deep = {}
    local node = deep
    for _ = 1, 200 do
        node.next = {}
        node = node.next
    end

    local payloads = {
        nil, 0, -1, 0 / 0, math.huge, "", ("x"):rep(100000), true, false,
        {}, { 1, 2, 3 }, cyclic, booby, deep, print, coroutine.create(print),
        Vector3.new(1, 2, 3), Color3.new(1, 1, 1), Enum.Material.Neon,
        { Accept = booby }, { Affinity = booby }, { Key = booby, Value = true },
        { PlotId = 0 / 0, Accept = true }, { PlotId = math.huge, Accept = true },
        { PlotId = -1, Accept = true }, { Confirm = booby },
        { [1] = "positional", Accept = true },
        { ["Accept "] = true }, { accept = true },
    }
    for _, def in ipairs(c2s()) do
        for index = 1, 29 do
            local ok, result
            t.noThrow(function() ok, result = def.Validate(payloads[index]) end,
                ("%s.Validate errored on fuzz payload %d"):format(def.Name, index))
            t.truthy(type(ok) == "boolean" or ok == nil,
                ("%s.Validate returned a non-boolean"):format(def.Name))
            if ok == false and result ~= nil then
                t.truthy(type(result) == "string", "the rejection reason is a string when present")
            end
        end
    end
end)

t.test("fuzz: a wrong-case or padded key never sneaks through", function()
    t.falsy(accepts(RemoteSchema.Remotes.SetSetting, { key = "Music", value = true }))
    t.falsy(accepts(RemoteSchema.Remotes.SetSetting, { Key = "music", Value = true }))
    t.falsy(accepts(RemoteSchema.Remotes.ChooseAffinity, { Affinity = "EMBER" }))
    t.falsy(accepts(RemoteSchema.Remotes.ChooseAffinity, { Affinity = " ember" }))
    t.falsy(accepts(RemoteSchema.Remotes.ChooseAffinity, { Affinity = "ember\0" }))
end)

t.test("NO client->server payload may carry a quantity, price, id or balance", function()
    -- This is the design invariant, not an implementation detail. Purchases go through
    -- server-listened ProximityPrompts precisely so nothing here has an amount to forge; if this
    -- test ever needs relaxing, the anti-exploit posture in the README has changed.
    local FORBIDDEN = { "Amount", "Cost", "Price", "Essence", "Currency", "Quantity", "Count",
        "Stage", "Multiplier", "Rebirths", "Balance", "DropperId", "UpgradeId", "SectionId",
        "Id", "Value" }
    local ALLOWED_VALUE_ON = { SetSetting = true } -- SetSetting.Value is a boolean toggle
    for _, def in ipairs(c2s()) do
        for _, field in ipairs(FORBIDDEN) do
            if not (field == "Value" and ALLOWED_VALUE_ON[def.Name]) then
                local payload = { [field] = 1 }
                t.falsy(accepts(def, payload),
                    ("%s accepted a payload carrying %s"):format(def.Name, field))
            end
        end
    end
    -- And positively: the only numeric field anywhere in the inbound protocol is LinkResponse.PlotId,
    -- which names a plot rather than a quantity.
    t.truthy(accepts(RemoteSchema.Remotes.LinkResponse, { PlotId = 1, Accept = false }))
end)
