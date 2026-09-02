--!strict
--[[
    TableUtil
    Pure table helpers used across every layer: copying (cycle-safe), merging, key/value extraction,
    list transforms and deep comparison. No services, no Instances -- safe on client, server and in
    the headless test harness.
    Owner: shared  |  Consumers: StateSchema, ClientStore, ProfileService, PlotService, UiBuilder
]]

local TableUtil = {}

type AnyTable = { [any]: any }

-- WHY the identity map: PlotState snapshots and runtime tables can contain shared sub-tables (and,
-- during development, accidental cycles). Copying with a `seen` map preserves the original object
-- graph exactly and makes a cyclic input terminate instead of overflowing the stack.
local function copyValue(value: any, seen: AnyTable): any
	if type(value) ~= "table" then
		-- Numbers/strings/booleans are immutable; userdata (Color3, Vector3, CFrame, Enum items) is
		-- immutable in Roblox too, so both are copied BY REFERENCE. Never touch their metatables.
		return value
	end

	local existing = seen[value]
	if existing ~= nil then
		return existing
	end

	local copy: AnyTable = {}
	seen[value] = copy
	for key, item in pairs(value) do
		-- Keys are NOT deep-copied: a copied table-key would be unreachable via the original key.
		copy[key] = copyValue(item, seen)
	end

	-- Share the metatable by reference so class-like tables keep their behaviour; deep-copying a
	-- metatable would duplicate methods for no benefit. Guard against __metatable-protected tables,
	-- where getmetatable returns a non-table.
	local meta = getmetatable(value :: any)
	if type(meta) == "table" then
		setmetatable(copy, meta)
	end
	return copy
end

function TableUtil.deepCopy<T>(t: T): T
	if type(t) ~= "table" then
		return t
	end
	return copyValue(t, {}) :: any
end

function TableUtil.shallowCopy<T>(t: T): T
	if type(t) ~= "table" then
		return t
	end
	return (table.clone(t :: any) :: any)
end

-- Returns a NEW table: base with patch applied. Nested plain tables are merged recursively so a
-- patch like { Plot = { Essence = 5 } } does not wipe the rest of Plot; array-like tables and
-- userdata are replaced wholesale (there is no sane element-wise merge for ordered data).
function TableUtil.merge(base: AnyTable?, patch: AnyTable?): AnyTable
	local result: AnyTable = {}
	if type(base) == "table" then
		for key, value in pairs(base :: AnyTable) do
			result[key] = TableUtil.deepCopy(value)
		end
	end
	if type(patch) == "table" then
		for key, value in pairs(patch :: AnyTable) do
			local current = result[key]
			if type(value) == "table" and type(current) == "table" and not TableUtil.isArray(value) then
				result[key] = TableUtil.merge(current :: AnyTable, value :: AnyTable)
			else
				result[key] = TableUtil.deepCopy(value)
			end
		end
	end
	return result
end

function TableUtil.count(t: AnyTable?): number
	if type(t) ~= "table" then
		return 0
	end
	local n = 0
	for _ in pairs(t :: AnyTable) do
		n += 1
	end
	return n
end

function TableUtil.keys(t: AnyTable?): { any }
	local out: { any } = {}
	if type(t) ~= "table" then
		return out
	end
	for key in pairs(t :: AnyTable) do
		table.insert(out, key)
	end
	return out
end

function TableUtil.values(t: AnyTable?): { any }
	local out: { any } = {}
	if type(t) ~= "table" then
		return out
	end
	for _, value in pairs(t :: AnyTable) do
		table.insert(out, value)
	end
	return out
end

-- Deterministic key order. WHY a default comparator: table.sort errors on mixed key types, and
-- dictionaries keyed by both strings and numbers do occur (Theme.Stage is numeric, ids are strings).
function TableUtil.sortedKeys(t: AnyTable?, comparator: ((a: any, b: any) -> boolean)?): { any }
	local out = TableUtil.keys(t)
	local compare = comparator
		or function(a: any, b: any): boolean
			local ta, tb = type(a), type(b)
			if ta ~= tb then
				return ta < tb
			end
			if ta == "number" or ta == "string" then
				return (a :: any) < (b :: any)
			end
			return tostring(a) < tostring(b)
		end
	table.sort(out, compare)
	return out
end

function TableUtil.isEmpty(t: AnyTable?): boolean
	if type(t) ~= "table" then
		return true
	end
	return next(t :: AnyTable) == nil
end

-- True for a contiguous 1..n integer-keyed table. An empty table counts as an array, which is what
-- callers merging/serialising state want.
function TableUtil.isArray(t: any): boolean
	if type(t) ~= "table" then
		return false
	end
	local length = #t
	local seen = 0
	for key in pairs(t) do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > length then
			return false
		end
		seen += 1
	end
	return seen == length
end

function TableUtil.find<V>(list: { V }?, predicate: (value: V, index: number) -> boolean): (V?, number?)
	if type(list) ~= "table" or type(predicate) ~= "function" then
		return nil, nil
	end
	for index, value in ipairs(list :: { V }) do
		if predicate(value, index) then
			return value, index
		end
	end
	return nil, nil
end

function TableUtil.map<V, R>(list: { V }?, fn: (value: V, index: number) -> R): { R }
	local out: { R } = {}
	if type(list) ~= "table" or type(fn) ~= "function" then
		return out
	end
	for index, value in ipairs(list :: { V }) do
		out[index] = fn(value, index)
	end
	return out
end

function TableUtil.filter<V>(list: { V }?, fn: (value: V, index: number) -> boolean): { V }
	local out: { V } = {}
	if type(list) ~= "table" or type(fn) ~= "function" then
		return out
	end
	for index, value in ipairs(list :: { V }) do
		if fn(value, index) then
			table.insert(out, value)
		end
	end
	return out
end

function TableUtil.reduce<V, A>(list: { V }?, fn: (acc: A, value: V, index: number) -> A, init: A): A
	local acc = init
	if type(list) ~= "table" or type(fn) ~= "function" then
		return acc
	end
	for index, value in ipairs(list :: { V }) do
		acc = fn(acc, value, index)
	end
	return acc
end

-- Structural equality. Userdata (Color3/Vector3) compares with ==, which Roblox defines by value.
-- The `seen` pair-map makes cyclic inputs terminate: a pair already being compared is assumed equal
-- (standard co-inductive equality) rather than recursing forever.
local function deepEquals(a: any, b: any, seen: AnyTable): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end

	local pairsForA = seen[a]
	if pairsForA ~= nil and pairsForA[b] then
		return true
	end
	if pairsForA == nil then
		pairsForA = {}
		seen[a] = pairsForA
	end
	pairsForA[b] = true

	for key, value in pairs(a) do
		if not deepEquals(value, (b :: AnyTable)[key], seen) then
			return false
		end
	end
	for key in pairs(b) do
		if (a :: AnyTable)[key] == nil then
			return false
		end
	end
	return true
end

function TableUtil.deepEquals(a: any, b: any): boolean
	return deepEquals(a, b, {})
end

return TableUtil
