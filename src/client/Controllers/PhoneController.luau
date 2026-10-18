--!strict
-- The burner phone, with two apps: Contracts (jobs from the server, accept one, the job in
-- progress) and GPS (UI.GpsApp: map, route and directions to the job's pickup or dropoff, speed
-- limit). Open with the Phone button or P; getting into a car opens the GPS. Every game
-- notification (contract updates, police, busts) pops up on the phone: at the top of its screen
-- while it's open, or with the phone peeking up from the bottom of the screen while it's away.
-- The phone is the only navigation: nothing marks destinations in the world.

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Sounds = require(ReplicatedStorage.Shared.Sounds)
local Types = require(ReplicatedStorage.Shared.Types)
local HudController = require(script.Parent.HudController)
local GpsApp = require(script.Parent.Parent.UI.GpsApp)
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
-- when the phone peeks up with notifications: the space above the first card (bezel, status
-- bar) and below the last
local PEEK_TOP = 38
local PEEK_BOTTOM = 14

local phone: Frame
local list: ScrollingFrame
local statusLabel: TextLabel
local clockLabel: TextLabel
local activeCard: Frame
local activeTitle: TextLabel
local activeBody: TextLabel
local isOpen = false
local fit: UIScale
local notices: Frame
local noticeOrder = 0
local liveNotices = 0
local peeking = false

-- the job the player is on, if any, how far along it is, and the code the pickup contact wants
local activeContract: Types.Contract? = nil
local activeStage: string? = nil
local activePasscode: string? = nil

