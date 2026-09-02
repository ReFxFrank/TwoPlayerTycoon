--[[
    Mock/Datatypes
    Pure-Luau stand-ins for the Roblox datatype library: Vector2/3, CFrame (with a real 3x3
    rotation basis and quaternion Lerp), Color3, UDim/UDim2, BrickColor, TweenInfo, the sequence
    types, Random and a permissive lazy Enum tree.

    These are value types in Roblox (userdata) but tables here, so `typeof` is replaced with a
    metatable-aware version — production code that branches on typeof still behaves correctly.
]]

local Datatypes = {}

local rawTypeof = typeof

local function defineType(name)
    local meta = { __type = name }
    return meta
end

local function typeOf(value)
    if type(value) == "table" then
        local meta = getmetatable(value)
        if meta and rawget(meta, "__type") then
            return meta.__type
        end
    end
    return rawTypeof(value)
end

-------------------------------------------------------------------------------
-- Vector2
-------------------------------------------------------------------------------
local Vector2Meta = defineType("Vector2")
local function newVector2(x, y)
    return setmetatable({ X = x or 0, Y = y or 0 }, Vector2Meta)
end
Vector2Meta.__index = function(self, key)
    if key == "Magnitude" then
        return math.sqrt(self.X * self.X + self.Y * self.Y)
    elseif key == "Unit" then
        local m = math.sqrt(self.X * self.X + self.Y * self.Y)
        return newVector2(self.X / m, self.Y / m)
    end
    return nil
end
Vector2Meta.__add = function(a, b) return newVector2(a.X + b.X, a.Y + b.Y) end
Vector2Meta.__sub = function(a, b) return newVector2(a.X - b.X, a.Y - b.Y) end
Vector2Meta.__mul = function(a, b)
    if type(b) == "number" then return newVector2(a.X * b, a.Y * b) end
    if type(a) == "number" then return newVector2(b.X * a, b.Y * a) end
    return newVector2(a.X * b.X, a.Y * b.Y)
end
Vector2Meta.__eq = function(a, b) return a.X == b.X and a.Y == b.Y end
Vector2Meta.__tostring = function(self) return ("%g, %g"):format(self.X, self.Y) end

-------------------------------------------------------------------------------
-- Vector3
-------------------------------------------------------------------------------
local Vector3Meta = defineType("Vector3")
local Vector3Methods = {}
local function newVector3(x, y, z)
    return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vector3Meta)
end
Vector3Meta.__index = function(self, key)
    if key == "Magnitude" then
        return math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
    elseif key == "Unit" then
        local m = math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
        if m == 0 then return newVector3(0, 0, 0) end
        return newVector3(self.X / m, self.Y / m, self.Z / m)
    end
    return Vector3Methods[key]
