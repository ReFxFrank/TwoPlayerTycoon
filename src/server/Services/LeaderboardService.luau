--!strict
--[[
	LeaderboardService
	Owns the `leaderstats` folder Roblox reads to draw the in-game player list: Essence (the floor of
	the Sanctum's SHARED wallet, so both occupants show the same figure), Rebirths (per player, from
	their Profile's Prestige) and Contributed (that occupant's session share of what the pair earned).
	It only ever READS -- no gate, no purchase and no save depends on anything here, so a stale or
	missing leaderstat is a cosmetic bug and never a gameplay one.
	Kept in sync from PlotService's signals (throttled: SanctumChanged fires on every income tick) and
	a slow sweep that catches anything no signal announced.
	Owner: server/Services  |  Consumers: Bootstrap (registration), the Roblox player list
]]

local Players = game:GetService("Players")

-- Spec section 3.1: a connection is anything with :Disconnect(). Structural, so this behaves the
-- same under Roblox's RBXScriptConnection and under the headless mock.
type Connection = { Disconnect: (self: any) -> () }
type Entry = { Folder: any, Essence: any, Rebirths: any, Contributed: any }

local FOLDER_NAME = "leaderstats" -- the exact name Roblox looks for; anything else shows nothing
local STAT_NAMES = { "Essence", "Rebirths", "Contributed" } -- display order in the player list

--[[ THE CLAMP THAT MUST NOT BE REMOVED. An IntValue is a SIGNED 32-BIT integer: assigning
     2147483648 does not error and does not saturate -- it WRAPS, and the player list shows a large
     NEGATIVE balance. This is not a theoretical edge. StateSchema caps a wallet at MAX_CURRENCY =
     1e15, six orders of magnitude past 2^31-1, and the late-game income curve reaches nine figures
     long before Stage 6, so a real session WILL cross it. Clamping shows a pinned 2,147,483,647
     instead: wrong, but monotonically wrong in the direction a player expects, and the HUD (which
     reads the snapshot, not this) still shows the true figure.
     A NumberValue would hold the real number, but Roblox renders leaderstats through the IntValue
     path players recognise, and spec section 6 names IntValue. ]]
local INT32_MAX = 2147483647
local INT32_MIN = -2147483648

--[[ Cadences. SIGNAL_INTERVAL throttles the signal-driven refresh because PlotService coalesces
     SanctumChanged to once per INCOME tick -- ten times a second per Sanctum -- and an IntValue
     write replicates to every client in the server. SWEEP_SECONDS is the backstop for the values no
     signal covers (a rebirth granted while the plot sat still, a contribution that moved without a
     state change), so the board can be at most this stale, never permanently wrong. ]]
local SIGNAL_INTERVAL = 0.5
local SWEEP_SECONDS = 5

local Service = {}
Service.Name = "LeaderboardService"

local plots: any, profiles: any = nil, nil
local connections: { Connection } = {}
local entries: { [any]: Entry } = {}
local running, generation = false, 0

--[[ Sanctum -> os.clock() of its last signal-driven refresh. WEAK KEYS: PlotService rebuilds its
     Sanctums on a re-Init, and a strong key would pin every discarded one alive for the life of the
     server. ]]
local function newThrottle(): { [any]: number }
	return (setmetatable({}, { __mode = "k" }) :: any) :: { [any]: number }
end
local lastRefresh: { [any]: number } = newThrottle()

-- `Parent ~= Players` is the O(1) "still in the server" test (engine and mock both unparent on
-- PlayerRemoving). The typeof/IsA pair in front makes it total, since a signal can hand this a
-- plain table from the harness or a nil from a half-released Sanctum.
local function isLivePlayer(player: any): boolean
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players
end

-- pcall'd: a Player is userdata, and reading a field off one who has already left can throw.
local function userIdOf(player: any): number?
	if player == nil then return nil end
	local ok, id = pcall(function(): any return (player :: any).UserId end)
	return if ok and type(id) == "number" and id == id then id else nil
end

