--[[
    Mock/Instances
    A working Instance tree: parenting, children lookup by name, class hierarchy for :IsA,
    attributes, lazily-created signals, Clone/Destroy, and RemoteEvent plumbing that lets one
    process play both server and client.

    Signals here fire SYNCHRONOUSLY (Roblox schedules handlers on fresh threads). Tests need
    deterministic ordering far more than they need fidelity to Roblox's scheduler, and handler
    errors are caught so one bad listener cannot abort a Fire.
]]

local Datatypes = M.Datatypes
local Instances = {}

-- Filled in by Mock/Services once the Players service and remote recorder exist.
Instances.hooks = {
    getLocalPlayer = function() return nil end,
    recordRemote = function() end,
    isServerContext = function() return true end,
}

-------------------------------------------------------------------------------
-- Signal
-------------------------------------------------------------------------------
local SignalMeta = { __type = "RBXScriptSignal" }
SignalMeta.__index = SignalMeta

local function newSignal(name)
    return setmetatable({ _name = name, _handlers = {}, _nextId = 1 }, SignalMeta)
end

function SignalMeta:Connect(handler)
    local id = self._nextId
    self._nextId += 1
    self._handlers[id] = handler
    local connection
    connection = {
        Connected = true,
        Disconnect = function()
            connection.Connected = false
            self._handlers[id] = nil
        end,
    }
    connection.disconnect = connection.Disconnect
    return connection
end
SignalMeta.connect = SignalMeta.Connect

function SignalMeta:Once(handler)
    local connection
    connection = self:Connect(function(...)
        connection:Disconnect()
        handler(...)
    end)
    return connection
end

function SignalMeta:Fire(...)
    -- Iterate a snapshot so a handler may disconnect itself or others mid-fire.
    local ids = {}
    for id in pairs(self._handlers) do
        table.insert(ids, id)
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local handler = self._handlers[id]
        if handler then
            local ok, err = pcall(handler, ...)
            if not ok then
                print(("[mock] signal '%s' handler errored: %s"):format(tostring(self._name), tostring(err)))
            end
        end
    end
end

function SignalMeta:Wait()
    -- Wait() outside a coroutine cannot yield, so the mock returns immediately. Tests that need
    -- real waiting use Mock.advance() plus a Connect.
    return nil
end

function SignalMeta:DisconnectAll()
    self._handlers = {}
end
SignalMeta.Destroy = SignalMeta.DisconnectAll

Instances.newSignal = newSignal

-------------------------------------------------------------------------------
-- Class hierarchy
-------------------------------------------------------------------------------
local SUPERCLASS = {
    Folder = "Instance", Configuration = "Instance", Model = "PVInstance", PVInstance = "Instance",
    BasePart = "PVInstance", Part = "BasePart", MeshPart = "BasePart", WedgePart = "Part",
    SpawnLocation = "Part", Seat = "Part", Terrain = "BasePart",
    GuiBase = "Instance", GuiBase2d = "GuiBase", LayerCollector = "GuiBase2d",
    ScreenGui = "LayerCollector", SurfaceGui = "LayerCollector", BillboardGui = "LayerCollector",
    GuiObject = "GuiBase2d", Frame = "GuiObject", ScrollingFrame = "GuiObject",
    GuiLabel = "GuiObject", TextLabel = "GuiLabel", ImageLabel = "GuiLabel",
    GuiButton = "GuiObject", TextButton = "GuiButton", ImageButton = "GuiButton",
    TextBox = "GuiObject", CanvasGroup = "GuiObject", ViewportFrame = "GuiObject",
    UIBase = "Instance", UIComponent = "UIBase", UILayout = "UIComponent",
    UIListLayout = "UILayout", UIGridLayout = "UILayout", UIPageLayout = "UILayout",
    UIConstraint = "UIComponent", UIAspectRatioConstraint = "UIConstraint",
    UISizeConstraint = "UIConstraint", UITextSizeConstraint = "UIConstraint",
    UICorner = "UIComponent", UIStroke = "UIComponent", UIGradient = "UIComponent",
    UIPadding = "UIComponent", UIScale = "UIComponent",
    ValueBase = "Instance", IntValue = "ValueBase", NumberValue = "ValueBase",
    StringValue = "ValueBase", BoolValue = "ValueBase", ObjectValue = "ValueBase",
    Attachment = "Instance", PointLight = "Instance", SpotLight = "Instance",
    SurfaceLight = "Instance", ParticleEmitter = "Instance", Beam = "Instance",
    Trail = "Instance", Smoke = "Instance", Fire = "Instance", Sparkles = "Instance",
    Sound = "Instance", SoundGroup = "Instance", Highlight = "Instance",
    SpecialMesh = "DataModelMesh", DataModelMesh = "Instance",
    ProximityPrompt = "Instance", ClickDetector = "Instance",
    BaseRemoteEvent = "Instance", RemoteEvent = "BaseRemoteEvent",
    UnreliableRemoteEvent = "BaseRemoteEvent", RemoteFunction = "Instance",
    BindableEvent = "Instance", BindableFunction = "Instance",
    Humanoid = "Instance", Player = "Instance", Team = "Instance",
    Script = "LuaSourceContainer", LocalScript = "LuaSourceContainer",
    ModuleScript = "LuaSourceContainer", LuaSourceContainer = "Instance",
    Camera = "Instance", Tool = "Model", Accessory = "Model",
}

