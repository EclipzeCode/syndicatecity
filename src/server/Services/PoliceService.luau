--!strict
-- Police AI. Patrol cars cruise the road graph (Workspace.Map.RoadGraph). When a player becomes
-- wanted, the nearest cops switch on their sirens and chase: straight at the player while they can
-- see them, along the road graph when they can't. A cop that stays close to a slow or stopped player
-- busts them. Cops shoot only at wanted players on foot, and can be disabled by shooting their car.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Palette = require(ReplicatedStorage.Shared.Palette)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local CombatService = require(script.Parent.CombatService)
local HeatService = require(script.Parent.HeatService)
local JobService = require(script.Parent.JobService)
local PlayerDataService = require(script.Parent.PlayerDataService)
local VehicleService = require(script.Parent.VehicleService)

local POLICE = Config.Police
local TUNING = Config.Vehicles.Types.Police
local LANE_OFFSET = 9
local ARRIVE_DISTANCE = 22

type Node = { id: string, position: Vector3, links: { string } }

type Cop = {
	car: Model,
	chassis: BasePart,
	from: string?,
	to: string,
	target: Player?,
	path: { string },
	nextPathTime: number,
	health: number,
	disabledUntil: number,
	stuckTime: number,
	reverseUntil: number,
	lastShot: number,
	sees: boolean,
}

local PoliceService = {}

local graph: { [string]: Node } = {}
local nodeIds: { string } = {}
local cops: { Cop } = {}
local bustProgress: { [Player]: number } = {}
local releaseOnSpawn: { [Player]: boolean } = {}
local rng = Random.new()

local notice = Remotes.event("Notice")

---------------------------------------------------------------------------------------------------
-- Road graph
---------------------------------------------------------------------------------------------------

local function loadGraph(): boolean
	local map = workspace:FindFirstChild("Map")
	local folder = map and map:FindFirstChild("RoadGraph")
	if not folder then
		return false
	end
	for _, value in folder:GetChildren() do
		if value:IsA("Vector3Value") then
			local links = string.split((value:GetAttribute("Links") :: string?) or "", ",")
			graph[value.Name] = { id = value.Name, position = value.Value, links = links }
			table.insert(nodeIds, value.Name)
		end
	end
	return #nodeIds > 0
end

local function nearestNode(position: Vector3): string
	local best, bestDistance = nodeIds[1], math.huge
	for id, node in graph do
		local d = (node.position - position).Magnitude
		if d < bestDistance then
			best, bestDistance = id, d
		end
	end
	return best
end

-- Dijkstra over ~50 nodes; cheap enough to rerun every second per pursuer.
local function findPath(fromId: string, toId: string): { string }
	local dist: { [string]: number } = { [fromId] = 0 }
	local prev: { [string]: string } = {}
	local open: { [string]: boolean } = { [fromId] = true }
	while next(open) do
		local current, best = nil :: string?, math.huge
		for id in open do
			if dist[id] < best then
				current, best = id, dist[id]
			end
		end
		local cur = current :: string
		open[cur] = nil
		if cur == toId then
			break
		end
		for _, linkId in graph[cur].links do
			local link = graph[linkId]
			if link then
				local alt = dist[cur] + (link.position - graph[cur].position).Magnitude
				if alt < (dist[linkId] or math.huge) then
					dist[linkId] = alt
					prev[linkId] = cur
					open[linkId] = true
				end
			end
		end
	end
	local path = {}
	local step: string? = toId
	while step and step ~= fromId do
		table.insert(path, 1, step)
		step = prev[step]
	end
	return path
end

-- Aim for the right-hand lane of the road between two nodes.
local function laneTarget(fromPos: Vector3, toPos: Vector3): Vector3
	local flat = Vector3.new(toPos.X - fromPos.X, 0, toPos.Z - fromPos.Z)
	if flat.Magnitude < 1 then
		return toPos
	end
	local right = flat.Unit:Cross(Vector3.yAxis)
	return toPos + right * LANE_OFFSET
end

---------------------------------------------------------------------------------------------------
-- Cops
---------------------------------------------------------------------------------------------------

local function setSiren(cop: Cop, on: boolean)
	cop.car:SetAttribute("Siren", on)
end

