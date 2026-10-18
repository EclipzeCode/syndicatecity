--!strict
-- Police AI. Patrol cars work district beats on the road graph (Workspace.Map.RoadGraph) and
-- keep an eye on the players around them. Each car runs a small state machine (see
-- Police/Suspicion): it notices suspicious behavior it can actually see (speeding, cargo up
-- close), builds suspicion while that lasts, tails the player if it gets suspicious enough, and
-- calls a pursuit if the player keeps it up. Driving clean lets suspicion decay and the patrol
-- goes back to its beat.
--
-- Pursuits are the wanted state: when a player becomes wanted (from a patrol escalating, or heat
-- from anything else), the nearest cops switch on their sirens and chase: straight at the player
-- while they can see them, along the road graph when they can't. A cop that stays close to a slow
-- or stopped player busts them. Cops shoot only at wanted players on foot, and can be disabled by
-- shooting their car.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Palette = require(ReplicatedStorage.Shared.Palette)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Driver = require(script.Parent.Parent.Navigation.Driver)
local RoadGraph = require(script.Parent.Parent.Navigation.RoadGraph)
local Suspicion = require(script.Parent.Parent.Police.Suspicion)
local CombatService = require(script.Parent.CombatService)
local HeatService = require(script.Parent.HeatService)
local JobService = require(script.Parent.JobService)
local PlayerDataService = require(script.Parent.PlayerDataService)
local VehicleService = require(script.Parent.VehicleService)
local WorldService = require(script.Parent.WorldService)

local POLICE = Config.Police
local DETECT = POLICE.Detection
local TUNING = Config.Vehicles.Types.Police
local IS_STUDIO = RunService:IsStudio()

local SUSPICION: Suspicion.Config = {
	SpeedingPerSecond = DETECT.SpeedingPerSecond,
	SpeedingFullOver = Config.Heat.SpeedingFullOver,
	CargoPerSecond = DETECT.CargoPerSecond,
	CargoSuspicionCap = DETECT.CargoSuspicionCap,
	HeatMultiplier = DETECT.HeatMultiplier,
	DecayPerSecond = DETECT.DecayPerSecond,
	InvestigateThreshold = DETECT.InvestigateThreshold,
	PursuitThreshold = DETECT.PursuitThreshold,
	ClearThreshold = DETECT.ClearThreshold,
	LoseSightSeconds = DETECT.LoseSightSeconds,
	InvestigateMaxSeconds = DETECT.InvestigateMaxSeconds,
}
local NOTHING_SEEN: Suspicion.Observation = { speedOver = 0, cargoRisk = 0, heat = 0 }

type Cop = {
	car: Model,
	chassis: BasePart,
	-- where it's going and how (lane, route, jams, what's in its way): see Navigation/Driver
	driver: Driver.State,
	-- the district this car patrols; nil for backup cars called in for a pursuit
	beat: string?,
	state: Suspicion.State,
	stateSince: number,
	-- the player being pursued (Pursuing)
	target: Player?,
	-- the player being observed or investigated, how suspicious they look, and when last seen
	watch: Player?,
	suspicion: number,
	lastSeen: number,
	-- players this car leaves alone until the given time (after an encounter)
	ignoreUntil: { [Player]: number },
	health: number,
	disabledUntil: number,
	lastShot: number,
	sees: boolean,
}

local PoliceService = {}

local nodes = RoadGraph.nodes
local cops: { Cop } = {}
local beatCenters: { [string]: Vector3 } = {}
local bustProgress: { [Player]: number } = {}
local releaseOnSpawn: { [Player]: boolean } = {}
local attention: { [Player]: string } = {}
local rng = Random.new()

local notice = Remotes.event("Notice")

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

---------------------------------------------------------------------------------------------------
-- Cops
---------------------------------------------------------------------------------------------------

local function setSiren(cop: Cop, on: boolean)
	cop.car:SetAttribute("Siren", on)
