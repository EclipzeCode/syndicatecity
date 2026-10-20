--!strict
-- Shared AI driving for police and traffic cars on the road graph: steering toward a target with
-- the stuck/reverse fallback, following a lane between two nodes, routing along the graph, and
-- road manners:
--   * brakes for anything in its lane ahead (cars, people on foot) and stops short of it
--   * if something sits in the way for a while, pulls out and drives around it
--   * notices being hit hard and by whom (lastImpact), so callers can react
-- Callers own the decisions (where to go, how fast); this only drives.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local RoadGraph = require(script.Parent.RoadGraph)
local VehicleService = require(script.Parent.Parent.Services.VehicleService)

local DRIVING = Config.Driving
local LANE_OFFSET = 9
local ARRIVE_DISTANCE = 22
-- leaving a junction, cars first make for their lane this far down the new road
local JUNCTION_EXIT = 26

local Driver = {}

-- Something on the road: a car or a person on foot, and the player behind it if any.
export type Obstacle = {
	instance: Instance,
	position: Vector3,
	velocity: Vector3,
	radius: number,
	player: Player?,
}

export type Impact = { player: Player, strength: number, time: number }

export type State = {
	car: Model,
	chassis: BasePart,
	from: string?,
	to: string,
	path: { string },
	nextPathTime: number,
	stuckTime: number,
	reverseUntil: number,
	reverses: { number },
	needsRespawn: boolean,
	-- what's stopping it, for how long, and when it pulled out to go around
	blockedBy: Obstacle?,
	blockedFor: number,
	passUntil: number,
	-- what it's going around
	passing: Instance?,
	lastVelocity: Vector3,
	lastVelocityAt: number,
	lastImpact: Impact?,
}

export type Options = {
	-- don't brake for these (the car being chased, for instance)
	ignore: { [Instance]: boolean }?,
	-- no braking for obstacles at all
	reckless: boolean?,
}

local obstacles: { Obstacle } = {}
local scannedAt = -1

function Driver.new(car: Model, from: string?, to: string): State
	return {
		car = car,
		chassis = car.PrimaryPart :: BasePart,
		from = from,
		to = to,
		path = {},
		nextPathTime = 0,
		stuckTime = 0,
		reverseUntil = 0,
		reverses = {},
		needsRespawn = false,
		blockedBy = nil,
		blockedFor = 0,
		passUntil = 0,
		passing = nil,
		lastVelocity = Vector3.zero,
		lastVelocityAt = 0,
		lastImpact = nil,
	}
end

-- Aim for the right-hand lane of the road between two nodes.
function Driver.laneTarget(fromPos: Vector3, toPos: Vector3): Vector3
	local flat = Vector3.new(toPos.X - fromPos.X, 0, toPos.Z - fromPos.Z)
	if flat.Magnitude < 1 then
		return toPos
	end
	local right = flat.Unit:Cross(Vector3.yAxis)
	return toPos + right * LANE_OFFSET
end

-- Refreshes the list of cars and people on foot, once per frame however many callers ask.
function Driver.scan()
	local stamp = workspace.DistributedGameTime
	if stamp == scannedAt then
		return
	end
	scannedAt = stamp
	table.clear(obstacles)
	for _, instance in CollectionService:GetTagged("Vehicle") do
		local car = instance :: Model
		local chassis = car.PrimaryPart
		if chassis and car:IsDescendantOf(workspace) then
			table.insert(obstacles, {
				instance = car,
				position = chassis.Position,
				velocity = chassis.AssemblyLinearVelocity,
				radius = chassis.Size.Z / 2,
				player = VehicleService.getDriver(car),
			})
		end
	end
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 and humanoid.SeatPart == nil then
			table.insert(obstacles, {
				instance = character :: Model,
				position = root.Position,
				velocity = root.AssemblyLinearVelocity,
				radius = 1.5,
				player = player,
			})
		end
	end
end

