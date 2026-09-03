--!strict
--[[
    ClientBootstrap
    The client's only entry point. It waits for the remote folder, builds the SanctumHud, creates
    the ClientStore, feeds StateSync into it, and then hands every controller the same context and
    starts it. Nothing here decides anything about the game: it is wiring, and its one job is to
    make sure a player always ends up with a HUD bound to the server's snapshot.
]]
--[[ WHY EVERY CONTROLLER IS ISOLATED IN A pcall. These eight controllers are independent surfaces
     -- a toast stack, a sound bank, a settings panel. An error while requiring or initialising any
     one of them must not stop the other seven, because the failure mode of an unguarded loop here
     is a player standing in a fully working Sanctum with no interface at all. A broken controller
     costs its own feature and one warn line, never the HUD.

     WHY StateSync IS READ EXACTLY ONCE, HERE. If controllers connected to it themselves they would
     each hold a private copy of the snapshot, and the copies would diverge the moment one of them
     handled a payload slightly differently. The store is the single reader, and Observe is the only
     way anything downstream learns that a value changed. ]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local ClientStore = require(Modules:WaitForChild("ClientStore"))
local RemoteSchema = require(Modules:WaitForChild("RemoteSchema"))

local ControllerFolder = script.Parent:WaitForChild("Controllers")
local UiBuilder = require(ControllerFolder:WaitForChild("UiBuilder"))

-- Deterministic order, HUD first: if something later in the list is going to fail, the most
-- important surface in the game is already bound by the time it does.
local CONTROLLER_ORDER = {
	"HudController",
	"NotifyController",
	"PromptController",
	"AffinityController",
	"LinkController",
	"RebirthController",
	"SettingsController",
	"EvolutionFxController",
	"SoundController",
}

-- Bounded so a missing remote surfaces as a warning instead of a client that hangs forever on a
-- server built from an older RemoteSchema.
local WAIT_SECONDS = 10

local function collectRemotes(folder: Instance): { [string]: any }
	local remotes: { [string]: any } = {}
	for _, def in ipairs(RemoteSchema.List) do
		local remote = folder:WaitForChild(def.Name, WAIT_SECONDS)
		if remote ~= nil and remote:IsA("RemoteEvent") then
			remotes[def.Name] = remote
		else
			-- Not fatal: a controller that needs a missing remote simply does nothing, which is a
			-- far better outcome than refusing to build the rest of the interface.
			warn("[ClientBootstrap] remote '" .. def.Name .. "' is missing from " .. RemoteSchema.FolderName)
		end
	end
	return remotes
end

--[[ Init every controller, then Start every controller that survived Init. Two phases, mirroring
     ServiceRegistry on the server: a controller may look another one up during Start (PromptController
     reads HudController.ReasonText), and that is only safe once all of them have been built. ]]
local function startControllers(context: { [string]: any }): ()
	local started: { any } = {}

	for _, name in ipairs(CONTROLLER_ORDER) do
		local module = ControllerFolder:FindFirstChild(name)
		if module == nil then
			warn("[ClientBootstrap] no controller named '" .. name .. "'")
			continue
		end
		local okRequire, controller = pcall(require, module)
		if not okRequire or type(controller) ~= "table" then
			warn("[ClientBootstrap] failed to require " .. name .. ": " .. tostring(controller))
			continue
		end
		local okInit, initError = pcall(function()
			controller:Init(context)
		end)
		if okInit then
			table.insert(started, controller)
		else
			warn("[ClientBootstrap] " .. name .. ":Init failed: " .. tostring(initError))
		end
	end

	for _, controller in ipairs(started) do
		local okStart, startError = pcall(function()
			controller:Start()
		end)
		if not okStart then
			warn("[ClientBootstrap] " .. tostring(controller.Name) .. ":Start failed: " .. tostring(startError))
		end
	end
end

local player = Players.LocalPlayer
if player == nil then
	-- Only reachable if this script is run outside a client context; bailing beats erroring.
	warn("[ClientBootstrap] no LocalPlayer, so there is nobody to build a HUD for")
	return
end

local playerGui = player:WaitForChild("PlayerGui")
local remoteFolder = ReplicatedStorage:WaitForChild(RemoteSchema.FolderName)
if playerGui == nil or remoteFolder == nil then
	warn("[ClientBootstrap] PlayerGui or " .. RemoteSchema.FolderName .. " never arrived; no HUD")
	return
end

local remotes = collectRemotes(remoteFolder)
local store = ClientStore.new()

-- Parented only once the whole tree exists, so a half-built HUD is never on screen.
local ui = UiBuilder.build()
ui.ScreenGui.Parent = playerGui

--[[ The ONLY StateSync listener in the client. ClientStore itself decides what a Full payload means
     versus an essence-only tick, so this handler stays a single forwarding call -- it runs twice a
     second and has no business doing anything more. ]]
local stateSync = remotes[RemoteSchema.Remotes.StateSync.Name]
if stateSync ~= nil then
	stateSync.OnClientEvent:Connect(function(snapshot: any)
		store:Set(snapshot)
	end)
else
	warn("[ClientBootstrap] StateSync is missing; the HUD will show its zeroed default state")
end

local function requestSnapshot(): ()
	local remote = remotes[RemoteSchema.Remotes.RequestSnapshot.Name]
	if remote == nil then
		return
	end
	-- No payload: the server derives the sanctum from the player's occupancy, so there is nothing
	-- to ask for and nothing to forge.
	remote:FireServer()
end

startControllers({
	Store = store,
	Remotes = remotes,
	Player = player,
	PlayerGui = playerGui,
	Ui = ui,
})

--[[ Ask once now, and again on every respawn. The HUD survives a respawn (ResetOnSpawn = false), so
     without this a player who died mid-attunement would keep reading a snapshot from before it --
     and the throttled replicator only pushes a Full snapshot when the sanctum is dirty, so a stale
     HUD could sit there indefinitely on a quiet plot. ]]
requestSnapshot()
player.CharacterAdded:Connect(requestSnapshot)
