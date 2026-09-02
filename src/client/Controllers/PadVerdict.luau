--!strict
--[[
    PadVerdict
    What one purchase pad MEANS, with no Instance in sight. It keeps a PlotState-shaped view of the
    snapshot and answers, for a given PadKind and id: what the pad is called, whether it can be acted
    on right now, the closed-set reason code if it cannot, and what it costs. Every answer is
    Economy's -- the same pure module PurchaseService runs on the server -- and every name comes
    straight from the catalogues.
    Split out of PromptController for the 300-line rule: this is that controller's pure half, and
    keeping it separate means the wording rules can be read without the Instance plumbing.
    Owner: client  |  Consumers: PromptController (only)
]]

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local DropperData = require(Modules:WaitForChild("DropperData"))
local Economy = require(Modules:WaitForChild("Economy"))
local EvolutionData = require(Modules:WaitForChild("EvolutionData"))
local SectionData = require(Modules:WaitForChild("SectionData"))
local UpgradeData = require(Modules:WaitForChild("UpgradeData"))

-- Exactly the fields Economy reads out of a PlotState, and nothing else. It is a PROJECTION of the
-- server's state rebuilt from each Full snapshot, never a second copy the client may edit.
type PlotView = {
	Essence: number,
	Stage: number,
	Affinity: string?,
	Droppers: { [string]: number },
	Upgrades: { [string]: number },
	Sections: { [string]: boolean },
	LifetimeEssence: number,
}

local PadVerdict = {}

local Reason = Economy.Reason
local EMPTY: { [string]: any } = {}

-- Re-exported so PromptController never has to spell a reason code as a literal: the closed set has
-- exactly one definition, in Economy, and this is the client's handle on it.
PadVerdict.Reason = Reason

-- The verb each PadKind uses when it CAN be acted on. Everything else a pad ever says is reason
-- text, so this table is the whole of the affordable vocabulary.
local VERBS: { [string]: string } = {
	dropper = "Buy for",
	upgrade = "Buy for",
	section = "Buy for",
	attune = "Attune for",
	transcend = "Transcend",
	link = "Share this Sanctum",
}

-- Snapshot fields are untrusted in the same sense Economy treats them: a NaN reaching a cost makes
-- every comparison against it false, and the pad would silently read as affordable.
local function num(value: any, default: number): number
	if type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge then
		return value
	end
	return default
end

local function map(value: any): { [string]: any }
	return if type(value) == "table" then value else EMPTY
end

--[[ The zeroed view a controller starts from. Stage 1 with nothing owned is the emptiest legal
     PlotState, so every pad reads "locked" or "cannot afford" until the first snapshot lands --
     which is the honest answer before the server has told this client anything. ]]
function PadVerdict.new(): PlotView
	return {
		Essence = 0,
		Stage = 1,
		Affinity = nil,
		Droppers = EMPTY :: any,
		Upgrades = EMPTY :: any,
		Sections = EMPTY :: any,
		LifetimeEssence = 0,
	}
end

-- Mutates in place rather than returning a fresh table: the view is held by one controller for the
-- life of the session, and reallocating it on every Full snapshot would churn for no benefit.
function PadVerdict.update(view: PlotView, source: any): ()
	local raw = map(source)
	view.Stage = math.clamp(math.floor(num(raw.Stage, 1)), 1, EvolutionData.MaxStage)
	view.Affinity = if type(raw.Affinity) == "string" then raw.Affinity else nil
	-- Referenced, not copied. ClientStore already deep-copies each Full payload, so these tables are
	-- private to the store and nothing on the client mutates them.
	view.Droppers = map(raw.Droppers) :: any
	view.Upgrades = map(raw.Upgrades) :: any
	view.Sections = map(raw.Sections) :: any
	view.LifetimeEssence = num(raw.LifetimeEssence, 0)
end

function PadVerdict.setEssence(view: PlotView, value: any): ()
	view.Essence = num(value, 0)
end

function PadVerdict.verb(kind: string): string
	return VERBS[kind] or "Buy for"
end

--[[ One switch over PadKind, and every branch DEFERS: the display name comes from the catalogue and
     the verdict from Economy, run on the same PlotState shape the server holds. An id this build has
     never heard of is made UNAVAILABLE, never free -- the same doctrine Economy applies to a corrupt
     def, for the same reason. ]]
function PadVerdict.evaluate(view: PlotView, kind: string, id: string): (string, boolean, string, number)
	if kind == "dropper" then
		local def = DropperData.get(id)
		if def == nil then
			return "Wellspring", false, Reason.UnknownId, 0
		end
		local ok, reason = Economy.dropperStatus(view, def)
		return def.Name, ok, reason, Economy.getDropperCost(def, num(view.Droppers[id], 0))
	elseif kind == "upgrade" then
		local def = UpgradeData.get(id)
		if def == nil then
			return "Upgrade", false, Reason.UnknownId, 0
		end
		local ok, reason = Economy.upgradeStatus(view, def)
		return def.Name, ok, reason, Economy.getUpgradeCost(def, Economy.upgradeLevel(view, id))
	elseif kind == "section" then
		local def = SectionData.get(id)
		if def == nil then
			return "Wing", false, Reason.UnknownId, 0
		end
		local ok, reason = Economy.sectionStatus(view, def)
		return def.Name, ok, reason, Economy.getSectionCost(def)
	elseif kind == "attune" then
		local ok, reason = Economy.attuneStatus(view)
		local nextStage = EvolutionData.next(view.Stage)
		if nextStage == nil then
			-- Primordial. attuneStatus already returned max_stage, so the pad reads as a landmark
			-- rather than as a purchase with a missing price.
			return "The Conflux", ok, reason, 0
		end
		return "Attune: " .. nextStage.Name, ok, reason, num(nextStage.RequiredEssence, 0)
	elseif kind == "transcend" then
		local ok, reason = Economy.transcendStatus(view)
		-- Transcendence spends the run, not the wallet: quoting a price here would be a lie.
		return "Transcendence", ok, reason, 0
	elseif kind == "link" then
		-- Not a purchase at all: the link pad costs nothing and PlotService alone decides who may
		-- use it, so the only honest thing the client can put on it is what it does.
		return "Sanctum Link", true, Reason.Ok, 0
	end
	return "Pad", false, Reason.UnknownId, 0
end

return PadVerdict
