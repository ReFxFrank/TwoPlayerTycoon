--!strict
--[[
    SoundController
    Every sound the client can play, behind one deliberate gate: all asset ids live in a single
    table at the top of this file, all of them empty. An empty id makes the play call a silent
    no-op rather than an error, so Sanctum of Embers is fully playable before any audio exists and
    becomes audible the moment the ids are filled in -- with no other file touched.
    Owner: client  |  Consumers: ClientBootstrap (lifecycle), EvolutionFxController, NotifyController
]]
--[[ WHY SILENT-BY-DEFAULT IS THE WHOLE DESIGN (confirmed decision 9.5.7). Inventing plausible
     looking asset ids was rejected: an unverifiable id is either silent anyway or, worse, ships the
     wrong sound confidently. So the wiring is finished -- the toggles, the pool, every cue -- and
     only the ids are outstanding. Nothing downstream needs to know whether audio exists yet.

     WHY A POOL. Purchases fire a cue per click and a player mashing a Wellspring pad can trigger
     several a second. Allocating a Sound per click would churn Instances on the hot path, so a
     fixed ring of voices is created once at Init and reused forever; when every voice is busy the
     oldest is stolen, because a dropped cue is better than an unbounded allocation. ]]

local SoundService = game:GetService("SoundService")

type Context = { Store: any, Remotes: { [string]: any }, Player: any, PlayerGui: any, Ui: any }

local Controller = {}
Controller.Name = "SoundController"

--[[ THE one asset table. Every id is a `rbxassetid://...` string when supplied; each is empty until
     then. Do not scatter ids into the code below -- the silent no-op check reads this table only. ]]
local ASSETS = {
	Music = {
		Ambient = "", -- TODO: asset id -- looping sanctum ambience
	},
	Sfx = {
		Purchase = "", -- TODO: asset id -- a Wellspring/Upgrade/Wing pad was bought
		Attune = "", -- TODO: asset id -- the Conflux reached a new Stage
		Transcend = "", -- TODO: asset id -- the pair Transcended
		Notify = "", -- TODO: asset id -- a toast appeared
		Error = "", -- TODO: asset id -- a refused action
		Collect = "", -- TODO: asset id -- a Mote reached the Conflux Font
	},
}

-- Mix levels, kept out of ASSETS so that table stays exactly "the ids". Collect is the quietest by
-- a wide margin: it can fire many times a second at a built-out Sanctum.
local VOLUME: { [string]: number } = {
	Purchase = 0.35, Attune = 0.60, Transcend = 0.80, Notify = 0.30, Error = 0.40, Collect = 0.12,
}
local MUSIC_VOLUME = 0.22
local DEFAULT_VOLUME = 0.35
local POOL_SIZE = 6 -- enough overlap for a purchase burst, small enough to be free

local connections: { any } = {}
local store: any = nil
local root: any = nil
local music: any = nil
local pool: { any } = {}
local cursor = 0
-- Both default to ON, matching StateSchema's Settings default: the store hands us `true` before the
-- first snapshot arrives, and a player whose profile says otherwise is corrected within a tick.
local musicEnabled = true
local sfxEnabled = true

-- The single definition of "we have an id for this". Anything that is not a non-empty string is a
-- cue that has not been supplied yet.
local function isPlayable(id: any): boolean
	return type(id) == "string" and id ~= ""
end

local function applyMusic(): ()
	if music == nil then
		return
	end
	if musicEnabled and isPlayable(ASSETS.Music.Ambient) then
		music.SoundId = ASSETS.Music.Ambient
		if music.Playing ~= true then
			music:Play()
		end
	elseif music.Playing == true then
		music:Stop()
	end
end

-- Round-robin, preferring an idle voice. Returns nil only if Init never ran, which is the one case
-- where a caller must still not error.
local function nextVoice(): any?
	local size = #pool
	if size == 0 then
		return nil
	end
	for _ = 1, size do
		cursor = (cursor % size) + 1
		local candidate = pool[cursor]
		if candidate ~= nil and candidate.Playing ~= true then
			return candidate
		end
	end
	return pool[cursor]
end

--[[ Play one named cue. Silent (and harmless) for an unknown name, a missing id, a disabled Sfx
     setting or a controller that failed to Init -- every one of those is a normal state, not a
     fault, so none of them warns. ]]
function Controller:PlaySfx(name: string): ()
	if not sfxEnabled then
		return
	end
	local id = if type(name) == "string" then (ASSETS.Sfx :: { [string]: any })[name] else nil
	if not isPlayable(id) then
		return
	end
	local voice = nextVoice()
	if voice == nil then
		return
	end
	voice.SoundId = id
	voice.Volume = VOLUME[name] or DEFAULT_VOLUME
	voice:Play()
end

--[[ Local override for the music bed. It deliberately does NOT fire SetSetting: SettingsController
     owns that remote and the saved preference, and this must stay usable for a momentary duck. ]]
function Controller:SetMusicEnabled(enabled: boolean): ()
	musicEnabled = enabled == true
	applyMusic()
end

function Controller:Init(context: Context): ()
	store = context.Store

	-- One folder so a teardown is a single Destroy and nothing is left parented to SoundService.
	root = Instance.new("Folder")
	root.Name = "SanctumAudio"
	root.Parent = SoundService

	music = Instance.new("Sound")
	music.Name = "Ambient"
	music.Looped = true
	music.Volume = MUSIC_VOLUME
	music.SoundId = ASSETS.Music.Ambient
	music.Parent = root

	for index = 1, POOL_SIZE do
		local voice = Instance.new("Sound")
		voice.Name = "Sfx" .. tostring(index)
		voice.Looped = false
		voice.Volume = DEFAULT_VOLUME
		voice.Parent = root
		pool[index] = voice
	end
end

function Controller:Start(): ()
	if store == nil then
		return
	end

	--[[ `value ~= false` rather than `value == true`: a snapshot that predates the profile load has
	     no You.Settings at all, and the honest default for both switches is on. Only an explicit
	     false silences anything. ]]
	table.insert(connections, store:Observe("You.Settings.Music", function(value: any)
		Controller:SetMusicEnabled(value ~= false)
	end))

	table.insert(connections, store:Observe("You.Settings.Sfx", function(value: any)
		sfxEnabled = value ~= false
		if not sfxEnabled then
			-- Stop in-flight voices too: a player who just turned SFX off should hear silence now,
			-- not after the current cue finishes.
			for _, voice in ipairs(pool) do
				if voice.Playing == true then
					voice:Stop()
				end
			end
		end
	end))
end

function Controller:Stop(): ()
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)

	musicEnabled = false
	applyMusic()
	table.clear(pool)
	cursor = 0
	music = nil
	if root ~= nil then
		root:Destroy()
		root = nil
	end
end

return Controller
