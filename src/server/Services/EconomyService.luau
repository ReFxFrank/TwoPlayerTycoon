--!strict
--[[
	EconomyService
	The ONLY writer of PlotState.Essence in the whole game. Every other service asks it: motes credit
	through Credit, pads and attunements spend through TryDebit, and nothing else is allowed to touch
	the shared wallet. It also owns the per-Sanctum Multipliers CACHE -- Economy.getMultipliers walks
	every upgrade in the catalogue and this runs inside the one income Heartbeat, so the result is
	computed on change (RefreshMultipliers) rather than on read. Every method is total: it runs in
	that shared loop, where one error would stop income for every Sanctum on the server.
	Owner: server/Services  |  Consumers: PlotService, PurchaseService, EvolutionService,
	                                      RebirthService, StateReplicator, LeaderboardService
]]

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local Economy = require(Modules:WaitForChild("Economy"))
local GameConfig = require(Modules:WaitForChild("GameConfig"))
local StateSchema = require(Modules:WaitForChild("StateSchema"))

type Multipliers = Economy.Multipliers
--[[ Every public method takes the Sanctum as `any` rather than a named type. Two reasons: PlotService
     owns the real Sanctum type and resolves THIS service through the registry, so naming it here
     would be a require cycle; and the argument is untrusted anyway -- it is validated at runtime by
     stateOf, which is what lets the harness drive these methods with a plain table. Only State,
     Occupants and Dirty are ever touched. ]]
type Occupant = { [string]: any }

local function isFinite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local MAX_CURRENCY = StateSchema.MAX_CURRENCY
--[[ Dust floor. A credit smaller than this is arithmetic noise -- a rounding remainder, or a corrupt
     def yielding 1e-300 -- and adding it to a wallet held as a double changes nothing while still
     costing a dirty flag and a replication tick every frame. GameConfig owns the number; the guard
     is here because a hand-edited config must never turn the floor into NaN (which rejects every
     credit) or into a large number (which would silently swallow real income). ]]
local CONFIGURED_FLOOR = GameConfig.Income.MinCredit
local MIN_CREDIT = math.clamp(if isFinite(CONFIGURED_FLOOR) then CONFIGURED_FLOOR else 0.0001, 0, 1)
local EMPTY: { [string]: any } = {}
-- No occupants resolved => no prestige bonus. Shared and never written to.
local NO_REBIRTHS: { number } = {}

local Service = {}
Service.Name = "EconomyService"

local profiles: any = nil -- ProfileService, resolved in Init (registered before this service)
local plots: any = nil -- PlotService, resolved LAZILY: it is registered AFTER this service
local registryRef: any = nil
-- Fires at most once per boot: the clamp below can only engage on a balance bug, and a warning per
-- mote would bury the one line that matters under thousands of copies.
local clampWarned = false

-- Every currency read passes through here: NaN/inf/nil/string all collapse to 0, and a stored value
-- above the ceiling (a corrupt save) is repaired on the spot rather than propagated into a write.
local function currency(v: any): number
	return if isFinite(v) then math.clamp(v :: number, 0, MAX_CURRENCY) else 0
end

--[[ The one gate every public method opens with. A nil, non-table or State-less Sanctum returns nil
     and the caller no-ops: PlotService drives all six Sanctums from ONE Heartbeat, so erroring on a
     half-released plot would take income down for every player on the server, not just that one. ]]
local function stateOf(sanctum: any): { [string]: any }?
	if type(sanctum) ~= "table" then return nil end
	local state = (sanctum :: { [string]: any }).State
	return if type(state) == "table" then state :: { [string]: any } else nil
end

--[[ Occupants is keyed by UserId in PlotService, but this walks it with `pairs` and reads each entry
     structurally, so a differently-keyed table (or one holding a nil-ed slot mid-release) iterates
     correctly instead of erroring. ]]
local function eachOccupant(sanctum: any, fn: (Occupant) -> ()): ()
	local list = (sanctum :: { [string]: any }).Occupants
	if type(list) ~= "table" then return end
	for _, entry in pairs(list :: { [any]: any }) do
		if type(entry) == "table" then fn(entry :: Occupant) end
	end
end

-- pcall'd: a Player is userdata, and reading a field off one that has already left can throw. A
-- failed read simply means "cannot identify this player", never a crash inside the income loop.
local function userIdOf(player: any): number?
	if player == nil then return nil end
	local ok, id = pcall(function(): any return (player :: any).UserId end)
	return if ok and isFinite(id) then id :: number else nil
end

