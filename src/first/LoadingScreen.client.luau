--!strict
-- Loading screen. Runs from ReplicatedFirst before anything else, so it can't use UI.Theme yet;
-- the colors and fonts below match it. Stays up until the game has loaded and the character has
-- spawned (or a timeout), then fades out.

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local TweenService = game:GetService("TweenService")

local TITLE = "SMUGGLING GAME"
local SUBTITLE = "CONTRACTS  ·  CARGO  ·  NO QUESTIONS"
local MIN_SECONDS = 2
local MAX_SECONDS = 15

local TIPS = {
	"Press P to open your burner phone and take a contract.",
	"Hold Shift to sprint.",
	"Speeding and driving past patrols raises your heat.",
	"Lose the cops by breaking line of sight. Heat drains faster when they can't see you.",
	"Cash you carry is lost if you get busted.",
	"Cops only bust you when you're slow or stopped. Keep moving.",
}

local BACKGROUND = Color3.fromRGB(16, 18, 24)
local TEXT = Color3.fromRGB(240, 240, 236)
local TEXT_DIM = Color3.fromRGB(150, 156, 170)
local TRACK = Color3.fromRGB(48, 51, 62)
local ACCENT = Color3.fromRGB(255, 196, 48) -- Palette.Pickup

local player = Players.LocalPlayer
ReplicatedFirst:RemoveDefaultLoadingScreen()

local function new(className: string, props: { [string]: any }, parent: Instance?): any
	local inst = Instance.new(className)
	for key, value in props do
		(inst :: any)[key] = value
	end
	inst.Parent = parent
	return inst
end

local gui = new("ScreenGui", {
	Name = "LoadingScreen",
	IgnoreGuiInset = true,
	ResetOnSpawn = false,
	DisplayOrder = 100,
}, nil)

local background = new("Frame", {
	BackgroundColor3 = Color3.new(1, 1, 1),
	BorderSizePixel = 0,
	Size = UDim2.fromScale(1, 1),
}, gui)
-- soft top-to-bottom shade; a gradient multiplies the frame color, hence the white frame
new("UIGradient", {
	Rotation = 90,
	Color = ColorSequence.new(Color3.fromRGB(30, 33, 42), BACKGROUND),
}, background)

local center = new("Frame", {
	BackgroundTransparency = 1,
	Size = UDim2.fromOffset(420, 220),
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.45),
}, background)

local title = new("TextLabel", {
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBlack,
	Text = TITLE,
	TextColor3 = TEXT,
	TextScaled = true,
	Size = UDim2.new(1, 0, 0, 56),
}, center)
new("UITextSizeConstraint", { MaxTextSize = 52 }, title)

local subtitle = new("TextLabel", {
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	Text = SUBTITLE,
	TextColor3 = TEXT_DIM,
	TextSize = 12,
	Size = UDim2.new(1, 0, 0, 18),
	Position = UDim2.fromOffset(0, 62),
}, center)

local track = new("Frame", {
	BackgroundColor3 = TRACK,
	BorderSizePixel = 0,
	Size = UDim2.new(0, 320, 0, 6),
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 118),
	ClipsDescendants = true,
}, center)
new("UICorner", { CornerRadius = UDim.new(0, 3) }, track)
local fill = new("Frame", {
	BackgroundColor3 = ACCENT,
	BorderSizePixel = 0,
	Size = UDim2.fromScale(0, 1),
}, track)
new("UICorner", { CornerRadius = UDim.new(0, 3) }, fill)

local status = new("TextLabel", {
	BackgroundTransparency = 1,
	Font = Enum.Font.RobotoMono,
	Text = "Loading the city…",
	TextColor3 = TEXT_DIM,
	TextSize = 13,
	Size = UDim2.new(1, 0, 0, 18),
	Position = UDim2.fromOffset(0, 134),
}, center)

local tip = new("TextLabel", {
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamMedium,
	Text = TIPS[math.random(#TIPS)],
	TextColor3 = TEXT,
	TextSize = 15,
	TextWrapped = true,
	Size = UDim2.new(1, 0, 0, 40),
	Position = UDim2.fromOffset(0, 176),
}, center)

gui.Parent = player:WaitForChild("PlayerGui")

-- rotate tips while loading
local done = false
task.spawn(function()
	local i = table.find(TIPS, tip.Text) or 1
	while not done do
		task.wait(4)
		if done then
			break
		end
		i = i % #TIPS + 1
		local fadeOut = TweenService:Create(tip, TweenInfo.new(0.25), { TextTransparency = 1 })
		fadeOut:Play()
		fadeOut.Completed:Wait()
		tip.Text = TIPS[i]
		TweenService:Create(tip, TweenInfo.new(0.25), { TextTransparency = 0 }):Play()
	end
end)

-- Progress: half for the game loading, half for the asset queue draining and the character
-- spawning. The bar only ever moves forward.
local started = os.clock()
local peakQueue = math.max(ContentProvider.RequestQueueSize, 1)
local shown = 0
while true do
	local elapsed = os.clock() - started
	local queue = ContentProvider.RequestQueueSize
	peakQueue = math.max(peakQueue, queue)
	local loaded = game:IsLoaded()
	local character = player.Character
	local spawned = character ~= nil and character:FindFirstChild("HumanoidRootPart") ~= nil
	local target = (if loaded then 0.5 else 0.25 * math.min(elapsed / 4, 1))
		+ 0.3 * (1 - queue / peakQueue)
		+ (if spawned then 0.2 else 0)
	shown = math.max(shown, math.min(target, 1))
	fill.Size = UDim2.fromScale(shown, 1)
	status.Text = if not loaded then "Loading the city…" elseif not spawned then "Finding you a room at the motel…" else "Almost there…"
	if (loaded and spawned and queue < 5 and elapsed >= MIN_SECONDS) or elapsed >= MAX_SECONDS then
		break
	end
	task.wait(0.1)
end

done = true
fill.Size = UDim2.fromScale(1, 1)
status.Text = "Ready"
task.wait(0.3)
local fade = TweenInfo.new(0.6)
TweenService:Create(background, fade, { BackgroundTransparency = 1 }):Play()
for _, label in { title, subtitle, status, tip } do
	TweenService:Create(label, fade, { TextTransparency = 1 }):Play()
end
TweenService:Create(track, fade, { BackgroundTransparency = 1 }):Play()
TweenService:Create(fill, fade, { BackgroundTransparency = 1 }):Play()
task.wait(0.7)
gui:Destroy()
