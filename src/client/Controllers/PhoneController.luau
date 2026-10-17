--!strict
-- The burner phone: lists contracts from the server and lets the player accept one.
-- Open with the Phone button or the P key.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local HudController = require(script.Parent.HudController)

local player = Players.LocalPlayer

local getContracts = Remotes.func("GetContracts")
local acceptContract = Remotes.func("AcceptContract")
local contractUpdated = Remotes.event("ContractUpdated")

local PhoneController = {}

local phone: Frame
local list: ScrollingFrame
local errorLabel: TextLabel

local function clearList()
	for _, child in list:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

local function render(contracts: { Types.Contract })
	clearList()
	errorLabel.Text = if #contracts == 0 then "No contracts right now. Check back soon." else ""

	for index, contract in contracts do
		local row = Instance.new("TextButton")
		row.LayoutOrder = index
		row.Size = UDim2.new(1, 0, 0, 56)
		row.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
		row.BorderSizePixel = 0
		row.AutoButtonColor = true
		row.Font = Enum.Font.Gotham
		row.TextSize = 14
		row.TextColor3 = Color3.new(1, 1, 1)
		row.TextWrapped = true
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.Text = `  {contract.syndicate}  ·  ${contract.payout}\n  {contract.pickupName} → {contract.dropoffName}`
		row.Activated:Connect(function()
			local ok, err = acceptContract:InvokeServer(contract.id)
			if ok then
				phone.Visible = false
			else
				errorLabel.Text = err or "Couldn't accept that contract"
			end
		end)
		row.Parent = list
	end
end

function PhoneController.toggle()
	phone.Visible = not phone.Visible
	if phone.Visible then
		render(getContracts:InvokeServer() :: { Types.Contract })
	end
end

local objectiveVersion = 0

local function showObjective(text: string, clearAfter: number?)
	objectiveVersion += 1
	local version = objectiveVersion
	HudController.setObjective(text)
	if clearAfter then
		task.delay(clearAfter, function()
			-- don't clear a newer objective that replaced this one
			if objectiveVersion == version then
				HudController.setObjective("")
			end
		end)
	end
end

local function onContractUpdated(status: Types.JobStatus, contract: Types.Contract?)
	if not contract then
		return
	end
	if status == "accepted" then
		showObjective(`Pick up the cargo at {contract.pickupName}`)
		HudController.setWaypoint(contract.pickupName, true)
	elseif status == "pickedUp" then
		showObjective(`Deliver to {contract.dropoffName}. Keep a low profile.`)
		HudController.setWaypoint(contract.dropoffName, false)
	elseif status == "delivered" then
		showObjective(`Delivered. {contract.syndicate} paid ${contract.payout}.`, 4)
		HudController.setWaypoint(nil)
		HudController.showBanner("delivered", `+${contract.payout}`)
	elseif status == "failed" then
		showObjective("Job failed. The cargo is gone.", 4)
		HudController.setWaypoint(nil)
		HudController.showBanner("failed", "Job failed")
	elseif status == "busted" then
		showObjective("The police confiscated the cargo.", 4)
		HudController.setWaypoint(nil)
	end
end

function PhoneController.init()
	local gui = Instance.new("ScreenGui")
	gui.Name = "Phone"
	gui.ResetOnSpawn = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local button = Instance.new("TextButton")
	button.Text = "Phone (P)"
	button.Font = Enum.Font.GothamMedium
	button.TextSize = 16
	button.TextColor3 = Color3.new(1, 1, 1)
	button.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
	button.BorderSizePixel = 0
	button.Size = UDim2.fromOffset(120, 40)
	button.AnchorPoint = Vector2.new(1, 1)
	button.Position = UDim2.new(1, -16, 1, -16)
	button.Parent = gui
	button.Activated:Connect(PhoneController.toggle)

	phone = Instance.new("Frame")
	phone.Visible = false
	phone.BackgroundColor3 = Color3.fromRGB(15, 15, 18)
	phone.BorderSizePixel = 0
	phone.Size = UDim2.fromOffset(300, 460)
	phone.AnchorPoint = Vector2.new(1, 1)
	phone.Position = UDim2.new(1, -16, 1, -64)
	phone.Parent = gui

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 18
	title.TextColor3 = Color3.new(1, 1, 1)
	title.Text = "Contracts"
	title.Size = UDim2.new(1, 0, 0, 40)
	title.Parent = phone

	errorLabel = Instance.new("TextLabel")
	errorLabel.BackgroundTransparency = 1
	errorLabel.Font = Enum.Font.Gotham
	errorLabel.TextSize = 13
	errorLabel.TextColor3 = Color3.fromRGB(255, 120, 120)
	errorLabel.TextWrapped = true
	errorLabel.Text = ""
	errorLabel.Size = UDim2.new(1, -16, 0, 32)
	errorLabel.Position = UDim2.new(0, 8, 1, -36)
	errorLabel.Parent = phone

	list = Instance.new("ScrollingFrame")
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.Size = UDim2.new(1, -16, 1, -84)
	list.Position = UDim2.fromOffset(8, 44)
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new()
	list.ScrollBarThickness = 4
	list.Parent = phone

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = list

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if not gameProcessed and input.KeyCode == Enum.KeyCode.P then
			PhoneController.toggle()
		end
	end)

	contractUpdated.OnClientEvent:Connect(onContractUpdated)
end

return PhoneController
