--!strict
--[[
	EvolutionService
	The Attunement authority. It decides whether a Sanctum may take its next Stage, spends the Essence
	for it, advances the Stage by exactly one step, repaints the Conflux, re-applies both occupants'
	walk speed, and owns the permanent Stage 3 Affinity choice. It is the ONLY writer of
	PlotState.Stage and PlotState.Affinity, and every gate it opens is re-read from the LIVE state at
	the moment of the change: a client's copy, a pad's wording and a check made one frame ago are all
	hints, never permission.
	Owner: server/Services  |  Consumers: PurchaseService (the attunement pad), RebirthService (which
	                                      re-applies Stage 1 visuals after a reset), tests
]]
--[[ WHAT "unlock the Stage's UnlockedSections" MEANS, and why nothing priced is granted here. The
     manifest is the same kind as UnlockedDroppers/UnlockedUpgrades: it names what the Stage makes
     REACHABLE, not what it hands over -- a new tier of Wellsprings is bought, and so is a Wing.
     SectionData prices all four (2.5K -> 15M) around the loop "attune -> buy the Wing -> fill it ->
     attune again" and each Wing's RequiredStage IS the Stage listing it, so granting one here would
     make PurchaseService:PurchaseSection answer `already_owned` forever (four pads nobody could ever
     use) and delete ~15.7M Essence from a curve the owner confirmed final (spec 9.5 item 3). A Stage
     therefore OPENS its sections (Economy.sectionStatus does that from RequiredStage) and only a
     free one is granted outright; Wing visibility is then re-asserted from ownership. ]]

local Players = game:GetService("Players")

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local AffinityData = require(Modules:WaitForChild("AffinityData"))
local Economy = require(Modules:WaitForChild("Economy"))
local EvolutionData = require(Modules:WaitForChild("EvolutionData"))
local SectionData = require(Modules:WaitForChild("SectionData"))
local Theme = require(Modules:WaitForChild("Theme"))

local PlotBuilder = require(script.Parent.Parent:WaitForChild("Systems"):WaitForChild("PlotBuilder"))

-- Sanctum is `any` throughout: PlotService owns the real type and resolves THIS service through the
-- registry, so naming it would be a require cycle -- and the argument is untrusted anyway, which is
-- what lets the headless harness drive these methods with a plain table.
type Connection = { Disconnect: (self: any) -> () }

local Service = {}
Service.Name = "EvolutionService"

