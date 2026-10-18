--!strict
-- The pickup contact: shows a contact's Talk prompt only to the player whose contract uses that
-- pickup, and runs the short dialogue the server opens (a line from the contact and three
-- answers). The server decides everything; this only renders and forwards the choice.
-- Answer with a click, a tap or a gamepad; Leave (Escape, gamepad B) closes it.

local CollectionService = game:GetService("CollectionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local HudController = require(script.Parent.HudController)
local Theme = require(script.Parent.Parent.UI.Theme)

local player = Players.LocalPlayer
local C = Theme.Colors
local F = Theme.Fonts

local answerContact = Remotes.func("AnswerContact")
local closeContact = Remotes.event("CloseContact")

local ContactController = {}

-- the pickup the player's contract is waiting on ("" when none)
local activePickup = ""

local panel: Frame
local nameLabel: TextLabel
local lineLabel: TextLabel
local buttons: { TextButton } = {}
local isOpen = false
local busy = false
local version = 0

---------------------------------------------------------------------------------------------------
-- Prompts
---------------------------------------------------------------------------------------------------

local function updatePrompt(prompt: Instance)
	if prompt:IsA("ProximityPrompt") then
		prompt.Enabled = activePickup ~= "" and prompt:GetAttribute("PickupName") == activePickup
	end
end

local function updatePrompts()
	for _, prompt in CollectionService:GetTagged("ContactPrompt") do
		updatePrompt(prompt)
	end
end

---------------------------------------------------------------------------------------------------
-- Dialogue
---------------------------------------------------------------------------------------------------

local function setButtonsActive(active: boolean)
	for _, button in buttons do
		button.Active = active
		button.AutoButtonColor = active
		button.TextTransparency = if active then 0 else 0.35
	end
end

local function resetButtons()
	for _, button in buttons do
		button.BackgroundColor3 = C.PanelRaised
		local stroke = button:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Transparency = 0.9
			stroke.Color = C.Outline
		end
	end
end

function ContactController.close(tellServer: boolean)
	if not isOpen then
		return
	end
	isOpen = false
	version += 1
	if tellServer then
		closeContact:FireServer()
	end
	if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(panel) then
		GuiService.SelectedObject = nil
	end
	local fade = TweenService:Create(panel, TweenInfo.new(0.2), { Position = UDim2.new(0.5, 0, 1, 40) })
	fade:Play()
	fade.Completed:Connect(function()
		if not isOpen then
			panel.Visible = false
		end
	end)
end

local function open(contact: string, line: string, options: { string })
	version += 1
	isOpen = true
	busy = false
	nameLabel.Text = string.upper(contact)
	lineLabel.Text = `"{line}"`
	lineLabel.TextColor3 = C.Text
	resetButtons()
	for i, button in buttons do
		local option = options[i]
		button.Visible = option ~= nil
		button.Text = option or ""
	end
	setButtonsActive(true)
	panel.Visible = true
	panel.Position = UDim2.new(0.5, 0, 1, 40)
	TweenService:Create(panel, TweenInfo.new(0.3, Enum.EasingStyle.Quint), { Position = UDim2.new(0.5, 0, 1, -84) }):Play()
	if UserInputService.GamepadEnabled then
		GuiService.SelectedObject = buttons[1]
	end
end

local function choose(index: number)
	local button = buttons[index]
	if not isOpen or busy or not button or not button.Visible then
		return
	end
	busy = true
	local myVersion = version
	setButtonsActive(false)
	local stroke = button:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = C.Text
		stroke.Transparency = 0.2
	end
	lineLabel.TextColor3 = C.TextDim

	local ok, reply = pcall(function()
		return answerContact:InvokeServer(index)
	end)
	if myVersion ~= version then
		-- closed while we were waiting
		return
	end
	local result = if ok and typeof(reply) == "table" then reply else nil
	if not result then
		-- too fast, or the server ignored it: let them try again
		task.wait(0.4)
		if myVersion == version then
			busy = false
			resetButtons()
			setButtonsActive(true)
		end
		return
	end

	if result.line ~= "" then
		lineLabel.Text = `"{result.line}"`
	end
	if result.ok then
		lineLabel.TextColor3 = C.Cash
		button.BackgroundColor3 = C.Cash:Lerp(C.PanelRaised, 0.6)
		task.delay(1.6, function()
			if myVersion == version then
				ContactController.close(false)
			end
		end)
	elseif result.done then
		ContactController.close(false)
	else
		-- wrong answer: no penalty, just say so and let them pick again
		lineLabel.TextColor3 = C.Danger
		button.BackgroundColor3 = C.Danger:Lerp(C.PanelRaised, 0.7)
		task.wait(0.5)
		if myVersion == version then
			busy = false
			resetButtons()
			setButtonsActive(true)
		end
	end
end

local function build()
	local gui = Theme.new("ScreenGui", {
		Name = "ContactDialogue",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 5,
		Parent = player:WaitForChild("PlayerGui"),
	})
	panel = Theme.panel({
		Name = "Dialogue",
		Visible = false,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, 40),
		Size = UDim2.new(1, -32, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = gui,
	})
	-- leave the phone button (bottom right) clear on wide screens; fill the width on phones
	Theme.new("UISizeConstraint", { MaxSize = Vector2.new(520, math.huge), Parent = panel })
	Theme.padding(16, 14).Parent = panel
	Theme.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8), Parent = panel })

	local head = Theme.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 16), LayoutOrder = 1, Parent = panel })
	nameLabel = Theme.caption("", { TextColor3 = C.Pickup, Size = UDim2.new(1, -70, 1, 0), Parent = head })
	local leave = Theme.new("TextButton", {
		Text = "Leave",
		Font = F.Bold,
		TextSize = 12,
		TextColor3 = C.TextDim,
		BackgroundTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Right,
		Size = UDim2.new(0, 70, 1, 0),
		Position = UDim2.new(1, -70, 0, 0),
		Parent = head,
	})
	leave.Activated:Connect(function()
		ContactController.close(true)
	end)

	lineLabel = Theme.label({
		Font = F.Bold,
		TextSize = 17,
		TextWrapped = true,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 22),
		LayoutOrder = 2,
		Parent = panel,
	})

	for i = 1, 3 do
		local button = Theme.button({
			Name = `Answer{i}`,
			LayoutOrder = 2 + i,
			TextSize = 16,
			TextXAlignment = Enum.TextXAlignment.Left,
			Size = UDim2.new(1, 0, 0, 44),
			Selectable = true,
			Parent = panel,
		})
		Theme.stroke(0.9).Parent = button
		Theme.new("UIPadding", { PaddingLeft = UDim.new(0, 14), Parent = button })
		button.Activated:Connect(function()
			task.spawn(choose, i)
		end)
		buttons[i] = button
	end
