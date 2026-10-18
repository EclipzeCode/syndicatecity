--!strict
-- The burner phone: a Contracts app that lists jobs from the server and lets the player accept one,
-- and shows the job in progress. Open with the Phone button or the P key. Contract updates arrive
-- as HUD toasts and set the objective and waypoint.

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local HudController = require(script.Parent.HudController)
local Theme = require(script.Parent.Parent.UI.Theme)

local player = Players.LocalPlayer
local C = Theme.Colors
local F = Theme.Fonts

local getContracts = Remotes.func("GetContracts")
local acceptContract = Remotes.func("AcceptContract")
local contractUpdated = Remotes.event("ContractUpdated")

local PhoneController = {}

local PHONE_SIZE = Vector2.new(300, 560)
local OPEN_POSITION = UDim2.new(1, -16, 1, -80)
local CLOSED_POSITION = UDim2.new(1, -16, 1, PHONE_SIZE.Y + 40)

local phone: Frame
local list: ScrollingFrame
local statusLabel: TextLabel
local clockLabel: TextLabel
local activeCard: Frame
local activeTitle: TextLabel
local activeBody: TextLabel
local isOpen = false

-- the job the player is on, if any, and how far along it is
local activeContract: Types.Contract? = nil
local activeStage: string? = nil

local function pointPosition(name: string, tag: string): Vector3?
	for _, part in CollectionService:GetTagged(tag) do
		if part.Name == name and part:IsA("BasePart") then
			return part.Position
		end
	end
	return nil
end

local function distanceTo(position: Vector3?): string
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not position or not root then
		return ""
	end
	return Theme.distance((position - root.Position).Magnitude)
end

---------------------------------------------------------------------------------------------------
-- Contract list
---------------------------------------------------------------------------------------------------

local function clearList()
	for _, child in list:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

local reload: () -> ()

local function routeRow(parent: Instance, order: number, color: Color3, verb: string, name: string, distance: string)
	local row = Theme.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 18), LayoutOrder = order, Parent = parent })
	Theme.new("Frame", {
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(8, 8),
		Position = UDim2.fromOffset(0, 5),
		Parent = row,
	}, { Theme.corner(4) })
	Theme.label({
		Text = `<font color="#969CAA">{verb}</font>  {name}`,
		RichText = true,
		TextSize = 14,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.new(1, -70, 1, 0),
		Position = UDim2.fromOffset(16, 0),
		Parent = row,
	})
	Theme.label({
		Text = distance,
		Font = F.Mono,
		TextSize = 12,
		TextColor3 = C.TextDim,
		TextXAlignment = Enum.TextXAlignment.Right,
		Size = UDim2.new(0, 60, 1, 0),
		Position = UDim2.new(1, -60, 0, 0),
		Parent = row,
	})
end

