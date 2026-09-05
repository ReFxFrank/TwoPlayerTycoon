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

t.test("every client-to-server remote has a server handler", function()
    -- The structural guard. SetSetting and ResetData were both declared, validated, rate-limited,
    -- wired on the client -- and had no handler at all, so every click died as a counted rejection.
    -- Nothing failed; the features were simply inert. A per-remote test would not have found it,
    -- because there was no code to test.
    local RemoteSchema = loadModule("ReplicatedStorage/Modules/RemoteSchema")
    local services = bootServer()
    local ash = joinPlayer("Ash", 1)

    local payloads = {
        RequestSnapshot = nil,
        RebirthVote = { Accept = false },
        ChooseAffinity = { Affinity = "ember" },
        SetSetting = { Key = "Music", Value = true },
        LinkResponse = { PlotId = 1, Accept = false },
        ResetData = { Confirm = true },
    }
    for _, def in ipairs(RemoteSchema.List) do
        if def.Direction == "ClientToServer" then
            services.RemoteService:ResetRejectionStats()
            Mock.fireServer(def.Name, ash, payloads[def.Name])
            Mock.advance(0.2)
            local stats = services.RemoteService:GetRejectionStats()[ash.UserId]
            local rejected = stats ~= nil and (stats[def.Name] or 0) or 0
            t.eq(rejected, 0, ("%s was rejected -- most likely it has no handler"):format(def.Name))
            Mock.advance(def.RateLimit.Interval * 2)
        end
    end
end)

t.test("the Music and Sfx toggles actually change the saved setting", function()
    local services = bootServer()
    local ash = joinPlayer("Ash", 1)
    t.truthy(services.ProfileService:Get(ash).Settings.Music, "settings default on")

    Mock.fireServer("SetSetting", ash, { Key = "Music", Value = false })
    Mock.advance(0.2)
    t.falsy(services.ProfileService:Get(ash).Settings.Music, "the click reached the profile")

    Mock.advance(2)
    -- A setting is per-PLAYER, so it never dirties a Sanctum and no periodic full push would carry
    -- it. The handler pushes explicitly, or the toggle's label would sit stale until the next
    -- income tick happened to dirty the plot. Clear FIRST so we only see that push.
    Mock.clearOutbox()
    Mock.fireServer("SetSetting", ash, { Key = "Sfx", Value = false })
    Mock.advance(0.2)
    t.falsy(services.ProfileService:Get(ash).Settings.Sfx)
    local pushes = Mock.outboxFor("StateSync", ash)
    local full
    for index = #pushes, 1, -1 do
        local payload = pushes[index].Args[1]
        if type(payload) == "table" and payload.Full then full = payload break end
    end
    t.truthy(full, "the change was pushed immediately, not left to the next dirty tick")
    t.falsy(full.You.Settings.Music, "and the payload carries the new settings")
    t.falsy(full.You.Settings.Sfx)
end)

t.test("the data reset is refused on a live server and works in Studio", function()
    local GameConfigLive = loadModule("ReplicatedStorage/Modules/GameConfig")
    t.truthy(GameConfigLive.Debug.DataResetStudioOnly, "the shipping config is Studio-only")

    local services = bootServer()
    local ash = joinPlayer("Ash", 1)
    services.EconomyService:Credit(services.PlotService:GetSanctumForPlayer(ash), 5000)
    services.PlotService:SaveAll(false)
    Mock.advance(0.5)
    t.gt(services.ProfileService:Get(ash).Plot.Essence, 0)

    -- Live server: the client hiding the button is a courtesy; THIS is the control.
    Mock.Services.context.Studio = false
    Mock.fireServer("ResetData", ash, { Confirm = true })
    Mock.advance(0.5)
    t.gt(services.ProfileService:Get(ash).Plot.Essence, 0, "an irreversible action must not be live")

    Mock.Services.context.Studio = true
    Mock.advance(GameConfigLive.Save.AutosaveSeconds)
    Mock.fireServer("ResetData", ash, { Confirm = true })
    Mock.advance(0.5)
    t.eq(services.ProfileService:Get(ash).Plot.Essence, 0, "but must still work while developing")
end)