end

function ContactController.init()
	build()

	Remotes.event("ContactDialogue").OnClientEvent:Connect(function(action: string, payload: any)
		if action == "open" and typeof(payload) == "table" and typeof(payload.options) == "table" then
			open(tostring(payload.contact or "Contact"), tostring(payload.line or ""), payload.options)
		elseif action == "close" then
			ContactController.close(false)
			if typeof(payload) == "string" and payload ~= "" then
				HudController.notify("info", payload)
			end
		end
	end)

	-- only the contact for this player's own pickup offers to talk
	Remotes.event("ContractUpdated").OnClientEvent:Connect(function(status: Types.JobStatus, contract: Types.Contract?)
		activePickup = if status == "accepted" and contract then contract.pickupName else ""
		-- a pickup is closed by the answer reply, after the contact's last line; anything else
		-- (failed, busted) ends the conversation at once
		if status ~= "accepted" and status ~= "pickedUp" then
			ContactController.close(false)
		end
		updatePrompts()
	end)
	CollectionService:GetInstanceAddedSignal("ContactPrompt"):Connect(updatePrompt)
	updatePrompts()

	UserInputService.InputBegan:Connect(function(input, _gameProcessed)
		if not isOpen then
			return
		end
		-- (no number-key shortcuts: 1-3 equip backpack tools)
		if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB then
			ContactController.close(true)
		end
	end)
end

return ContactController