-- The nearest obstacle in this car's lane ahead, within braking range at `speed`.
function Driver.obstacleAhead(state: State, speed: number, ignore: { [Instance]: boolean }?): (number, Obstacle?)
	local cf = state.chassis.CFrame
	local ownHalf = state.chassis.Size.Z / 2
	local reach = DRIVING.LookAhead + math.max(speed, 0) * DRIVING.LookAheadPerSpeed
	local best, bestObstacle = math.huge, nil
	for _, obstacle in obstacles do
		if obstacle.instance == state.car or (ignore and ignore[obstacle.instance]) then
			continue
		end
		local rel = cf:PointToObjectSpace(obstacle.position)
		local ahead = -rel.Z - ownHalf - obstacle.radius
		if ahead > -1 and ahead < reach and math.abs(rel.X) < DRIVING.LaneHalfWidth and math.abs(rel.Y) < 12 then
			if ahead < best then
				best, bestObstacle = ahead, obstacle
			end
		end
	end
	return best, bestObstacle
end

-- A stable number per car, to break ties at a crossing the same way for both cars.
local tieBreak: { [Instance]: number } = setmetatable({}, { __mode = "k" }) :: any
local nextTieBreak = 0
local function tieId(instance: Instance): number
	local id = tieBreak[instance]
	if not id then
		nextTieBreak += 1
		id = nextTieBreak
		tieBreak[instance] = id
	end
	return id
end

-- Whether a strip of road is free of other cars and people: `offset` studs to the side of this
-- car (negative is left), from `from` to `to` studs ahead (negative is behind). `except` is
-- left out (the car being passed).
local function stripClear(state: State, offset: number, from: number, to: number, except: Instance?): boolean
	local cf = state.chassis.CFrame
	for _, obstacle in obstacles do
		if obstacle.instance == state.car or obstacle.instance == except then
			continue
		end
		local rel = cf:PointToObjectSpace(obstacle.position)
		local ahead = -rel.Z
		if math.abs(rel.X - offset) < DRIVING.LaneHalfWidth and ahead > from and ahead < to and math.abs(rel.Y) < 12 then
			return false
		end
	end
	return true
end

-- Crossing traffic: another car whose path crosses this one's in the next few seconds. Whichever
-- would get to the crossing later gives way (and AI cars always give way to players). Returns
-- how far ahead the crossing is and the car to give way to, or nil when there's nothing to wait
-- for. Cars going the same or the opposite way are left to the lane checks.
local CONFLICT_HORIZON = 3
local CONFLICT_SEPARATION = 1.5
local function crossingAhead(state: State, speed: number, intended: number, ignore: { [Instance]: boolean }?): (number, Obstacle?)
	local cf = state.chassis.CFrame
	local look = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
	if look.Magnitude < 0.1 then
		return math.huge, nil
	end
	local u = look.Unit
	local p = cf.Position
	-- a car waiting at a junction still checks as if it were about to go
	local ourSpeed = math.max(speed, math.min(intended, 12), 6)
	local best, bestObstacle = math.huge, nil
	for _, obstacle in obstacles do
		-- cars only (people on foot are handled by the lane check)
		if obstacle.instance == state.car or (ignore and ignore[obstacle.instance]) or obstacle.radius < 2 then
			continue
		end
		local w = Vector3.new(obstacle.velocity.X, 0, obstacle.velocity.Z)
		local theirSpeed = w.Magnitude
		if theirSpeed < 3 then
			continue
		end
		local h = w / theirSpeed
		if math.abs(u:Dot(h)) > 0.8 then
			continue
		end
		-- where the two paths cross: p + u * s = q + h * t
		local d = obstacle.position - p
		local denom = u.X * h.Z - u.Z * h.X
		local s = (d.X * h.Z - d.Z * h.X) / denom
		local t = (d.X * u.Z - d.Z * u.X) / denom
		-- already in the crossing (keep going to clear it), it's past it, or it's far away
		if s < 5 or t < -6 or s > 70 then
			continue
		end
		local ourTime = s / ourSpeed
		local theirTime = math.max(t, 0) / theirSpeed
		if ourTime > CONFLICT_HORIZON or theirTime > CONFLICT_HORIZON or math.abs(ourTime - theirTime) > CONFLICT_SEPARATION then
			continue
		end
		-- a car already in the crossing has it, however slow it is
		local giveWay = obstacle.player ~= nil
			or t < 8
			or ourTime > theirTime + 0.15
			or (math.abs(ourTime - theirTime) <= 0.15 and tieId(state.car) > tieId(obstacle.instance))
		if giveWay and s < best then
			best, bestObstacle = s, obstacle
		end
	end
	return best, bestObstacle
