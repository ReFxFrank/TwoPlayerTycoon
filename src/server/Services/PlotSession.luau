--!strict
--[[
	PlotSession
	Everything about a PLAYER's relationship to a Sanctum, kept apart from the machinery that makes a
	Sanctum run: which plot a claim lands on, the slot and spawn they get, the max-merge that admits
	a linked partner, the mirror of the live state into every occupant's Profile, and the grace
	window that lets a disconnect-and-rejoin keep the plot. PlotService owns it, drives it and
	publishes its results; it was split out only to keep every file inside the 300-line budget.
	Owner: server/Services  |  Consumers: PlotService (which binds exactly one)
]]

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local DropperData = require(Modules:WaitForChild("DropperData"))
local Economy = require(Modules:WaitForChild("Economy"))
local GameConfig = require(Modules:WaitForChild("GameConfig"))
local StateSchema = require(Modules:WaitForChild("StateSchema"))

type PlotState = StateSchema.PlotState
type Occupant = { UserId: number, Player: any, Slot: number, JoinedAt: number, Contribution: number, Vote: boolean? }
type Plot = any -- PlotRuntime's object; typed there, and naming it here would be a require cycle

local SLOTS = GameConfig.Plot.SlotsPerSanctum
local STARTER_DROPPER = "ember_vent" -- DropperData's balance model names this as the cold-start seed

local PlotSession = {}

