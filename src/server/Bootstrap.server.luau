--!strict
--[[
	Bootstrap
	The server's entry point and its ONLY wiring: it requires every service module, registers each
	with a ServiceRegistry in dependency order, runs the two boot phases (Init, then Start) and binds
	shutdown to StopAll. It contains no gameplay logic at all -- everything a service needs it gets
	from the registry, so this file stays the one place the boot order is written down.

	The whole boot runs inside a pcall and a failure is refused rather than absorbed: a server that
	came up with, say, PlotService live and EconomyService missing would take real players' sessions
	and mirror broken state into their saves. A server that refuses to start loses one session; a
	server that boots half a game loses accounts.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("GameConfig"))

local Core = script.Parent
local ServiceRegistry = require(Core:WaitForChild("ServiceRegistry"))
local Services = Core:WaitForChild("Services")

--[[ REGISTRATION ORDER IS DEPENDENCY ORDER (spec section 6). Registry:InitAll and :StartAll walk
     this list forwards and :StopAll walks it backwards, so every service is constructed after the
     peers it resolves and torn down before them.

       RateLimiter        nothing
       RemoteService      RateLimiter
       DataStoreWrapper   nothing
       ProfileService     DataStoreWrapper
       EconomyService     ProfileService
       PlotService        ProfileService, EconomyService, RemoteService  (+ PurchaseService, lazily)
       PurchaseService    EconomyService, PlotService, RemoteService
       EvolutionService   PlotService, EconomyService, RemoteService
       RebirthService     PlotService, EconomyService, ProfileService, RemoteService
       LeaderboardService PlotService, ProfileService
       StateReplicator    PlotService, ProfileService, RemoteService, EconomyService

     PlotService is the one forward reference: it needs PurchaseService to build pads, which needs
     PlotService's Sanctums to build them on. That cycle is broken with registry:TryGet inside
     PlotService rather than by reordering, because the pads cannot exist before the plots do. ]]
local ORDER = {
	"RateLimiter",
	"RemoteService",
	"DataStoreWrapper",
	"ProfileService",
	"EconomyService",
	"PlotService",
	"PurchaseService",
	"EvolutionService",
	"RebirthService",
	"LeaderboardService",
	"StateReplicator",
}

local registry = ServiceRegistry.new()

--[[ Names the step that was in flight when something threw. ServiceRegistry's own error already
     lists which service failed Init or Start, but a module that errors at REQUIRE time (a bad
     upvalue, a missing sibling) never reaches the registry at all -- and without this the log would
     show only a stack inside that module with nothing to say which service it belonged to. ]]
local stage = "startup"

local function boot(): ()
	for _, name in ipairs(ORDER) do
		stage = ("require %s"):format(name)
		-- WaitForChild, not FindFirstChild: under Rojo the Services folder streams in as its own
		-- instances, and a nil here would read as "this service does not exist" rather than
		-- "it has not replicated yet".
		local service = require(Services:WaitForChild(name)) :: any
		stage = ("register %s"):format(name)
		registry:Register(name, service)
	end
	--[[ Two phases, never one. Init resolves peers and allocates state, Start connects events and
	     opens loops, so by the time any Start runs EVERY service exists and is initialised -- which
	     is what removes the circular-require problem without a dependency-injection framework. ]]
	stage = "InitAll"
	registry:InitAll()
	stage = "StartAll"
	registry:StartAll()
	stage = "running"
end

local startedAt = os.clock()
local ok, err = pcall(boot)

--[[ Bound AFTER the boot attempt, so ProfileService's own BindToClose (registered during its Start)
     is registered first and its shutdown SaveAll runs before StopAll tears its peers down. Bound
     even on failure: whatever did start still deserves an orderly teardown, and StopAll pcalls every
     Stop, so a service that never finished Init cannot throw out of the shutdown path. ]]
game:BindToClose(function()
	registry:StopAll()
end)

if ok then
	-- One line, and it is the line a live-server operator reads first: what came up, how long it
	-- took, how big the world is, and whether the build is in a debug mode that changes balance.
	print(
		("[Bootstrap] Sanctum of Embers online -- %d services in %.0fms | %d sanctums x %d slots | FastMode=%s Debug=%s | %s"):format(
			#ORDER,
			(os.clock() - startedAt) * 1000,
			GameConfig.Plot.SanctumCount,
			GameConfig.Plot.SlotsPerSanctum,
			tostring(GameConfig.Debug.FastMode),
			tostring(GameConfig.Debug.Enabled),
			table.concat(ORDER, " -> ")
		)
	)
else
	-- Loud and unmissable. The banner exists because this line lands in a log full of ordinary
	-- warnings, and "which service" is the only question worth answering at 3am.
	warn("==================================================================")
	warn(("[Bootstrap] BOOT FAILED during: %s"):format(stage))
	warn(("[Bootstrap] %s"):format(tostring(err)))
	warn("[Bootstrap] The server is NOT running the game. No sanctum will be claimed and no")
	warn("[Bootstrap] profile will be written -- which is deliberate: a half-booted server would")
	warn("[Bootstrap] mirror broken state into real players' saves.")
	warn("==================================================================")
	--[[ Re-raised last, once the warnings are out and BindToClose is bound. Roblox's error telemetry
	     reports errors, not warnings, so without this a broken deploy is invisible on the dashboard;
	     and raising from the entry point is the closest thing available to refusing to start. ]]
	error(("Bootstrap failed during %s: %s"):format(stage, tostring(err)), 0)
end
