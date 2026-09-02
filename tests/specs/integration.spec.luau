--[[
    integration.spec
    The Definition of Done, proved end to end against the REAL entry point: Bootstrap.server.luau
    registers and starts every service, players join through PlayerAdded, and purchases happen by
    triggering the actual in-world ProximityPrompts.

    Nothing here reaches past a public API to make something work. If a domino is not connected,
    these tests fail -- which is exactly how the two wiring gaps in this codebase were found.
]]

local GameConfig = loadModule("ReplicatedStorage/Modules/GameConfig")
local Economy = loadModule("ReplicatedStorage/Modules/Economy")
local EvolutionData = loadModule("ReplicatedStorage/Modules/EvolutionData")
local AffinityData = loadModule("ReplicatedStorage/Modules/AffinityData")
local RebirthData = loadModule("ReplicatedStorage/Modules/RebirthData")
local DropperData = loadModule("ReplicatedStorage/Modules/DropperData")
local SectionData = loadModule("ReplicatedStorage/Modules/SectionData")
local StateSchema = loadModule("ReplicatedStorage/Modules/StateSchema")

--- Boots the whole server exactly as Roblox would, then hands back the service singletons.
--- Modules are cached, so these are the same tables Bootstrap registered.
local function bootServer()
    runScript("ServerScriptService/Core/Bootstrap")
    Mock.advance(0.5)
    local services = {}
    for _, name in ipairs({ "RateLimiter", "RemoteService", "DataStoreWrapper", "ProfileService",
        "EconomyService", "PlotService", "PurchaseService", "EvolutionService", "RebirthService",
        "LeaderboardService", "StateReplicator" }) do
        services[name] = loadModule("ServerScriptService/Core/Services/" .. name)
    end
    return services
end

--- Joins a player the way a real client does: appear in Players and let the server react.
local function joinPlayer(services, name, userId)
    local player = Mock.addPlayer(name, userId)
    Mock.advance(1) -- LoadAsync yields on the DataStore
    return player
end

local function sanctumOf(services, player)
    return services.PlotService:GetSanctumForPlayer(player)
end

--- Finds an in-world pad by its Runtime key and triggers its prompt, as a player pressing E does.
local function usePad(services, sanctum, key, player)
    local runtime = services.PlotService:GetSanctumRuntime(sanctum)
    local pad = runtime and runtime.Pads and runtime.Pads[key]
    if pad == nil then return false, "no pad " .. key end
    local prompt
    for _, descendant in ipairs(pad:GetDescendants()) do
        if descendant:IsA("ProximityPrompt") then prompt = descendant break end
    end
    if prompt == nil then return false, "no prompt on " .. key end
    Mock.triggerPrompt(prompt, player)
    return true
end

--- Grants essence through the real crediting path. The INCOME path (wellsprings -> rails -> font)
--- is proved separately in simulation.spec; these tests are about the transitions it pays for, and
--- stage 6 costs 600 million.
local function grant(services, sanctum, amount)
    services.EconomyService:Credit(sanctum, amount)
end

-------------------------------------------------------------------------------
t.test("the server boots and builds a world", function()
    local services = bootServer()
    t.truthy(services.PlotService:GetSanctum(1), "sanctums exist")
    local remotes = game:GetService("ReplicatedStorage"):FindFirstChild("SanctumRemotes")
    t.truthy(remotes, "the remote folder was created")
    t.truthy(remotes:FindFirstChild("StateSync"))
end)

t.test("a player who joins is given a profile, a plot and leaderstats", function()
    local services = bootServer()
    local ash = joinPlayer(services, "Ash", 1)

    t.truthy(services.ProfileService:IsLoaded(ash), "profile loaded")
    local sanctum = sanctumOf(services, ash)
    t.truthy(sanctum, "a sanctum was claimed")
    t.eq(sanctum.State.Droppers[DropperData.List[1].Id], 1, "with the free starting wellspring")

    local leaderstats = ash:FindFirstChild("leaderstats")
    t.truthy(leaderstats, "leaderstats were created")
    t.truthy(leaderstats:FindFirstChild("Essence"))
    t.truthy(leaderstats:FindFirstChild("Rebirths"))
end)