end
Vector3Meta.__add = function(a, b) return newVector3(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
Vector3Meta.__sub = function(a, b) return newVector3(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
Vector3Meta.__unm = function(a) return newVector3(-a.X, -a.Y, -a.Z) end
Vector3Meta.__mul = function(a, b)
    if type(b) == "number" then return newVector3(a.X * b, a.Y * b, a.Z * b) end
    if type(a) == "number" then return newVector3(b.X * a, b.Y * a, b.Z * a) end
    return newVector3(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
Vector3Meta.__div = function(a, b)
    if type(b) == "number" then return newVector3(a.X / b, a.Y / b, a.Z / b) end
    return newVector3(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
Vector3Meta.__eq = function(a, b) return a.X == b.X and a.Y == b.Y and a.Z == b.Z end
Vector3Meta.__tostring = function(self) return ("%g, %g, %g"):format(self.X, self.Y, self.Z) end
function Vector3Methods:Dot(other) return self.X * other.X + self.Y * other.Y + self.Z * other.Z end
function Vector3Methods:Cross(other)
    return newVector3(
        self.Y * other.Z - self.Z * other.Y,
        self.Z * other.X - self.X * other.Z,
        self.X * other.Y - self.Y * other.X
    )
end
function Vector3Methods:Lerp(other, alpha)
    return newVector3(
        self.X + (other.X - self.X) * alpha,
        self.Y + (other.Y - self.Y) * alpha,
        self.Z + (other.Z - self.Z) * alpha
    )
end
function Vector3Methods:FuzzyEq(other, epsilon)
    epsilon = epsilon or 1e-5
    return math.abs(self.X - other.X) <= epsilon
        and math.abs(self.Y - other.Y) <= epsilon
        and math.abs(self.Z - other.Z) <= epsilon
end

-------------------------------------------------------------------------------
-- CFrame: position + row-major 3x3 rotation basis (r11..r33, matching GetComponents order).
-------------------------------------------------------------------------------
local CFrameMeta = defineType("CFrame")
local CFrameMethods = {}

local function newCFrameRaw(px, py, pz, r11, r12, r13, r21, r22, r23, r31, r32, r33)
    return setmetatable({
        _p = newVector3(px, py, pz),
        r11 = r11, r12 = r12, r13 = r13,
        r21 = r21, r22 = r22, r23 = r23,
        r31 = r31, r32 = r32, r33 = r33,
    }, CFrameMeta)
end

local function identityAt(px, py, pz)
    return newCFrameRaw(px, py, pz, 1, 0, 0, 0, 1, 0, 0, 0, 1)
end

CFrameMeta.__index = function(self, key)
    if key == "Position" or key == "p" then
        return self._p
    elseif key == "X" then return self._p.X
    elseif key == "Y" then return self._p.Y
    elseif key == "Z" then return self._p.Z
    elseif key == "LookVector" then return newVector3(-self.r13, -self.r23, -self.r33)
    elseif key == "RightVector" then return newVector3(self.r11, self.r21, self.r31)
    elseif key == "UpVector" then return newVector3(self.r12, self.r22, self.r32)
    elseif key == "Rotation" then
        return newCFrameRaw(0, 0, 0, self.r11, self.r12, self.r13, self.r21, self.r22, self.r23, self.r31, self.r32, self.r33)
    end
    return CFrameMethods[key]
end

local function multiplyCFrames(a, b)
    local bp = b._p
    local px = a.r11 * bp.X + a.r12 * bp.Y + a.r13 * bp.Z + a._p.X
    local py = a.r21 * bp.X + a.r22 * bp.Y + a.r23 * bp.Z + a._p.Y
    local pz = a.r31 * bp.X + a.r32 * bp.Y + a.r33 * bp.Z + a._p.Z
    return newCFrameRaw(px, py, pz,
        a.r11 * b.r11 + a.r12 * b.r21 + a.r13 * b.r31,
        a.r11 * b.r12 + a.r12 * b.r22 + a.r13 * b.r32,
        a.r11 * b.r13 + a.r12 * b.r23 + a.r13 * b.r33,
        a.r21 * b.r11 + a.r22 * b.r21 + a.r23 * b.r31,
        a.r21 * b.r12 + a.r22 * b.r22 + a.r23 * b.r32,
        a.r21 * b.r13 + a.r22 * b.r23 + a.r23 * b.r33,
        a.r31 * b.r11 + a.r32 * b.r21 + a.r33 * b.r31,
        a.r31 * b.r12 + a.r32 * b.r22 + a.r33 * b.r32,
        a.r31 * b.r13 + a.r32 * b.r23 + a.r33 * b.r33)
end

CFrameMeta.__mul = function(a, b)
    if typeOf(b) == "Vector3" then
        return newVector3(
            a.r11 * b.X + a.r12 * b.Y + a.r13 * b.Z + a._p.X,
            a.r21 * b.X + a.r22 * b.Y + a.r23 * b.Z + a._p.Y,
            a.r31 * b.X + a.r32 * b.Y + a.r33 * b.Z + a._p.Z)
    end
    return multiplyCFrames(a, b)
end
CFrameMeta.__add = function(a, v) return newCFrameRaw(a._p.X + v.X, a._p.Y + v.Y, a._p.Z + v.Z,
    a.r11, a.r12, a.r13, a.r21, a.r22, a.r23, a.r31, a.r32, a.r33) end
CFrameMeta.__sub = function(a, v) return a + (-v) end
CFrameMeta.__eq = function(a, b) return a._p == b._p and a.r11 == b.r11 and a.r22 == b.r22 and a.r33 == b.r33 end
CFrameMeta.__tostring = function(self) return ("%g, %g, %g"):format(self._p.X, self._p.Y, self._p.Z) end

function CFrameMethods:GetComponents()
    return self._p.X, self._p.Y, self._p.Z, self.r11, self.r12, self.r13,
        self.r21, self.r22, self.r23, self.r31, self.r32, self.r33
end
function CFrameMethods:Inverse()
    -- Rotation is orthonormal, so its inverse is its transpose.
    local ix = -(self.r11 * self._p.X + self.r21 * self._p.Y + self.r31 * self._p.Z)
    local iy = -(self.r12 * self._p.X + self.r22 * self._p.Y + self.r32 * self._p.Z)
    local iz = -(self.r13 * self._p.X + self.r23 * self._p.Y + self.r33 * self._p.Z)
    return newCFrameRaw(ix, iy, iz, self.r11, self.r21, self.r31, self.r12, self.r22, self.r32,
        self.r13, self.r23, self.r33)
end
function CFrameMethods:ToWorldSpace(other) return multiplyCFrames(self, other) end
function CFrameMethods:ToObjectSpace(other) return multiplyCFrames(self:Inverse(), other) end
function CFrameMethods:PointToWorldSpace(v) return self * v end
function CFrameMethods:PointToObjectSpace(v) return self:Inverse() * v end
function CFrameMethods:VectorToWorldSpace(v)
    return newVector3(self.r11 * v.X + self.r12 * v.Y + self.r13 * v.Z,
        self.r21 * v.X + self.r22 * v.Y + self.r23 * v.Z,
        self.r31 * v.X + self.r32 * v.Y + self.r33 * v.Z)
end

local function toQuaternion(cf)
    local trace = cf.r11 + cf.r22 + cf.r33
    if trace > 0 then
        local s = math.sqrt(trace + 1) * 2
        return (cf.r32 - cf.r23) / s, (cf.r13 - cf.r31) / s, (cf.r21 - cf.r12) / s, 0.25 * s
    elseif cf.r11 > cf.r22 and cf.r11 > cf.r33 then
        local s = math.sqrt(1 + cf.r11 - cf.r22 - cf.r33) * 2
        return 0.25 * s, (cf.r12 + cf.r21) / s, (cf.r13 + cf.r31) / s, (cf.r32 - cf.r23) / s
    elseif cf.r22 > cf.r33 then
        local s = math.sqrt(1 + cf.r22 - cf.r11 - cf.r33) * 2
        return (cf.r12 + cf.r21) / s, 0.25 * s, (cf.r23 + cf.r32) / s, (cf.r13 - cf.r31) / s
    end
    local s = math.sqrt(1 + cf.r33 - cf.r11 - cf.r22) * 2
    return (cf.r13 + cf.r31) / s, (cf.r23 + cf.r32) / s, 0.25 * s, (cf.r21 - cf.r12) / s
end

local function fromQuaternion(px, py, pz, x, y, z, w)
    local length = math.sqrt(x * x + y * y + z * z + w * w)
    if length == 0 then return identityAt(px, py, pz) end
    x, y, z, w = x / length, y / length, z / length, w / length
    return newCFrameRaw(px, py, pz,
        1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w),
        2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w),
        2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y))
end

function CFrameMethods:Lerp(goal, alpha)
    local p = self._p:Lerp(goal._p, alpha)
    local ax, ay, az, aw = toQuaternion(self)
    local bx, by, bz, bw = toQuaternion(goal)
    if ax * bx + ay * by + az * bz + aw * bw < 0 then
        bx, by, bz, bw = -bx, -by, -bz, -bw -- take the short way round
    end
    return fromQuaternion(p.X, p.Y, p.Z,
        ax + (bx - ax) * alpha, ay + (by - ay) * alpha,
        az + (bz - az) * alpha, aw + (bw - aw) * alpha)
end

local CFrame = {}
function CFrame.new(a, b, c, ...)
    if a == nil then return identityAt(0, 0, 0) end
    if typeOf(a) == "Vector3" then
        if typeOf(b) == "Vector3" then return CFrame.lookAt(a, b) end
        return identityAt(a.X, a.Y, a.Z)
    end
    local extra = { ... }
    if #extra >= 9 then
        return newCFrameRaw(a, b, c, extra[1], extra[2], extra[3], extra[4], extra[5], extra[6],
            extra[7], extra[8], extra[9])
    end
    return identityAt(a or 0, b or 0, c or 0)
end
CFrame.identity = identityAt(0, 0, 0)
function CFrame.lookAt(from, look, up)
    up = up or newVector3(0, 1, 0)
    local forward = (look - from)
    if forward.Magnitude < 1e-6 then return identityAt(from.X, from.Y, from.Z) end
    forward = forward.Unit
    local right = forward:Cross(up)
    if right.Magnitude < 1e-6 then right = forward:Cross(newVector3(0, 0, 1)) end
    right = right.Unit
    local realUp = right:Cross(forward)
    -- Roblox stores -forward in the third basis column, hence LookVector = -r13,-r23,-r33.
    return newCFrameRaw(from.X, from.Y, from.Z,
        right.X, realUp.X, -forward.X,
        right.Y, realUp.Y, -forward.Y,
        right.Z, realUp.Z, -forward.Z)
end
function CFrame.Angles(rx, ry, rz)
    local cx, sx = math.cos(rx), math.sin(rx)
    local cy, sy = math.cos(ry), math.sin(ry)
    local cz, sz = math.cos(rz), math.sin(rz)
    return newCFrameRaw(0, 0, 0,
        cy * cz, -cy * sz, sy,
        sx * sy * cz + cx * sz, -sx * sy * sz + cx * cz, -sx * cy,
        -cx * sy * cz + sx * sz, cx * sy * sz + sx * cz, cx * cy)
end
CFrame.fromEulerAnglesXYZ = CFrame.Angles
CFrame.fromEulerAnglesYXZ = CFrame.Angles

-------------------------------------------------------------------------------
-- Color3 / BrickColor
-------------------------------------------------------------------------------
local Color3Meta = defineType("Color3")
local Color3Methods = {}
local function newColor3(r, g, b)
    return setmetatable({ R = r or 0, G = g or 0, B = b or 0 }, Color3Meta)
end
Color3Meta.__index = Color3Methods
Color3Meta.__eq = function(a, b) return a.R == b.R and a.G == b.G and a.B == b.B end
Color3Meta.__tostring = function(self) return ("%g, %g, %g"):format(self.R, self.G, self.B) end
function Color3Methods:Lerp(other, alpha)
    return newColor3(self.R + (other.R - self.R) * alpha, self.G + (other.G - self.G) * alpha,
        self.B + (other.B - self.B) * alpha)
end
function Color3Methods:ToHex()
    return ("%02X%02X%02X"):format(math.floor(self.R * 255 + 0.5), math.floor(self.G * 255 + 0.5),
        math.floor(self.B * 255 + 0.5))
end
local Color3 = {}
Color3.new = newColor3
function Color3.fromRGB(r, g, b) return newColor3((r or 0) / 255, (g or 0) / 255, (b or 0) / 255) end
function Color3.fromHSV(h, s, v)
    local i = math.floor(h * 6)
    local f = h * 6 - i
    local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
    local m = i % 6
    if m == 0 then return newColor3(v, t, p) elseif m == 1 then return newColor3(q, v, p)
    elseif m == 2 then return newColor3(p, v, t) elseif m == 3 then return newColor3(p, q, v)
    elseif m == 4 then return newColor3(t, p, v) end
    return newColor3(v, p, q)
end
Color3.fromHex = function(hex)
    hex = hex:gsub("#", "")
    return Color3.fromRGB(tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16))
