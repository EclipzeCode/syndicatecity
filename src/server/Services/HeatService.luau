--!strict
-- Short-term police attention. Rises from speeding and carrying cargo near patrols, decays over time.
-- Exposed to clients through the "Heat" and "Wanted" Player attributes.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

type WantedListener = (player: Player, isWanted: boolean) -> ()

local HeatService = {}

local heat: { [Player]: number } = {}
local carryingCargo: { [Player]: boolean } = {}
local wanted: { [Player]: boolean } = {}
local wantedListeners: { WantedListener } = {}

function HeatService.getHeat(player: Player): number
	return heat[player] or 0
end

function HeatService.isWanted(player: Player): boolean
	return wanted[player] == true
end

function HeatService.add(player: Player, amount: number)
	heat[player] = math.clamp(HeatService.getHeat(player) + amount, 0, Config.Heat.Max)
end

function HeatService.setCarryingCargo(player: Player, value: boolean)
	carryingCargo[player] = if value then true else nil
end

function HeatService.onWantedChanged(listener: WantedListener)
	table.insert(wantedListeners, listener)
end

local function setWanted(player: Player, value: boolean)
	if HeatService.isWanted(player) == value then
		return
	end
	wanted[player] = if value then true else nil
	player:SetAttribute("Wanted", value)
	for _, listener in wantedListeners do
		task.spawn(listener, player, value)
	end
end

local function isNearPatrol(position: Vector3): boolean
	for _, instance in CollectionService:GetTagged(Config.Tags.Patrol) do
		if instance:IsA("BasePart") and (instance.Position - position).Magnitude <= Config.Heat.PatrolRadius then
			return true
		end
	end
	return false
end

local function step(player: Player, dt: number)
	local delta = -Config.Heat.DecayPerSecond * dt

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		if root.AssemblyLinearVelocity.Magnitude > Config.Heat.SpeedingThreshold then
			delta += Config.Heat.SpeedingHeatPerSecond * dt
		end
		if carryingCargo[player] and isNearPatrol(root.Position) then
			delta += Config.Heat.CargoNearPatrolHeatPerSecond * dt
		end
	end

	HeatService.add(player, delta)
	local value = HeatService.getHeat(player)
	player:SetAttribute("Heat", math.floor(value + 0.5))

	if value >= Config.Heat.WantedThreshold then
		setWanted(player, true)
	elseif value <= Config.Heat.ClearThreshold then
		setWanted(player, false)
	end
end

function HeatService.init()
	Players.PlayerRemoving:Connect(function(player)
		heat[player] = nil
		carryingCargo[player] = nil
		wanted[player] = nil
	end)

	task.spawn(function()
		while true do
			local dt = task.wait(Config.Heat.TickSeconds)
			for _, player in Players:GetPlayers() do
				step(player, dt)
			end
		end
	end)
end

return HeatService