-- Closed set (DECISIONS #11): the client maps a code to wording, and a gate never returns prose.
-- Economy owns most of these; the two added here are about WHO is asking.
local Reason = {
	UnknownSanctum = "unknown_sanctum", -- not a table, or carrying no PlotState
	NoPlayer = "no_player", -- not an occupant, so not entitled to spend this Sanctum's wallet
	Ok = Economy.Reason.Ok, Insufficient = Economy.Reason.Insufficient,
	MaxStage = Economy.Reason.MaxStage, NeedStage = Economy.Reason.NeedStage,
	UnknownId = Economy.Reason.UnknownId, AlreadyOwned = Economy.Reason.AlreadyOwned,
}
Service.Reason = Reason

local plots: any, economy: any, remotes: any, registryRef: any = nil, nil, nil, nil
local purchases: any = nil -- registered AFTER this service; resolved lazily in refreshPads
local connections: { Connection } = {}
-- userId -> respawn watch, keyed by id so a rejoin replaces its own entry instead of leaking one.
local watched: { [number]: Connection } = {}

local function stateOf(sanctum: any): { [string]: any }?
	local state = if type(sanctum) == "table" then (sanctum :: { [string]: any }).State else nil
	return if type(state) == "table" then state :: { [string]: any } else nil
end

-- Clamped exactly as Economy clamps it, so "never skip a Stage, never pass MaxStage" holds even for
-- a stored Stage of 0, 9e99 or NaN.
local function stageOf(state: { [string]: any }): number
	local raw = state.Stage
	return math.clamp(math.floor(if type(raw) == "number" and raw == raw then raw else 1), 1, EvolutionData.MaxStage)
end

-- pcall'd: a Player is userdata and reading a field off one who has already left can throw.
local function userIdOf(player: any): number?
	local ok, id = pcall(function(): any return (player :: any).UserId end)
	return if ok and type(id) == "number" and id == id then id else nil
end

-- THE authorisation check for every mutation below. Occupants is keyed by UserId in PlotService,
-- but a direct hit is not assumed: a fixture (or a table caught mid-release) may be keyed otherwise,
-- so a structural sweep matches it rather than erroring inside a remote handler.
local function occupantOf(sanctum: any, player: any): boolean
	local userId, list = userIdOf(player), (sanctum :: { [string]: any }).Occupants
	if userId == nil or type(list) ~= "table" then return false end
	if type((list :: { [any]: any })[userId]) == "table" then return true end
	for _, entry in pairs(list :: { [any]: any }) do
		if type(entry) == "table" and (entry.Player == player or entry.UserId == userId) then return true end
	end
	return false
end

local function occupantsOf(sanctum: any): { Player }
	return if plots ~= nil then plots:GetOccupants(sanctum) else {}
end

-- PlotService's accessor first: it proves the Sanctum is one of ours before handing over its
-- Instance tree. A fixture is not, so the field is the fallback; every PlotBuilder entry point used
-- below is total against a malformed runtime.
local function runtimeOf(sanctum: any): any
	local runtime = if plots ~= nil then plots:GetSanctumRuntime(sanctum) else nil
	return if runtime ~= nil then runtime else (sanctum :: { [string]: any }).Runtime
end

-- A Stage change re-prices and re-opens pads, so signs must be redrawn. TryGet, never Get:
-- PurchaseService is registered AFTER this service and Get errors by design.
local function refreshPads(sanctum: any): ()
	if purchases == nil and registryRef ~= nil then purchases = registryRef:TryGet("PurchaseService") end
	if purchases ~= nil and type(purchases.RefreshPads) == "function" then purchases:RefreshPads(sanctum) end
end

-- MOCK-EXTRA: Humanoid.WalkSpeed assignment -- 3.1 lists Humanoid as read-only, and this is the one
-- write the Stage curve needs. Wrapped whole: a character mid-respawn is a Model whose Humanoid has
-- not been parented yet, which is normal and not worth an error inside the signal a death fires.
local function applySpeed(player: any, speed: number): ()
	pcall(function()
		local character = (player :: any).Character
		local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
		if humanoid ~= nil then humanoid.WalkSpeed = speed end
	end)
end

local function unwatch(userId: number?): ()
	local existing = if userId ~= nil then watched[userId] else nil
	if existing ~= nil then existing:Disconnect() end
	if userId ~= nil then watched[userId] = nil end
end
local function disconnectAll(): ()
	for _, connection in ipairs(connections) do connection:Disconnect() end
	table.clear(connections)
	for userId in pairs(watched) do unwatch(userId) end
end

function Service:CanAttune(sanctum: any): (boolean, string)
	local state = stateOf(sanctum)
	if state == nil then return false, Reason.UnknownSanctum end
	return Economy.attuneStatus(state :: any)
end

-- The Conflux's look follows (Stage, Affinity); every Wing's presence follows ownership. Both are
-- re-asserted rather than diffed -- a handful of writes on a rare event, and re-asserting REPAIRS a
-- Sanctum whose visuals drifted (a link merge that added a Wing, a reset that took four away).
function Service:ApplyStageVisuals(sanctum: any): ()
	local state = stateOf(sanctum)
	local runtime = if state ~= nil then runtimeOf(sanctum) else nil
	if state == nil or runtime == nil then return end

	local affinity = if type(state.Affinity) == "string" then state.Affinity :: string else nil
	PlotBuilder.setConfluxAppearance(runtime, Theme.getConfluxAppearance(stageOf(state), affinity))
	local owned = if type(state.Sections) == "table" then state.Sections :: { [string]: any } else nil
	for _, section in ipairs(SectionData.List) do
		local visible = section.Id == SectionData.Base or (owned ~= nil and owned[section.Id] == true)
		PlotBuilder.setSectionVisible(runtime, section.Id, visible)
	end
end

-- Walk speed is a Stage + Affinity property of the SANCTUM, applied to whoever stands in it now --
-- including a partner who linked in at Stage 6 and has never attuned anything themselves.
function Service:ApplyStageStats(sanctum: any): ()
	local state = stateOf(sanctum)
	if state == nil then return end
	local speed = Economy.getWalkSpeed(state :: any)
	for _, player in ipairs(occupantsOf(sanctum)) do applySpeed(player, speed) end
end

-- Spend the next Stage's RequiredEssence and take exactly one step up. Debit BEFORE mutating:
-- TryDebit re-reads the wallet and is atomic against a second pad triggered on the same frame, so
-- two occupants hammering the attunement pad together cannot buy one Stage twice or skip one.
function Service:Attune(player: any, sanctum: any): (boolean, string)
	local state = stateOf(sanctum)
	if state == nil then return false, Reason.UnknownSanctum end
	-- Re-checked from live occupancy even though the pad stands inside the Sanctum: a prompt can be
	-- triggered by anyone who can reach it, and reaching it is not the same as owning the wallet.
	if not occupantOf(sanctum, player) then return false, Reason.NoPlayer end
	local allowed, reason = Economy.attuneStatus(state :: any)
	if not allowed then return false, reason end

	-- attuneStatus already refuses the top Stage; nextStage is re-derived because the debit below
	-- reads RequiredEssence off that very table.
	local nextStage = EvolutionData.next(stageOf(state))
	if nextStage == nil then return false, Reason.MaxStage end
	-- A failed debit is only reachable when another spend landed between the gate and here. The
	-- Stage is NOT advanced: a free Attunement is far worse than a wasted prompt.
	if economy == nil or not economy:TryDebit(sanctum, nextStage.RequiredEssence) then
		return false, Reason.Insufficient
	end
	state.Stage = nextStage.Index
	if type(state.Sections) ~= "table" then state.Sections = {} end
	local sections = state.Sections :: { [string]: any }
	for _, id in ipairs(nextStage.UnlockedSections) do
		local def = SectionData.get(id) -- free sections only; see the note at the top of this file
		if def ~= nil and def.Cost <= 0 then sections[id] = true end
	end
	-- The Stage multiplier feeds every Mote's value, so the cache is rebuilt before the next tick.
	if economy ~= nil then economy:RefreshMultipliers(sanctum) end
	Service:ApplyStageVisuals(sanctum)
	Service:ApplyStageStats(sanctum)
	if plots ~= nil then plots:MarkDirty(sanctum) end
	refreshPads(sanctum)

	if remotes ~= nil then
		local to, id = occupantsOf(sanctum), (sanctum :: { [string]: any }).Id
		remotes:FireClients(to, "Fx", { Kind = "attune", Data = { Stage = nextStage.Index },
			PlotId = if type(id) == "number" then id else 0 })
		remotes:FireClients(to, "Notify", { Kind = "success",
			Text = string.format("Attuned to Stage %d -- %s.", nextStage.Index, nextStage.Title) })
	end
	return true, Reason.Ok
end

-- The Stage 3 elemental choice (spec 9.5 item 4). ONE Affinity per Sanctum, not one each: either
-- occupant may make it and it binds both until the next Transcendence. Refusals are ordered
-- most-permanent-first, so the client says "already chosen" rather than "wrong stage".
function Service:ChooseAffinity(player: any, sanctum: any, affinityId: any): (boolean, string)
	local state = stateOf(sanctum)
	if state == nil then return false, Reason.UnknownSanctum end
	if not occupantOf(sanctum, player) then return false, Reason.NoPlayer end
	-- RemoteSchema already rejects anything outside the catalogue at the wire; checked again because
	-- a pad path and a spec both reach this function without passing through that validator.
	if not AffinityData.isValid(affinityId) then return false, Reason.UnknownId end
	if AffinityData.isValid(state.Affinity) then return false, Reason.AlreadyOwned end
	if stageOf(state) < EvolutionData.AffinityUnlockStage then return false, Reason.NeedStage end

	state.Affinity = affinityId :: string
	-- One choice moves IncomeMultiplier, SpawnRate, MoteValue, RailSpeed and WalkSpeed at once, so
	-- the cache, the Conflux material and both characters all follow it in the same breath.
	if economy ~= nil then economy:RefreshMultipliers(sanctum) end
	Service:ApplyStageVisuals(sanctum)
	Service:ApplyStageStats(sanctum)
	if plots ~= nil then plots:MarkDirty(sanctum) end
	local def = AffinityData.get(affinityId :: string)
	if remotes ~= nil then
		remotes:FireClients(occupantsOf(sanctum), "Notify", { Kind = "success", Text = string.format(
			"The Conflux binds to %s. This lasts until you Transcend.", (def :: any).Name) })
	end
	return true, Reason.Ok
end

-- Respawn handling. Without it a death resets a Stage 6 player to 16 studs/s on a 200x200 stud
-- Sanctum, permanently, because nothing else ever re-writes WalkSpeed.
-- MOCK-EXTRA: Player.CharacterAdded.
local function watch(player: any): ()
	local userId = userIdOf(player)
	if userId == nil or watched[userId] ~= nil then return end
	local ok, connection = pcall(function(): any
		return (player :: any).CharacterAdded:Connect(function()
			-- Re-read the Sanctum instead of capturing it: by the time a respawn lands, this player
			-- may have left the plot or linked into another one at a different Stage.
			local sanctum = if plots ~= nil then plots:GetSanctumForPlayer(player) else nil
			if sanctum ~= nil then Service:ApplyStageStats(sanctum) end
		end)
	end)
	if ok and connection ~= nil then watched[userId] = connection end
end

function Service:Init(registry: any): () -- ServiceRegistry contract; resolve peers only
	registryRef = registry
	-- Resolved only: section 6 forbids cross-service calls during Init.
	plots = registry:Get("PlotService")
	economy = registry:Get("EconomyService")
	remotes = registry:Get("RemoteService")
	purchases = nil -- registered after this service; resolved lazily in refreshPads
	-- A re-Init must not inherit the previous boot's connections: they would keep writing WalkSpeed
	-- from a discarded registry's view of the world.
	disconnectAll()
end

function Service:Start(): ()
	if remotes ~= nil then
		-- The payload names an element and nothing else: the Sanctum comes from the sender's live
		-- occupancy, so nobody can bind an element in a plot they are not standing in.
		remotes:On("ChooseAffinity", function(player: Player, payload: any)
			local sanctum = if plots ~= nil then plots:GetSanctumForPlayer(player) else nil
			if sanctum == nil then return end
			local id = if type(payload) == "table" then (payload :: any).Affinity else nil
			-- One line and no code on refusal: a refused choice is either a stale modal or a probe,
			-- and naming the gate that closed only helps the second.
			if not Service:ChooseAffinity(player, sanctum, id) then
				remotes:FireClient(player, "Notify", { Kind = "warn",
					Text = "The Conflux will not bind to that right now." })
			end
		end)
	end
	-- A partner linking into a Stage 6 Sanctum inherits its speed at once; a fresh claimer is put
	-- back to 16 rather than keeping the speed of the plot they left.
	if plots ~= nil then
		table.insert(connections, plots.OccupantAdded:Connect(function(sanctum: any)
			Service:ApplyStageStats(sanctum)
		end))
	end
	table.insert(connections, Players.PlayerAdded:Connect(watch))
	table.insert(connections, Players.PlayerRemoving:Connect(function(player: Player)
		unwatch(userIdOf(player))
	end))
	for _, player in ipairs(Players:GetPlayers()) do watch(player) end -- joined before Start
end

function Service:Stop(): ()
	disconnectAll()
end

return Service