-- tier label colors on contract cards
local TIER_COLORS: { [string]: Color3 } = {
	Routine = C.Cash,
	Standard = C.Dropoff,
	["High-value"] = C.Danger,
}

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
	if contract.tier then
		local tierColor = TIER_COLORS[contract.tier] or C.TextDim
		local drive = if contract.routeSeconds then ` · ~{contract.routeSeconds}s drive` else ""
		Theme.label({
			Text = `<font color="#{tierColor:ToHex()}">{string.upper(contract.tier)}</font>  {contract.cargo or "Cargo"}{drive}`,
			RichText = true,
			TextSize = 12,
			TextColor3 = C.TextDim,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Size = UDim2.new(1, 0, 0, 14),
			LayoutOrder = 2,
			Parent = card,
		})
	end
	routeRow(card, 3, C.Pickup, "Pick up", contract.pickupName, distanceTo(pickup))
	local route = if pickup and dropoff then Theme.distance((dropoff - pickup).Magnitude) else ""
	routeRow(card, 4, C.Dropoff, "Deliver", contract.dropoffName, route)

	local busy = activeContract ~= nil
	local accept = Theme.button({
		Text = if busy then "Finish your current job first" else "Accept",
		LayoutOrder = 5,
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
			-- in a car, go straight to directions; on foot, put the phone away
			local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.SeatPart then
				PhoneController.showApp("gps")
			else
				PhoneController.close()
			end
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
		activeTitle.Text = `Meet the contact at {contract.pickupName}`
		local code = if activePasscode then `Code: {activePasscode} · ` else ""
		activeBody.Text = `{code}{distanceTo(pointPosition(contract.pickupName, Config.Tags.Pickup))} away · {Theme.money(contract.payout)} on delivery`
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
-- Apps, open / close
---------------------------------------------------------------------------------------------------

local pages: { [string]: Frame } = {}
local tabs: { [string]: TextButton } = {}
local currentApp = "contracts"
-- set when getting into a car opened the GPS, so getting out can put the phone away again
local autoOpened = false

function PhoneController.showApp(name: string)
	currentApp = name
	for appName, page in pages do
		page.Visible = appName == name
	end
	for appName, tab in tabs do
		local active = appName == name
		tab.BackgroundColor3 = if active then C.PanelRaised else C.Panel
		tab.TextColor3 = if active then C.Text else C.TextDim
	end
	if name == "contracts" and isOpen then
		task.spawn(reload)
	end
end

-- Opens the phone, on `app` if given ("contracts" or "gps").
function PhoneController.open(app: string?)
	if app then
		PhoneController.showApp(app)
	end
	if isOpen then
		return
	end
	isOpen = true
	peeking = false
	phone.Visible = true
	TweenService:Create(phone, TweenInfo.new(0.35, Enum.EasingStyle.Quint), { Position = OPEN_POSITION }):Play()
	if currentApp == "contracts" then
		task.spawn(reload)
	end
end

local function slideAway()
	local tween = TweenService:Create(phone, TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.In), { Position = CLOSED_POSITION })
	tween:Play()
	tween.Completed:Connect(function()
		if not isOpen and not peeking then
			phone.Visible = false
		end
	end)
end

function PhoneController.close()
	autoOpened = false
	if not isOpen then
		return
	end
	isOpen = false
	slideAway()
end

---------------------------------------------------------------------------------------------------
-- Notifications
---------------------------------------------------------------------------------------------------

-- With the phone away, it peeks up far enough to show its notifications (re-run as cards come
-- and go, once the list has laid itself out).
local function peek()
	if isOpen then
		return
	end
	peeking = true
	phone.Visible = true
	local cards = 0
	for _, child in notices:GetChildren() do
		if child.Name == "Notice" and child:IsA("Frame") then
			cards += child.Size.Y.Offset + 6
		end
	end
	local shown = (PEEK_TOP + cards + PEEK_BOTTOM) * fit.Scale
	local y = PHONE_SIZE.Y * fit.Scale - shown
	TweenService:Create(phone, TweenInfo.new(0.35, Enum.EasingStyle.Back), { Position = UDim2.new(1, -16, 1, y) }):Play()
end

local function unpeek()
	if not peeking then
		return
	end
	peeking = false
	if not isOpen then
		slideAway()
	end
end

-- the ringer, once per burst of notices
local RING_GAP = 0.6
local lastRing = 0

-- A notification card at the top of the phone screen; leaves after `seconds`. `big` shows the
-- title large, for the moments that matter (BUSTED, WANTED, +$1,200). The phone rings for it.
function PhoneController.notify(kind: string, title: string, body: string?, seconds: number?, big: boolean?)
	local now = os.clock()
	if now - lastRing > RING_GAP then
		lastRing = now
		Sounds.play("PhoneRing", SoundService, if big then 1.2 else 1)
	end
	local style = Theme.Notices[kind] or Theme.Notices.info
	noticeOrder += 1
	liveNotices += 1
	local hasBody = body ~= nil and body ~= ""
	local height = (if big then 50 else 44) + (if hasBody then 30 else 0)
	local card = Theme.new("Frame", {
		Name = "Notice",
		LayoutOrder = -noticeOrder,
		BackgroundColor3 = C.PanelRaised,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, height),
		Parent = notices,
	}, { Theme.corner(14), Theme.stroke(0.5, style.color) })
	local chip = Theme.new("Frame", {
		BackgroundColor3 = style.color,
		BackgroundTransparency = 0.8,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(28, 28),
		Position = UDim2.fromOffset(10, 10),
		Parent = card,
	}, { Theme.corner(14) })
	Theme.label({
		Text = style.icon,
		Font = F.Heavy,
		TextSize = 15,
		TextColor3 = style.color,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		Parent = chip,
	})
	Theme.label({
		Text = title,
		Font = if big then F.Heavy else F.Bold,
		TextSize = if big then 26 else 14,
		TextColor3 = if big then style.color else C.Text,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.new(1, -56, 0, if big then 32 else 18),
		Position = UDim2.fromOffset(46, if big then 8 else 15),
		Parent = card,
	})
	if hasBody then
		Theme.label({
			Text = body,
			TextSize = 12,
			TextColor3 = C.TextDim,
			TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Top,
			Size = UDim2.new(1, -56, 0, 30),
			Position = UDim2.fromOffset(46, if big then 42 else 36),
			Parent = card,
		})
	end
	-- keep the stack short
	local cards = {}
	for _, child in notices:GetChildren() do
		if child.Name == "Notice" then
			table.insert(cards, child)
		end
	end
	table.sort(cards, function(a, b)
		return (a :: Frame).LayoutOrder < (b :: Frame).LayoutOrder
	end)
	for i = 3, #cards do
		cards[i]:Destroy()
	end

	local scale = Theme.new("UIScale", { Scale = 0.85, Parent = card })
	TweenService:Create(scale, TweenInfo.new(0.3, Enum.EasingStyle.Back), { Scale = 1 }):Play()
	peek()

	task.delay(seconds or 4, function()
		liveNotices = math.max(0, liveNotices - 1)
		if card.Parent then
			local fade = TweenService:Create(scale, TweenInfo.new(0.2, Enum.EasingStyle.Quint, Enum.EasingDirection.In), { Scale = 0 })
			fade:Play()
			fade.Completed:Wait()
			card:Destroy()
		end
		if liveNotices == 0 then
			unpeek()
		elseif peeking then
			peek()
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

local function onContractUpdated(status: Types.JobStatus, contract: Types.Contract?, details: Types.ContractDetails?)
	if not contract then
		return
	end
	if status == "accepted" then
		activeContract, activeStage = contract, "accepted"
		activePasscode = if details and typeof(details.passcode) == "string" then details.passcode else nil
		local code = if activePasscode then ` · code "{activePasscode}"` else ""
		HudController.setObjective(`Meet the contact at {contract.pickupName}{code}`, "pickup")
		GpsApp.setDestination(pointPosition(contract.pickupName, Config.Tags.Pickup), contract.pickupName, C.Pickup)
		HudController.notify("pickup", "Contract accepted", `Meet the contact at {contract.pickupName}{code}`, 8)
	elseif status == "pickedUp" then
		activeStage = "pickedUp"
		HudController.setObjective(`Deliver to {contract.dropoffName}. Keep a low profile.`, "dropoff")
		GpsApp.setDestination(pointPosition(contract.dropoffName, Config.Tags.Dropoff), contract.dropoffName, C.Dropoff)
		HudController.notify("dropoff", "Cargo loaded", `Deliver to {contract.dropoffName} · route on your GPS`)
	else
		activeContract, activeStage, activePasscode = nil, nil, nil
		HudController.setObjective("")
		GpsApp.setDestination(nil)
		if status == "delivered" then
			HudController.notify("cash", `+{Theme.money(contract.payout)}`, `Delivered · {contract.syndicate} paid up`, 5, true)
		elseif status == "failed" then
			HudController.notify("danger", "Job failed", "The cargo is gone.", 5)
		elseif status == "busted" then
			HudController.notify("police", "Cargo confiscated", "The police took the shipment.", 5)
		end
	end
	if isOpen and currentApp == "contracts" then
		task.spawn(reload)
	end
end

-- Getting into a car opens the GPS; getting out puts the phone away if the car opened it.
local function onCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.Seated:Connect(function(active, seat)
		if active then
			local car = seat and seat.Parent
			if car and CollectionService:HasTag(car, "Vehicle") then
				local wasShowingGps = isOpen and currentApp == "gps"
				PhoneController.open("gps")
				autoOpened = not wasShowingGps
			end
		elseif autoOpened then
			if isOpen and currentApp == "gps" then
				PhoneController.close()
			end
			autoOpened = false
		end
	end)
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

-- The Contracts app: header, the job in progress, and the list of offers.
local function buildContracts(page: Frame)
	local header = Theme.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -28, 0, 48), Position = UDim2.fromOffset(14, 4), Parent = page })
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

	activeCard = Theme.new("Frame", {
		Name = "ActiveJob",
		Visible = false,
		BackgroundColor3 = C.PanelRaised,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -28, 0, 62),
		Position = UDim2.fromOffset(14, 60),
		Parent = page,
	}, { Theme.corner(12), Theme.stroke(0.6, C.Pickup), Theme.padding(12, 10) })
	Theme.caption("Current job", { Size = UDim2.new(1, 0, 0, 12), Parent = activeCard })
	activeTitle = Theme.label({ Font = F.Bold, TextSize = 15, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, 0, 0, 18), Position = UDim2.fromOffset(0, 14), Parent = activeCard })
	activeBody = Theme.label({ TextSize = 12, TextColor3 = C.TextDim, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, 0, 0, 14), Position = UDim2.fromOffset(0, 32), Parent = activeCard })

	list = Theme.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -20, 1, -62),
		Position = UDim2.fromOffset(14, 62),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = C.TextDim,
		Parent = page,
	})
	Theme.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 10), Parent = list })
	Theme.new("UIPadding", { PaddingRight = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), Parent = list })

	-- the list sits below the active-job card while there is one
	activeCard:GetPropertyChangedSignal("Visible"):Connect(function()
		local top = if activeCard.Visible then 132 else 62
		list.Position = UDim2.fromOffset(14, top)
		list.Size = UDim2.new(1, -20, 1, -top)
	end)
