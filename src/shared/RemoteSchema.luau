--!strict
--[[
    RemoteSchema
    The wire contract: every RemoteEvent the game owns, declared exactly once so RemoteService (which
    creates them) and ClientBootstrap (which looks them up) can never disagree about a name, a
    direction, a rate limit or a payload shape. Client -> server entries carry a token-bucket budget
    and a total validator; server -> client entries carry neither, because the server is trusted.
    Owner: shared  |  Consumers: RemoteService, RateLimiter, ClientBootstrap, every controller, tests
]]
--[[ WHY THE SURFACE IS THIS SMALL (§1.7). Purchases run through server-listened ProximityPrompts,
     so there is no client -> server message that names an amount, a price or a plot to charge. What
     is left is intent only: a vote, a choice between four literal ids, two booleans and a refresh.
     Every validator below is TOTAL -- it returns false instead of erroring on any input, including
     userdata and tables with hostile metatables -- because an error thrown inside a remote handler
     is a free denial of service. Every validator also REJECTS EXTRA KEYS: a payload padded with
     junk is an attempt to smuggle a field past a future handler that reads it. ]]

local Validate = require(script.Parent.Validate)
local GameConfig = require(script.Parent.GameConfig)
local AffinityData = require(script.Parent.AffinityData)

export type RemoteDef = {
	Name: string,
	Direction: "ServerToClient" | "ClientToServer",
	RateLimit: { Tokens: number, Interval: number }?, -- ClientToServer only
	Validate: ((payload: any) -> (boolean, string?))?, -- ClientToServer only
}

local RemoteSchema = {}
RemoteSchema.FolderName = "SanctumRemotes"

local S2C: "ServerToClient" = "ServerToClient"
local C2S: "ClientToServer" = "ClientToServer"

-- Wraps a checker so it can never throw: a metatable whose __index errors, a userdata payload or a
-- deeply nested table all collapse to a clean rejection instead of unwinding the handler.
local function total(check: (payload: any) -> (boolean, string?)): (payload: any) -> (boolean, string?)
	return function(payload: any): (boolean, string?)
		local ok, accepted, reason = pcall(check, payload)
		if not ok then
			return false, "validator error"
		end
		if accepted == true then
			return true, nil
		end
		return false, if type(reason) == "string" then reason else "rejected"
	end
end

-- Shape first (exact fields, exact kinds, no extras), then any value-level rule.
local function shaped(shape: { [string]: string }, extra: ((payload: any) -> (boolean, string?))?)
	return total(function(payload: any): (boolean, string?)
		local ok, reason = Validate.payload(payload, shape)
		if not ok then
			return false, reason
		end
		if extra ~= nil then
			return extra(payload)
		end
		return true, nil
	end)
end

-- Plot ids are indices into the server's sanctum array. Bounding them here means a forged id can
-- never reach a table lookup, and a float ("PlotId = 1.5") can never alias slot 1.
local function isPlotId(value: any): boolean
	return type(value) == "number"
		and value == value
		and value % 1 == 0
		and value >= 1
		and value <= GameConfig.Plot.SanctumCount
end

