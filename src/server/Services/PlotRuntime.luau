--!strict
--[[
	PlotRuntime
	One Sanctum's live machinery: the Instance tree PlotBuilder made, the DropperSystem emit clock,
	the MoteSystem flight pool, the rail geometry each Wellspring's Motes ride, and the Wing
	visibility that follows PlotState. It turns an emit into a Mote and a landed Mote into a credit,
	and exposes exactly one non-yielding Step for PlotService's shared Heartbeat to call. It knows
	nothing about claims, links, Profiles or the release grace: those are policy, and policy lives in
	the service. Split out of PlotService only to keep both files inside the 300-line budget.
	Owner: server/Services  |  Consumers: PlotService (which owns one per Sanctum)
]]

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local Economy = require(Modules:WaitForChild("Economy"))
local PlotLayout = require(Modules:WaitForChild("PlotLayout"))
local SectionData = require(Modules:WaitForChild("SectionData"))
local StateSchema = require(Modules:WaitForChild("StateSchema"))

local Systems = script.Parent.Parent:WaitForChild("Systems")
local DropperSystem = require(Systems:WaitForChild("DropperSystem"))
local MoteSystem = require(Systems:WaitForChild("MoteSystem"))
local PlotBuilder = require(Systems:WaitForChild("PlotBuilder"))

type PlotState = StateSchema.PlotState
-- Player is `any` here rather than Player: the harness drives a Sanctum with plain tables, and this
-- module only ever passes an occupant's Player straight back to EconomyService.
type Occupant = { UserId: number, Player: any, Slot: number, JoinedAt: number, Contribution: number, Vote: boolean? }
type Sanctum = { Id: number, Model: Instance, State: PlotState, Occupants: { [number]: Occupant },
	AnchorUserId: number?, Runtime: any, Dirty: boolean }
type Connection = { Disconnect: (self: any) -> () }

local PlotRuntime = {}

local Plot = {}
Plot.__index = Plot

type PlotSelf = {
	Sanctum: Sanctum,
	--[[ Release-grace and replication bookkeeping. Written ONLY by PlotService -- they live on this
	     record rather than in a parallel table so a plot is one object, but they are its policy, not
	     this module's: Reserved is who may reclaim the plot, GraceToken lets a claim cancel an armed
	     timer without hunting for its thread, and Announced coalesces SanctumChanged. ]]
	Reserved: { [number]: boolean }, GraceToken: number, Announced: boolean, LastWarn: number,
	_droppers: any, _motes: any, _economy: any,
	_paths: { [string]: { CFrame } },
	_characters: { [number]: Connection }, -- one respawn watch per occupant, dropped when they leave
}
type Plot = typeof(setmetatable({} :: PlotSelf, Plot))

--[[ Cached for the life of the plot: rail geometry is fixed once PlotBuilder has run, and MoteSystem
     borrows the path by reference and never mutates it, so one table serves every Mote a Wellspring
     ever emits. The pad publishes its own (section, order), so this can never drift from the pad
     numbering PlotBuilder invented. ]]
local function railPathFor(self: Plot, def: any): { CFrame }?
	local cached = self._paths[def.Id]
	if cached ~= nil then return cached end
	local runtime = self.Sanctum.Runtime
	local pads = if type(runtime) == "table" then (runtime :: any).Pads else nil
	local pad = if type(pads) == "table" then pads["dropper:" .. tostring(def.Id)] else nil
	if pad == nil then return nil end
	local section = SectionData.get(pad:GetAttribute("PadSection") :: any)
	local order = pad:GetAttribute("PadOrder")
	-- A pad with no usable (section, order) would send PlotLayout arithmetic on nil, inside the
	-- income loop that drives every Sanctum on the server.
	if section == nil or type(order) ~= "number" then return nil end
	local path = PlotLayout.railPath((runtime :: any).Origin, section, order)
	self._paths[def.Id] = path
	return path
end

--[[ Passive income has no single author, so each occupant is credited the share earned WHILE THEY
     WERE PRESENT: a partner who joins for the last five minutes shows a small contribution and the
     player who carried the hour shows a large one, which is the whole point of tracking it next to a
     wallet that is shared (§1.2). It moves no Essence -- AddContribution is leaderboard flavour. ]]
local function shareContribution(self: Plot, credited: any): ()
	if type(credited) ~= "number" or credited <= 0 then return end
	local occupants, count = self.Sanctum.Occupants, 0
	for _ in pairs(occupants) do count += 1 end
	if count == 0 then return end -- a Mote landing on the frame the last occupant left
	local share = credited / count
	for _, occupant in pairs(occupants) do
		self._economy:AddContribution(self.Sanctum, occupant.Player, share)
	end
end

local function emit(self: Plot, def: any): ()
	local path = railPathFor(self, def)
	--[[ No rail means PlotBuilder never gave this Wellspring a pad -- a build bug, not a game state.
	     Following MoteSystem's rule for a malformed path, it is NOT credited: paying for it would
	     hide the bug behind income that still looks correct. ]]
	if path == nil then return end
	local sanctum = self.Sanctum
	local multipliers = self._economy:GetMultipliers(sanctum)
	self._motes:Spawn(def, Economy.getMoteValue(def, sanctum.State, multipliers), path,
		Economy.getRailTravelTime(sanctum.State, multipliers))
end

