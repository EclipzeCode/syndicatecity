--!strict
-- Builds car models: a collision chassis and cabin, a driver VehicleSeat and a passenger Seat,
-- plus the visuals. Visuals come from the Blender mesh template in ServerStorage.Assets.Vehicles
-- (imported by Tools.MeshImporter) when there is one; otherwise graybox parts stand in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Palette = require(ReplicatedStorage.Shared.Palette)

local CarFactory = {}

local TIRE = Color3.fromRGB(34, 34, 38)
local TRIM = Color3.fromRGB(70, 72, 80)

-- graybox parts that only exist for looks; a mesh template replaces all of them
local GRAYBOX_VISUALS = {
	Windows = true,
	Roof = true,
	Bumper = true,
	Headlight = true,
	Taillight = true,
	Wheel = true,
	Hubcap = true,
	DoorStripe = true,
	LightBarBase = true,
	SirenRed = true,
	SirenBlue = true,
}

local function addHeadlightBeam(part: BasePart)
	local light = Instance.new("SpotLight")
	light.Face = Enum.NormalId.Front
	light.Range = 50
	light.Angle = 60
	light.Brightness = 2
	light.Color = Color3.fromRGB(255, 236, 200)
	light.Parent = part
end

local function addSirenLight(part: BasePart)
	local light = Instance.new("PointLight")
	light.Color = part.Color
	light.Range = 18
	light.Brightness = 3
	light.Enabled = false
	light.Parent = part
end

local function meshTemplate(vehicleType: string): Model?
	local assets = ServerStorage:FindFirstChild("Assets")
	local vehicles = assets and assets:FindFirstChild("Vehicles")
	return if vehicles then vehicles:FindFirstChild(vehicleType) :: Model? else nil
end

-- Swaps the graybox visuals for the mesh template. Template parts are laid out around the
-- chassis centre, so each is placed relative to the chassis and welded to it.
local function applyMeshes(model: Model, chassis: BasePart, template: Model, color: Color3)
	for _, child in model:GetChildren() do
		if GRAYBOX_VISUALS[child.Name] then
			child:Destroy()
		end
	end
	chassis.Transparency = 1
	local cabin = model:FindFirstChild("Cabin") :: BasePart?
	if cabin then
		cabin.Transparency = 1
	end
	for _, source in template:GetChildren() do
		if not source:IsA("BasePart") then
			continue
		end
		local p = source:Clone()
		p.Anchored = false
		p.Massless = true
		p.CanCollide = false
		p.CanTouch = false
		p.CanQuery = false
		p.CFrame = chassis.CFrame * source.CFrame
		if p.Name == "Body" then
			p.Color = color
		end
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = chassis
		weld.Part1 = p
		weld.Parent = p
		p.Parent = model
		if p.Name == "HeadlightR" then
			addHeadlightBeam(p)
		elseif p.Name == "SirenRed" or p.Name == "SirenBlue" then
			addSirenLight(p)
		end
	end
end

local function weldedPart(model: Model, chassis: BasePart, props: { [string]: any }): Part
	local p = Instance.new("Part")
	if props.Shape then
		p.Shape = props.Shape
	end
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Massless = true
	p.CanCollide = false
	p.CanTouch = false
	for key, value in props do
		(p :: any)[key] = value
	end
	local offset = props.CFrame or CFrame.new()
	p.CFrame = chassis.CFrame * offset
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = chassis
	weld.Part1 = p
	weld.Parent = p
	p.Parent = model
	return p
end