local function contractCard(contract: Types.Contract, index: number)
	local pickup = pointPosition(contract.pickupName, Config.Tags.Pickup)
	local dropoff = pointPosition(contract.dropoffName, Config.Tags.Dropoff)
	local card = Theme.new("Frame", {
		LayoutOrder = index,
		BackgroundColor3 = C.PanelRaised,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = list,
	}, { Theme.corner(12), Theme.stroke(0.92), Theme.padding(12, 10) })
	Theme.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6), Parent = card })

	local head = Theme.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 24), LayoutOrder = 1, Parent = card })
	Theme.caption(contract.syndicate, { Size = UDim2.new(1, -90, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd, Parent = head })
	Theme.label({
		Text = Theme.money(contract.payout),
		Font = F.Heavy,
		TextSize = 20,
		TextColor3 = C.Cash,
		TextXAlignment = Enum.TextXAlignment.Right,
		Size = UDim2.new(0, 90, 1, 0),
		Position = UDim2.new(1, -90, 0, 0),
		Parent = head,
	})
	routeRow(card, 2, C.Pickup, "Pick up", contract.pickupName, distanceTo(pickup))
	local route = if pickup and dropoff then Theme.distance((dropoff - pickup).Magnitude) else ""
	routeRow(card, 3, C.Dropoff, "Deliver", contract.dropoffName, route)

	local busy = activeContract ~= nil
	local accept = Theme.button({
		Text = if busy then "Finish your current job first" else "Accept",
		LayoutOrder = 4,
		Size = UDim2.new(1, 0, 0, 34),
		BackgroundColor3 = if busy then C.Track else C.Cash,
		TextColor3 = if busy then C.TextDim else Color3.fromRGB(14, 30, 18),
		AutoButtonColor = not busy,
		Active = not busy,
		Parent = card,
	})
	accept.Activated:Connect(function()
		if activeContract then
			return
		end
		accept.Text = "Accepting…"
		local ok, err = acceptContract:InvokeServer(contract.id)
		if ok then
			PhoneController.close()
		else
			-- usually the board moved on: show the fresh list, then say why
			reload()
			statusLabel.Text = err or "Couldn't accept that contract"
			statusLabel.TextColor3 = C.Danger
		end
	end)
end

local function refreshActiveCard()
	local contract = activeContract
	activeCard.Visible = contract ~= nil
	if not contract then
		return
	end
	if activeStage == "pickedUp" then
		activeTitle.Text = `Deliver to {contract.dropoffName}`
		activeBody.Text = `{distanceTo(pointPosition(contract.dropoffName, Config.Tags.Dropoff))} away · keep a low profile`
		activeTitle.TextColor3 = C.Dropoff
	else
		activeTitle.Text = `Pick up at {contract.pickupName}`
		activeBody.Text = `{distanceTo(pointPosition(contract.pickupName, Config.Tags.Pickup))} away · {Theme.money(contract.payout)} on delivery`
		activeTitle.TextColor3 = C.Pickup
	end
end

local function render(contracts: { Types.Contract })
	clearList()
	refreshActiveCard()
	statusLabel.TextColor3 = C.TextDim
	statusLabel.Text = if #contracts == 0 then "No contracts right now. Check back soon." else `{#contracts} jobs on offer`
	for index, contract in contracts do
		contractCard(contract, index)
	end
end

local lastReload = 0

reload = function()
	lastReload = os.clock()
	statusLabel.Text = "Connecting…"
	statusLabel.TextColor3 = C.TextDim
	local ok, contracts = pcall(function()
		return getContracts:InvokeServer()
	end)
	if ok then
		render(contracts :: { Types.Contract })
	else
		statusLabel.Text = "No signal. Try again."
		statusLabel.TextColor3 = C.Danger
	end
end

---------------------------------------------------------------------------------------------------
-- Open / close
---------------------------------------------------------------------------------------------------

function PhoneController.open()
	if isOpen then
		return
	end
	isOpen = true
	phone.Visible = true
	TweenService:Create(phone, TweenInfo.new(0.35, Enum.EasingStyle.Quint), { Position = OPEN_POSITION }):Play()
	task.spawn(reload)
end

function PhoneController.close()
	if not isOpen then
		return
	end
	isOpen = false
	local tween = TweenService:Create(phone, TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.In), { Position = CLOSED_POSITION })
	tween:Play()
	tween.Completed:Connect(function()
		if not isOpen then
			phone.Visible = false
		end
	end)
end

function PhoneController.toggle()
	if isOpen then
		PhoneController.close()
	else
		PhoneController.open()
	end
end

---------------------------------------------------------------------------------------------------
-- Contract updates
---------------------------------------------------------------------------------------------------