t.test("a requested snapshot reports the partner's real prestige", function()
    -- pushFull's single argument was doing two jobs: the gather set (whose profiles fill the
    -- snapshot) and the send set. PushTo narrowed it to the requester, so a veteran partner
    -- rendered as a fresh account -- on the exact path the client uses to recover its HUD.
    local StateSchema = loadModule("ReplicatedStorage/Modules/StateSchema")
    local profile = StateSchema.newProfile()
    profile.Prestige.Rebirths = 7
    game:GetService("DataStoreService"):GetDataStore(GameConfig.Save.DataStoreName)
        :SetAsync(GameConfig.Save.KeyPrefix .. "2", { Data = profile })

    local services = bootServer()
    local ash = joinPlayer("Ash", 1)
    local bree = joinPlayer("Bree", 2)
    local host = services.PlotService:GetSanctumForPlayer(ash)
    linkUp(services, host, bree, ash)
    t.eq(services.ProfileService:Get(bree).Prestige.Rebirths, 7)

    Mock.clearOutbox()
    Mock.fireServer("RequestSnapshot", ash, nil)
    Mock.advance(0.2)
    local pushes = Mock.outboxFor("StateSync", ash)
    local payload = pushes[#pushes].Args[1]
    t.truthy(payload.Full, "RequestSnapshot returns a full snapshot")
    local partner
    for _, occupant in ipairs(payload.Occupants) do
        if occupant.UserId == bree.UserId then partner = occupant end
    end
    t.truthy(partner, "the partner is in the roster")
    t.eq(partner.Rebirths, 7, "a veteran partner must not read as a fresh account")
    t.gt(partner.Multiplier, 1)
end)

t.test("a failed boot stops taking sessions instead of running half a game", function()
    -- Bootstrap's own failure banner promises \"no profile will be written\". That was false: every
    -- service whose Start had already succeeded stayed live, so the server kept admitting players
    -- and autosaving for its whole lifetime.
    local Registry = loadModule("ServerScriptService/Core/ServiceRegistry")
    local registry = Registry.new()
    local started = { Stopped = false }
    registry:Register("Fine", {
        Name = "Fine",
        Init = function() end,
        Start = function() started.Running = true end,
        Stop = function() started.Stopped = true end,
    })
    registry:Register("Broken", {
        Name = "Broken",
        Init = function() end,
        Start = function() error("boom", 0) end,
    })
    registry:InitAll()
    t.throws(function() registry:StartAll() end, "a failed Start is fatal")
    t.truthy(started.Running, "the earlier service really did start")

    -- This is what Bootstrap now does in its failure branch.
    t.noThrow(function() registry:StopAll() end, "teardown must never mask the boot error")
    t.truthy(started.Stopped, "and it actually stopped what had started")
end)

t.test("a player who disconnects mid-load leaves no ghost holding a sanctum or the lock", function()
    --[[ The worst bug found in this project. PlayerRemoving fires while LoadAsync is parked on the
         DataStore, so Release finds no entry and bails -- and will never run again. LoadAsync then
         resumes and registers unconditionally: the departed player gets an entry, an autosave loop
         and a claimed Sanctum that nothing can ever free. Worse, every autosave re-stamps their
         session lock, so the lock never goes stale and that player is refused on EVERY other server
         with "your sanctum is still saving" for as long as this one lives. ]]
    local services = bootServer()
    Mock.DataStore.setLatency(0.2) -- a real join always yields; this makes the window deterministic

    local ghost = Mock.addPlayer("Ghost", 8001)
    Mock.removePlayer(ghost) -- leaves DURING the load
    Mock.advance(2)

    t.falsy(services.ProfileService:IsLoaded(ghost), "no profile is registered for a departed player")
    t.eq(services.PlotService:GetSanctumForPlayer(ghost), nil, "and no sanctum is held")

    local occupied = 0
    services.PlotService:ForEachSanctum(function(sanctum)
        if next(sanctum.Occupants) ~= nil then occupied += 1 end
    end)
    t.eq(occupied, 0, "every sanctum is still claimable")

    -- The lock half: it must be released, or this player cannot play anywhere else.
    local stored = game:GetService("DataStoreService")
        :GetDataStore(GameConfig.Save.DataStoreName):GetAsync(GameConfig.Save.KeyPrefix .. "8001")
    if stored ~= nil and stored.Lock ~= nil then
        t.eq(stored.Lock.JobId, nil, "a ghost must not hold the session lock")
    end

    local before = Mock.DataStore.calls()
    Mock.advance(GameConfig.Save.AutosaveSeconds * 3)
    t.eq(Mock.DataStore.calls(), before, "and must not keep autosaving forever")
end)