end

-- The state is on the car as an attribute so it's easy to watch in Studio while debugging.
local function setState(cop: Cop, state: Suspicion.State)
	cop.state = state
	cop.stateSince = os.clock()
	cop.car:SetAttribute("PoliceState", state)
end

local function spawnCop(nodeId: string, beat: string?): Cop
	local cframe, nextId = Driver.spawnFrame(nodeId, rng)
	local car = VehicleService.spawn("Police", Palette.PoliceWhite, cframe)
	-- headlights on only at night
	WorldService.autoHeadlights(car)
	local chassis = car.PrimaryPart :: BasePart
	CollectionService:AddTag(chassis, Config.Tags.Patrol)
	car:SetAttribute("Siren", false)
	car:SetAttribute("Beat", beat or "Backup")

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
		driver = Driver.new(car, nodeId, nextId),
		beat = beat,
		state = "Patrolling",
		stateSince = os.clock(),
		target = nil,
		watch = nil,
		suspicion = 0,
		lastSeen = 0,
		ignoreUntil = {},
		health = POLICE.CarHealth,
		disabledUntil = 0,
		lastShot = 0,
		sees = false,
	}
	setState(cop, "Patrolling")
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

-- Back to the nearest road node, then on along its beat.
local function returnToRoute(cop: Cop)
	cop.driver.path = {}
	cop.driver.from = nil
	cop.driver.to = RoadGraph.nearest(cop.chassis.Position)
	setState(cop, "Returning")
end

-- Ends the car's observation or investigation. The player gets a breather from this car.
local function endEncounter(cop: Cop, nextState: Suspicion.State)
	local player = cop.watch
	if player then
		cop.ignoreUntil[player] = os.clock() + DETECT.CooldownSeconds
	end
	cop.watch = nil
	cop.suspicion = 0
	if IS_STUDIO then
		cop.car:SetAttribute("Suspicion", nil)
	end
	if nextState == "Returning" then
		returnToRoute(cop)
	else
		setState(cop, nextState)
	end
end

local function returnToPatrol(cop: Cop)
	if cop.target then
		cop.ignoreUntil[cop.target] = os.clock() + DETECT.CooldownSeconds
	end
	cop.target = nil
	setSiren(cop, false)
	if cop.watch then
		endEncounter(cop, "Returning")
	else
		returnToRoute(cop)
	end
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

