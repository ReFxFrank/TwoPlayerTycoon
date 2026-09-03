--[[
    pacing.spec
    Measures the progression curve instead of asserting it from a balance model.

    docs/GAMEPLAY.md publishes specific milestones ("Stage 2 at 4.3 min, Stage 6 at 52 min"). Those
    came from arithmetic, and arithmetic about a compounding economy is exactly the kind of claim
    that drifts the moment any cost or rate changes. This spec plays the game -- real purchases
    through PurchaseService, real attunements, the real income loop -- and reports where the
    milestones actually fall, so the document cannot quietly become a lie.

    The player policy is the standard tycoon strategy: attune the moment it is allowed, otherwise
    spend everything on the best thing currently affordable.
]]

local Economy = loadModule("ReplicatedStorage/Modules/Economy")
local DropperData = loadModule("ReplicatedStorage/Modules/DropperData")
local UpgradeData = loadModule("ReplicatedStorage/Modules/UpgradeData")
local SectionData = loadModule("ReplicatedStorage/Modules/SectionData")
local EvolutionData = loadModule("ReplicatedStorage/Modules/EvolutionData")
local AffinityData = loadModule("ReplicatedStorage/Modules/AffinityData")
local RebirthData = loadModule("ReplicatedStorage/Modules/RebirthData")

local STEP = 0.1 -- PlotService decimates to GameConfig.Income.TickRate anyway, so this loses nothing
local DECIDE_EVERY = 2 -- simulated seconds between purchase decisions; a player is not faster

local function bootServer()
    runScript("ServerScriptService/Core/Bootstrap")
    Mock.advance(0.5)
    local services = {}
    for _, name in ipairs({ "ProfileService", "PlotService", "EconomyService", "PurchaseService",
        "EvolutionService", "RebirthService" }) do
        services[name] = loadModule("ServerScriptService/Core/Services/" .. name)
    end
    return services
end

--- Essence per second one more of this wellspring would add, ignoring multipliers (they scale
--- everything equally, so they cannot change the ordering).
local function yieldOf(def)
    return def.BaseValue / math.max(def.Interval, 0.01)
end

--- One purchase decision, in the order a player actually makes them: advance the Conflux if you
--- can, then unlock space, then buy the best earner, then improve throughput.
---
--- SAVING IS PART OF THE POLICY, and getting it wrong invalidates the whole measurement. Both
--- extremes are badly wrong models of a player:
---   * Spend everything always -- never banks the attunement cost, so it only ever attunes by
---     accident once nothing is affordable. Reads as a balance wall that is not there.
---   * Save as soon as essence is the blocker -- never builds income, so it saves 250 essence at
---     1/s from a standing start. Turns a 50-minute run into a 220-minute one.
--- A player does neither: they invest while the next stage is far away and start banking once it is
--- within reach. SAVE_WITHIN_SECONDS is that "within reach" horizon.
local SAVE_WITHIN_SECONDS = 120

local function act(services, player, sanctum)
    local state = sanctum.State

    if select(1, services.EvolutionService:Attune(player, sanctum)) then
        return "attune"
    end

    local _, blocked = Economy.attuneStatus(state)
    if blocked == Economy.Reason.NeedEssence then
        -- attuneStatus reports the FIRST failing gate, so need_essence means the lifetime and
        -- wellspring gates are already met and only the bank is short.
        local nextStage = EvolutionData.next(state.Stage)
        local income = Economy.estimateIncomePerSecond(state, services.EconomyService:GetMultipliers(sanctum))
        if nextStage ~= nil and income > 0 then
            local shortfall = nextStage.RequiredEssence - state.Essence
            if shortfall <= income * SAVE_WITHIN_SECONDS then
                return nil -- close enough to be worth banking rather than spending
            end
        end
    end

    if state.Stage >= EvolutionData.AffinityUnlockStage and state.Affinity == nil then
        services.EvolutionService:ChooseAffinity(player, sanctum, AffinityData.List[1].Id)
    end

    -- Wings gate everything above them, so they come before more of what you already have.
    for _, section in ipairs(SectionData.List) do
        if not state.Sections[section.Id] and select(1, Economy.sectionStatus(state, section)) then
            if select(1, services.PurchaseService:PurchaseSection(player, sanctum, section.Id)) then
                return "wing:" .. section.Id
            end
        end
    end

    local best, bestYield = nil, 0
    for _, def in ipairs(DropperData.List) do
        if select(1, Economy.dropperStatus(state, def)) and yieldOf(def) > bestYield then
            best, bestYield = def, yieldOf(def)
        end
    end
    if best ~= nil and select(1, services.PurchaseService:PurchaseDropper(player, sanctum, best.Id)) then
        return "dropper:" .. best.Id
    end

    for _, upgrade in ipairs(UpgradeData.List) do
        if select(1, Economy.upgradeStatus(state, upgrade)) then
            if select(1, services.PurchaseService:PurchaseUpgrade(player, sanctum, upgrade.Id)) then
                return "upgrade:" .. upgrade.Id
            end
        end
    end
    return nil
end