-- Identity by object first, UserId second: the object compare is what matches under Roblox, the
-- UserId compare is what matches a rejoined Player instance or a harness table.
local function isSource(occupant: Occupant, player: any, userId: number?): boolean
	if player == nil then return false end
	if occupant.Player == player then return true end
	return userId ~= nil and occupant.UserId == userId
end

--[[ Dirty is set on the Sanctum FIRST, so the flag survives even when PlotService is not resolvable
     yet (boot order) -- StateReplicator reads the field, not the call. The peer call is what fires
     SanctumChanged for anyone listening. ]]
local function markDirty(sanctum: any): ()
	(sanctum :: { [string]: any }).Dirty = true
	-- TryGet, never Get: PlotService is legitimately absent during Init and in unit tests, where Get
	-- would ERROR by design. The type check covers a stub registry (the harness passes a table with
	-- only Get) -- calling a nil TryGet would throw from inside the income loop.
	if plots == nil and type(registryRef) == "table" and type(registryRef.TryGet) == "function" then
		plots = registryRef:TryGet("PlotService")
	end
	if plots ~= nil and type(plots.MarkDirty) == "function" then
		plots:MarkDirty(sanctum)
	end
end

-- Weak KEYS so a Sanctum that PlotService has released is not pinned alive by its cached
-- multipliers; the entry disappears with the plot instead of leaking for the life of the server.
local function newCache(): { [any]: Multipliers }
	return (setmetatable({}, { __mode = "k" }) :: any) :: { [any]: Multipliers }
end
local cache: { [any]: Multipliers } = newCache()