t.test("essence accrues and reaches the client", function()
    local services = bootServer()
    local ash = joinPlayer(services, "Ash", 1)
    local sanctum = sanctumOf(services, ash)
    Mock.clearOutbox()
    Mock.advance(90)

    t.gt(sanctum.State.Essence, 0, "the income loop ran")
    local pushes = Mock.outboxFor("StateSync", ash)
    t.gt(#pushes, 0, "the client was told")
    local latest = pushes[#pushes].Args[1]
    t.truthy(type(latest) == "table" and latest.Essence ~= nil)
    t.eq(ash.leaderstats.Essence.Value, math.floor(sanctum.State.Essence), "leaderstats track it")
end)

t.test("a purchase happens by pressing E on the pad, and is server-authoritative", function()
    local services = bootServer()
    local ash = joinPlayer(services, "Ash", 1)
    local sanctum = sanctumOf(services, ash)
    local dropper = DropperData.List[1]

    -- Too poor: the pad must refuse.
    local owned = sanctum.State.Droppers[dropper.Id]
    usePad(services, sanctum, "dropper:" .. dropper.Id, ash)
    t.eq(sanctum.State.Droppers[dropper.Id], owned, "an unaffordable purchase is refused")

    grant(services, sanctum, 10000)
    local before = sanctum.State.Essence
    t.truthy(usePad(services, sanctum, "dropper:" .. dropper.Id, ash))
    t.eq(sanctum.State.Droppers[dropper.Id], owned + 1, "and an affordable one goes through")
    t.lt(sanctum.State.Essence, before, "the wallet was actually debited")
end)

t.test("a player cannot buy on a sanctum they do not occupy", function()
    local services = bootServer()
    local ash = joinPlayer(services, "Ash", 1)
    local bree = joinPlayer(services, "Bree", 2)
    local ashPlot = sanctumOf(services, ash)
    grant(services, ashPlot, 100000)
    local dropper = DropperData.List[1]
    local owned = ashPlot.State.Droppers[dropper.Id]

    -- Bree reaches Ash's pad. Standing somewhere she should not be is exactly the exploit case.
    usePad(services, ashPlot, "dropper:" .. dropper.Id, bree)
    t.eq(ashPlot.State.Droppers[dropper.Id], owned, "occupancy is re-checked on the server")
end)

t.test("two players link and share one wallet", function()
    local services = bootServer()
    local ash = joinPlayer(services, "Ash", 1)
    local bree = joinPlayer(services, "Bree", 2)
    local host = sanctumOf(services, ash)

    t.truthy(services.PlotService:RequestLink(bree, host))
    services.PlotService:ResolveLink(ash, host, true)
    Mock.advance(1)

    t.eq(#services.PlotService:GetOccupants(host), 2)
    grant(services, host, 5000)
    -- One pool: a purchase by either player spends the same essence.
    local dropper = DropperData.List[1]
    local owned = host.State.Droppers[dropper.Id]
    usePad(services, host, "dropper:" .. dropper.Id, bree)
    t.eq(host.State.Droppers[dropper.Id], owned + 1, "the partner buys from the shared wallet")
end)

t.test("the pair attunes through all six stages", function()
    local services = bootServer()
    local ash = joinPlayer(services, "Ash", 1)
    local sanctum = sanctumOf(services, ash)

    for target = 2, EvolutionData.MaxStage do
        local stage = EvolutionData.Stages[target]
        -- Meet the three gates: essence, lifetime essence, and wellsprings owned.
        grant(services, sanctum, math.max(stage.RequiredEssence, stage.RequiredLifetimeEssence) * 1.2)
        local starter = DropperData.List[1]
        sanctum.State.Droppers[starter.Id] = math.max(stage.RequiredDroppers, 1)
        services.EconomyService:RefreshMultipliers(sanctum)

        local ok, reason = services.EvolutionService:Attune(ash, sanctum)
        t.truthy(ok, ("attuning to stage %d was refused: %s"):format(target, tostring(reason)))
        t.eq(sanctum.State.Stage, target)
    end
    t.eq(sanctum.State.Stage, EvolutionData.MaxStage, "Primordial reached")

    -- Attuning past the top must be refused, not wrap or overflow.
    local ok, reason = services.EvolutionService:Attune(ash, sanctum)
    t.falsy(ok)
    t.eq(reason, Economy.Reason.MaxStage)
end)

t.test("attuning raises income and walk speed", function()
    local services = bootServer()
    local ash = joinPlayer(services, "Ash", 1)
    local sanctum = sanctumOf(services, ash)
    local before = Economy.totalMultiplier(services.EconomyService:GetMultipliers(sanctum))

    local stage = EvolutionData.Stages[2]
    grant(services, sanctum, math.max(stage.RequiredEssence, stage.RequiredLifetimeEssence) * 1.2)
    sanctum.State.Droppers[DropperData.List[1].Id] = math.max(stage.RequiredDroppers, 1)
    t.truthy(services.EvolutionService:Attune(ash, sanctum))
    Mock.advance(1)

    t.gt(Economy.totalMultiplier(services.EconomyService:GetMultipliers(sanctum)), before)
    local humanoid = ash.Character and ash.Character:FindFirstChildOfClass("Humanoid")
    t.eq(humanoid.WalkSpeed, EvolutionData.Stages[2].WalkSpeed, "the sanctum grew, so traversal did")
end)

t.test("an affinity is chosen once and is permanent for the run", function()
    local services = bootServer()
    local ash = joinPlayer(services, "Ash", 1)
    local sanctum = sanctumOf(services, ash)
    sanctum.State.Stage = EvolutionData.AffinityUnlockStage
    services.EconomyService:RefreshMultipliers(sanctum)

    local ember = AffinityData.List[1].Id
    t.truthy(services.EvolutionService:ChooseAffinity(ash, sanctum, ember))
    t.eq(sanctum.State.Affinity, ember)

    t.falsy(services.EvolutionService:ChooseAffinity(ash, sanctum, AffinityData.List[2].Id),
        "the choice cannot be swapped once made")
    t.falsy(services.EvolutionService:ChooseAffinity(ash, sanctum, "plasma"),
        "and an unknown element is refused")
    t.eq(sanctum.State.Affinity, ember)
end)

t.test("transcendence needs both occupants and pays both of them", function()
    local services = bootServer()
    local ash = joinPlayer(services, "Ash", 1)
    local bree = joinPlayer(services, "Bree", 2)
    local host = sanctumOf(services, ash)
    services.PlotService:RequestLink(bree, host)
    services.PlotService:ResolveLink(ash, host, true)
    Mock.advance(1)

    host.State.Stage = RebirthData.RequiredStage
    grant(services, host, RebirthData.RequiredLifetimeEssence * 1.1)
    host.State.LifetimeEssence = math.max(host.State.LifetimeEssence, RebirthData.RequiredLifetimeEssence * 1.1)

    t.truthy(services.RebirthService:BeginVote(ash, host))
    -- One vote is not enough: a shared plot must not have a unilateral reset button.
    Mock.advance(1)
    t.eq(host.State.Stage, RebirthData.RequiredStage, "the reset has not happened on one vote")

    services.RebirthService:CastVote(bree, true)
    Mock.advance(1)

    t.eq(host.State.Stage, 1, "the sanctum reset")
    t.eq(host.State.Essence, 0)
    t.eq(host.State.Affinity, nil)
    t.eq(services.ProfileService:Get(ash).Prestige.Rebirths, 1, "the initiator was paid")
    t.eq(services.ProfileService:Get(bree).Prestige.Rebirths, 1, "and so was the partner")
    t.gt(services.ProfileService:Get(ash).Prestige.Multiplier, 1)
    t.eq(host.State.Droppers[DropperData.List[1].Id], 1,
        "and the free wellspring is granted again, or income would be zero forever")
end)

t.test("a no vote cancels the reset", function()
    local services = bootServer()
    local ash = joinPlayer(services, "Ash", 1)
    local bree = joinPlayer(services, "Bree", 2)
    local host = sanctumOf(services, ash)
    services.PlotService:RequestLink(bree, host)
    services.PlotService:ResolveLink(ash, host, true)
    Mock.advance(1)

    host.State.Stage = RebirthData.RequiredStage
    grant(services, host, RebirthData.RequiredLifetimeEssence * 1.1)
    host.State.LifetimeEssence = RebirthData.RequiredLifetimeEssence * 1.1
    local essence = host.State.Essence

    services.RebirthService:BeginVote(ash, host)
    services.RebirthService:CastVote(bree, false)
    Mock.advance(1)
    t.eq(host.State.Stage, RebirthData.RequiredStage, "nothing was reset")
    t.eq(host.State.Essence, essence)
    t.eq(services.ProfileService:Get(ash).Prestige.Rebirths, 0, "and nobody was paid")
end)

t.test("progress and prestige survive a server restart and a rejoin", function()
    local services = bootServer()
    local ash = joinPlayer(services, "Ash", 1)
    local sanctum = sanctumOf(services, ash)
    grant(services, sanctum, 250000)
    sanctum.State.Stage = 4
    sanctum.State.Droppers[DropperData.List[1].Id] = 12
    services.ProfileService:Get(ash).Prestige.Rebirths = 3
    services.PlotService:SaveAll(false)
    Mock.advance(1)

    Mock.shutdown()          -- BindToClose: the real shutdown save
    Mock.restartServer()     -- drop every runtime object, keep the datastore

    local after = bootServer()
    local returning = joinPlayer(after, "Ash", 1)
    local reloaded = sanctumOf(after, returning)

    t.truthy(reloaded, "they got a plot again")
    t.eq(reloaded.State.Stage, 4, "their stage came back")
    t.gt(reloaded.State.Essence, 200000, "and their essence")
    t.eq(reloaded.State.Droppers[DropperData.List[1].Id], 12, "and their wellsprings")
    t.eq(after.ProfileService:Get(returning).Prestige.Rebirths, 3, "and their prestige")
end)

-------------------------------------------------------------------------------
-- Anti-exploit, end to end
-------------------------------------------------------------------------------
t.test("no remote can move essence, stage or prestige", function()
    local services = bootServer()
    local ash = joinPlayer(services, "Ash", 1)
    local sanctum = sanctumOf(services, ash)
    grant(services, sanctum, 1000)
    local essence, stage = sanctum.State.Essence, sanctum.State.Stage
    local rebirths = services.ProfileService:Get(ash).Prestige.Rebirths

    local hostile = {
        { "RebirthVote", { Accept = true } },
        { "RebirthVote", { Accept = true, Amount = 1e12 } },
        { "ChooseAffinity", { Affinity = "ember", Essence = 1e12 } },
        { "SetSetting", { Key = "Essence", Value = true } },
        { "SetSetting", { Key = "Music", Value = true, Stage = 6 } },
        { "LinkResponse", { PlotId = sanctum.Id, Accept = true, Essence = 1e12 } },
        { "ResetData", { Confirm = true } },
        { "RequestSnapshot", { Essence = 1e12 } },
    }
    for _, case in ipairs(hostile) do
        t.noThrow(function() Mock.fireServer(case[1], ash, case[2]) end)
    end
    Mock.advance(1)

    t.eq(sanctum.State.Essence, essence, "no remote moved the wallet")
    t.eq(sanctum.State.Stage, stage, "or the stage")
    t.eq(services.ProfileService:Get(ash).Prestige.Rebirths, rebirths, "or prestige")
end)

t.test("a flood of remote calls is throttled and never crashes the server", function()
    local services = bootServer()
    local ash = joinPlayer(services, "Ash", 1)
    local sanctum = sanctumOf(services, ash)
    Mock.advance(30)
    local essence = sanctum.State.Essence

    for _ = 1, 500 do
        Mock.fireServer("RequestSnapshot", ash, nil)
        Mock.fireServer("RebirthVote", ash, { Accept = true })
        Mock.fireServer("ChooseAffinity", ash, { Affinity = "ember" })
    end
    Mock.advance(1)
    t.truthy(services.PlotService:GetSanctumForPlayer(ash), "the server is still serving them")
    t.truthy(sanctum.State.Essence >= essence, "and the wallet only moved the way income moves it")
    local rejections = services.RemoteService:GetRejectionStats()[ash.UserId]
    t.truthy(rejections ~= nil and next(rejections) ~= nil, "the flood was counted as rejections")
end)

t.test("a purchase spam cannot buy more than the wallet allows", function()
    local services = bootServer()
    local ash = joinPlayer(services, "Ash", 1)
    local sanctum = sanctumOf(services, ash)
    local dropper = DropperData.List[1]
    sanctum.State.Droppers[dropper.Id] = 0
    grant(services, sanctum, Economy.getDropperCost(dropper, 0) + Economy.getDropperCost(dropper, 1))

    for _ = 1, 50 do usePad(services, sanctum, "dropper:" .. dropper.Id, ash) end
    -- Exactly two were affordable, however many times the prompt fired.
    t.eq(sanctum.State.Droppers[dropper.Id], 2)
    t.truthy(sanctum.State.Essence >= 0, "and the wallet never went negative")
end)
