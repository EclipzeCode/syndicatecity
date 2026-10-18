--!strict
-- Simulates the car the local player is driving. The server hands the driver network ownership,
-- so impulses applied here move the car for everyone.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local VehiclePhysics = require(ReplicatedStorage.Shared.VehiclePhysics)

local player = Players.LocalPlayer

local VehicleController = {}

local currentSeat: VehicleSeat? = nil

-- The car's chassis if the local player is in its driver seat.
function VehicleController.getDrivenCar(): (Model?, BasePart?)
	local seat = currentSeat
	if not seat or not seat.Parent then
		return nil, nil
	end
	local car = seat.Parent :: Model
	return car, car.PrimaryPart
end

-- Jumping out of a seat leaves the character inside the car's solid chassis and cabin, and
-- physics then flings it out (the ragdoll on exit). The client owns its character, so it steps
-- out beside the seat's door instead: the same side if there's room, else the other side, else
-- onto the roof.
local function stepOut(character: Model, humanoid: Humanoid, seat: BasePart)
	local car = seat.Parent
	if not car or not car:IsA("Model") or not CollectionService:HasTag(car, "Vehicle") then
		return
	end
	local chassis = car.PrimaryPart
	local root = humanoid.RootPart
	if not chassis or not root then
		return
	end
	local seatLocal = chassis.CFrame:PointToObjectSpace(seat.Position)
	local side = if seatLocal.X < 0 then -1 else 1
	local _, yaw, _ = chassis.CFrame:ToOrientation()
	local standHeight = humanoid.HipHeight + root.Size.Y / 2

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { car, character }
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = { car, character }
	overlapParams.RespectCanCollide = true

	local target: CFrame? = nil
	for _, s in { side, -side } do
		local beside = chassis.CFrame:PointToWorldSpace(Vector3.new(s * (chassis.Size.X / 2 + 2.5), 0, seatLocal.Z))
		local hit = workspace:Raycast(beside + Vector3.new(0, 6, 0), Vector3.new(0, -20, 0), rayParams)
		if hit then
			local spot = CFrame.new(hit.Position + Vector3.new(0, standHeight + 0.1, 0)) * CFrame.Angles(0, yaw, 0)
			-- room to stand: a body-sized box from the feet up, clear of anything solid
			local body = spot * CFrame.new(0, 2.5 - standHeight, 0)
			if #workspace:GetPartBoundsInBox(body, Vector3.new(2, 4.5, 2), overlapParams) == 0 then
				target = spot
				break
			end
		end
	end
	if not target then
		local top = chassis.CFrame:PointToWorldSpace(Vector3.new(0, chassis.Size.Y / 2 + 6, 0))
		target = CFrame.new(top + Vector3.new(0, standHeight, 0)) * CFrame.Angles(0, yaw, 0)
	end
	character:PivotTo(target :: CFrame)
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	humanoid:ChangeState(Enum.HumanoidStateType.Running)
end

local function onCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local lastSeat: BasePart? = nil
	humanoid.Seated:Connect(function(active, seatPart)
		if not active then
			local seat = lastSeat
			lastSeat = nil
			currentSeat = nil
			-- a car that was impounded or despawned under the player is already gone
			if seat and seat.Parent then
				stepOut(character, humanoid, seat)
			end
			return
		end
		lastSeat = seatPart
		if seatPart and seatPart:IsA("VehicleSeat") then
			local car = seatPart.Parent
			if car and CollectionService:HasTag(car, "Vehicle") then
				currentSeat = seatPart
				return
			end
		end
		currentSeat = nil
	end)
end

function VehicleController.init()
	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end

	RunService.PreSimulation:Connect(function(dt)
		local car, chassis = VehicleController.getDrivenCar()
		local seat = currentSeat
		if not car or not chassis or not seat then
			return
		end
		local tuning = Config.Vehicles.Types[car:GetAttribute("VehicleType") :: string]
		if tuning then
			VehiclePhysics.step(car, chassis, tuning, { throttle = seat.ThrottleFloat, steer = seat.SteerFloat }, dt)
		end
	end)
end

return VehicleController
