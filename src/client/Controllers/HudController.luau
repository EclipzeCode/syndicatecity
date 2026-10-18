--!strict
-- On-screen HUD: dirty cash, heat, police attention, wanted/bust state, objective and ammo. Reads
-- Player attributes set by the server (DirtyCash, Heat, PoliceAttention, Wanted, BustProgress,
-- Reloading) and the equipped pistol's Ammo attribute. Driving info lives in CarHudController and
-- navigation in the phone's GPS app; nothing marks the world on screen.
--
-- Notifications (HudController.notify, and server "Notice" events) don't take over the screen:
-- they pop up on the burner phone. PhoneController registers itself with setNotifier.

local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Theme = require(script.Parent.Parent.UI.Theme)

local player = Players.LocalPlayer
local C = Theme.Colors
local F = Theme.Fonts

local HudController = {}

local objective: Frame
local objectiveDot: Frame
local objectiveLabel: TextLabel

-- `kind` picks the accent and icon (Theme.Notices); `big` is for moments that matter (BUSTED,
-- WANTED, +$1,200) and shows the title large.
export type Notifier = (kind: string, title: string, body: string?, seconds: number?, big: boolean?) -> ()

local notifier: Notifier? = nil
-- notifications sent before the phone was ready
local pending: { { any } } = {}

-- Server notices (Remotes "Notice") that deserve a big headline.
local NOTICES: { [string]: { title: string, kind: string } } = {
	busted = { title = "BUSTED", kind = "police" },
	wanted = { title = "WANTED", kind = "danger" },
	ko = { title = "KNOCKED OUT", kind = "danger" },
}

-- Quieter server notices.
local QUIET_NOTICES: { [string]: { kind: string, title: string } } = {
	tailed = { kind = "police", title = "You're being followed" },
	clear = { kind = "info", title = "Tail's gone" },
}

-- An optional radio chirp when a patrol starts tailing you (Config.Police.Detection.RadioSoundId).
local function playRadio()
	local id = Config.Police.Detection.RadioSoundId
	if id == "" then
		return
	end
	local sound = Instance.new("Sound")
	sound.SoundId = id
	sound.Volume = 0.5
	SoundService:PlayLocalSound(sound)
	task.delay(5, function()
		sound:Destroy()
	end)
end

---------------------------------------------------------------------------------------------------
-- Notifications
---------------------------------------------------------------------------------------------------

-- Pops a notification up on the phone; it goes away on its own after `seconds`.
function HudController.notify(kind: string, title: string, body: string?, seconds: number?, big: boolean?)
	if notifier then
		notifier(kind, title, body, seconds, big)
	else
		table.insert(pending, { kind, title, body, seconds, big })
	end
end

function HudController.setNotifier(fn: Notifier)
	notifier = fn
	for _, args in pending do
		fn(table.unpack(args))
	end
	table.clear(pending)
end

---------------------------------------------------------------------------------------------------
-- Objective
---------------------------------------------------------------------------------------------------

-- `kind` colors the dot: "pickup", "dropoff", or nothing for neutral.
function HudController.setObjective(text: string, kind: string?)
	objectiveLabel.Text = text
	objective.Visible = text ~= ""
	objectiveDot.BackgroundColor3 = if kind == "pickup" then C.Pickup elseif kind == "dropoff" then C.Dropoff else C.TextDim
end

local function onNotice(kind: string, text: string)
	local notice = NOTICES[kind]
	local quiet = QUIET_NOTICES[kind]
	if quiet then
		HudController.notify(quiet.kind, quiet.title, text, 5)
		if kind == "tailed" then
			playRadio()
		end
	elseif notice then
		-- server texts lead with the headline ("BUSTED! Fined $200…"); the title has it already
		local lead, rest = string.match(text, "^([^!]+)!%s*(.+)$")
		local body = if lead and #lead <= 14 then rest else text
		HudController.notify(notice.kind, notice.title, body, 6, true)
	else
		HudController.notify("info", text)
	end
end

---------------------------------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------------------------------

