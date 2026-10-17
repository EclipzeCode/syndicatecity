--!strict
-- Minimal shooting, kept stylized for a Mild maturity rating: hitscan shots with tracer and spark
-- effects, no blood, and players who drop to 0 health are "knocked out" and respawn.
-- Every player gets a pistol; it only works on foot. Shots are validated and resolved on the server.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local HeatService = require(script.Parent.HeatService)

local WEAPON = Config.Weapons.Pistol
local TOOL_NAME = "Pistol"

type GunState = {
	ammo: number,
	lastShot: number,
	reloading: boolean,
}

local CombatService = {}

local states: { [Player]: GunState } = {}
local copHitListeners: { (car: Model, shooter: Player) -> () } = {}
local knockoutHandler: ((player: Player) -> boolean)? = nil

local shotFired = Remotes.event("ShotFired")
local notice = Remotes.event("Notice")

local function gunPart(tool: Tool, handle: BasePart, name: string, size: Vector3, offset: CFrame, color: Color3)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.Massless = true
	p.CFrame = handle.CFrame * offset
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = handle
	weld.Part1 = p
	weld.Parent = p
	p.Parent = tool
end

-- Chunky, slightly toy-like pistol built from parts (a Blender mesh replaces it later).
local function buildPistol(): Tool
	local tool = Instance.new("Tool")
	tool.Name = TOOL_NAME
	tool.ToolTip = "Pistol (on foot only)"
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	tool.Grip = CFrame.new(0, -0.45, 0.35)

	local body = Color3.fromRGB(58, 60, 70)
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.45, 0.55, 1.9)
	handle.Color = body
	handle.Material = Enum.Material.SmoothPlastic
	handle.CanCollide = false
	handle.CanTouch = false
	handle.CanQuery = false
	handle.Parent = tool

	gunPart(tool, handle, "Grip", Vector3.new(0.4, 1.1, 0.55), CFrame.new(0, -0.65, 0.55) * CFrame.Angles(math.rad(-15), 0, 0), body)
	gunPart(tool, handle, "Stripe", Vector3.new(0.47, 0.14, 1.6), CFrame.new(0, 0.12, -0.05), Color3.fromRGB(255, 176, 48))
	gunPart(tool, handle, "Barrel", Vector3.new(0.3, 0.3, 0.3), CFrame.new(0, 0.05, -1.05), Color3.fromRGB(30, 30, 34))

	local muzzle = Instance.new("Attachment")
	muzzle.Name = "Muzzle"
	muzzle.Position = Vector3.new(0, 0.05, -1.2)
	muzzle.Parent = handle

	tool:SetAttribute("Ammo", WEAPON.MagazineSize)
	tool:SetAttribute("MagazineSize", WEAPON.MagazineSize)
	return tool
end

local function getTool(player: Player): Tool?
	local character = player.Character
	local tool = character and character:FindFirstChild(TOOL_NAME)
	return if tool and tool:IsA("Tool") then tool else nil
end

local function setAmmo(player: Player, ammo: number)
	local state = states[player]
	state.ammo = ammo
	local tool = getTool(player) or (player:FindFirstChild("Backpack") and player.Backpack:FindFirstChild(TOOL_NAME))
	if tool then
		tool:SetAttribute("Ammo", ammo)
	end
end

local function reload(player: Player)
	local state = states[player]
	if not state or state.reloading or state.ammo == WEAPON.MagazineSize then
		return
	end
	state.reloading = true
	player:SetAttribute("Reloading", true)
	task.delay(WEAPON.ReloadSeconds, function()
		if states[player] == state then
			state.reloading = false
			player:SetAttribute("Reloading", false)
			setAmmo(player, WEAPON.MagazineSize)
		end
	end)
end

local function isNearPolice(position: Vector3): boolean
	local vehicles = workspace:FindFirstChild("Vehicles")
	if not vehicles then
		return false
	end
	for _, car in vehicles:GetChildren() do
		if car:GetAttribute("VehicleType") == "Police" and car:IsA("Model") and car.PrimaryPart then
			if (car.PrimaryPart.Position - position).Magnitude <= WEAPON.NearPoliceRadius then
				return true
			end
		end
	end
	return false
end