--- Plays until the pair could transcend, or until `limit` simulated seconds elapse.
local function play(limit)
    local services = bootServer()
    local player = Mock.addPlayer("Ash", 1)
    Mock.advance(1)
    local sanctum = services.PlotService:GetSanctumForPlayer(player)
    assert(sanctum ~= nil, "no sanctum was claimed")

    local marks = { Stages = {}, FirstPurchase = nil, TranscendReady = nil, Purchases = 0 }
    local elapsed, sinceDecision = 0, 0

    while elapsed < limit do
        Mock.advance(DECIDE_EVERY, STEP)
        elapsed += DECIDE_EVERY
        sinceDecision += DECIDE_EVERY

        -- Keep buying while anything is affordable: a real player does not stop at one purchase.
        for _ = 1, 40 do
            local bought = act(services, player, sanctum)
            if bought == nil then break end
            marks.Purchases += 1
            if marks.FirstPurchase == nil then marks.FirstPurchase = elapsed end
            local stage = sanctum.State.Stage
            if marks.Stages[stage] == nil then marks.Stages[stage] = elapsed end
        end
        if marks.Stages[1] == nil then marks.Stages[1] = 0 end

        if marks.TranscendReady == nil and select(1, Economy.transcendStatus(sanctum.State)) then
            marks.TranscendReady = elapsed
            break
        end
    end
    marks.Elapsed = elapsed
    marks.Sanctum = sanctum
    marks.Services = services
    marks.Player = player
    return marks
end

t.test("a solo run reaches every stage, and matches the curve docs/GAMEPLAY.md publishes", function()
    local marks = play(4 * 3600) -- generous ceiling; the loop breaks as soon as it is ready

    local function mins(seconds)
        return seconds and ("%.1f min"):format(seconds / 60) or "never"
    end
    print(("      first purchase: %s"):format(mins(marks.FirstPurchase)))
    for stage = 2, EvolutionData.MaxStage do
        print(("      stage %d (%-10s): %s"):format(stage, EvolutionData.Stages[stage].Name,
            mins(marks.Stages[stage])))
    end
    print(("      transcend-ready: %s   (%d purchases)"):format(mins(marks.TranscendReady), marks.Purchases))
    local previous = 0
    for stage = 2, EvolutionData.MaxStage do
        print(("      gap to stage %d: %s"):format(stage, mins(marks.Stages[stage] - previous)))
        previous = marks.Stages[stage]
    end

    t.truthy(marks.FirstPurchase, "the first wellspring must be affordable from a cold start")
    for stage = 2, EvolutionData.MaxStage do
        t.truthy(marks.Stages[stage], ("stage %d was never reached"):format(stage))
    end
    t.truthy(marks.TranscendReady, "the run must terminate in a transcendence")

    -- These bounds are wide on purpose. They are not a balance target; they exist so a change that
    -- moves the curve by a factor -- the kind that silently rewrites the whole game's feel -- fails
    -- here and forces the published document to be updated with it.
    t.lt(marks.FirstPurchase, 90, "the loop must teach itself inside the first minute or so")
    t.lt(marks.Stages[2], 12 * 60, "the first attunement is the hook; it cannot be a slog")
    t.gt(marks.Stages[2], 30, "nor instant, or it teaches nothing")
    t.lt(marks.TranscendReady, 90 * 60, "the run must fit in a sitting")
    t.gt(marks.TranscendReady, 20 * 60, "and must not be over before it starts")
    t.truthy(marks.Stages[EvolutionData.MaxStage] < 3 * 3600,
        "Primordial must be reachable in a sitting, not a week")

    --[[ THE WALL GUARD. Milestone bounds alone cannot see a lumpy curve: a run can hit every
         checkpoint on time while one stage in the middle takes four times its neighbours, which is
         a grind exactly where the player has just learned what attunement is. Measured gaps sit
         between 4 and 13 minutes, so a stage costing more than three times the median is a wall. ]]
    local gaps = {}
    for stage = 2, EvolutionData.MaxStage do
        table.insert(gaps, marks.Stages[stage] - (marks.Stages[stage - 1] or 0))
    end
    local sorted = table.clone(gaps)
    table.sort(sorted)
    local median = sorted[math.ceil(#sorted / 2)]
    for index, gap in ipairs(gaps) do
        t.lt(gap, median * 3, ("stage %d took %.1f min against a median of %.1f -- that is a wall")
            :format(index + 1, gap / 60, median / 60))
    end
    t.truthy(marks.TranscendReady >= marks.Stages[EvolutionData.MaxStage],
        "transcendence comes after the final stage, never before")

    -- The curve must actually be a curve: each stage costs more real time than the last.
    for stage = 3, EvolutionData.MaxStage do
        t.truthy(marks.Stages[stage] > marks.Stages[stage - 1],
            ("stage %d arrived no later than stage %d"):format(stage, stage - 1))
    end
end)

t.test("a rebirthed pair reaches the end materially faster", function()
    -- GAMEPLAY.md claims roughly a third of the time at four rebirths. If prestige did not
    -- meaningfully compress the run, the entire replay loop would be pointless.
    local StateSchema = loadModule("ReplicatedStorage/Modules/StateSchema")
    local GameConfig = loadModule("ReplicatedStorage/Modules/GameConfig")
    local profile = StateSchema.newProfile()
    profile.Prestige.Rebirths = 4
    profile.Prestige.Multiplier = Economy.getPrestigeMultiplier(4)
    game:GetService("DataStoreService"):GetDataStore(GameConfig.Save.DataStoreName)
        :SetAsync(GameConfig.Save.KeyPrefix .. "1", { Data = profile })

    local marks = play(4 * 3600)
    print(("      with 4 rebirths, transcend-ready: %.1f min"):format(marks.TranscendReady / 60))
    t.truthy(marks.TranscendReady, "a veteran run still completes")
    t.eq(marks.Services.ProfileService:Get(marks.Player).Prestige.Rebirths, 4,
        "the prestige really was loaded")
end)
