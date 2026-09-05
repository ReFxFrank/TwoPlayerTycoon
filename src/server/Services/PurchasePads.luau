--!strict
--[[
	PurchasePads
	The pure half of PurchaseService: what one pad MEANS, and what it SHOWS. Given a PlotState it
	answers, for a pad kind and id, whether the pad can be acted on, the closed-set reason if it
	cannot, what it costs, what it is called and whether the Sanctum can see it yet -- every answer
	is Economy's, run on the same catalogue the client reads. It then writes that verdict onto the
	pad Instance: the four attributes the client reads, the sign wording, whether the prompt is live
	at all, and whether the pad is visible. It knows nothing about occupancy, Essence or Triggered
	signals -- those are decisions, and decisions live in the service.
	Split out of PurchaseService only to keep both files inside the project's 300-line budget.
	Owner: server/Services  |  Consumers: PurchaseService (only)
]]

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local DropperData = require(Modules:WaitForChild("DropperData"))
local Economy = require(Modules:WaitForChild("Economy"))
local EvolutionData = require(Modules:WaitForChild("EvolutionData"))
local Format = require(Modules:WaitForChild("Format"))
local GameConfig = require(Modules:WaitForChild("GameConfig"))
local SectionData = require(Modules:WaitForChild("SectionData"))
local UpgradeData = require(Modules:WaitForChild("UpgradeData"))

-- Ok/Reason are the purchase gate; the rest is wording. Hidden means "this Sanctum cannot see the
-- content at all yet", which is a stronger statement than locked.
type Verdict = { Ok: boolean, Reason: string, Cost: number, Name: string, Detail: string, Hidden: boolean }

local PurchasePads = {}

local Reason = Economy.Reason
local SLOTS = math.max(1, GameConfig.Plot.SlotsPerSanctum)
-- The reason code the link pad reports when it is not usable. It never reaches a purchase, so it
-- stays local to the pad's presentation rather than joining Economy's closed set.
local LINK_UNAVAILABLE = "unavailable"

-- Every Runtime.Pads key resolves to one of these; anything else is a pad this build has invented
-- and PurchaseService has not been taught to sell.
local KINDS: { [string]: boolean } = { dropper = true, upgrade = true, section = true,
	attune = true, transcend = true, link = true }
PurchasePads.Kinds = KINDS

--[[ The three refusals that leave a prompt LIVE. All mean "come back with more Essence", and a pad
     the pair are visibly saving for must stay a target. Every other refusal DISABLES the prompt
     rather than merely relabelling it, so an unbuyable pad cannot even be pressed.

     NeedLifetime belongs here for a reason worth stating: it is the ONE gate that income alone can
     open, and RefreshPads is reached only from a purchase, an attunement or a RebuildSanctum. Held
     hard, the Attune and Transcend prompts stayed DISABLED after their gate had opened and only
     came back if the pair happened to buy something -- so a pair idling to the threshold, which is
     the whole activity of a tycoon, walked to a dead pad. Nothing is weakened: the pad becomes
     pressable-but-refused exactly like an unaffordable dropper, and Attune and BeginVote each
     re-run the full gate against live state on the trigger. ]]
local SOFT: { [string]: boolean } = { [Reason.Insufficient] = true, [Reason.NeedEssence] = true,
	[Reason.NeedLifetime] = true }

local function num(v: any, default: number): number
	return if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then v :: number else default
end

--[[ Runtime.Pads keys are the server's own identity for a pad ("dropper:ember_vent", "attune",
     "link:2"). They are parsed here rather than read back off the pad's attributes, because those
     attributes are what this module PUBLISHES -- deriving behaviour from them would let one bad
     refresh rewrite what a pad sells. The two bare keys carry the kind as their id, matching what
     PlotBuilder already writes for them. ]]
function PurchasePads.split(key: any): (string?, string)
	if type(key) ~= "string" then return nil, "" end
	local colon = string.find(key, ":", 1, true)
	if colon == nil then return (if KINDS[key] then key else nil), key end
	local kind = string.sub(key, 1, colon - 1)
	return (if KINDS[kind] then kind else nil), string.sub(key, colon + 1)
end

-- Economy has no public owned-count reader, and PurchaseService needs the same number to increment.
function PurchasePads.owned(state: any, id: string): number
	local map = if type(state) == "table" then (state :: any).Droppers else nil
	return math.max(0, math.floor(num(if type(map) == "table" then (map :: any)[id] else nil, 0)))
end

local function verdict(ok: boolean, reason: string, cost: number, name: string, detail: string,
	hidden: boolean): Verdict
	return { Ok = ok, Reason = reason, Cost = cost, Name = name, Detail = detail, Hidden = hidden }
end

-- Both stage-gate codes read the same on a pad, and both hide it: a Wing's contents and a Stage's
-- contents are equally "not yet".
local function stageHidden(reason: string): boolean
	return reason == Reason.LockedStage or reason == Reason.LockedSection
end

--[[ What a pad is worth, what it is called and whether the Sanctum can see it yet -- all of it
     Economy's answer, run against the LIVE PlotState the caller passes in. A pad is HIDDEN when the
     Sanctum has not reached the content at all (a Stage gate, a Wing already bought, a Transcendence
     still Stages away): an unreachable pad standing in the room reads as broken, and hiding it turns
     each Attunement into a visible unlock. Everything else stays visible and says why.
     `occupants` is the live headcount, and is only read by the link pad. ]]