t.test("repeated mid-load disconnects cannot exhaust the server's sanctums", function()
    local services = bootServer()
    Mock.DataStore.setLatency(0.2)
    for index = 1, GameConfig.Plot.SanctumCount + 2 do
        local ghost = Mock.addPlayer("Ghost" .. index, 8100 + index)
        Mock.removePlayer(ghost)
        Mock.advance(1)
    end
    Mock.DataStore.setLatency(0)

    -- A real player joining afterwards must still get a plot.
    local ash = Mock.addPlayer("Ash", 1)
    Mock.advance(2)
    t.truthy(services.PlotService:GetSanctumForPlayer(ash),
        "eight ghosts must not leave a full server with nobody on it")
end)

t.test("a disconnect during a DataStore outage leaves no ghost either", function()
    -- The unsavable path registers unconditionally too. That profile never touches the lock, but it
    -- still holds a Sanctum for the life of the server.
    local services = bootServer()
    Mock.DataStore.failAlways(true)
    local ghost = Mock.addPlayer("Ghost", 8002)
    Mock.removePlayer(ghost)
    Mock.advance(3)
    Mock.DataStore.failAlways(false)

    t.falsy(services.ProfileService:IsLoaded(ghost))
    t.eq(services.PlotService:GetSanctumForPlayer(ghost), nil)
end)

t.test("a player turned away from a full server is given a plot when one frees up", function()
    -- ClaimEmpty was reached only from the one-shot ProfileLoaded handler and the boot sweep. There
    -- is no client claim remote, and an empty Sanctum cannot be linked into, so a player who joined
    -- one second too early sat in the lobby for the entire session while a plot stood free.
    local services = bootServer()
    local occupants = {}
    for index = 1, GameConfig.Plot.SanctumCount do
        occupants[index] = joinPlayer("P" .. index, 900 + index)
    end
    local late = joinPlayer("Late", 999)
    t.eq(services.PlotService:GetSanctumForPlayer(late), nil, "the server really was full")

    Mock.removePlayer(occupants[1])
    Mock.advance(GameConfig.Plot.ReleaseGraceSeconds + 5)
    t.truthy(services.PlotService:GetSanctumForPlayer(late),
        "the freed plot must reach the player who was waiting for it")
end)

t.test("the developer data reset clears the live sanctum, not just the profile", function()
    -- Re-announcing ProfileLoaded cannot blank the plot: PlotSession.claim is idempotent, so a
    -- settled player is handed their existing Sanctum back without re-adopting. The reset appeared
    -- to work and the next mirror wrote the old plot straight back over the fresh profile.
    local services = bootServer()
    local ash = joinPlayer("Ash", 1)
    local sanctum = services.PlotService:GetSanctumForPlayer(ash)
    services.EconomyService:Credit(sanctum, 250000)
    sanctum.State.Stage = 4
    services.PlotService:SaveAll(false)
    Mock.advance(1)

    Mock.Services.context.Studio = true
    Mock.fireServer("ResetData", ash, { Confirm = true })
    Mock.advance(1)

    t.eq(services.ProfileService:Get(ash).Plot.Essence, 0, "the profile was reset")
    local live = services.PlotService:GetSanctumForPlayer(ash)
    t.eq(live.State.Stage, 1, "and so was the sanctum standing in the world")
    t.lt(live.State.Essence, 250000)

    -- The real test: let the mirror run. A reset that undoes itself is worse than none.
    Mock.advance(GameConfig.Save.AutosaveSeconds + GameConfig.Save.AutosaveJitter + 5)
    t.lt(services.ProfileService:Get(ash).Plot.Essence, 250000,
        "the old plot must not be written back over the fresh profile")
    t.eq(services.ProfileService:Get(ash).Plot.Stage, 1)
end)

