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

local shadowCar

-- Keeps the player pinned beside the nearest patrol car (on its right) for `seconds`, with the
-- given apparent velocity, and returns the encounter state seen at the end.
local function shadowNearestCop(services, player, velocity, seconds, exclude)
	local root = rootOf(player)
	root.Anchored = true
	local vehicles = workspace:FindFirstChild("Vehicles")
	local target
	local best = math.huge
	for _, car in vehicles:GetChildren() do
		if car:GetAttribute("VehicleType") == "Police" and car.PrimaryPart and car ~= exclude and (exclude == nil or car:GetAttribute("PoliceState") == "Patrolling") and car:GetAttribute("PoliceState") ~= "Pursuing" then
			local d = (car.PrimaryPart.Position - root.Position).Magnitude
			if d < best then
				target, best = car, d
			end
		end
	end
	return shadowCar(player, target, velocity, seconds)
end

shadowCar = function(player, target, velocity, seconds)
	local root = rootOf(player)
	root.Anchored = true
	local t = os.clock()
	while os.clock() - t < seconds do
		local cf = target.PrimaryPart.CFrame
		player.Character:PivotTo(CFrame.new(cf.Position + cf.RightVector * 16 + Vector3.new(0, 2, 0)))
		root.AssemblyLinearVelocity = velocity
		task.wait(0.05)
	end
	return target
end

local function policeTests(services, player)
	local Heat = services.HeatService
	local snapshot = services.PoliceService.debugSnapshot()
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

	Heat.clear(player)
	services.JobService.debugFail(player)

	-- standing next to a patrol doing nothing wrong
	local root = rootOf(player)
	shadowNearestCop(services, player, Vector3.zero, 2)
	check("an innocent player next to a patrol isn't watched", snapshotFor(services, player) == nil)
	check("and isn't wanted", not Heat.isWanted(player))

	-- speeding right beside a patrol: observed, then tailed, then pursued
	local speed = Config.Heat.SpeedingThreshold + 30
	local car = shadowNearestCop(services, player, Vector3.new(speed, 0, 0), 1)
	local cop = snapshotFor(services, player)
	check("speeding beside a patrol gets noticed", cop ~= nil and (cop.state == "Observing" or cop.state == "Investigating"), cop and cop.state)
	check("heat rises while observed", Heat.getHeat(player) > 0, Heat.getHeat(player))
	shadowNearestCop(services, player, Vector3.new(speed, 0, 0), 9)
	cop = snapshotFor(services, player)
	check("keeping it up escalates to a pursuit", cop ~= nil and cop.state == "Pursuing", cop and cop.state)
	check("a pursuit makes the player wanted", Heat.isWanted(player))
	check("the patrol's siren is on", car:GetAttribute("Siren") == true)

	-- the pursuit ends: the patrol goes back to its beat rather than staying on the player
	root.AssemblyLinearVelocity = Vector3.zero
	Heat.clear(player)
	task.wait(0.5)
	cop = snapshotFor(services, player)
	check("pursuers stand down when the player isn't wanted", cop == nil, cop and cop.state)
	check("the patrol returns to its route", car:GetAttribute("PoliceState") == "Returning" or car:GetAttribute("PoliceState") == "Patrolling", car:GetAttribute("PoliceState"))

	-- slowing down ends an investigation (cars from the last encounter leave this player alone
	-- for a while, so use one that's just patrolling)
	Heat.clear(player)
	local second = shadowNearestCop(services, player, Vector3.new(speed, 0, 0), 3.2, car)
	local watcher = snapshotFor(services, player)
	check("a second patrol starts tailing", watcher ~= nil and watcher.state == "Investigating", watcher and watcher.state)
	check("the HUD hears about the tail", player:GetAttribute("PoliceAttention") == "tailed", player:GetAttribute("PoliceAttention"))
	check("tailing isn't a pursuit", not Heat.isWanted(player) and second:GetAttribute("Siren") ~= true)
	shadowCar(player, second, Vector3.zero, 12)
	local after = snapshotFor(services, player)
	check("driving clean ends the investigation", after == nil, after and `{after.state} {after.suspicion}`)
	check("the HUD tail indicator clears", (player:GetAttribute("PoliceAttention") or "") == "", player:GetAttribute("PoliceAttention"))
	check("the second patrol heads back to its beat", second:GetAttribute("PoliceState") == "Returning" or second:GetAttribute("PoliceState") == "Patrolling", second:GetAttribute("PoliceState"))
	check("and the player was never wanted", not Heat.isWanted(player))
	root.AssemblyLinearVelocity = Vector3.zero
	root.Anchored = false
	Heat.clear(player)
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