end

-- Watches for a hard knock (a sudden change of velocity) with a player's car close by and
-- coming this way, and records who did it in state.lastImpact.
local function checkImpact(state: State, now: number)
	local velocity = state.chassis.AssemblyLinearVelocity
	local change = (velocity - state.lastVelocity).Magnitude
	-- only a change between consecutive frames is a knock; a car that wasn't driven for a while
	-- (disabled, just spawned) has a stale reading
	local fresh = now - state.lastVelocityAt < 0.1
	state.lastVelocity = velocity
	state.lastVelocityAt = now
	if not fresh or change < DRIVING.ImpactDeltaV then
		return
	end
	local position = state.chassis.Position
	for _, obstacle in obstacles do
		local player = obstacle.player
		if player and obstacle.instance ~= state.car and (obstacle.position - position).Magnitude < DRIVING.ImpactRange then
			local toward = (position - obstacle.position)
			local closing = if toward.Magnitude > 0.1 then obstacle.velocity:Dot(toward.Unit) else 0
			if closing > DRIVING.ImpactClosingSpeed or change > DRIVING.ImpactDeltaV * 2 then
				state.lastImpact = { player = player, strength = change, time = now }
				return
			end
		end
	end
end

-- Steers toward `target` at up to `desiredSpeed`, slowing for sharp turns and for anything in
-- the lane, reversing out of jams.
function Driver.drive(state: State, target: Vector3, desiredSpeed: number, dt: number, now: number, options: Options?)
	Driver.scan()
	checkImpact(state, now)
	local cf = state.chassis.CFrame
	local speed = state.chassis.AssemblyLinearVelocity:Dot(cf.LookVector)

	-- going around something: aim a lane over to the left and keep it slow, and give up the
	-- moment anything comes the other way in that lane
	local passing = now < state.passUntil
	if passing and not stripClear(state, -LANE_OFFSET * 1.2, -2, DRIVING.PassLookAhead, state.passing) then
		state.passUntil = now
		passing = false
	end
	if passing then
		target += -cf.RightVector * LANE_OFFSET * 1.2
		desiredSpeed = math.min(desiredSpeed, DRIVING.PassSpeed)
	end

	local rel = cf:PointToObjectSpace(target)
	local angle = math.atan2(rel.X, -rel.Z) -- positive: target is to the right
	local steer = math.clamp(angle * 2.2, -1, 1)

	if now < state.reverseUntil then
		-- never back into someone
		if stripClear(state, 0, -(state.chassis.Size.Z + 8), 0) then
			VehicleService.setAIInput(state.car, { throttle = -1, steer = -steer })
			return
		end
		state.reverseUntil = now
	end

	-- slow down for sharp turns
	local turnFactor = math.clamp(1 - math.abs(angle) / math.rad(100), 0.3, 1)
	local targetSpeed = desiredSpeed * turnFactor

	-- road manners: stop short of whatever is in the lane
	local opts = options or {}
	state.blockedBy = nil
	local crossingBlock = false
	if not opts.reckless and not passing then
		local gap, obstacle = Driver.obstacleAhead(state, speed, opts.ignore)
		if obstacle then
			local allowed = math.max(0, (gap - DRIVING.StopGap) * DRIVING.BrakeEagerness)
			-- moving away from us? we can follow at its pace
			local along = obstacle.velocity:Dot(cf.LookVector)
			if along > 2 then
				allowed = math.max(allowed, along * 0.9)
			end
			if allowed < targetSpeed then
				targetSpeed = allowed
				state.blockedBy = obstacle
			end
		end
		-- give way to crossing traffic: stop short of where the paths cross
		local crossAt, crossing = crossingAhead(state, speed, targetSpeed, opts.ignore)
		if crossing then
			local allowed = math.max(0, (crossAt - DRIVING.CrossingGap) * DRIVING.BrakeEagerness)
			if allowed < targetSpeed then
				targetSpeed = allowed
				state.blockedBy = crossing
				crossingBlock = true
			end
		end
	end
	-- stuck behind something that isn't moving: go around it once the other lane is clear (never
	-- around crossing traffic, which will be gone in a moment)
	if state.blockedBy and not crossingBlock and math.abs(speed) < 3 then
		state.blockedFor += dt
		if state.blockedFor >= DRIVING.PassAfterSeconds then
			local blocker = state.blockedBy :: Obstacle
			if stripClear(state, -LANE_OFFSET * 1.2, -12, DRIVING.PassLookAhead, blocker.instance) then
				state.blockedFor = 0
				state.passUntil = now + DRIVING.PassSeconds
				state.passing = blocker.instance
			end
		end
	elseif not state.blockedBy then
		state.blockedFor = 0
	end

	local throttle = math.clamp((targetSpeed - speed) / 8, -1, 1)
	if throttle > 0.3 and math.abs(speed) < 3 then
		state.stuckTime += dt
		if state.stuckTime > 1.5 then
			state.stuckTime = 0
			state.reverseUntil = now + 1.3
			-- a car that keeps backing out of the same jam gets replaced
			table.insert(state.reverses, now)
			while state.reverses[1] and now - state.reverses[1] > Config.Police.StuckWindowSeconds do
				table.remove(state.reverses, 1)
			end
			if #state.reverses >= Config.Police.StuckReversesBeforeRespawn then
				state.needsRespawn = true
			end
		end
	else
		state.stuckTime = 0
	end
	VehicleService.setAIInput(state.car, {
		throttle = throttle,
		steer = steer,
		parked = targetSpeed < 0.5 and math.abs(speed) < 4,
	})
