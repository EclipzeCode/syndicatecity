--!strict
-- Server entry point. Services are initialized in dependency order.

local Services = script.Parent.Services

local PlayerDataService = require(Services.PlayerDataService)
local HeatService = require(Services.HeatService)
local VehicleService = require(Services.VehicleService)
local JobService = require(Services.JobService)
local CombatService = require(Services.CombatService)
local PoliceService = require(Services.PoliceService)
local TrafficService = require(Services.TrafficService)
local WorldService = require(Services.WorldService)

PlayerDataService.init()
HeatService.init()
VehicleService.init()
JobService.init()
CombatService.init()
PoliceService.init()
TrafficService.init()
WorldService.init()

-- Studio-only test hook: game.ServerStorage.Debug:Invoke("heat", 60) gives every player heat;
-- Invoke("test") runs Tools.ServerTests against the live services; Invoke("contact") accepts a
-- contract and opens its pickup contact's dialogue.
if game:GetService("RunService"):IsStudio() then
	local debug = Instance.new("BindableFunction")
	debug.Name = "Debug"
	debug.OnInvoke = function(command: string, value: number?)
		if command == "test" or command == "contact" then
			local tests = require(game:GetService("ServerStorage").Tools.ServerTests :: ModuleScript) :: any
			return tests({
				HeatService = HeatService,
				JobService = JobService,
				PlayerDataService = PlayerDataService,
				PoliceService = PoliceService,
				TrafficService = TrafficService,
			}, command)
		end
		for _, player in game:GetService("Players"):GetPlayers() do
			if command == "heat" then
				HeatService.add(player, value or 60)
			elseif command == "cash" then
				PlayerDataService.addDirtyCash(player, value or 1000)
			end
		end
		return true
	end
	debug.Parent = game:GetService("ServerStorage")
end
