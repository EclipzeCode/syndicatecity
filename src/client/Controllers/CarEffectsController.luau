--!strict
-- Local-only car effects for every car near the camera:
--   * wheels roll with the car's speed and the front ones steer into turns (CarFactory hangs the
--     wheels on Motor6Ds named WheelMotor; this sets their Transform)
--   * a trail behind the rear wheels that depends on the ground: dust and tire tracks on dirt,
--     grass and sand, nothing on pavement
-- Nothing here replicates or affects physics.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local VehiclePhysics = require(ReplicatedStorage.Shared.VehiclePhysics)

local CarEffectsController = {}

-- only cars this close to the camera are animated
local RANGE = 350
-- how often each car checks the ground under it
local SURFACE_INTERVAL = 0.15
-- slower than this, no dust or tracks
local MIN_TRAIL_SPEED = 6
local MAX_STEER = math.rad(30)

-- How each surface looks behind a car. Paved surfaces leave nothing.
type SurfaceLook = { dust: Color3, track: Color3, rate: number, size: number }
local LOOKS: { [string]: SurfaceLook } = {
	dirt = { dust = Color3.fromRGB(196, 160, 116), track = Color3.fromRGB(92, 70, 48), rate = 36, size = 4.5 },
	grass = { dust = Color3.fromRGB(164, 150, 102), track = Color3.fromRGB(70, 96, 48), rate = 24, size = 3.2 },
	sand = { dust = Color3.fromRGB(240, 222, 176), track = Color3.fromRGB(176, 150, 104), rate = 32, size = 4 },
}

type Wheel = { motor: Motor6D, front: boolean, radius: number, spin: number }
type CarFx = {
	car: Model,
	chassis: BasePart,
	wheels: { Wheel },
	steer: number,
	emitters: { ParticleEmitter },
	trails: { Trail },
	surface: string,
	nextSurfaceCheck: number,
	active: boolean,
}

local cars: { [Model]: CarFx } = {}
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = false

local function setTrail(fx: CarFx, look: SurfaceLook?, speed: number)
	local on = look ~= nil and speed > MIN_TRAIL_SPEED
	for _, emitter in fx.emitters do
		emitter.Enabled = on
		if look then
			emitter.Color = ColorSequence.new(look.dust)
			emitter.Rate = look.rate * math.clamp(speed / 50, 0.3, 1.5)
			emitter.Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, look.size * 0.4),
				NumberSequenceKeypoint.new(1, look.size),
			})
		end
	end
	for _, trail in fx.trails do
		trail.Enabled = on
		if look then
			trail.Color = ColorSequence.new(look.track)
		end
	end
end

-- Dust emitters and track ribbons at the bottom of the two rear wheels (worked out from the car's
-- tuning, the same way CarFactory places the wheels).
local function buildTrail(fx: CarFx)
	local chassis = fx.chassis
	local tuning = Config.Vehicles.Types[fx.car:GetAttribute("VehicleType") :: string]
	if not tuning then
		return
	end
	local half = tuning.Size / 2
	local rear: { Vector3 } = {}
	for _, x in { -1, 1 } do
		table.insert(rear, Vector3.new(x * (half.X - 0.5), -half.Y - tuning.RideHeight + 0.15, half.Z - 2.6))
	end
	for _, bottom in rear do
		local dustPoint = Instance.new("Attachment")
		dustPoint.Name = "DustPoint"
		-- just behind and outside the tire, so the body doesn't hide it
		dustPoint.Position = bottom + Vector3.new(math.sign(bottom.X) * 0.6, 0.8, 1.8)
		dustPoint.Parent = chassis
		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "Dust"
		emitter.Texture = "rbxasset://textures/particles/smoke_main.dds"
		emitter.Lifetime = NumberRange.new(0.7, 1.4)
		emitter.Speed = NumberRange.new(3, 7)
		emitter.SpreadAngle = Vector2.new(40, 40)
		emitter.Acceleration = Vector3.new(0, 5, 0)
		emitter.Drag = 2
		emitter.RotSpeed = NumberRange.new(-40, 40)
		emitter.LightInfluence = 0.4
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.1),
			NumberSequenceKeypoint.new(0.6, 0.5),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter.EmissionDirection = Enum.NormalId.Back
		emitter.Enabled = false
		emitter.Parent = dustPoint
		table.insert(fx.emitters, emitter)

		-- a flat ribbon the width of the tire, lying on the ground behind it
		local a0 = Instance.new("Attachment")
		a0.Position = bottom + Vector3.new(-0.7, 0, 0)
		a0.Parent = chassis
		local a1 = Instance.new("Attachment")
		a1.Position = bottom + Vector3.new(0.7, 0, 0)
		a1.Parent = chassis
		local trail = Instance.new("Trail")
		trail.Name = "TireTrack"
		trail.Attachment0 = a0
		trail.Attachment1 = a1
		trail.Lifetime = 2.5
		trail.MinLength = 0.3
		trail.FaceCamera = false
		trail.LightInfluence = 1
		trail.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.35),
			NumberSequenceKeypoint.new(1, 1),
		})
		trail.Enabled = false
		trail.Parent = chassis
		table.insert(fx.trails, trail)
	end
