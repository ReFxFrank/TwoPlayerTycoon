--!strict
--[[
    PrestigeAward
    What a Transcendence pays one player: the rebirth count, the multiplier cached from it, the
    milestone badges and the banked lifetime total.

    Split out of RebirthService to keep that file inside the 300-line budget, and because this is the
    only code in the game that writes the one thing a player cannot re-earn -- worth having behind a
    single named function rather than inline in a 70-line Execute.
    Owner: server  |  Consumers: RebirthService
]]

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local Economy = require(Modules:WaitForChild("Economy"))
local RebirthData = require(Modules:WaitForChild("RebirthData"))

local MAX_CURRENCY = 1e15

local function currency(v: any): number
	if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return 0 end
	return math.clamp(v, 0, MAX_CURRENCY)
end

local PrestigeAward = {}

--- Credits one Transcendence to `prestige` (a Profile.Prestige table), banking `banked` essence.
--- Total: a malformed or missing Prestige table is left alone rather than erroring mid-payout.
function PrestigeAward.pay(prestige: any, banked: number): ()
	if type(prestige) ~= "table" then return end
	local rebirths = math.clamp(math.floor(currency(prestige.Rebirths)) + 1, 0, RebirthData.MaxTrackedRebirths)
	prestige.Rebirths = rebirths
	-- Recomputed, never incremented: the stored multiplier is a cache of the count, and one bad write
	-- would otherwise become a permanent income bonus.
	prestige.Multiplier = Economy.getPrestigeMultiplier(rebirths)
	-- badgesFor returns the FULL earned set, so merging it in also self-heals an award lost to a
	-- failed save. Merged into, never replaced: a hand-granted badge survives.
	if type(prestige.Badges) ~= "table" then prestige.Badges = {} end
	for id, earned in pairs(RebirthData.badgesFor(rebirths)) do
		if earned then (prestige.Badges :: { [string]: boolean })[id] = true end
	end
	prestige.TotalTranscended = math.min(currency(prestige.TotalTranscended) + currency(banked), MAX_CURRENCY)
end

return PrestigeAward
