--!strict
--[[
	MoteSystem
	The flight pool of one Sanctum. Every Mote is an ANCHORED part walked along a precomputed Ley
	Rail polyline by CFrame -- no physics body, no Touched connection (spec decision 8) -- and is
	collected the moment its ARC-LENGTH progress reaches 1. It owns the live-Mote cap, the Debris
	leak backstop and the orphan sweep. It never touches the wallet: it announces OnCollected(value,
	def) and EconomyService decides what the Essence is worth.
	Owner: server/Systems  |  Consumers: PlotService (owns one per Sanctum, drives it from the one
	                                     shared Heartbeat loop)
]]

local Debris = game:GetService("Debris")

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local Signal = require(Modules:WaitForChild("Signal"))
local Economy = require(Modules:WaitForChild("Economy"))
local GameConfig = require(Modules:WaitForChild("GameConfig"))
local DropperData = require(Modules:WaitForChild("DropperData"))

type Dropper = DropperData.Dropper

-- Structural and deliberately loose: PlotService owns the real Sanctum type and requires THIS
-- module, so naming its type here would be a require cycle. Only State (for the cap) and
-- Runtime.MoteFolder (for parenting) are ever read, which also lets the harness drive a plain table.
type Sanctum = { State: any, Runtime: any }

-- The part handle stays `any` so this module loads unchanged under the headless harness, whose
-- Instances are tables rather than userdata.
type MotePart = any

