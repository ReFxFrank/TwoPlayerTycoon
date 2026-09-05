--!strict
--[[
	PlotLinkController
	The offer book behind PlotService:RequestLink / :ResolveLink. It holds at most one outstanding
	LinkOffer per Sanctum, pushes it to the occupants whose consent is required, expires it after
	GameConfig.Plot.LinkConfirmSeconds, and hands an accepted offer back to its owner so the
	max-merge can happen there. It owns no occupancy and no PlotState: every gate that depends on who
	is actually in a Sanctum is PlotService's, checked once before the offer goes out and again when
	it lands, because up to thirty seconds of world can happen in between.
	Owner: server/Services  |  Consumers: PlotService (which owns exactly one of these)
]]

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local GameConfig = require(Modules:WaitForChild("GameConfig"))

type Offer = { PlotId: number, Joiner: any, JoinerId: number, ExpiresAt: number, Token: number }
-- Remotes is RemoteService and OnAccepted is PlotService's merge step. Both are optional so a spec
-- can drive the offer book with plain tables and no server standing behind it.
type Deps = { Remotes: any?, OnAccepted: ((sanctum: any, joiner: any) -> { any }?)? }

local PlotLinkController = {}

--[[ CLOSED SET, exactly like Economy's gate reasons (DECISIONS #11): the client owns the wording,
     and a free-text reason handed back through the link pad is free reconnaissance for whoever is
     probing it. ]]
local Reason = {
	Ok = "ok",
	OfferPending = "offer_pending", -- someone else is already asking to join that Sanctum
	NoRecipient = "no_recipient", -- nobody is there to consent
	NoOffer = "no_offer", -- an answer with nothing behind it: stale, or forged
	SelfOffer = "self_offer", -- the joiner tried to approve their own request
	Declined = "declined",
}
PlotLinkController.Reason = Reason

local Controller = {}
Controller.__index = Controller

type ControllerSelf = {
	_offers: { [number]: Offer }, -- keyed by PlotId: one open offer per Sanctum, never more
	_remotes: any,
	_onAccepted: (sanctum: any, joiner: any) -> { any }?,
	_token: number, -- monotonic; identifies WHICH offer an expiry closure belongs to
}
type Controller = typeof(setmetatable({} :: ControllerSelf, Controller))

-- pcall'd because a Player is userdata and reading a field off one who has already disconnected can
-- throw. This runs on the path a remote reaches, where an escaping error is a free denial of service.
local function userIdOf(player: any): number
	local ok, id = pcall(function(): any
		return (player :: any).UserId
	end)
	return if ok and type(id) == "number" and id == id then id else 0
end

local function nameOf(player: any): string
	local ok, name = pcall(function(): any
		return (player :: any).Name
	end)
	return if ok and type(name) == "string" and #name > 0 then name else "A wanderer"
end

function PlotLinkController.new(deps: Deps): Controller
	local given: Deps = if type(deps) == "table" then deps else {}
	return setmetatable({
		_offers = {},
		_remotes = given.Remotes,
		-- A no-op default keeps every call site total: a controller built without an owner still
		-- expires and declines correctly, it simply has nowhere to hand an acceptance.
		_onAccepted = given.OnAccepted or function() end,
		_token = 0,
	}, Controller)
end

function Controller._notify(self: Controller, player: any, kind: string, text: string): ()
	if self._remotes == nil then
		return
	end
	self._remotes:FireClient(player, "Notify", { Kind = kind, Text = text })
end

--[[ Opens an offer and pushes it to `recipients`. PlotService has already established that the
     joiner is unattached, that the Sanctum has a free slot and that the joiner's Profile is loaded;
     everything left is bookkeeping. ]]