t.test("the attune pad is live once its gate opens, without needing a purchase to wake it", function()
    --[[ RefreshPads is reached only from a purchase, an attunement or a RebuildSanctum. Lifetime
         essence is the one gate INCOME alone opens, so holding it as a hard refusal left the prompt
         disabled -- a pair idling to the threshold, which is the entire activity of a tycoon,
         walked to a dead pad. pacing.spec never saw it because it calls Attune directly. ]]
    local services = bootServer()
    local ash = joinPlayer("Ash", 1)
    local sanctum = services.PlotService:GetSanctumForPlayer(ash)
    local pad = padOf(services, sanctum, "attune")
    local prompt = promptOn(pad)
    t.truthy(prompt, "the attune pad has a prompt")

    -- Meet the stage-2 gate by INCOME only: no purchase, so nothing republishes the pads.
    local stage = EvolutionData.Stages[2]
    services.EconomyService:Credit(sanctum,
        math.max(stage.RequiredEssence, stage.RequiredLifetimeEssence) * 1.2)
    sanctum.State.Droppers[DropperData.List[1].Id] = math.max(stage.RequiredDroppers, 1)
    Mock.advance(2)

    t.truthy(prompt.Enabled, "the prompt must be pressable once the gate is open")
    Mock.triggerPrompt(prompt, ash)
    Mock.advance(1)
    t.eq(sanctum.State.Stage, 2, "and pressing it must actually attune")
end)

t.test("a transcendence vote does not survive the sanctum being reset under it", function()
    -- ResetSanctum replaces State on the same table the ballot book is keyed by, so a vote opened
    -- beforehand outlived it -- and the second yes minted permanent Prestige on a blank Stage 1
    -- sanctum. Prestige is the one thing a player cannot re-earn.
    local services = bootServer()
    local ash = joinPlayer("Ash", 1)
    local bree = joinPlayer("Bree", 2)
    local host = services.PlotService:GetSanctumForPlayer(ash)
    linkUp(services, host, bree, ash)

    host.State.Stage = RebirthData.RequiredStage
    services.EconomyService:Credit(host, RebirthData.RequiredLifetimeEssence * 1.1)
    host.State.LifetimeEssence = RebirthData.RequiredLifetimeEssence * 1.1
    t.truthy(services.RebirthService:BeginVote(ash, host))
    Mock.advance(0.5)

    services.PlotService:ResetSanctum(host) -- the developer reset, mid-vote
    Mock.advance(0.5)
    services.RebirthService:CastVote(bree, true)
    Mock.advance(1)

    t.eq(services.ProfileService:Get(ash).Prestige.Rebirths, 0, "no rebirth was earned")
    t.eq(services.ProfileService:Get(bree).Prestige.Rebirths, 0, "for either occupant")
end)

t.test("the transcendence banner names the count from AFTER the rebirth", function()
    local services = bootServer()
    local ash = joinPlayer("Ash", 1)
    local host = services.PlotService:GetSanctumForPlayer(ash)
    host.State.Stage = RebirthData.RequiredStage
    services.EconomyService:Credit(host, RebirthData.RequiredLifetimeEssence * 1.1)
    host.State.LifetimeEssence = RebirthData.RequiredLifetimeEssence * 1.1

    Mock.clearOutbox()
    services.RebirthService:BeginVote(ash, host) -- solo: one yes is unanimous
    Mock.advance(1)

    local fx
    for _, entry in ipairs(Mock.outboxFor("Fx", ash)) do
        local payload = entry.Args[1]
        if type(payload) == "table" and payload.Kind == "transcend" then fx = payload end
    end
    t.truthy(fx, "a transcend Fx was sent")
    t.truthy(fx.Data ~= nil and fx.Data.Rebirths == 1,
        "the banner must announce the new count, not the one from before")
end)

t.test("a completed link announces itself to both players", function()
    -- EvolutionFxController has always had a "link" handler and nothing ever sent one, so the
    -- moment the whole game is built around landed in silence.
    local services = bootServer()
    local ash = joinPlayer("Ash", 1)
    local bree = joinPlayer("Bree", 2)
    local host = services.PlotService:GetSanctumForPlayer(ash)

    Mock.clearOutbox()
    linkUp(services, host, bree, ash)

    local sawLink = false
    for _, entry in ipairs(Mock.outboxFor("Fx")) do
        local payload = entry.Args[1]
        if type(payload) == "table" and payload.Kind == "link" then sawLink = true end
    end
    t.truthy(sawLink, "the link must be announced")
end)