local function startPursuit(cop: Cop, player: Player)
	if cop.watch then
		-- quietly drop whatever else it was looking at
		cop.watch = nil
		cop.suspicion = 0
	end
	cop.target = player
	cop.driver.nextPathTime = 0
	setSiren(cop, true)
	setState(cop, "Pursuing")
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
	-- the car that was already investigating this player goes first, then the nearest
	table.sort(free, function(a, b)
		if (a.watch == player) ~= (b.watch == player) then
			return a.watch == player
		end
		return (a.chassis.Position - root.Position).Magnitude < (b.chassis.Position - root.Position).Magnitude
	end)
	for i = 1, math.min(needed, #free) do
		startPursuit(free[i], player)
	end
	needed -= #free
	-- call in backup from a road node out of sight
	while needed > 0 and #cops < POLICE.MaxCops do
		local candidates, fallback, fallbackDistance = {}, nil, math.huge
		for _, id in RoadGraph.ids do
			local d = (nodes[id].position - root.Position).Magnitude
			if d > 250 and d < 550 then
				table.insert(candidates, id)
			elseif d >= 550 and d < fallbackDistance then
				fallback, fallbackDistance = id, d
			end
		end
		local nodeId = if #candidates > 0 then candidates[rng:NextInteger(1, #candidates)] else fallback
		if not nodeId then
			break
		end
		startPursuit(spawnCop(nodeId, nil), player)
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

-- Drops every observation and investigation of a player (they left, or were arrested).
local function forgetPlayer(player: Player)
	for _, cop in cops do
		if cop.watch == player then
			endEncounter(cop, if cop.state == "Investigating" then "Returning" else "Patrolling")
		end
		cop.ignoreUntil[player] = nil
	end
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
	forgetPlayer(player)
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
-- Detection
---------------------------------------------------------------------------------------------------

-- What `cop` can see of `player` right now, or nil if it can't see them. Line of sight is only
-- checked when `needSight` (the player is being watched) or there is something to see.
local function observe(cop: Cop, player: Player, needSight: boolean): Suspicion.Observation?
	local root = rootOf(player)
	if not root then
		return nil
	end
	local distance = (root.Position - cop.chassis.Position).Magnitude
	if distance > DETECT.Range then
		return nil
	end
	local risk = JobService.getCargoRisk(player)
	local obs: Suspicion.Observation = {
		speedOver = HeatService.getSpeedOver(player),
		cargoRisk = if risk > 0 and distance <= DETECT.CargoRange * math.max(risk, 1) then risk else 0,
		heat = HeatService.getHeat(player) / Config.Heat.Max,
	}
	if not needSight and not Suspicion.isSuspicious(obs, SUSPICION) then
		return nil
	end
	-- rays are the expensive part, so they come last
	if DETECT.RequireLineOfSight and not hasLineOfSight(cop, root) then
		return nil
	end
	return obs
end

-- A patrolling car looks for the most suspicious player it can see and starts observing them.
local function lookAround(cop: Cop, now: number, watched: { [Player]: boolean })
	local best: Player?, bestRate = nil, 0
	for _, player in Players:GetPlayers() do
		if watched[player] or HeatService.isWanted(player) or (cop.ignoreUntil[player] or 0) > now then
			continue
		end
		local obs = observe(cop, player, false)
		if obs then
			local speeding, cargo = Suspicion.rates(obs, SUSPICION)
			if speeding + cargo > bestRate then
				best, bestRate = player, speeding + cargo
			end
		end
	end
	if best then
		cop.watch = best
		cop.suspicion = 0
		cop.lastSeen = now
		watched[best] = true
		setState(cop, "Observing")
	end
end

-- Advances an observation or investigation by dt, escalating or ending it as the rules say.
local function updateEncounter(cop: Cop, dt: number, now: number)
	local player = cop.watch :: Player
	if not player.Parent or HeatService.isWanted(player) then
		-- wanted players belong to the pursuit; assignPursuers prefers this car
		endEncounter(cop, if cop.state == "Investigating" then "Returning" else "Patrolling")
		return
	end
	local obs = observe(cop, player, true)
	if obs then
		cop.lastSeen = now
	end
	local before = cop.suspicion
	cop.suspicion = Suspicion.step(before, obs or NOTHING_SEEN, dt, SUSPICION)
	if cop.suspicion > before then
		HeatService.add(player, (cop.suspicion - before) * DETECT.HeatPerSuspicion)
	end
	if IS_STUDIO then
		cop.car:SetAttribute("Suspicion", math.floor(cop.suspicion))
	end

	local nextState = Suspicion.nextState(cop.state, cop.suspicion, now - cop.lastSeen, now - cop.stateSince, SUSPICION)
	if nextState == cop.state then
		return
	elseif nextState == "Investigating" then
		cop.driver.nextPathTime = 0
		setState(cop, "Investigating")
	elseif nextState == "Pursuing" then
		-- this car calls it in; reaching the wanted threshold brings the rest of the pursuit
		startPursuit(cop, player)
		HeatService.raiseTo(player, Config.Heat.WantedThreshold + 5)
	else
		endEncounter(cop, nextState)
	end
end

-- Mirrors the strongest attention on each player to their PoliceAttention attribute ("",
-- "watched", "tailed") for the HUD, with a notice when a tail starts or ends.
local function updateAttention()
	local levels: { [Player]: string } = {}
	for _, cop in cops do
		local player = cop.watch
		if player then
			if cop.state == "Investigating" then
				levels[player] = "tailed"
			elseif levels[player] == nil then
				levels[player] = "watched"
			end
		end
	end
	for _, player in Players:GetPlayers() do
		local level = levels[player] or ""
		local previous = attention[player] or ""
		if level ~= previous then
			attention[player] = level
			player:SetAttribute("PoliceAttention", level)
			if level == "tailed" then
				notice:FireClient(player, "tailed", "A patrol car is tailing you. Drive clean and it may lose interest.")
			elseif previous == "tailed" and not HeatService.isWanted(player) then
				notice:FireClient(player, "clear", "The patrol lost interest.")
			end
		end
	end
end

-- Turns a patrol car's attention to `player` (if it isn't already busy with someone else) and
-- adds `amount` suspicion. Returns false if it's busy.
local function jolt(cop: Cop, player: Player, amount: number, now: number): boolean
	if HeatService.isWanted(player) or (cop.watch and cop.watch ~= player) then
		return false
	end
	if not cop.watch then
		cop.watch = player
		cop.suspicion = 0
		setState(cop, "Observing")
	end
	cop.lastSeen = now
	local before = cop.suspicion
	cop.suspicion = Suspicion.bump(before, amount, SUSPICION)
	HeatService.add(player, (cop.suspicion - before) * DETECT.HeatPerSuspicion)
	return true