local function onContractUpdated(status: Types.JobStatus, contract: Types.Contract?)
	if not contract then
		return
	end
	if status == "accepted" then
		activeContract, activeStage = contract, "accepted"
		HudController.setObjective(`Pick up the cargo at {contract.pickupName}`, "pickup")
		HudController.setWaypoint(contract.pickupName, true)
		HudController.toast("pickup", "Contract accepted", `{contract.syndicate} · pick up at {contract.pickupName}`)
	elseif status == "pickedUp" then
		activeStage = "pickedUp"
		HudController.setObjective(`Deliver to {contract.dropoffName}. Keep a low profile.`, "dropoff")
		HudController.setWaypoint(contract.dropoffName, false)
		HudController.toast("dropoff", "Cargo loaded", `Deliver to {contract.dropoffName}`)
	else
		activeContract, activeStage = nil, nil
		HudController.setObjective("")
		HudController.setWaypoint(nil)
		if status == "delivered" then
			HudController.showBanner(`+{Theme.money(contract.payout)}`, C.Cash)
			HudController.toast("cash", "Delivered", `{contract.syndicate} paid {Theme.money(contract.payout)}`, 5)
		elseif status == "failed" then
			HudController.toast("danger", "Job failed", "The cargo is gone.", 5)
		elseif status == "busted" then
			HudController.toast("police", "Cargo confiscated", "The police took the shipment.", 5)
		end
	end
	if isOpen then
		task.spawn(reload)
	end
end

---------------------------------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------------------------------

local function buildStatusBar(screen: Frame)
	local bar = Theme.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28), Parent = screen })
	Theme.padding(14, 0).Parent = bar
	clockLabel = Theme.label({ Font = F.Mono, TextSize = 13, Size = UDim2.new(0.4, 0, 1, 0), Parent = bar })
	-- short enough to stay clear of the notch; a burner gets 3G at best
	Theme.label({
		Text = "3G · 87%",
		Font = F.Mono,
		TextSize = 12,
		TextColor3 = C.TextDim,
		TextXAlignment = Enum.TextXAlignment.Right,
		Size = UDim2.new(0.6, 0, 1, 0),
		Position = UDim2.fromScale(0.4, 0),
		Parent = bar,
	})
	-- the notch
	Theme.new("Frame", {
		BackgroundColor3 = Color3.fromRGB(8, 8, 10),
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(84, 20),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 0),
		Parent = screen,
	}, { Theme.corner(10) })
end

