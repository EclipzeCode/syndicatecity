--!nocheck
-- Server tests for v0.1: the police suspicion rules (pure), the pickup contact handoff and the
-- police encounter state machine (live, with the first player in the server).
--
-- Run during a Studio playtest (one player is enough), from the Server command bar:
--   print(game.ServerStorage.Debug:Invoke("test"))
-- Main passes the live services in, since requiring them from the command bar would load fresh
-- copies. The live tests move the player around and clean up after themselves.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage.Shared.Config)
local Suspicion = require(ServerScriptService.Server.Police.Suspicion)
local Handoff = require(ServerScriptService.Server.Jobs.Handoff)

local results = {}
local failures = 0

local function check(name: string, ok: boolean, detail: any?)
	if not ok then
		failures += 1
	end
	table.insert(results, `{if ok then "PASS" else "FAIL"}  {name}{if not ok and detail ~= nil then `  ({tostring(detail)})` else ""}`)
end

local CFG = {
	SpeedingPerSecond = 14,
	SpeedingFullOver = 25,
	CargoPerSecond = 6,
	CargoSuspicionCap = 60,
	HeatMultiplier = 1,
	DecayPerSecond = 6,
	InvestigateThreshold = 35,
	PursuitThreshold = 100,
	ClearThreshold = 5,
	LoseSightSeconds = 6,
	InvestigateMaxSeconds = 35,
}

local function obs(speedOver, cargoRisk, heat)
	return { speedOver = speedOver or 0, cargoRisk = cargoRisk or 0, heat = heat or 0 }
end

local function runFor(value, o, seconds)
	for _ = 1, math.floor(seconds / 0.1) do
		value = Suspicion.step(value, o, 0.1, CFG)
	end
	return value
end

local function suspicionTests()
	check("clean driving near police isn't suspicious", not Suspicion.isSuspicious(obs(), CFG))
	local slow = Suspicion.rates(obs(2), CFG)
	local fast = Suspicion.rates(obs(30), CFG)
	check("far over the limit is worse than slightly over", fast > slow, `{slow} vs {fast}`)
	check("speeding rate is capped at 150%", Suspicion.rates(obs(500), CFG) == 14 * 1.5)
	check("suspicion builds while speeding is visible", runFor(0, obs(25), 2) > 20)
	check("suspicion never passes the pursuit threshold", runFor(0, obs(100), 30) == 100)
	check("cargo alone stops at the cargo cap", runFor(0, obs(0, 1), 60) == 60)
	check("higher-risk cargo is noticed faster", runFor(0, obs(0, 1.5), 3) > runFor(0, obs(0, 1), 3))
	check("heat makes patrols quicker", runFor(0, obs(10, 0, 1), 2) > runFor(0, obs(10, 0, 0), 2))
	check("suspicion decays when nothing is visible", runFor(50, obs(), 3) < 50 and runFor(50, obs(), 20) == 0)
	check("cargo keeps suspicion at the cap, not above", runFor(90, obs(0, 1), 10) == 60)

	local S = Suspicion.nextState
	check("observing -> investigating at threshold", S("Observing", 35, 0, 1, CFG) == "Investigating")
	check("observing stays below threshold", S("Observing", 20, 0, 1, CFG) == "Observing")
	check("observing -> patrolling when suspicion is gone", S("Observing", 0, 0, 1, CFG) == "Patrolling")
	check("observing -> patrolling after losing sight", S("Observing", 20, 6, 1, CFG) == "Patrolling")
	check("investigating -> pursuing at threshold", S("Investigating", 100, 0, 1, CFG) == "Pursuing")
	check("investigating -> returning when clear", S("Investigating", 5, 0, 1, CFG) == "Returning")
	check("investigating -> returning after losing sight", S("Investigating", 50, 6, 1, CFG) == "Returning")
	check("investigation can't last forever", S("Investigating", 60, 0, 35, CFG) == "Returning")
	check("patrolling isn't changed by nextState", S("Patrolling", 100, 0, 0, CFG) == "Patrolling")
	check("a jolt adds suspicion", Suspicion.bump(10, 30, CFG) == 40)
	check("a jolt stops at the pursuit threshold", Suspicion.bump(90, 30, CFG) == 100)
