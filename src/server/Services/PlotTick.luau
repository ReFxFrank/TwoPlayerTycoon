--!strict
--[[
    PlotTick
    The one income loop: a single decimated step that advances every occupied Sanctum and mirrors
    dirty ones into their occupants' Profiles.

    Split out of PlotService to keep that file inside the 300-line budget. It owns the two pieces of
    clock state (the step accumulator and the mirror clock) so a restart cannot inherit a half-banked
    tick from the previous boot.
    Owner: server  |  Consumers: PlotService
]]

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local GameConfig = require(Modules:WaitForChild("GameConfig"))

-- DECIMATED to GameConfig.Income.TickRate: DropperSystem's catch-up bound is sized off a 0.1s step,
-- and stepping six Sanctums at render rate buys nothing a Mote's flight can show.
local STEP_INTERVAL = 1 / math.max(1, GameConfig.Income.TickRate)
local MAX_STEP = 0.5 -- after a hitch the banked dt would teleport every Mote to the Font in one frame
local MIRROR_SECONDS = 1 -- how often a dirty Sanctum is copied into its occupants' Profiles
local WARN_SECONDS = 10 -- throttle on the per-Sanctum step-failure warning

local PlotTick = {}
PlotTick.__index = PlotTick

--- `plots` is the live list PlotService owns; `session` supplies mirrorOne.
function PlotTick.new(plots: { any }, session: any)
	return setmetatable({ _plots = plots, _session = session, _accumulator = 0, _mirrorClock = 0 }, PlotTick)
end

function PlotTick.Reset(self: any): ()
	self._accumulator, self._mirrorClock = 0, 0
end

local function stepPlot(session: any, plot: any, dt: number, mirroring: boolean): ()
	plot:Step(dt)
	-- Cheap and non-yielding, so it rides the income tick: any save (autosave, release, shutdown)
	-- then finds a Profile at most MIRROR_SECONDS behind the live Sanctum, whoever triggered it.
	if mirroring and plot.Sanctum.Dirty then session.mirrorOne(plot) end
end

function PlotTick.Step(self: any, dt: any): ()
	self._accumulator += if type(dt) == "number" and dt == dt then dt else 0
	if self._accumulator < STEP_INTERVAL then return end
	local step = math.min(self._accumulator, MAX_STEP)
	self._accumulator = 0
	self._mirrorClock += step
	local mirroring = self._mirrorClock >= MIRROR_SECONDS
	if mirroring then self._mirrorClock = 0 end
	for _, plot in ipairs(self._plots) do
		plot.Announced = false -- re-arm the coalesced SanctumChanged for this tick
		if next(plot.Sanctum.Occupants) ~= nil then
			--[[ Per-Sanctum pcall, not one around the whole loop: an error in plot 3 must not stop
			     plots 4-6 earning, and an unguarded error would kill this connection for every
			     player on the server for the rest of its life. ]]
			local ok, err = pcall(stepPlot, self._session, plot, step, mirroring)
			if not ok and os.clock() - plot.LastWarn >= WARN_SECONDS then
				plot.LastWarn = os.clock()
				warn(("[PlotService] sanctum %d step failed: %s"):format(plot.Sanctum.Id, tostring(err)))
			end
		end
	end
end

return PlotTick