end

local BrickColorMeta = defineType("BrickColor")
local BrickColor = {}
function BrickColor.new(a, b, c)
    local color = typeOf(a) == "Color3" and a or (type(a) == "number" and b and newColor3(a, b, c) or newColor3(0.6, 0.6, 0.6))
    return setmetatable({ Name = type(a) == "string" and a or "Medium stone grey", Color = color }, BrickColorMeta)
end
function BrickColor.random() return BrickColor.new("Bright red") end

-------------------------------------------------------------------------------
-- UDim / UDim2
-------------------------------------------------------------------------------
local UDimMeta = defineType("UDim")
local function newUDim(scale, offset)
    return setmetatable({ Scale = scale or 0, Offset = offset or 0 }, UDimMeta)
end
UDimMeta.__index = UDimMeta
UDimMeta.__add = function(a, b) return newUDim(a.Scale + b.Scale, a.Offset + b.Offset) end
UDimMeta.__eq = function(a, b) return a.Scale == b.Scale and a.Offset == b.Offset end

local UDim2Meta = defineType("UDim2")
local UDim2Methods = {}
local function newUDim2(sx, ox, sy, oy)
    if typeOf(sx) == "UDim" then
        return setmetatable({ X = sx, Y = ox }, UDim2Meta)
    end
    return setmetatable({ X = newUDim(sx or 0, ox or 0), Y = newUDim(sy or 0, oy or 0) }, UDim2Meta)
