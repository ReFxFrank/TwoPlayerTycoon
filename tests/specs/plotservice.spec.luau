--[[
    plotservice.spec
    PlotService owns the Sanctum lifecycle: who is in which plot, what happens when a partner links
    in or walks out, and the single Heartbeat that drives every plot's income. It is booted here
    through the REAL ServiceRegistry with the real ProfileService, EconomyService and RemoteService,
    because most of what can go wrong is an interaction between them.
]]

local GameConfig = loadModule("ReplicatedStorage/Modules/GameConfig")
local StateSchema = loadModule("ReplicatedStorage/Modules/StateSchema")
local DropperData = loadModule("ReplicatedStorage/Modules/DropperData")
local SectionData = loadModule("ReplicatedStorage/Modules/SectionData")

local firstDropper = DropperData.List[1]

local function boot()
    local Registry = loadModule("ServerScriptService/Core/ServiceRegistry")
    local registry = Registry.new()
    local services = {}
    for _, name in ipairs({ "RateLimiter", "RemoteService", "DataStoreWrapper", "ProfileService",
        "EconomyService", "PlotService" }) do
        services[name] = loadModule("ServerScriptService/Core/Services/" .. name)
        registry:Register(name, services[name])
    end
    registry:InitAll()
    registry:StartAll()
    return services, registry
end

--- Seeds a saved profile straight into the DataStore, the way a returning player's really arrives.
--- It must be written BEFORE LoadAsync, which fires ProfileLoaded itself -- and that signal is what
--- PlotService claims on, so a profile mutated afterwards would arrive too late to be adopted.
local function seedSave(userId, mutate)
    local profile = StateSchema.newProfile()
    mutate(profile)
    game:GetService("DataStoreService"):GetDataStore(GameConfig.Save.DataStoreName)
        :SetAsync(GameConfig.Save.KeyPrefix .. tostring(userId), { Data = profile })
end

--- Joins a player the way the real server does.
local function join(services, name, userId, seed)
    if seed then seedSave(userId, seed) end
    local player = Mock.addPlayer(name, userId)
    local profile = services.ProfileService:LoadAsync(player)
    Mock.advance(0)
    return player, profile
end

local function sanctumOf(services, player)
    return services.PlotService:GetSanctumForPlayer(player)
end

