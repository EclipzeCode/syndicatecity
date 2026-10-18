--!strict
-- Contract board and the pickup -> dropoff job loop.
-- Pickup and dropoff points are any BaseParts tagged with Config.Tags.Pickup / Config.Tags.Dropoff;
-- each part's Name is shown to players, so give them unique, readable names.
--
-- Contracts are sorted into tiers (Config.Jobs.Tiers) by the estimated drive between their pickup
-- and dropoff along the road graph, so the board mixes short runs with long hauls. At the pickup,
-- a contact (Jobs/Handoff) checks the player's code before loading the cargo; at the dropoff the
-- player hands it over with a prompt as before.

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local RoadGraph = require(script.Parent.Parent.Navigation.RoadGraph)
local Handoff = require(script.Parent.Parent.Jobs.Handoff)
local HeatService = require(script.Parent.HeatService)
local PlayerDataService = require(script.Parent.PlayerDataService)

type Contract = Types.Contract
type ActiveJob = {
	contract: Contract,
	hasCargo: boolean,
}
type Tier = typeof(Config.Jobs.Tiers[1])
-- a pickup/dropoff pairing and its estimated drive
type Route = { pickup: BasePart, dropoff: BasePart, seconds: number }

local JobService = {}

local board: { Contract } = {}
local activeJobs: { [Player]: ActiveJob } = {}
local pickups: { BasePart } = {}
local dropoffs: { BasePart } = {}
local routesByTier: { [string]: { Route } } = {}
local rng = Random.new()

local contractUpdated = Remotes.event("ContractUpdated")

local function notify(player: Player, status: Types.JobStatus, contract: Contract?, details: Types.ContractDetails?)
	contractUpdated:FireClient(player, status, contract, details)
end

local function collectTagged(tag: string): { BasePart }
	local parts = {}
	for _, instance in CollectionService:GetTagged(tag) do
		if instance:IsA("BasePart") then
			table.insert(parts, instance)
		end
	end
	return parts
end

local function spawnTestPoints()
	local function make(name: string, tag: string, position: Vector3, color: Color3)
		local part = Instance.new("Part")
		part.Name = name
		part.Anchored = true
		part.Size = Vector3.new(8, 1, 8)
		part.Position = position
		part.Color = color
		part.Material = Enum.Material.Neon
		part.Parent = workspace
		CollectionService:AddTag(part, tag)
	end
	make("Test Pickup", Config.Tags.Pickup, Vector3.new(0, 0.5, 40), Color3.fromRGB(255, 196, 0))
	make("Test Dropoff", Config.Tags.Dropoff, Vector3.new(200, 0.5, 40), Color3.fromRGB(0, 190, 255))
end

-- Estimates every pickup -> dropoff drive and files it under its tier.
local function sortRoutes()
	local hasGraph = RoadGraph.load()
	table.clear(routesByTier)
	for _, pickup in pickups do
		for _, dropoff in dropoffs do
			local seconds = if hasGraph
				then RoadGraph.routeTime(pickup.Position, dropoff.Position, Config.Jobs.RouteSpeeds)
				else (dropoff.Position - pickup.Position).Magnitude / Config.Jobs.RouteSpeeds.street
			for _, tier in Config.Jobs.Tiers do
				if seconds <= tier.MaxSeconds then
					routesByTier[tier.Name] = routesByTier[tier.Name] or {}
					table.insert(routesByTier[tier.Name], { pickup = pickup, dropoff = dropoff, seconds = seconds })
					break
				end
			end
		end
	end
end

local function pickTier(): Tier?
	-- a tier missing from the board goes first, so there's always a short and a long option
	local onBoard: { [string]: boolean } = {}
	for _, contract in board do
		if contract.tier then
			onBoard[contract.tier] = true
		end
	end
	local available, total = {}, 0
	for _, tier in Config.Jobs.Tiers do
		if routesByTier[tier.Name] and #routesByTier[tier.Name] > 0 then
			if not onBoard[tier.Name] then
				return tier
			end
			table.insert(available, tier)
			total += tier.Weight
		end
	end
	local roll = rng:NextNumber() * total
	for _, tier in available do
		roll -= tier.Weight
		if roll <= 0 then
			return tier
		end
	end
	return available[1]
end