end
UDim2Meta.__index = UDim2Methods
UDim2Meta.__add = function(a, b) return newUDim2(a.X + b.X, a.Y + b.Y) end
UDim2Meta.__eq = function(a, b) return a.X == b.X and a.Y == b.Y end
function UDim2Methods:Lerp(other, alpha)
    return newUDim2(
        newUDim(self.X.Scale + (other.X.Scale - self.X.Scale) * alpha,
            self.X.Offset + (other.X.Offset - self.X.Offset) * alpha),
        newUDim(self.Y.Scale + (other.Y.Scale - self.Y.Scale) * alpha,
            self.Y.Offset + (other.Y.Offset - self.Y.Offset) * alpha))
end
local UDim2 = { new = newUDim2 }
function UDim2.fromScale(x, y) return newUDim2(x, 0, y, 0) end
function UDim2.fromOffset(x, y) return newUDim2(0, x, 0, y) end

-------------------------------------------------------------------------------
-- Enum: lazy and permissive. Any Enum.Category.Item resolves and is reference-stable.
-------------------------------------------------------------------------------
local EnumItemMeta = defineType("EnumItem")
local EnumMeta = defineType("Enum")
local enumCategories = {}

local function getCategory(name)
    local existing = enumCategories[name]
    if existing then return existing end
    local items = {}
    local nextValue = 0
    local category
    category = setmetatable({}, {
        __type = "Enum",
        __index = function(_, itemName)
            if itemName == "GetEnumItems" then
                return function()
                    local list = {}
                    for _, item in pairs(items) do table.insert(list, item) end
                    table.sort(list, function(a, b) return a.Value < b.Value end)
                    return list
                end
            end
            local item = items[itemName]
            if not item then
                item = setmetatable({ Name = itemName, Value = nextValue, EnumType = category },
                    EnumItemMeta)
                nextValue += 1
                items[itemName] = item
            end
            return item
        end,
        __tostring = function() return "Enum." .. name end,
    })
    enumCategories[name] = category
    return category