--[[ The prestige half of the multiplier stack lives in per-player Profiles, not in PlotState, so it
     is gathered here per refresh. A missing profile contributes nothing rather than defaulting to
     something: a player whose profile failed to load must not silently earn a stranger's bonus. ]]
local function rebirthsOf(sanctum: any): { number }
	if profiles == nil then return NO_REBIRTHS end
	local list: { number } = {}
	eachOccupant(sanctum, function(occupant: Occupant)
		local player = occupant.Player
		if player == nil then return end
		local profile = profiles:Get(player)
		local prestige = if type(profile) == "table" then (profile :: any).Prestige else nil
		if type(prestige) == "table" then
			-- Raw: Economy.getPrestigeMultiplier clamps to RebirthData.MaxTrackedRebirths itself, so
			-- a tampered count is capped in exactly one place.
			table.insert(list, if isFinite(prestige.Rebirths) then prestige.Rebirths else 0)
		end
	end)
	return list
end

--[[ Public API ]]

--[[ Recompute and cache. MUST be called after any stage, affinity, upgrade or occupancy change --
     those are the four inputs to Economy.getMultipliers, and a stale cache would pay the old rate
     until something else happened to invalidate it. ]]
function Service:RefreshMultipliers(sanctum: any): Multipliers
	local state = stateOf(sanctum)
	if state == nil then
		-- A corrupt Sanctum still gets legal, neutral multipliers (Economy defaults every field) so
		-- the caller can multiply by them; nothing is cached against a key we could not validate.
		return Economy.getMultipliers(EMPTY :: any, NO_REBIRTHS)
	end
	local multipliers = Economy.getMultipliers(state :: any, rebirthsOf(sanctum))
	-- Frozen because the table is SHARED with every reader until the next refresh: a consumer
	-- adjusting one field in place would silently retune income for the whole Sanctum.
	cache[sanctum] = table.freeze(multipliers)
	return multipliers
end

-- Lazy read. The cache miss path is the same recompute, so a caller never has to know whether
-- anything has refreshed this Sanctum yet.
function Service:GetMultipliers(sanctum: any): Multipliers
	if type(sanctum) == "table" then
		local cached = cache[sanctum]
		if cached ~= nil then return cached end
	end
	return Service:RefreshMultipliers(sanctum)
end

--[[ The only way Essence enters the world. Returns the amount actually credited, which is 0 for
     every rejected call, so a caller can log or account for the difference.
     `amount` is already fully multiplied by the caller (MoteSystem values a mote through
     Economy.getMoteValue) -- this function applies no multipliers of its own. ]]
function Service:Credit(sanctum: any, amount: number, sourcePlayer: Player?): number
	local state = stateOf(sanctum)
	if state == nil then return 0 end
	-- `not isFinite` first: every comparison against NaN is false, so an unguarded `amount <= 0`
	-- would pass NaN straight through and poison the wallet permanently.
	if not isFinite(amount) or amount < MIN_CREDIT then return 0 end

	local wallet = currency(state.Essence)
	--[[ Ceiling clamp. MAX_CURRENCY (1e15) sits below 2^53, the last exactly-representable integer:
	     past it a shared wallet stops being exact and additions silently round away. Reaching it in
	     play is impossible, so the clamp engaging means a runaway multiplier -- worth exactly one
	     loud line, and worth surviving rather than storing an inf that would destroy the save. ]]
	local credited = math.min(amount, MAX_CURRENCY - wallet)
	if credited < amount and not clampWarned then
		clampWarned = true
		warn(("[EconomyService] essence clamped at %g -- a multiplier has run away"):format(MAX_CURRENCY))
	end
	if credited <= 0 then return 0 end

	state.Essence = wallet + credited
	-- LifetimeEssence is the transcendence gate and resets with the Sanctum, so it tracks what was
	-- actually banked, not what was offered: the clamped figure keeps the two in step.
	state.LifetimeEssence = math.min(currency(state.LifetimeEssence) + credited, MAX_CURRENCY)

	local sourceId = userIdOf(sourcePlayer)
	eachOccupant(sanctum, function(occupant: Occupant)
		-- Lifetime stat, per player, never reset: BOTH occupants earn from a shared wallet, so both
		-- profiles are credited in full rather than splitting one payout between them.
		local player = occupant.Player
		local profile = if player ~= nil and profiles ~= nil then profiles:Get(player) else nil
		local stats = if type(profile) == "table" then (profile :: any).Stats else nil
		if type(stats) == "table" then
			stats.TotalEssenceEarned = math.min(currency(stats.TotalEssenceEarned) + credited, MAX_CURRENCY)
		end
		if isSource(occupant, sourcePlayer, sourceId) then
			occupant.Contribution = math.min(currency(occupant.Contribution) + credited, MAX_CURRENCY)
		end
	end)

	markDirty(sanctum)
	return credited
end

--[[ The only way Essence leaves the world. Atomic in the sense that matters here: the balance is
     re-read from live state and tested INSIDE this call, so a price checked by PurchaseService a
     moment ago cannot be spent twice by two pads triggered on the same frame. Nothing is mutated on
     a failed debit, and Essence can never go negative. ]]
function Service:TryDebit(sanctum: any, amount: number): boolean
	local state = stateOf(sanctum)
	if state == nil then return false end
	-- NaN, inf (a maxed upgrade's cost) and negative "refunds" are all rejected here
	if not isFinite(amount) or amount < 0 then return false end
	-- Economy.canAfford, not a local comparison: the pad's affordability check and this debit must
	-- agree exactly, or a purchase can pass the gate and then fail to pay for itself.
	if not Economy.canAfford(state :: any, amount) then return false end
	if amount <= 0 then
		return true -- a free item (a FastMode-discounted cost that floored to 0): nothing to move
	end
	-- currency() re-clamps as it reads, so a corrupt balance ABOVE the ceiling is repaired by the
	-- same statement that spends from it rather than being carried forward into the next save.
	state.Essence = math.max(0, currency(state.Essence) - amount)
	markDirty(sanctum)
	return true
end

--[[ Session-only leaderboard flavour (spec 1.2): it records who carried, and touches NO wallet.
     Contribution lives on the Occupant, not in PlotState, so it is never saved and never merged. ]]
function Service:AddContribution(sanctum: any, player: any, amount: number): ()
	if stateOf(sanctum) == nil or not isFinite(amount) or amount <= 0 then return end
	local userId = userIdOf(player)
	eachOccupant(sanctum, function(occupant: Occupant)
		if isSource(occupant, player, userId) then
			occupant.Contribution = math.min(currency(occupant.Contribution) + amount, MAX_CURRENCY)
			markDirty(sanctum) -- Contribution rides the full snapshot; the partner panel reads it
		end
	end)
end

--[[ ServiceRegistry contract ]]

function Service:Init(registry: any): ()
	registryRef = registry
	profiles = registry:Get("ProfileService") -- resolved only: section 6 forbids calls during Init
	--[[ PlotService is registered AFTER this service, so it does not exist yet. It is resolved
	     lazily in markDirty instead -- Get here would error and abort the whole boot. ]]
	plots = nil
	-- Rebuilt so a re-Init never serves multipliers cached against a previous boot's Sanctums.
	cache = newCache()
	clampWarned = false
end

function Service:Start(): ()
	-- Nothing to connect: this service is entirely driven by its callers. The cache is invalidated
	-- by whoever changes an input (PlotService on occupancy, EvolutionService on stage/affinity,
	-- PurchaseService on an upgrade, RebirthService on prestige), which is the only correct moment.
end

function Service:Stop(): ()
	cache = newCache()
end

return Service
