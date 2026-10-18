--!strict
-- Local-only car sounds for every car near the camera, all 3D from the car's chassis:
--   * engine: pitch rises with speed; pulling hard sounds louder and higher than coasting
--   * tyres: a different loop on pavement, dirt, grass and sand, louder the faster the car goes
--   * a tyre screech when braking hard or sliding sideways
--   * the police siren while a patrol car's Siren attribute is on
--   * crashes: a sudden knock plays a sound for what the car hit (another car, a tree or rock,
--     a building or anything else built)
-- The local player's own throttle comes from their seat; for other cars (AI cars are simulated
-- on the server) it's read from how the car is speeding up. Nothing here replicates.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Sounds = require(ReplicatedStorage.Shared.Sounds)
local VehiclePhysics = require(ReplicatedStorage.Shared.VehiclePhysics)

local CarSoundController = {}

-- cars further than this from the camera are silent (sirens carry further)
local RANGE = 260
local SIREN_RANGE = 600
local SURFACE_INTERVAL = 0.2
-- which tyre loop plays on each surface
local ROLL_SOUNDS: { [string]: string } = {
	asphalt = "RollPaved",
	concrete = "RollPaved",
	paved = "RollPaved",
	dirt = "RollDirt",
	grass = "RollGrass",
	sand = "RollSand",
}
-- slowing faster than this (studs/s²) above SCREECH_MIN_SPEED screeches; so does a slide
local SCREECH_DECEL = 45
local SCREECH_MIN_SPEED = 18
local SCREECH_SLIDE = 16
-- a change in horizontal velocity this big between frames is a crash
local CRASH_DELTA_V = 20
local CRASH_COOLDOWN = 0.7

type CarSound = {
	car: Model,
	chassis: BasePart,
	maxSpeed: number,
	engine: Sound?,
	rolls: { [string]: Sound },
	screech: Sound?,
	siren: Sound?,
	surface: string,
	nextSurfaceCheck: number,
	lastVelocity: Vector3,
	lastVelocityAt: number,
	accel: number,
	load: number,
	screechLevel: number,
	lastCrash: number,
	active: boolean,
}

local cars: { [Model]: CarSound } = {}
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = false
local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude
overlapParams.RespectCanCollide = true

local player = game:GetService("Players").LocalPlayer

local function engineRunning(car: Model): boolean
	if car:GetAttribute("Traffic") == true or car:GetAttribute("VehicleType") == "Police" then
		return true
	end
	local seat = car:FindFirstChild("DriverSeat")
	return seat ~= nil and seat:IsA("VehicleSeat") and seat.Occupant ~= nil
end

-- The local player's throttle when they're driving this car, else nil.
local function ownThrottle(car: Model): number?
	local seat = car:FindFirstChild("DriverSeat")
	if not seat or not seat:IsA("VehicleSeat") then
		return nil
	end
	local occupant = seat.Occupant
	if occupant and occupant.Parent == player.Character then
		return seat.ThrottleFloat
	end
	return nil
end

local function stopAll(fx: CarSound)
	for _, sound in { fx.engine, fx.screech, fx.siren } do
		if sound and sound.Playing then
			sound:Stop()
		end
	end
	for _, sound in fx.rolls do
		if sound.Playing then
			sound:Stop()
		end
	end
end

-- Keeps a looped sound playing at `volume`, or stopped when it's (nearly) silent.
local function hold(sound: Sound, volume: number)
	sound.Volume = volume
	if volume > 0.01 then
		if not sound.Playing then
			sound:Play()
		end
	elseif sound.Playing then
		sound:Stop()
	end
end

---------------------------------------------------------------------------------------------------
-- Crashes
---------------------------------------------------------------------------------------------------

local NATURE_NAMES = { "Tree", "Rock", "Bush", "Trunk", "Canopy", "Leaves", "Stump", "Log" }

