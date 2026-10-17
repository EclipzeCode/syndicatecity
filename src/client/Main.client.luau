--!strict
-- Client entry point.

local Controllers = script.Parent.Controllers

local HudController = require(Controllers.HudController)
local PhoneController = require(Controllers.PhoneController)

HudController.init()
PhoneController.init()