end

-- What the patrol car's own driving runs into: a player ramming it, or a player standing or
-- parked in its way who doesn't move.
local function reactToDriving(cop: Cop, dt: number, now: number)
	local driver = cop.driver
	local impact = driver.lastImpact
	if impact then
		driver.lastImpact = nil
		if now - impact.time < 1 then
			local scale = math.clamp(impact.strength / DETECT.RamFullImpact, 0.5, 2.5)
			jolt(cop, impact.player, DETECT.RamSuspicion * scale, now)
		end
	end
	local blocker = driver.blockedBy
	local player = blocker and blocker.player
	if player and cop.state ~= "Investigating" and driver.blockedFor >= DETECT.BlockPatienceSeconds then
		jolt(cop, player, DETECT.BlockSuspicionPerSecond * dt, now)
	end
end

local function detect(dt: number)
	local now = os.clock()
	-- one car per player at a time, so a player isn't stalked by a convoy
	local watched: { [Player]: boolean } = {}
	for _, cop in cops do
		if cop.watch then
			watched[cop.watch] = true
		end
	end
	for _, cop in cops do
		if cop.disabledUntil > now or cop.state == "Pursuing" then
			continue
		end
		if cop.watch then
			updateEncounter(cop, dt, now)
		else
			lookAround(cop, now, watched)
		end
		reactToDriving(cop, dt, now)
	end
	updateAttention()
end

---------------------------------------------------------------------------------------------------
-- Driving
---------------------------------------------------------------------------------------------------

