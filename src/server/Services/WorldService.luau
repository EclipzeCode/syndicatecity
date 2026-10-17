--!strict
-- Day/night cycle. Street lights (tagged "StreetLight" by MapBuilder) switch on after dusk.

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)

local WorldService = {}

local function isNight(clock: number): boolean
	return clock >= 18.3 or clock < 6.2
end

local function setStreetLights(on: boolean)
	for _, lamp in CollectionService:GetTagged("StreetLight") do
		local light = lamp:FindFirstChildWhichIsA("Light")
		if light then
			light.Enabled = on
		end
		if lamp:IsA("BasePart") then
			lamp.Material = if on then Enum.Material.Neon else Enum.Material.SmoothPlastic
		end
	end
end

function WorldService.init()
	Lighting.ClockTime = Config.DayNight.StartClockTime
	local hoursPerSecond = 24 / (Config.DayNight.CycleMinutes * 60)
	local lightsOn = isNight(Lighting.ClockTime)
	setStreetLights(lightsOn)

	RunService.Heartbeat:Connect(function(dt)
		Lighting.ClockTime = (Lighting.ClockTime + dt * hoursPerSecond) % 24
		local night = isNight(Lighting.ClockTime)
		if night ~= lightsOn then
			lightsOn = night
			setStreetLights(night)
		end
	end)
end

return WorldService