end
EnumItemMeta.__index = EnumItemMeta
EnumItemMeta.__tostring = function(self) return ("Enum.%s.%s"):format(tostring(self.EnumType), self.Name) end

local Enum = setmetatable({}, {
    __type = "Enums",
    __index = function(_, categoryName) return getCategory(categoryName) end,
})

-------------------------------------------------------------------------------
-- Misc value types
-------------------------------------------------------------------------------
local TweenInfoMeta = defineType("TweenInfo")
local TweenInfo = {}
function TweenInfo.new(time, style, direction, repeatCount, reverses, delayTime)
    return setmetatable({
        Time = time or 1, EasingStyle = style, EasingDirection = direction,
        RepeatCount = repeatCount or 0, Reverses = reverses or false, DelayTime = delayTime or 0,
    }, TweenInfoMeta)
end

local NumberSequenceKeypointMeta = defineType("NumberSequenceKeypoint")
local function newNumberSequenceKeypoint(t, value, envelope)
    return setmetatable({ Time = t, Value = value, Envelope = envelope or 0 }, NumberSequenceKeypointMeta)
end
local NumberSequenceMeta = defineType("NumberSequence")
local NumberSequence = {}
function NumberSequence.new(a, b)
    local keypoints = type(a) == "table" and getmetatable(a) == nil and a
        or { newNumberSequenceKeypoint(0, a or 0), newNumberSequenceKeypoint(1, b or a or 0) }
    return setmetatable({ Keypoints = keypoints }, NumberSequenceMeta)