local SIGNAL_NAMES = {
    Changed = true, ChildAdded = true, ChildRemoved = true, DescendantAdded = true,
    DescendantRemoving = true, AncestryChanged = true, Destroying = true,
    Touched = true, TouchEnded = true, Triggered = true, TriggerEnded = true,
    PromptShown = true, PromptHidden = true, PromptButtonHoldBegan = true,
    PromptButtonHoldEnded = true, PromptTriggered = true,
    MouseButton1Click = true, MouseButton1Down = true, MouseButton1Up = true,
    MouseEnter = true, MouseLeave = true, Activated = true, InputBegan = true,
    OnServerEvent = true, OnClientEvent = true, Completed = true, Played = true, Ended = true,
    Died = true, HealthChanged = true, CharacterAdded = true, CharacterRemoving = true,
    PlayerAdded = true, PlayerRemoving = true, Heartbeat = true, Stepped = true,
    RenderStepped = true, PostSimulation = true, PreSimulation = true, PreRender = true,
}

local DEFAULTS = {
    Instance = { Archivable = true },
    BasePart = {
        Anchored = false, CanCollide = true, CanTouch = true, CanQuery = true, Transparency = 0,
        Reflectance = 0, CastShadow = true, Massless = false, TopSurface = 0, BottomSurface = 0,
    },
    GuiObject = {
        Visible = true, BackgroundTransparency = 0, BorderSizePixel = 0, ZIndex = 1,
        ClipsDescendants = false, Active = false,
    },
    ScreenGui = { Enabled = true, ResetOnSpawn = true, IgnoreGuiInset = false, DisplayOrder = 0 },
    ProximityPrompt = {
        ActionText = "Interact", ObjectText = "", HoldDuration = 0, MaxActivationDistance = 10,
        RequiresLineOfSight = true, Enabled = true, KeyboardKeyCode = 0,
    },
    Sound = { Volume = 0.5, Looped = false, Playing = false, PlaybackSpeed = 1, TimePosition = 0 },
    Humanoid = { Health = 100, MaxHealth = 100, WalkSpeed = 16, JumpPower = 50 },
    ValueBase = { Value = 0 },
    StringValue = { Value = "" },
    BoolValue = { Value = false },
    ObjectValue = { Value = nil },
}

local function defaultsFor(className)
    local merged = {}
    local chain = {}
    local current = className
    while current do
        table.insert(chain, 1, current)
        current = SUPERCLASS[current]
    end
    for _, name in ipairs(chain) do
        for key, value in pairs(DEFAULTS[name] or {}) do
            merged[key] = value
        end
    end
    return merged
end

-------------------------------------------------------------------------------
-- Instance
-------------------------------------------------------------------------------
local InstanceMeta = { __type = "Instance" }
local Methods = {}

