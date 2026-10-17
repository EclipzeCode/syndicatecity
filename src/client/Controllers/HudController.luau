--!strict
-- On-screen HUD: dirty cash, heat bar, wanted/bust state, objective, waypoint marker, speedometer,
-- ammo and big center banners. Reads Player attributes set by the server (DirtyCash, Heat, Wanted,
-- BustProgress, Reloading) and the equipped pistol's Ammo attribute.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.Shared.Config)
local Palette = require(ReplicatedStorage.Shared.Palette)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local player = Players.LocalPlayer

local HudController = {}

local PANEL = Color3.fromRGB(24, 26, 34)
local WANTED_RED = Color3.fromRGB(255, 84, 84)

local objectiveLabel: TextLabel
local banner: TextLabel
local bannerVersion = 0
local waypoint: BillboardGui
local waypointLabel: TextLabel

local function round(parent: GuiObject, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
end

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

local function makeBar(parent: Instance, position: UDim2, color: Color3): (Frame, Frame)
	local bar = Instance.new("Frame")
	bar.BackgroundColor3 = Color3.fromRGB(60, 62, 72)
	bar.BorderSizePixel = 0
	bar.Size = UDim2.new(1, -76, 0, 12)
	bar.Position = position
	bar.Parent = parent
	round(bar, 6)
	local fill = Instance.new("Frame")
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(0, 1)
	fill.Parent = bar
	round(fill, 6)
	return bar, fill
end

function HudController.setObjective(text: string)
	objectiveLabel.Text = text
	objectiveLabel.Visible = text ~= ""
end

local BANNER_COLORS = {
	busted = Color3.fromRGB(80, 140, 255),
	wanted = WANTED_RED,
	ko = Color3.fromRGB(255, 255, 255),
	delivered = Color3.fromRGB(120, 230, 120),
	failed = Color3.fromRGB(255, 170, 80),
}

function HudController.showBanner(kind: string, text: string)
	bannerVersion += 1
	local version = bannerVersion
	banner.Text = text
	banner.TextColor3 = BANNER_COLORS[kind] or Color3.new(1, 1, 1)
	banner.TextTransparency = 0
	banner.Size = UDim2.new(1, 0, 0, 40)
	TweenService:Create(banner, TweenInfo.new(0.25, Enum.EasingStyle.Back), { Size = UDim2.new(1, 0, 0, 56) }):Play()
	task.delay(3, function()
		if bannerVersion == version then
			TweenService:Create(banner, TweenInfo.new(0.6), { TextTransparency = 1 }):Play()
		end
	end)
end

-- Marks the pickup/dropoff part with the given name, or clears the marker.
function HudController.setWaypoint(pointName: string?, isPickup: boolean?)
	waypoint.Adornee = nil
	waypoint.Enabled = false
	if not pointName then
		return
	end
	local tag = if isPickup then Config.Tags.Pickup else Config.Tags.Dropoff
	for _, part in CollectionService:GetTagged(tag) do
		if part.Name == pointName and part:IsA("BasePart") then
			waypoint.Adornee = part
			waypoint.Enabled = true
			waypointLabel.TextColor3 = if isPickup then Palette.Pickup else Palette.Dropoff
			waypointLabel:SetAttribute("PointName", pointName)
			return
		end
	end
end

local function buildWaypoint(gui: ScreenGui)
	waypoint = Instance.new("BillboardGui")
	waypoint.Name = "Waypoint"
	waypoint.AlwaysOnTop = true
	waypoint.Size = UDim2.fromOffset(200, 54)
	waypoint.StudsOffset = Vector3.new(0, 10, 0)
	waypoint.LightInfluence = 0
	waypoint.Enabled = false
	waypoint.Parent = gui

	local arrow = Instance.new("TextLabel")
	arrow.BackgroundTransparency = 1
	arrow.Size = UDim2.new(1, 0, 0, 22)
	arrow.Position = UDim2.fromOffset(0, 32)
	arrow.Font = Enum.Font.GothamBlack
	arrow.TextSize = 22
	arrow.Text = "▼"
	arrow.TextColor3 = Color3.new(1, 1, 1)
	arrow.TextStrokeTransparency = 0.4
	arrow.Parent = waypoint

	waypointLabel = Instance.new("TextLabel")
	waypointLabel.BackgroundTransparency = 1
	waypointLabel.Size = UDim2.new(1, 0, 0, 32)
	waypointLabel.Font = Enum.Font.FredokaOne
	waypointLabel.TextSize = 18
	waypointLabel.TextStrokeTransparency = 0.3
	waypointLabel.Parent = waypoint
end

function HudController.init()
	local gui = Instance.new("ScreenGui")
	gui.Name = "Hud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.Parent = player:WaitForChild("PlayerGui")

	-- status panel
	local panel = Instance.new("Frame")
	panel.BackgroundColor3 = PANEL
	panel.BackgroundTransparency = 0.2
	panel.BorderSizePixel = 0
	panel.Size = UDim2.fromOffset(250, 104)
	panel.Position = UDim2.fromOffset(16, 16)
	panel.Parent = gui
	round(panel, 12)

	local cashLabel = makeLabel(panel, "", UDim2.new(1, -24, 0, 26), UDim2.fromOffset(14, 8))
	cashLabel.Font = Enum.Font.GothamBold
	cashLabel.TextSize = 18
	makeLabel(panel, "Heat", UDim2.new(0, 50, 0, 16), UDim2.fromOffset(14, 42)).TextSize = 14
	local _, heatFill = makeBar(panel, UDim2.fromOffset(62, 44), Color3.fromRGB(240, 110, 60))
	local bustTitle = makeLabel(panel, "Bust", UDim2.new(0, 50, 0, 16), UDim2.fromOffset(14, 62))
	bustTitle.TextSize = 14
	local bustBar, bustFill = makeBar(panel, UDim2.fromOffset(62, 64), Color3.fromRGB(80, 140, 255))

	local wantedLabel = makeLabel(panel, "★ WANTED — lose them!", UDim2.new(1, -24, 0, 20), UDim2.fromOffset(14, 80))
	wantedLabel.TextColor3 = WANTED_RED
	wantedLabel.Font = Enum.Font.GothamBold
	wantedLabel.TextSize = 14

	-- objective
	objectiveLabel = makeLabel(gui, "", UDim2.new(0, 520, 0, 36), UDim2.new(0.5, -260, 0, 16))
	objectiveLabel.TextXAlignment = Enum.TextXAlignment.Center
	objectiveLabel.BackgroundColor3 = PANEL
	objectiveLabel.BackgroundTransparency = 0.2
	objectiveLabel.Visible = false
	round(objectiveLabel, 10)

	-- center banner
	banner = makeLabel(gui, "", UDim2.new(1, 0, 0, 56), UDim2.new(0, 0, 0.3, 0))
	banner.TextXAlignment = Enum.TextXAlignment.Center
	banner.Font = Enum.Font.FredokaOne
	banner.TextScaled = true
	banner.TextStrokeTransparency = 0.5
	banner.TextTransparency = 1

	-- speedometer
	local speedo = makeLabel(gui, "", UDim2.fromOffset(220, 48), UDim2.new(0.5, -110, 1, -72))
	speedo.TextXAlignment = Enum.TextXAlignment.Center
	speedo.Font = Enum.Font.GothamBlack
	speedo.TextSize = 30
	speedo.BackgroundColor3 = PANEL
	speedo.BackgroundTransparency = 0.2
	speedo.Visible = false
	round(speedo, 12)

	-- ammo
	local ammo = makeLabel(gui, "", UDim2.fromOffset(120, 36), UDim2.new(1, -136, 1, -104))
	ammo.TextXAlignment = Enum.TextXAlignment.Center
	ammo.Font = Enum.Font.GothamBold
	ammo.BackgroundColor3 = PANEL
	ammo.BackgroundTransparency = 0.2
	ammo.Visible = false
	round(ammo, 10)

	buildWaypoint(gui)

	local function refresh()
		local cash = (player:GetAttribute("DirtyCash") :: number?) or 0
		local heat = (player:GetAttribute("Heat") :: number?) or 0
		local bust = (player:GetAttribute("BustProgress") :: number?) or 0
		local wanted = player:GetAttribute("Wanted") == true
		cashLabel.Text = `$ {cash}  dirty cash`
		heatFill.Size = UDim2.fromScale(math.clamp(heat / Config.Heat.Max, 0, 1), 1)
		wantedLabel.Visible = wanted
		bustBar.Visible = wanted
		bustTitle.Visible = wanted
		bustFill.Size = UDim2.fromScale(math.clamp(bust, 0, 1), 1)
		panel.Size = UDim2.fromOffset(250, if wanted then 104 else 64)
	end
	for _, attribute in { "DirtyCash", "Heat", "Wanted", "BustProgress" } do
		player:GetAttributeChangedSignal(attribute):Connect(refresh)
	end
	refresh()

	local limitMph = math.floor(Config.Heat.SpeedingThreshold * Config.Vehicles.MphPerStud + 0.5)
	RunService.RenderStepped:Connect(function()
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local seat = humanoid and humanoid.SeatPart
		if seat then
			local speed = seat.AssemblyLinearVelocity.Magnitude
			local mph = math.floor(speed * Config.Vehicles.MphPerStud + 0.5)
			speedo.Visible = true
			speedo.Text = if speed > Config.Heat.SpeedingThreshold then `{mph} mph  (limit {limitMph})` else `{mph} mph`
			speedo.TextColor3 = if speed > Config.Heat.SpeedingThreshold then WANTED_RED else Color3.new(1, 1, 1)
		else
			speedo.Visible = false
		end

		local tool = character and character:FindFirstChild("Pistol")
		if tool then
			ammo.Visible = true
			ammo.Text = if player:GetAttribute("Reloading") == true
				then "Reloading…"
				else `{tool:GetAttribute("Ammo") or 0} / {tool:GetAttribute("MagazineSize") or 0}`
		else
			ammo.Visible = false
		end

		local target = waypoint.Adornee :: BasePart?
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if target and root then
			local distance = math.floor((target.Position - root.Position).Magnitude)
			waypointLabel.Text = `{waypointLabel:GetAttribute("PointName")} · {distance}m`
		end
	end)

	Remotes.event("Notice").OnClientEvent:Connect(HudController.showBanner)
end

return HudController
