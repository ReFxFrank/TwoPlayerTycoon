--!strict
--[[
    RebirthController
    Owns the Transcendence modal: the irreversible-action warning, the live consensus vote list and
    its countdown. It decides nothing. The server opens a vote by pushing RebirthVoteState, counts
    the votes and executes; this file renders that state and forwards two button presses as
    RebirthVote { Accept = true } / { Accept = false }.
    Owner: client  |  Consumers: ClientBootstrap (lifecycle)
]]
--[[ WHY THE COPY IS BLUNT. Transcendence deletes an hour of shared work and the pair have thirty
     seconds to agree to it. Softening the wording to "reset your progress" would make the most
     destructive button in the game read like a menu option, so the modal names every category of
     thing that is destroyed and every category that survives, in exactly those words.

     WHY THE MODAL IS CLOSED FROM FOUR DIRECTIONS. A vote can end in four ways: unanimous yes,
     somebody votes no, an occupant leaves, or the window expires -- and only the first is visible
     in the payload. So it closes on a terminal push (an ExpiresAt that is not in the future), on a
     local countdown reaching zero, on unanimity, and on a Confirm the server never answered. A
     stuck modal is a full-screen scrim over a running Sanctum, which is unrecoverable in-game. ]]

local RunService = game:GetService("RunService")

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local Format = require(Modules:WaitForChild("Format"))
local RemoteSchema = require(Modules:WaitForChild("RemoteSchema"))
local Theme = require(Modules:WaitForChild("Theme"))

type Context = { Store: any, Remotes: { [string]: any }, Player: any, PlayerGui: any, Ui: any }

local Controller = {}
Controller.Name = "RebirthController"

-- Named in full, in the player's vocabulary, with no hedging. "Everything" alone is not a warning.
local WARNING = table.concat({
	"This cannot be undone, and it takes the whole Sanctum with it.",
	"LOST -- every Essence in the shared wallet, your Stage (back to Mote), every Wellspring, every"
		.. " Upgrade, every Wing, and the Affinity the pair chose.",
	"KEPT -- your rebirth count, your permanent multiplier, and the badges you have earned. Those"
		.. " are per player and are never merged or reset.",
	"Every occupant must vote yes inside the window. Everyone who votes yes keeps the reward.",
}, "\n\n")

-- How long a Confirm may go unanswered before the modal gives up. The server replies with a vote
-- state within a tick when it accepts, so silence past this means it refused.
local ANSWER_GRACE = 5
local TICK_INTERVAL = 0.25 -- countdown redraw cadence; a 30s window does not need per-frame text

local connections: { any } = {}
local remotes: { [string]: any } = {}
local modal: any = nil
local transcendButton: any = nil
local selfKey = ""
local names: { [string]: string } = {}
local votes: { [string]: boolean } = {}
local expiresAt = 0 -- os.time() deadline of the live vote; 0 = no vote in progress
-- os.clock() at which Confirm was sent with no live vote. nil, not 0, because os.clock() is zero
-- at the first frame of a session and a sentinel that collides with a real reading is a bug.
local pendingSince: number? = nil
local accumulator = 0

local function num(value: any, default: number): number
	if type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge then
		return value
	end
	return default
end

--[[ Rows are filled in sorted key order, not pairs order: Luau's pairs order is unspecified, so
     without the sort a partner could visibly swap rows between two pushes of the same vote. ]]
local function renderVotes(): ()
	local keys: { string } = {}
	for key in pairs(names) do
		table.insert(keys, key)
	end
	table.sort(keys)

	for index, row in ipairs(modal.VoteRows) do
		local key = keys[index]
		if key == nil then
			row.Visible = false
			continue
		end
		local who = tostring(names[key])
		if key == selfKey then
			who ..= "  (you)"
		end
		local vote = votes[key]
		if vote == true then
			row.Text = who .. "  --  yes"
			row.TextColor3 = Theme.Ui.Positive
		elseif vote == false then
			row.Text = who .. "  --  no"
			row.TextColor3 = Theme.Ui.Negative
		else
			-- "deciding", not "no": an occupant who has not answered yet has refused nothing.
			row.Text = who .. "  --  deciding"
			row.TextColor3 = Theme.Ui.Muted
		end
		row.Visible = true
	end
end

-- The Confirm button is the player's own vote, so once it is cast it stops being a button: leaving
-- it live would invite a second press that says nothing new.
local function renderConfirm(): ()
	local cast = votes[selfKey] == true
	local button = modal.Confirm
	button.Text = if cast then "Waiting for the Sanctum" else (if expiresAt > 0 then "Vote yes" else "Begin the vote")
	button.BackgroundColor3 = if cast then Theme.Ui.Panel else Theme.Ui.Warning
	button.TextColor3 = if cast then Theme.Ui.Muted else Theme.Ui.Background
	button.Active = not cast
	button.AutoButtonColor = not cast
