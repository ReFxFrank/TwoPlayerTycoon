--!strict
--[[
    ProfileAutosave
    The per-player autosave loop, and the jitter that keeps a full server from writing on one frame.

    Split out of ProfileService for the 300-line ceiling. It is a real seam: this is the only
    background writer in the game, and the two conditions that must stop it -- the server shutting
    down, and the player having left -- are the ones the ghost-profile bug turned out to hinge on.
    Owner: server  |  Consumers: ProfileService
]]

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local GameConfig = require(Modules:WaitForChild("GameConfig"))

local SAVE = GameConfig.Save
local MIN_AUTOSAVE_SECONDS = 5 -- a floor, so a misconfigured interval cannot hammer the DataStore

-- Its own RNG, so autosave jitter never perturbs the global math.random sequence that mote paths and
-- other systems draw from -- which would make their tests non-reproducible.
local rng = Random.new(os.time())

local ProfileAutosave = {}

--- Starts the loop for `entry`. `stillOurs` is re-asked after every park: it must return false once
--- the server has stopped or this entry is no longer the live one for its player.
function ProfileAutosave.start(entry: any, save: (any) -> (), stillOurs: (any) -> boolean): ()
	if entry.Autosave then return end -- a second thread would double this player's write rate
	entry.Autosave = true
	task.spawn(function()
		while entry.Autosave and stillOurs(entry) do
			-- The +/- jitter IS the stagger: players who joined on the same frame land up to 2 x
			-- AutosaveJitter (40s) apart, and re-rolling each cycle stops them re-converging. A fixed
			-- period would have all twelve occupants of a full server writing on one frame.
			local jitter = rng:NextNumber(-SAVE.AutosaveJitter, SAVE.AutosaveJitter)
			task.wait(math.max(SAVE.AutosaveSeconds + jitter, MIN_AUTOSAVE_SECONDS))
			-- Re-checked after the park: the player may have left, or the server stopped, while this
			-- thread slept, and saving a released profile would retake a lock nobody holds.
			if not entry.Autosave or not stillOurs(entry) then break end
			save(entry.Player)
		end
		entry.Autosave = false
	end)
end

return ProfileAutosave
