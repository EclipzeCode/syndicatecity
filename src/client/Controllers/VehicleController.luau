--!strict
-- Simulates the car the local player is driving (the server hands the driver network ownership,
-- so impulses applied here move the car for everyone) and owns the in-car controls:
--   Space  handbrake (driver)      L  headlights (driver)      F  get out (any seat)
-- Those keys are only bound while seated, so on foot F still triggers the Drive prompt and
-- Space still jumps.

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local VehiclePhysics = require(ReplicatedStorage.Shared.VehiclePhysics)

local player = Players.LocalPlayer
local toggleHeadlights = Remotes.event("ToggleHeadlights")

local VehicleController = {}

-- driver seat, when the local player is driving
local currentSeat: VehicleSeat? = nil
-- any seat in a car (driver or passenger)
local carSeat: BasePart? = nil
local handbrakeHeld = false

-- above the default jump binding, so Space brakes instead of bailing out of the car
local PRIORITY = Enum.ContextActionPriority.High.Value

export type State = {
	car: Model,
	seat: BasePart,
	isDriver: boolean,
	handbrake: boolean,
}

-- What the local player is sitting in, for the car HUD; nil on foot.
function VehicleController.getState(): State?
	local seat = carSeat
	if not seat or not seat.Parent then
		return nil
	end
	return {
		car = seat.Parent :: Model,
		seat = seat,
		isDriver = currentSeat ~= nil,
		handbrake = handbrakeHeld,
	}
end

local function sink(_: string, _: Enum.UserInputState, _: InputObject): Enum.ContextActionResult
	return Enum.ContextActionResult.Sink
end

local function bindCarControls(isDriver: boolean)
	ContextActionService:BindActionAtPriority("CarExit", function(_, state)
		if state == Enum.UserInputState.Begin then
			local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.Sit = false
			end
		end
		return Enum.ContextActionResult.Sink
	end, false, PRIORITY, Enum.KeyCode.F, Enum.KeyCode.ButtonY)
	if isDriver then
		ContextActionService:BindActionAtPriority("CarHandbrake", function(_, state)
			if state == Enum.UserInputState.Begin then
				handbrakeHeld = true
			elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
				handbrakeHeld = false
			end
			return Enum.ContextActionResult.Sink
		end, false, PRIORITY, Enum.KeyCode.Space, Enum.KeyCode.ButtonX)
		ContextActionService:BindActionAtPriority("CarHeadlights", function(_, state)
			if state == Enum.UserInputState.Begin then
				toggleHeadlights:FireServer()
			end
			return Enum.ContextActionResult.Sink
		end, false, PRIORITY, Enum.KeyCode.L, Enum.KeyCode.DPadUp)
	else
		-- passengers can't drive, but Space still shouldn't throw them out of the car
		ContextActionService:BindActionAtPriority("CarHandbrake", sink, false, PRIORITY, Enum.KeyCode.Space)
	end
end

local function unbindCarControls()
	for _, name in { "CarExit", "CarHandbrake", "CarHeadlights" } do
		ContextActionService:UnbindAction(name)
	end
	handbrakeHeld = false
end

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
			carSeat = nil
			unbindCarControls()
			-- a car that was impounded or despawned under the player is already gone
			if seat and seat.Parent then
				stepOut(character, humanoid, seat)
			end
			return
		end
		lastSeat = seatPart
		currentSeat = nil
		carSeat = nil
		local car = seatPart and seatPart.Parent
		if seatPart and car and CollectionService:HasTag(car, "Vehicle") then
			carSeat = seatPart
			if seatPart:IsA("VehicleSeat") then
				currentSeat = seatPart
			end
			bindCarControls(currentSeat ~= nil)
		end
	end)
	humanoid.Died:Connect(unbindCarControls)
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
			VehiclePhysics.step(car, chassis, tuning, {
				throttle = seat.ThrottleFloat,
				steer = seat.SteerFloat,
				handbrake = handbrakeHeld,
			}, dt)
		end
	end)
end

return VehicleController
