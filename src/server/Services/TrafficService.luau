--!strict
-- Civilian traffic: a handful of cars (Config.Traffic) that cruise the road graph around the
-- players. They drive like the police (Navigation/Driver): keep to their lane, brake for anything
-- in the way and drive around it if it doesn't move. If someone rams them they stop for a moment,
-- then carry on; they never get suspicious. Cars appear out of sight near players and are removed
-- once everyone is far away, so traffic is always where people are.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Palette = require(ReplicatedStorage.Shared.Palette)
local Driver = require(script.Parent.Parent.Navigation.Driver)
local RoadGraph = require(script.Parent.Parent.Navigation.RoadGraph)
local VehicleService = require(script.Parent.VehicleService)
local WorldService = require(script.Parent.WorldService)

local TRAFFIC = Config.Traffic

type Civilian = {
	car: Model,
	driver: Driver.State,
	-- stopped after being hit, until this time
	shakenUntil: number,
}

local TrafficService = {}

local civilians: { Civilian } = {}
local rng = Random.new()

local function spawnCivilian()
	local nodeId = Driver.spawnNode(rng, nil, TRAFFIC.SpawnRange)
	local cframe, nextId = Driver.spawnFrame(nodeId, rng)
	local vehicleType = if rng:NextNumber() < TRAFFIC.VanChance then "Van" else "Sedan"
	local car = VehicleService.spawn(vehicleType, Palette.CarColors[rng:NextInteger(1, #Palette.CarColors)], cframe)
	car.Name = `Traffic{vehicleType}`
	car:SetAttribute("Traffic", true)
	WorldService.autoHeadlights(car)
	table.insert(civilians, { car = car, driver = Driver.new(car, nodeId, nextId), shakenUntil = 0 })
end

local function removeCivilian(civilian: Civilian)
	local index = table.find(civilians, civilian)
	if index then
		table.remove(civilians, index)
	end
	civilian.car:Destroy()
end

local function nearestPlayerDistance(position: Vector3): number
	local nearest = math.huge
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			nearest = math.min(nearest, (root.Position - position).Magnitude)
		end
	end
	return nearest
end

local function drive(civilian: Civilian, dt: number, now: number)
	local driver = civilian.driver
	local impact = driver.lastImpact
	if impact then
		driver.lastImpact = nil
		civilian.shakenUntil = now + TRAFFIC.RamStopSeconds
	end
	if now < civilian.shakenUntil then
		-- pull up and wait
		Driver.drive(driver, driver.chassis.Position + driver.chassis.CFrame.LookVector * 20, 0, dt, now)
		return
	end
	Driver.advance(driver, function(state)
		return Driver.randomNext(state, rng)
	end)
	local speed = TRAFFIC.Speeds[Driver.roadKind(driver)] or TRAFFIC.Speeds.street
	Driver.cruise(driver, speed, dt, now)
end

-- Keeps the right number of cars around the players: removes ones that are lost, stuck or far
-- from everyone, and adds new ones out of sight.
local function maintain()
	for _, civilian in table.clone(civilians) do
		local chassis = civilian.driver.chassis
		local lost = not civilian.car.Parent or chassis.Position.Y < -4 or civilian.driver.needsRespawn
		local nearest = if lost then math.huge else nearestPlayerDistance(chassis.Position)
		-- don't pop a car out of existence in front of someone
		if lost or (nearest > TRAFFIC.DespawnDistance) then
			removeCivilian(civilian)
		end
	end
	if #Players:GetPlayers() == 0 then
		return
	end
	for _ = #civilians + 1, TRAFFIC.Count do
		spawnCivilian()
	end
end

local maintenanceTimer = 0

function TrafficService.init()
	if not RoadGraph.load() then
		warn("[TrafficService] No Workspace.Map.RoadGraph; no traffic. Build the map with MapBuilder.")
		return
	end
	RunService.Heartbeat:Connect(function(dt)
		local now = os.clock()
		for _, civilian in table.clone(civilians) do
			if civilian.car.Parent then
				drive(civilian, dt, now)
			end
		end
		maintenanceTimer += dt
		if maintenanceTimer >= 2 then
			maintenanceTimer = 0
			maintain()
		end
	end)
end

-- Studio test hook: the traffic cars and whether each is stopped behind something.
function TrafficService.debugSnapshot(): { { car: Model, blockedBy: Instance?, shaken: boolean } }
	local snapshot = {}
	for _, civilian in civilians do
		local blocker = civilian.driver.blockedBy
		table.insert(snapshot, {
			car = civilian.car,
			blockedBy = if blocker then blocker.instance else nil,
			shaken = os.clock() < civilian.shakenUntil,
		})
	end
	return snapshot
end

return TrafficService