local function isNature(instance: Instance): boolean
	local node: Instance? = instance
	while node and node ~= workspace do
		for _, prefix in NATURE_NAMES do
			if string.sub(node.Name, 1, #prefix) == prefix then
				return true
			end
		end
		node = node.Parent
	end
	return false
end

-- The ground, roads and other flat things a car drives on (lots, sidewalks, kerbs no higher
-- than `floor`): landing on them isn't a crash.
local function isGround(instance: BasePart, floor: number): boolean
	if instance:IsA("Terrain") or instance:GetAttribute("Surface") ~= nil then
		return true
	end
	local cf, size = instance.CFrame, instance.Size
	local halfHeight = (math.abs(cf.RightVector.Y) * size.X + math.abs(cf.UpVector.Y) * size.Y + math.abs(cf.LookVector.Y) * size.Z) / 2
	if cf.Position.Y + halfHeight < floor then
		return true
	end
	local map = workspace:FindFirstChild("Map")
	if map then
		for _, name in { "Ground", "Roads", "Beach", "GpsAreas" } do
			local folder = map:FindFirstChild(name)
			if folder and instance:IsDescendantOf(folder) then
				return true
			end
		end
	end
	return false
end

local function vehicleOf(instance: Instance): Model?
	local node = instance.Parent
	while node and node ~= workspace do
		if node:IsA("Model") and CollectionService:HasTag(node, "Vehicle") then
			return node
		end
		node = node.Parent
	end
	return nil
end

-- What the car just hit: "car" (and which), "nature", "building", or nil for nothing solid
-- (a hard landing, a person).
local function classifyHit(fx: CarSound): (string?, Model?)
	local chassis = fx.chassis
	overlapParams.FilterDescendantsInstances = { fx.car }
	local parts = workspace:GetPartBoundsInBox(chassis.CFrame, chassis.Size + Vector3.new(5, 1, 5), overlapParams)
	-- anything that doesn't reach above the bottom of the body is driven over, not hit
	local floor = chassis.Position.Y - chassis.Size.Y / 2 + 0.5
	local found: string? = nil
	for _, part in parts do
		local other = vehicleOf(part)
		if other then
			return "car", other
		end
		local model = part:FindFirstAncestorOfClass("Model")
		if isGround(part, floor) or (model and model:FindFirstChildOfClass("Humanoid")) then
			continue
		end
		if isNature(part) then
			found = "nature"
		elseif found == nil then
			found = "building"
		end
	end
	return found, nil
end

local CRASH_SOUNDS = { car = "CrashCar", nature = "CrashNature", building = "CrashBuilding" }

local function checkCrash(fx: CarSound, change: number, now: number)
	if change < CRASH_DELTA_V or now - fx.lastCrash < CRASH_COOLDOWN then
		return
	end
	local kind, other = classifyHit(fx)
	if not kind then
		return
	end
	fx.lastCrash = now
	if other then
		-- one bang per collision, not one from each car
		local otherFx = cars[other]
		if otherFx then
			if now - otherFx.lastCrash < CRASH_COOLDOWN then
				return
			end
			otherFx.lastCrash = now
		end
	end
	local loudness = math.clamp(change / 45, 0.45, 1.3)
	Sounds.play(CRASH_SOUNDS[kind], fx.chassis, loudness, 0.92 + math.random() * 0.16)
end

---------------------------------------------------------------------------------------------------
-- Per car
---------------------------------------------------------------------------------------------------

-- With streaming on, a car's parts come and go as it moves in and out of range (and come back
-- as new instances), so every tagged car is kept here and its sounds are rebuilt on whichever
-- chassis it has now.
local known: { [Model]: boolean } = {}

local function newCarSound(car: Model, chassis: BasePart): CarSound
	local tuning = Config.Vehicles.Types[car:GetAttribute("VehicleType") :: string]
	return {
		car = car,
		chassis = chassis,
		maxSpeed = if tuning then tuning.MaxSpeed else 100,
		engine = nil,
		rolls = {},
		screech = nil,
		siren = nil,
		surface = "paved",
		nextSurfaceCheck = 0,
		lastVelocity = chassis.AssemblyLinearVelocity,
		lastVelocityAt = os.clock(),
		accel = 0,
		load = 0,
		screechLevel = 0,
		lastCrash = 0,
		active = false,
	}
end

local function track(car: Instance)
	if car:IsA("Model") then
		known[car] = true
	end
end

local function drop(car: Model)
	local fx = cars[car]
	if fx then
		stopAll(fx)
		cars[car] = nil
	end
end

local function untrack(car: Instance)
	known[car :: Model] = nil
	drop(car :: Model)
end

local function updateSiren(fx: CarSound, distance: number)
	local on = fx.car:GetAttribute("Siren") == true and distance < SIREN_RANGE
	if on and not fx.siren then
		fx.siren = Sounds.make("Siren", fx.chassis)
	end
	local siren = fx.siren
	if siren then
		if on and not siren.Playing then
			siren:Play()
		elseif not on and siren.Playing then
			siren:Stop()
		end
	end
end

