--!strict
-- Surf near the coast, local to each client: a looped wave sound that sits on the nearest bit of
-- shoreline to the listener, so it gets louder walking or driving down to the beach and fades
-- out inland. The shoreline is the ShoreFoam MapBuilder lays along the waterline
-- (Workspace.Map.Beach); without it, the nearest terrain water around the listener stands in.

local RunService = game:GetService("RunService")

local Sounds = require(game:GetService("ReplicatedStorage").Shared.Sounds)

local CoastSoundController = {}

local CHECK_INTERVAL = 0.4
local FOAM_REFRESH = 5
-- beyond this from any shore, no surf at all
local AUDIBLE = 320
-- the emitter glides to a new spot instead of jumping, studs/s
local GLIDE_SPEED = 60

local emitter: Part
local surf: Sound
local foam: { Vector3 } = {}
local foamRefreshedAt = -math.huge
local target: Vector3? = nil

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Include
rayParams.FilterDescendantsInstances = { workspace.Terrain }
rayParams.IgnoreWater = false

local function refreshFoam()
	table.clear(foam)
	local map = workspace:FindFirstChild("Map")
	local beach = map and map:FindFirstChild("Beach")
	if not beach then
		return
	end
	for _, d in beach:GetDescendants() do
		if d:IsA("BasePart") and string.sub(d.Name, 1, 9) == "ShoreFoam" then
			table.insert(foam, d.Position)
		elseif d:IsA("Model") and string.sub(d.Name, 1, 9) == "ShoreFoam" then
			table.insert(foam, d:GetPivot().Position)
		end
	end
end

local function listener(): Vector3
	local character = game:GetService("Players").LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	local camera = workspace.CurrentCamera
	return if camera then camera.Focus.Position else Vector3.zero
end

-- The nearest terrain water in a ring around `around`, if any is in earshot.
local function nearestWater(around: Vector3): Vector3?
	local best, bestDistance = nil, math.huge
	for _, radius in { 30, 70, 120, 180, 250 } do
		for i = 0, 15 do
			local angle = i / 16 * math.pi * 2
			local point = around + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
			local result = workspace:Raycast(point + Vector3.new(0, 150, 0), Vector3.new(0, -400, 0), rayParams)
			if result and result.Material == Enum.Material.Water then
				local distance = (result.Position - around).Magnitude
				if distance < bestDistance then
					best, bestDistance = result.Position, distance
				end
			end
		end
		-- the nearest ring with water is close enough
		if best then
			return best
		end
	end
	return nil
end

local function findShore(): Vector3?
	local now = os.clock()
	if now - foamRefreshedAt > FOAM_REFRESH then
		foamRefreshedAt = now
		refreshFoam()
	end
	local here = listener()
	if #foam > 0 then
		local best, bestDistance = nil, math.huge
		for _, position in foam do
			local distance = (position - here).Magnitude
			if distance < bestDistance then
				best, bestDistance = position, distance
			end
		end
		return if bestDistance < AUDIBLE then best else nil
	end
	return nearestWater(here)
end

function CoastSoundController.init()
	emitter = Instance.new("Part")
	emitter.Name = "CoastSound"
	emitter.Anchored = true
	emitter.CanCollide = false
	emitter.CanQuery = false
	emitter.CanTouch = false
	emitter.Transparency = 1
	emitter.Size = Vector3.one
	emitter.Parent = workspace
	surf = Sounds.make("Waves", emitter)

	local timer = CHECK_INTERVAL
	RunService.Heartbeat:Connect(function(dt)
		timer += dt
		if timer >= CHECK_INTERVAL then
			timer = 0
			target = findShore()
			if target and not surf.Playing then
				-- a fresh spot for the new beach, not a glide across the island
				emitter.Position = target
				surf:Play()
			elseif not target and surf.Playing then
				surf:Stop()
			end
		end
		local goal = target
		if goal then
			local offset = goal - emitter.Position
			local step = GLIDE_SPEED * dt
			emitter.Position = if offset.Magnitude <= step then goal else emitter.Position + offset.Unit * step
		end
	end)
end

-- Studio test hook: where the surf is and whether it's playing.
function CoastSoundController.debugState(): (Vector3, boolean, number)
	return emitter.Position, surf.Playing, (emitter.Position - listener()).Magnitude
end

return CoastSoundController
