--!strict
-- Pistol input: click to fire at the mouse/touch point, R to reload. The server validates every shot;
-- the client only aims and shows feedback.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local player = Players.LocalPlayer
local mouse = player:GetMouse()

local fireWeapon = Remotes.event("FireWeapon")
local reloadWeapon = Remotes.event("ReloadWeapon")

local WeaponController = {}

local lastShot = 0

local function equippedTool(): Tool?
	local character = player.Character
	local tool = character and character:FindFirstChild("Pistol")
	return if tool and tool:IsA("Tool") then tool else nil
end

local function onActivated()
	local now = os.clock()
	if now - lastShot < Config.Weapons.Pistol.FireInterval then
		return
	end
	lastShot = now
	fireWeapon:FireServer(mouse.Hit.Position)
end

local function watchTool(tool: Instance)
	if tool:IsA("Tool") and tool.Name == "Pistol" then
		tool.Activated:Connect(onActivated)
	end
end

function WeaponController.init()
	local function onCharacter(character: Model)
		local backpack = player:WaitForChild("Backpack")
		for _, tool in backpack:GetChildren() do
			watchTool(tool)
		end
		backpack.ChildAdded:Connect(watchTool)
		for _, tool in character:GetChildren() do
			watchTool(tool)
		end
	end
	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if not gameProcessed and input.KeyCode == Enum.KeyCode.R and equippedTool() then
			reloadWeapon:FireServer()
		end
	end)
end

function WeaponController.getEquipped(): Tool?
	return equippedTool()
end

return WeaponController