end

local ColorSequenceKeypointMeta = defineType("ColorSequenceKeypoint")
local function newColorSequenceKeypoint(t, value)
    return setmetatable({ Time = t, Value = value }, ColorSequenceKeypointMeta)
end
local ColorSequenceMeta = defineType("ColorSequence")
local ColorSequence = {}
function ColorSequence.new(a, b)
    local keypoints = type(a) == "table" and getmetatable(a) == nil and a
        or { newColorSequenceKeypoint(0, a), newColorSequenceKeypoint(1, b or a) }
    return setmetatable({ Keypoints = keypoints }, ColorSequenceMeta)
end

local RandomMeta = defineType("Random")
RandomMeta.__index = RandomMeta
local Random = {}
function Random.new(seed)
    -- Deterministic LCG so seeded runs are reproducible across machines.
    return setmetatable({ _state = (seed or 1) % 2147483647 }, RandomMeta)
end
function RandomMeta:_next()
    self._state = (self._state * 1103515245 + 12345) % 2147483648
    return self._state / 2147483648
end
function RandomMeta:NextNumber(min, max)
    local value = self:_next()
    if min == nil then return value end
    return min + value * (max - min)
end
function RandomMeta:NextInteger(min, max)
    return math.floor(self:NextNumber(min, max + 1))
end

-----------------------------------------------------------------------------------------------------------------------------------------------------------
-- Install globals.
--
-- These are written through getfenv() rather than by bare assignment: several of the library
-- tables above are declared `local`, so `CFrame = CFrame` would silently assign the local to
-- itself and never reach the chunk environment the game modules read from.
-------------------------------------------------------------------------------
local ENV = getfenv(1)

ENV.Vector2 = { new = newVector2, zero = newVector2(0, 0), one = newVector2(1, 1) }
ENV.Vector3 = {
    new = newVector3, zero = newVector3(0, 0, 0), one = newVector3(1, 1, 1),
    xAxis = newVector3(1, 0, 0), yAxis = newVector3(0, 1, 0), zAxis = newVector3(0, 0, 1),
}
ENV.CFrame = CFrame
ENV.Color3 = Color3
ENV.BrickColor = BrickColor
ENV.UDim = { new = newUDim }
ENV.UDim2 = UDim2
ENV.Enum = Enum
ENV.TweenInfo = TweenInfo
ENV.NumberSequence = NumberSequence
ENV.NumberSequenceKeypoint = { new = newNumberSequenceKeypoint }
ENV.ColorSequence = ColorSequence
ENV.ColorSequenceKeypoint = { new = newColorSequenceKeypoint }
ENV.Random = Random
ENV.typeof = typeOf

Datatypes.typeOf = typeOf
Datatypes.newVector3 = newVector3
Datatypes.newColor3 = newColor3
Datatypes.CFrame = CFrame
Datatypes.identityAt = identityAt
M.Datatypes = Datatypes
