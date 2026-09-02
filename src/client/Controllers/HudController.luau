--!strict
--[[
    HudController
    Binds the always-on regions of the SanctumHud -- the essence/income/stage readout, the two
    partner slots and the action bar -- to the ClientStore snapshot. It renders and nothing else:
    every number it shows was computed by the server, and every gate it reports was decided by
    Economy. It also owns the single reason-code -> human-text table the whole client shares.
    Owner: client  |  Consumers: ClientBootstrap (lifecycle), PromptController (ReasonText)
]]
--[[ WHY THE OBSERVERS ARE SPLIT THIS FINELY. StateSync pushes essence twice a second and everything
     else only when the sanctum is dirty. One coarse "re-render the HUD" observer would therefore
     rebuild the partner panel, re-read EvolutionData and reformat six labels 120 times a minute for
     the sake of one number. Each observer below owns exactly the widgets its own path can change,
     and the two that ride the essence tick do a single assignment each. ]]

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local Economy = require(Modules:WaitForChild("Economy"))
local EvolutionData = require(Modules:WaitForChild("EvolutionData"))
local Format = require(Modules:WaitForChild("Format"))
local Theme = require(Modules:WaitForChild("Theme"))

type Context = { Store: any, Remotes: { [string]: any }, Player: any, PlayerGui: any, Ui: any }

local Controller = {}
Controller.Name = "HudController"

local Reason = Economy.Reason

--[[ THE reason table. Economy returns closed-set codes and never sentences (§11 of DECISIONS), so
     exactly one file is allowed to decide what a code means in English -- this one. PromptController
     reads it through Controller.ReasonText rather than restating any of it, which is what stops a
     pad saying "Locked" while the HUD says "Not enough Essence" about the same refusal. ]]
local REASON_TEXT: { [string]: string } = {
	[Reason.Ok] = "Ready",
	[Reason.LockedStage] = "Attune the Conflux further first",
	[Reason.LockedSection] = "Unlock the Wing it stands in first",
	[Reason.MaxOwned] = "You own every one of these",
	[Reason.MaxLevel] = "Fully upgraded",
	[Reason.AlreadyOwned] = "Already part of the Sanctum",
	[Reason.Insufficient] = "Not enough Essence",
	[Reason.MaxStage] = "Primordial -- nothing further to attune into",
	[Reason.NeedEssence] = "Not enough Essence banked",
	[Reason.NeedLifetime] = "Earn more Essence this run",
	[Reason.NeedDroppers] = "Raise more Wellsprings first",
	[Reason.NeedStage] = "Reach Stage " .. tostring(EvolutionData.MaxStage) .. " first",
	[Reason.UnknownId] = "Unavailable",
}
Controller.ReasonText = REASON_TEXT

--[[ Resolver rather than a raw index, because a reason code arrives over the wire: a server built
     from newer data could name a code this client has never heard of, and a blank button is worse
     than a vague one. ]]
function Controller.reasonText(code: any): string
	if type(code) == "string" then
		local text = REASON_TEXT[code]
		if text ~= nil then
			return text
		end
	end
	return "Not available yet"
end

-- Snapshot fields are untrusted in the same sense Economy treats them: a malformed push must show a
-- zero, never propagate a NaN into a UDim2 (which would collapse the bar to an unrenderable size).
local function num(value: any, default: number): number
	if type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge then
		return value
	end
	return default
end

local connections: { any } = {}
local hud: any, partners: any, bar: any
local store: any
-- Cached so the two multi-source labels (income + motes) and the progress bar can each be redrawn
-- from one changed input without re-reading the whole snapshot.
local income, motes, stageTarget = 0, 0, 0

local function renderIncome(): ()
	hud.IncomeLabel.Text = string.format("%s/s   %d motes", Format.essence(income), motes)
end

-- Progress towards the NEXT stage's entry price. stageTarget of 0 means Primordial: the bar reads
-- full, because there is no further stage to be a fraction of.
local function renderProgress(essence: any): ()
	local fraction = if stageTarget > 0 then math.clamp(num(essence, 0) / stageTarget, 0, 1) else 1
	hud.StageFill.Size = UDim2.fromScale(fraction, 1)
end

local function renderStage(value: any): ()
	local index = math.clamp(math.floor(num(value, 1)), 1, EvolutionData.MaxStage)
	local def = EvolutionData.get(index)
	hud.StageLabel.Text = string.format(
		"%s  -  Stage %d / %d",
		if def then def.Name else "Unknown",
		index,
		EvolutionData.MaxStage
	)
	local nextStage = EvolutionData.next(index)
	stageTarget = if nextStage then num(nextStage.RequiredEssence, 0) else 0
	-- The bar's denominator just moved, so redraw it now rather than waiting for the next essence
	-- tick to make an attunement look like it reset the progress it just completed.
	renderProgress(store:GetPath("Essence"))