-- Closed set (DECISIONS #11): the client maps a code to wording, and the server never sends prose.
local Reason = {
	Ok = "ok", UnknownSanctum = "unknown_sanctum",
	NoPlayer = "no_player", -- not a live player, or not an occupant entitled to answer
	AlreadyHere = "already_here", AlreadyLinked = "already_linked", -- §1.5: one Sanctum at a time
	SanctumEmpty = "sanctum_empty", -- claim it outright; there is nobody there to ask
	SanctumFull = "sanctum_full",
	NotLoaded = "not_loaded", -- no saved PlotState to merge, so no offer is made
}
PlotSession.Reason = Reason

local owner: any, plots: { Plot }, profiles: any, links: any = nil, {}, nil, nil
local byUserId: { [number]: Plot } = {}

-- pcall'd: a Player is userdata, and reading a field off one who has already left can throw.
local function userIdOf(player: any): number?
	if player == nil then return nil end
	local ok, id = pcall(function(): any return (player :: any).UserId end)
	return if ok and type(id) == "number" and id == id then id else nil
end

local function occupantCount(plot: Plot): number
	local total = 0
	for _ in pairs(plot.Sanctum.Occupants) do total += 1 end
	return total
end

local function freeSlot(plot: Plot): number?
	local taken: { [number]: boolean } = {}
	for _, occupant in pairs(plot.Sanctum.Occupants) do taken[occupant.Slot] = true end
	for slot = 1, SLOTS do
		if not taken[slot] then return slot end
	end
	return nil
end

local function addOccupant(plot: Plot, player: any, userId: number): Occupant?
	local slot = freeSlot(plot)
	if slot == nil then return nil end
	local occupant: Occupant = { UserId = userId, Player = player, Slot = slot,
		JoinedAt = os.time(), Contribution = 0, Vote = nil }
	plot.Sanctum.Occupants[userId] = occupant
	byUserId[userId] = plot
	-- Bumping the token cancels any armed release timer: a live occupant must never have their
	-- Sanctum blanked by a countdown that started before they arrived.
	plot.GraceToken += 1
	plot.Reserved = {}
	if plot.Sanctum.AnchorUserId == nil then plot.Sanctum.AnchorUserId = userId end
	plot:Watch(player, userId)
	plot:Seat(player, slot)
	owner.OccupantAdded:Fire(plot.Sanctum, player)
	return occupant
end

local function removeOccupant(plot: Plot, occupant: Occupant): ()
	local sanctum = plot.Sanctum
	sanctum.Occupants[occupant.UserId] = nil
	if byUserId[occupant.UserId] == plot then byUserId[occupant.UserId] = nil end
	--[[ Reserved for the grace window: a disconnect-and-rejoin must land back on this plot with its
	     progress intact, because losing a Sanctum to a dropped connection would be the single most
	     frustrating thing in the game (DECISIONS #6). ]]
	plot.Reserved[occupant.UserId] = true
	plot:Unwatch(occupant.UserId) -- their respawns are no longer this Sanctum's business
	if sanctum.AnchorUserId == occupant.UserId then
		-- Promote whoever is left, so the plot always has a nameable owner; nil when nobody is.
		sanctum.AnchorUserId = nil
		for id in pairs(sanctum.Occupants) do
			sanctum.AnchorUserId = id
			break
		end
	end
end

--[[ Writes the live shared PlotState into EVERY occupant's Profile (§1.5). Co-op means both players
     carry the same result home, so there is no host copy and no guest copy. CLONED, not aliased: a
     leaver's Profile must stop tracking a Sanctum they are no longer in. ]]
local function mirror(plot: Plot): ()
	if profiles == nil then return end
	for _, occupant in pairs(plot.Sanctum.Occupants) do
		local profile = profiles:Get(occupant.Player)
		if type(profile) == "table" then
			(profile :: any).Plot = StateSchema.clonePlotState(plot.Sanctum.State)
		end
	end
end

local function savedPlotOf(player: any): PlotState?
	local profile = if profiles ~= nil then profiles:Get(player) else nil
	local saved = if type(profile) == "table" then (profile :: any).Plot else nil
	return if type(saved) == "table" then saved :: PlotState else nil
end

--[[ Brings the claimer's saved PlotState into the Sanctum. A RECLAIM inside the grace window
     max-merges rather than replacing: the two should already be identical (the save ran on release),
     and merging means a save that silently failed cannot cost the pair their progress. ]]
local function adopt(plot: Plot, player: any, reclaiming: boolean): ()
	local saved = savedPlotOf(player)
	local state: PlotState = plot.Sanctum.State
	if saved ~= nil then
		state = if reclaiming then StateSchema.mergePlotStates(state, saved) else StateSchema.clonePlotState(saved)
	end
	--[[ COLD START. newPlotState owns nothing, so without this seed a fresh Sanctum earns zero and
	     the first purchase never becomes affordable -- DropperData's balance model documents the one
	     free ember_vent as a contract with this service. Granted only when the pair owns NOTHING at
	     all, so it can never top up a real save. ]]
	if Economy.totalDroppersOwned(state) == 0 then
		local starter = DropperData.get(STARTER_DROPPER) or DropperData.List[1]
		if starter ~= nil then state.Droppers[starter.Id] = 1 end
	end
	plot.Sanctum.State = state
end

local function beginGrace(plot: Plot): ()
	plot.GraceToken += 1
	local token = plot.GraceToken
	task.delay(math.max(0, GameConfig.Plot.ReleaseGraceSeconds), function()
		-- The TOKEN, not the thread, is the cancellation: any claim bumps it, so a plot that was
		-- reclaimed or taken by someone else simply finds a mismatch here and is left alone.
		if plot.GraceToken ~= token or next(plot.Sanctum.Occupants) ~= nil then return end
		plot:Reset()
		owner:MarkDirty(plot.Sanctum)
	end)
end

--[[ Public surface -- every entry point PlotService forwards to. ]]

function PlotSession.bind(service: any, list: { Plot }, profileService: any, linkController: any): ()
	owner, plots, profiles, links = service, list, profileService, linkController
end

-- Teardown for Stop / re-Init. The respawn watches belong to each plot and die with it in Destroy.
function PlotSession.reset(): ()
	table.clear(byUserId)
end

function PlotSession.plotFor(player: any): Plot?
	local userId = userIdOf(player)
	return if userId ~= nil then byUserId[userId] else nil
end

--[[ Picks a plot in a deliberate order: the one this player just left (still inside its grace
     window) first, then a genuinely idle one, and only then one that is counting down for somebody
     else. Stealing a graced plot is safe -- its state was mirrored into every occupant's Profile
     before that timer started -- and it is what stops a busy server turning a player away. ]]
function PlotSession.claim(player: any): Plot?
	local userId = userIdOf(player)
	if userId == nil then return nil end
	local existing = byUserId[userId]
	if existing ~= nil then return existing end -- idempotent: never move a settled player

	local reserved: Plot?, idle: Plot?, graced: Plot? = nil, nil, nil
	for _, plot in ipairs(plots) do
		if next(plot.Sanctum.Occupants) == nil then
			if plot.Reserved[userId] then
				reserved = plot
				break
			elseif next(plot.Reserved) == nil then
				idle = idle or plot
			else
				graced = graced or plot
			end
		end
	end
	local plot = reserved or idle or graced
	if plot == nil then return nil end

	local reclaiming = plot == reserved
	-- A stolen graced plot still holds the previous pair's progress; blank it first so the claimer
	-- never sees, or earns from, a stranger's Wellsprings.
	if not reclaiming then plot:Reset() end
	plot.Reserved = {}
	if addOccupant(plot, player, userId) == nil then return nil end
	adopt(plot, player, reclaiming)
	owner:RebuildSanctum(plot.Sanctum)
	return plot
end

function PlotSession.release(player: any): ()
	local userId = userIdOf(player)
	if userId == nil then return end
	if links ~= nil then links:CancelForPlayer(player) end
	local plot = byUserId[userId]
	if plot == nil then return end
	local occupant = plot.Sanctum.Occupants[userId]
	if occupant == nil then
		byUserId[userId] = nil -- a stale index entry; there is nothing else to unwind
		return
	end
	-- Mirrored BEFORE the occupant is dropped, so the leaver's own Profile carries the shared result
	-- home (§1.5) rather than the state they arrived with.
	mirror(plot)
	removeOccupant(plot, occupant)
	owner.OccupantRemoved:Fire(plot.Sanctum, player)
	-- Income is NOT paused for whoever is left (DECISIONS #6): nothing here touches the runtime.
	if profiles ~= nil then
		for _, other in ipairs(owner:GetOccupants(plot.Sanctum)) do profiles:Save(other) end
	end
	if next(plot.Sanctum.Occupants) == nil then
		if links ~= nil then links:Cancel(plot.Sanctum.Id) end
		beginGrace(plot)
	end
	owner:MarkDirty(plot.Sanctum)
end

--[[ ProfileService saves AND releases on PlayerRemoving, and its own handler is connected first
     (registration order), so ProfileReleasing is the last window in which the leaver's Profile can
     still be given the shared result. Nothing here yields, so it lands before that write. ]]
function PlotSession.flush(player: any, profile: any): ()
	local userId = userIdOf(player)
	local plot = if userId ~= nil then byUserId[userId] else nil
	if plot ~= nil and type(profile) == "table" then
		profile.Plot = StateSchema.clonePlotState(plot.Sanctum.State)
	end
end

function PlotSession.mirrorAll(): ()
	for _, plot in ipairs(plots) do mirror(plot) end
end

function PlotSession.mirrorOne(plot: Plot): ()
	mirror(plot)
end

function PlotSession.requestLink(player: any, plot: Plot): (boolean, string)
	local userId = userIdOf(player)
	if userId == nil then return false, Reason.NoPlayer end
	local current = byUserId[userId]
	if current == plot then return false, Reason.AlreadyHere end
	-- §1.5: one Sanctum at a time. Linking out of an occupied plot would strand the partner in a
	-- state that is about to be merged somewhere else.
	if current ~= nil then return false, Reason.AlreadyLinked end
	local recipients = owner:GetOccupants(plot.Sanctum)
	if #recipients == 0 then return false, Reason.SanctumEmpty end
	if #recipients >= SLOTS then return false, Reason.SanctumFull end
	-- The merge reads the joiner's SAVED PlotState, so an unloaded Profile must not be offered:
	-- accepting one would link them in with nothing of their own and read as data loss.
	if savedPlotOf(player) == nil then return false, Reason.NotLoaded end
	return links:Open(player, plot.Sanctum, recipients)
end

function PlotSession.resolveLink(player: any, plot: Plot, accept: boolean): (boolean, string)
	local userId = userIdOf(player)
	-- Only a CURRENT occupant may answer. The offer was addressed to them, and the opt-in exists
	-- precisely to stop anyone else waving a stranger into their plot.
	if userId == nil or plot.Sanctum.Occupants[userId] == nil then return false, Reason.NoPlayer end
	return links:Resolve(player, plot.Sanctum, accept == true)
end

--[[ Runs up to LinkConfirmSeconds after the request, so EVERY gate is re-checked against live state:
     the joiner may have claimed a plot of their own in the meantime, and the second slot may have
     been taken by an offer that was accepted first. ]]
function PlotSession.linkAccepted(plot: Plot, joiner: any): ()
	local userId = userIdOf(joiner)
	if userId == nil or byUserId[userId] ~= nil or occupantCount(plot) >= SLOTS then return end
	local saved = savedPlotOf(joiner)
	if saved ~= nil then
		--[[ MAX-MERGE (§1.5): per-field max, union of sets, so nobody can lose anything they owned
		     by being sociable. The LIVE state is the left argument, which is what keeps the Affinity
		     the pair has already been playing rather than the joiner's. ]]
		plot.Sanctum.State = StateSchema.mergePlotStates(plot.Sanctum.State, saved)
	end
	if addOccupant(plot, joiner, userId) == nil then return end
	owner:RebuildSanctum(plot.Sanctum)
	mirror(plot) -- the merged state belongs to BOTH of them from this moment on
end

return PlotSession