local allInstances = setmetatable({}, { __mode = "k" })

local function newInstance(className, name)
    local self = setmetatable({}, InstanceMeta)
    rawset(self, "_class", className)
    rawset(self, "_props", defaultsFor(className))
    rawset(self, "_children", {})
    rawset(self, "_signals", {})
    rawset(self, "_attributes", {})
    rawset(self, "_attributeSignals", {})
    rawset(self, "_propertySignals", {})
    rawset(self, "_parent", nil)
    rawset(self, "_destroyed", false)
    self._props.Name = name or className
    -- Class-specific defaults that need datatypes constructed at runtime.
    if className == "Part" or className == "MeshPart" or className == "WedgePart" then
        self._props.Size = Vector3.new(4, 1, 2)
        self._props.Position = Vector3.new(0, 0, 0)
        self._props.CFrame = CFrame.new(0, 0, 0)
        self._props.Color = Color3.fromRGB(163, 162, 165)
        self._props.Material = Enum.Material.Plastic
    elseif className == "Frame" or className == "TextLabel" or className == "TextButton" then
        self._props.Size = UDim2.new(0, 100, 0, 100)
        self._props.Position = UDim2.new(0, 0, 0, 0)
        self._props.AnchorPoint = Vector2.new(0, 0)
        self._props.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        if className ~= "Frame" then
            self._props.Text = "Label"
            self._props.TextColor3 = Color3.fromRGB(0, 0, 0)
            self._props.TextScaled = false
        end
    end
    allInstances[self] = true
    return self
end

local function getSignal(self, name)
    local existing = self._signals[name]
    if existing then return existing end
    local signal = newSignal(("%s.%s"):format(self._props.Name, name))
    self._signals[name] = signal
    return signal
end
Instances.getSignal = getSignal

InstanceMeta.__index = function(self, key)
    local method = Methods[key]
    if method then return method end
    local props = rawget(self, "_props")
    if props[key] ~= nil then return props[key] end
    if key == "Parent" then return rawget(self, "_parent") end
    if key == "ClassName" then return rawget(self, "_class") end
    if SIGNAL_NAMES[key] then return getSignal(self, key) end
    -- Roblox falls back to a child of that name.
    for _, child in ipairs(rawget(self, "_children")) do
        if child._props.Name == key then return child end
    end
    return nil
end

local function setParent(self, parent)
    local old = rawget(self, "_parent")
    if old == parent then return end
    if old then
        for index, child in ipairs(old._children) do
            if child == self then
                table.remove(old._children, index)
                break
            end
        end
        getSignal(old, "ChildRemoved"):Fire(self)
    end
    rawset(self, "_parent", parent)
    if parent then
        table.insert(parent._children, self)
        getSignal(parent, "ChildAdded"):Fire(self)
        local ancestor = parent
        while ancestor do
            getSignal(ancestor, "DescendantAdded"):Fire(self)
            ancestor = rawget(ancestor, "_parent")
        end
    end
    getSignal(self, "AncestryChanged"):Fire(self, parent)
end

--[[ Roblox VALIDATES every property assignment and throws on a type mismatch; a permissive mock does
     not, and that difference turns a green suite into a dead server. A real example from this
     project: a refactor left BasePart.Material assigned from a nil global. All 304 tests stayed
     green and the shipped place file would not have booted -- PlotService:Init would have thrown
     "Unable to assign property Material. EnumItem expected, got nil".

     Deliberately a SHORTLIST, not a property database. Every entry is one whose wrong-typing is
     easy to introduce and fatal in Roblox. Unknown properties stay permissive, because the
     alternative is a mock that must be taught every property before a test can use one. ]]