function PhoneController.init()
	local gui = Theme.new("ScreenGui", {
		Name = "Phone",
		ResetOnSpawn = false,
		Parent = player:WaitForChild("PlayerGui"),
	})

	-- the phone button, bottom right
	local button = Theme.new("TextButton", {
		Name = "PhoneButton",
		Text = "",
		AutoButtonColor = true,
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = Theme.PanelTransparency,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(140, 48),
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -16, 1, -16),
		Parent = gui,
	}, { Theme.corner(), Theme.stroke() })
	Theme.label({ Text = "Phone", Font = F.Bold, Size = UDim2.new(1, -56, 1, 0), Position = UDim2.fromOffset(16, 0), Parent = button })
	local key = Theme.new("Frame", {
		BackgroundColor3 = C.PanelRaised,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(28, 28),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Parent = button,
	}, { Theme.corner(6), Theme.stroke(0.8) })
	Theme.label({ Text = "P", Font = F.Mono, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = key })
	button.Activated:Connect(PhoneController.toggle)

	-- the device: a dark body with a bezel around the screen
	phone = Theme.new("Frame", {
		Name = "Device",
		Visible = false,
		BackgroundColor3 = Color3.fromRGB(10, 10, 12),
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(PHONE_SIZE.X, PHONE_SIZE.Y),
		AnchorPoint = Vector2.new(1, 1),
		Position = CLOSED_POSITION,
		Parent = gui,
	}, { Theme.corner(32), Theme.stroke(0, Color3.fromRGB(58, 60, 68)), Theme.padding(8) })
	-- shrink to fit short screens (the phone button and a margin stay visible)
	local fit = Theme.new("UIScale", { Parent = phone })
	local function rescale()
		local camera = workspace.CurrentCamera
		local height = if camera then camera.ViewportSize.Y else 800
		fit.Scale = math.clamp((height - 110) / PHONE_SIZE.Y, 0.6, 1)
	end
	rescale()
	if workspace.CurrentCamera then
		workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
	end
	local screen = Theme.new("Frame", {
		Name = "Screen",
		BackgroundColor3 = Color3.fromRGB(16, 18, 24),
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ClipsDescendants = true,
		Parent = phone,
	}, { Theme.corner(26) })
	buildStatusBar(screen)

	-- app header
	local header = Theme.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -28, 0, 48), Position = UDim2.fromOffset(14, 34), Parent = screen })
	Theme.label({ Text = "Contracts", Font = F.Heavy, TextSize = 24, Size = UDim2.new(1, -80, 0, 28), Parent = header })
	statusLabel = Theme.caption("", { Size = UDim2.new(1, -80, 0, 16), Position = UDim2.fromOffset(0, 30), Parent = header })
	-- Gotham has no refresh arrow glyph, so the button says what it does
	local refresh = Theme.button({
		Text = "Refresh",
		TextSize = 12,
		Size = UDim2.fromOffset(68, 28),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Parent = header,
	})
	refresh.Activated:Connect(function()
		task.spawn(reload)
	end)

	-- the job in progress
	activeCard = Theme.new("Frame", {
		Name = "ActiveJob",
		Visible = false,
		BackgroundColor3 = C.PanelRaised,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -28, 0, 62),
		Position = UDim2.fromOffset(14, 90),
		Parent = screen,
	}, { Theme.corner(12), Theme.stroke(0.6, C.Pickup), Theme.padding(12, 10) })
	Theme.caption("Current job", { Size = UDim2.new(1, 0, 0, 12), Parent = activeCard })
	activeTitle = Theme.label({ Font = F.Bold, TextSize = 15, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, 0, 0, 18), Position = UDim2.fromOffset(0, 14), Parent = activeCard })
	activeBody = Theme.label({ TextSize = 12, TextColor3 = C.TextDim, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, 0, 0, 14), Position = UDim2.fromOffset(0, 32), Parent = activeCard })

	list = Theme.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -20, 1, -126),
		Position = UDim2.fromOffset(14, 92),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = C.TextDim,
		Parent = screen,
	})
	Theme.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 10), Parent = list })
	Theme.new("UIPadding", { PaddingRight = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), Parent = list })

	-- the home bar closes the app
	local home = Theme.new("TextButton", {
		Text = "",
		BackgroundColor3 = C.TextDim,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		Size = UDim2.fromOffset(110, 5),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -10),
		Parent = screen,
	}, { Theme.corner(3) })
	home.Activated:Connect(PhoneController.close)

	-- the list sits below the active-job card while there is one
	activeCard:GetPropertyChangedSignal("Visible"):Connect(function()
		local top = if activeCard.Visible then 162 else 92
		list.Position = UDim2.fromOffset(14, top)
		list.Size = UDim2.new(1, -20, 1, -(top + 34))
	end)

	-- the clock follows the in-game time of day; distances on the active card stay current
	local tick = 0
	RunService.Heartbeat:Connect(function(dt)
		tick += dt
		if tick < 0.5 or not isOpen then
			return
		end
		tick = 0
		local minutes = math.floor(Lighting.ClockTime * 60) % (24 * 60)
		clockLabel.Text = string.format("%02d:%02d", minutes // 60, minutes % 60)
		refreshActiveCard()
		-- the board turns over every Config.Jobs.RefreshSeconds; don't let an open phone go stale
		if os.clock() - lastReload > 20 then
			task.spawn(reload)
		end
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.P then
			PhoneController.toggle()
		elseif input.KeyCode == Enum.KeyCode.Escape and isOpen then
			PhoneController.close()
		end
	end)

	contractUpdated.OnClientEvent:Connect(onContractUpdated)
end

return PhoneController
