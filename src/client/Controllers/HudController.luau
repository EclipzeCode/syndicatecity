--!strict
-- On-screen HUD: dirty cash, heat bar, wanted banner and the current objective.
-- Reads Player attributes set by the server (DirtyCash, Heat, Wanted).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

local player = Players.LocalPlayer

local HudController = {}

local objectiveLabel: TextLabel

local function makeLabel(parent: Instance, text: string, size: UDim2, position: UDim2): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamMedium
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextSize = 16
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = text
	label.Size = size
	label.Position = position
	label.Parent = parent
	return label
end

function HudController.setObjective(text: string)
	objectiveLabel.Text = text
	objectiveLabel.Visible = text ~= ""
end

function HudController.init()
	local gui = Instance.new("ScreenGui")
	gui.Name = "Hud"
	gui.ResetOnSpawn = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local panel = Instance.new("Frame")
	panel.BackgroundColor3 = Color3.new(0, 0, 0)
	panel.BackgroundTransparency = 0.4
	panel.BorderSizePixel = 0
	panel.Size = UDim2.fromOffset(240, 84)
	panel.Position = UDim2.fromOffset(16, 16)
	panel.Parent = gui

	local cashLabel = makeLabel(panel, "", UDim2.new(1, -24, 0, 24), UDim2.fromOffset(12, 8))
	makeLabel(panel, "Heat", UDim2.new(0, 40, 0, 16), UDim2.fromOffset(12, 40)).TextSize = 14

	local heatBar = Instance.new("Frame")
	heatBar.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
	heatBar.BorderSizePixel = 0
	heatBar.Size = UDim2.new(1, -72, 0, 12)
	heatBar.Position = UDim2.fromOffset(60, 42)
	heatBar.Parent = panel

	local heatFill = Instance.new("Frame")
	heatFill.BackgroundColor3 = Color3.fromRGB(230, 70, 50)
	heatFill.BorderSizePixel = 0
	heatFill.Size = UDim2.fromScale(0, 1)
	heatFill.Parent = heatBar

	local wantedLabel = makeLabel(panel, "WANTED", UDim2.new(1, -24, 0, 20), UDim2.fromOffset(12, 60))
	wantedLabel.TextColor3 = Color3.fromRGB(255, 80, 80)
	wantedLabel.Font = Enum.Font.GothamBold
	wantedLabel.TextSize = 14

	objectiveLabel = makeLabel(gui, "", UDim2.new(0, 480, 0, 32), UDim2.new(0.5, -240, 0, 16))
	objectiveLabel.TextXAlignment = Enum.TextXAlignment.Center
	objectiveLabel.BackgroundColor3 = Color3.new(0, 0, 0)
	objectiveLabel.BackgroundTransparency = 0.4
	objectiveLabel.Visible = false

	local function refresh()
		local cash = (player:GetAttribute("DirtyCash") :: number?) or 0
		local heat = (player:GetAttribute("Heat") :: number?) or 0
		cashLabel.Text = `Dirty cash: ${cash}`
		heatFill.Size = UDim2.fromScale(math.clamp(heat / Config.Heat.Max, 0, 1), 1)
		wantedLabel.Visible = player:GetAttribute("Wanted") == true
	end

	for _, attribute in { "DirtyCash", "Heat", "Wanted" } do
		player:GetAttributeChangedSignal(attribute):Connect(refresh)
	end
	refresh()
end

return HudController