local PROPERTY_TYPES: { [string]: string } = {
    Material = "EnumItem", Color = "Color3",
    CFrame = "CFrame",
    Anchored = "boolean", CanCollide = "boolean", CanTouch = "boolean", CanQuery = "boolean",
    Transparency = "number", Reflectance = "number", CastShadow = "boolean",
    Name = "string", Text = "string", Visible = "boolean", Enabled = "boolean",
    TextColor3 = "Color3", BackgroundColor3 = "Color3", TextScaled = "boolean",
    BackgroundTransparency = "number", ZIndex = "number", TextSize = "number",
    AnchorPoint = "Vector2",
    WalkSpeed = "number", Volume = "number", Looped = "boolean",
    ActionText = "string", ObjectText = "string", HoldDuration = "number",
    MaxActivationDistance = "number", RequiresLineOfSight = "boolean",
    Range = "number", Brightness = "number",
}

--- Size and Position are Vector3 on a BasePart and UDim2 on a GuiObject, so the expected type is
--- resolved from the instance rather than from the property name alone.
local function expectedTypeFor(instance, key)
    if key == "Size" or key == "Position" then
        if instance:IsA("BasePart") then
            return "Vector3"
        elseif instance:IsA("GuiObject") then
            return "UDim2"
        end
        return nil
    end
    return PROPERTY_TYPES[key]
end

InstanceMeta.__newindex = function(self, key, value)
    if key == "Parent" then
        setParent(self, value)
        return
    end
    local expected = expectedTypeFor(self, key)
    if expected ~= nil and typeof(value) ~= expected then
        error(("Unable to assign property %s. %s expected, got %s"):format(
            key, expected, typeof(value)), 2)
    end
    local props = rawget(self, "_props")
    local previous = props[key]
    props[key] = value
    if key == "CFrame" and rawget(self, "_class") ~= nil then
        props.Position = value and value.Position or props.Position
    elseif key == "Position" and SUPERCLASS[rawget(self, "_class")] == "BasePart" then
        props.CFrame = CFrame.new(value.X, value.Y, value.Z)
    end
    if previous ~= value then
        local propertySignal = rawget(self, "_propertySignals")[key]
        if propertySignal then propertySignal:Fire() end
        local changed = rawget(self, "_signals").Changed
        if changed then changed:Fire(key) end
    end
end

InstanceMeta.__tostring = function(self) return rawget(self, "_props").Name end

function Methods:IsA(className)
    local current = rawget(self, "_class")
    while current do
        if current == className then return true end
        current = SUPERCLASS[current]
    end
    return className == "Instance"
end

function Methods:GetChildren()
    local copy = {}
    for index, child in ipairs(rawget(self, "_children")) do copy[index] = child end
    return copy
end

function Methods:GetDescendants()
    local out = {}
    local function walk(node)
        for _, child in ipairs(rawget(node, "_children")) do
            table.insert(out, child)
            walk(child)
        end
    end
    walk(self)
    return out
end

function Methods:FindFirstChild(name, recursive)
    for _, child in ipairs(rawget(self, "_children")) do
        if child._props.Name == name then return child end
    end
    if recursive then
        for _, child in ipairs(rawget(self, "_children")) do
            local found = child:FindFirstChild(name, true)
            if found then return found end
        end
    end
    return nil
end

function Methods:FindFirstChildOfClass(className)
    for _, child in ipairs(rawget(self, "_children")) do
        if rawget(child, "_class") == className then return child end
    end
    return nil
end
Methods.FindFirstChildWhichIsA = function(self, className)
    for _, child in ipairs(rawget(self, "_children")) do
        if child:IsA(className) then return child end
    end
    return nil
end

function Methods:FindFirstAncestor(name)
    local parent = rawget(self, "_parent")
    while parent do
        if parent._props.Name == name then return parent end
        parent = rawget(parent, "_parent")
    end
    return nil
end

function Methods:WaitForChild(name, timeout)
    local existing = self:FindFirstChild(name)
    if existing then return existing end
    -- On the mock's main thread task.wait fast-forwards the clock, which lets deferred creation
    -- run; bound the spin so a genuinely missing child fails the test instead of hanging it.
    local deadline = timeout or 5
    local waited = 0
    while waited < deadline do
        task.wait(1 / 30)
        waited += 1 / 30
        existing = self:FindFirstChild(name)
        if existing then return existing end
    end
    return nil
end

function Methods:ClearAllChildren()
    for _, child in ipairs(self:GetChildren()) do child:Destroy() end