function CarFactory.build(vehicleType: string, color: Color3, cframe: CFrame): Model
	local tuning = Config.Vehicles.Types[vehicleType]
	assert(tuning, `unknown vehicle type {vehicleType}`)
	local size: Vector3 = tuning.Size
	local isVan = vehicleType == "Van"
	local isPolice = vehicleType == "Police"

	local model = Instance.new("Model")
	model.Name = vehicleType
	model:SetAttribute("VehicleType", vehicleType)

	local chassis = Instance.new("Part")
	chassis.Name = "Chassis"
	chassis.Size = size
	chassis.CFrame = cframe
	chassis.Color = color
	chassis.Material = Enum.Material.SmoothPlastic
	chassis.TopSurface = Enum.SurfaceType.Smooth
	chassis.BottomSurface = Enum.SurfaceType.Smooth
	chassis.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.2, 0, 1, 1)
	chassis.CollisionGroup = "Vehicles"
	chassis.Parent = model
	model.PrimaryPart = chassis

	local half = size / 2
	local cabinLength = if isVan then size.Z * 0.78 else size.Z * 0.5
	local cabinOffsetZ = if isVan then size.Z * 0.1 else size.Z * 0.04
	local cabinHeight: number = tuning.CabinHeight
	local cabin = weldedPart(model, chassis, {
		Name = "Cabin",
		Size = Vector3.new(size.X - 0.5, cabinHeight, cabinLength),
		CFrame = CFrame.new(0, half.Y + cabinHeight / 2, cabinOffsetZ),
		Color = color,
		CanCollide = true,
		CollisionGroup = "Vehicles",
	})
	weldedPart(model, chassis, {
		Name = "Windows",
		Size = Vector3.new(size.X - 0.3, cabinHeight * 0.55, if isVan then 4 else cabinLength + 0.2),
		CFrame = CFrame.new(
			0,
			half.Y + cabinHeight * 0.55,
			if isVan then cabinOffsetZ - cabinLength / 2 + 1.9 else cabinOffsetZ
		),
		Color = Palette.Glass,
		Reflectance = 0.2,
	})
	weldedPart(model, chassis, {
		Name = "Roof",
		Size = Vector3.new(size.X - 0.2, 0.4, cabinLength + 0.2),
		CFrame = CFrame.new(0, half.Y + cabinHeight + 0.1, cabinOffsetZ),
		Color = color:Lerp(Color3.new(0, 0, 0), 0.15),
	})

	for _, z in { -half.Z - 0.3, half.Z + 0.3 } do
		weldedPart(model, chassis, {
			Name = "Bumper",
			Size = Vector3.new(size.X + 0.2, 0.9, 0.8),
			CFrame = CFrame.new(0, -half.Y + 0.6, z),
			Color = TRIM,
		})
	end
	for _, x in { -1, 1 } do
		local head = weldedPart(model, chassis, {
			Name = "Headlight",
			Size = Vector3.new(1.6, 0.7, 0.3),
			CFrame = CFrame.new(x * (half.X - 1.2), half.Y - 0.6, -half.Z - 0.1),
			Color = Color3.fromRGB(255, 244, 214),
			Material = Enum.Material.Neon,
		})
		if x == 1 then
			addHeadlightBeam(head)
		end
		weldedPart(model, chassis, {
			Name = "Taillight",
			Size = Vector3.new(1.6, 0.7, 0.3),
			CFrame = CFrame.new(x * (half.X - 1.2), half.Y - 0.6, half.Z + 0.1),
			Color = Color3.fromRGB(220, 40, 40),
			Material = Enum.Material.Neon,
		})
	end

	-- wheels (visual only; the raycast suspension holds the car up)
	local radius: number = tuning.WheelRadius
	local wheelY = -half.Y - tuning.RideHeight + radius
	for _, x in { -1, 1 } do
		for _, z in { -1, 1 } do
			local wheelCf = CFrame.new(x * (half.X - 0.5), wheelY, z * (half.Z - 2.6))
			weldedPart(model, chassis, {
				Name = "Wheel",
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(1.5, radius * 2, radius * 2),
				CFrame = wheelCf,
				Color = TIRE,
			})
			weldedPart(model, chassis, {
				Name = "Hubcap",
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(1.6, radius, radius),
				CFrame = wheelCf,
				Color = Color3.fromRGB(196, 198, 204),
			})
		end
	end

	-- cargo sits on the rear deck (sedan) or behind the back window (van) so cops can spot it
	weldedPart(model, chassis, {
		Name = "CargoCrate",
		Size = Vector3.new(3.4, 2.2, 3),
		CFrame = if isVan
			then CFrame.new(0, half.Y + 1.1, half.Z - 1.5)
			else CFrame.new(0, half.Y + 1.1, half.Z - 2),
		Color = Palette.Wood,
		Transparency = 1,
	})

	if isPolice then
		weldedPart(model, chassis, {
			Name = "DoorStripe",
			Size = Vector3.new(size.X + 0.1, 1, size.Z * 0.6),
			CFrame = CFrame.new(0, 0.1, 0),
			Color = Palette.PoliceNavy,
		})
		weldedPart(model, chassis, {
			Name = "LightBarBase",
			Size = Vector3.new(4.6, 0.4, 1.2),
			CFrame = CFrame.new(0, half.Y + cabinHeight + 0.5, cabinOffsetZ),
			Color = TRIM,
		})
		for _, x in { -1, 1 } do
			local siren = weldedPart(model, chassis, {
				Name = if x < 0 then "SirenRed" else "SirenBlue",
				Size = Vector3.new(2, 0.6, 1),
				CFrame = CFrame.new(x * 1.1, half.Y + cabinHeight + 0.95, cabinOffsetZ),
				Color = if x < 0 then Palette.SirenRed else Palette.SirenBlue,
				Material = Enum.Material.SmoothPlastic,
			})
			addSirenLight(siren)
		end
	end

	-- seats sit inside the chassis top so the character's upper body shows through the cabin
	local seat = Instance.new("VehicleSeat")
	seat.Name = "DriverSeat"
	seat.Size = Vector3.new(2, 0.4, 2)
	seat.CFrame = chassis.CFrame * CFrame.new(-1.4, half.Y - 0.6, cabinOffsetZ - 0.5)
	seat.Transparency = 1
	seat.CanCollide = false
	seat.CanTouch = false
	seat.Massless = true
	seat.HeadsUpDisplay = false
	seat.MaxSpeed = 0
	seat.Torque = 0
	local seatWeld = Instance.new("WeldConstraint")
	seatWeld.Part0 = chassis
	seatWeld.Part1 = seat
	seatWeld.Parent = seat
	seat.Parent = model

	if not isPolice then
		local passenger = Instance.new("Seat")
		passenger.Name = "PassengerSeat"
		passenger.Size = Vector3.new(2, 0.4, 2)
		passenger.CFrame = chassis.CFrame * CFrame.new(1.4, half.Y - 0.6, cabinOffsetZ - 0.5)
		passenger.Transparency = 1
		passenger.CanCollide = false
		passenger.CanTouch = false
		passenger.Massless = true
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = chassis
		weld.Part1 = passenger
		weld.Parent = passenger
		passenger.Parent = model
	end

	local template = meshTemplate(vehicleType)
	if template then
		applyMeshes(model, chassis, template, color)
	end

	return model
end

return CarFactory
