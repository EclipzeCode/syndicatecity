--!strict
-- Client entry point.

local Controllers = script.Parent.Controllers

local HudController = require(Controllers.HudController)
local PhoneController = require(Controllers.PhoneController)
local VehicleController = require(Controllers.VehicleController)
local WeaponController = require(Controllers.WeaponController)
local EffectsController = require(Controllers.EffectsController)

HudController.init()
PhoneController.init()
VehicleController.init()
WeaponController.init()
EffectsController.init()
