--!strict
-- Client entry point.

local Controllers = script.Parent.Controllers

local HudController = require(Controllers.HudController)
local PhoneController = require(Controllers.PhoneController)
local VehicleController = require(Controllers.VehicleController)
local WeaponController = require(Controllers.WeaponController)
local EffectsController = require(Controllers.EffectsController)
local MovementController = require(Controllers.MovementController)
local CarHudController = require(Controllers.CarHudController)
local ContactController = require(Controllers.ContactController)

HudController.init()
PhoneController.init()
VehicleController.init()
CarHudController.init()
WeaponController.init()
EffectsController.init()
MovementController.init()
ContactController.init()