end

local function track(car: Instance)
	if not car:IsA("Model") or cars[car] then
		return
	end
	local chassis = car.PrimaryPart or car:WaitForChild("Chassis", 5)
	if not chassis or not chassis:IsA("BasePart") or not car.Parent then
		return
	end
	local fx: CarFx = {
		car = car,
		chassis = chassis,
		wheels = {},
		steer = 0,
		emitters = {},
		trails = {},
		surface = "paved",
		nextSurfaceCheck = 0,
		active = true,
	}
	-- wheel parts can stream in after the car itself
	local function addMotor(motor: Instance)
		if motor:IsA("Motor6D") and motor.Name == "WheelMotor" then
			table.insert(fx.wheels, {
				motor = motor,
				front = motor:GetAttribute("Front") == true,
				radius = (motor:GetAttribute("Radius") :: number?) or 1.5,
				spin = 0,
			})
		end
	end
	for _, d in car:GetDescendants() do
		addMotor(d)
	end
	car.DescendantAdded:Connect(addMotor)
	buildTrail(fx)
	cars[car] = fx
end

local function untrack(car: Instance)
	cars[car :: Model] = nil
end

local function update(dt: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local eye = camera.CFrame.Position
	local now = os.clock()
	for car, fx in cars do
		local chassis = fx.chassis
		if not car.Parent or not chassis.Parent then
			cars[car] = nil
			continue
		end
		if (chassis.Position - eye).Magnitude > RANGE then
			if fx.active then
				fx.active = false
				setTrail(fx, nil, 0)
			end
			continue
		end
		fx.active = true

		local cf = chassis.CFrame
		local velocity = chassis.AssemblyLinearVelocity
		local forwardSpeed = velocity:Dot(cf.LookVector)
		local yawRate = chassis.AssemblyAngularVelocity:Dot(cf.UpVector)

		-- steer angle from how fast the car is turning for its speed (bicycle model), so it
		-- works the same for every car whoever simulates it
		local target = 0
		if math.abs(forwardSpeed) > 2 then
			target = math.clamp(math.atan(yawRate * 9 / forwardSpeed), -MAX_STEER, MAX_STEER)
		end
		fx.steer += (target - fx.steer) * math.min(1, dt * 10)

		for _, wheel in fx.wheels do
			-- rolling forward (-Z) turns the top of the wheel toward the front
			wheel.spin = (wheel.spin - forwardSpeed / wheel.radius * dt) % (math.pi * 2)
			local steer = if wheel.front then CFrame.Angles(0, fx.steer, 0) else CFrame.identity
			wheel.motor.Transform = steer * CFrame.Angles(wheel.spin, 0, 0)
		end

		if now >= fx.nextSurfaceCheck then
			fx.nextSurfaceCheck = now + SURFACE_INTERVAL
			rayParams.FilterDescendantsInstances = { car }
			local result = workspace:Raycast(cf.Position, -cf.UpVector * 8, rayParams)
			fx.surface = if result then VehiclePhysics.surfaceOf(result) else "air"
			setTrail(fx, LOOKS[fx.surface], math.abs(forwardSpeed))
		end
	end
end

function CarEffectsController.init()
	CollectionService:GetInstanceAddedSignal("Vehicle"):Connect(function(car)
		task.spawn(track, car)
	end)
	CollectionService:GetInstanceRemovedSignal("Vehicle"):Connect(untrack)
	for _, car in CollectionService:GetTagged("Vehicle") do
		task.spawn(track, car)
	end
	RunService.RenderStepped:Connect(update)
end

return CarEffectsController