-- Every value written to an IntValue passes through here. NaN is tested FIRST: every comparison
-- against it is false, so math.clamp would pass it straight through to the wrapping assignment.
local function toInt32(value: any): number
	if type(value) ~= "number" or value ~= value then
		return 0
	end
	-- math.floor(inf) is still inf, which clamp then pins to the ceiling -- deliberate, and the
	-- reason the floor happens before the clamp rather than after.
	return math.clamp(math.floor(value), INT32_MIN, INT32_MAX)
end

-- Written only when it actually changes: an IntValue assignment replicates to every client in the
-- server, and the sweep alone would otherwise send three unchanged numbers per player per cycle.
local function assign(target: any, value: any): ()
	local clamped = toInt32(value)
	if target ~= nil and target.Value ~= clamped then
		target.Value = clamped
	end
end

--[[ `parent`'s IntValue of this name, created only if absent. A wrong-class squatter is destroyed:
     leaving, say, a StringValue named "Essence" in place would make that column render as text and
     every later assign would throw. ]]
local function ensureValue(parent: any, name: string): any
	local existing = parent:FindFirstChild(name)
	if existing ~= nil then
		if existing:IsA("IntValue") then
			return existing
		end
		existing:Destroy()
	end
	local created = Instance.new("IntValue")
	created.Name = name
	created.Value = 0
	created.Parent = parent
	return created
end

--[[ The player's leaderstats, built on first use. Idempotent by design -- it is called from four
     signals and the sweep, and any of them can be the first to reach a given player. ]]
local function ensureStats(player: any): Entry?
	if not isLivePlayer(player) then
		-- A folder parented to a departed Player is never seen by anyone and would keep the Player
		-- (and its character) referenced by our entry table.
		return nil
	end
	local cached = entries[player]
	if cached ~= nil and cached.Folder.Parent == player then
		return cached
	end
	local folder = player:FindFirstChild(FOLDER_NAME)
	if folder ~= nil and not folder:IsA("Folder") then
		folder:Destroy() -- Roblox reads only a Folder here; anything else silently shows no stats
		folder = nil
	end
	if folder == nil then
		folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME
	end
	local entry: Entry = {
		Folder = folder,
		Essence = ensureValue(folder, STAT_NAMES[1]),
		Rebirths = ensureValue(folder, STAT_NAMES[2]),
		Contributed = ensureValue(folder, STAT_NAMES[3]),
	}
	-- Parented LAST, so the player list can only ever see a folder that already has all three
	-- columns in it rather than popping them in one at a time.
	folder.Parent = player
	entries[player] = entry
	return entry
end

--[[ Public API ]]

--[[ Re-reads one player's three numbers from live state. Total: a player with no Sanctum shows
     zeroes rather than the last plot they were in, which is the honest reading while they are
     between plots (their real progress is in their Profile, not on the board). ]]
function Service:Refresh(player: any): ()
	local entry = ensureStats(player)
	if entry == nil then
		return
	end
	local essence, contributed = 0, 0
	local sanctum = if plots ~= nil then plots:GetSanctumForPlayer(player) else nil
	if type(sanctum) == "table" then
		local state = (sanctum :: { [string]: any }).State
		if type(state) == "table" then
			essence = (state :: { [string]: any }).Essence
		end
		-- Occupants is keyed by UserId; read structurally so a half-released Sanctum (an entry
		-- nil-ed mid-removal) is simply "no contribution" instead of an error.
		local occupants = (sanctum :: { [string]: any }).Occupants
		local userId = userIdOf(player)
		local occupant = if type(occupants) == "table" and userId ~= nil then occupants[userId] else nil
		if type(occupant) == "table" then
			contributed = (occupant :: { [string]: any }).Contribution
		end
	end
	-- Prestige is per player and NEVER merged (§1.5), so it comes from the Profile, not the Sanctum.
	local profile = if profiles ~= nil then profiles:Get(player) else nil
	local prestige = if type(profile) == "table" then (profile :: { [string]: any }).Prestige else nil
	local rebirths = if type(prestige) == "table" then (prestige :: { [string]: any }).Rebirths else 0

	assign(entry.Essence, essence)
	assign(entry.Rebirths, rebirths)
	assign(entry.Contributed, contributed)
end

