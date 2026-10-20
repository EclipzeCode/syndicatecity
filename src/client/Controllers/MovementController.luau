--!strict
-- On-foot movement: hold Left Shift (or click the left stick on a gamepad) to sprint. Players
-- who turn Shift Lock on in the Roblox settings use Shift for that, so they sprint with Left Ctrl.
-- The client owns its character, so it sets WalkSpeed directly. It only switches between the
-- walk and sprint speeds: when the server sets anything else (0 while being busted), sprinting
-- leaves it alone.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

local player = Players.LocalPlayer

local MovementController = {}

local WALK = Config.Movement.WalkSpeed
local SPRINT = Config.Movement.SprintSpeed

local sprintHeld = false

local function apply()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	if humanoid.WalkSpeed ~= WALK and humanoid.WalkSpeed ~= SPRINT then
		return
	end
	humanoid.WalkSpeed = if sprintHeld then SPRINT else WALK
end

local gameSettings = UserSettings():GetService("UserGameSettings")

-- Whether this player has Shift Lock switched on (Shift then toggles the camera lock).
local function shiftLockOn(): boolean
	return gameSettings.ControlMode == Enum.ControlMode.MouseLockSwitch
end

local function onSprint(_: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	-- Shift belongs to Shift Lock when it's on; Ctrl only sprints when it is
	local shift = input.KeyCode == Enum.KeyCode.LeftShift
	local ctrl = input.KeyCode == Enum.KeyCode.LeftControl
	if (shift and shiftLockOn()) or (ctrl and not shiftLockOn()) then
		if sprintHeld and state ~= Enum.UserInputState.Begin then
			sprintHeld = false
			apply()
		end
		return Enum.ContextActionResult.Pass
	end
	if state == Enum.UserInputState.Begin then
		sprintHeld = true
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		sprintHeld = false
	end
	apply()
	-- let Shift keep reaching other bindings
	return Enum.ContextActionResult.Pass
end

local function onCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	sprintHeld = false
	humanoid.WalkSpeed = WALK
	-- the bust freeze sets WalkSpeed to 0 and back to walk speed; re-apply a held sprint then
	humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
		if humanoid.WalkSpeed == WALK and sprintHeld then
			humanoid.WalkSpeed = SPRINT
		end
	end)
end

-- Shift Lock is allowed (StarterPlayer.EnableMouseLockOption in default.project.json); see onSprint
-- for how Shift is shared with it.
function MovementController.init()
	ContextActionService:BindAction("Sprint", onSprint, false, Enum.KeyCode.LeftShift, Enum.KeyCode.LeftControl, Enum.KeyCode.ButtonL3)
	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end
end

return MovementController