local function onFire(player: Player, target: unknown)
	if typeof(target) ~= "Vector3" or target ~= target then
		return
	end
	local state = states[player]
	local tool = getTool(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local handle = tool and tool:FindFirstChild("Handle") :: BasePart?
	if not state or not tool or not humanoid or not handle or not character then
		return
	end
	if humanoid.Health <= 0 or humanoid.SeatPart ~= nil or state.reloading then
		return
	end
	local now = os.clock()
	-- small tolerance for network jitter
	if now - state.lastShot < WEAPON.FireInterval * 0.85 then
		return
	end
	if state.ammo <= 0 then
		reload(player)
		return
	end
	state.lastShot = now
	setAmmo(player, state.ammo - 1)

	local muzzle = handle:FindFirstChild("Muzzle") :: Attachment?
	local origin = if muzzle then muzzle.WorldPosition else handle.Position
	local direction = (target :: Vector3) - origin
	if direction.Magnitude < 0.1 then
		return
	end
	direction = direction.Unit * WEAPON.Range

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	local result = workspace:Raycast(origin, direction, params)
	local hitPosition = if result then result.Position else origin + direction
	local hitCharacter = false

	if result then
		local model = result.Instance:FindFirstAncestorOfClass("Model")
		local victimHumanoid = model and model:FindFirstChildOfClass("Humanoid")
		if model and victimHumanoid and victimHumanoid.Health > 0 then
			victimHumanoid:TakeDamage(WEAPON.Damage)
			hitCharacter = true
		elseif model then
			-- hits on any part of a police car (seats and wheels belong to the car model)
			local car = if model:GetAttribute("VehicleType") then model else model:FindFirstAncestorOfClass("Model")
			if car and car:GetAttribute("VehicleType") == "Police" then
				HeatService.add(player, WEAPON.HeatForHittingCop)
				for _, listener in copHitListeners do
					task.spawn(listener, car, player)
				end
			end
		end
	end

	HeatService.add(player, if isNearPolice(origin) then WEAPON.HeatPerShotNearPolice else WEAPON.HeatPerShot)
	shotFired:FireAllClients(origin, hitPosition, hitCharacter)

	if state.ammo <= 0 then
		reload(player)
	end
end

-- Police shots at a wanted player on foot. Misses still show a tracer so it reads as a warning.
function CombatService.policeShoot(origin: Vector3, player: Player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid or humanoid.Health <= 0 then
		return
	end
	-- moving targets are harder to hit
	local speed = root.AssemblyLinearVelocity.Magnitude
	local accuracy = Config.Police.ShootAccuracy * (if speed > 10 then 0.6 else 1)
	local hit = math.random() < accuracy
	local aim = root.Position
	if not hit then
		aim += Vector3.new(math.random(-6, 6), math.random(-2, 4), math.random(-6, 6))
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local vehicles = workspace:FindFirstChild("Vehicles")
	params.FilterDescendantsInstances = if vehicles then { vehicles } else {}
	local direction = (aim - origin).Unit * (Config.Police.ShootRange + 20)
	local result = workspace:Raycast(origin, direction, params)
	local hitPosition = if result then result.Position else origin + direction
	local hitCharacter = false
	if hit and result and result.Instance:IsDescendantOf(character :: Model) then
		humanoid:TakeDamage(Config.Police.ShootDamage)
		hitCharacter = true
	end
	shotFired:FireAllClients(origin, hitPosition, hitCharacter)
end

function CombatService.onCopHit(listener: (car: Model, shooter: Player) -> ())
	table.insert(copHitListeners, listener)
end

-- PoliceService claims knockouts of wanted players (they become arrests); returns true if handled.
function CombatService.setKnockoutHandler(handler: (player: Player) -> boolean)
	knockoutHandler = handler
end

local function onCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	states[player] = { ammo = WEAPON.MagazineSize, lastShot = 0, reloading = false }
	player:SetAttribute("Reloading", false)
	local backpack = player:WaitForChild("Backpack")
	if not backpack:FindFirstChild(TOOL_NAME) then
		buildPistol().Parent = backpack
	end
	humanoid.Died:Connect(function()
		local handled = knockoutHandler ~= nil and knockoutHandler(player)
		if not handled then
			notice:FireClient(player, "ko", "Knocked out! You'll wake up at the motel.")
		end
	end)
end

function CombatService.init()
	Remotes.event("FireWeapon").OnServerEvent:Connect(onFire)
	Remotes.event("ReloadWeapon").OnServerEvent:Connect(reload)

	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(function(character)
			onCharacter(player, character)
		end)
		if player.Character then
			task.spawn(onCharacter, player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
	end)
end

return CombatService
