--!strict
-- Player cars: spawning from CarSpawn pads, seating, network ownership, cargo visuals, resets.
-- Also simulates every car nobody is driving (parked cars and AI-driven police cars).

local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Palette = require(ReplicatedStorage.Shared.Palette)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local VehiclePhysics = require(ReplicatedStorage.Shared.VehiclePhysics)
local CarFactory = require(script.Parent.Parent.Vehicles.CarFactory)

local VehicleService = {}

local VEHICLE_TAG = "Vehicle"

local carsFolder: Folder
local playerCars: { [Player]: Model } = {}
local lastSpawn: { [Player]: number } = {}
local aiInputs: { [Model]: VehiclePhysics.Input } = {}
local upsideDownSince: { [Model]: number } = {}

local function setupCollisionGroups()
	for _, group in { "Vehicles", "Characters", "WheelRay" } do
		if not PhysicsService:IsCollisionGroupRegistered(group) then
			PhysicsService:RegisterCollisionGroup(group)
		end
	end
	-- suspension rays pass through people instead of lifting the car onto them
	PhysicsService:CollisionGroupSetCollidable("WheelRay", "Characters", false)
end

local function setCharacterGroup(character: Model)
	local function apply(part: Instance)
		if part:IsA("BasePart") then
			part.CollisionGroup = "Characters"
		end
	end
	for _, d in character:GetDescendants() do
		apply(d)
	end
	character.DescendantAdded:Connect(apply)
end

function VehicleService.getDriver(car: Model): Player?
	local seat = car:FindFirstChild("DriverSeat") :: VehicleSeat?
	local humanoid = seat and seat.Occupant
	return if humanoid then Players:GetPlayerFromCharacter(humanoid.Parent) else nil
end

function VehicleService.getPlayerCar(player: Player): Model?
	return playerCars[player]
end

-- The car a player is currently sitting in, if any.
function VehicleService.getOccupiedCar(player: Player): Model?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	if seat then
		local model = seat:FindFirstAncestorOfClass("Model")
		if model and CollectionService:HasTag(model, VEHICLE_TAG) then
			return model
		end
	end
	return nil
end

-- AI-driven cars (police) set their inputs here; the server simulates them.
function VehicleService.setAIInput(car: Model, input: VehiclePhysics.Input?)
	aiInputs[car] = input
end

function VehicleService.spawn(vehicleType: string, color: Color3, cframe: CFrame): Model
	local car = CarFactory.build(vehicleType, color, cframe)
	CollectionService:AddTag(car, VEHICLE_TAG)
	car.Parent = carsFolder
	-- lock to the server; automatic ownership would hand parked/AI cars to nearby clients
	;(car.PrimaryPart :: BasePart):SetNetworkOwner(nil)
	return car
end

local function despawnPlayerCar(player: Player)
	local car = playerCars[player]
	playerCars[player] = nil
	if car then
		car:Destroy()
	end
end

local function updateCargoVisual(player: Player)
	local car = playerCars[player]
	local crate = car and car:FindFirstChild("CargoCrate") :: BasePart?
	if crate then
		crate.Transparency = if player:GetAttribute("HasCargo") == true then 0 else 1
	end
end

local function sit(player: Player, seat: Seat | VehicleSeat)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 and not seat.Occupant and not humanoid.SeatPart then
		seat:Sit(humanoid)
	end
end

local function setupPlayerCar(player: Player, car: Model)
	local chassis = car.PrimaryPart :: BasePart
	local driverSeat = car:FindFirstChild("DriverSeat") :: VehicleSeat
	local passengerSeat = car:FindFirstChild("PassengerSeat") :: Seat?
	car:SetAttribute("OwnerUserId", player.UserId)

	local drive = Instance.new("ProximityPrompt")
	drive.ActionText = "Drive"
	drive.ObjectText = `{player.DisplayName}'s {car.Name}`
	drive.KeyboardKeyCode = Enum.KeyCode.F
	drive.MaxActivationDistance = 12
	drive.RequiresLineOfSight = false
	drive.Parent = chassis
	drive.Triggered:Connect(function(who)
		-- only the owner drives; anyone can ride along
		if who == player then
			sit(who, driverSeat)
		elseif passengerSeat then
			sit(who, passengerSeat)
		end
	end)

	driverSeat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local driver = VehicleService.getDriver(car)
		drive.Enabled = driver == nil
		if chassis:IsDescendantOf(workspace) then
			-- the driver simulates their own car so steering feels instant
			chassis:SetNetworkOwner(driver)
		end
	end)
	updateCargoVisual(player)
end

