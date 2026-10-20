--!strict
-- Cartoon crash effects, local to each client: at the point of impact a quick white flash, a
-- ring that snaps outward, a burst of spinning stars, a puff of smoke and a comic word ("BAM!",
-- "CRASH!") that pops up and fades. Bigger knocks make bigger effects. Everything cleans itself
-- up in a couple of seconds.

local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")

local CrashEffects = {}

local WORDS: { [string]: { string } } = {
	car = { "BAM!", "CRASH!", "SMASH!", "WHAM!" },
	building = { "BONK!", "THUD!", "CRUNCH!", "POW!" },
	nature = { "BONK!", "THUNK!", "CRACK!", "WHACK!" },
}
local WORD_COLORS = {
	Color3.fromRGB(255, 214, 64),
	Color3.fromRGB(255, 120, 72),
	Color3.fromRGB(255, 255, 255),
	Color3.fromRGB(120, 220, 255),
}
local STAR_COLORS = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 244, 150)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 190, 60)),
})

local rng = Random.new()
local folder: Folder? = nil

local function effectsFolder(): Folder
	local existing = folder
	if existing and existing.Parent then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = "CrashEffects"
	created.Parent = workspace
	folder = created
	return created
end

local function anchor(position: Vector3): Part
	local p = Instance.new("Part")
	p.Name = "Crash"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = Vector3.one
	p.Position = position
	p.Parent = effectsFolder()
	return p
end

local function burst(parent: Instance, props: { [string]: any }, count: number)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Enabled = false
	for key, value in props do
		(emitter :: any)[key] = value
	end
	emitter.Parent = parent
	emitter:Emit(count)
end

-- A flat bright sphere that swells and vanishes in a blink.
local function flash(position: Vector3, size: number)
	local ball = Instance.new("Part")
	ball.Name = "Flash"
	ball.Shape = Enum.PartType.Ball
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	ball.CastShadow = false
	ball.Material = Enum.Material.Neon
	ball.Color = Color3.fromRGB(255, 250, 220)
	ball.Size = Vector3.one * size * 0.4
	ball.Position = position
	ball.Transparency = 0.1
	ball.Parent = effectsFolder()
	TweenService:Create(ball, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.one * size * 1.6,
		Transparency = 1,
	}):Play()
	Debris:AddItem(ball, 0.25)
end

-- The comic word, popping in with a little overshoot, then drifting up and fading.
local function word(parent: BasePart, kind: string, scale: number)
	local list = WORDS[kind] or WORDS.building
	local gui = Instance.new("BillboardGui")
	gui.Name = "CrashWord"
	gui.Size = UDim2.fromScale(10 * scale, 4 * scale)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 250
	gui.Adornee = parent
	gui.Parent = parent

	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromScale(0.2, 0.2)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.LuckiestGuy
	label.Text = list[rng:NextInteger(1, #list)]
	label.TextScaled = true
	label.TextColor3 = WORD_COLORS[rng:NextInteger(1, #WORD_COLORS)]
	label.Rotation = rng:NextNumber(-14, 14)
	label.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(30, 24, 40)
	stroke.Thickness = 3
	stroke.Parent = label

	TweenService:Create(label, TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Size = UDim2.fromScale(1, 1),
	}):Play()
	task.delay(0.45, function()
		local fade = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(label, fade, { TextTransparency = 1, Position = UDim2.fromScale(0.5, 0.2) }):Play()
		TweenService:Create(stroke, fade, { Transparency = 1 }):Play()
	end)
end

-- Plays the effects at `position`. `kind` is "car", "building" or "nature"; `strength` is
-- roughly 0.5 (a bump) to 1.3 (a big smash).
function CrashEffects.play(position: Vector3, kind: string, strength: number)
	local scale = math.clamp(strength, 0.5, 1.3)
	local holder = anchor(position)
	local attachment = Instance.new("Attachment")
	attachment.Parent = holder

	flash(position, 5 * scale)

	-- a ring snapping outward
	burst(attachment, {
		Texture = "rbxasset://textures/particles/explosion01_shockwave_main.dds",
		Color = ColorSequence.new(Color3.fromRGB(255, 255, 255)),
		LightEmission = 0.6,
		Lifetime = NumberRange.new(0.25),
		Speed = NumberRange.new(0),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 14 * scale) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) }),
		Orientation = Enum.ParticleOrientation.FacingCamera,
	}, 1)

	-- spinning cartoon stars flying out
	burst(attachment, {
		Texture = "rbxasset://textures/particles/sparkles_main.dds",
		Color = STAR_COLORS,
		LightEmission = 0.8,
		Lifetime = NumberRange.new(0.5, 0.9),
		Speed = NumberRange.new(14 * scale, 26 * scale),
		SpreadAngle = Vector2.new(180, 180),
		Acceleration = Vector3.new(0, -30, 0),
		Drag = 2,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-360, 360),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.6 * scale), NumberSequenceKeypoint.new(1, 0.2) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.7, 0), NumberSequenceKeypoint.new(1, 1) }),
	}, math.round(10 * scale))

	-- a puff of soft grey smoke that rolls up and thins out
	burst(attachment, {
		Texture = "rbxasset://textures/particles/smoke_main.dds",
		Color = ColorSequence.new(Color3.fromRGB(235, 235, 240), Color3.fromRGB(150, 150, 160)),
		LightInfluence = 0.5,
		Lifetime = NumberRange.new(0.9, 1.6),
		Speed = NumberRange.new(4, 9),
		SpreadAngle = Vector2.new(70, 70),
		EmissionDirection = Enum.NormalId.Top,
		Acceleration = Vector3.new(0, 4, 0),
		Drag = 2.5,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-60, 60),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2 * scale), NumberSequenceKeypoint.new(1, 7 * scale) }),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.15),
			NumberSequenceKeypoint.new(0.6, 0.5),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}, math.round(8 * scale))

	-- chips of whatever was hit: bark and leaves off a tree, sparks off a car or wall
	if kind == "nature" then
		burst(attachment, {
			Texture = "rbxasset://textures/particles/SquareParticle.png",
			Color = ColorSequence.new(Color3.fromRGB(96, 170, 70), Color3.fromRGB(120, 84, 52)),
			Lifetime = NumberRange.new(0.6, 1.1),
			Speed = NumberRange.new(10, 20),
			SpreadAngle = Vector2.new(120, 120),
			EmissionDirection = Enum.NormalId.Top,
			Acceleration = Vector3.new(0, -40, 0),
			RotSpeed = NumberRange.new(-300, 300),
			Size = NumberSequence.new(0.5),
		}, 12)
	else
		burst(attachment, {
			Texture = "rbxasset://textures/particles/fire_sparks_main.dds",
			Color = ColorSequence.new(Color3.fromRGB(255, 220, 120)),
			LightEmission = 1,
			Lifetime = NumberRange.new(0.25, 0.5),
			Speed = NumberRange.new(20, 34),
			SpreadAngle = Vector2.new(90, 90),
			Acceleration = Vector3.new(0, -50, 0),
			Size = NumberSequence.new(0.6, 0.1),
		}, math.round(12 * scale))
	end

	word(holder, kind, scale)
	Debris:AddItem(holder, 2.2)
end

return CrashEffects