end

---------------------------------------------------------------------------------------------------

local function rootOf(player)
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

local function teleport(player, position)
	local root = rootOf(player)
	if root then
		root.AssemblyLinearVelocity = Vector3.zero
		player.Character:PivotTo(CFrame.new(position + Vector3.new(0, 3, 0)))
	end
end

local function contactFor(pickupName)
	local folder = workspace:FindFirstChild("Contacts")
	return folder and folder:FindFirstChild(`Contact ({pickupName})`)
end

local function handoffTests(services, player)
	local Jobs = services.JobService
	-- start from no job
	Jobs.debugFail(player)
	task.wait(0.1)

	local pickupBefore = Handoff.debugPending(player)
	check("no contract, no pending pickup", pickupBefore == nil)

	local board = Jobs.debugBoard()
	check("board offers contracts", #board > 0, #board)
	local tiers = {}
	for _, c in board do
		tiers[c.tier or "?"] = true
		check(`contract {c.pickupName} -> {c.dropoffName} is tiered`, c.tier ~= nil and c.routeSeconds ~= nil and c.risk ~= nil)
	end
	check("board mixes tiers", tiers.Routine and tiers.Standard and tiers["High-value"], next(tiers))
	check("board contracts carry no passcode", board[1] and board[1].passcode == nil)

	local contract = board[1]
	local ok = Jobs.debugAccept(player, contract.id)
	check("accept contract", ok)
	local ok2 = Jobs.debugAccept(player, board[1] and board[1].id)
	check("can't accept a second contract", not ok2)

	local pickupName, options, correct = Handoff.debugPending(player)
	check("pending pickup matches contract", pickupName == contract.pickupName, pickupName)
	check("three answer options", options and #options == 3, options and #options)
	local unique = {}
	for _, o in options or {} do
		unique[o] = true
	end
	local count = 0
	for _ in unique do
		count += 1
	end
	check("options are distinct", count == 3)
	check("correct index is valid", correct and correct >= 1 and correct <= 3)

	local contact = contactFor(contract.pickupName)
	check("contact NPC spawned at the pickup", contact ~= nil)
	check("contact has a talk prompt", contact and contact:FindFirstChild("ContactPrompt", true) ~= nil)
	check("answer keeps nothing replicated", contact and contact:FindFirstChild("ContactPrompt", true):GetAttribute("Correct") == nil)

	-- too far away: talking does nothing
	teleport(player, contact:GetPivot().Position + Vector3.new(60, 0, 0))
	task.wait(0.2)
	Handoff.debugTalk(player)
	check("can't talk from far away", not Handoff.debugSessionOpen(player))
	check("can't answer without talking", Handoff.debugAnswer(player, correct) == nil)

	-- in range
	teleport(player, contact:GetPivot().Position + Vector3.new(4, 0, 4))
	task.wait(0.2)
	Handoff.debugTalk(player)
	check("talking opens the dialogue", Handoff.debugSessionOpen(player))

	for _, bad in { "1", 0, 4, 1.5, -1, nil, {} } do
		task.wait(Config.Jobs.Contact.AnswerCooldown + 0.05)
		check(`rejects bad answer {tostring(bad)}`, Handoff.debugAnswer(player, bad) == nil)
	end
	local _, hasCargo = Jobs.debugActive(player)
	check("bad answers give no cargo", not hasCargo)

	task.wait(Config.Jobs.Contact.AnswerCooldown + 0.05)
	local wrong = correct % 3 + 1
	local reply = Handoff.debugAnswer(player, wrong)
	check("wrong answer is refused", reply and reply.ok == false and reply.done == false)
	_, hasCargo = Jobs.debugActive(player)
	check("wrong answer gives no cargo", not hasCargo)
	check("dialogue stays open for a retry", Handoff.debugSessionOpen(player))

	check("answers too fast are ignored", Handoff.debugAnswer(player, correct) == nil)
	task.wait(Config.Jobs.Contact.AnswerCooldown + 0.05)
	reply = Handoff.debugAnswer(player, correct)
	check("right answer hands over the cargo", reply and reply.ok == true and reply.done == true)
	_, hasCargo = Jobs.debugActive(player)
	check("player has the cargo", hasCargo)
	check("player HasCargo attribute set", player:GetAttribute("HasCargo") == true)
	check("dialogue closed after the handoff", not Handoff.debugSessionOpen(player))
	check("cargo risk visible to police", services.JobService.getCargoRisk(player) == contract.risk)

	task.wait(Config.Jobs.Contact.AnswerCooldown + 0.05)
	check("replayed answer does nothing", Handoff.debugAnswer(player, correct) == nil)
	Handoff.debugTalk(player)
	check("can't reopen after pickup", not Handoff.debugSessionOpen(player))

	-- deliver: pays the contract once
	local cash = services.PlayerDataService.getDirtyCash(player)
	for _, part in game:GetService("CollectionService"):GetTagged(Config.Tags.Dropoff) do
		if part.Name == contract.dropoffName then
			teleport(player, part.Position)
		end
	end
	task.wait(0.2)
	Jobs.debugDropoff(player)
	Jobs.debugDropoff(player)
	check("delivery pays the payout once", services.PlayerDataService.getDirtyCash(player) == cash + contract.payout, services.PlayerDataService.getDirtyCash(player) - cash)
	check("job cleared after delivery", Jobs.debugActive(player) == nil)
	check("cargo cleared after delivery", player:GetAttribute("HasCargo") == false)

	-- a contract that fails mid-dialogue closes the dialogue and the contact goes away
	board = Jobs.debugBoard()
	Jobs.debugAccept(player, board[1].id)
	local name2 = Handoff.debugPending(player)
	local contact2 = contactFor(name2)
	teleport(player, contact2:GetPivot().Position + Vector3.new(4, 0, 4))
	task.wait(0.2)
	Handoff.debugTalk(player)
	check("second contract: dialogue opens", Handoff.debugSessionOpen(player))
	local _, options2, correct2 = Handoff.debugPending(player)
	Jobs.debugFail(player)
	task.wait(0.1)
	check("failed contract closes the dialogue", not Handoff.debugSessionOpen(player))
	task.wait(Config.Jobs.Contact.AnswerCooldown + 0.05)
	check("failed contract can't be picked up", Handoff.debugAnswer(player, correct2) == nil)
	check("failed contract: no cargo", player:GetAttribute("HasCargo") == false)
	task.wait(0.2)
	check("contact leaves once nobody needs it", contactFor(name2) == nil)
	check("options were sent", options2 ~= nil)

	-- walking away closes an open dialogue
	board = Jobs.debugBoard()
	Jobs.debugAccept(player, board[1].id)
	local name3 = Handoff.debugPending(player)
	local contact3 = contactFor(name3)
	teleport(player, contact3:GetPivot().Position + Vector3.new(4, 0, 4))
	task.wait(0.2)
	Handoff.debugTalk(player)
	teleport(player, contact3:GetPivot().Position + Vector3.new(80, 0, 0))
	task.wait(1.2)
	check("walking away closes the dialogue", not Handoff.debugSessionOpen(player))
	Jobs.debugFail(player)
end

---------------------------------------------------------------------------------------------------

local function snapshotFor(services, player)
	for _, cop in services.PoliceService.debugSnapshot() do
		if cop.watch == player or cop.target == player then
			return cop
		end
	end
	return nil
end

-- The patrol observing or investigating the player (not one pursuing them), if any.
local function watcherOf(services, player)
	for _, cop in services.PoliceService.debugSnapshot() do
		if cop.watch == player then
			return cop
		end
	end
	return nil
end

local function entryFor(services, car)
	for _, cop in services.PoliceService.debugSnapshot() do
		if cop.car == car then
			return cop
		end
	end
	return nil
end

-- The nearest patrol car that's free to notice the player: on (or heading back to) its beat,
-- busy with nobody, and not giving this player a breather after an earlier encounter.
local function nearestFreeCop(services, player)
	local root = rootOf(player)
	local now = os.clock()
	local target
	local best = math.huge
	for _, cop in services.PoliceService.debugSnapshot() do
		local free = (cop.state == "Patrolling" or cop.state == "Returning") and cop.watch == nil and cop.target == nil
			and not cop.disabled and (cop.ignoring[player] or 0) <= now
		if free and cop.car.PrimaryPart then
			local d = (cop.car.PrimaryPart.Position - root.Position).Magnitude
			if d < best then
				target, best = cop.car, d
			end
		end
	end
	return target
end

-- Keeps the player pinned beside `car` (on its right) with the given apparent velocity until
-- `done()` is true or `timeout` seconds pass (with no `done`, for the whole time). If a patrol
-- starts watching the player the player sticks with that one, so the encounter being tested keeps
-- its line of sight even when a different car noticed first. Returns the car it ended beside.
-- Polling the police state instead of sleeping a fixed time keeps the tests from racing the
-- detection loop.
local function shadow(services, player, car, velocity, timeout, done)
	local root = rootOf(player)
	root.Anchored = true
	local deadline = os.clock() + timeout
	while true do
		local watcher = watcherOf(services, player)
		if watcher and watcher.car.PrimaryPart then
			car = watcher.car
		end
		if (done and done()) or os.clock() >= deadline then
			return car
		end
		local cf = car.PrimaryPart.CFrame
		player.Character:PivotTo(CFrame.new(cf.Position + cf.RightVector * 16 + Vector3.new(0, 2, 0)))
		root.AssemblyLinearVelocity = velocity
		task.wait(0.05)
	end
end

local function waitFor(timeout, done)
	local deadline = os.clock() + timeout
	while not done() and os.clock() < deadline do
		task.wait(0.05)
	end
end

local function policeTests(services, player)
	local Heat = services.HeatService
	local Police = services.PoliceService
	local snapshot = Police.debugSnapshot()
	local beats = {}
	for _, cop in snapshot do
		if cop.beat then
			beats[cop.beat] = (beats[cop.beat] or 0) + 1
		end
	end
	local expected = 0
	for beat, count in Config.Police.Beats do
		expected += count
		check(`{count} patrol(s) on the {beat} beat`, beats[beat] == count, beats[beat])
	end
	check("patrols exist with no heat", #snapshot >= expected, #snapshot)

	-- start from a clean slate: earlier runs leave cooldowns and encounters behind
	Heat.clear(player)
	services.JobService.debugFail(player)
	Police.debugReset(player)

	-- standing next to a patrol doing nothing wrong
	local root = rootOf(player)
	shadow(services, player, nearestFreeCop(services, player), Vector3.zero, 2)
	check("an innocent player next to a patrol isn't watched", snapshotFor(services, player) == nil)
	check("and isn't wanted", not Heat.isWanted(player))

	-- speeding right beside a patrol: observed, then tailed, then pursued
	local fast = Vector3.new(Config.Heat.SpeedingThreshold + 30, 0, 0)
	local car = shadow(services, player, nearestFreeCop(services, player), fast, 3, function()
		return watcherOf(services, player) ~= nil
	end)
	local cop = watcherOf(services, player)
	check("speeding beside a patrol gets noticed", cop ~= nil and (cop.state == "Observing" or cop.state == "Investigating"), cop and cop.state)
	car = shadow(services, player, car, fast, 3, function()
		return Heat.getHeat(player) > 0
	end)
	check("heat rises while observed", Heat.getHeat(player) > 0, Heat.getHeat(player))
	-- suspicion builds at ~17/s, so the pursuit is due in about 6 s
	shadow(services, player, car, fast, 15, function()
		local entry = entryFor(services, car)
		return entry ~= nil and entry.state == "Pursuing"
	end)
	cop = entryFor(services, car)
	check("keeping it up escalates to a pursuit", cop ~= nil and cop.state == "Pursuing" and cop.target == player, cop and cop.state)
	check("a pursuit makes the player wanted", Heat.isWanted(player))
	check("the patrol's siren is on", car:GetAttribute("Siren") == true)

	-- the pursuit ends: the patrol goes back to its beat rather than staying on the player
	root.AssemblyLinearVelocity = Vector3.zero
	Heat.clear(player)
	waitFor(2, function()
		return snapshotFor(services, player) == nil
	end)
	cop = snapshotFor(services, player)
	check("pursuers stand down when the player isn't wanted", cop == nil, cop and cop.state)
	check("the patrol returns to its route", car:GetAttribute("PoliceState") == "Returning" or car:GetAttribute("PoliceState") == "Patrolling", car:GetAttribute("PoliceState"))
	local pursuer = entryFor(services, car)
	check("and leaves the player alone for a while", pursuer ~= nil and (pursuer.ignoring[player] or 0) > os.clock(), pursuer and pursuer.ignoring[player])

	-- slowing down ends an investigation (cars from the last encounter leave this player alone
	-- for a while, so use one that's free)
	Heat.clear(player)
	local second = shadow(services, player, nearestFreeCop(services, player), fast, 8, function()
		local watcher = watcherOf(services, player)
		return watcher ~= nil and watcher.state == "Investigating"
	end)
	local watcher = watcherOf(services, player)
	check("a second patrol starts tailing", watcher ~= nil and watcher.state == "Investigating" and watcher.car ~= car, watcher and watcher.state)
	check("the HUD hears about the tail", player:GetAttribute("PoliceAttention") == "tailed", player:GetAttribute("PoliceAttention"))
	check("tailing isn't a pursuit", not Heat.isWanted(player) and second:GetAttribute("Siren") ~= true)
	-- suspicion decays at 6/s from the investigate threshold, so the tail ends in about 5 s
	shadow(services, player, second, Vector3.zero, 15, function()
		return snapshotFor(services, player) == nil and (player:GetAttribute("PoliceAttention") or "") == ""
	end)
	local after = snapshotFor(services, player)
	check("driving clean ends the investigation", after == nil, after and `{after.state} {after.suspicion}`)
	check("the HUD tail indicator clears", (player:GetAttribute("PoliceAttention") or "") == "", player:GetAttribute("PoliceAttention"))
	check("the second patrol heads back to its beat", second:GetAttribute("PoliceState") == "Returning" or second:GetAttribute("PoliceState") == "Patrolling", second:GetAttribute("PoliceState"))
	check("and the player was never wanted", not Heat.isWanted(player))
	root.AssemblyLinearVelocity = Vector3.zero
	root.Anchored = false
	Heat.clear(player)
	Police.debugReset(player)
end

-- Debug:Invoke("contact"): accept a contract (a downtown one if offered), stand the player in
-- front of its contact and open the dialogue, to try the UI by hand.
local function meetContact(services, player)
	local Jobs = services.JobService
	Jobs.debugFail(player)
	local board = Jobs.debugBoard()
	local pick = board[1]
	for _, c in board do
		if c.pickupName == "Parking Lot B" then
			pick = c
		end
	end
	if not pick then
		return "the board is empty; wait for it to refill"
	end
	Jobs.debugAccept(player, pick.id)
	local name = Handoff.debugPending(player)
	local contact = contactFor(name)
	local cf = contact:GetPivot()
	local stand = cf.Position + cf.LookVector * 7 + Vector3.new(0, 3, 0)
	player.Character:PivotTo(CFrame.lookAt(stand, Vector3.new(cf.Position.X, stand.Y, cf.Position.Z)))
	task.wait(0.5)
	Handoff.debugTalk(player)
	return `talking to the contact at {name}`
end

local function drivingTests(services, player)
	local Heat = services.HeatService
	Heat.clear(player)
	services.JobService.debugFail(player)
	services.PoliceService.debugReset(player)
	local root = rootOf(player)
	local now = os.clock()

	-- traffic is out and lights follow the time of day
	task.wait(2.5)
	local traffic = services.TrafficService.debugSnapshot()
	check("civilian traffic is on the roads", #traffic >= Config.Traffic.Count, #traffic)
	local night = game.Lighting.ClockTime >= 18.3 or game.Lighting.ClockTime < 6.2
	local wrongLights = 0
	for _, cop in services.PoliceService.debugSnapshot() do
		if cop.car:GetAttribute("Headlights") ~= night then
			wrongLights += 1
		end
	end
	check(`police headlights are {if night then "on at night" else "off by day"}`, wrongLights == 0, wrongLights)

	-- standing in a patrol car's lane: it stops short instead of running you over
	local target
	for _, cop in services.PoliceService.debugSnapshot() do
		if cop.state == "Patrolling" and cop.car.PrimaryPart.AssemblyLinearVelocity.Magnitude > 20 then
			target = cop
			break
		end
	end
	if not target then
		check("a moving patrol car to stand in front of", false, "none moving")
		return
	end
	local car = target.car
	root.Anchored = true
	local cf = car.PrimaryPart.CFrame
	local stand = cf.Position + cf.LookVector * 45
	player.Character:PivotTo(CFrame.new(stand.X, stand.Y + 1, stand.Z))
	task.wait(4)
	local speed = car.PrimaryPart.AssemblyLinearVelocity.Magnitude
	local gap = (car.PrimaryPart.Position - root.Position).Magnitude
	check("a patrol car brakes for someone in its lane", speed < 4 and gap > 6, string.format("speed %.1f gap %.1f", speed, gap))

	-- and if you don't move, it takes an interest in you
	task.wait(5)
	local cop = snapshotFor(services, player)
	check("blocking a patrol car makes it suspicious", cop ~= nil and cop.car == car, cop and cop.state)
	root.Anchored = false
	Heat.clear(player)
	task.wait(0.5)

	-- ramming a patrol car: a hard knock gets you tailed straight away
	local rammed = services.PoliceService.debugRam(player, 45)
	task.wait(0.8)
	cop = nil
	for _, entry in services.PoliceService.debugSnapshot() do
		if entry.car == rammed then
			cop = entry
		end
	end
	check("ramming a patrol car gets you noticed", cop ~= nil and cop.watch == player, cop and cop.state)
	check("a hard ram goes straight to a tail", cop ~= nil and (cop.state == "Investigating" or cop.state == "Pursuing"), cop and `{cop.state} {cop.suspicion}`)
	check("ramming adds heat", Heat.getHeat(player) > 0, Heat.getHeat(player))
	Heat.clear(player)
	-- the rammed car would otherwise still be tailing the player when the next run starts
	services.PoliceService.debugReset(player)
end

return function(services, mode: string?)
	if mode == "contact" then
		return meetContact(services, Players:GetPlayers()[1])
	end
	table.clear(results)
	failures = 0
	suspicionTests()
	local player = Players:GetPlayers()[1]
	if player and player.Character and rootOf(player) then
		local home = player.Character:GetPivot()
		local ok, err = pcall(handoffTests, services, player)
		check("handoff tests ran", ok, err)
		ok, err = pcall(policeTests, services, player)
		check("police tests ran", ok, err)
		ok, err = pcall(drivingTests, services, player)
		check("driving tests ran", ok, err)
		local root = rootOf(player)
		if root then
			root.Anchored = false
		end
		services.HeatService.clear(player)
		player.Character:PivotTo(home)
	else
		table.insert(results, "SKIP  live tests (start a playtest first)")
	end
	table.insert(results, `{failures} failure(s)`)
	return table.concat(results, "\n")
end
