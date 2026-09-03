--[[
    regression.spec
    Defects found by an adversarial review pass over the subsystems that integration.spec exercises
    but does not inspect closely. Every one of these passed the full suite before it was fixed: they
    are state-that-went-stale and ordering bugs, not logic errors, which is exactly the class an
    end-to-end happy path walks straight past.
]]

local GameConfig = loadModule("ReplicatedStorage/Modules/GameConfig")
local EvolutionData = loadModule("ReplicatedStorage/Modules/EvolutionData")
local RebirthData = loadModule("ReplicatedStorage/Modules/RebirthData")
local DropperData = loadModule("ReplicatedStorage/Modules/DropperData")
local Theme = loadModule("ReplicatedStorage/Modules/Theme")

local function bootServer()
    runScript("ServerScriptService/Core/Bootstrap")
    Mock.advance(0.5)
    local services = {}
    for _, name in ipairs({ "ProfileService", "EconomyService", "PlotService", "PurchaseService",
        "EvolutionService", "RebirthService", "RemoteService" }) do
        services[name] = loadModule("ServerScriptService/Core/Services/" .. name)
    end
    return services
end

local function joinPlayer(name, userId)
    local player = Mock.addPlayer(name, userId)
    Mock.advance(1)
    return player
end

local function seedSave(userId, mutate)
    local StateSchema = loadModule("ReplicatedStorage/Modules/StateSchema")
    local profile = StateSchema.newProfile()
    mutate(profile)
    game:GetService("DataStoreService"):GetDataStore(GameConfig.Save.DataStoreName)
        :SetAsync(GameConfig.Save.KeyPrefix .. tostring(userId), { Data = profile })
end

local function padOf(services, sanctum, key)
    local runtime = services.PlotService:GetSanctumRuntime(sanctum)
    return runtime and runtime.Pads and runtime.Pads[key]
end

local function promptOn(pad)
    for _, descendant in ipairs(pad:GetDescendants()) do
        if descendant:IsA("ProximityPrompt") then return descendant end
    end
    return nil
end

local function linkUp(services, host, joiner, hostPlayer)
    services.PlotService:RequestLink(joiner, host)
    services.PlotService:ResolveLink(hostPlayer, host, true)
    Mock.advance(1)
end

-------------------------------------------------------------------------------
t.test("a successful transcendence closes the vote modal on every client", function()
    -- The terminal RebirthVoteState (ExpiresAt not in the future) is what closes the modal. Cancel
    -- sends it; Execute did not -- so on EVERY successful transcendence both players were left
    -- staring at a full-screen scrim over a Sanctum that had already been wiped.
    local services = bootServer()
    local ash = joinPlayer("Ash", 1)
    local bree = joinPlayer("Bree", 2)
    local host = services.PlotService:GetSanctumForPlayer(ash)
    linkUp(services, host, bree, ash)

    host.State.Stage = RebirthData.RequiredStage
    services.EconomyService:Credit(host, RebirthData.RequiredLifetimeEssence * 1.1)
    host.State.LifetimeEssence = RebirthData.RequiredLifetimeEssence * 1.1

    services.RebirthService:BeginVote(ash, host)
    Mock.advance(0.5)
    Mock.clearOutbox()
    services.RebirthService:CastVote(bree, true)
    Mock.advance(1)

    t.eq(host.State.Stage, 1, "the transcendence happened")
    local pushes = Mock.outboxFor("RebirthVoteState")
    t.gt(#pushes, 0, "a terminal ballot was pushed after the final yes")
    local final = pushes[#pushes].Args[1]
    t.truthy(type(final) == "table")
    t.truthy(final.ExpiresAt <= os.time(),
        "ExpiresAt must not be in the future, or the modal stays open over a wiped sanctum")
end)

t.test("a returning player's conflux and walk speed match their saved stage", function()
    -- ApplyStageVisuals/ApplyStageStats ran only on attune, affinity and rebirth -- never on the
    -- claim path. A returning Stage 4 player played the whole session under a Stage 1 conflux at
    -- Stage 1 walk speed.
    seedSave(1, function(profile)
        profile.Plot.Stage = 4
        profile.Plot.Affinity = "ember"
        profile.Plot.Essence = 50000
    end)
    local services = bootServer()
    local ash = joinPlayer("Ash", 1)
    local sanctum = services.PlotService:GetSanctumForPlayer(ash)
    Mock.advance(1)

    t.eq(sanctum.State.Stage, 4, "the save was adopted")
    local expected = Theme.getConfluxAppearance(4, "ember")
    local runtime = services.PlotService:GetSanctumRuntime(sanctum)
    t.near(runtime.Conflux.Size.X, expected.Size, 0.001,
        "the conflux is the sanctum's single biggest piece of progress feedback")
    t.eq(runtime.Conflux.Color, expected.Color)

    local humanoid = ash.Character and ash.Character:FindFirstChildOfClass("Humanoid")
    t.eq(humanoid.WalkSpeed, EvolutionData.Stages[4].WalkSpeed,
        "OccupantAdded fired before the save was adopted, so speed was read off a blank state")
end)

t.test("the link pad reopens when a partner leaves", function()
    -- RefreshPads was reached from claim, link-accept, purchase and attune -- but not from release.
    -- A partner who dropped from a full Sanctum found their friend's link pad dead until the friend
    -- happened to buy something. This is exactly the disconnect-and-rejoin case DECISIONS #6 exists
    -- to protect.
    local services = bootServer()
    local ash = joinPlayer("Ash", 1)
    local bree = joinPlayer("Bree", 2)
    local host = services.PlotService:GetSanctumForPlayer(ash)
    linkUp(services, host, bree, ash)

    local pad = padOf(services, host, "link:2") or padOf(services, host, "link:1")
    t.truthy(pad, "the sanctum has a link pad")
    t.truthy(pad:GetAttribute("PadLocked"), "full sanctum: the pad is correctly closed")

    Mock.removePlayer(bree)
    Mock.advance(2)
    t.eq(#services.PlotService:GetOccupants(host), 1, "a slot really is free again")
    t.falsy(pad:GetAttribute("PadLocked"), "so the pad must reopen without waiting for a purchase")
    local prompt = promptOn(pad)
    t.truthy(prompt and prompt.Enabled, "and its prompt must be live")
end)

t.test("a sanctum wiped by the grace timer stops advertising the old pair's progress", function()
    -- beginGrace reset the state but only marked the plot dirty; nothing republished the pads. Every
    -- price, sign and prompt kept describing a PlotState that no longer existed, on a plot standing
    -- in full view of the whole server.
    local services = bootServer()
    local ash = joinPlayer("Ash", 1)
    local sanctum = services.PlotService:GetSanctumForPlayer(ash)
    local dropper = DropperData.List[1]
    services.EconomyService:Credit(sanctum, 100000)
    services.PurchaseService:PurchaseDropper(ash, sanctum, dropper.Id)
    Mock.advance(1)

    local pad = padOf(services, sanctum, "dropper:" .. dropper.Id)
    local costWhileOwned = pad:GetAttribute("PadCost")
    t.gt(costWhileOwned, 0)

    Mock.removePlayer(ash)
    Mock.advance(GameConfig.Plot.ReleaseGraceSeconds + 5)
    t.eq(sanctum.State.Essence, 0, "the grace timer wiped the plot")

    t.neq(pad:GetAttribute("PadCost"), costWhileOwned,
        "the pad still quoted the price for a wellspring count that no longer exists")
end)
