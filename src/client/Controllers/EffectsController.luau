--!strict
-- Cosmetic effects: shot tracers, muzzle flashes and impact sparks (no blood), plus flashing police
-- sirens. Everything here is local-only.

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

local EffectsController = {}

local effectsFolder: Folder

local function flash(position: Vector3, color: Color3, size: number, duration: number)
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Ball
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = Vector3.one * size
	p.Position = position
	p.Parent = effectsFolder
	TweenService:Create(p, TweenInfo.new(duration), { Transparency = 1, Size = Vector3.one * size * 1.8 }):Play()
	Debris:AddItem(p, duration)
end

local function onShot(origin: Vector3, hit: Vector3, hitCharacter: boolean)
	local length = (hit - origin).Magnitude
	if length > 0.5 then
		local tracer = Instance.new("Part")
		tracer.Anchored = true
		tracer.CanCollide = false
		tracer.CanQuery = false
		tracer.CanTouch = false
		tracer.CastShadow = false
		tracer.Material = Enum.Material.Neon
		tracer.Color = Color3.fromRGB(255, 226, 140)
		tracer.Size = Vector3.new(0.12, 0.12, length)
		tracer.CFrame = CFrame.lookAt((origin + hit) / 2, hit)
		tracer.Parent = effectsFolder
		TweenService:Create(tracer, TweenInfo.new(0.12), { Transparency = 1 }):Play()
		Debris:AddItem(tracer, 0.12)
	end
	flash(origin, Color3.fromRGB(255, 200, 80), 0.8, 0.06)
	-- a hit on a person is a bright white "pop", never blood
	flash(hit, if hitCharacter then Color3.fromRGB(255, 255, 255) else Color3.fromRGB(255, 180, 60), if hitCharacter then 1.6 else 0.7, 0.15)
end

local function updateSirens()
	local phase = math.floor(os.clock() * 4) % 2 == 0
	local vehicles = workspace:FindFirstChild("Vehicles")
	if not vehicles then
		return
	end
	for _, car in vehicles:GetChildren() do
		if car:GetAttribute("VehicleType") ~= "Police" then
			continue
		end
		local on = car:GetAttribute("Siren") == true
		for _, name in { "SirenRed", "SirenBlue" } do
			local siren = car:FindFirstChild(name) :: BasePart?
			if siren then
				local lit = on and ((name == "SirenRed") == phase)
				siren.Material = if lit then Enum.Material.Neon else Enum.Material.SmoothPlastic
				local light = siren:FindFirstChildWhichIsA("Light")
				if light then
					light.Enabled = lit
				end
			end
		end
	end
end

function EffectsController.init()
	effectsFolder = Instance.new("Folder")
	effectsFolder.Name = "LocalEffects"
	effectsFolder.Parent = workspace

	Remotes.event("ShotFired").OnClientEvent:Connect(onShot)

	local sirenTimer = 0
	RunService.Heartbeat:Connect(function(dt)
		sirenTimer += dt
		if sirenTimer >= 0.125 then
			sirenTimer = 0
			updateSirens()
		end
	end)
end

return EffectsController