-- The next node after arriving at `cop.driver.to`: on its beat when it can, heading back toward the
-- beat when it has wandered off it, never straight back unless it's a dead end.
local function nextPatrolNode(cop: Cop): string
	local here = nodes[cop.driver.to]
	local options, onBeat = {}, {}
	for _, id in here.links do
		if id ~= cop.driver.from then
			table.insert(options, id)
			if cop.beat and nodes[id].district == cop.beat then
				table.insert(onBeat, id)
			end
		end
	end
	if #options == 0 then
		return cop.driver.from or here.links[1]
	end
	local beat = cop.beat
	if beat and #onBeat > 0 and rng:NextNumber() < POLICE.BeatStayChance then
		return onBeat[rng:NextInteger(1, #onBeat)]
	elseif beat and #onBeat == 0 and here.district ~= beat and beatCenters[beat] then
		local center = beatCenters[beat]
		table.sort(options, function(a, b)
			return (nodes[a].position - center).Magnitude < (nodes[b].position - center).Magnitude
		end)
		return options[1]
	end
	return options[rng:NextInteger(1, #options)]
end

local function patrol(cop: Cop, speed: number, dt: number, now: number)
	local arrived = Driver.advance(cop.driver, function()
		return nextPatrolNode(cop)
	end)
	if arrived and cop.state == "Returning" then
		setState(cop, "Patrolling")
	end
	Driver.cruise(cop.driver, speed, dt, now)
end

-- Investigating: no sirens, just a car in the mirror that keeps about TailDistance back.
local function tail(cop: Cop, player: Player, dt: number, now: number)
	local root = rootOf(player)
	if not root then
		patrol(cop, POLICE.PatrolSpeed, dt, now)
		return
	end
	local distance = (root.Position - cop.chassis.Position).Magnitude
	if now - cop.lastSeen < 1 and distance < 160 then
		local playerSpeed = root.AssemblyLinearVelocity.Magnitude
		local desired = if distance > DETECT.TailDistance * 1.4
			then math.min(TUNING.MaxSpeed * 0.85, playerSpeed + 25)
			elseif distance < DETECT.TailDistance * 0.7 then math.max(0, playerSpeed - 10)
			else playerSpeed
		Driver.drive(cop.driver, root.Position, desired, dt, now, { ignore = Driver.ignoring(player) })
		cop.driver.path = {}
		return
	end
	Driver.followRoads(cop.driver, root.Position, TUNING.MaxSpeed * 0.75, dt, now, { ignore = Driver.ignoring(player) })
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

	local ignore = { ignore = Driver.ignoring(player) }
	local character = root.Parent
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local onFoot = humanoid ~= nil and humanoid.SeatPart == nil

	if cop.sees and onFoot and distance <= POLICE.ShootRange then
		local fleeing = root.AssemblyLinearVelocity.Magnitude > POLICE.BustMaxSpeed
		if fleeing then
			-- a runner gets warning shots from the car window
			Driver.drive(cop.driver, root.Position, 0, dt, now, ignore)
			if now - cop.lastShot >= POLICE.ShootInterval then
				cop.lastShot = now
				CombatService.policeShoot(position + cop.chassis.CFrame.UpVector * 4, player)
			end
		else
			-- someone standing still gets arrested, not shot: pull up next to them
			Driver.drive(cop.driver, root.Position, math.clamp(distance - 12, 0, 30), dt, now, ignore)
		end
		return
	end

	if cop.sees then
		local targetVelocity = root.AssemblyLinearVelocity
		local lead = if distance > 30 then targetVelocity * math.clamp(distance / 120, 0, 0.6) else Vector3.zero
		local desired = if distance < 25 then math.max(targetVelocity.Magnitude, 8) else TUNING.MaxSpeed
		Driver.drive(cop.driver, root.Position + lead, desired, dt, now, ignore)
		cop.driver.path = {}
		return
	end

	Driver.followRoads(cop.driver, root.Position, TUNING.MaxSpeed * 0.9, dt, now, ignore)
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

---------------------------------------------------------------------------------------------------
-- Upkeep
---------------------------------------------------------------------------------------------------

-- Replaces cars that sank, fell off the map or keep getting stuck, and tops patrol beats back up.
local function maintainFleet()
	for _, cop in table.clone(cops) do
		local lost = not cop.car.Parent or cop.chassis.Position.Y < -4
		if lost or cop.driver.needsRespawn then
			local target = cop.target
			local beat = cop.beat
			if cop.watch then
				endEncounter(cop, "Patrolling")
			end
			removeCop(cop)
			-- backup cars only come back while their pursuit is on
			if beat or target then
				local replacement = spawnCop(Driver.spawnNode(rng, beat), beat)
				if target and HeatService.isWanted(target) then
					startPursuit(replacement, target)
				end
			end
		end
	end
	for beat, count in POLICE.Beats do
		local have = 0
		for _, cop in cops do
			if cop.beat == beat then
				have += 1
			end
		end
		for _ = have + 1, count do
			spawnCop(Driver.spawnNode(rng, beat), beat)
		end
	end
	-- retire backup cars once they're idle and nobody is around to see it
	for _, cop in table.clone(cops) do
		if cop.beat == nil and cop.target == nil then
			local nearPlayer = false
			for _, player in Players:GetPlayers() do
				local root = rootOf(player)
				if root and (root.Position - cop.chassis.Position).Magnitude < 300 then
					nearPlayer = true
				end
			end
			if not nearPlayer then
				if cop.watch then
					endEncounter(cop, "Patrolling")
				end
				removeCop(cop)
			end
		end
	end
end

local detectTimer = 0
local maintenanceTimer = 0

local function update(dt: number)
	local now = os.clock()
	for _, cop in table.clone(cops) do
		if not cop.car.Parent then
			continue
		end
		if updateDisabled(cop, now) then
			continue
		end
		local target = cop.target
		if cop.state == "Pursuing" and target and target.Parent then
			chase(cop, target, dt, now)
		elseif cop.state == "Investigating" and cop.watch then
			tail(cop, cop.watch, dt, now)
		else
			if cop.state == "Pursuing" then
				-- the pursuit ended without the usual release (the target left)
				returnToPatrol(cop)
			end
			cop.sees = false
			-- a car that's watching someone eases off a little
			patrol(cop, if cop.state == "Observing" then POLICE.PatrolSpeed * 0.8 else POLICE.PatrolSpeed, dt, now)
		end
	end

	detectTimer += dt
	if detectTimer >= DETECT.IntervalSeconds then
		detect(detectTimer)
		detectTimer = 0
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
		maintainFleet()
	end
end

function PoliceService.init()
	if not RoadGraph.load() then
		warn("[PoliceService] No Workspace.Map.RoadGraph; police are disabled. Build the map with MapBuilder.")
		return
	end

	-- the middle of each district, so a patrol that wandered off its beat can head back
	local sums: { [string]: Vector3 } = {}
	local counts: { [string]: number } = {}
	for _, node in nodes do
		sums[node.district] = (sums[node.district] or Vector3.zero) + node.position
		counts[node.district] = (counts[node.district] or 0) + 1
	end
	for district, sum in sums do
		beatCenters[district] = sum / counts[district]
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
		forgetPlayer(player)
		releaseOnSpawn[player] = nil
		attention[player] = nil
	end)

	-- the patrol fleet, spread over each beat
	for beat, count in POLICE.Beats do
		for _ = 1, count do
			spawnCop(Driver.spawnNode(rng, beat), beat)
		end
	end

	RunService.Heartbeat:Connect(update)
end

-- Studio test hook: as if `player` had just rammed the nearest patrol car. Returns that car.
function PoliceService.debugRam(player: Player, strength: number): Model?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return nil
	end
	local best, bestDistance = nil, math.huge
	for _, cop in cops do
		local d = (cop.chassis.Position - root.Position).Magnitude
		if cop.state == "Patrolling" and d < bestDistance then
			best, bestDistance = cop, d
		end
	end
	if best then
		best.driver.lastImpact = { player = player, strength = strength, time = os.clock() }
		return best.car
	end
	return nil
end

-- Studio test hook: a snapshot of every patrol car's state (see Tools.ServerTests).
function PoliceService.debugSnapshot(): { { state: string, beat: string?, watch: Player?, target: Player?, suspicion: number, car: Model, blockedFor: number } }
	local snapshot = {}
	for _, cop in cops do
		table.insert(snapshot, { state = cop.state, beat = cop.beat, watch = cop.watch, target = cop.target, suspicion = cop.suspicion, car = cop.car, blockedFor = cop.driver.blockedFor })
	end
	return snapshot
end

return PoliceService
