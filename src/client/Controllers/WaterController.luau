--!strict
-- Cartoon wave crests, drawn locally on each client: white rounded strokes lying on the water
-- near the camera that fade in, drift with the wind and fade out, over the flat turquoise
-- terrain water (MapBuilder sets it up). Nothing here replicates.

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local WaterController = {}

-- wave crests: how many at once, how far from the camera, and how long each lasts
local WAVE_COUNT = 60
local WAVE_RANGE = NumberRange.new(25, 280)
local WAVE_LIFE = NumberRange.new(2.6, 4.2)
local WIND = Vector3.new(1, 0, 0.35).Unit
local DRIFT_SPEED = 4

local CREST_DAY = Color3.fromRGB(255, 255, 255)
local CREST_NIGHT = Color3.fromRGB(150, 172, 214)
local TROUGH = Color3.fromRGB(46, 150, 200)

type Wave = {
	part: Part,
	group: CanvasGroup,
	crest: Frame,
	born: number,
	life: number,
	position: Vector3,
	yaw: number,
	alive: boolean,
}

local waves: { Wave } = {}
local folder: Folder
local rng = Random.new()
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Include
rayParams.FilterDescendantsInstances = { workspace.Terrain }
rayParams.IgnoreWater = false

local function pill(parent: Instance, size: UDim2, position: UDim2, color: Color3): Frame
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Size = size
	f.Position = position
	f.BackgroundColor3 = color
	f.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = f
	f.Parent = parent
	return f
end

-- A wave crest: an invisible flat card with a drawing on its top face.
local function newWave(): Wave
	local p = Instance.new("Part")
	p.Name = "Wave"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = Vector3.new(18, 0.05, 4)
	p.Parent = folder
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Top
	gui.LightInfluence = 0.3
	gui.CanvasSize = Vector2.new(360, 80)
	gui.Parent = p
	local group = Instance.new("CanvasGroup")
	group.BackgroundTransparency = 1
	group.Size = UDim2.fromScale(1, 1)
	group.GroupTransparency = 1
	group.Parent = gui
	-- a darker trough behind the crest gives it a little depth
	pill(group, UDim2.fromScale(0.9, 0.5), UDim2.fromScale(0.5, 0.62), TROUGH)
	local crest = pill(group, UDim2.fromScale(0.82, 0.38), UDim2.fromScale(0.5, 0.42), CREST_DAY)
	return { part = p, group = group, crest = crest, born = 0, life = 1, position = Vector3.zero, yaw = 0, alive = false }
end

-- Puts a wave on open water somewhere around the camera, if it finds some.
local function spawnWave(wave: Wave, eye: Vector3, now: number)
	local angle = rng:NextNumber() * math.pi * 2
	local distance = rng:NextNumber(WAVE_RANGE.Min, WAVE_RANGE.Max)
	local x, z = eye.X + math.cos(angle) * distance, eye.Z + math.sin(angle) * distance
	local hit = workspace:Raycast(Vector3.new(x, 60, z), Vector3.new(0, -120, 0), rayParams)
	if not hit or hit.Material ~= Enum.Material.Water then
		wave.alive = false
		return
	end
	wave.alive = true
	wave.born = now
	wave.life = rng:NextNumber(WAVE_LIFE.Min, WAVE_LIFE.Max)
	wave.position = Vector3.new(x, hit.Position.Y, z)
	-- crests run across the wind, with a little wobble
	wave.yaw = math.atan2(WIND.X, WIND.Z) + rng:NextNumber(-0.35, 0.35)
	wave.part.Size = Vector3.new(rng:NextNumber(12, 24), 0.05, rng:NextNumber(3, 5))
end

local function update(_dt: number)
	local now = os.clock()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local eye = camera.CFrame.Position
	local day = math.clamp((Lighting:GetSunDirection().Y + 0.1) / 0.35, 0, 1)
	local crestColor = CREST_NIGHT:Lerp(CREST_DAY, day)
	-- only a few new waves per frame keeps the raycasts cheap
	local spawned = 0
	for _, wave in waves do
		local age = now - wave.born
		if not wave.alive or age > wave.life then
			if spawned < 3 then
				spawned += 1
				spawnWave(wave, eye, now)
			end
			if not wave.alive then
				wave.group.GroupTransparency = 1
				continue
			end
			age = 0
		end
		local t = age / wave.life
		-- fade in, hold, fade out; stretch a little as it rolls
		local fade = math.min(t / 0.25, 1, (1 - t) / 0.3)
		wave.group.GroupTransparency = 1 - math.clamp(fade, 0, 1) * 0.9
		wave.crest.BackgroundColor3 = crestColor
		local drift = WIND * DRIFT_SPEED * age
		local position = wave.position + drift + Vector3.new(0, 0.12, 0)
		wave.part.CFrame = CFrame.new(position) * CFrame.Angles(0, wave.yaw, 0)
	end
end

function WaterController.init()
	folder = Instance.new("Folder")
	folder.Name = "Waves"
	folder.Parent = workspace.CurrentCamera
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		if workspace.CurrentCamera then
			folder.Parent = workspace.CurrentCamera
		end
	end)
	for _ = 1, WAVE_COUNT do
		table.insert(waves, newWave())
	end
	RunService.RenderStepped:Connect(update)
end

return WaterController
