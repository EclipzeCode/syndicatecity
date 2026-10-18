--!strict
-- Arcade raycast car physics, shared so it runs wherever the car is simulated: on the driver's client
-- for player-driven cars (they own the physics), on the server for parked and police cars.
--
-- The chassis floats on four raycast springs; driving, grip and steering are impulses on the chassis.
-- Wheels are visual only. Front of the car is the chassis LookVector (-Z).

local Types = require(script.Parent.Types)

type Tuning = Types.VehicleTuning

local VehiclePhysics = {}

export type Input = {
	throttle: number, -- -1..1
	steer: number, -- -1 (left) .. 1 (right)
	parked: boolean?, -- strong brake when nobody is driving
	handbrake: boolean?, -- strong brake while held (Space)
}

-- Coasting slows the car like engine braking plus drag, studs/s² (constant + per stud/s), so a
-- car you stop driving comes to rest in a few seconds instead of sliding forever.
local COAST_DECEL = 6
local COAST_DRAG = 0.25
-- Below this speed with no throttle the car holds still, like a car in gear with the brake on.
local HOLD_SPEED = 1.5

local paramsByCar: { [Model]: RaycastParams } = setmetatable({}, { __mode = "k" }) :: any

local function raycastParams(car: Model): RaycastParams
	local params = paramsByCar[car]
	if not params then
		params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { car }
		params.CollisionGroup = "WheelRay"
		params.IgnoreWater = false
		-- drive over pads and other non-solid markers instead of bumping up onto them
		params.RespectCanCollide = true
		paramsByCar[car] = params
	end
	return params
end

-- Returns how many wheels touched the ground.
function VehiclePhysics.step(car: Model, chassis: BasePart, tuning: Tuning, input: Input, dt: number): number
	dt = math.min(dt, 1 / 20)
	local cf = chassis.CFrame
	local up = cf.UpVector
	local size = tuning.Size
	local mass = chassis.AssemblyMass
	local gravity = workspace.Gravity

	-- spring sized so the car rests with the chassis RideHeight above the ground
	local restLength = tuning.RideHeight + tuning.SpringTravel
	local stiffness = mass * gravity / (4 * tuning.SpringTravel)
	local damping = 2 * 0.55 * math.sqrt(stiffness * mass / 4)
	local params = raycastParams(car)

	local grounded = 0
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			local corner = cf:PointToWorldSpace(Vector3.new(sx * (size.X / 2 - 0.8), -size.Y / 2 + 0.3, sz * (size.Z / 2 - 2.6)))
			local result = workspace:Raycast(corner, -up * (restLength + 0.3), params)
			if result then
				local distance = (result.Position - corner).Magnitude - 0.3
				local compression = restLength - distance
				if compression > 0 then
					local pointVelocity = chassis:GetVelocityAtPosition(corner)
					local force = stiffness * compression - damping * pointVelocity:Dot(up)
					if force > 0 then
						chassis:ApplyImpulseAtPosition(up * force * dt, corner)
					end
				end
				grounded += 1
			end
		end
	end

	local velocity = chassis.AssemblyLinearVelocity
	local angular = chassis.AssemblyAngularVelocity
	local yawRate = angular:Dot(up)

	if grounded >= 2 then
		local forward = cf.LookVector
		local right = cf.RightVector
		local forwardSpeed = velocity:Dot(forward)
		local throttle = math.clamp(input.throttle, -1, 1)

		-- slow toward 0 at `rate` without overshooting, so braking ends at exactly 0
		local function brakeToStop(rate: number): number
			return -math.sign(forwardSpeed) * math.min(math.abs(forwardSpeed) / dt, rate)
		end

		local holding = false
		local accel = 0
		if input.parked or input.handbrake then
			accel = brakeToStop(tuning.Brake * 1.2)
			holding = math.abs(forwardSpeed) < HOLD_SPEED
		elseif throttle > 0 then
			if forwardSpeed < -2 then
				accel = tuning.Brake * throttle
			elseif forwardSpeed < tuning.MaxSpeed then
				-- engine falls off toward top speed
				accel = tuning.Acceleration * throttle * (1 - 0.6 * math.max(forwardSpeed, 0) / tuning.MaxSpeed)
			end
		elseif throttle < 0 then
			if forwardSpeed > 2 then
				accel = tuning.Brake * throttle
			elseif forwardSpeed > -tuning.ReverseSpeed then
				accel = tuning.Acceleration * 0.6 * throttle
			end
		else
			accel = brakeToStop(COAST_DECEL + COAST_DRAG * math.abs(forwardSpeed))
			holding = math.abs(forwardSpeed) < HOLD_SPEED
		end
		chassis:ApplyImpulse(forward * accel * mass * dt)

		-- tires resist sliding sideways; a held car doesn't creep sideways either
		local sideways = velocity:Dot(right)
		local grip = if holding then 1 else math.min(1, tuning.Grip * dt)
		chassis:ApplyImpulse(-right * sideways * grip * mass)

		-- steering sets the yaw rate directly for a responsive arcade feel
		local speedFactor = math.clamp(math.abs(forwardSpeed) / 20, 0, 1)
		local highSpeedDamp = 1 - 0.4 * math.clamp(math.abs(forwardSpeed) / tuning.MaxSpeed, 0, 1)
		local direction = if forwardSpeed >= 0 then 1 else -1
		local desiredYaw = -math.clamp(input.steer, -1, 1) * tuning.TurnRate * speedFactor * highSpeedDamp * direction
		local newYaw = yawRate + (desiredYaw - yawRate) * math.min(1, 8 * dt)
		-- also calm roll and pitch so bumps don't flip the car
		local tilt = angular - up * yawRate
		chassis.AssemblyAngularVelocity = tilt * (1 - math.min(1, 3 * dt)) + up * newYaw
	end

	return grounded
end

return VehiclePhysics
