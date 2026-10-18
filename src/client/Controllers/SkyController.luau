--!strict
-- A cartoon sky, built locally on each client: a round sun with spinning rays and a cratered
-- moon that follow the real sun and moon directions (the default ones are hidden; see
-- MapBuilder.applyLighting), and drawn flat-bottomed clouds that drift across the sky and wrap
-- around the camera. All three are flat billboards, like drawings. Everything is tinted by the time of day. Nothing here replicates.

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local SkyController = {}

-- how far away the sun and moon are drawn, and their size there. Close enough that the
-- atmosphere's haze doesn't wash them out, beyond the clouds so clouds pass in front.
local SKY_DISTANCE = 1900
local SUN_SIZE = 520
local MOON_SIZE = 380

local CLOUD_COUNT = 24
local CLOUD_HEIGHT = NumberRange.new(420, 600)
-- clouds live in a square this far each way from the camera and wrap at its edges
local CLOUD_RADIUS = 1700
local WIND = Vector3.new(7, 0, 2.5)

local SUN_FILL = Color3.fromRGB(255, 196, 48)
local SUN_EDGE = Color3.fromRGB(255, 128, 32)
local MOON_FILL = Color3.fromRGB(240, 236, 214)
local MOON_CRATER = Color3.fromRGB(206, 200, 176)

-- cloud colors through the day: night, dawn/dusk, day
local CLOUD_NIGHT = Color3.fromRGB(70, 78, 104)
local CLOUD_DUSK = Color3.fromRGB(255, 196, 170)
local CLOUD_DAY = Color3.fromRGB(255, 255, 255)
-- the darker underside each cloud is drawn over
local CLOUD_SHADE = Color3.fromRGB(150, 170, 210)

type Cloud = { part: Part, tops: { Frame }, shades: { Frame }, offset: Vector3 }

local folder: Folder
local sunPart: Part
local moonPart: Part
local sunRays: Frame
local clouds: { Cloud } = {}
local rng = Random.new()

local function circle(parent: Instance, size: UDim2, position: UDim2, color: Color3, transparency: number?): Frame
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Size = size
	f.Position = position
	f.BackgroundColor3 = color
	f.BackgroundTransparency = transparency or 0
	f.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = f
	f.Parent = parent
	return f
end

-- An invisible anchor part far out in the sky with a billboard drawn on it.
local function skyBody(name: string, size: number): (Part, BillboardGui)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = Vector3.one
	p.Parent = folder
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromScale(size, size)
	gui.LightInfluence = 0
	gui.Brightness = 2.5
	gui.Parent = p
	return p, gui
end

local function buildSun()
	local gui
	sunPart, gui = skyBody("Sun", SUN_SIZE)
	local center = UDim2.fromScale(0.5, 0.5)
	-- soft halo, then rays, then the disc
	circle(gui, UDim2.fromScale(1, 1), center, SUN_FILL, 0.82)
	sunRays = Instance.new("Frame")
	sunRays.BackgroundTransparency = 1
	sunRays.Size = UDim2.fromScale(1, 1)
	sunRays.Parent = gui
	for i = 0, 7 do
		local spoke = Instance.new("Frame")
		spoke.BackgroundTransparency = 1
		spoke.AnchorPoint = Vector2.new(0.5, 0.5)
		spoke.Position = center
		spoke.Size = UDim2.fromScale(0.84, 0.84)
		spoke.Rotation = i * 45
		spoke.Parent = sunRays
		local ray = Instance.new("Frame")
		ray.AnchorPoint = Vector2.new(0.5, 0)
		ray.Position = UDim2.fromScale(0.5, 0)
		ray.Size = UDim2.fromScale(0.09, 0.16)
		ray.BackgroundColor3 = SUN_FILL
		ray.BorderSizePixel = 0
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = ray
		ray.Parent = spoke
	end
	local disc = circle(gui, UDim2.fromScale(0.5, 0.5), center, SUN_FILL)
	local stroke = Instance.new("UIStroke")
	stroke.Color = SUN_EDGE
	stroke.Thickness = 5
	stroke.Parent = disc
	-- a highlight so it reads as a cartoon ball
	circle(disc, UDim2.fromScale(0.3, 0.3), UDim2.fromScale(0.34, 0.32), Color3.new(1, 1, 1), 0.55)
end

local function buildMoon()
	local gui
	moonPart, gui = skyBody("Moon", MOON_SIZE)
	local center = UDim2.fromScale(0.5, 0.5)
	circle(gui, UDim2.fromScale(1, 1), center, MOON_FILL, 0.88)
	local disc = circle(gui, UDim2.fromScale(0.56, 0.56), center, MOON_FILL)
	local stroke = Instance.new("UIStroke")
	stroke.Color = MOON_CRATER
	stroke.Thickness = 4
	stroke.Parent = disc
	circle(disc, UDim2.fromScale(0.26, 0.26), UDim2.fromScale(0.36, 0.38), MOON_CRATER)
	circle(disc, UDim2.fromScale(0.16, 0.16), UDim2.fromScale(0.66, 0.62), MOON_CRATER)
	circle(disc, UDim2.fromScale(0.11, 0.11), UDim2.fromScale(0.44, 0.74), MOON_CRATER)
end

local function cloudOffset(): Vector3
	return Vector3.new(rng:NextNumber(-CLOUD_RADIUS, CLOUD_RADIUS), rng:NextNumber(CLOUD_HEIGHT.Min, CLOUD_HEIGHT.Max), rng:NextNumber(-CLOUD_RADIUS, CLOUD_RADIUS))