-- Every occupant of one Sanctum. `force` skips the throttle, for the structural signals (someone
-- joined or left) where a half-second-late board would be visibly wrong.
function Service:RefreshSanctum(sanctum: any, force: boolean?): ()
	if plots == nil or type(sanctum) ~= "table" then
		return
	end
	if force ~= true then
		local last = lastRefresh[sanctum]
		-- os.clock is monotonic: a wall-clock correction cannot stall this throttle or open it early.
		if last ~= nil and os.clock() - last < SIGNAL_INTERVAL then
			return
		end
	end
	lastRefresh[sanctum] = os.clock()
	for _, player in ipairs(plots:GetOccupants(sanctum)) do
		Service:Refresh(player)
	end
end

function Service:RefreshAll(): ()
	for _, player in ipairs(Players:GetPlayers()) do
		--[[ pcall'd per player: this runs on a timer nothing supervises, so one player in a strange
		     state (mid-release, character gone) must not stop the others being updated -- and an
		     error escaping here would kill the sweep thread for the rest of the server's life. ]]
		local ok, err = pcall(Service.Refresh, Service, player)
		if not ok then
			warn(("[LeaderboardService] refresh failed: %s"):format(tostring(err)))
		end
	end
end

--[[ ServiceRegistry contract ]]

function Service:Init(registry: any): ()
	-- Resolved only: section 6 forbids cross-service calls during Init. Both are registered before
	-- this service, so a missing one is a Bootstrap bug worth erroring on.
	plots = registry:Get("PlotService")
	profiles = registry:Get("ProfileService")
	-- A re-Init must not inherit the previous boot's connections or entries: the connections would
	-- keep firing into a discarded table, and the entries would point at Players from a dead run.
	Service:Stop()
	entries = {}
	lastRefresh = newThrottle()
end

function Service:Start(): ()
	running = true
	--[[ The board exists from the moment the player joins, before their Profile has loaded: an empty
	     row reads as "loading", whereas no row at all reads as a broken game. ]]
	table.insert(connections, Players.PlayerAdded:Connect(function(player: Player)
		ensureStats(player)
	end))
	--[[ Without this, `entries` keeps one Entry per departed player forever -- and because a Player
	     instance is a strong key, each leaked entry also pins that Player and its character. The
	     folder itself needs no cleanup: it is a child of the Player and leaves with them. ]]
	table.insert(connections, Players.PlayerRemoving:Connect(function(player: Player)
		entries[player] = nil
	end))
	-- Rebirths is only knowable once the Profile is in memory.
	table.insert(connections, profiles.ProfileLoaded:Connect(function(player: Player)
		Service:Refresh(player)
	end))
	--[[ Occupancy changed, so BOTH occupants' rows are wrong at once: the newcomer's Essence column
	     has to switch to the shared wallet, and the partner's contribution share changes with them.
	     Forced past the throttle -- this is the one moment a stale board is obvious. ]]
	table.insert(connections, plots.OccupantAdded:Connect(function(sanctum: any, player: Player)
		Service:Refresh(player)
		Service:RefreshSanctum(sanctum, true)
	end))
	table.insert(connections, plots.OccupantRemoved:Connect(function(sanctum: any, player: Player)
		Service:Refresh(player) -- they have no Sanctum now, so their row zeroes out
		Service:RefreshSanctum(sanctum, true)
	end))
	-- The income signal. Throttled: PlotService coalesces it to once per income tick, which is ten
	-- times a second per Sanctum.
	table.insert(connections, plots.SanctumChanged:Connect(function(sanctum: any)
		Service:RefreshSanctum(sanctum, false)
	end))

	--[[ The slow sweep. A generation token, not just `running`, is what stops a Stop/Start cycle (or
	     a re-Init in the harness) leaving two loops writing to the same IntValues at twice the rate:
	     the older thread finds a changed generation at its next wake and exits. ]]
	generation += 1
	local mine = generation
	task.spawn(function()
		while running and generation == mine do
			task.wait(SWEEP_SECONDS)
			-- Re-checked after the park: the service may have stopped while this thread slept.
			if not running or generation ~= mine then
				break
			end
			Service:RefreshAll()
		end
	end)
end

function Service:Stop(): ()
	running = false -- the sweep thread exits at its next wake
	generation += 1
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
	-- The leaderstats folders are deliberately LEFT STANDING: they belong to the Players, and
	-- destroying them on a soft restart would blank every player's row for no reason.
end

return Service
