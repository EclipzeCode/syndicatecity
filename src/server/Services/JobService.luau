--!strict
-- Contract board and the pickup -> dropoff job loop.
-- Pickup and dropoff points are any BaseParts tagged with Config.Tags.Pickup / Config.Tags.Dropoff;
-- each part's Name is shown to players, so give them unique, readable names.

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local HeatService = require(script.Parent.HeatService)
local PlayerDataService = require(script.Parent.PlayerDataService)

type Contract = Types.Contract
type ActiveJob = {
	contract: Contract,
	hasCargo: boolean,
}

local JobService = {}

local board: { Contract } = {}
local activeJobs: { [Player]: ActiveJob } = {}
local pickups: { BasePart } = {}
local dropoffs: { BasePart } = {}
local rng = Random.new()

local contractUpdated = Remotes.event("ContractUpdated")

local function notify(player: Player, status: Types.JobStatus, contract: Contract?)
	contractUpdated:FireClient(player, status, contract)
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

local function generateContract(): Contract?
	if #pickups == 0 or #dropoffs == 0 then
		return nil
	end
	local pickup = pickups[rng:NextInteger(1, #pickups)]
	local dropoff = dropoffs[rng:NextInteger(1, #dropoffs)]
	return {
		id = HttpService:GenerateGUID(false),
		syndicate = Config.Syndicates[rng:NextInteger(1, #Config.Syndicates)],
		pickupName = pickup.Name,
		dropoffName = dropoff.Name,
		payout = rng:NextInteger(Config.Jobs.MinPayout, Config.Jobs.MaxPayout),
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

local function failJob(player: Player)
	local job = activeJobs[player]
	if not job then
		return
	end
	activeJobs[player] = nil
	HeatService.setCarryingCargo(player, false)
	notify(player, "failed", job.contract)
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
			notify(player, "accepted", contract)
			return true, nil
		end
	end
	return false, "That contract is no longer available"
end

local function onPickup(player: Player, part: BasePart)
	local job = activeJobs[player]
	if not job or job.hasCargo or job.contract.pickupName ~= part.Name or not isWithinReach(player, part) then
		return
	end
	job.hasCargo = true
	HeatService.setCarryingCargo(player, true)
	notify(player, "pickedUp", job.contract)
end

local function onDropoff(player: Player, part: BasePart)
	local job = activeJobs[player]
	if not job or not job.hasCargo or job.contract.dropoffName ~= part.Name or not isWithinReach(player, part) then
		return
	end
	activeJobs[player] = nil
	HeatService.setCarryingCargo(player, false)
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
			if job and job.hasCargo then
				-- TODO(v0.3): dropped cargo becomes evidence
				failJob(player)
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

	for _, part in pickups do
		addPrompt(part, "Load cargo", onPickup)
	end
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

return JobService
