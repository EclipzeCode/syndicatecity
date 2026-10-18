--!strict
-- Mini car HUD, bottom left, shown while the local player sits in a car: an analog speedometer
-- (0-80 mph, red past the speed limit; the exact number is on the phone's GPS), gear and
-- indicator lights, and the in-car controls underneath.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Theme = require(script.Parent.Parent.UI.Theme)
local VehicleController = require(script.Parent.VehicleController)

local player = Players.LocalPlayer
local C = Theme.Colors
local F = Theme.Fonts

local CarHudController = {}

local DIAL_MAX_MPH = 80
local DIAL_SWEEP = 240 -- degrees, centred on straight up
local DIAL_SIZE = 156
local LIMIT_MPH = math.floor(Config.Heat.SpeedingThreshold * Config.Vehicles.MphPerStud + 0.5)

local function dialAngle(mph: number): number
	return -DIAL_SWEEP / 2 + math.clamp(mph / DIAL_MAX_MPH, 0, 1) * DIAL_SWEEP
end

-- A frame the size of the dial, turned about the dial's centre; children drawn at its top edge
-- end up on the rim at that angle.
local function spoke(dial: Frame, angle: number): Frame
	return Theme.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Rotation = angle,
		Parent = dial,
	})
end

local function buildDial(parent: Instance): Frame
	local dial = Theme.new("Frame", {
		Name = "Speedometer",
		BackgroundColor3 = Color3.fromRGB(10, 11, 15),
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(DIAL_SIZE, DIAL_SIZE),
		Parent = parent,
	}, { Theme.corner(DIAL_SIZE // 2), Theme.stroke(0.8) })

	for mph = 0, DIAL_MAX_MPH, 5 do
		local major = mph % 20 == 0
		local over = mph > LIMIT_MPH
		Theme.new("Frame", {
			BackgroundColor3 = if over then C.Wanted else (if major then C.Text else C.TextDim),
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(if major then 3 else 2, if major then 12 else 7),
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 6),
			Parent = spoke(dial, dialAngle(mph)),
		})
		if major then
			local a = math.rad(dialAngle(mph))
			local r = DIAL_SIZE / 2 - 32
			Theme.label({
				Text = tostring(mph),
				Font = F.Bold,
				TextSize = 12,
				TextColor3 = if over then C.Wanted else C.TextDim,
				TextXAlignment = Enum.TextXAlignment.Center,
				Size = UDim2.fromOffset(28, 14),
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromOffset(DIAL_SIZE / 2 + r * math.sin(a), DIAL_SIZE / 2 - r * math.cos(a)),
				Parent = dial,
			})
		end
	end

	local needle = spoke(dial, dialAngle(0))
	needle.Name = "Needle"
	Theme.new("Frame", {
		BackgroundColor3 = C.HeatLow,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(3, DIAL_SIZE / 2 - 14),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 0.5),
		Parent = needle,
	}, { Theme.corner(2) })
	Theme.new("Frame", {
		BackgroundColor3 = C.PanelRaised,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(16, 16),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Parent = dial,
	}, { Theme.corner(8), Theme.stroke(0.6) })
	Theme.caption("mph", {
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.fromOffset(60, 12),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.66, 0),
		Parent = dial,
	})
	return needle
end

-- An indicator light: a dim chip that lights up in its color.
local function indicator(parent: Instance, text: string, order: number): TextLabel
	return Theme.label({
		Text = text,
		Font = F.Heavy,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Center,
		BackgroundColor3 = C.PanelRaised,
		BackgroundTransparency = 0,
		TextColor3 = C.TextDim,
		Size = UDim2.new(1, 0, 0, 22),
		LayoutOrder = order,
		Parent = parent,
	})
end

local function setIndicator(label: TextLabel, on: boolean, color: Color3)
	label.TextColor3 = if on then Color3.fromRGB(16, 16, 20) else C.TextDim
	label.BackgroundColor3 = if on then color else C.PanelRaised
end