function Controller.Open(self: Controller, joiner: any, sanctum: any, recipients: { any }): (boolean, string)
	local plotId = (sanctum :: any).Id
	if type(plotId) ~= "number" then
		return false, Reason.NoRecipient
	end
	--[[ One offer per Sanctum. Two in flight would race for a single slot, and the loser would be
	     merged into a plot that had no room left by the time their acceptance arrived. ]]
	if self._offers[plotId] ~= nil then
		return false, Reason.OfferPending
	end
	if type(recipients) ~= "table" or #recipients == 0 then
		return false, Reason.NoRecipient
	end

	self._token += 1
	local token = self._token
	-- Floored at one second: a hand-edited config of 0 would expire the offer before the client
	-- could render the modal, making the link pad silently unusable.
	local window = math.max(1, GameConfig.Plot.LinkConfirmSeconds)
	local offer: Offer = {
		PlotId = plotId,
		Joiner = joiner,
		JoinerId = userIdOf(joiner),
		-- os.time, not tick: the client compares it against its own os.time to draw the countdown.
		ExpiresAt = os.time() + window,
		Token = token,
	}
	self._offers[plotId] = offer
	if self._remotes ~= nil then
		self._remotes:FireClients(recipients, "LinkOffer", {
			PlotId = plotId,
			FromUserId = offer.JoinerId,
			FromName = nameOf(joiner),
			ExpiresAt = offer.ExpiresAt,
		})
	end
	--[[ The TOKEN is the cancellation, not the thread: an offer that is answered or replaced is
	     removed from the book, so this closure finds a mismatch and does nothing. Nothing in it
	     yields, so a wedged client can never hold a Sanctum's second slot open past its window. ]]
	task.delay(window, function()
		local current = self._offers[plotId]
		if current == nil or current.Token ~= token then
			return
		end
		self._offers[plotId] = nil
		self:_notify(current.Joiner, "warn", "Nobody answered your link request.")
	end)
	self:_notify(joiner, "info", "Link requested. Waiting for the sanctum to answer.")
	return true, Reason.Ok
end

--[[ Answers the open offer for `sanctum`. PlotService has already established that `responder` is a
     current occupant of it -- the offer was addressed to them and to nobody else. ]]
function Controller.Resolve(self: Controller, responder: any, sanctum: any, accept: boolean): (boolean, string)
	local plotId = (sanctum :: any).Id
	local offer = if type(plotId) == "number" then self._offers[plotId] else nil
	if offer == nil then
		return false, Reason.NoOffer
	end
	-- The joiner cannot wave their own request through: the occupant's consent IS the opt-in (§1.5),
	-- and without this check a stranger could join any plot by answering for themselves.
	if userIdOf(responder) == offer.JoinerId then
		return false, Reason.SelfOffer
	end
	-- Consumed either way, BEFORE the callback: the merge inside OnAccepted must not be able to see
	-- a still-open offer and act on it a second time.
	self._offers[plotId :: number] = nil
	if accept ~= true then
		self:_notify(offer.Joiner, "warn", "Your link request was declined.")
		return true, Reason.Declined
	end
	--[[ OnAccepted reports the resulting roster, or nil if the merge declined -- every gate is
	     re-checked against live state in there, so an accepted offer can still not land.
	     EvolutionFxController has always had a "link" handler and nothing ever sent one, so until
	     now the moment the whole game is built around arrived in silence. ]]
	local occupants = self._onAccepted(sanctum, offer.Joiner)
	if self._remotes ~= nil and type(occupants) == "table" and #occupants > 1 then
		self._remotes:FireClients(occupants, "Fx",
			{ Kind = "link", PlotId = sanctum.Id, Data = { Name = offer.Joiner.Name } })
	end
	return true, Reason.Ok
end

function Controller.Pending(self: Controller, plotId: any): Offer?
	return if type(plotId) == "number" then self._offers[plotId] else nil
end

-- Called when a Sanctum empties: there is nobody left who could consent, so the offer dies with it.
function Controller.Cancel(self: Controller, plotId: any): ()
	local offer = self:Pending(plotId)
	if offer == nil then
		return
	end
	self._offers[plotId :: number] = nil
	self:_notify(offer.Joiner, "warn", "That sanctum is no longer available.")
end

-- The joiner left before anyone answered. Dropped silently -- there is nobody to tell.
function Controller.CancelForPlayer(self: Controller, player: any): ()
	local userId = userIdOf(player)
	-- 0 is the "could not read a UserId" sentinel, and matching on it would cancel every offer whose
	-- joiner was equally unreadable rather than the one that belongs to this player.
	if userId == 0 then
		return
	end
	for plotId, offer in pairs(self._offers) do
		if offer.JoinerId == userId then
			self._offers[plotId] = nil
		end
	end
end

--[[ Builds the in-world way to ASK. The link pads belong here rather than to PurchaseService:
     standing on one buys nothing, it opens the offer above, and PurchaseService's contract is
     purchases. Listened to on the SERVER, so there is no inbound message to forge (§1.7) -- the
     player and the pad both arrive from the engine. Returns its connections for the owner to hold. ]]
function Controller.AttachPads(self: Controller, sanctum: any, onRequest: (player: any) -> ()): { any }
	local made: { any } = {}
	local runtime = (sanctum :: any).Runtime
	local pads = if type(runtime) == "table" then (runtime :: any).Pads else nil
	if type(pads) ~= "table" then
		return made
	end
	for slot = 1, GameConfig.Plot.SlotsPerSanctum do
		local pad = pads["link:" .. tostring(slot)]
		-- Re-entrancy guard: a second Start must not stack two prompts on one pad, which would open
		-- (and immediately refuse) two offers for a single hold.
		if pad ~= nil and pad:FindFirstChildOfClass("ProximityPrompt") == nil then
			local prompt = Instance.new("ProximityPrompt")
			prompt.ActionText = "Link"
			prompt.ObjectText = "Sanctum " .. tostring((sanctum :: any).Id)
			prompt.RequiresLineOfSight = false
			prompt.MaxActivationDistance = 10
			prompt.HoldDuration = 0
			prompt.Parent = pad
			table.insert(made, prompt.Triggered:Connect(onRequest))
		end
	end
	return made
end

-- Teardown. Outstanding expiry threads survive, but every one of them now finds an empty book.
function Controller.Clear(self: Controller): ()
	table.clear(self._offers)
end

return PlotLinkController
