--!strict
--[[
    Format
    Number/time presentation helpers shared by the HUD, prompts, toasts and server log lines so a
    value never renders two different ways in two places. Pure: no services, no Instances.
    Owner: shared  |  Consumers: HudController, PromptController, UiBuilder, NotifyController
]]

local GameConfig = require(script.Parent.GameConfig)

local Format = {}

-- Short-scale suffixes. Index i covers 1000^i, so Dc (decillion) covers [1e33, 1e36).
-- Anything past the table falls back to scientific notation rather than printing garbage.
local SUFFIXES = { "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }

-- WHY: a NaN or inf reaching a TextLabel shows "nan"/"inf" to players and can poison later maths.
-- Every public function funnels through this and degrades to a safe zero instead.
-- Rendered instead of "0" when a number really is infinite; see Format.abbreviate.
local INFINITY = "\u{221E}"

local function isFinite(n: any): boolean
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- Drops the trailing ".00"/".50" zeros the spec asks for, but only when a decimal point exists
-- (naively stripping zeros would turn "1000" into "1").
local function trimZeros(s: string): string
	if string.find(s, "%.", 1) == nil then
		return s
	end
	s = (string.gsub(s, "0+$", ""))
	s = (string.gsub(s, "%.$", ""))
	return s
end

-- Compact scientific form ("1e36", "2.5e40"). Callers already filtered nan/inf, so %e is safe.
local function scientific(n: number): string
	local formatted = string.format("%.2e", n)
	local mantissa, exponent = string.match(formatted, "^(-?%d+%.?%d*)e([+-]%d+)$")
	if mantissa ~= nil and exponent ~= nil then
		-- Drop the exponent's "+" and leading zeros ("e+36" -> "e36") for a tidier label.
		return trimZeros(mantissa) .. "e" .. tostring(tonumber(exponent) or 0)
	end
	return formatted
end

--[[ 0..999 print exactly; above that use two decimals with the suffix table. ]]
function Format.abbreviate(n: number): string
	if not isFinite(n) then
		-- NaN and non-numbers read as 0, but an infinity must NOT: a cost label showing "0" for an
		-- unreachable price would read as free. Economy avoids producing infinities at all; this is
		-- the second line of defence.
		if n == math.huge then
			return INFINITY
		elseif n == -math.huge then
			return "-" .. INFINITY
		end
		return "0"
	end

	local sign = if n < 0 then "-" else ""
	local value = math.abs(n)

	if value < 1000 then
		if value % 1 == 0 then
			-- string.format avoids tostring()'s scientific notation and any float dust.
			return sign .. string.format("%.0f", value)
		end
		return sign .. trimZeros(string.format("%.2f", value))
	end

	-- Repeated division instead of math.log(value, 1000): logs are off by an ulp at exact powers
	-- (log(1e9, 1000) == 2.9999...), which would render 1e9 as "999.99M".
	local index = 0
	while value >= 1000 and index < #SUFFIXES do
		value /= 1000
		index += 1
	end

	-- Rounding to 2dp can push 999.999 up to "1000.00"; promote to the next suffix instead.
	if value >= 999.995 and index < #SUFFIXES then
		value /= 1000
		index += 1
	end

	if value >= 1000 then
		-- Past Dc: no suffix left, so fall back to scientific notation.
		return sign .. scientific(math.abs(n))
	end

	return sign .. trimZeros(string.format("%.2f", value)) .. SUFFIXES[index]
end

--[[ Thousands separators on the whole part, e.g. 1234567 -> "1,234,567". Fractions are truncated:
     comma() is for exact counts (contributions, leaderstats), abbreviate() is for big numbers. ]]
function Format.comma(n: number): string
	if not isFinite(n) then
		if n == math.huge then
			return INFINITY
		elseif n == -math.huge then
			return "-" .. INFINITY
		end
		return "0"
	end

	local sign = if n < 0 then "-" else ""
	local whole = math.floor(math.abs(n))
	local digits = string.format("%.0f", whole)

	while true do
		local replaced: number
		digits, replaced = string.gsub(digits, "^(%d+)(%d%d%d)", "%1,%2")
		if replaced == 0 then
			break
		end
	end
	return sign .. digits
end

--[[ "1h 04m" / "3m 20s" / "12s"; the second unit is zero padded so the label never jitters. ]]
function Format.time(seconds: number): string
	if not isFinite(seconds) or seconds < 0 then
		return "0s"
	end

	local total = math.floor(seconds)
	local days = math.floor(total / 86400)
	local hours = math.floor(total / 3600) % 24
	local minutes = math.floor(total / 60) % 60
	local secs = total % 60

	if days > 0 then
		return string.format("%dd %02dh", days, hours)
	elseif hours > 0 then
		return string.format("%dh %02dm", hours, minutes)
	elseif minutes > 0 then
		return string.format("%dm %02ds", minutes, secs)
	end
	return string.format("%ds", secs)
end

--[[ "x2.35"; trailing zeros are dropped so a clean x2 does not read as "x2.00". ]]
function Format.multiplier(x: number): string
	if not isFinite(x) then
		return "x1"
	end
	if math.abs(x) >= 1000 then
		-- Deep prestige runs can push multipliers into the thousands; reuse the suffix table there.
		return "x" .. Format.abbreviate(x)
	end
	return "x" .. trimZeros(string.format("%.2f", x))
end

function Format.essence(n: number): string
	return GameConfig.Currency.Symbol .. Format.abbreviate(n)
end

--[[ 0.25 -> "25%". Rounded to a whole percent, except tiny non-zero values which would otherwise
     collapse to a misleading "0%". ]]
function Format.percent(x: number): string
	if not isFinite(x) then
		return "0%"
	end
	local scaled = x * 100
	if scaled ~= 0 and math.abs(scaled) < 1 then
		return trimZeros(string.format("%.2f", scaled)) .. "%"
	end
	return string.format("%d%%", math.floor(scaled + 0.5))
end

return Format
