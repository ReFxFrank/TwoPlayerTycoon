--!strict
--[[
    Validate
    Defensive type/shape predicates. Everything crossing a trust boundary -- client remote payloads
    and DataStore reads -- passes through here first. Every function is total: it accepts ANY input
    (nil, userdata, functions, cyclic tables) and returns a value instead of erroring, because a
    thrown error inside a remote handler is itself a denial-of-service vector.
    Owner: shared  |  Consumers: RemoteSchema, RemoteService, StateSchema, ProfileService
]]

local Validate = {}

-- Accepted field kinds for Validate.payload shapes. A trailing "?" marks the field optional.
local KIND_CHECKS: { [string]: (value: any) -> boolean } = {}

function Validate.isNumber(v: any): boolean
	return type(v) == "number"
end

-- Rejects nan and +/-inf as well as non-numbers. Anything that reaches arithmetic on state must be
-- finite: nan poisons every comparison it touches (nan >= 0 is false, so clamps silently fail).
function Validate.isFiniteNumber(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

function Validate.isString(v: any): boolean
	return type(v) == "string"
end

function Validate.isBoolean(v: any): boolean
	return type(v) == "boolean"
end

function Validate.isTable(v: any): boolean
	return type(v) == "table"
end

-- Contiguous 1..n integer keys (an empty table qualifies).
function Validate.isArray(v: any): boolean
	if type(v) ~= "table" then
		return false
	end
	local length = #v
	local seen = 0
	for key in pairs(v) do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > length then
			return false
		end
		seen += 1
	end
	return seen == length
end

-- Ids (dropper/upgrade/section/affinity) are word characters only: they end up in attribute names,
-- Instance names and DataStore payloads, so punctuation and spaces are rejected outright.
function Validate.isId(v: any): boolean
	if type(v) ~= "string" then
		return false
	end
	local length = #v
	if length < 1 or length > 64 then
		return false
	end
	return string.match(v, "^[%w_]+$") ~= nil
end

--[[ Returns a guaranteed-finite number inside [min, max]. Non-numbers, nan and inf collapse to
     `default` (itself clamped), so callers can use the result without a second check. ]]
function Validate.clampNumber(v: any, min: number, max: number, default: number): number
	local low = if Validate.isFiniteNumber(min) then min else -math.huge
	local high = if Validate.isFiniteNumber(max) then max else math.huge
	if low > high then
		low, high = high, low -- tolerate swapped bounds instead of erroring inside math.clamp
	end

	local fallback = if Validate.isFiniteNumber(default) then default else 0
	fallback = math.max(low, math.min(high, fallback))

	if not Validate.isFiniteNumber(v) then
		return fallback
	end
	return math.max(low, math.min(high, v :: number))
end

-- `set` is used as a lookup table (e.g. AffinityData.ById), so membership is `set[v] ~= nil`.
function Validate.stringOneOf(v: any, set: { [string]: any }): boolean
	if type(v) ~= "string" or type(set) ~= "table" then
		return false
	end
	return (set :: { [string]: any })[v] ~= nil
end

KIND_CHECKS["number"] = Validate.isFiniteNumber
KIND_CHECKS["string"] = Validate.isString
KIND_CHECKS["boolean"] = Validate.isBoolean
KIND_CHECKS["id"] = Validate.isId
KIND_CHECKS["table"] = Validate.isTable

--[[ Exact shape check for remote payloads.
     shape = { Accept = "boolean", Affinity = "id", Data = "table?" }
     Rules: every required field present and of the right kind, and NO unexpected extra keys -- an
     attacker padding a payload with junk must be rejected, not silently trimmed. An empty shape
     means "no payload": nil or an empty table. ]]
local function checkPayload(value: any, shape: any): (boolean, string?)
	if type(shape) ~= "table" then
		return false, "invalid shape"
	end

	local expected = 0
	for _ in pairs(shape) do
		expected += 1
	end

	if expected == 0 then
		if value == nil then
			return true, nil
		end
		if type(value) ~= "table" or next(value) ~= nil then
			return false, "expected no payload"
		end
		return true, nil
	end

	if type(value) ~= "table" then
		return false, "expected a table payload"
	end

	for field, kind in pairs(shape) do
		if type(field) ~= "string" then
			return false, "invalid shape key"
		end
		if type(kind) ~= "string" then
			return false, "invalid shape kind for " .. field
		end

		local optional = string.sub(kind, -1) == "?"
		local baseKind = if optional then string.sub(kind, 1, -2) else kind
		local check = KIND_CHECKS[baseKind]
		if check == nil then
			return false, "unknown shape kind '" .. baseKind .. "'"
		end

		local given = (value :: { [string]: any })[field]
		if given == nil then
			if not optional then
				return false, "missing field '" .. field .. "'"
			end
		elseif not check(given) then
			return false, "field '" .. field .. "' expected " .. baseKind
		end
	end

	-- Reject extras. Iterating only the top level keeps this O(fields) and cycle-proof.
	for field in pairs(value :: { [any]: any }) do
		if type(field) ~= "string" or (shape :: { [string]: any })[field] == nil then
			return false, "unexpected field '" .. tostring(field) .. "'"
		end
	end

	return true, nil
end

function Validate.payload(value: any, shape: any): (boolean, string?)
	-- pcall is the belt to checkPayload's braces: even a pathological input (protected metatable,
	-- __index that errors) can only ever produce `false` here, never an error out of a remote.
	local ok, result, reason = pcall(checkPayload, value, shape)
	if not ok then
		return false, "payload rejected"
	end
	return result == true, reason
end

return Validate