type Mote = {
	Part: MotePart,
	Def: Dropper,
	Value: number, -- Essence this Mote is worth when it lands; already fully multiplied
	Progress: number, -- 0..1 across the WHOLE polyline
	Travel: number, -- seconds for the full flight; the divisor progress advances by
	Path: { CFrame }, -- borrowed by reference and NEVER mutated, so callers may cache one per pad
	Marks: { number }, -- cumulative arc length at each waypoint; Marks[1] = 0
	Length: number, -- Marks[#Marks]
	Cursor: number, -- segment the Mote is currently on; monotonic, so lookup is O(1) amortised
}

local MIN_TRAVEL = 0.05 -- divisor floor: dt / 0 is inf progress, which skips the flight entirely
local MAX_TRAVEL = 3600 -- a Mote that would fly for an hour is a leak, not a Mote

local function num(v: any, default: number): number
	return if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then v else default
end

-- Cumulative arc length, computed ONCE per Spawn. Interpolating by waypoint INDEX instead would make
-- a 4-stud hop off the nozzle and a 90-stud trunk run take exactly as long as each other, so a Mote
-- would crawl across the short segments and teleport across the long one.
local function measure(path: { CFrame }): ({ number }, number)
	local marks = table.create(#path)
	marks[1] = 0
	local total = 0
	for i = 2, #path do
		local delta = (path[i].Position - path[i - 1].Position).Magnitude
		-- A NaN or inf waypoint would poison every later mark and freeze the Mote on the pad; treat
		-- that segment as a zero-length hop instead so the rest of the rail still measures.
		total += num(delta, 0)
		marks[i] = total
	end
	return marks, total
end

-- World CFrame for the Mote's current progress, interpolated by DISTANCE along the polyline.
local function poseOf(mote: Mote): CFrame
	local path, marks = mote.Path, mote.Marks
	local last = #path
	if mote.Length <= 0 then
		-- Degenerate rail (every waypoint identical, or all lengths rejected above): there is no
		-- distance to divide by, so walk the waypoints uniformly rather than dividing by zero.
		local slot = math.clamp(1 + mote.Progress * (last - 1), 1, last)
		local index = math.min(math.floor(slot), last - 1)
		return path[index]:Lerp(path[index + 1], slot - index)
	end
	local target = mote.Progress * mote.Length
	-- Progress only ever increases, so the cursor only ever moves forward: this scan costs O(1)
	-- amortised over the whole flight instead of an O(waypoints) search on every tick of every Mote.
	local cursor = mote.Cursor
	while cursor < last - 1 and marks[cursor + 1] < target do
		cursor += 1
	end
	mote.Cursor = cursor
	local span = marks[cursor + 1] - marks[cursor]
	local alpha = if span > 0 then (target - marks[cursor]) / span else 0
	return path[cursor]:Lerp(path[cursor + 1], math.clamp(alpha, 0, 1))
end

-- Resolved per Spawn, never cached at construction: PlotService rebuilds the Sanctum model on
-- Transcendence, and a cached folder would parent every later Mote into a destroyed tree where the
-- orphan sweep would silently eat it.
local function moteFolder(sanctum: Sanctum): MotePart?
	local runtime = sanctum.Runtime
	if runtime == nil then
		return nil
	end
	return (runtime :: any).MoteFolder
end

local MoteSystem = {}

local MoteRuntime = {}
MoteRuntime.__index = MoteRuntime

type MoteRuntimeSelf = {
	OnCollected: Signal.Signal, -- (value: number, dropperDef: Dropper)
	_sanctum: Sanctum,
	_motes: { Mote },
	_destroyed: boolean,
}
type MoteRuntime = typeof(setmetatable({} :: MoteRuntimeSelf, MoteRuntime))

function MoteSystem.new(sanctum: Sanctum): MoteRuntime
	return setmetatable({
		OnCollected = Signal.new(),
		_sanctum = sanctum,
		_motes = {},
		_destroyed = false,
	}, MoteRuntime)
end

function MoteRuntime.Count(self: MoteRuntime): number
	return #self._motes
end

-- Builds the visual. Split out only so Spawn stays readable; every property here is set because its
-- default is wrong for a Mote, not for decoration.
local function buildPart(def: Dropper, pose: CFrame, folder: MotePart): MotePart
	local part = Instance.new("Part")
	part.Name = "Mote"
	part.Anchored = true -- decision 8: CFrame-driven, never handed to the physics solver
	part.CanCollide = false -- a Mote must never shove a player off their own rail
	part.CanTouch = false -- there is no Touched listener anywhere; this drops the touch bookkeeping
	part.CanQuery = false -- and keeps 60 parts per Sanctum out of every raycast
	part.CastShadow = false -- 60 shadow casters per Sanctum for a 1.4-stud bauble is pure cost
	part.Size = if typeof(GameConfig.Mote.Size) == "Vector3" then GameConfig.Mote.Size else Vector3.new(1.4, 1.4, 1.4)
	part.Shape = Enum.PartType.Ball
	-- Guarded: a def edited badly in a live patch would otherwise throw INSIDE the spawn loop, and
	-- one bad catalogue entry would stop every Sanctum on the server from earning.
	if typeof(def.Color) == "Color3" then
		part.Color = def.Color
	end
	if typeof(def.Material) == "EnumItem" then
		part.Material = def.Material
	end
	part.CFrame = pose
	part.Parent = folder
	-- Leak backstop. Every path out of Step destroys its own part, so this only ever fires for a Mote
	-- the server somehow stopped stepping -- which is precisely the case that would otherwise leak.
	Debris:AddItem(part, math.max(1, num(GameConfig.Mote.LifetimeSeconds, 30)))
	return part
end

function MoteRuntime.Spawn(
	self: MoteRuntime,
	dropperDef: Dropper,
	value: number,
	path: { CFrame },
	travelTime: number
): boolean
	-- A released Sanctum has no wallet left to credit, so this drops the Mote outright rather than
	-- firing OnCollected at a listener PlotService has already torn down.
	if self._destroyed then
		return false
	end
	local worth = num(value, 0)
	-- Non-finite or non-positive value means a bug upstream (a corrupt def, a NaN multiplier). It is
	-- NOT credited: an inf written into the shared wallet is unrecoverable, and a 0 is just noise.
	if worth <= 0 then
		return false
	end
	-- Malformed rail. Also not credited -- unlike the cap below, this is a PlotLayout/PlotBuilder bug,
	-- and paying for it would hide it behind income that still looks correct.
	if type(path) ~= "table" or #path < 2 then
		return false
	end
	for index = 1, #path do
		if typeof(path[index]) ~= "CFrame" then
			return false
		end
	end

	-- OVERFLOW. Income is NEVER lost to the cap (decision 8): the value is credited immediately and
	-- only the VISUAL is dropped, so a pair who let Motes pile up lose feedback, never Essence. The
	-- false return tells the caller no part exists to track.
	if #self._motes >= Economy.getMoteCapacity(self._sanctum.State) then
		self.OnCollected:Fire(worth, dropperDef)
		return false
	end
	local folder = moteFolder(self._sanctum)
	if folder == nil then
		-- Same rule as the cap: a Sanctum whose Runtime has no MoteFolder (a builder that has not
		-- finished yet) can render nothing, but it must not silently swallow the Essence either.
		self.OnCollected:Fire(worth, dropperDef)
		return false
	end

	local travel = math.clamp(num(travelTime, num(GameConfig.Mote.BaseTravelSeconds, 6)), MIN_TRAVEL, MAX_TRAVEL)
	local marks, length = measure(path)
	local part = buildPart(dropperDef, path[1], folder)
	self._motes[#self._motes + 1] = {
		Part = part,
		Def = dropperDef,
		Value = worth,
		Progress = 0,
		Travel = travel,
		Path = path,
		Marks = marks,
		Length = length,
		Cursor = 1,
	}
	return true
end

function MoteRuntime.Step(self: MoteRuntime, dt: number): ()
	if self._destroyed then
		return
	end
	local step = num(dt, 0)
	-- A non-positive or non-finite dt would either do nothing or set every Progress to NaN, after
	-- which `Progress >= 1` is false forever and no Mote is ever collected again.
	if step <= 0 then
		return
	end
	local motes = self._motes
	-- Backwards, because finished Motes are removed in place and a forward loop would skip whichever
	-- element slid down into the freed slot.
	for index = #motes, 1, -1 do
		local mote = motes[index]
		local part = mote.Part
		if part.Parent == nil then
			-- Destroyed out from under us: the Debris backstop fired, or the whole Sanctum model was
			-- torn down. Dropped WITHOUT crediting -- crediting here is how one Mote gets paid for
			-- twice (once on the sweep, once when it lands) or paid for having never landed at all.
			table.remove(motes, index)
		else
			mote.Progress += step / mote.Travel
			if mote.Progress >= 1 then
				-- Removed BEFORE the signal so a handler reading Count() (or spawning a replacement
				-- Mote from inside OnCollected) already sees the freed capacity slot.
				table.remove(motes, index)
				part:Destroy()
				self.OnCollected:Fire(mote.Value, mote.Def)
			else
				part.CFrame = poseOf(mote)
			end
		end
	end
end

function MoteRuntime.Clear(self: MoteRuntime): ()
	local motes = self._motes
	-- Value in flight is deliberately DISCARDED, not credited. Clear is called on Transcendence,
	-- which is resetting the wallet in the same breath, and on plot release, where there is no wallet
	-- left -- crediting here would hand a pair free Essence for pressing reset.
	for index = #motes, 1, -1 do
		local part = motes[index].Part
		if part ~= nil then
			part:Destroy()
		end
	end
	table.clear(motes)
end

function MoteRuntime.Destroy(self: MoteRuntime): ()
	-- Clear FIRST: sixty anchored parts per Sanctum, six Sanctums, every release -- a skipped cleanup
	-- here is a slow leak that only shows up hours into a live server.
	self:Clear()
	self._destroyed = true
	self.OnCollected:Destroy()
end

return MoteSystem
