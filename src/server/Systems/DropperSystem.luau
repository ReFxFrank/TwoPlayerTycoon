--!strict
--[[
	DropperSystem
	The emit clock of one Sanctum. It keeps an independent accumulator per OWNED COPY of a Wellspring
	-- three Ember Vents are three staggered streams, not one stream emitting three Motes at once --
	re-reads each stream's interval from Economy on every Step so an upgrade or Attunement lands on
	the very next frame, and bounds catch-up so a laggy Step cannot avalanche. It builds no Instances
	and knows nothing about Motes: it announces OnSpawn(def, index) and PlotService decides what that
	means.
	Owner: server/Systems  |  Consumers: PlotService (owns one per Sanctum, drives it from the one
	                                     shared Heartbeat loop)
]]

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local Signal = require(Modules:WaitForChild("Signal"))
local Economy = require(Modules:WaitForChild("Economy"))
local DropperData = require(Modules:WaitForChild("DropperData"))

type Dropper = DropperData.Dropper

-- Structural and deliberately loose. PlotService owns the real Sanctum type and requires THIS
-- module, so naming its type here would be a require cycle; only `State` is ever read, which also
-- lets the headless harness drive a Step with a plain table.
type Sanctum = { State: any }

type Stream = {
	Def: Dropper,
	Index: number, -- 1..owned: WHICH copy of this Wellspring, passed straight to OnSpawn
	Key: string, -- "<id>#<index>": the identity whose accumulator phase Rebuild preserves
	Elapsed: number, -- seconds banked toward the current interval
}

-- CATCH-UP BOUND. A Step arriving with a huge dt (a server hitch, a resumed Studio breakpoint, a
-- test calling Step(60)) must not emit one Mote per elapsed interval: at Economy's 0.15s floor that
-- is 400 spawns for ONE Wellspring inside ONE frame, each allocating a part -- the hitch would
-- become a freeze, which is exactly the failure this bound exists to prevent. Four is sized off the
-- production cadence (GameConfig.Income.TickRate = 10, so dt = 0.1): it absorbs a 0.6s stall at the
-- fastest legal interval and never fires in normal play.
local MAX_CATCHUP_PER_STEP = 4

