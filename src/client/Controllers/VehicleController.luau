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

local function onCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.Seated:Connect(function(active, seatPart)
		if active and seatPart and seatPart:IsA("VehicleSeat") then
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
