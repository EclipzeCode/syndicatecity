--!strict
-- Short-term police attention. Decays over time; rises with what patrols see (PoliceService adds
-- heat as their suspicion builds), gunfire (CombatService) and, slowly, reckless driving nobody saw.
-- Exposed to clients through the "Heat" and "Wanted" Player attributes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

type WantedListener = (player: Player, isWanted: boolean) -> ()

local HEAT = Config.Heat

local HeatService = {}

local heat: { [Player]: number } = {}
local speedingFor: { [Player]: number } = {}
local wanted: { [Player]: boolean } = {}
local wantedListeners: { WantedListener } = {}

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

function HeatService.getHeat(player: Player): number
	return heat[player] or 0
end

function HeatService.isWanted(player: Player): boolean
	return wanted[player] == true
end

function HeatService.add(player: Player, amount: number)
	heat[player] = math.clamp(HeatService.getHeat(player) + amount, 0, HEAT.Max)
end

-- Raises heat to at least `value`; reaching the wanted threshold makes the player wanted at once
-- (a patrol escalating to a pursuit shouldn't wait for the next tick).
function HeatService.raiseTo(player: Player, value: number)
	if HeatService.getHeat(player) < value then
		heat[player] = math.clamp(value, 0, HEAT.Max)
		player:SetAttribute("Heat", math.floor(heat[player] + 0.5))
	end
	if HeatService.getHeat(player) >= HEAT.WantedThreshold then
		setWanted(player, true)
	end
end

-- Wipes heat and the wanted state (after an arrest).
function HeatService.clear(player: Player)
	heat[player] = 0
	player:SetAttribute("Heat", 0)
	setWanted(player, false)
end

function HeatService.onWantedChanged(listener: WantedListener)
	table.insert(wantedListeners, listener)
end

-- How far over the speed limit a player is going, in studs/s (0 when not speeding).
function HeatService.getSpeedOver(player: Player): number
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return 0
	end
	-- passengers aren't the ones speeding
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.SeatPart and not humanoid.SeatPart:IsA("VehicleSeat") then
		return 0
	end
	local velocity = root.AssemblyLinearVelocity
	local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	return math.max(0, speed - HEAT.SpeedingThreshold)
end

local function step(player: Player, dt: number)
	local delta = -HEAT.DecayPerSecond * dt

	-- unseen speeding builds a little heat over time, more the further over the limit; brief
	-- bursts (overtaking, a downhill) are forgiven
	local over = HeatService.getSpeedOver(player)
	if over > 0 then
		speedingFor[player] = (speedingFor[player] or 0) + dt
		if speedingFor[player] >= HEAT.SpeedingGraceSeconds then
			delta += HEAT.SpeedingHeatPerSecond * math.clamp(over / HEAT.SpeedingFullOver, 0.25, 1.5) * dt
		end
	else
		speedingFor[player] = nil
	end

	HeatService.add(player, delta)
	local value = HeatService.getHeat(player)
	player:SetAttribute("Heat", math.floor(value + 0.5))

	if value >= HEAT.WantedThreshold then
		setWanted(player, true)
	elseif value <= HEAT.ClearThreshold then
		setWanted(player, false)
	end
end

function HeatService.init()
	Players.PlayerRemoving:Connect(function(player)
		heat[player] = nil
		speedingFor[player] = nil
		wanted[player] = nil
	end)

	task.spawn(function()
		while true do
			local dt = task.wait(HEAT.TickSeconds)
			for _, player in Players:GetPlayers() do
				step(player, dt)
			end
		end
	end)
end

return HeatService