local function generateContract(): Contract?
	local tier = pickTier()
	if not tier then
		return nil
	end
	local routes = routesByTier[tier.Name]
	local route = routes[rng:NextInteger(1, #routes)]
	return {
		id = HttpService:GenerateGUID(false),
		syndicate = Config.Syndicates[rng:NextInteger(1, #Config.Syndicates)],
		pickupName = route.pickup.Name,
		dropoffName = route.dropoff.Name,
		payout = rng:NextInteger(tier.Payout[1], tier.Payout[2]),
		tier = tier.Name,
		cargo = tier.Cargo[rng:NextInteger(1, #tier.Cargo)],
		risk = tier.Risk,
		routeSeconds = math.floor(route.seconds + 0.5),
	}
end

local function refillBoard()
	while #board < Config.Jobs.BoardSize do
		local contract = generateContract()
		if not contract then
			return
		end
		table.insert(board, contract)
	end
end

local function isWithinReach(player: Player, part: BasePart): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root ~= nil
		and root:IsA("BasePart")
		and (root.Position - part.Position).Magnitude <= Config.Jobs.InteractDistance
end

local function setCargo(player: Player, value: boolean)
	player:SetAttribute("HasCargo", value)
end

local function failJob(player: Player, status: Types.JobStatus)
	local job = activeJobs[player]
	if not job then
		return
	end
	activeJobs[player] = nil
	Handoff.release(player)
	setCargo(player, false)
	notify(player, status, job.contract)
end

-- Arrest: the police confiscate the cargo and the contract is over.
function JobService.bust(player: Player)
	failJob(player, "busted")
end

-- How much police attention the player's cargo draws (0 when they aren't carrying any).
function JobService.getCargoRisk(player: Player): number
	local job = activeJobs[player]
	if not job or not job.hasCargo then
		return 0
	end
	return job.contract.risk or 1
end

local function onAccept(player: Player, contractId: unknown): (boolean, string?)
	if typeof(contractId) ~= "string" then
		return false, "Bad request"
	end
	if activeJobs[player] then
		return false, "You already have a job"
	end
	for index, contract in board do
		if contract.id == contractId then
			table.remove(board, index)
			activeJobs[player] = { contract = contract, hasCargo = false }
			local passcode = Handoff.prepare(player, contract)
			notify(player, "accepted", contract, { passcode = passcode })
			return true, nil
		end
	end
	return false, "That contract is no longer available"
end

-- Handoff callbacks: the contact may hand over cargo only for the player's current contract,
-- once. Both are checked again on every request.
local function canPickUp(player: Player, contractId: string): boolean
	local job = activeJobs[player]
	return job ~= nil and job.contract.id == contractId and not job.hasCargo
end

local function loadCargo(player: Player, contractId: string): boolean
	if not canPickUp(player, contractId) then
		return false
	end
	local job = activeJobs[player] :: ActiveJob
	job.hasCargo = true
	setCargo(player, true)
	Handoff.release(player, Config.Jobs.Contact.LingerSeconds)
	notify(player, "pickedUp", job.contract)
	return true
end

local function onDropoff(player: Player, part: BasePart)
	local job = activeJobs[player]
	if not job or not job.hasCargo or job.contract.dropoffName ~= part.Name or not isWithinReach(player, part) then
		return
	end
	activeJobs[player] = nil
	setCargo(player, false)
	-- TODO(v0.2): payment types (upfront, on delivery, undisclosed, items, scams) and skimming
	PlayerDataService.addDirtyCash(player, job.contract.payout)
	notify(player, "delivered", job.contract)
end

local function addPrompt(part: BasePart, actionText: string, handler: (Player, BasePart) -> ())
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = actionText
	prompt.ObjectText = part.Name
	prompt.HoldDuration = 1
	prompt.MaxActivationDistance = Config.Jobs.InteractDistance
	prompt.RequiresLineOfSight = false
	prompt.Parent = part
	prompt.Triggered:Connect(function(player)
		handler(player, part)
	end)
end

local function watchCharacter(player: Player)
	local function onCharacter(character: Model)
		local humanoid = character:WaitForChild("Humanoid") :: Humanoid
		humanoid.Died:Connect(function()
			local job = activeJobs[player]
			-- wanted players who go down are arrested instead; PoliceService handles that
			if job and job.hasCargo and not HeatService.isWanted(player) then
				-- TODO(v0.3): dropped cargo becomes evidence
				failJob(player, "failed")
			end
		end)
	end
	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end
end

function JobService.init()
	pickups = collectTagged(Config.Tags.Pickup)
	dropoffs = collectTagged(Config.Tags.Dropoff)
	if (#pickups == 0 or #dropoffs == 0) and Config.Debug.SpawnTestPoints then
		spawnTestPoints()
		pickups = collectTagged(Config.Tags.Pickup)
		dropoffs = collectTagged(Config.Tags.Dropoff)
	end
	if #pickups == 0 or #dropoffs == 0 then
		warn("[JobService] No pickup or dropoff points tagged; the contract board will stay empty")
	end
	sortRoutes()

	Handoff.init(pickups, { canPickUp = canPickUp, loadCargo = loadCargo })
	for _, part in dropoffs do
		addPrompt(part, "Deliver cargo", onDropoff)
	end

	refillBoard()

	Remotes.func("GetContracts").OnServerInvoke = function(_player: Player)
		return board
	end
	Remotes.func("AcceptContract").OnServerInvoke = onAccept

	Players.PlayerAdded:Connect(watchCharacter)
	for _, player in Players:GetPlayers() do
		watchCharacter(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		activeJobs[player] = nil
	end)

	-- rotate one contract off the board every refresh so it doesn't go stale
	task.spawn(function()
		while true do
			task.wait(Config.Jobs.RefreshSeconds)
			if #board > 0 then
				table.remove(board, 1)
			end
			refillBoard()
		end
	end)
end

-- Studio test hooks (see Tools.ServerTests).
function JobService.debugAccept(player: Player, contractId: string?): (boolean, string?)
	return onAccept(player, contractId or (board[1] and board[1].id))
end

function JobService.debugActive(player: Player): (Contract?, boolean)
	local job = activeJobs[player]
	return if job then job.contract else nil, job ~= nil and job.hasCargo
end

function JobService.debugBoard(): { Contract }
	return board
end

function JobService.debugDropoff(player: Player)
	local job = activeJobs[player]
	if not job then
		return
	end
	for _, part in dropoffs do
		if part.Name == job.contract.dropoffName then
			onDropoff(player, part)
		end
	end
end

function JobService.debugFail(player: Player)
	failJob(player, "failed")
end

return JobService