-- One "[key] action" pair in the controls strip.
local function control(parent: Instance, key: string, action: string, order: number)
	local row = Theme.new("Frame", {
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 22),
		LayoutOrder = order,
		Parent = parent,
	})
	Theme.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 5),
		Parent = row,
	})
	local chip = Theme.label({
		Text = key,
		Font = F.Mono,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Center,
		BackgroundColor3 = C.PanelRaised,
		BackgroundTransparency = 0,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 20),
		LayoutOrder = 1,
		Parent = row,
	})
	Theme.new("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6), Parent = chip })
	Theme.corner(4).Parent = chip
	Theme.stroke(0.85).Parent = chip
	Theme.label({
		Text = action,
		TextSize = 12,
		TextColor3 = C.TextDim,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 20),
		LayoutOrder = 2,
		Parent = row,
	})
end

function CarHudController.init()
	local gui = Theme.new("ScreenGui", {
		Name = "CarHud",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = player:WaitForChild("PlayerGui"),
	})

	local panel = Theme.panel({
		Name = "Car",
		Size = UDim2.fromOffset(290, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 16, 1, -16),
		Visible = false,
		Parent = gui,
	})
	Theme.padding(12).Parent = panel
	Theme.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 10), Parent = panel })

	-- top: dial and indicator column
	local top = Theme.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, DIAL_SIZE), LayoutOrder = 1, Parent = panel })
	local needle = buildDial(top)
	local column = Theme.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -(DIAL_SIZE + 12), 1, 0),
		Position = UDim2.fromOffset(DIAL_SIZE + 12, 0),
		Parent = top,
	})
	Theme.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6), Parent = column })
	Theme.caption("Gear", { Size = UDim2.new(1, 0, 0, 12), LayoutOrder = 1, Parent = column })
	local gear = Theme.label({ Text = "P", Font = F.Heavy, TextSize = 30, Size = UDim2.new(1, 0, 0, 32), LayoutOrder = 2, Parent = column })
	local lights = indicator(column, "LIGHTS", 3)
	local brake = indicator(column, "BRAKE", 4)
	local speeding = indicator(column, `LIMIT {LIMIT_MPH}`, 5)
	for _, chip in { lights, brake, speeding } do
		Theme.corner(5).Parent = chip
	end

	-- bottom: the controls
	Theme.new("Frame", { BackgroundColor3 = C.Outline, BackgroundTransparency = 0.9, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 1), LayoutOrder = 2, Parent = panel })
	local controls = Theme.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 3,
		Parent = panel,
	})
	Theme.new("UIGridLayout", {
		CellSize = UDim2.new(0.5, -4, 0, 22),
		CellPadding = UDim2.fromOffset(8, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = controls,
	})
	local driverControls = { { "W S", "Gas / brake" }, { "A D", "Steer" }, { "Space", "Handbrake" }, { "L", "Lights" }, { "F", "Get out" }, { "P", "Phone" } }
	local passengerControls = { { "F", "Get out" }, { "P", "Phone" } }
	local shownFor: boolean? = nil
	local function showControls(isDriver: boolean)
		if shownFor == isDriver then
			return
		end
		shownFor = isDriver
		for _, child in controls:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		for i, pair in if isDriver then driverControls else passengerControls do
			control(controls, pair[1], pair[2], i)
		end
	end

	local shownAngle = dialAngle(0)
	RunService.RenderStepped:Connect(function(dt)
		local state = VehicleController.getState()
		local chassis = state and state.car.PrimaryPart
		if not state or not chassis then
			panel.Visible = false
			return
		end
		panel.Visible = true
		showControls(state.isDriver)

		-- horizontal only: a parked car's suspension jitters up and down a little
		local velocity = chassis.AssemblyLinearVelocity
		local ground = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
		local forward = velocity:Dot(chassis.CFrame.LookVector)
		local mph = ground * Config.Vehicles.MphPerStud
		local over = ground > Config.Heat.SpeedingThreshold

		-- the needle eases toward the speed like a real gauge
		shownAngle += (dialAngle(mph) - shownAngle) * math.min(1, dt * 10)
		needle.Rotation = shownAngle

		local throttle = if state.seat:IsA("VehicleSeat") then state.seat.ThrottleFloat else 0
		gear.Text = if forward < -1 or (throttle < 0 and forward < 1) then "R"
			elseif math.abs(forward) < 0.5 and throttle == 0 then "P"
			else "D"
		setIndicator(lights, state.car:GetAttribute("Headlights") == true, C.Pickup)
		setIndicator(brake, state.handbrake, C.Wanted)
		setIndicator(speeding, over, C.Wanted)
	end)
end

return CarHudController
