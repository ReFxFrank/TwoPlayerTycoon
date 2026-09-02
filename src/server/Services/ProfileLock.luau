--!strict
--[[
    ProfileLock
    The session-lock protocol: how a stored record encodes ownership of a player's save, and when a
    lock may be taken. Split out of ProfileService to keep that file inside the 300-line budget, and
    because this is the part whose reasoning most needs to sit in one place -- get it wrong in one
    direction and a crashed server locks a player out of their own account forever; get it wrong in
    the other and two servers write one profile.
    Owner: server  |  Consumers: ProfileService
]]

local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local GameConfig = require(Modules:WaitForChild("GameConfig"))

local SAVE, SESSION = GameConfig.Save, GameConfig.Session

export type Lock = { JobId: string, Stamp: number }

local ProfileLock = {}
-- The identity this server claims locks under. game.JobId is empty in Studio, so a stable
-- fallback keeps a Studio session from colliding with a real one.
ProfileLock.JobId = if game.JobId ~= nil and #game.JobId > 0 then game.JobId else "studio-local"

function ProfileLock.keyFor(player: Player): string return SAVE.KeyPrefix .. tostring(player.UserId) end

--[[ The stored value is { Lock = {JobId, Stamp}, Data = Profile }. A raw legacy Profile (written by
     a build predating the lock) has no Data field and is read as unlocked data, so an old save is
     adopted rather than mistaken for garbage and overwritten. ]]
function ProfileLock.unwrap(raw: any): (Lock?, any)
	if type(raw) ~= "table" then return nil, nil end
	local stored = raw :: { [string]: any }
	if type(stored.Data) ~= "table" then return nil, raw end
	local lock = stored.Lock
	if type(lock) ~= "table" or type(lock.JobId) ~= "string" or type(lock.Stamp) ~= "number" then
		-- A malformed or absent lock is no lock. Refusing to load over a half-written lock record
		-- would strand the player for LockStaleSeconds over a value we can simply replace.
		return nil, stored.Data
	end
	return { JobId = lock.JobId, Stamp = lock.Stamp }, stored.Data
end

--[[ A lock blocks a load only while it is live AND belongs to someone else.
     WHY a stale lock MUST be stealable: a server that crashes never runs its release-save, so its
     lock is left behind forever. Without the steal, one crash locks that player out of their own
     save permanently -- the account becomes unloadable. The steal is the repair for a dead server.
     WHY the window must sit well above the autosave interval: every save refreshes the stamp, so a
     live session's lock is never older than one autosave period (120s +/-20s). LockStaleSeconds is
     900 -- seven autosaves of slack -- so a laggy but living server is never mistaken for a dead
     one. A window near or below the autosave period would steal locks from LIVE sessions and let
     two servers write one profile: exactly the corruption the lock exists to prevent. ]]
function ProfileLock.blocks(lock: Lock?, now: number): boolean
	if lock == nil or lock.JobId == ProfileLock.JobId then return false end -- unlocked, or ours (a rejoin here)
	return (now - lock.Stamp) <= SESSION.LockStaleSeconds
end

return ProfileLock