local function updateCar(fx: CarSound, dt: number, now: number, eye: Vector3)
	local chassis = fx.chassis
	local distance = (chassis.Position - eye).Magnitude
	updateSiren(fx, distance)

	local velocity = chassis.AssemblyLinearVelocity
	local cf = chassis.CFrame
	local forwardSpeed = velocity:Dot(cf.LookVector)
	local speed = math.abs(forwardSpeed)

	-- acceleration along the car, smoothed (velocity replicates in steps for server cars)
	local elapsed = now - fx.lastVelocityAt
	local flatChange = velocity - fx.lastVelocity
	flatChange = Vector3.new(flatChange.X, 0, flatChange.Z)
	local fresh = elapsed > 0 and elapsed < 0.2
	if fresh then
		local along = (velocity - fx.lastVelocity):Dot(cf.LookVector) / elapsed
		-- speeding up in reverse is acceleration too
		if forwardSpeed < 0 then
			along = -along
		end
		fx.accel += (along - fx.accel) * math.min(1, dt * 6)
		checkCrash(fx, flatChange.Magnitude, now)
	end
	fx.lastVelocity = velocity
	fx.lastVelocityAt = now

	if distance > RANGE then
		if fx.active then
			fx.active = false
			stopAll(fx)
		end
		return
	end
	fx.active = true

	-- engine
	if engineRunning(fx.car) then
		local engine = fx.engine or Sounds.make("Engine", chassis)
		fx.engine = engine
		local throttle = ownThrottle(fx.car)
		local targetLoad = if throttle then math.max(throttle, -throttle * 0.6) else math.clamp(fx.accel / 18, 0, 1)
		fx.load += (targetLoad - fx.load) * math.min(1, dt * 5)
		local speedFrac = math.clamp(speed / fx.maxSpeed, 0, 1.2)
		engine.PlaybackSpeed = 0.75 + speedFrac * 0.75 + fx.load * 0.18
		hold(engine, Sounds.Defs.Engine.volume * (0.55 + fx.load * 0.45 + speedFrac * 0.15))
	elseif fx.engine and fx.engine.Playing then
		fx.engine:Stop()
	end

	-- tyres on the ground
	if now >= fx.nextSurfaceCheck then
		fx.nextSurfaceCheck = now + SURFACE_INTERVAL
		rayParams.FilterDescendantsInstances = { fx.car }
		local result = workspace:Raycast(cf.Position, -cf.UpVector * 8, rayParams)
		fx.surface = if result then VehiclePhysics.surfaceOf(result) else "air"
	end
	local rollName = ROLL_SOUNDS[fx.surface]
	local rollVolume = math.clamp((speed - 3) / 50, 0, 1)
	for name, sound in fx.rolls do
		if name ~= rollName then
			hold(sound, 0)
		end
	end
	if rollName and rollVolume > 0.01 then
		local roll = fx.rolls[rollName] or Sounds.make(rollName, chassis)
		fx.rolls[rollName] = roll
		roll.PlaybackSpeed = 0.8 + math.clamp(speed / fx.maxSpeed, 0, 1) * 0.5
		hold(roll, Sounds.Defs[rollName].volume * rollVolume)
	elseif rollName and fx.rolls[rollName] then
		hold(fx.rolls[rollName], 0)
	end

	-- screech: hard braking or a sideways slide, on the ground
	local slide = math.abs(velocity:Dot(cf.RightVector))
	local target = 0
	if fx.surface ~= "air" and fx.surface ~= "water" then
		if speed > SCREECH_MIN_SPEED and -fx.accel > SCREECH_DECEL then
			target = math.clamp((-fx.accel - SCREECH_DECEL) / 50 + 0.4, 0, 1)
		end
		if slide > SCREECH_SLIDE then
			target = math.max(target, math.clamp((slide - SCREECH_SLIDE) / 20 + 0.3, 0, 1))
		end
		-- softer on loose ground
		if VehiclePhysics.isOffroad(fx.surface) or fx.surface == "dirt" then
			target *= 0.35
		end
	end
	-- quick to start, a moment to fade
	local rate = if target > fx.screechLevel then 12 else 4
	fx.screechLevel += (target - fx.screechLevel) * math.min(1, dt * rate)
	if fx.screechLevel > 0.02 and not fx.screech then
		fx.screech = Sounds.make("Screech", chassis)
	end
	local screech = fx.screech
	if screech then
		screech.PlaybackSpeed = 0.9 + fx.screechLevel * 0.2
		hold(screech, Sounds.Defs.Screech.volume * fx.screechLevel)
	end
end

local function update(dt: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local eye = camera.CFrame.Position
	local now = os.clock()
	for car in known do
		if not car.Parent then
			untrack(car)
			continue
		end
		local chassis = car.PrimaryPart
		local fx = cars[car]
		if fx and fx.chassis ~= chassis then
			drop(car)
			fx = nil
		end
		if not chassis then
			continue
		end
		if not fx then
			fx = newCarSound(car, chassis)
			cars[car] = fx
		end
		updateCar(fx :: CarSound, dt, now, eye)
	end
end

function CarSoundController.init()
	CollectionService:GetInstanceAddedSignal("Vehicle"):Connect(track)
	CollectionService:GetInstanceRemovedSignal("Vehicle"):Connect(untrack)
	for _, car in CollectionService:GetTagged("Vehicle") do
		track(car)
	end
	RunService.Heartbeat:Connect(update)
end

-- Studio test hook: what each nearby car is playing.
function CarSoundController.debugSnapshot(): { [Model]: { [string]: any } }
	local snapshot = {}
	for car, fx in cars do
		local playing = {}
		for _, sound in { fx.engine, fx.screech, fx.siren } do
			if sound and sound.Playing then
				playing[sound.Name] = { volume = sound.Volume, pitch = sound.PlaybackSpeed }
			end
		end
		for name, sound in fx.rolls do
			if sound.Playing then
				playing[name] = { volume = sound.Volume, pitch = sound.PlaybackSpeed }
			end
		end
		snapshot[car] = { surface = fx.surface, accel = fx.accel, load = fx.load, playing = playing }
	end
	return snapshot
end

return CarSoundController
