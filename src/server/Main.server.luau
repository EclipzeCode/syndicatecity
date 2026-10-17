--!strict
-- Server entry point. Services are initialized in dependency order.

local Services = script.Parent.Services

local PlayerDataService = require(Services.PlayerDataService)
local HeatService = require(Services.HeatService)
local PoliceService = require(Services.PoliceService)
local JobService = require(Services.JobService)

PlayerDataService.init()
HeatService.init()
PoliceService.init()
JobService.init()