end

function PhoneController.init()
	local gui = Theme.new("ScreenGui", {
		Name = "Phone",
		ResetOnSpawn = false,
		-- Sibling keeps the GPS map's layers inside its CanvasGroup (Global lets them escape it)
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
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
	fit = Theme.new("UIScale", { Parent = phone })
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

	-- app pages fill the space between the status bar and the tab bar
	pages.contracts = Theme.new("Frame", {
		Name = "Contracts",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 1, -92),
		Position = UDim2.fromOffset(0, 30),
		Parent = screen,
	})
	pages.gps = Theme.new("Frame", {
		Name = "Gps",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -20, 1, -96),
		Position = UDim2.fromOffset(10, 32),
		Visible = false,
		Parent = screen,
	})
	buildContracts(pages.contracts)
	GpsApp.build(pages.gps)

	-- tab bar
	local tabBar = Theme.new("Frame", {
		BackgroundColor3 = C.Panel,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -20, 0, 38),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -22),
		Parent = screen,
	}, { Theme.corner(12), Theme.padding(4) })
	Theme.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = tabBar,
	})
	for i, app in { { "contracts", "Contracts" }, { "gps", "GPS" } } do
		local tab = Theme.button({
			Text = app[2],
			TextSize = 13,
			LayoutOrder = i,
			Size = UDim2.new(0.5, -2, 1, 0),
			Parent = tabBar,
		})
		tab.Activated:Connect(function()
			PhoneController.showApp(app[1])
		end)
		tabs[app[1]] = tab
	end
	PhoneController.showApp("contracts")

	-- the home bar closes the phone
	local home = Theme.new("TextButton", {
		Text = "",
		BackgroundColor3 = C.TextDim,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		Size = UDim2.fromOffset(110, 5),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -8),
		Parent = screen,
	}, { Theme.corner(3) })
	home.Activated:Connect(PhoneController.close)

	-- notifications drop in over whatever app is showing, below the status bar
	notices = Theme.new("Frame", {
		Name = "Notices",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -16, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Position = UDim2.fromOffset(8, 30),
		ZIndex = 10,
		Parent = screen,
	})
	Theme.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6), Parent = notices })
	HudController.setNotifier(PhoneController.notify)

	-- the GPS redraws every frame while it's showing
	RunService.RenderStepped:Connect(function(dt)
		if isOpen and currentApp == "gps" then
			GpsApp.update(dt)
		end
	end)

	-- the clock follows the in-game time of day; the contracts page stays current
	local tick = 0
	RunService.Heartbeat:Connect(function(dt)
		tick += dt
		if tick < 0.5 or not isOpen then
			return
		end
		tick = 0
		local minutes = math.floor(Lighting.ClockTime * 60) % (24 * 60)
		clockLabel.Text = string.format("%02d:%02d", minutes // 60, minutes % 60)
		if currentApp == "contracts" then
			refreshActiveCard()
			-- the board turns over every Config.Jobs.RefreshSeconds; don't let an open phone go stale
			if os.clock() - lastReload > 20 then
				task.spawn(reload)
			end
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
	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end
end

return PhoneController