local function onSpawnPad(pad: BasePart)
	local vehicleType = (pad:GetAttribute("VehicleType") :: string?) or "Sedan"
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = `Get {vehicleType}`
	prompt.ObjectText = "Motel parking"
	prompt.HoldDuration = 0.5
	prompt.MaxActivationDistance = 14
	prompt.RequiresLineOfSight = false
	prompt.Parent = pad
	prompt.Triggered:Connect(function(player)
		local now = os.clock()
		if lastSpawn[player] and now - lastSpawn[player] < Config.Vehicles.SpawnCooldown then
			return
		end
		lastSpawn[player] = now
		despawnPlayerCar(player)
		local color = Palette.CarColors[(player.UserId % #Palette.CarColors) + 1]
		local cframe = pad.CFrame * CFrame.new(0, 5, 0)
		local car = VehicleService.spawn(vehicleType, color, cframe)
		car.Name = vehicleType
		playerCars[player] = car
		setupPlayerCar(player, car)
	end)
end

-- Flips cars that have been upside down for a few seconds and removes ones that sank.
local function checkCarHealth(car: Model, chassis: BasePart, now: number)
	if chassis.Position.Y < -10 then
		for player, owned in playerCars do
			if owned == car then
				playerCars[player] = nil
			end
		end
		car:Destroy()
		return
	end
	if chassis.CFrame.UpVector.Y < 0.3 and chassis.AssemblyLinearVelocity.Magnitude < 8 then
		local since = upsideDownSince[car]
		if not since then
			upsideDownSince[car] = now
		elseif now - since > 3 then
			upsideDownSince[car] = nil
			local _, yaw, _ = chassis.CFrame:ToOrientation()
			car:PivotTo(CFrame.new(chassis.Position + Vector3.new(0, 6, 0)) * CFrame.Angles(0, yaw, 0))
			chassis.AssemblyLinearVelocity = Vector3.zero
			chassis.AssemblyAngularVelocity = Vector3.zero
		end
	else
		upsideDownSince[car] = nil
	end
end

local healthTimer = 0

local function simulate(dt: number)
	healthTimer += dt
	local checkHealth = healthTimer > 0.5
	if checkHealth then
		healthTimer = 0
	end
	local now = os.clock()
	for _, instance in CollectionService:GetTagged(VEHICLE_TAG) do
		local car = instance :: Model
		local chassis = car.PrimaryPart
		if not chassis or not car:IsDescendantOf(workspace) then
			continue
		end
		local tuning = Config.Vehicles.Types[car:GetAttribute("VehicleType") :: string]
		if not tuning then
			continue
		end
		-- player-driven cars are simulated by their driver's client
		if VehicleService.getDriver(car) == nil then
			local input = aiInputs[car] or { throttle = 0, steer = 0, parked = true }
			VehiclePhysics.step(car, chassis, tuning, input, dt)
		end
		if checkHealth then
			checkCarHealth(car, chassis, now)
		end
	end
end

local lastHeadlightToggle: { [Player]: number } = {}

-- Only the driver can switch their car's headlights.
local function onToggleHeadlights(player: Player)
	local now = os.clock()
	if lastHeadlightToggle[player] and now - lastHeadlightToggle[player] < 0.25 then
		return
	end
	local car = VehicleService.getOccupiedCar(player)
	if not car or VehicleService.getDriver(car) ~= player then
		return
	end
	lastHeadlightToggle[player] = now
	CarFactory.setHeadlights(car, car:GetAttribute("Headlights") ~= true)
end

function VehicleService.init()
	setupCollisionGroups()
	Remotes.event("ToggleHeadlights").OnServerEvent:Connect(onToggleHeadlights)
	Players.PlayerRemoving:Connect(function(player)
		lastHeadlightToggle[player] = nil
	end)

	carsFolder = Instance.new("Folder")
	carsFolder.Name = "Vehicles"
	carsFolder.Parent = workspace

	CollectionService:GetInstanceRemovedSignal(VEHICLE_TAG):Connect(function(instance)
		aiInputs[instance :: Model] = nil
		upsideDownSince[instance :: Model] = nil
	end)

	for _, pad in CollectionService:GetTagged(Config.Tags.CarSpawn) do
		if pad:IsA("BasePart") then
			onSpawnPad(pad)
		end
	end

	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(setCharacterGroup)
		if player.Character then
			setCharacterGroup(player.Character)
		end
		player:GetAttributeChangedSignal("HasCargo"):Connect(function()
			updateCargoVisual(player)
		end)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		despawnPlayerCar(player)
		lastSpawn[player] = nil
	end)

	RunService.PreSimulation:Connect(simulate)
end

-- Removes a player's car (impounded on arrest).
function VehicleService.impound(player: Player)
	despawnPlayerCar(player)
end

return VehicleService
