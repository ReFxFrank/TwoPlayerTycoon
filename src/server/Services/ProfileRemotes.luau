--!strict
--[[
    ProfileRemotes
    The two client->server remotes ProfileService owns, because it owns Profile.Settings and the
    Profile itself: the Music/Sfx toggles and the developer data reset.

    Split out to keep ProfileService inside the 300-line budget. Neither remote had a handler at all
    before this module existed -- every click died at RemoteService as a counted "no handler
    registered" rejection, so the settings toggles were inert end to end and the reset's documented
    Studio gate was never actually enforced anywhere.
    Owner: server  |  Consumers: ProfileService
]]

local RunService = game:GetService("RunService")

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local GameConfig = require(Modules:WaitForChild("GameConfig"))
local StateSchema = require(Modules:WaitForChild("StateSchema"))

local ProfileRemotes = {}

local replicator: any = nil
local plotService: any = nil

--- PlotService is registered after ProfileService, so it is resolved lazily like the replicator.
local function resolvePlots(registry: any): any
	if plotService == nil and registry ~= nil and type(registry.TryGet) == "function" then
		plotService = registry:TryGet("PlotService")
	end
	return plotService
end

--- Settings are per-PLAYER, so changing one never marks a Sanctum dirty -- and a full snapshot is
--- only pushed for a dirty Sanctum. Without an explicit push the toggle's label would sit stale
--- until the next income tick happened to dirty the plot. Resolved lazily: StateReplicator is
--- registered after ProfileService.
local function pushTo(registry: any, player: any): ()
	if replicator == nil and registry ~= nil and type(registry.TryGet) == "function" then
		replicator = registry:TryGet("StateReplicator")
	end
	if replicator ~= nil and type(replicator.PushTo) == "function" then
		replicator:PushTo(player)
	end
end

--- `service` is ProfileService; `entryFor` resolves a player to its live entry.
function ProfileRemotes.register(remotes: any, service: any, entryFor: (any) -> any, registry: any): ()
	if remotes == nil then return end
	replicator, plotService = nil, nil -- a re-register must not keep the previous boot's handles

	remotes:On("SetSetting", function(player: Player, payload: any)
		local entry = entryFor(player)
		if entry == nil then return end
		-- RemoteSchema already bounded Key to "Music"/"Sfx" and Value to a boolean, so the shape is
		-- settled by the time it lands here. The next full snapshot carries it back to the client.
		entry.Profile.Settings[payload.Key] = payload.Value == true
		pushTo(registry, player)
	end)

	remotes:On("ResetData", function(player: Player)
		--[[ The AUTHORITATIVE half of the two-part gate from DECISIONS #14. SettingsController hides
		     the button under the same condition, but a client hiding a control is a courtesy, not a
		     control -- this is what actually keeps it unreachable on a live server. ]]
		if GameConfig.Debug.AllowDataReset ~= true then return end
		if GameConfig.Debug.DataResetStudioOnly == true and not RunService:IsStudio() then return end
		local entry = entryFor(player)
		-- Never reset a profile that is already refusing to save: it would look like it worked and
		-- then silently restore itself on the next join.
		if entry == nil or (entry.Profile :: any).__NoSave == true then return end
		entry.Profile = StateSchema.newProfile()
		--[[ The live Sanctum is the OTHER half of a save, and re-announcing ProfileLoaded does NOT
		     blank it: PlotSession.claim is idempotent by design, so a settled player gets their
		     existing plot back without re-adopting. Leave it and the next mirror -- from the income
		     tick, or unconditionally on release -- writes the old plot straight back over the fresh
		     Profile, so the reset appears to work and silently undoes itself. In a shared Sanctum
		     this clears the plot for both occupants, which is honest: the plot IS shared. ]]
		local plots = resolvePlots(registry)
		if plots ~= nil then
			local sanctum = plots:GetSanctumForPlayer(player)
			if sanctum ~= nil then
				plots:ClearMotes(sanctum)
				plots:ResetSanctum(sanctum)
			end
		end
		service.ProfileLoaded:Fire(player, entry.Profile)
		service:Save(player)
		pushTo(registry, player)
	end)
end

return ProfileRemotes