end

-- A drawn cloud: a billboard (always facing you, like the sun and moon) of overlapping round
-- puffs on a flat-bottomed base. The same shapes sit behind in a darker tint, nudged down, so
-- the underside reads as shading without outlines between puffs.
local function buildCloud(): Cloud
	local width = rng:NextNumber(240, 420)
	local height = width * 0.5
	local p, gui = skyBody("Cloud", 1)
	gui.Size = UDim2.fromScale(width, height)
	gui.Brightness = 1.6

	local puffs = {}
	local count = rng:NextInteger(3, 5)
	for i = 1, count do
		local t = (i - 0.5) / count
		-- biggest in the middle
		local size = (0.5 - math.abs(t - 0.5) * 0.55) * rng:NextNumber(0.85, 1.1)
		table.insert(puffs, { x = 0.12 + t * 0.76, y = 0.72 - size * 0.42, size = size })
	end

	local tops, shades = {}, {}
	for layer = 1, 2 do
		local shade = layer == 1
		local holder = Instance.new("Frame")
		holder.BackgroundTransparency = 1
		holder.Size = UDim2.fromScale(1, 1)
		holder.Position = if shade then UDim2.fromScale(0, 0.06) else UDim2.new()
		holder.Parent = gui
		local list = if shade then shades else tops
		-- the flat base: a wide pill
		local base = Instance.new("Frame")
		base.AnchorPoint = Vector2.new(0.5, 1)
		base.Position = UDim2.fromScale(0.5, 0.86)
		base.Size = UDim2.fromScale(0.94, 0.3)
		base.BorderSizePixel = 0
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = base
		base.Parent = holder
		table.insert(list, base)
		for _, puff in puffs do
			-- puffs are circles: their height is set from their width so they stay round
			local f = circle(holder, UDim2.fromScale(puff.size * 0.5, puff.size), UDim2.fromScale(puff.x, puff.y), Color3.new(1, 1, 1))
			table.insert(list, f)
		end
	end
	return { part = p, tops = tops, shades = shades, offset = cloudOffset() }
end

-- 0 at night, 1 in full day, with a dawn/dusk band where the sun is near the horizon.
local function daylight(): (number, number)
	local sunY = Lighting:GetSunDirection().Y
	local day = math.clamp((sunY + 0.1) / 0.35, 0, 1)
	local dusk = math.clamp(1 - math.abs(sunY - 0.05) / 0.2, 0, 1)
	return day, dusk
end

local tintTimer = math.huge

local function update(dt: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local eye = camera.CFrame.Position

	local sunDir = Lighting:GetSunDirection()
	local moonDir = Lighting:GetMoonDirection()
	sunPart.CFrame = CFrame.new(eye + sunDir * SKY_DISTANCE)
	moonPart.CFrame = CFrame.new(eye + moonDir * SKY_DISTANCE)
	;(sunPart:FindFirstChildOfClass("BillboardGui") :: BillboardGui).Enabled = sunDir.Y > -0.15
	;(moonPart:FindFirstChildOfClass("BillboardGui") :: BillboardGui).Enabled = moonDir.Y > -0.15
	sunRays.Rotation = (sunRays.Rotation + dt * 4) % 360

	-- clouds drift with the wind and wrap around the camera so the sky never runs out
	for _, cloud in clouds do
		cloud.offset += WIND * dt
		local rel = Vector3.new(cloud.offset.X - eye.X, 0, cloud.offset.Z - eye.Z)
		local x, z = cloud.offset.X, cloud.offset.Z
		if rel.X > CLOUD_RADIUS then
			x -= CLOUD_RADIUS * 2
		elseif rel.X < -CLOUD_RADIUS then
			x += CLOUD_RADIUS * 2
		end
		if rel.Z > CLOUD_RADIUS then
			z -= CLOUD_RADIUS * 2
		elseif rel.Z < -CLOUD_RADIUS then
			z += CLOUD_RADIUS * 2
		end
		cloud.offset = Vector3.new(x, cloud.offset.Y, z)
		cloud.part.CFrame = CFrame.new(cloud.offset)
	end

	tintTimer += dt
	if tintTimer > 1 then
		tintTimer = 0
		local day, dusk = daylight()
		local color = CLOUD_NIGHT:Lerp(CLOUD_DAY, day):Lerp(CLOUD_DUSK, dusk * 0.6)
		local shade = color:Lerp(CLOUD_SHADE, 0.35)
		for _, cloud in clouds do
			for _, f in cloud.tops do
				f.BackgroundColor3 = color
			end
			for _, f in cloud.shades do
				f.BackgroundColor3 = shade
			end
		end
	end
end

function SkyController.init()
	folder = Instance.new("Folder")
	folder.Name = "Sky"
	-- under the camera: local to this client, and out of the way of the map
	folder.Parent = workspace.CurrentCamera
	buildSun()
	buildMoon()
	for _ = 1, CLOUD_COUNT do
		local cloud = buildCloud()
		cloud.part.CFrame = CFrame.new(cloud.offset)
		table.insert(clouds, cloud)
	end
	-- the camera can be replaced; keep the sky with the current one
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		if workspace.CurrentCamera then
			folder.Parent = workspace.CurrentCamera
		end
	end)
	RunService.RenderStepped:Connect(update)
end

return SkyController