end

-- When the car reaches the node it's heading for, picks the next with `choose` (given the node
-- it just reached). Returns true when it arrived somewhere this call.
function Driver.advance(state: State, choose: (state: State) -> string): boolean
	local nodes = RoadGraph.nodes
	if not nodes[state.to] then
		state.from, state.to = nil, RoadGraph.nearest(state.chassis.Position)
	end
	local toNode = nodes[state.to]
	local position = state.chassis.Position
	if (Vector3.new(toNode.position.X, position.Y, toNode.position.Z) - position).Magnitude < ARRIVE_DISTANCE then
		local nextId = choose(state)
		state.from = state.to
		state.to = nextId
		return true
	end
	return false
end

-- Drives the lane from state.from to state.to. Coming out of a junction it first aims for the
-- start of its new lane just past the junction, so turns go round the corner in the right lane
-- instead of cutting across the oncoming one toward a point far down the next road.
function Driver.cruise(state: State, speed: number, dt: number, now: number, options: Options?)
	local nodes = RoadGraph.nodes
	local toNode = nodes[state.to]
	local fromNode = if state.from then nodes[state.from] else nil
	local fromPos = if fromNode then fromNode.position else state.chassis.Position
	local target = Driver.laneTarget(fromPos, toNode.position)
	if fromNode then
		local flat = Vector3.new(toNode.position.X - fromPos.X, 0, toNode.position.Z - fromPos.Z)
		local position = state.chassis.Position
		local offset = Vector3.new(position.X - fromPos.X, 0, position.Z - fromPos.Z)
		if flat.Magnitude > JUNCTION_EXIT * 2 and offset.Magnitude < JUNCTION_EXIT + 20 then
			local dir = flat.Unit
			if offset:Dot(dir) < JUNCTION_EXIT - 6 then
				target = fromPos + dir * JUNCTION_EXIT + dir:Cross(Vector3.yAxis) * LANE_OFFSET
			end
		end
	end
	Driver.drive(state, target, speed, dt, now, options)