end

local function close(): ()
	expiresAt = 0
	pendingSince = nil
	names = {}
	votes = {}
	modal.TimerLabel.Text = ""
	for _, row in ipairs(modal.VoteRows) do
		row.Visible = false
	end
	modal.Root.Visible = false
end

local function open(): ()
	modal.Root.Visible = true
	renderVotes()
	renderConfirm()
end

-- Vacuously-true guard: a push whose Names table is empty must not read as "everybody agreed".
local function unanimous(): boolean
	local count = 0
	for key in pairs(names) do
		count += 1
		if votes[key] ~= true then
			return false
		end
	end
	return count > 0
end

local function send(accept: boolean): ()
	local remote = remotes[RemoteSchema.Remotes.RebirthVote.Name]
	if remote == nil then
		return
	end
	-- Accept is the whole payload: the server derives the sanctum from occupancy, so there is no
	-- plot, player or amount here for anyone to forge.
	remote:FireServer({ Accept = accept })
end

--[[ The server's vote state. It is the only thing that puts a vote on screen -- pressing the HUD
     button opens the warning, but until a state arrives there is no vote, no list and no clock. ]]
local function onVoteState(payload: any): ()
	if type(payload) ~= "table" then
		return
	end
	local deadline = num(payload.ExpiresAt, 0)
	if deadline <= os.time() then
		-- A cancel, an expiry or a completed vote all arrive looking like this. Close, do not guess.
		close()
		return
	end

	names = {}
	votes = {}
	if type(payload.Names) == "table" then
		for key, value in pairs(payload.Names) do
			if type(key) == "string" and type(value) == "string" then
				names[key] = value
			end
		end
	end
	if type(payload.Votes) == "table" then
		for key, value in pairs(payload.Votes) do
			if type(key) == "string" and type(value) == "boolean" then
				votes[key] = value
			end
		end
	end

	expiresAt = deadline
	pendingSince = nil
	if unanimous() then
		-- Everyone has agreed; the server is already executing and the Fx is on its way.
		close()
		return
	end
	open()
end

local function tick(deltaTime: number): ()
	accumulator += deltaTime
	if accumulator < TICK_INTERVAL then
		return
	end
	accumulator = 0
	if modal == nil or modal.Root.Visible ~= true then
		return
	end

	if expiresAt > 0 then
		local remaining = expiresAt - os.time()
		if remaining <= 0 then
			close()
			return
		end
		modal.TimerLabel.Text = "Vote closes in " .. Format.time(remaining)
	elseif pendingSince ~= nil and os.clock() - pendingSince > ANSWER_GRACE then
		-- Confirmed, but the server never opened a vote: it refused (gate not met, or a vote is
		-- already running elsewhere). It said why through Notify; the modal simply gets out of the way.
		close()
	end
end

function Controller:Init(context: Context): ()
	remotes = context.Remotes
	modal = context.Ui.Modals.Transcend
	transcendButton = context.Ui.ActionBar.TranscendButton
	selfKey = tostring(context.Player.UserId)

	modal.Body.Text = WARNING
	-- Smaller than the shell default: this is the longest body copy in the game and it must fit
	-- without scrolling, because a warning the player has to scroll is a warning they will not read.
	modal.Body.TextSize = 13
	modal.TimerLabel.Text = ""
	modal.Root.Visible = false
	renderConfirm()
end

function Controller:Start(): ()
	local function track(connection: any): ()
		table.insert(connections, connection)
	end

	-- The HUD button only ever opens the warning. HudController shows it solely when
	-- Gates.Transcend.Ok is true, and the server re-checks the gate before opening a vote anyway.
	track(transcendButton.Activated:Connect(open))

	track(modal.Confirm.Activated:Connect(function()
		if votes[selfKey] == true then
			return
		end
		send(true)
		if expiresAt == 0 then
			-- Opening the vote, not answering one: start the answer clock so a refusal cannot leave
			-- the modal sitting open forever.
			pendingSince = os.clock()
		end
		-- Optimistic only in the UI: the row and the button say "sent", the server still decides.
		votes[selfKey] = true
		renderVotes()
		renderConfirm()
	end))

	track(modal.Cancel.Activated:Connect(function()
		-- A no is worth sending even with no vote running: it is how a partner declines the vote
		-- the other one just opened, and the server ignores it otherwise.
		send(false)
		close()
	end))

	local remote = remotes[RemoteSchema.Remotes.RebirthVoteState.Name]
	if remote ~= nil then
		track(remote.OnClientEvent:Connect(onVoteState))
	end

	-- One always-on Heartbeat rather than connect/disconnect per vote: the handler is a numeric
	-- compare and an early return, and a countdown that fails to start is worse than a free frame.
	track(RunService.Heartbeat:Connect(tick))
end

function Controller:Stop(): ()
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
	if modal ~= nil then
		close()
	end
end

return Controller
