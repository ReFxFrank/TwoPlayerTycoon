--!strict
--[[
    LinkController
    The client half of the link offer. PlotService pushes LinkOffer to a Sanctum's occupants when
    someone asks to join them; this shows the modal, runs the confirmation clock down, and sends the
    answer back as LinkResponse.

    It exists because the server half did not have one. The LinkOffer remote was declared, fired and
    the modal was built -- but nothing on the client ever listened, so an occupant was never asked
    and could never accept. Linking, the game's entire two-player hook, could not be completed by a
    real player at all; only a test calling PlotService:ResolveLink directly could.

    It decides NOTHING: the payload names a plot, never an outcome, and the server re-checks every
    gate against live state when the answer arrives.
    Owner: client  |  Consumers: ClientBootstrap
]]

local RunService = game:GetService("RunService")

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local RemoteSchema = require(Modules:WaitForChild("RemoteSchema"))

type Context = { [string]: any }

local Controller = {}
Controller.Name = "LinkController"

local remotes: { [string]: any } = {}
local modal: any = nil
local connections: { any } = {}

-- The offer being shown. PlotId 0 means "nothing pending", which is also what makes a stray Accept
-- after the modal closes a no-op rather than a second answer.
local plotId: number = 0
local expiresAt: number = 0

local function close(): ()
	plotId, expiresAt = 0, 0
	if modal ~= nil then
		modal.Root.Visible = false
	end
end

local function answer(accept: boolean): ()
	local id = plotId
	close() -- closed FIRST, so a double click cannot send two answers for one offer
	if id == 0 then
		return
	end
	local remote = remotes[RemoteSchema.Remotes.LinkResponse.Name]
	if remote ~= nil then
		-- Exactly the shape RemoteSchema validates: a plot id and a yes/no. No amount, no state.
		remote:FireServer({ PlotId = id, Accept = accept })
	end
end

local function onOffer(payload: any): ()
	if modal == nil or type(payload) ~= "table" then
		return
	end
	local id = (payload :: any).PlotId
	if type(id) ~= "number" then
		return
	end
	plotId = id
	expiresAt = if type((payload :: any).ExpiresAt) == "number" then (payload :: any).ExpiresAt else 0
	local who = (payload :: any).FromName
	modal.FromLabel.Text = ("%s wants to join your Sanctum."):format(
		if type(who) == "string" and #who > 0 then who else "Someone")
	modal.Root.Visible = true
end

-- The window is the server's; this only stops the modal outliving it. The server expires the offer
-- on its own clock, so a client that misses this tick simply sends an answer that is ignored.
local function tick(): ()
	if plotId == 0 or expiresAt == 0 then
		return
	end
	if os.time() >= expiresAt then
		close()
	end
end

function Controller:Init(context: Context): ()
	remotes = context.Remotes
	modal = context.Ui.Modals.LinkOffer
	modal.FromLabel.Text = ""
	modal.Root.Visible = false
end

function Controller:Start(): ()
	local function track(connection: any): ()
		table.insert(connections, connection)
	end

	track(modal.Confirm.Activated:Connect(function()
		answer(true)
	end))
	track(modal.Cancel.Activated:Connect(function()
		answer(false)
	end))

	local remote = remotes[RemoteSchema.Remotes.LinkOffer.Name]
	if remote ~= nil then
		track(remote.OnClientEvent:Connect(onOffer))
	end
	track(RunService.Heartbeat:Connect(tick))
end

function Controller:Stop(): ()
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
	close()
end

return Controller