end

-- A random next node that isn't straight back, unless it's a dead end.
function Driver.randomNext(state: State, rng: Random): string
	local here = RoadGraph.nodes[state.to]
	local options = {}
	for _, id in here.links do
		if id ~= state.from then
			table.insert(options, id)
		end
	end
	if #options == 0 then
		return state.from or here.links[1]
	end
	return options[rng:NextInteger(1, #options)]
end

-- The road kind between state.from and state.to ("street", "highway", ...).
function Driver.roadKind(state: State): string
	local from = state.from and RoadGraph.nodes[state.from]
	return if from then from.kinds[state.to] or "street" else "street"
end

-- Follows the roads toward a point out of sight, re-planning once a second.
function Driver.followRoads(state: State, targetPosition: Vector3, speed: number, dt: number, now: number, options: Options?)
	local nodes = RoadGraph.nodes
	local position = state.chassis.Position
	if now >= state.nextPathTime or #state.path == 0 then
		state.nextPathTime = now + 1
		state.path = RoadGraph.findPath(RoadGraph.nearest(position), RoadGraph.nearest(targetPosition))
		if #state.path == 0 then
			Driver.drive(state, targetPosition, speed * 0.6, dt, now, options)
			return
		end
	end
	local nextNode = nodes[state.path[1]]
	local flatDistance = (Vector3.new(nextNode.position.X, position.Y, nextNode.position.Z) - position).Magnitude
	if flatDistance < ARRIVE_DISTANCE and #state.path > 1 then
		table.remove(state.path, 1)
		nextNode = nodes[state.path[1]]
	end
	Driver.drive(state, Driver.laneTarget(position, nextNode.position), speed, dt, now, options)
end

-- Ignores a player's car and character (for chasing or tailing them).
function Driver.ignoring(player: Player): { [Instance]: boolean }
	local ignore: { [Instance]: boolean } = {}
	if player.Character then
		ignore[player.Character] = true
	end
	local car = VehicleService.getOccupiedCar(player)
	if car then
		ignore[car] = true
	end
	return ignore
end

-- Where a new car goes: partway along a road between two nodes, in the right-hand lane, facing
-- along it. Cars start out of sight and away from junctions, with room around them, so they
-- don't spawn into each other.
export type Spawn = { cframe: CFrame, from: string, to: string }

export type SpawnOptions = {
	-- only roads starting in this district
	district: string?,
	-- distance band from `around` (or from the nearest player when `around` is nil)
	near: NumberRange?,
	around: Vector3?,
}

-- out of sight of every player
local HIDDEN_DISTANCE = 250
-- no other car closer than this, in any direction
local SPAWN_CLEARANCE = 45
-- and none in the same lane this far ahead or behind (a car coming up behind would rear-end
-- the new one while it gets going; one just ahead would be hit right away)
local SPAWN_LANE_GAP = 90
-- start at least this far from either node, so cars don't appear in the middle of a junction
local SPAWN_NODE_MARGIN = 30
-- the chassis sits this far above the road surface when it appears
local SPAWN_HEIGHT = 4

local spawnRayParams = RaycastParams.new()
spawnRayParams.FilterType = Enum.RaycastFilterType.Exclude
spawnRayParams.RespectCanCollide = true

local function playerPositions(): { Vector3 }
	local positions = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			table.insert(positions, root.Position)
		end
	end
	return positions
end

local function nearestOf(positions: { Vector3 }, point: Vector3): number
	local nearest = math.huge
	for _, position in positions do
		nearest = math.min(nearest, (position - point).Magnitude)
	end
	return nearest
end

-- Whether a car facing `cframe` has room: nothing close by, and nothing in its lane just ahead
-- or behind.
function Driver.spawnClear(cframe: CFrame): boolean
	for _, instance in CollectionService:GetTagged("Vehicle") do
		local chassis = (instance :: Model).PrimaryPart
		if not chassis or not instance:IsDescendantOf(workspace) then
			continue
		end
		local rel = cframe:PointToObjectSpace(chassis.Position)
		if rel.Magnitude < SPAWN_CLEARANCE then
			return false
		end
		if math.abs(rel.X) < DRIVING.LaneHalfWidth + 4 and math.abs(rel.Z) < SPAWN_LANE_GAP and math.abs(rel.Y) < 20 then
			return false
		end
	end
	return true
end

-- The road surface under a lane point, or nil when there's no road there (a lane off the edge
-- of a narrow road, a gap in the map).
local function roadHeight(point: Vector3): number?
	spawnRayParams.FilterDescendantsInstances = CollectionService:GetTagged("Vehicle")
	local result = workspace:Raycast(point + Vector3.new(0, 40, 0), Vector3.new(0, -80, 0), spawnRayParams)
	if result and result.Instance:GetAttribute("Surface") ~= nil then
		return result.Position.Y
	end
	return nil
end

-- A spot for a new car (see Spawn), or nil when there's no free one right now; callers try again
-- later. Prefers roads out of sight; falls back to any road with room.
function Driver.findSpawn(rng: Random, options: SpawnOptions?): Spawn?
	local opts = options or {}
	local nodes = RoadGraph.nodes
	local players = playerPositions()
	-- every road (both directions) leaving a node in the district, long enough to start on
	local segments: { { from: string, to: string } } = {}
	for _, id in RoadGraph.ids do
		local node = nodes[id]
		if opts.district == nil or node.district == opts.district then
			for _, other in node.links do
				if (nodes[other].position - node.position).Magnitude >= SPAWN_NODE_MARGIN * 2 + 10 then
					table.insert(segments, { from = id, to = other })
				end
			end
		end
	end
	if #segments == 0 then
		return nil
	end

	local function attempt(strict: boolean): Spawn?
		for _ = 1, 40 do
			local segment = segments[rng:NextInteger(1, #segments)]
			local a, b = nodes[segment.from].position, nodes[segment.to].position
			local length = (b - a).Magnitude
			local along = rng:NextNumber(SPAWN_NODE_MARGIN, length - SPAWN_NODE_MARGIN)
			local direction = (b - a).Unit
			local flat = Vector3.new(direction.X, 0, direction.Z)
			if flat.Magnitude < 0.1 then
				continue
			end
			local right = flat.Unit:Cross(Vector3.yAxis)
			local point = a + direction * along + right * LANE_OFFSET
			if strict then
				local nearest = nearestOf(players, point)
				if nearest < HIDDEN_DISTANCE then
					continue
				end
				local band = opts.near
				if band then
					local distance = if opts.around then (opts.around - point).Magnitude else nearest
					if distance ~= math.huge and (distance < band.Min or distance > band.Max) then
						continue
					end
				end
			elseif nearestOf(players, point) < 60 then
				-- never right on top of someone, even as a last resort
				continue
			end
			local ground = roadHeight(point)
			if not ground then
				continue
			end
			local position = Vector3.new(point.X, ground + SPAWN_HEIGHT, point.Z)
			-- face along the road, level with its slope
			local cframe = CFrame.lookAt(position, position + direction)
			if Driver.spawnClear(cframe) then
				return { cframe = cframe, from = segment.from, to = segment.to }
			end
		end
		return nil
	end
	return attempt(true) or attempt(false)
end

return Driver