-------------------------------------------------------------------------------
-- Construction and claiming
-------------------------------------------------------------------------------
t.test("Init builds every sanctum the config asks for, once", function()
    boot()
    local folder
    for _, child in ipairs(workspace:GetChildren()) do
        if #child:GetChildren() >= GameConfig.Plot.SanctumCount then folder = child end
    end
    t.truthy(folder, "a folder of sanctums exists in the workspace")
    t.eq(#folder:GetChildren(), GameConfig.Plot.SanctumCount)
end)

t.test("a joining player claims a sanctum and is its anchor", function()
    local services = boot()
    local ash = join(services, "Ash", 1)
    local sanctum = sanctumOf(services, ash)
    t.truthy(sanctum, "the player was placed in a plot")
    t.eq(sanctum.AnchorUserId, ash.UserId, "the first occupant anchors the plot")
    t.eq(#services.PlotService:GetOccupants(sanctum), 1)
    t.eq(sanctum.Occupants[ash.UserId].Slot, 1)
end)

t.test("a fresh sanctum is granted the free starting wellspring", function()
    local services = boot()
    local ash = join(services, "Ash", 1)
    local sanctum = sanctumOf(services, ash)
    -- The cold-start pacing in DropperData assumes this: without it a new player has no income at
    -- all and can never afford their first purchase.
    t.eq(sanctum.State.Droppers[firstDropper.Id], 1)
end)

t.test("a returning player's saved plot is loaded, not overwritten", function()
    local services = boot()
    local ash = join(services, "Ash", 1, function(profile)
        profile.Plot.Essence = 5000
        profile.Plot.Stage = 3
        profile.Plot.Droppers[firstDropper.Id] = 7
        profile.Plot.Sections[SectionData.List[2].Id] = true
    end)
    local sanctum = sanctumOf(services, ash)
    t.eq(sanctum.State.Essence, 5000)
    t.eq(sanctum.State.Stage, 3)
    t.eq(sanctum.State.Droppers[firstDropper.Id], 7, "an existing wellspring count is not reset to 1")
    t.truthy(sanctum.State.Sections[SectionData.List[2].Id])
end)

t.test("two players get their own sanctums by default -- linking is opt-in", function()
    local services = boot()
    local ash = join(services, "Ash", 1)
    local bree = join(services, "Bree", 2)
    local a, b = sanctumOf(services, ash), sanctumOf(services, bree)
    t.truthy(a and b)
    t.neq(a.Id, b.Id, "nobody is dropped into a stranger's plot without asking")
end)

t.test("a full server turns the next joiner away rather than double-booking", function()
    local services = boot()
    for index = 1, GameConfig.Plot.SanctumCount do
        join(services, "P" .. index, 100 + index)
    end
    local late = Mock.addPlayer("Late", 999)
    local profile = services.ProfileService:LoadAsync(late)
    services.ProfileService.ProfileLoaded:Fire(late, profile)
    Mock.advance(0)
    t.eq(sanctumOf(services, late), nil)
    t.gt(#Mock.outboxFor("Notify", late), 0, "and is told why")
end)

-------------------------------------------------------------------------------
-- Income
-------------------------------------------------------------------------------
t.test("essence accrues from the single heartbeat", function()
    local services = boot()
    local ash = join(services, "Ash", 1)
    local sanctum = sanctumOf(services, ash)
    t.eq(sanctum.State.Essence, 0)
    Mock.advance(60)
    t.gt(sanctum.State.Essence, 0, "the free wellspring produced income")
    t.gt(sanctum.State.LifetimeEssence, 0)
end)

t.test("an empty sanctum earns nothing", function()
    local services = boot()
    local ash = join(services, "Ash", 1)
    local occupied = sanctumOf(services, ash)
    Mock.advance(30)
    services.PlotService:ForEachSanctum(function(sanctum)
        if sanctum.Id ~= occupied.Id then
            t.eq(sanctum.State.Essence, 0, "an unoccupied plot must not simulate")
        end
    end)
end)

t.test("one bad sanctum cannot stop the whole server's income", function()
    local services = boot()
    local ash = join(services, "Ash", 1)
    local sanctum = sanctumOf(services, ash)
    -- Corrupt a DIFFERENT plot's state, the way a bad save or a bug might.
    services.PlotService:ForEachSanctum(function(other)
        if other.Id ~= sanctum.Id then other.State = "corrupt" end
    end)
    t.noThrow(function() Mock.advance(30) end, "the shared Heartbeat must survive one bad plot")
    t.gt(sanctum.State.Essence, 0, "and the healthy plot kept earning")
end)

-------------------------------------------------------------------------------
-- Linking
-------------------------------------------------------------------------------
t.test("linking offers, then max-merges on accept", function()
    local services = boot()
    local ash = join(services, "Ash", 1, function(profile)
        profile.Plot.Essence = 900
        profile.Plot.Droppers[firstDropper.Id] = 9
        profile.Plot.Stage = 2
    end)
    local bree = join(services, "Bree", 2, function(profile)
        profile.Plot.Essence = 100
        profile.Plot.Droppers[DropperData.List[2].Id] = 4
        profile.Plot.Stage = 4
    end)
    local host = sanctumOf(services, ash)

    Mock.clearOutbox()
    local ok = services.PlotService:RequestLink(bree, host)
    t.truthy(ok, "the offer was made")
    t.gt(#Mock.outboxFor("LinkOffer"), 0, "and the occupant was asked")

    services.PlotService:ResolveLink(ash, host, true)
    Mock.advance(0)

    t.eq(#services.PlotService:GetOccupants(host), 2, "both players are in the plot")
    t.eq(sanctumOf(services, bree).Id, host.Id)
    -- Max-merge (DECISIONS #3): nobody loses anything they owned by being sociable.
    t.eq(host.State.Essence, 900, "the larger wallet survives")
    t.eq(host.State.Stage, 4, "the further stage survives")
    t.eq(host.State.Droppers[firstDropper.Id], 9)
    t.eq(host.State.Droppers[DropperData.List[2].Id], 4, "the joiner's wellsprings came with them")
end)

t.test("declining a link changes nothing", function()
    local services = boot()
    local ash = join(services, "Ash", 1)
    local bree = join(services, "Bree", 2)
    local host = sanctumOf(services, ash)
    local guestPlot = sanctumOf(services, bree)

    services.PlotService:RequestLink(bree, host)
    services.PlotService:ResolveLink(ash, host, false)
    Mock.advance(0)
    t.eq(#services.PlotService:GetOccupants(host), 1)
    t.eq(sanctumOf(services, bree).Id, guestPlot.Id, "the joiner stayed home")
end)

t.test("a link offer expires on its own", function()
    local services = boot()
    local ash = join(services, "Ash", 1)
    local bree = join(services, "Bree", 2)
    local host = sanctumOf(services, ash)
    services.PlotService:RequestLink(bree, host)
    Mock.advance(GameConfig.Plot.LinkConfirmSeconds + 5)
    services.PlotService:ResolveLink(ash, host, true)
    Mock.advance(0)
    t.eq(#services.PlotService:GetOccupants(host), 1, "an expired offer cannot be accepted late")
end)

t.test("a player already in a sanctum cannot be linked into a second one", function()
    local services = boot()
    local ash = join(services, "Ash", 1)
    local bree = join(services, "Bree", 2)
    local host = sanctumOf(services, ash)
    services.PlotService:RequestLink(bree, host)
    services.PlotService:ResolveLink(ash, host, true)
    Mock.advance(0)

    local cass = join(services, "Cass", 3)
    local cassPlot = sanctumOf(services, cass)
    -- The plot is full; a third occupant must be refused.
    local ok = services.PlotService:RequestLink(cass, host)
    services.PlotService:ResolveLink(ash, host, true)
    Mock.advance(0)
    t.eq(#services.PlotService:GetOccupants(host), GameConfig.Plot.SlotsPerSanctum)
    t.eq(sanctumOf(services, cass).Id, cassPlot.Id, "the third player stayed in their own plot")
end)

t.test("both occupants' prestige lifts the shared income", function()
    local services = boot()
    local ash = join(services, "Ash", 1, function(profile) profile.Prestige.Rebirths = 6 end)
    local bree = join(services, "Bree", 2, function(profile) profile.Prestige.Rebirths = 6 end)
    local host = sanctumOf(services, ash)

    Mock.advance(60)
    local solo = host.State.Essence
    host.State.Essence = 0

    services.PlotService:RequestLink(bree, host)
    services.PlotService:ResolveLink(ash, host, true)
    Mock.advance(0)
    Mock.advance(60)
    t.gt(host.State.Essence, solo, "a partner's prestige is felt immediately in the shared wallet")
end)

-------------------------------------------------------------------------------
-- Leaving
-------------------------------------------------------------------------------
t.test("a partner leaving does not pause the remaining player's income", function()
    local services = boot()
    local ash = join(services, "Ash", 1)
    local bree = join(services, "Bree", 2)
    local host = sanctumOf(services, ash)
    services.PlotService:RequestLink(bree, host)
    services.PlotService:ResolveLink(ash, host, true)
    Mock.advance(0)

    Mock.removePlayer(bree)
    Mock.advance(0)
    t.eq(#services.PlotService:GetOccupants(host), 1)

    local before = host.State.Essence
    Mock.advance(60)
    -- DECISIONS #6: pausing would punish the player who stayed for something they did not do.
    t.gt(host.State.Essence, before, "the sanctum keeps running for whoever is left")
end)

t.test("the shared plot is mirrored to every occupant's save", function()
    local services = boot()
    local ash, ashProfile = join(services, "Ash", 1)
    local bree, breeProfile = join(services, "Bree", 2)
    local host = sanctumOf(services, ash)
    services.PlotService:RequestLink(bree, host)
    services.PlotService:ResolveLink(ash, host, true)
    Mock.advance(0)
    Mock.advance(120)

    services.PlotService:SaveAll(false)
    Mock.advance(0)
    -- Both players genuinely co-own the result, so both carry it home.
    t.gt(ashProfile.Plot.Essence, 0)
    t.eq(breeProfile.Plot.Essence, ashProfile.Plot.Essence)
    t.eq(breeProfile.Plot.Stage, ashProfile.Plot.Stage)
end)

t.test("prestige is never mirrored between partners", function()
    local services = boot()
    local ash, ashProfile = join(services, "Ash", 1, function(p) p.Prestige.Rebirths = 5 end)
    local bree, breeProfile = join(services, "Bree", 2)
    local host = sanctumOf(services, ash)
    services.PlotService:RequestLink(bree, host)
    services.PlotService:ResolveLink(ash, host, true)
    Mock.advance(30)
    services.PlotService:SaveAll(false)
    Mock.advance(0)
    t.eq(ashProfile.Prestige.Rebirths, 5)
    t.eq(breeProfile.Prestige.Rebirths, 0, "prestige is the one thing you can only earn yourself")
end)

t.test("the last occupant leaving frees the sanctum after the grace period", function()
    local services = boot()
    local ash = join(services, "Ash", 1)
    local sanctum = sanctumOf(services, ash)
    Mock.advance(120)
    t.gt(sanctum.State.Essence, 0)

    Mock.removePlayer(ash)
    Mock.advance(1)
    t.eq(#services.PlotService:GetOccupants(sanctum), 0)
    -- Inside the grace window a disconnect-and-rejoin must not cost the plot.
    t.gt(sanctum.State.Essence, 0, "the plot is held, not wiped, during the grace period")

    Mock.advance(GameConfig.Plot.ReleaseGraceSeconds + 5)
    t.eq(sanctum.State.Essence, 0, "and is reset once the grace period lapses")
    t.eq(sanctum.State.Stage, 1)
end)

t.test("a rejoin inside the grace window keeps the plot", function()
    local services = boot()
    local ash = join(services, "Ash", 1)
    local sanctum = sanctumOf(services, ash)
    Mock.advance(120)
    local earned = sanctum.State.Essence

    Mock.removePlayer(ash)
    Mock.advance(GameConfig.Plot.ReleaseGraceSeconds / 2)
    local again = join(services, "Ash", 1)
    local reclaimed = sanctumOf(services, again)
    t.truthy(reclaimed)
    t.gt(reclaimed.State.Essence, earned * 0.5,
        "a dropped connection must not cost an hour of progress")
end)

t.test("releasing an unknown player is harmless", function()
    local services = boot()
    local stranger = Mock.addPlayer("Stranger", 999)
    t.noThrow(function() services.PlotService:ReleaseOccupant(stranger) end)
    t.noThrow(function() services.PlotService:ReleaseOccupant(nil) end)
    t.noThrow(function() services.PlotService:GetSanctumForPlayer(nil) end)
    t.noThrow(function() services.PlotService:MarkDirty(nil) end)
    t.noThrow(function() services.PlotService:RequestLink(nil, nil) end)
    t.noThrow(function() services.PlotService:ResolveLink(nil, nil, true) end)
end)

t.test("a forged LinkResponse cannot join a plot that never offered", function()
    local services = boot()
    local ash = join(services, "Ash", 1)
    local bree = join(services, "Bree", 2)
    local host = sanctumOf(services, ash)
    -- No RequestLink was ever made. The remote names a plot, never an outcome.
    Mock.fireServer("LinkResponse", bree, { PlotId = host.Id, Accept = true })
    Mock.advance(0)
    t.eq(#services.PlotService:GetOccupants(host), 1, "acceptance requires a pending offer")

    for _, payload in ipairs({ { PlotId = 9999, Accept = true }, { PlotId = -1, Accept = true } }) do
        t.noThrow(function() Mock.fireServer("LinkResponse", bree, payload) end)
    end
end)

t.test("a solo player CAN link out -- this is the whole two-player hook", function()
    -- Regression guard. Every player auto-claims a Sanctum the moment their Profile loads, so a
    -- "you already have a plot" gate on linking makes co-op play unreachable: the feature the game
    -- is named for would refuse every request in production while every unit test still passed.
    local services = boot()
    local ash = join(services, "Ash", 1)
    local bree = join(services, "Bree", 2)
    local host = sanctumOf(services, ash)
    t.truthy(sanctumOf(services, bree), "the joiner starts with a plot of their own, as everyone does")

    local ok, reason = services.PlotService:RequestLink(bree, host)
    t.truthy(ok, "a solo player must be able to ask: " .. tostring(reason))
    services.PlotService:ResolveLink(ash, host, true)
    Mock.advance(0)
    t.eq(#services.PlotService:GetOccupants(host), 2)
end)

t.test("linking out frees the joiner's old sanctum for someone else", function()
    local services = boot()
    local ash = join(services, "Ash", 1)
    local bree = join(services, "Bree", 2)
    local host = sanctumOf(services, ash)
    local vacated = sanctumOf(services, bree)

    services.PlotService:RequestLink(bree, host)
    services.PlotService:ResolveLink(ash, host, true)
    Mock.advance(0)
    t.eq(#services.PlotService:GetOccupants(vacated), 0, "their old plot is empty")

    -- A deliberate move is not a disconnect, so the plot must not stay reserved for them.
    local cass = join(services, "Cass", 3)
    t.truthy(sanctumOf(services, cass), "a new player can take it")
end)

t.test("a player with a partner cannot link out and strand them", function()
    local services = boot()
    local ash = join(services, "Ash", 1)
    local bree = join(services, "Bree", 2)
    local cass = join(services, "Cass", 3)
    local pairPlot = sanctumOf(services, ash)
    local third = sanctumOf(services, cass)

    services.PlotService:RequestLink(bree, pairPlot)
    services.PlotService:ResolveLink(ash, pairPlot, true)
    Mock.advance(0)
    t.eq(#services.PlotService:GetOccupants(pairPlot), 2)

    -- Bree now has a partner. Linking away would leave Ash in a state about to be merged elsewhere.
    local ok = services.PlotService:RequestLink(bree, third)
    t.falsy(ok, "leaving a partner behind by linking is refused")
    t.eq(#services.PlotService:GetOccupants(pairPlot), 2)
end)

t.test("the accept-time recheck catches a partner arriving during the confirmation window", function()
    local services = boot()
    local ash = join(services, "Ash", 1)
    local bree = join(services, "Bree", 2)
    local cass = join(services, "Cass", 3)
    local host = sanctumOf(services, ash)
    local breePlot = sanctumOf(services, bree)

    -- Bree asks to join Ash while still alone...
    t.truthy(services.PlotService:RequestLink(bree, host))
    -- ...then Cass links into Bree's plot before Ash answers.
    services.PlotService:RequestLink(cass, breePlot)
    services.PlotService:ResolveLink(bree, breePlot, true)
    Mock.advance(0)
    t.eq(#services.PlotService:GetOccupants(breePlot), 2)

    -- Ash accepts now. Every gate is re-checked against live state, so Bree must not be moved.
    services.PlotService:ResolveLink(ash, host, true)
    Mock.advance(0)
    t.eq(#services.PlotService:GetOccupants(host), 1, "Cass would have been stranded")
    t.eq(sanctumOf(services, bree).Id, breePlot.Id)
end)
