--[[
    Mock/Json
    Minimal JSON encoder/decoder backing the mocked HttpService. Roblox's implementation is native;
    this one only needs to round-trip the plain tables our save data uses (no userdata, no cycles).
]]

local Json = {}

local ESCAPES = {
    ['"'] = '\\"',
    ["\\"] = "\\\\",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
}

local function escape(str: string): string
    return (str:gsub('[%c"\\]', function(c)
        return ESCAPES[c] or string.format("\\u%04x", string.byte(c))
    end))
end

local function isArray(t)
    local n = 0
    for key in pairs(t) do
        if type(key) ~= "number" then
            return false
        end
        n += 1
    end
    return n == #t
end

local function encodeValue(value, out)
    local kind = type(value)
    if value == nil then
        table.insert(out, "null")
    elseif kind == "boolean" then
        table.insert(out, tostring(value))
    elseif kind == "number" then
        -- JSON has no NaN/inf; Roblox errors on them, and so do we (callers must sanitise first).
        if value ~= value or value == math.huge or value == -math.huge then
            error("cannot encode non-finite number", 0)
        end
        if value == math.floor(value) and math.abs(value) < 1e15 then
            table.insert(out, string.format("%d", value))
        else
            table.insert(out, string.format("%.14g", value))
        end
    elseif kind == "string" then
        table.insert(out, '"' .. escape(value) .. '"')
    elseif kind == "table" then
        if isArray(value) then
            table.insert(out, "[")
            for index, item in ipairs(value) do
                if index > 1 then
                    table.insert(out, ",")
                end
                encodeValue(item, out)
            end
            table.insert(out, "]")
        else
            table.insert(out, "{")
            local keys = {}
            for key in pairs(value) do
                table.insert(keys, key)
            end
            -- Sort by the rendered key so output is stable regardless of hash order. Keys stay in
            -- their original type here, so `false` and numeric-keyed values encode correctly.
            table.sort(keys, function(a, b)
                return tostring(a) < tostring(b)
            end)
            for index, key in ipairs(keys) do
                if index > 1 then
                    table.insert(out, ",")
                end
                table.insert(out, '"' .. escape(tostring(key)) .. '":')
                encodeValue(value[key], out)
            end
            table.insert(out, "}")
        end
    else
        error("cannot encode value of type " .. kind, 0)
    end
end

function Json.encode(value): string
    local out = {}
    encodeValue(value, out)
    return table.concat(out)
end

local Decoder = {}
Decoder.__index = Decoder

local function newDecoder(text)
    return setmetatable({ text = text, pos = 1 }, Decoder)
end

function Decoder:skip()
    while self.pos <= #self.text and self.text:sub(self.pos, self.pos):match("%s") do
        self.pos += 1
    end
end

function Decoder:expect(char)
    if self.text:sub(self.pos, self.pos) ~= char then
        error(("expected '%s' at %d"):format(char, self.pos), 0)
    end
    self.pos += 1
end

function Decoder:parseString()
    self:expect('"')
    local buffer = {}
    while true do
        local char = self.text:sub(self.pos, self.pos)
        if char == "" then
            error("unterminated string", 0)
        end
        self.pos += 1
        if char == '"' then
            break
        elseif char == "\\" then
            local escaped = self.text:sub(self.pos, self.pos)
            self.pos += 1
            if escaped == "n" then
                table.insert(buffer, "\n")
            elseif escaped == "t" then
                table.insert(buffer, "\t")
            elseif escaped == "r" then
                table.insert(buffer, "\r")
            elseif escaped == "b" then
                table.insert(buffer, "\b")
            elseif escaped == "f" then
                table.insert(buffer, "\f")
            elseif escaped == "u" then
                local hex = self.text:sub(self.pos, self.pos + 3)
                self.pos += 4
                table.insert(buffer, utf8.char(tonumber(hex, 16) or 63))
            else
                table.insert(buffer, escaped)
            end
        else
            table.insert(buffer, char)
        end
    end
    return table.concat(buffer)
end

function Decoder:parseValue()
    self:skip()
    local char = self.text:sub(self.pos, self.pos)
    if char == "{" then
        self.pos += 1
        local result = {}
        self:skip()
        if self.text:sub(self.pos, self.pos) == "}" then
            self.pos += 1
            return result
        end
        while true do
            self:skip()
            local key = self:parseString()
            self:skip()
            self:expect(":")
            result[key] = self:parseValue()
            self:skip()
            local next = self.text:sub(self.pos, self.pos)
            self.pos += 1
            if next == "}" then
                return result
            elseif next ~= "," then
                error("expected ',' or '}'", 0)
            end
        end
    elseif char == "[" then
        self.pos += 1
        local result = {}
        self:skip()
        if self.text:sub(self.pos, self.pos) == "]" then
            self.pos += 1
            return result
        end
        while true do
            table.insert(result, self:parseValue())
            self:skip()
            local next = self.text:sub(self.pos, self.pos)
            self.pos += 1
            if next == "]" then
                return result
            elseif next ~= "," then
                error("expected ',' or ']'", 0)
            end
        end
    elseif char == '"' then
        return self:parseString()
    elseif self.text:sub(self.pos, self.pos + 3) == "true" then
        self.pos += 4
        return true
    elseif self.text:sub(self.pos, self.pos + 4) == "false" then
        self.pos += 5
        return false
    elseif self.text:sub(self.pos, self.pos + 3) == "null" then
        self.pos += 4
        return nil
    end
    local numberText = self.text:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", self.pos)
    if not numberText then
        error("unexpected character at " .. self.pos, 0)
    end
    self.pos += #numberText
    return tonumber(numberText)
end

function Json.decode(text: string)
    local decoder = newDecoder(text)
    local value = decoder:parseValue()
    return value
end

M.Json = Json