function PlotRuntime.new(id: number, parent: Instance, economy: any): Plot
	local model, runtime = PlotBuilder.build(id, parent)
	local sanctum: Sanctum = { Id = id, Model = model, State = StateSchema.newPlotState(),
		Occupants = {}, AnchorUserId = nil, Runtime = runtime, Dirty = false }
	local self: Plot = setmetatable({
		Sanctum = sanctum, Reserved = {}, GraceToken = 0, Announced = false, LastWarn = 0,
		_droppers = DropperSystem.new(sanctum), _motes = MoteSystem.new(sanctum),
		_economy = economy, _paths = {}, _characters = {},
	}, Plot)
	self._droppers.OnSpawn:Connect(function(def: any)
		emit(self, def)
	end)
	-- The one place a Mote's value becomes Essence, and it only ASKS: EconomyService owns the wallet.
	self._motes.OnCollected:Connect(function(value: number)
		shareContribution(self, self._economy:Credit(sanctum, value))
	end)
	-- Every Wing but the core starts locked, so the fresh plot must not ship with all five standing.
	self:ApplySections()
	return self
end

--[[ Locked Wings are REPARENTED out of the world by PlotBuilder, which is what makes their pads
     unreachable rather than merely invisible -- PurchaseService then never has to re-check the Wing
     lock on a trigger, because the prompt cannot be reached at all. ]]
function Plot.ApplySections(self: Plot): ()
	local unlocked = self.Sanctum.State.Sections
	for _, section in ipairs(SectionData.List) do
		local visible = section.Id == SectionData.Base or unlocked[section.Id] == true
		PlotBuilder.setSectionVisible(self.Sanctum.Runtime, section.Id, visible)
	end
end

-- NOTHING on this path may yield: it runs inside the one Heartbeat that drives every Sanctum, and a
-- yield there would stall income for the whole server behind one plot's slow call.
function Plot.Step(self: Plot, dt: number): ()
	self._droppers:Step(dt, self._economy:GetMultipliers(self.Sanctum))
	self._motes:Step(dt)
end

-- Re-derives everything downstream of PlotState. Called after a load, a link merge, a purchase, an
-- attunement and a reset -- anything that can change what the Sanctum owns.
function Plot.Rebuild(self: Plot): ()
	self._droppers:Rebuild()
	self:ApplySections()
	self._economy:RefreshMultipliers(self.Sanctum)
end

--[[ Back to a blank Sanctum: the grace window expired, or a claimer took a plot that was counting
     down for somebody else. Motes in flight are DISCARDED rather than credited -- there is no longer
     a wallet that earned them, and the previous pair's progress is already in their Profiles. ]]
function Plot.Reset(self: Plot): ()
	self.Sanctum.State = StateSchema.newPlotState()
	self.Sanctum.AnchorUserId = nil
	self.Reserved = {}
	self._motes:Clear()
	self:Rebuild()
end

--[[ Puts a character on its slot's spawn. Only a BasePart carries a CFrame, and a character mid
     respawn is a Model whose root has not arrived yet -- both are normal, so a missing root simply
     leaves the player where they are rather than erroring inside a join. ]]
function Plot.Seat(self: Plot, player: any, slot: number): ()
	local character = (player :: any).Character
	if character == nil then return end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("Part") then
		root.CFrame = PlotLayout.spawnSlotCFrame((self.Sanctum.Runtime :: any).Origin, slot)
	end
end

--[[ MOCK-EXTRA: Player.CharacterAdded. Without this watch a death respawns the player at the world
     origin, which is Sanctum 1's floor -- i.e. inside a stranger's plot, every time anybody dies. ]]
function Plot.Watch(self: Plot, player: any, userId: number): ()
	self:Unwatch(userId) -- a rejoin must not stack a second watch on the same player
	self._characters[userId] = (player :: any).CharacterAdded:Connect(function()
		-- Re-read rather than capture: by the time a respawn lands, this player may have been
		-- released from the plot entirely, and seating them here would drag them back.
		local occupant = self.Sanctum.Occupants[userId]
		if occupant ~= nil then self:Seat(player, occupant.Slot) end
	end)
end

function Plot.Unwatch(self: Plot, userId: number): ()
	local existing = self._characters[userId]
	if existing ~= nil then
		existing:Disconnect()
		self._characters[userId] = nil
	end
end

function Plot.ClearMotes(self: Plot): ()
	self._motes:Clear()
end

function Plot.MoteCount(self: Plot): number
	return self._motes:Count()
end

function Plot.Destroy(self: Plot): ()
	-- Respawn watches hold a reference to this plot; left connected they would keep seating players
	-- on a Sanctum that no longer exists.
	for userId in pairs(self._characters) do self:Unwatch(userId) end
	self._droppers:Destroy()
	self._motes:Destroy()
	-- PlotBuilder.destroy, not Model:Destroy: locked Wings live OUTSIDE the model and would leak.
	PlotBuilder.destroy(self.Sanctum.Model)
end

--[[ Builds every Sanctum in the world, filling the caller's tables IN PLACE -- PlotSession holds a
     reference to the same list, so replacing it would leave that binding pointing at the previous
     boot's plots. Rebuilt from scratch each time: a leftover folder would leave abandoned Sanctums
     standing in Workspace whose pads still answer a ProximityPrompt, and a re-Init happens both in
     tests and after a failed boot. ]]
function PlotRuntime.buildAll(folderName: string, count: number, plots: { any }, byId: { [number]: any }, economy: any): ()
	local previous = workspace:FindFirstChild(folderName)
	if previous ~= nil then previous:Destroy() end
	local created = Instance.new("Folder")
	created.Name = folderName
	created.Parent = workspace
	for id = 1, count do
		local plot = PlotRuntime.new(id, created, economy)
		table.insert(plots, plot)
		byId[id] = plot
	end
end

return PlotRuntime
