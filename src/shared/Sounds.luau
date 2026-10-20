--!strict
-- Every sound effect in the game: Creator Store audio (all public, free, checked to load in
-- Studio) with its volume and how far it carries. Sounds parented to a part play in 3D from it;
-- parented to SoundService or a GUI they play flat (the phone ringer).
--
-- Rolloff is InverseTapered: full volume within `near` studs, fading to silence at `far`.

local ContentProvider = game:GetService("ContentProvider")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")

local Sounds = {}

export type Def = {
	id: string,
	volume: number,
	near: number?,
	far: number?,
	looped: boolean?,
	-- one-shots: cut off after this many seconds (with a short fade), for clips with long tails
	length: number?,
}

-- the fade at the end of a cut-off one-shot
local CUT_FADE = 0.15

local DEFS: { [string]: Def } = {
	-- engine loop (Roblox Resources "Car-Engine-Loop"); pitch follows speed and throttle
	Engine = { id = "rbxassetid://80317022777602", volume = 0.45, near = 12, far = 220, looped = true },
	-- tyres on the ground, one loop per kind of surface
	RollPaved = { id = "rbxassetid://6560398360", volume = 0.25, near = 10, far = 120, looped = true },
	RollDirt = { id = "rbxassetid://9126157444", volume = 0.45, near = 10, far = 140, looped = true },
	RollGrass = { id = "rbxassetid://100303349931924", volume = 0.5, near = 10, far = 110, looped = true },
	RollSand = { id = "rbxassetid://9118029227", volume = 0.5, near = 10, far = 110, looped = true },
	-- braking hard or skidding
	Screech = { id = "rbxassetid://109487442763183", volume = 0.6, near = 15, far = 260, looped = true },
	-- police wail, carries a long way
	Siren = { id = "rbxassetid://4832498807", volume = 0.6, near = 30, far = 600, looped = true },
	-- crashes, short and loud from the first frame: one for hitting another car, one for anything
	-- else solid (buildings, trees, rocks)
	CrashCar = { id = "rbxassetid://7340406550", volume = 1.1, near = 20, far = 350, length = 0.7 },
	CrashBuilding = { id = "rbxassetid://102683443968763", volume = 0.8, near = 20, far = 350, length = 0.6 },
	-- cargo: a box slid into the boot at the pickup, set down at the dropoff
	CargoLoad = { id = "rbxassetid://9113721416", volume = 0.9, near = 10, far = 90 },
	CargoUnload = { id = "rbxassetid://9117939398", volume = 0.9, near = 10, far = 90 },
	-- surf on the beach
	Waves = { id = "rbxassetid://9119677305", volume = 0.7, near = 40, far = 300, looped = true },
	-- phone notification ringer (flat, not 3D)
	PhoneRing = { id = "rbxassetid://127205266270030", volume = 0.5 },
}
Sounds.Defs = DEFS

-- A Sound set up from its definition, not playing yet.
function Sounds.make(name: string, parent: Instance): Sound
	local def = DEFS[name]
	assert(def, `unknown sound {name}`)
	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = def.id
	sound.Volume = def.volume
	sound.Looped = def.looped == true
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = def.near or 10
	sound.RollOffMaxDistance = def.far or 200
	sound.Parent = parent
	return sound
end

-- Plays a one-shot sound from `parent` and cleans it up afterwards. `loudness` scales the
-- volume and `pitch` sets the playback speed (a little variety stops repeats sounding canned).
function Sounds.play(name: string, parent: Instance, loudness: number?, pitch: number?): Sound
	local sound = Sounds.make(name, parent)
	sound.Volume *= loudness or 1
	sound.PlaybackSpeed = pitch or 1
	sound:Play()
	local length = DEFS[name].length
	if length then
		local seconds = length / sound.PlaybackSpeed
		task.delay(math.max(0, seconds - CUT_FADE), function()
			if sound.Parent then
				TweenService:Create(sound, TweenInfo.new(CUT_FADE), { Volume = 0 }):Play()
			end
		end)
		Debris:AddItem(sound, seconds + 0.05)
	end
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	-- in case it never loads or ends
	Debris:AddItem(sound, 15)
	return sound
end

-- Loads every sound up front so the first crash or ring plays the moment it happens instead of
-- waiting for the download. Yields; call it from a spawned thread.
function Sounds.preload()
	local holder = Instance.new("Folder")
	local list = {}
	for name in DEFS do
		local sound = Sounds.make(name, holder)
		table.insert(list, sound)
	end
	ContentProvider:PreloadAsync(list)
	holder:Destroy()
end

return Sounds