RemoteSchema.Remotes = {
	--[[ Server -> client. No RateLimit and no Validate: these are produced by trusted code, and a
	     validator on this side would only cost CPU on the hot replication path. ]]
	StateSync = { Name = "StateSync", Direction = S2C }, -- §7 snapshot; the highest-frequency remote
	Notify = { Name = "Notify", Direction = S2C }, -- { Kind = "info"|"success"|"warn"|"error", Text }
	Fx = { Name = "Fx", Direction = S2C }, -- { Kind = "attune"|"transcend"|"purchase"|"link", PlotId, Data? }
	LinkOffer = { Name = "LinkOffer", Direction = S2C }, -- { PlotId, FromUserId, FromName, ExpiresAt }
	RebirthVoteState = { Name = "RebirthVoteState", Direction = S2C }, -- { PlotId, Votes, ExpiresAt, Names }

	--[[ Client -> server. Budgets are sized at "a human mashing the button", not "a script": each
	     one is a few times the fastest honest rate, so a real player never notices and a spammer is
	     throttled before the handler runs. ]]

	-- A resync button and the reconnect path both fire this; 4 per 5s absorbs an impatient
	-- double-tap while capping the cost of forcing a full snapshot rebuild.
	RequestSnapshot = {
		Name = "RequestSnapshot",
		Direction = C2S,
		RateLimit = { Tokens = 4, Interval = 5 },
		-- an empty shape accepts only nil or {}; anything carried here is an attempt to smuggle
		-- arguments into a handler that takes none
		Validate = shaped({}),
	},

	-- The consensus vote (§1.8). Accept is the WHOLE payload: the sanctum is derived from the
	-- player's occupancy server-side, so nobody can vote in someone else's transcendence.
	RebirthVote = {
		Name = "RebirthVote",
		Direction = C2S,
		RateLimit = { Tokens = 5, Interval = 10 },
		Validate = shaped({ Accept = "boolean" }),
	},

	-- Permanent for the run, so it is checked against the catalogue rather than a pattern: only the
	-- four literal ids are accepted, and "id" already bounds length and character set.
	ChooseAffinity = {
		Name = "ChooseAffinity",
		Direction = C2S,
		RateLimit = { Tokens = 4, Interval = 10 },
		Validate = shaped({ Affinity = "id" }, function(payload: any): (boolean, string?)
			if not AffinityData.isValid((payload :: any).Affinity) then
				return false, "unknown affinity"
			end
			return true, nil
		end),
	},

	-- Cosmetic, but still validated: Key is a closed set because it is used to index the saved
	-- Settings table, and an arbitrary string there would write a field the sanitiser then drops.
	SetSetting = {
		Name = "SetSetting",
		Direction = C2S,
		RateLimit = { Tokens = 10, Interval = 10 },
		Validate = shaped({ Key = "string", Value = "boolean" }, function(payload: any): (boolean, string?)
			local key = (payload :: any).Key
			if key ~= "Music" and key ~= "Sfx" then
				return false, "unknown setting"
			end
			return true, nil
		end),
	},

	-- Answer to a LinkOffer. PlotId is bounded so a decline for a sanctum the player was never
	-- offered cannot index past the array; the server still re-checks that an offer is pending.
	LinkResponse = {
		Name = "LinkResponse",
		Direction = C2S,
		RateLimit = { Tokens = 5, Interval = 10 },
		Validate = shaped({ PlotId = "number", Accept = "boolean" }, function(payload: any): (boolean, string?)
			if not isPlotId((payload :: any).PlotId) then
				return false, "plot id out of range"
			end
			return true, nil
		end),
	},

	-- Destructive and irreversible, so it is the tightest budget in the game and is refused outright
	-- unless the build opted in. Confirm must be literally true: a truthy 1 or "yes" is rejected, so
	-- a mistyped client cannot wipe a profile.
	ResetData = {
		Name = "ResetData",
		Direction = C2S,
		RateLimit = { Tokens = 1, Interval = 30 },
		Validate = shaped({ Confirm = "boolean" }, function(payload: any): (boolean, string?)
			if GameConfig.Debug.AllowDataReset ~= true then
				return false, "data reset disabled"
			end
			if (payload :: any).Confirm ~= true then
				return false, "confirmation required"
			end
			return true, nil
		end),
	},
} :: { [string]: RemoteDef }

-- Deterministic creation order for RemoteService (and for the specs): server -> client first, so a
-- client that is already listening cannot miss an early push while the C2S events are still being
-- created, then alphabetical inside each direction.
RemoteSchema.List = {} :: { RemoteDef }
for _, def in pairs(RemoteSchema.Remotes) do
	table.insert(RemoteSchema.List, def)
end
table.sort(RemoteSchema.List, function(a: RemoteDef, b: RemoteDef): boolean
	if a.Direction ~= b.Direction then
		return a.Direction == S2C
	end
	return a.Name < b.Name
end)

function RemoteSchema.get(name: string): RemoteDef?
	-- typed guard: `Remotes[name]` with a non-string would be a silent nil, and callers use the nil
	-- as "this remote does not exist" -- which is exactly what an unknown name should look like
	if type(name) ~= "string" then
		return nil
	end
	return RemoteSchema.Remotes[name]
end

return RemoteSchema