-- Economy.getDropperInterval ignores its Multipliers argument BY DESIGN (prestige and Stage scale a
-- Mote's value, not the cadence -- scaling both would compound one bonus twice), but the signature
-- demands one. This neutral table keeps the seeding call honest without inventing a bonus.
local NEUTRAL: Economy.Multipliers = { Prestige = 1, Stage = 1, Affinity = 1, Upgrades = 1, Debug = 1 }

-- R2 low-discrepancy constants (1/g and 1/g^2 for the plastic number). Successive ordinals land far
-- apart in [0,1), so a freshly bought third Ember Vent syncs neither with the first two nor with a
-- Dew Font that happens to share its interval. Deterministic -- no Random -- so mote tests reproduce.
local PHASE_PER_DROPPER = 0.7548776662466927
local PHASE_PER_COPY = 0.5698402909980532

-- NaN is the reason this is not a plain `or`: every comparison against NaN is false, so an unguarded
-- clamp silently passes it through and one poisoned accumulator never emits again.
local function num(v: any, default: number): number
	return if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then v else default
end

local DropperSystem = {}

local DropperRuntime = {}
DropperRuntime.__index = DropperRuntime

type DropperRuntimeSelf = {
	OnSpawn: Signal.Signal, -- (dropperDef: Dropper, index: number)
	_sanctum: Sanctum,
	_streams: { Stream }, -- iteration order for Step
	_byKey: { [string]: Stream }, -- phase-preservation index for Rebuild
	_destroyed: boolean,
}
type DropperRuntime = typeof(setmetatable({} :: DropperRuntimeSelf, DropperRuntime))

-- Owned count for one catalogue entry, hardened against a corrupt save: non-numbers, NaN, negatives
-- and fractions collapse to a whole number, and MaxOwned caps it so `Droppers.ember_vent = 1e9`
-- allocates 25 streams rather than a billion.
local function ownedCount(raw: any, def: Dropper): number
	local max = math.max(0, math.floor(num(def.MaxOwned, 0)))
	return math.clamp(math.floor(num(raw, 0)), 0, max)
end

-- Starting phase for a brand new stream, in seconds. Offsetting by the R2 fraction of the interval
-- is what stops a pair who just bought three Wellsprings from watching all three fire in lockstep
-- forever after.
local function initialElapsed(sanctum: Sanctum, def: Dropper, index: number): number
	local interval = Economy.getDropperInterval(def, sanctum.State, NEUTRAL)
	local order = num(def.Order, 1)
	local fraction = ((order - 1) * PHASE_PER_DROPPER + (index - 1) * PHASE_PER_COPY) % 1
	return interval * fraction
end

function DropperSystem.new(sanctum: Sanctum): DropperRuntime
	local self: DropperRuntime = setmetatable({
		OnSpawn = Signal.new(),
		_sanctum = sanctum,
		_streams = {},
		_byKey = {},
		_destroyed = false,
	}, DropperRuntime)
	-- A Sanctum loaded from a save already owns Wellsprings; without this it would sit silent until
	-- the first purchase happened to call Rebuild.
	self:Rebuild()
	return self
end

-- Re-derives the stream set from PlotState. Called after every purchase, Attunement and Transcendence.
function DropperRuntime.Rebuild(self: DropperRuntime): ()
	-- PlotService can release a Sanctum in the same frame a purchase queued a rebuild.
	if self._destroyed then
		return
	end
	local state = self._sanctum.State
	local owned = if type(state) == "table" then (state :: any).Droppers else nil
	local ownedMap: { [string]: any } = if type(owned) == "table" then owned else {}

	local streams: { Stream } = {}
	local byKey: { [string]: Stream } = {}
	-- Iterate the CATALOGUE, never the save. That is Economy's doctrine applied to the emit clock:
	-- an id injected into a tampered profile ("i_win" = 99) can never create a stream at all.
	for _, def in ipairs(DropperData.List) do
		local count = ownedCount(ownedMap[def.Id], def)
		for index = 1, count do
			local key = def.Id .. "#" .. index
			local stream = self._byKey[key]
			if stream == nil then
				-- Only genuinely NEW copies start fresh.
				stream = {
					Def = def,
					Index = index,
					Key = key,
					Elapsed = initialElapsed(self._sanctum, def, index),
				}
			else
				-- Reusing the table preserves Elapsed. Without that, every purchase would reset the
				-- timer of every Wellspring the pair already owned, so a fast-clicking player could
				-- starve their own income by never letting a stream reach its interval.
				stream.Def = def
			end
			streams[#streams + 1] = stream
			byKey[key] = stream
		end
	end
	self._streams = streams
	-- Streams for copies that are gone (a Transcendence reset) simply fall out of the new index.
	self._byKey = byKey
end

function DropperRuntime.Step(self: DropperRuntime, dt: number, multipliers: Economy.Multipliers): ()
	if self._destroyed then
		return
	end
	local step = num(dt, 0)
	-- A non-positive or non-finite dt (a clock that stepped backwards, a NaN out of a division)
	-- would either do nothing or poison every accumulator permanently. Drop the frame instead.
	if step <= 0 then
		return
	end
	local state = self._sanctum.State
	local m: Economy.Multipliers = if type(multipliers) == "table" then multipliers else NEUTRAL

	for _, stream in ipairs(self._streams) do
		-- Re-read every Step, never cached: a SpawnRate upgrade or an Affinity choice must change
		-- the cadence on the next frame, not at the next Rebuild. Economy floors this at 0.15, so it
		-- is always a safe divisor and a safe modulus below.
		local interval = Economy.getDropperInterval(stream.Def, state, m)
		local elapsed = stream.Elapsed + step
		local emitted = 0
		while elapsed >= interval and emitted < MAX_CATCHUP_PER_STEP do
			elapsed -= interval
			emitted += 1
			self.OnSpawn:Fire(stream.Def, stream.Index)
		end
		-- Backlog past the bound is DISCARDED, not banked. Carrying it would pin every Wellspring at
		-- the catch-up cap for minutes after a single hitch, turning one stutter into a lasting lag
		-- tax; the modulus keeps the sub-interval phase so the stream stays staggered. In the normal
		-- path (elapsed already < interval) this is a no-op.
		stream.Elapsed = elapsed % interval
	end
end

-- Live stream count -- one per owned copy. Exposed for PlotService diagnostics and the timing tests;
-- it is a read-only view, not part of the emit contract.
function DropperRuntime.StreamCount(self: DropperRuntime): number
	return #self._streams
end

function DropperRuntime.Destroy(self: DropperRuntime): ()
	self._destroyed = true
	-- Cleared before the signal dies so a Step already part-way through a release cannot resurrect
	-- work against a Sanctum whose State has been handed back.
	table.clear(self._streams)
	table.clear(self._byKey)
	self.OnSpawn:Destroy()
end

return DropperSystem
