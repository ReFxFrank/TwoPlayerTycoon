--!strict
--[[
    PlotMirror
    The bridge between a Sanctum's live PlotState and the per-player Profiles that persist it:
    mirroring the shared state out to every occupant, reading a player's saved state back, and
    adopting it when they claim a plot.

    Split out of PlotSession to keep that file inside the 300-line budget. It is the only place that
    decides which direction state flows between a Sanctum and a Profile, which is worth having in
    one file regardless.
    Owner: server  |  Consumers: PlotSession
]]

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local StateSchema = require(Modules:WaitForChild("StateSchema"))

type PlotState = StateSchema.PlotState

local PlotMirror = {}
local profiles: any = nil

function PlotMirror.bind(profileService: any): ()
	profiles = profileService
end

--[[ Writes the live shared PlotState into EVERY occupant's Profile (§1.5). Co-op means both players
     carry the same result home, so there is no host copy and no guest copy. CLONED, not aliased: a
     leaver's Profile must stop tracking a Sanctum they are no longer in. ]]
function PlotMirror.mirror(plot: any): ()
	if profiles == nil then return end
	for _, occupant in pairs(plot.Sanctum.Occupants) do
		local profile = profiles:Get(occupant.Player)
		if type(profile) == "table" then
			(profile :: any).Plot = StateSchema.clonePlotState(plot.Sanctum.State)
		end
	end
end

function PlotMirror.savedPlotOf(player: any): PlotState?
	local profile = if profiles ~= nil then profiles:Get(player) else nil
	local saved = if type(profile) == "table" then (profile :: any).Plot else nil
	return if type(saved) == "table" then saved :: PlotState else nil
end

--[[ Brings the claimer's saved PlotState in. A RECLAIM inside the grace window max-merges rather
     than replacing: the two should already match (release saves), so merging means a save that
     silently failed cannot cost the pair their progress. ]]
function PlotMirror.adopt(plot: any, player: any, reclaiming: boolean): ()
	local saved = PlotMirror.savedPlotOf(player)
	if saved ~= nil then
		plot.Sanctum.State = if reclaiming then StateSchema.mergePlotStates(plot.Sanctum.State, saved)
			else StateSchema.clonePlotState(saved)
	end
end

return PlotMirror