end

--[[ Two rows, filled by Slot rather than by array order: the server may list occupants in join
     order, and a partner leaving must not shuffle the surviving player into the other row. ]]
local function renderOccupants(list: any): ()
	local bySlot: { [number]: any } = {}
	if type(list) == "table" then
		for _, entry in ipairs(list) do
			if type(entry) == "table" then
				local slot = math.floor(num(entry.Slot, 0))
				if slot >= 1 and slot <= #partners.Slots then
					bySlot[slot] = entry
				end
			end
		end
	end

	for slot, row in ipairs(partners.Slots) do
		local occupant = bySlot[slot]
		local filled = occupant ~= nil
		row.NameLabel.Visible = filled
		row.ContributionLabel.Visible = filled
		row.RebirthChip.Visible = filled
		row.EmptyLabel.Visible = not filled
		if occupant ~= nil then
			local you = occupant.IsYou == true
			row.NameLabel.Text = tostring(occupant.Name) .. (if you then "  (you)" else "")
			row.ContributionLabel.Text = Format.abbreviate(num(occupant.Contribution, 0)) .. " contributed"
			-- "R3" rather than "3 rebirths": the chip is a quarter of a row wide and the R reads as
			-- a rank at a glance, which is the only thing it needs to do.
			row.RebirthChip.Text = "R" .. tostring(math.max(0, math.floor(num(occupant.Rebirths, 0))))
			-- The accent stroke is the only "this row is you" marker that survives being read at a
			-- glance; the "(you)" suffix is the accessible fallback for it.
			row.Highlight.Transparency = if you then 0 else 1
		else
			row.Highlight.Transparency = 1
		end
	end
end

--[[ The Attune button is a SIGNPOST, not a purchase: attunement happens at a server-listened pad
     (§1.7), so this only ever mirrors Gates.Attune. Blocked states keep the cost visible, because
     "Not enough Essence" without a number tells the player nothing about how far off they are. ]]
local function renderAttune(gate: any): ()
	local g = if type(gate) == "table" then gate else {}
	local ok = g.Ok == true
	local cost = num(g.Cost, 0)
	local costText = if cost > 0 then Format.essence(cost) else ""
	local button = bar.AttuneButton

	if ok then
		button.Text = if costText ~= "" then ("Attune  " .. costText) else "Attune"
		button.BackgroundColor3 = Theme.Ui.Accent
		button.TextColor3 = Theme.Ui.Background
	else
		local why = Controller.reasonText(g.Reason)
		button.Text = if costText ~= "" then (why .. "  " .. costText) else why
		button.BackgroundColor3 = Theme.Ui.Panel
		button.TextColor3 = Theme.Ui.Muted
	end
	-- Both flags, not just the colour: AutoButtonColor alone would still flash a hover highlight on
	-- a button that cannot do anything.
	button.Active = ok
	button.AutoButtonColor = ok
end

function Controller:Init(context: Context): ()
	store = context.Store
	hud = context.Ui.Hud
	partners = context.Ui.Partners
	bar = context.Ui.ActionBar
end

function Controller:Start(): ()
	local function track(connection: any): ()
		table.insert(connections, connection)
	end

	-- The hot path. Essence arrives ~twice a second, so these two observers do one assignment each
	-- and share no work; everything they would otherwise need was cached by a colder observer.
	track(store:Observe("Essence", function(value: any)
		hud.EssenceLabel.Text = Format.essence(num(value, 0))
	end))
	track(store:Observe("Essence", renderProgress))

	track(store:Observe("Plot.IncomePerSecond", function(value: any)
		income = num(value, 0)
		renderIncome()
	end))
	track(store:Observe("Plot.MoteCount", function(value: any)
		motes = math.max(0, math.floor(num(value, 0)))
		renderIncome()
	end))
	track(store:Observe("Plot.Multiplier", function(value: any)
		hud.MultiplierChip.Text = Format.multiplier(num(value, 1))
	end))
	track(store:Observe("Plot.Stage", renderStage))
	track(store:Observe("Occupants", renderOccupants))
	track(store:Observe("Gates.Attune", renderAttune))

	-- Hidden entirely rather than greyed out: an ineligible Transcendence is not a decision the pair
	-- is being offered, and a permanently dead button trains players to ignore the action bar.
	track(store:Observe("Gates.Transcend", function(gate: any)
		bar.TranscendButton.Visible = type(gate) == "table" and gate.Ok == true
	end))
end

function Controller:Stop(): ()
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

return Controller