function PurchasePads.evaluate(state: any, kind: string, id: string, occupants: number): Verdict
	if kind == "dropper" then
		local def = DropperData.get(id)
		-- An id no catalogue knows is made UNAVAILABLE, never free -- the same doctrine Economy
		-- applies to a corrupt def, for the same reason.
		if def == nil then return verdict(false, Reason.UnknownId, 0, "Wellspring", "", true) end
		local ok, reason = Economy.dropperStatus(state, def)
		local cost = Economy.getDropperCost(def, PurchasePads.owned(state, id))
		local detail = if reason == Reason.MaxOwned then "Maxed" else Format.essence(cost)
		return verdict(ok, reason, cost, def.Name, detail, stageHidden(reason))
	elseif kind == "upgrade" then
		local def = UpgradeData.get(id)
		if def == nil then return verdict(false, Reason.UnknownId, 0, "Upgrade", "", true) end
		local ok, reason = Economy.upgradeStatus(state, def)
		local level = Economy.upgradeLevel(state, id)
		-- getUpgradeCost returns math.huge at max level. Publishing that would put an infinity on a
		-- sign and in the PadCost attribute; a maxed pad has no price, so it quotes none.
		local maxed = reason == Reason.MaxLevel
		local cost = if maxed then 0 else Economy.getUpgradeCost(def, level)
		local detail = if maxed then "Maxed" else string.format("Lv %d  %s", level + 1, Format.essence(cost))
		return verdict(ok, reason, cost, def.Name, detail, stageHidden(reason))
	elseif kind == "section" then
		local def = SectionData.get(id)
		if def == nil then return verdict(false, Reason.UnknownId, 0, "Wing", "", true) end
		local ok, reason = Economy.sectionStatus(state, def)
		local cost = Economy.getSectionCost(def)
		-- A bought Wing's pad has nothing left to sell, and the room it sold is now standing next
		-- to it, so it is hidden rather than left saying "Unlocked" forever.
		local hidden = reason == Reason.AlreadyOwned or stageHidden(reason)
		return verdict(ok, reason, cost, def.Name, Format.essence(cost), hidden)
	elseif kind == "attune" then
		local ok, reason = Economy.attuneStatus(state)
		local nextStage = EvolutionData.next(math.floor(num(if type(state) == "table"
			then (state :: any).Stage else nil, 1)))
		if nextStage == nil then
			-- Primordial: a landmark, not a purchase. Quoting a price here would be a lie, and
			-- hiding the pad would delete the centrepiece of a finished Sanctum.
			return verdict(ok, reason, 0, "The Conflux", "Primordial", false)
		end
		local cost = math.max(0, num(nextStage.RequiredEssence, 0))
		return verdict(ok, reason, cost, "Attune: " .. nextStage.Name, Format.essence(cost), false)
	elseif kind == "transcend" then
		local ok, reason = Economy.transcendStatus(state)
		-- Transcendence spends the RUN, not the wallet, so it has no price. Its pad stays hidden
		-- until the pair are at the Stage that could ever allow it (§8: it appears when eligible).
		return verdict(ok, reason, 0, "Transcendence", (if ok then "Ready" else "Not yet"),
			reason == Reason.NeedStage)
	end
	--[[ link: not a purchase at all, and the only pad a NON-occupant is meant to use. Nobody home
	     means there is nobody to ask, so the pad is hidden; a full Sanctum shows a dead pad instead,
	     because a link pad that vanishes when a partner arrives reads as a bug. ]]
	local count = math.max(0, math.floor(num(occupants, 0)))
	local ok = count > 0 and count < SLOTS
	return verdict(ok, (if ok then Reason.Ok else LINK_UNAVAILABLE), 0, "Sanctum Link",
		string.format("%d/%d", count, SLOTS), count == 0)
end

--[[ Writes one verdict onto one pad. Locked is the union of "cannot see it" and "cannot act on it
     for a reason more Essence will not fix" -- PadLocked is the client's cue to grey the pad out,
     and prompt.Enabled is the server making that refusal real rather than cosmetic. ]]
function PurchasePads.publish(pad: any, label: any, prompt: any, kind: string, id: string, v: Verdict): ()
	local locked = v.Hidden or (not v.Ok and not SOFT[v.Reason])
	pad:SetAttribute("PadKind", kind)
	pad:SetAttribute("PadId", id)
	pad:SetAttribute("PadCost", v.Cost)
	pad:SetAttribute("PadLocked", locked)
	if label ~= nil then
		label.Text = v.Name .. "\n" .. v.Detail
	end
	if prompt ~= nil then
		prompt.Enabled = not locked
		-- PromptController rewrites both of these with its own wording the moment a snapshot lands;
		-- these are what a client that has not yet loaded (or has no controller) reads.
		prompt.ObjectText = v.Name
		prompt.ActionText = v.Detail
	end
	pad.Transparency = if v.Hidden then 1 else 0
	pad.CanCollide = not v.Hidden
	-- The BillboardGui, not its label: disabling the gui stops it rendering at all, where a blanked
	-- label is still a live billboard on every client within 90 studs.
	local sign = if label ~= nil then label.Parent else nil
	if sign ~= nil then
		sign.Enabled = not v.Hidden
	end
end

return PurchasePads