local function spawnCop(nodeId: string): Cop
	local node = graph[nodeId]
	local nextId = node.links[rng:NextInteger(1, #node.links)]
	local nextPos = graph[nextId].position
	local start = laneTarget(nextPos, node.position)
	local cframe = CFrame.lookAt(start + Vector3.new(0, 4, 0), laneTarget(node.position, nextPos) + Vector3.new(0, 4, 0))
	local car = VehicleService.spawn("Police", Palette.PoliceWhite, cframe)
	local chassis = car.PrimaryPart :: BasePart
	CollectionService:AddTag(chassis, Config.Tags.Patrol)
	car:SetAttribute("Siren", false)

	local smoke = Instance.new("Smoke")
	smoke.Name = "DisabledSmoke"
	smoke.Color = Color3.fromRGB(90, 90, 96)
	smoke.Opacity = 0.35
	smoke.RiseVelocity = 6
	smoke.Size = 3
	smoke.Enabled = false
	smoke.Parent = chassis

	local cop: Cop = {
		car = car,
		chassis = chassis,
		from = nodeId,
		to = nextId,
		target = nil,
		path = {},
		nextPathTime = 0,
		health = POLICE.CarHealth,
		disabledUntil = 0,
		stuckTime = 0,
		reverseUntil = 0,
		lastShot = 0,
		sees = false,
	}
	table.insert(cops, cop)
	return cop
end

local function removeCop(cop: Cop)
	local index = table.find(cops, cop)
	if index then
		table.remove(cops, index)
	end
	cop.car:Destroy()
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function hasLineOfSight(cop: Cop, root: BasePart): boolean
	local origin = cop.chassis.Position + cop.chassis.CFrame.UpVector * 4
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore: { Instance } = { cop.car }
	local character = root.Parent
	if character then
		table.insert(ignore, character)
	end
	local car = root.Parent and Players:GetPlayerFromCharacter(root.Parent)
	local playerCar = car and VehicleService.getOccupiedCar(car)
	if playerCar then
		table.insert(ignore, playerCar)
	end
	params.FilterDescendantsInstances = ignore
	return workspace:Raycast(origin, root.Position - origin, params) == nil
end

local function returnToPatrol(cop: Cop)
	cop.target = nil
	cop.path = {}
	cop.from = nil
	cop.to = nearestNode(cop.chassis.Position)
	setSiren(cop, false)
end

local function pursuersOf(player: Player): number
	local count = 0
	for _, cop in cops do
		if cop.target == player then
			count += 1
		end
	end
	return count
end

local function assignPursuers(player: Player)
	local root = rootOf(player)
	if not root then
		return
	end
	local needed = POLICE.PursuersPerPlayer - pursuersOf(player)
	if needed <= 0 then
		return
	end
	local now = os.clock()
	local free = {}
	for _, cop in cops do
		if cop.target == nil and cop.disabledUntil < now then
			table.insert(free, cop)
		end
	end
	table.sort(free, function(a, b)
		return (a.chassis.Position - root.Position).Magnitude < (b.chassis.Position - root.Position).Magnitude
	end)
	for i = 1, math.min(needed, #free) do
		free[i].target = player
		free[i].nextPathTime = 0
		setSiren(free[i], true)
	end
	needed -= #free
	-- call in backup from a road node out of sight
	while needed > 0 and #cops < POLICE.MaxCops do
		local candidates = {}
		for _, id in nodeIds do
			local d = (graph[id].position - root.Position).Magnitude
			if d > 250 and d < 550 then
				table.insert(candidates, id)
			end
		end
		if #candidates == 0 then
			break
		end
		local cop = spawnCop(candidates[rng:NextInteger(1, #candidates)])
		cop.target = player
		setSiren(cop, true)
		needed -= 1
	end
end

local function releasePursuers(player: Player)
	for _, cop in cops do
		if cop.target == player then
			returnToPatrol(cop)
		end
	end
	bustProgress[player] = nil
	player:SetAttribute("BustProgress", 0)
end

---------------------------------------------------------------------------------------------------
-- Arrest
---------------------------------------------------------------------------------------------------

local function releasePoint(): CFrame?
	for _, part in CollectionService:GetTagged(Config.Tags.PoliceRelease) do
		if part:IsA("BasePart") then
			return part.CFrame + Vector3.new(0, 3, 0)
		end
	end
	return nil
end

function PoliceService.bust(player: Player, knockedOut: boolean?)
	releasePursuers(player)
	HeatService.clear(player)
	JobService.bust(player)
	VehicleService.impound(player)
	local fine = math.floor(PlayerDataService.getDirtyCash(player) * POLICE.BustFinePercent)
	if fine > 0 then
		PlayerDataService.addDirtyCash(player, -fine)
	end
	notice:FireClient(player, "busted", `BUSTED! Fined ${fine}. Your car was impounded.`)

	if knockedOut then
		releaseOnSpawn[player] = true
		return
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.Sit = false
		humanoid.WalkSpeed = 0
	end
	task.delay(2.5, function()
		local point = releasePoint()
		if character and character.Parent and point then
			character:PivotTo(point)
		end
		if humanoid then
			humanoid.WalkSpeed = Config.Movement.WalkSpeed
		end
	end)
end

---------------------------------------------------------------------------------------------------
-- Driving
---------------------------------------------------------------------------------------------------

local function drive(cop: Cop, target: Vector3, desiredSpeed: number, dt: number, now: number)
	local cf = cop.chassis.CFrame
	local rel = cf:PointToObjectSpace(target)
	local angle = math.atan2(rel.X, -rel.Z) -- positive: target is to the right
	local speed = cop.chassis.AssemblyLinearVelocity:Dot(cf.LookVector)
	local steer = math.clamp(angle * 2.2, -1, 1)

	if now < cop.reverseUntil then
		VehicleService.setAIInput(cop.car, { throttle = -1, steer = -steer })
		return
	end

	-- slow down for sharp turns
	local turnFactor = math.clamp(1 - math.abs(angle) / math.rad(100), 0.3, 1)
	local targetSpeed = desiredSpeed * turnFactor
	local throttle = math.clamp((targetSpeed - speed) / 8, -1, 1)

	if throttle > 0.3 and math.abs(speed) < 3 then
		cop.stuckTime += dt
		if cop.stuckTime > 1.5 then
			cop.stuckTime = 0
			cop.reverseUntil = now + 1.3
		end
	else
		cop.stuckTime = 0
	end
	VehicleService.setAIInput(cop.car, { throttle = throttle, steer = steer, parked = desiredSpeed == 0 and math.abs(speed) < 4 })
end

local function patrol(cop: Cop, dt: number, now: number)
	local toNode = graph[cop.to]
	local position = cop.chassis.Position
	if (Vector3.new(toNode.position.X, position.Y, toNode.position.Z) - position).Magnitude < ARRIVE_DISTANCE then
		local options = {}
		for _, id in toNode.links do
			if id ~= cop.from and graph[id] then
				table.insert(options, id)
			end
		end
		if #options == 0 then
			options = { cop.from :: string }
		end
		cop.from = cop.to
		cop.to = options[rng:NextInteger(1, #options)]
		toNode = graph[cop.to]
	end
	local fromPos = if cop.from then graph[cop.from].position else position
	drive(cop, laneTarget(fromPos, toNode.position), POLICE.PatrolSpeed, dt, now)
end

local function chase(cop: Cop, player: Player, dt: number, now: number)
	local root = rootOf(player)
	if not root then
		returnToPatrol(cop)
		return
	end
	local position = cop.chassis.Position
	local toPlayer = root.Position - position
	local distance = toPlayer.Magnitude
	cop.sees = distance <= POLICE.SightRange and hasLineOfSight(cop, root)

	local character = root.Parent
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local onFoot = humanoid ~= nil and humanoid.SeatPart == nil

	if cop.sees and onFoot and distance <= POLICE.ShootRange then
		local fleeing = root.AssemblyLinearVelocity.Magnitude > POLICE.BustMaxSpeed
		if fleeing then
			-- a runner gets warning shots from the car window
			drive(cop, root.Position, 0, dt, now)
			if now - cop.lastShot >= POLICE.ShootInterval then
				cop.lastShot = now
				CombatService.policeShoot(position + cop.chassis.CFrame.UpVector * 4, player)
			end
		else
			-- someone standing still gets arrested, not shot: pull up next to them
			drive(cop, root.Position, math.clamp(distance - 12, 0, 30), dt, now)
		end
		return
	end

	if cop.sees then
		local targetVelocity = root.AssemblyLinearVelocity
		local lead = if distance > 30 then targetVelocity * math.clamp(distance / 120, 0, 0.6) else Vector3.zero
		local desired = if distance < 25 then math.max(targetVelocity.Magnitude, 8) else TUNING.MaxSpeed
		drive(cop, root.Position + lead, desired, dt, now)
		cop.path = {}
		return
	end

	-- out of sight: follow the roads toward the player's last area
	if now >= cop.nextPathTime or #cop.path == 0 then
		cop.nextPathTime = now + 1
		cop.path = findPath(nearestNode(position), nearestNode(root.Position))
		if #cop.path == 0 then
			drive(cop, root.Position, TUNING.MaxSpeed * 0.6, dt, now)
			return
		end
	end
	local nextNode = graph[cop.path[1]]
	local flatDistance = (Vector3.new(nextNode.position.X, position.Y, nextNode.position.Z) - position).Magnitude
	if flatDistance < ARRIVE_DISTANCE and #cop.path > 1 then
		table.remove(cop.path, 1)
		nextNode = graph[cop.path[1]]
	end
	drive(cop, laneTarget(position, nextNode.position), TUNING.MaxSpeed * 0.9, dt, now)
end

local function updateDisabled(cop: Cop, now: number): boolean
	if cop.disabledUntil > now then
		VehicleService.setAIInput(cop.car, { throttle = 0, steer = 0, parked = true })
		return true
	end
	if cop.health <= 0 then
		cop.health = POLICE.CarHealth
		local smoke = cop.chassis:FindFirstChild("DisabledSmoke") :: Smoke?
		if smoke then
			smoke.Enabled = false
		end
	end
	return false
end

local function onCopHit(car: Model, _shooter: Player)
	for _, cop in cops do
		if cop.car == car and cop.disabledUntil <= os.clock() then
			cop.health -= 1
			if cop.health <= 0 then
				cop.disabledUntil = os.clock() + POLICE.DisabledSeconds
				local smoke = cop.chassis:FindFirstChild("DisabledSmoke") :: Smoke?
				if smoke then
					smoke.Enabled = true
				end
				local target = cop.target
				returnToPatrol(cop)
				if target then
					assignPursuers(target)
				end
			end
			return
		end
	end
end

local function updateBust(player: Player, dt: number)
	local root = rootOf(player)
	if not root then
		return
	end
	local close = false
	for _, cop in cops do
		if cop.target == player and cop.disabledUntil <= os.clock() then
			if (cop.chassis.Position - root.Position).Magnitude <= POLICE.BustDistance then
				close = true
				break
			end
		end
	end
	local progress = bustProgress[player] or 0
	if close and root.AssemblyLinearVelocity.Magnitude <= POLICE.BustMaxSpeed then
		progress += dt / POLICE.BustSeconds
	else
		progress = math.max(0, progress - dt / POLICE.BustSeconds)
	end
	bustProgress[player] = progress
	player:SetAttribute("BustProgress", math.floor(progress * 20) / 20)
	if progress >= 1 then
		PoliceService.bust(player)
	end
end

local maintenanceTimer = 0

local function update(dt: number)
	local now = os.clock()
	for _, cop in table.clone(cops) do
		if not cop.car.Parent then
			local index = table.find(cops, cop)
			if index then
				table.remove(cops, index)
			end
			continue
		end
		if updateDisabled(cop, now) then
			continue
		end
		local target = cop.target
		if target and target.Parent then
			chase(cop, target, dt, now)
		else
			if target then
				returnToPatrol(cop)
			end
			cop.sees = false
			patrol(cop, dt, now)
		end
	end

	for _, player in Players:GetPlayers() do
		if HeatService.isWanted(player) then
			local seen = false
			for _, cop in cops do
				if cop.target == player and cop.sees then
					seen = true
					break
				end
			end
			HeatService.add(player, (if seen then POLICE.SeenHeatPerSecond else -POLICE.UnseenExtraDecayPerSecond) * dt)
			updateBust(player, dt)
		end
	end

	maintenanceTimer += dt
	if maintenanceTimer >= 2 then
		maintenanceTimer = 0
		for _, player in Players:GetPlayers() do
			if HeatService.isWanted(player) then
				assignPursuers(player)
			end
		end
		-- retire extra backup cops once they're idle and nobody is around to see it
		if #cops > POLICE.PatrolCount then
			for _, cop in table.clone(cops) do
				if #cops <= POLICE.PatrolCount then
					break
				end
				if cop.target == nil then
					local nearPlayer = false
					for _, player in Players:GetPlayers() do
						local root = rootOf(player)
						if root and (root.Position - cop.chassis.Position).Magnitude < 300 then
							nearPlayer = true
						end
					end
					if not nearPlayer then
						removeCop(cop)
					end
				end
			end
		end
	end
end

function PoliceService.init()
	if not loadGraph() then
		warn("[PoliceService] No Workspace.Map.RoadGraph; police are disabled. Build the map with MapBuilder.")
		return
	end

	HeatService.onWantedChanged(function(player, isWanted)
		if isWanted then
			assignPursuers(player)
			notice:FireClient(player, "wanted", "WANTED! Lose the cops.")
		else
			releasePursuers(player)
		end
	end)

	CombatService.onCopHit(onCopHit)
	CombatService.setKnockoutHandler(function(player)
		if HeatService.isWanted(player) then
			PoliceService.bust(player, true)
			return true
		end
		return false
	end)

	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(function(character)
			if releaseOnSpawn[player] then
				releaseOnSpawn[player] = nil
				local point = releasePoint()
				if point then
					task.defer(function()
						character:PivotTo(point)
					end)
				end
			end
		end)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		releasePursuers(player)
		releaseOnSpawn[player] = nil
	end)

	-- spread the patrol cars across the map
	local shuffled = table.clone(nodeIds)
	for i = #shuffled, 2, -1 do
		local j = rng:NextInteger(1, i)
		shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
	end
	for i = 1, math.min(POLICE.PatrolCount, #shuffled) do
		spawnCop(shuffled[i])
	end

	RunService.Heartbeat:Connect(update)
end

return PoliceService