function HudController.init()
	local gui = Theme.new("ScreenGui", {
		Name = "Hud",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		IgnoreGuiInset = false,
		Parent = player:WaitForChild("PlayerGui"),
	})

	-- status panel: cash, heat, and the wanted strip while police are chasing
	local status = Theme.panel({
		Name = "Status",
		Size = UDim2.fromOffset(240, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Position = UDim2.fromOffset(16, 16),
		Parent = gui,
	})
	local statusStroke = status:FindFirstChildOfClass("UIStroke") :: UIStroke
	Theme.padding(14, 12).Parent = status
	Theme.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8), Parent = status })

	local cashRow = Theme.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40), LayoutOrder = 1, Parent = status })
	local cashChip = Theme.new("Frame", {
		BackgroundColor3 = C.Cash,
		BackgroundTransparency = 0.82,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(36, 36),
		Position = UDim2.fromOffset(0, 2),
		Parent = cashRow,
	}, { Theme.corner(8) })
	Theme.label({ Text = "$", Font = F.Heavy, TextSize = 20, TextColor3 = C.Cash, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = cashChip })
	Theme.caption("Dirty cash", { Size = UDim2.new(1, -48, 0, 14), Position = UDim2.fromOffset(48, 2), Parent = cashRow })
	local cashLabel = Theme.label({ Font = F.Heavy, TextSize = 22, TextColor3 = C.Cash, Size = UDim2.new(1, -48, 0, 24), Position = UDim2.fromOffset(48, 16), Parent = cashRow })

	local heatRow = Theme.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26), LayoutOrder = 2, Parent = status })
	Theme.caption("Heat", { Size = UDim2.new(0.5, 0, 0, 14), Parent = heatRow })
	local heatValue = Theme.caption("", { Size = UDim2.new(0.5, 0, 0, 14), Position = UDim2.fromScale(0.5, 0), TextXAlignment = Enum.TextXAlignment.Right, Parent = heatRow })
	local _, heatFill = Theme.bar({ Size = UDim2.new(1, 0, 0, 8), Position = UDim2.fromOffset(0, 18), Parent = heatRow }, C.HeatLow)

	-- a police car is tailing you: a quiet blue chip, no numbers
	local tailRow = Theme.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20), LayoutOrder = 3, Visible = false, Parent = status })
	local tailChip = Theme.new("Frame", {
		BackgroundColor3 = C.Police,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(92, 20),
		Parent = tailRow,
	}, { Theme.corner(10) })
	Theme.label({ Text = "◉ TAILED", Font = F.Heavy, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = tailChip })
	Theme.caption("Drive clean", { Size = UDim2.new(1, -100, 0, 20), Position = UDim2.fromOffset(100, 0), Parent = tailRow })

	local wantedRow = Theme.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 44), LayoutOrder = 4, Visible = false, Parent = status })
	local wantedChip = Theme.new("Frame", {
		BackgroundColor3 = C.Wanted,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(92, 20),
		Parent = wantedRow,
	}, { Theme.corner(10) })
	Theme.label({ Text = "★ WANTED", Font = F.Heavy, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = wantedChip })
	Theme.caption("Lose them", { Size = UDim2.new(1, -100, 0, 20), Position = UDim2.fromOffset(100, 0), Parent = wantedRow })
	Theme.caption("Bust", { Size = UDim2.new(0, 40, 0, 14), Position = UDim2.fromOffset(0, 28), Parent = wantedRow })
	local _, bustFill = Theme.bar({ Size = UDim2.new(1, -44, 0, 8), Position = UDim2.fromOffset(44, 31), Parent = wantedRow }, C.Police)

	-- objective pill, top centre
	objective = Theme.panel({
		Name = "Objective",
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 40),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 16),
		Visible = false,
		Parent = gui,
	})
	Theme.padding(16, 0).Parent = objective
	Theme.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 10),
		Parent = objective,
	})
	objectiveDot = Theme.new("Frame", { BorderSizePixel = 0, Size = UDim2.fromOffset(10, 10), LayoutOrder = 1, Parent = objective }, { Theme.corner(5) })
	objectiveLabel = Theme.label({ Font = F.Bold, TextSize = 16, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 40), LayoutOrder = 2, Parent = objective })

	-- ammo, bottom right above the phone button
	local ammo = Theme.panel({
		Name = "Ammo",
		Size = UDim2.fromOffset(140, 52),
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -16, 1, -84),
		Visible = false,
		Parent = gui,
	})
	Theme.caption("Pistol", { Size = UDim2.new(1, -24, 0, 14), Position = UDim2.fromOffset(12, 8), Parent = ammo })
	local ammoValue = Theme.label({ Font = F.Mono, TextSize = 18, Size = UDim2.new(1, -24, 0, 22), Position = UDim2.fromOffset(12, 22), Parent = ammo })

	local function refresh()
		local cash = (player:GetAttribute("DirtyCash") :: number?) or 0
		local heat = (player:GetAttribute("Heat") :: number?) or 0
		local bust = (player:GetAttribute("BustProgress") :: number?) or 0
		local wanted = player:GetAttribute("Wanted") == true
		local attention = (player:GetAttribute("PoliceAttention") :: string?) or ""
		local heatFraction = math.clamp(heat / Config.Heat.Max, 0, 1)
		cashLabel.Text = Theme.money(cash)
		heatValue.Text = `{math.floor(heatFraction * 100)}%`
		TweenService:Create(heatFill, TweenInfo.new(0.3), {
			Size = UDim2.fromScale(heatFraction, 1),
			BackgroundColor3 = C.HeatLow:Lerp(C.HeatHigh, heatFraction),
		}):Play()
		wantedRow.Visible = wanted
		tailRow.Visible = attention == "tailed" and not wanted
		bustFill.Size = UDim2.fromScale(math.clamp(bust, 0, 1), 1)
		-- the panel's outline is the subtle tell: blue while a patrol has an eye on you
		statusStroke.Color = if wanted then C.Wanted elseif attention ~= "" then C.Police else C.Outline
		statusStroke.Transparency = if wanted then 0.3 elseif attention == "tailed" then 0.35 elseif attention == "watched" then 0.65 else 0.9
	end
	for _, attribute in { "DirtyCash", "Heat", "Wanted", "BustProgress", "PoliceAttention" } do
		player:GetAttributeChangedSignal(attribute):Connect(refresh)
	end
	refresh()

	RunService.RenderStepped:Connect(function()
		local character = player.Character
		local tool = character and character:FindFirstChild("Pistol")
		if tool then
			ammo.Visible = true
			ammoValue.Text = if player:GetAttribute("Reloading") == true
				then "reloading…"
				else `{tool:GetAttribute("Ammo") or 0} / {tool:GetAttribute("MagazineSize") or 0}`
		else
			ammo.Visible = false
		end
	end)

	Remotes.event("Notice").OnClientEvent:Connect(onNotice)
end

return HudController