end

function Methods:Destroy()
    if rawget(self, "_destroyed") then return end
    rawset(self, "_destroyed", true)
    local destroying = rawget(self, "_signals").Destroying
    if destroying then destroying:Fire() end
    for _, child in ipairs(self:GetChildren()) do child:Destroy() end
    setParent(self, nil)
    for _, signal in pairs(rawget(self, "_signals")) do signal:DisconnectAll() end
end
Methods.Remove = Methods.Destroy

function Methods:Clone()
    local copy = newInstance(rawget(self, "_class"), rawget(self, "_props").Name)
    for key, value in pairs(rawget(self, "_props")) do copy._props[key] = value end
    for key, value in pairs(rawget(self, "_attributes")) do copy._attributes[key] = value end
    for _, child in ipairs(rawget(self, "_children")) do
        local childCopy = child:Clone()
        childCopy.Parent = copy
    end
    return copy
end

function Methods:SetAttribute(name, value)
    rawget(self, "_attributes")[name] = value
    local signal = rawget(self, "_attributeSignals")[name]
    if signal then signal:Fire() end
end

function Methods:GetAttribute(name) return rawget(self, "_attributes")[name] end

function Methods:GetAttributes()
    local copy = {}
    for key, value in pairs(rawget(self, "_attributes")) do copy[key] = value end
    return copy
end

function Methods:GetAttributeChangedSignal(name)
    local signals = rawget(self, "_attributeSignals")
    if not signals[name] then signals[name] = newSignal("attr:" .. name) end
    return signals[name]
end

function Methods:GetPropertyChangedSignal(name)
    local signals = rawget(self, "_propertySignals")
    if not signals[name] then signals[name] = newSignal("prop:" .. name) end
    return signals[name]
end

function Methods:GetFullName()
    local names, node = {}, self
    while node do
        table.insert(names, 1, rawget(node, "_props").Name)
        node = rawget(node, "_parent")
    end
    return table.concat(names, ".")
end

function Methods:IsDescendantOf(ancestor)
    local node = rawget(self, "_parent")
    while node do
        if node == ancestor then return true end
        node = rawget(node, "_parent")
    end
    return false
end

function Methods:PivotTo(cf) rawget(self, "_props").WorldPivot = cf end
function Methods:GetPivot() return rawget(self, "_props").WorldPivot or CFrame.new(0, 0, 0) end
function Methods:SetPrimaryPartCFrame(cf) self:PivotTo(cf) end
function Methods:ScaleTo(_) end
function Methods:Play() rawget(self, "_props").Playing = true end
function Methods:Stop() rawget(self, "_props").Playing = false end
function Methods:Pause() rawget(self, "_props").Playing = false end
function Methods:Resume() rawget(self, "_props").Playing = true end
function Methods:Emit(_) end

-- RemoteEvent plumbing: one process hosts both sides, so FireClient only reaches OnClientEvent
-- when the target is the simulated LocalPlayer. Everything is recorded for assertions.
function Methods:FireClient(player, ...)
    Instances.hooks.recordRemote(rawget(self, "_props").Name, player, { ... })
    if Instances.hooks.getLocalPlayer() == player then
        getSignal(self, "OnClientEvent"):Fire(...)
    end
end

function Methods:FireAllClients(...)
    Instances.hooks.recordRemote(rawget(self, "_props").Name, nil, { ... })
    getSignal(self, "OnClientEvent"):Fire(...)
end

function Methods:FireServer(...)
    getSignal(self, "OnServerEvent"):Fire(Instances.hooks.getLocalPlayer(), ...)
end

Instances.newInstance = newInstance
Instances.allInstances = allInstances
-- Exported so Mock/Services can bolt on class-specific methods (Player:Kick, etc).
Instances.Methods = Methods
Instances.SUPERCLASS = SUPERCLASS

local ENV = getfenv(1)
ENV.Instance = {
    new = function(className, parent)
        local created = newInstance(className)
        if parent then created.Parent = parent end
        return created
    end,
}

M.Instances = Instances
