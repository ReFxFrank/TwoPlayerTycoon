--!strict
--[[
	RebirthService
	Transcendence: the consensus vote and the reset behind it. It opens a vote when an occupant asks,
	broadcasts the live ballot, and executes only when EVERY current occupant has voted yes inside
	GameConfig.Rebirth.VoteWindowSeconds (spec 9.5 item 2) -- a single no, a departure, a roster
	change or the window running out all cancel it. Execution grants every occupant their permanent
	prestige, wipes the shared PlotState back to a seeded Stage 1 Sanctum, and saves them at once.
	Owner: server/Services  |  Consumers: PurchaseService (the transcendence pad), tests
]]
--[[ WHY CONSENSUS, AND WHY THE RESET COMES LAST. A shared plot with a unilateral reset button is a
     griefing tool (DECISIONS #9), so the vote is the gate; a solo occupant's single yes IS
     unanimous, so playing alone is never blocked. Execute's ordering is the difference between a
     rebirth and a disaster: Prestige is written FIRST (the only thing a player cannot re-earn), the
     Sanctum is reset second, and each Profile is given the RESET plot before it is saved. Saving
     ahead of that mirror persists "Stage 6 plot + one extra rebirth": a free rebirth every rejoin. ]]

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local DropperData = require(Modules:WaitForChild("DropperData"))
local Economy = require(Modules:WaitForChild("Economy"))
local GameConfig = require(Modules:WaitForChild("GameConfig"))
local RebirthData = require(Modules:WaitForChild("RebirthData"))

local PrestigeAward = require(script.Parent.PrestigeAward)
local RebirthAnnounce = require(script.Parent.RebirthAnnounce)
local StateSchema = require(Modules:WaitForChild("StateSchema"))

type Connection = { Disconnect: (self: any) -> () }
-- One live vote. Sanctum is held by reference so a stale timer can prove which vote it is cancelling.
type Vote = { Sanctum: any, ExpiresAt: number, Ballots: { [number]: boolean } }

local STARTER_DROPPER = "ember_vent" -- DropperData's balance model names this the cold-start seed
local WINDOW = math.max(1, GameConfig.Rebirth.VoteWindowSeconds)
local MAX_CURRENCY = StateSchema.MAX_CURRENCY

local Service = {}
Service.Name = "RebirthService"

-- Closed set (DECISIONS #11): the client maps a code to wording, and a gate never returns prose.
local Reason = {
	UnknownSanctum = "unknown_sanctum", -- not a table, or carrying no PlotState
	NoPlayer = "no_player", -- not an occupant of THIS Sanctum, so not entitled to reset it
	VoteOpen = "vote_open", -- one vote at a time; a second request is a duplicate, not a new one
	Declined = "declined", Expired = "expired", RosterChanged = "roster_changed", Ok = Economy.Reason.Ok,
	NeedStage = Economy.Reason.NeedStage, NeedLifetime = Economy.Reason.NeedLifetime,
}
Service.Reason = Reason

local plots: any, economy: any, profiles: any, remotes: any = nil, nil, nil, nil
local evolution: any = nil -- optional presentation peer; see Init
local connections: { Connection } = {}
-- Weak KEYS so a Sanctum PlotService has released is not pinned alive by an abandoned ballot.
local function newBallotBook(): { [any]: Vote }
	return (setmetatable({}, { __mode = "k" }) :: any) :: { [any]: Vote }
end
local active: { [any]: Vote } = newBallotBook()

local function stateOf(sanctum: any): { [string]: any }?
	local state = if type(sanctum) == "table" then (sanctum :: { [string]: any }).State else nil
	return if type(state) == "table" then state :: { [string]: any } else nil
end
-- pcall'd: a Player is userdata, and reading a field off one who has already left can throw.
local function userIdOf(player: any): number?
	local ok, id = pcall(function(): any return (player :: any).UserId end)
	return if ok and type(id) == "number" and id == id then id else nil
end
local function nameOf(player: any): string
	local ok, name = pcall(function(): any return (player :: any).Name end)
	return if ok and type(name) == "string" then name else "Occupant"
end
-- NaN/inf/nil all collapse to 0: these figures are written straight back into a save.
local function currency(v: any): number
	local finite = type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
	return if finite then math.clamp(v :: number, 0, MAX_CURRENCY) else 0
end
local function occupantsOf(sanctum: any): { Player }
	return if plots ~= nil then plots:GetOccupants(sanctum) else {}
end
local function plotIdOf(sanctum: any): number
	local id = if type(sanctum) == "table" then (sanctum :: { [string]: any }).Id else nil
	return if type(id) == "number" and id == id then id else 0
end
-- Authorisation: only a live occupant of THIS Sanctum may open or answer its vote.
local function isOccupant(sanctum: any, player: any): boolean
	for _, other in ipairs(occupantsOf(sanctum)) do
		if other == player then return true end
	end
	return false
end
-- Delegated to RebirthAnnounce, which owns the whole client-facing surface of a vote.
local function notify(sanctum: any, kind: string, text: string): ()
	RebirthAnnounce.notify(sanctum, kind, text)
end
local function broadcast(sanctum: any, vote: any): ()
	RebirthAnnounce.broadcast(sanctum, vote)
end

function Service:CanTranscend(sanctum: any): (boolean, string)
	local state = stateOf(sanctum)
	if state == nil then return false, Reason.UnknownSanctum end
	return Economy.transcendStatus(state :: any)
end

-- Grants prestige, wipes the Sanctum and re-seeds it. Reached only from a unanimous ballot, so
-- "every occupant" and "everyone who voted yes" (spec 9.5 item 2) are the same set here.
function Service:Execute(sanctum: any): ()
	local state = stateOf(sanctum)
	if state == nil then return end
	active[sanctum] = nil
	-- The terminal ballot, sent FIRST so it survives any later error. Cancel was the only path
	-- sending it, so a SUCCESSFUL vote used to leave both clients holding a scrim over a wiped
	-- Sanctum, with the expiry timer finding active[sanctum] already cleared and cancelling nothing.
	broadcast(sanctum, nil)
	local occupants = occupantsOf(sanctum)
	local banked = currency(state.LifetimeEssence) -- read BEFORE the reset zeroes it
	for _, player in ipairs(occupants) do
		local profile = if profiles ~= nil then profiles:Get(player) else nil
		PrestigeAward.pay(if type(profile) == "table" then (profile :: any).Prestige else nil, banked)
	end

	-- The Sanctum, not the players: Prestige lives in a different table precisely so a bug here
	-- cannot touch the one thing players cannot re-earn.
	local fresh = StateSchema.newPlotState()
	-- THE COLD-START INVARIANT, restored here as well as in PlotSession: a Sanctum with no Wellspring
	-- earns exactly zero, and zero income never affords a first purchase, so the pair would be stuck
	-- forever holding a fresh multiplier they could not use.
	local starter = DropperData.get(STARTER_DROPPER) or DropperData.List[1]
	if starter ~= nil then fresh.Droppers[starter.Id] = 1 end
	;(sanctum :: { [string]: any }).State = fresh

	-- Motes in flight belong to the run that just ended; crediting them would pay the pair for
	-- pressing the button. RebuildSanctum re-derives emit streams, Wings, the cache and pad wording.
	if plots ~= nil then
		plots:ClearMotes(sanctum)
		plots:RebuildSanctum(sanctum)
	end
	-- Explicit as well as via RebuildSanctum: prestige just changed, and RebuildSanctum is a no-op
	-- for a Sanctum this PlotService does not own (a spec fixture), where the cache would stay stale.
	if economy ~= nil then economy:RefreshMultipliers(sanctum) end
	if evolution ~= nil then
		evolution:ApplyStageVisuals(sanctum) -- Conflux back to Stage 1, four Wings back out of the world
		evolution:ApplyStageStats(sanctum) -- and both characters back to 16 studs/s
	end
	if plots ~= nil then plots:MarkDirty(sanctum) end

	if remotes ~= nil then
		--[[ Per player, not FireClients: the banner names THIS occupant's new rebirth count, and the
		     count is per player. The client's snapshot is up to a full replication interval behind
		     at this instant and the banner renders once, so the number has to ride the payload --
		     otherwise every Transcendence announces the count from before it. ]]
		for _, occupant in ipairs(occupants) do
			local profile = if profiles ~= nil then profiles:Get(occupant) else nil
			local prestige = if type(profile) == "table" then (profile :: any).Prestige else nil
			remotes:FireClient(occupant, "Fx", { Kind = "transcend", PlotId = plotIdOf(sanctum),
				Data = { Rebirths = if type(prestige) == "table" then prestige.Rebirths else nil } })
		end
	end
	notify(sanctum, "success", "The Conflux transcends. The Sanctum is new; the power is yours to keep.")
	-- Mirror the RESET plot, then save immediately rather than at the next autosave: PlotService's
	-- own mirror is up to a second away (see the note at the top), and a rebirth lost to a crash is
	-- unrecoverable because the hour of progress that bought it is already gone from the Sanctum.
	for _, player in ipairs(occupants) do
		local profile = if profiles ~= nil then profiles:Get(player) else nil
		if type(profile) == "table" then (profile :: any).Plot = StateSchema.clonePlotState(fresh) end
		if profiles ~= nil then profiles:Save(player) end
	end
end

-- Cancels the live vote and pushes the terminal state. Total and idempotent: it is reached from a
-- "no", a departure, an expiry and a roster change, and two of those can land on one frame.
function Service:Cancel(sanctum: any, reason: string): ()
	local vote = if type(sanctum) == "table" then active[sanctum] else nil
	if vote == nil then return end
	active[sanctum] = nil
	broadcast(sanctum, nil)
	notify(sanctum, "warn", if reason == Reason.Expired
		then "The Transcendence vote expired. Nothing was reset."
		else "The Transcendence vote was called off. Nothing was reset.")
end

--[[ Unanimity is measured against the LIVE occupant list, not against who was present when the vote
     opened: that is what makes "every occupant must vote yes" true at the moment of the reset rather
     than thirty seconds earlier. Only an occupant can reach here, so it is never vacuously true. ]]
local function tally(sanctum: any, vote: Vote): ()
	for _, other in ipairs(occupantsOf(sanctum)) do
		local id = userIdOf(other)
		if id == nil or vote.Ballots[id] ~= true then
			broadcast(sanctum, vote)
			return
		end
	end
	--[[ Re-checked at EXECUTION, not only at BeginVote. Unanimity is measured against the live
	     roster, but the SANCTUM can also move underneath an open ballot: PlotService:ResetSanctum
	     (the developer data reset) replaces State on the same table the ballot book is keyed by, so
	     a vote opened before it survives it. Without this the second yes mints permanent Prestige
	     on a blank Stage 1 Sanctum -- and Prestige is the one thing players cannot re-earn. ]]
	local state = stateOf(sanctum)
	if state == nil then return end
	if not (Economy.transcendStatus(state :: any)) then
		Service:Cancel(sanctum, Reason.Expired)
		return
	end
	Service:Execute(sanctum)
end

-- Opens the window. The initiator's own yes is counted immediately (they asked for it), which is
-- also what makes a SOLO occupant's single vote unanimous and executes on the spot.
function Service:BeginVote(player: any, sanctum: any): (boolean, string)
	local state = stateOf(sanctum)
	if state == nil then return false, Reason.UnknownSanctum end
	if not isOccupant(sanctum, player) then return false, Reason.NoPlayer end
	if active[sanctum] ~= nil then return false, Reason.VoteOpen end
	-- Re-checked against LIVE state: the pad's wording, the client's snapshot and any check made
	-- before the walk to the pad are all stale by definition.
	local allowed, reason = Economy.transcendStatus(state :: any)
	if not allowed then return false, reason end
	local userId = userIdOf(player)
	if userId == nil then return false, Reason.NoPlayer end

	local vote: Vote = { Sanctum = sanctum, ExpiresAt = os.time() + WINDOW, Ballots = { [userId] = true } }
	active[sanctum] = vote
	-- Identity, not a token, is the cancellation: a later vote on this Sanctum is a DIFFERENT table,
	-- so a stale timer finds a mismatch and leaves the new vote alone.
	task.delay(WINDOW, function()
		if active[sanctum] == vote then Service:Cancel(sanctum, Reason.Expired) end
	end)
	tally(sanctum, vote) -- broadcasts, or executes outright when the initiator is the only occupant
	return true, Reason.Ok
end

-- The RebirthVote remote lands here. The Sanctum comes from the sender's live occupancy, so nobody
-- can vote in a Transcendence they are not part of, and no payload names a plot.
function Service:CastVote(player: any, accept: boolean): ()
	local sanctum = if plots ~= nil then plots:GetSanctumForPlayer(player) else nil
	if sanctum == nil then return end
	local vote = active[sanctum]
	if vote == nil then
		-- Nothing open: a yes is a request to start one (the client's Confirm button doubles as
		-- both), and a no has nothing to refuse.
		if accept == true then Service:BeginVote(player, sanctum) end
		return
	end
	if not isOccupant(sanctum, player) then return end
	if accept ~= true then
		-- One no ends it at once. Waiting out the window would leave the pair staring at a countdown
		-- whose outcome is already decided.
		Service:Cancel(sanctum, Reason.Declined)
		return
	end
	local userId = userIdOf(player)
	if userId == nil then return end
	vote.Ballots[userId] = true
	tally(sanctum, vote)
end

function Service:Init(registry: any): () -- ServiceRegistry contract; resolve peers only
	-- Resolved only: section 6 forbids cross-service calls during Init.
	plots = registry:Get("PlotService")
	economy = registry:Get("EconomyService")
	profiles = registry:Get("ProfileService")
	remotes = registry:Get("RemoteService")
	RebirthAnnounce.bind({ Remotes = remotes, Occupants = occupantsOf, UserId = userIdOf,
		Name = nameOf, PlotId = plotIdOf })
	-- TryGet, not Get: EvolutionService is registered before this one so it is always there on a real
	-- boot, but its role here is PRESENTATION (repaint the Conflux, re-apply walk speed). A reset is
	-- correct without it, and refusing to boot a server over a cosmetic peer would be worse.
	evolution = registry:TryGet("EvolutionService")
	-- A re-Init must not inherit the previous boot's connections, nor a ballot from a dead world.
	for _, connection in ipairs(connections) do connection:Disconnect() end
	table.clear(connections)
	active = newBallotBook()
end

function Service:Start(): ()
	if remotes ~= nil then
		remotes:On("RebirthVote", function(player: Player, payload: any)
			Service:CastVote(player, type(payload) == "table" and (payload :: any).Accept == true)
		end)
	end
	-- Any change to who is in the Sanctum cancels the vote: a leaver would otherwise have their yes
	-- counted for a reset they are not part of, and a partner linking in mid-vote would be reset by
	-- a decision nobody asked them about.
	if plots ~= nil then
		local function roster(sanctum: any)
			Service:Cancel(sanctum, Reason.RosterChanged)
		end
		table.insert(connections, plots.OccupantRemoved:Connect(roster))
		table.insert(connections, plots.OccupantAdded:Connect(roster))
	end
end

function Service:Stop(): ()
	for _, connection in ipairs(connections) do connection:Disconnect() end
	table.clear(connections)
end

return Service
