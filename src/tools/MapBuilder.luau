--!strict
-- Edit-mode graybox builder for the first district. Run from Studio's command bar:
--   require(game.ServerStorage.Tools.MapBuilder).build()
-- Deletes and rebuilds Workspace.Map (ground, roads + road graph, downtown, industrial, docks,
-- woods, highway, job points, spawns) and applies the lighting baseline. Save the place afterwards.
-- The layout is deterministic (fixed seed), so rebuilding gives the same map.

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Palette = require(ReplicatedStorage.Shared.Palette)

local MapBuilder = {}

local GROUND_Y = 0 -- top of the grass
local ROAD_TOP = 0.4
local SIDEWALK_TOP = 1.2

local STREET_WIDTH = 36
local HIGHWAY_WIDTH = 56
local DIRT_WIDTH = 28

local rng = Random.new(1017)

type Props = { [string]: any }

local function part(parent: Instance, props: Props): Part
	local p = Instance.new("Part")
	-- shape first, so a later Size isn't overridden by the shape change
	if props.Shape then
		p.Shape = props.Shape
	end
	p.Anchored = true
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CastShadow = true
	for key, value in props do
		(p :: any)[key] = value
	end
	p.Parent = parent
	return p
end

local function folder(parent: Instance, name: string): Folder
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

local function pick<T>(list: { T }): T
	return list[rng:NextInteger(1, #list)]
end

-- Flushes a built section into the map and yields so Studio stays responsive.
local function flush(section: Instance, map: Instance)
	section.Parent = map
	task.wait()
end

---------------------------------------------------------------------------------------------------
-- Road graph
---------------------------------------------------------------------------------------------------

type Node = { id: string, position: Vector3, links: { string } }
type Edge = { a: string, b: string, kind: string }

local nodes: { [string]: Node } = {}
local edges: { Edge } = {}

local function node(id: string, x: number, z: number)
	nodes[id] = { id = id, position = Vector3.new(x, ROAD_TOP, z), links = {} }
end

local function link(a: string, b: string, kind: string)
	assert(nodes[a] and nodes[b], `missing road node {a} or {b}`)
	table.insert(nodes[a].links, b)
	table.insert(nodes[b].links, a)
	table.insert(edges, { a = a, b = b, kind = kind })
end

local GRID_X = { -480, -320, -160, 0, 160, 320, 480, 640 }
local GRID_Z = { -480, -320, -160, 0, 160 }

local function gridId(xi: number, zi: number): string
	return `G{xi}_{zi}`
end

local function defineRoads()
	table.clear(nodes)
	table.clear(edges)

	-- city grid; the industrial east side (x >= 320) has big lots, so some streets are missing
	local function industrialGap(xi: number, zi: number): boolean
		return xi >= 6 and (zi == 2 or zi == 4)
	end
	for xi, x in GRID_X do
		for zi, z in GRID_Z do
			if not (xi == 7 and (zi == 2 or zi == 4)) then
				node(gridId(xi, zi), x, z)
			end
		end
	end
	for zi = 1, #GRID_Z do
		for xi = 1, #GRID_X - 1 do
			if not industrialGap(xi, zi) then
				link(gridId(xi, zi), gridId(xi + 1, zi), "street")
			end
		end
	end
	for xi = 1, #GRID_X do
		if xi ~= 7 then
			for zi = 1, #GRID_Z - 1 do
				link(gridId(xi, zi), gridId(xi, zi + 1), "street")
			end
		end
	end

	-- highway along the south edge, with on-ramps
	node("H1", -820, 420)
	node("H2", -480, 420)
	node("H3", -160, 420)
	node("H4", 160, 420)
	node("H5", 320, 420)
	node("H6", 640, 420)
	link("H1", "H2", "highway")
	link("H2", "H3", "highway")
	link("H3", "H4", "highway")
	link("H4", "H5", "highway")
	link("H5", "H6", "highway")
	link(gridId(3, 5), "H3", "street")
	link(gridId(6, 5), "H5", "street")
	link(gridId(8, 5), "H6", "street")

	-- woods: dirt roads winding off the west edge of downtown
	node("W1", -600, -200)
	node("W2", -720, -110)
	node("W3", -820, 40)
	node("W4", -780, 230)
	node("W6", -620, -580)
	node("W7", -780, -480)
	node("W8", -840, -280)
	link(gridId(1, 3), "W1", "dirt")
	link("W1", "W2", "dirt")
	link("W2", "W3", "dirt")
	link("W3", "W4", "dirt")
	link("W4", "H1", "dirt")
	link(gridId(1, 1), "W6", "dirt")
	link("W6", "W7", "dirt")
	link("W7", "W8", "dirt")
	link("W8", "W2", "dirt")
end

local function edgeWidth(kind: string): number
	return if kind == "highway" then HIGHWAY_WIDTH elseif kind == "dirt" then DIRT_WIDTH else STREET_WIDTH
end

local function distanceToSegment(p: Vector3, a: Vector3, b: Vector3): number
	local ab = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	local ap = Vector3.new(p.X - a.X, 0, p.Z - a.Z)
	local t = math.clamp(ap:Dot(ab) / ab:Dot(ab), 0, 1)
	return (ap - ab * t).Magnitude
end

local function nearRoad(p: Vector3, margin: number): boolean
	for _, edge in edges do
		local a, b = nodes[edge.a].position, nodes[edge.b].position
		if distanceToSegment(p, a, b) < edgeWidth(edge.kind) / 2 + margin then
			return true
		end
	end
	return false
end

local function buildRoads(map: Instance)
	local roads = Instance.new("Folder")
	roads.Name = "Roads"

	for _, edge in edges do
		local a, b = nodes[edge.a].position, nodes[edge.b].position
		local width = edgeWidth(edge.kind)
		local length = (b - a).Magnitude
		local mid = (a + b) / 2
		local cf = CFrame.lookAt(Vector3.new(mid.X, ROAD_TOP - 0.5, mid.Z), Vector3.new(b.X, ROAD_TOP - 0.5, b.Z))
		local color = if edge.kind == "dirt" then Palette.Dirt else Palette.Asphalt
		part(roads, {
			Name = "Road",
			Size = Vector3.new(width, 1, length + width * 0.5),
			CFrame = cf,
			Color = color,
			CastShadow = false,
		})

		local lineLength = length - width - 4
		if edge.kind == "street" and lineLength > 0 then
			part(roads, {
				Name = "CenterLine",
				Size = Vector3.new(0.6, 0.1, lineLength),
				CFrame = cf * CFrame.new(0, 0.55, 0),
				Color = Palette.LineYellow,
				CastShadow = false,
			})
		elseif edge.kind == "highway" and lineLength > 0 then
			for _, x in { -0.6, 0.6 } do
				part(roads, {
					Name = "CenterLine",
					Size = Vector3.new(0.5, 0.1, lineLength),
					CFrame = cf * CFrame.new(x, 0.55, 0),
					Color = Palette.LineYellow,
					CastShadow = false,
				})
			end
			for _, side in { -1, 1 } do
				part(roads, {
					Name = "EdgeLine",
					Size = Vector3.new(0.6, 0.1, lineLength),
					CFrame = cf * CFrame.new(side * (width / 2 - 2), 0.55, 0),
					Color = Palette.LineWhite,
					CastShadow = false,
				})
				local dashes = math.floor(lineLength / 24)
				for i = 0, dashes - 1 do
					local z = -lineLength / 2 + 12 + i * 24
					part(roads, {
						Name = "LaneDash",
						Size = Vector3.new(0.5, 0.1, 10),
						CFrame = cf * CFrame.new(side * width / 4, 0.55, z),
						Color = Palette.LineWhite,
						CastShadow = false,
					})
				end
			end
		end
	end

	-- round the joints so curves and intersections don't show gaps
	for _, n in nodes do
		local width = 0
		local kind = "street"
		for _, edge in edges do
			if edge.a == n.id or edge.b == n.id then
				if edgeWidth(edge.kind) > width then
					width = edgeWidth(edge.kind)
					kind = edge.kind
				end
			end
		end
		part(roads, {
			Name = "Junction",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(1, width, width),
			CFrame = CFrame.new(n.position.X, ROAD_TOP - 0.49, n.position.Z) * CFrame.Angles(0, 0, math.rad(90)),
			Color = if kind == "dirt" then Palette.Dirt else Palette.Asphalt,
			CastShadow = false,
		})
	end
	flush(roads, map)

	-- the graph police AI drives on and the phone GPS routes on; LinkKinds lists each link's road
	-- kind ("street", "highway", "dirt") in the same order as Links
	local kindOf: { [string]: string } = {}
	for _, edge in edges do
		kindOf[`{edge.a}|{edge.b}`] = edge.kind
		kindOf[`{edge.b}|{edge.a}`] = edge.kind
	end
	local graph = Instance.new("Folder")
	graph.Name = "RoadGraph"
	for _, n in nodes do
		local value = Instance.new("Vector3Value")
		value.Name = n.id
		value.Value = n.position
		value:SetAttribute("Links", table.concat(n.links, ","))
		local kinds = {}
		for _, other in n.links do
			table.insert(kinds, kindOf[`{n.id}|{other}`] or "street")
		end
		value:SetAttribute("LinkKinds", table.concat(kinds, ","))
		value.Parent = graph
	end
	graph.Parent = map
end

---------------------------------------------------------------------------------------------------
-- Props
---------------------------------------------------------------------------------------------------

local function tree(parent: Instance, position: Vector3, scale: number)
	local trunkHeight = 10 * scale
	part(parent, {
		Name = "Trunk",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(trunkHeight, 2.2 * scale, 2.2 * scale),
		CFrame = CFrame.new(position + Vector3.new(0, trunkHeight / 2, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Palette.Trunk,
	})
	local leaves = pick(Palette.Leaves)
	local canopy = 12 * scale
	part(parent, {
		Name = "Canopy",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(canopy, canopy, canopy),
		Position = position + Vector3.new(0, trunkHeight + canopy * 0.3, 0),
		Color = leaves,
	})
	if rng:NextNumber() < 0.5 then
		local small = canopy * 0.7
		part(parent, {
			Name = "Canopy",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(small, small, small),
			Position = position + Vector3.new(canopy * 0.35, trunkHeight + canopy * 0.65, canopy * 0.1),
			Color = leaves,
		})
	end
end

local function rock(parent: Instance, position: Vector3, scale: number)
	part(parent, {
		Name = "Rock",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(6 * scale, 6 * scale, 6 * scale),
		CFrame = CFrame.new(position) * CFrame.Angles(0, rng:NextNumber() * 6, 0),
		Color = Palette.Rock,
		Material = Enum.Material.Slate,
	})
end

local function crateStack(parent: Instance, position: Vector3, count: number)
	for i = 1, count do
		local offset = Vector3.new((i % 2) * 4.4 - 2.2, 2 + math.floor((i - 1) / 2) * 4, 0)
		local crate = part(parent, {
			Name = "Crate",
			Size = Vector3.new(4, 4, 4),
			CFrame = CFrame.new(position + offset) * CFrame.Angles(0, math.rad(rng:NextInteger(-8, 8)), 0),
			Color = Palette.Wood,
		})
		part(parent, {
			Name = "CrateBand",
			Size = Vector3.new(4.1, 0.6, 4.1),
			CFrame = crate.CFrame,
			Color = Palette.Trunk,
		})
	end
end

local function container(parent: Instance, cf: CFrame)
	local color = pick(Palette.Containers)
	part(parent, {
		Name = "Container",
		Size = Vector3.new(8, 8.6, 24),
		CFrame = cf,
		Color = color,
	})
	for _, z in { -12.1, 12.1 } do
		part(parent, {
			Name = "ContainerDoor",
			Size = Vector3.new(7.2, 7.8, 0.3),
			CFrame = cf * CFrame.new(0, 0, z),
			Color = color:Lerp(Color3.new(0, 0, 0), 0.25),
		})
	end
end

local function streetLight(parent: Instance, position: Vector3, facing: Vector3)
	local base = position + Vector3.new(0, SIDEWALK_TOP, 0)
	part(parent, {
		Name = "Pole",
		Size = Vector3.new(0.8, 18, 0.8),
		Position = base + Vector3.new(0, 9, 0),
		Color = Palette.Roof,
	})
	local armEnd = base + Vector3.new(0, 18, 0) + facing * 5
	part(parent, {
		Name = "Arm",
		Size = Vector3.new(0.6, 0.6, 5.5),
		CFrame = CFrame.lookAt(base + Vector3.new(0, 18, 0) + facing * 2.5, armEnd),
		Color = Palette.Roof,
	})
	local lamp = part(parent, {
		Name = "Lamp",
		Size = Vector3.new(2, 0.6, 3),
		CFrame = CFrame.lookAt(armEnd - Vector3.new(0, 0.4, 0), armEnd - Vector3.new(0, 0.4, 0) + facing),
		Color = Color3.fromRGB(255, 236, 190),
		Material = Enum.Material.Neon,
		CastShadow = false,
	})
	local light = Instance.new("SpotLight")
	light.Face = Enum.NormalId.Bottom
	light.Angle = 110
	light.Range = 40
	light.Brightness = 2.5
	light.Color = Color3.fromRGB(255, 220, 170)
	light.Enabled = false
	light.Parent = lamp
	CollectionService:AddTag(lamp, "StreetLight")
end

---------------------------------------------------------------------------------------------------
-- Buildings
---------------------------------------------------------------------------------------------------

-- Blender building meshes imported by Tools.MeshImporter. Until they're imported, every
-- building falls back to its graybox parts.
local function buildingTemplate(name: string): Model?
	local assets = ServerStorage:FindFirstChild("Assets")
	local buildings = assets and assets:FindFirstChild("Buildings")
	return if buildings then buildings:FindFirstChild(name) :: Model? else nil
end

-- Clones a template with its base at `base` and its street face (template -Z) toward `facing`.
-- `color` tints the Body (wall) part.
local function placeTemplate(
	parent: Instance,
	template: Model,
	base: Vector3,
	facing: Vector3,
	color: Color3?,
	name: string?
): Model
	local model = template:Clone()
	model.Name = name or template.Name
	model:PivotTo(CFrame.lookAt(base, base + facing))
	local body = model:FindFirstChild("Body") :: BasePart?
	if color and body then
		body.Color = color
	end
	model.Parent = parent
	return model
end

-- Picks the mesh variant whose fixed size best fits a lot MapBuilder sized for a graybox.
local function buildingVariant(size: Vector3): string
	local long, short = math.max(size.X, size.Z), math.min(size.X, size.Z)
	if long >= 90 then
		return if size.Y > 60 then "Tower" else "BrickBlock"
	elseif short >= 40 then
		return if size.Y < 60 then "Midrise" elseif size.Y < 95 then "Office" else "OfficeTall"
	elseif size.Y <= 16 then
		return "RestStop"
	end
	return if size.Y < 26 then "Shop" else "ShopTall"
end

-- A stylized building: the matching mesh variant, or as a graybox a solid box with dark glass
-- bands (one part per floor covers all four faces), a roof cap and an awning on the street side.
local function building(parent: Instance, center: Vector3, size: Vector3, color: Color3, streetDir: Vector3?)
	local template = buildingTemplate(buildingVariant(size))
	if template then
		-- same random draws as the graybox below, so the rest of the layout doesn't shift
		if size.Y > 50 then
			rng:NextNumber()
		end
		if streetDir then
			pick(Palette.Containers)
		end
		placeTemplate(parent, template, center, streetDir or Vector3.new(0, 0, -1), color, "Building")
		return
	end
	local model = Instance.new("Model")
	model.Name = "Building"
	local base = center.Y
	part(model, {
		Name = "Body",
		Size = size,
		Position = Vector3.new(center.X, base + size.Y / 2, center.Z),
		Color = color,
	})
	local floorHeight = 12
	local floors = math.floor((size.Y - 6) / floorHeight)
	for i = 1, floors do
		part(model, {
			Name = "Windows",
			Size = Vector3.new(size.X + 0.3, 4.5, size.Z + 0.3),
			Position = Vector3.new(center.X, base + i * floorHeight - 1, center.Z),
			Color = Palette.Glass,
			Reflectance = 0.05,
			CastShadow = false,
		})
	end
	part(model, {
		Name = "RoofCap",
		Size = Vector3.new(size.X + 1.6, 1.4, size.Z + 1.6),
		Position = Vector3.new(center.X, base + size.Y + 0.2, center.Z),
		Color = color:Lerp(Color3.new(0, 0, 0), 0.3),
	})
	if size.Y > 50 and rng:NextNumber() < 0.6 then
		part(model, {
			Name = "RoofUnit",
			Size = Vector3.new(size.X * 0.3, 5, size.Z * 0.3),
			Position = Vector3.new(center.X + size.X * 0.15, base + size.Y + 3, center.Z - size.Z * 0.1),
			Color = Palette.Curb,
		})
	end
	if streetDir then
		local awningColor = pick(Palette.Containers)
		local along = Vector3.new(streetDir.Z, 0, -streetDir.X)
		local faceWidth = math.abs(along:Dot(size))
		local faceDepth = math.abs(streetDir:Dot(size))
		local awningCenter = Vector3.new(center.X, base + 7, center.Z) + streetDir * (faceDepth / 2 + 2)
		part(model, {
			Name = "Awning",
			Size = Vector3.new(faceWidth * 0.8, 0.6, 4),
			CFrame = CFrame.lookAt(awningCenter, awningCenter + streetDir) * CFrame.Angles(math.rad(-12), 0, 0),
			Color = awningColor,
		})
		part(model, {
			Name = "Storefront",
			Size = Vector3.new(faceWidth * 0.75, 5.5, 0.3),
			CFrame = CFrame.lookAt(
				Vector3.new(center.X, base + 3.2, center.Z) + streetDir * (faceDepth / 2 + 0.2),
				Vector3.new(center.X, base + 3.2, center.Z) + streetDir * (faceDepth / 2 + 1)
			),
			Color = Palette.Glass,
			Reflectance = 0.2,
		})
	end
	model.Parent = parent
end

local function blockBase(parent: Instance, x0: number, z0: number, x1: number, z1: number, color: Color3?)
	local inset = STREET_WIDTH / 2
	local sx, sz = (x1 - x0) - inset * 2, (z1 - z0) - inset * 2
	part(parent, {
		Name = "Sidewalk",
		Size = Vector3.new(sx, SIDEWALK_TOP + 1, sz),
		Position = Vector3.new((x0 + x1) / 2, (SIDEWALK_TOP - 1) / 2, (z0 + z1) / 2),
		Color = color or Palette.Sidewalk,
		CastShadow = false,
	})
	return sx, sz
end

local DOWNTOWN_CENTER = Vector3.new(-160, 0, -240)

local function downtownBlock(parent: Instance, x0: number, z0: number, x1: number, z1: number)
	local sx, sz = blockBase(parent, x0, z0, x1, z1)
	local cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
	local margin = 6
	local usable = Vector2.new(sx - margin * 2, sz - margin * 2)
	local dist = (Vector3.new(cx, 0, cz) - DOWNTOWN_CENTER).Magnitude
	local maxHeight = math.clamp(150 - dist * 0.3, 36, 150)

	-- either one tower or a 2x2 grid of smaller buildings
	if rng:NextNumber() < 0.3 then
		local h = maxHeight * rng:NextNumber(0.8, 1.1)
		building(parent, Vector3.new(cx, SIDEWALK_TOP, cz), Vector3.new(usable.X, h, usable.Y), pick(Palette.Buildings), nil)
		return
	end
	local lotW, lotD = usable.X / 2, usable.Y / 2
	for ix = 0, 1 do
		for iz = 0, 1 do
			local lx = cx - usable.X / 2 + lotW * (ix + 0.5)
			local lz = cz - usable.Y / 2 + lotD * (iz + 0.5)
			local w = lotW - rng:NextNumber(2, 8)
			local d = lotD - rng:NextNumber(2, 8)
			local h = rng:NextNumber(0.45, 1) * maxHeight
			-- face the awning toward the nearer street on the x axis
			local streetDir = Vector3.new(if ix == 0 then -1 else 1, 0, 0)
			building(parent, Vector3.new(lx, SIDEWALK_TOP, lz), Vector3.new(w, h, d), pick(Palette.Buildings), streetDir)
		end
	end
end

local function lowBlock(parent: Instance, x0: number, z0: number, x1: number, z1: number)
	local sx, sz = blockBase(parent, x0, z0, x1, z1)
	local cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
	local count = 3
	local w = (sx - 12) / count
	for i = 0, count - 1 do
		local lx = cx - (sx - 12) / 2 + w * (i + 0.5)
		local depth = sz * 0.45
		local h = rng:NextNumber(18, 32)
		building(
			parent,
			Vector3.new(lx, SIDEWALK_TOP, cz - sz / 2 + depth / 2 + 6),
			Vector3.new(w - 4, h, depth),
			pick(Palette.Buildings),
			Vector3.new(0, 0, -1)
		)
	end
	-- back half is a small yard with a tree
	tree(parent, Vector3.new(cx + rng:NextNumber(-30, 30), SIDEWALK_TOP, cz + sz * 0.25), 0.8)
end

local function parkBlock(parent: Instance, x0: number, z0: number, x1: number, z1: number)
	local sx, sz = blockBase(parent, x0, z0, x1, z1)
	local cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
	part(parent, {
		Name = "Lawn",
		Size = Vector3.new(sx - 10, 0.4, sz - 10),
		Position = Vector3.new(cx, SIDEWALK_TOP + 0.2, cz),
		Color = Palette.Grass,
		CastShadow = false,
	})
	part(parent, {
		Name = "Fountain",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(2.5, 26, 26),
		CFrame = CFrame.new(cx, SIDEWALK_TOP + 1.2, cz) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Palette.Sidewalk,
	})
	part(parent, {
		Name = "FountainWater",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.4, 22, 22),
		CFrame = CFrame.new(cx, SIDEWALK_TOP + 2.4, cz) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Palette.Water,
		Transparency = 0.2,
		CastShadow = false,
	})
	for _ = 1, 8 do
		local angle = rng:NextNumber() * math.pi * 2
		local r = rng:NextNumber(26, math.min(sx, sz) / 2 - 12)
		tree(parent, Vector3.new(cx + math.cos(angle) * r, SIDEWALK_TOP, cz + math.sin(angle) * r), rng:NextNumber(0.7, 1))
	end
end

local function parkingBlock(parent: Instance, x0: number, z0: number, x1: number, z1: number)
	local sx, sz = blockBase(parent, x0, z0, x1, z1)
	local cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
	part(parent, {
		Name = "Lot",
		Size = Vector3.new(sx - 6, 0.2, sz - 6),
		Position = Vector3.new(cx, SIDEWALK_TOP + 0.1, cz),
		Color = Palette.AsphaltLight,
		CastShadow = false,
	})
	for row = -1, 1, 2 do
		for i = -4, 4 do
			part(parent, {
				Name = "Stripe",
				Size = Vector3.new(0.4, 0.1, 16),
				Position = Vector3.new(cx + i * 11, SIDEWALK_TOP + 0.25, cz + row * 28),
				Color = Palette.LineWhite,
				CastShadow = false,
			})
		end
	end
end

local function policeStationBlock(parent: Instance, x0: number, z0: number, x1: number, z1: number)
	local sx, sz = blockBase(parent, x0, z0, x1, z1)
	local cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
	local center = Vector3.new(cx, SIDEWALK_TOP, cz - 14)
	local template = buildingTemplate("PoliceStation")
	local model: Model
	local sign: BasePart
	local signFace: Enum.NormalId
	if template then
		-- the station's street side is +Z
		model = placeTemplate(parent, template, center, Vector3.new(0, 0, 1), nil, "PoliceStation")
		sign = model:FindFirstChild("Sign") :: BasePart
		signFace = Enum.NormalId.Front
	else
		model = Instance.new("Model")
		model.Name = "PoliceStation"
		part(model, {
			Name = "Body",
			Size = Vector3.new(sx - 24, 30, sz * 0.5),
			Position = center + Vector3.new(0, 15, 0),
			Color = Palette.PoliceWhite,
		})
		part(model, {
			Name = "Stripe",
			Size = Vector3.new(sx - 23.6, 4, sz * 0.5 + 0.4),
			Position = center + Vector3.new(0, 20, 0),
			Color = Palette.PoliceNavy,
		})
		part(model, {
			Name = "Windows",
			Size = Vector3.new(sx - 23.6, 4, sz * 0.5 + 0.4),
			Position = center + Vector3.new(0, 10, 0),
			Color = Palette.Glass,
			Reflectance = 0.15,
		})
		sign = part(model, {
			Name = "Sign",
			Size = Vector3.new(30, 5, 0.6),
			Position = center + Vector3.new(0, 26, sz * 0.25 + 0.4),
			Color = Palette.PoliceNavy,
		})
		signFace = Enum.NormalId.Back
	end
	local gui = Instance.new("SurfaceGui")
	gui.Face = signFace
	gui.CanvasSize = Vector2.new(600, 100)
	gui.Parent = sign
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "POLICE"
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Parent = gui
	model.Parent = parent

	-- busted players are released out front
	local release = part(parent, {
		Name = "PoliceRelease",
		Size = Vector3.new(6, 1, 6),
		Position = Vector3.new(cx, SIDEWALK_TOP + 0.5, cz + sz / 2 - 10),
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
	})
	CollectionService:AddTag(release, Config.Tags.PoliceRelease)
end

---------------------------------------------------------------------------------------------------
-- Districts
---------------------------------------------------------------------------------------------------

local function buildGround(map: Instance)
	local ground = Instance.new("Folder")
	ground.Name = "Ground"
	part(ground, {
		Name = "Grass",
		Size = Vector3.new(1640, 8, 1300),
		Position = Vector3.new(-100, GROUND_Y - 4, -80),
		Color = Palette.Grass,
		CastShadow = false,
	})
	-- harbor: terrain water so players can swim back to the quay
	local terrain = workspace.Terrain
	local harbor = CFrame.new(920, GROUND_Y - 12, -80)
	terrain:FillBlock(harbor, Vector3.new(400, 40, 1320), Enum.Material.Air)
	terrain:FillBlock(harbor * CFrame.new(0, -4, 0), Vector3.new(400, 16, 1300), Enum.Material.Water)
	terrain:FillBlock(harbor * CFrame.new(0, -14, 0), Vector3.new(400, 4, 1300), Enum.Material.Sand)
	terrain.WaterColor = Palette.Water
	terrain.WaterTransparency = 0.6
	terrain.WaterReflectance = 0.25
	terrain.WaterWaveSize = 0.08
	terrain.WaterWaveSpeed = 6
	-- invisible map bounds
	local bounds = {
		{ Vector3.new(-100, 60, -735), Vector3.new(2000, 160, 10) },
		{ Vector3.new(-100, 60, 575), Vector3.new(2000, 160, 10) },
		{ Vector3.new(-925, 60, -80), Vector3.new(10, 160, 1320) },
		{ Vector3.new(1125, 60, -80), Vector3.new(10, 160, 1320) },
	}
	for _, b in bounds do
		part(ground, {
			Name = "Boundary",
			Position = b[1],
			Size = b[2],
			Transparency = 1,
			CanQuery = false,
			CastShadow = false,
		})
	end
	flush(ground, map)
end

local function buildDowntown(map: Instance)
	local downtown = Instance.new("Folder")
	downtown.Name = "Downtown"
	for xi = 1, 4 do
		for zi = 1, 4 do
			local x0, x1 = GRID_X[xi], GRID_X[xi + 1]
			local z0, z1 = GRID_Z[zi], GRID_Z[zi + 1]
			if xi == 2 and zi == 2 then
				parkBlock(downtown, x0, z0, x1, z1)
			elseif xi == 4 and zi == 1 then
				parkingBlock(downtown, x0, z0, x1, z1)
			elseif xi == 1 and zi == 3 then
				policeStationBlock(downtown, x0, z0, x1, z1)
			elseif zi == 4 then
				lowBlock(downtown, x0, z0, x1, z1)
			else
				downtownBlock(downtown, x0, z0, x1, z1)
			end
		end
		task.wait()
	end
	-- the column between downtown and industrial: older brick buildings
	for zi = 1, 4 do
		local x0, x1 = GRID_X[5], GRID_X[6]
		local z0, z1 = GRID_Z[zi], GRID_Z[zi + 1]
		local sx, sz = blockBase(downtown, x0, z0, x1, z1)
		building(
			downtown,
			Vector3.new((x0 + x1) / 2, SIDEWALK_TOP, (z0 + z1) / 2),
			Vector3.new(sx - 14, rng:NextNumber(24, 44), sz - 14),
			pick(Palette.Industrial),
			nil
		)
	end
	for xi = 1, 6 do
		for zi = 1, 5 do
			local x, z = GRID_X[xi], GRID_Z[zi]
			local corner = Vector3.new(x + STREET_WIDTH / 2 + 2, 0, z + STREET_WIDTH / 2 + 2)
			streetLight(downtown, corner, Vector3.new(-1, 0, 0))
		end
	end
	flush(downtown, map)
end

local function warehouse(parent: Instance, center: Vector3, size: Vector3, color: Color3, doorDir: Vector3)
	local template = buildingTemplate(if size.Y >= 31 then "WarehouseLarge" else "WarehouseSmall")
	if template then
		placeTemplate(parent, template, center, doorDir, color, "Warehouse")
		return
	end
	local model = Instance.new("Model")
	model.Name = "Warehouse"
	part(model, {
		Name = "Body",
		Size = size,
		Position = center + Vector3.new(0, size.Y / 2, 0),
		Color = color,
	})
	part(model, {
		Name = "Roof",
		Size = Vector3.new(size.X + 2, 2, size.Z + 2),
		Position = center + Vector3.new(0, size.Y + 1, 0),
		Color = Palette.Roof,
	})
	local along = Vector3.new(doorDir.Z, 0, -doorDir.X)
	local faceWidth = math.abs(along:Dot(size))
	local faceDepth = math.abs(doorDir:Dot(size))
	local doors = math.max(2, math.floor(faceWidth / 30))
	for i = 1, doors do
		local offset = along * ((i - 0.5) / doors - 0.5) * faceWidth
		local doorCenter = center + Vector3.new(0, 9, 0) + doorDir * (faceDepth / 2 + 0.2) + offset
		part(model, {
			Name = "RollDoor",
			Size = Vector3.new(16, 18, 0.4),
			CFrame = CFrame.lookAt(doorCenter, doorCenter + doorDir),
			Color = Palette.Industrial[2]:Lerp(Color3.new(0, 0, 0), 0.2),
		})
	end
	model.Parent = parent
end

local function crane(parent: Instance, position: Vector3)
	local model = Instance.new("Model")
	model.Name = "Crane"
	for _, z in { -14, 14 } do
		for _, x in { -12, 12 } do
			part(model, {
				Name = "Leg",
				Size = Vector3.new(3, 70, 3),
				Position = position + Vector3.new(x, 35, z),
				Color = Palette.CraneYellow,
			})
		end
		part(model, {
			Name = "Brace",
			Size = Vector3.new(27, 3, 3),
			Position = position + Vector3.new(0, 40, z),
			Color = Palette.CraneYellow,
		})
	end
	part(model, {
		Name = "Boom",
		Size = Vector3.new(130, 5, 6),
		Position = position + Vector3.new(30, 72, 0),
		Color = Palette.CraneYellow,
	})
	part(model, {
		Name = "Cab",
		Size = Vector3.new(10, 8, 10),
		Position = position + Vector3.new(4, 66, 0),
		Color = Palette.PoliceWhite,
	})
	model.Parent = parent
end

local function buildIndustrial(map: Instance)
	local industrial = Instance.new("Folder")
	industrial.Name = "Industrial"
	local lots = {
		{ 320, -480, 640, -160 },
		{ 320, -160, 640, 160 },
	}
	for i, lot in lots do
		local x0, z0, x1, z1 = lot[1], lot[2], lot[3], lot[4]
		local sx, sz = blockBase(industrial, x0, z0, x1, z1, Palette.Curb)
		local cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
		warehouse(
			industrial,
			Vector3.new(cx - sx / 4, SIDEWALK_TOP, cz - sz / 4),
			Vector3.new(sx / 2 - 16, 34, sz / 2 - 20),
			Palette.Industrial[i],
			Vector3.new(0, 0, 1)
		)
		warehouse(
			industrial,
			Vector3.new(cx + sx / 4, SIDEWALK_TOP, cz + sz / 4),
			Vector3.new(sx / 2 - 16, 28, sz / 2 - 20),
			Palette.Industrial[i + 2],
			Vector3.new(0, 0, -1)
		)
		-- container stacks in the open corners
		for row = 0, 2 do
			for stack = 1, rng:NextInteger(1, 3) do
				container(
					industrial,
					CFrame.new(cx + sx / 4 - 30 + row * 10, SIDEWALK_TOP + 4.3 + (stack - 1) * 8.6, cz - sz / 4)
				)
			end
		end
	end

	-- dock quay between the east road and the water
	local quayX, quayWidth = 700, 70
	part(industrial, {
		Name = "Quay",
		Size = Vector3.new(quayWidth, 2, 1200),
		Position = Vector3.new(quayX, SIDEWALK_TOP - 1, -80),
		Color = Palette.Curb,
		CastShadow = false,
	})
	-- piers start exactly at the quay's edge: overlapping it with the same top height made the
	-- two surfaces z-fight
	local pierStart, pierEnd = quayX + quayWidth / 2, 850
	for _, z in { -400, -160, 80 } do
		part(industrial, {
			Name = "Pier",
			Size = Vector3.new(pierEnd - pierStart, 1.5, 24),
			Position = Vector3.new((pierStart + pierEnd) / 2, SIDEWALK_TOP - 0.75, z),
			Color = Palette.Wood,
		})
		for px = 740, 840, 25 do
			for _, pz in { z - 11, z + 11 } do
				part(industrial, {
					Name = "Piling",
					Shape = Enum.PartType.Cylinder,
					Size = Vector3.new(16, 2, 2),
					CFrame = CFrame.new(px, SIDEWALK_TOP - 6, pz) * CFrame.Angles(0, 0, math.rad(90)),
					Color = Palette.Trunk,
				})
			end
		end
	end
	crane(industrial, Vector3.new(705, SIDEWALK_TOP, -280))
	crane(industrial, Vector3.new(705, SIDEWALK_TOP, -20))
	for i = 0, 5 do
		container(industrial, CFrame.new(712, SIDEWALK_TOP + 4.3, 140 + i * 26) * CFrame.Angles(0, math.rad(90), 0))
	end
	flush(industrial, map)
end

local function buildSouthStrip(map: Instance)
	local south = Instance.new("Folder")
	south.Name = "SouthStrip"

	-- Sunset Motel (solo players' crash pad)
	local motelTemplate = buildingTemplate("Motel")
	local motel: Model
	if motelTemplate then
		motel = placeTemplate(south, motelTemplate, Vector3.new(40, GROUND_Y, 300), Vector3.new(0, 0, -1), nil, "SunsetMotel")
	else
		motel = Instance.new("Model")
		motel.Name = "SunsetMotel"
		part(motel, {
			Name = "Body",
			Size = Vector3.new(110, 22, 26),
			Position = Vector3.new(40, 11, 300),
			Color = Palette.Buildings[6],
		})
		part(motel, {
			Name = "Walkway",
			Size = Vector3.new(110, 1, 8),
			Position = Vector3.new(40, 11, 283),
			Color = Palette.Buildings[1],
		})
		part(motel, {
			Name = "Roof",
			Size = Vector3.new(114, 1.4, 34),
			Position = Vector3.new(40, 22.7, 296),
			Color = Palette.Buildings[2],
		})
		for i = 0, 7 do
			for _, y in { 4.5, 15.5 } do
				part(motel, {
					Name = "Door",
					Size = Vector3.new(5, 8, 0.4),
					Position = Vector3.new(-6 + i * 13, y, 286.8),
					Color = Palette.Containers[2],
				})
			end
		end
	end
	local signPost = part(motel, {
		Name = "SignPost",
		Size = Vector3.new(1.4, 30, 1.4),
		Position = Vector3.new(-30, 15, 250),
		Color = Palette.Roof,
	})
	local sign = part(motel, {
		Name = "Sign",
		Size = Vector3.new(26, 9, 1),
		Position = signPost.Position + Vector3.new(0, 14, 0),
		Color = Palette.Containers[5],
	})
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.CanvasSize = Vector2.new(520, 180)
	gui.LightInfluence = 0
	gui.Parent = sign
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "SUNSET MOTEL"
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 244, 220)
	label.Parent = gui
	motel.Parent = south

	part(south, {
		Name = "MotelLot",
		Size = Vector3.new(150, 0.4, 90),
		Position = Vector3.new(40, ROAD_TOP - 0.2, 240),
		Color = Palette.AsphaltLight,
		CastShadow = false,
	})
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "MotelSpawn"
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Size = Vector3.new(10, 0.4, 10)
	spawn.Position = Vector3.new(40, ROAD_TOP + 0.2, 276)
	spawn.Color = Palette.Buildings[1]
	spawn.Material = Enum.Material.SmoothPlastic
	spawn.Transparency = 1
	spawn.CanCollide = false
	local decal = spawn:FindFirstChildOfClass("Decal")
	if decal then
		decal:Destroy()
	end
	spawn.Parent = south

	for i, vehicleType in { "Sedan", "Sedan", "Van" } do
		local pad = part(south, {
			Name = `{vehicleType}Spawn`,
			Size = Vector3.new(12, 0.2, 20),
			Position = Vector3.new(-10 + (i - 1) * 22, ROAD_TOP + 0.1, 232),
			Color = Palette.CarSpawn,
			Transparency = 0.5,
			CanCollide = false,
			CastShadow = false,
		})
		pad:SetAttribute("VehicleType", vehicleType)
		CollectionService:AddTag(pad, Config.Tags.CarSpawn)
	end

	-- gas station: canopy over the pumps, shop 50 studs behind it
	local gasTemplate = buildingTemplate("GasStation")
	local gas = if gasTemplate
		then placeTemplate(south, gasTemplate, Vector3.new(-330, GROUND_Y, 240), Vector3.new(0, 0, -1))
		else Instance.new("Model")
	gas.Name = "GasStation"
	if not gasTemplate then
		part(gas, {
			Name = "Canopy",
			Size = Vector3.new(60, 2, 36),
			Position = Vector3.new(-330, 18, 240),
			Color = Palette.PoliceWhite,
		})
		part(gas, {
			Name = "CanopyTrim",
			Size = Vector3.new(60.4, 1.2, 36.4),
			Position = Vector3.new(-330, 16.8, 240),
			Color = Palette.Containers[1],
		})
		for _, x in { -350, -310 } do
			part(gas, {
				Name = "Pillar",
				Size = Vector3.new(2, 17, 2),
				Position = Vector3.new(x, 8.5, 240),
				Color = Palette.Sidewalk,
			})
			part(gas, {
				Name = "Pump",
				Size = Vector3.new(3, 6, 2),
				Position = Vector3.new(x, 3, 246),
				Color = Palette.Containers[1],
			})
		end
		part(gas, {
			Name = "Shop",
			Size = Vector3.new(40, 16, 24),
			Position = Vector3.new(-330, 8, 290),
			Color = Palette.Buildings[3],
		})
		part(gas, {
			Name = "ShopWindow",
			Size = Vector3.new(30, 7, 0.4),
			Position = Vector3.new(-330, 5, 277.8),
			Color = Palette.Glass,
			Reflectance = 0.2,
		})
	end
	gas.Parent = south
	part(south, {
		Name = "GasLot",
		Size = Vector3.new(100, 0.4, 100),
		Position = Vector3.new(-330, ROAD_TOP - 0.2, 250),
		Color = Palette.AsphaltLight,
		CastShadow = false,
	})

	-- highway rest stop
	part(south, {
		Name = "RestStopLot",
		Size = Vector3.new(120, 0.4, 50),
		Position = Vector3.new(-640, ROAD_TOP - 0.2, 482),
		Color = Palette.AsphaltLight,
		CastShadow = false,
	})
	building(south, Vector3.new(-640, ROAD_TOP, 520), Vector3.new(40, 14, 20), Palette.Buildings[5], Vector3.new(0, 0, -1))
	flush(south, map)
end

-- spots kept free of trees: the rest stop and the sawmill clearing
local CLEARINGS = {
	{ -720, 440, -560, 560 },
	{ -820, -580, -700, -480 },
}

local function inClearing(p: Vector3): boolean
	for _, r in CLEARINGS do
		if p.X > r[1] and p.X < r[3] and p.Z > r[2] and p.Z < r[4] then
			return true
		end
	end
	return false
end

local function buildWoods(map: Instance)
	local woods = Instance.new("Folder")
	woods.Name = "Woods"
	local placed = 0
	local attempts = 0
	while placed < 360 and attempts < 4000 do
		attempts += 1
		local x = rng:NextNumber(-910, -520)
		local z = rng:NextNumber(-720, 560)
		-- also scatter along the north edge behind downtown
		if rng:NextNumber() < 0.3 then
			x = rng:NextNumber(-520, 620)
			z = rng:NextNumber(-720, -540)
		end
		local p = Vector3.new(x, GROUND_Y, z)
		if not nearRoad(p, 10) and not inClearing(p) then
			if rng:NextNumber() < 0.1 then
				rock(woods, p, rng:NextNumber(0.6, 1.6))
			else
				tree(woods, p, rng:NextNumber(0.8, 1.5))
			end
			placed += 1
			if placed % 60 == 0 then
				task.wait()
			end
		end
	end

	-- the Old Sawmill clearing; the shed opens east, toward the log pile
	local millTemplate = buildingTemplate("Sawmill")
	local mill = if millTemplate
		then placeTemplate(woods, millTemplate, Vector3.new(-770, GROUND_Y, -540), Vector3.new(1, 0, 0))
		else Instance.new("Model")
	mill.Name = "OldSawmill"
	if not millTemplate then
		part(mill, {
			Name = "Shed",
			Size = Vector3.new(44, 18, 28),
			Position = Vector3.new(-770, 9, -540),
			Color = Palette.Wood,
		})
		part(mill, {
			Name = "Roof",
			Size = Vector3.new(48, 2, 32),
			Position = Vector3.new(-770, 19, -540),
			Color = Palette.Industrial[3],
		})
	end
	for i = 0, 4 do
		part(mill, {
			Name = "Log",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(20, 3, 3),
			Position = Vector3.new(-735, 1.5 + (i % 2) * 2.6, -515 + i * 3.2),
			Color = Palette.Trunk,
		})
	end
	mill.Parent = woods
	flush(woods, map)
end

---------------------------------------------------------------------------------------------------
-- Job points
---------------------------------------------------------------------------------------------------

local JOB_POINTS = {
	{ name = "Pier 4", tag = "Pickup", position = Vector3.new(780, SIDEWALK_TOP, -400) },
	{ name = "Old Sawmill", tag = "Pickup", position = Vector3.new(-760, GROUND_Y, -505) },
	{ name = "Parking Lot B", tag = "Pickup", position = Vector3.new(80, SIDEWALK_TOP + 0.2, -400) },
	{ name = "Rail Yard", tag = "Pickup", position = Vector3.new(400, SIDEWALK_TOP, 100) },
	{ name = "Sunset Motel", tag = "Dropoff", position = Vector3.new(110, ROAD_TOP, 250) },
	{ name = "Gas Station", tag = "Dropoff", position = Vector3.new(-330, ROAD_TOP, 220) },
	{ name = "Highway Rest Stop", tag = "Dropoff", position = Vector3.new(-640, ROAD_TOP, 482) },
	{ name = "Warehouse 9", tag = "Dropoff", position = Vector3.new(420, SIDEWALK_TOP, -270) },
	{ name = "Back Alley", tag = "Dropoff", position = Vector3.new(-400, SIDEWALK_TOP, 120) },
}

local function buildJobPoints(map: Instance)
	local points = Instance.new("Folder")
	points.Name = "JobPoints"
	for _, def in JOB_POINTS do
		local isPickup = def.tag == "Pickup"
		local pad = part(points, {
			Name = def.name,
			Size = Vector3.new(16, 0.3, 16),
			Position = def.position + Vector3.new(0, 0.15, 0),
			Color = if isPickup then Palette.Pickup else Palette.Dropoff,
			Material = Enum.Material.Neon,
			Transparency = 0.35,
			CanCollide = false,
			CastShadow = false,
		})
		CollectionService:AddTag(pad, if isPickup then Config.Tags.Pickup else Config.Tags.Dropoff)
		if isPickup then
			crateStack(points, def.position + Vector3.new(11, 0, 0), 3)
		end
	end
	flush(points, map)
end

---------------------------------------------------------------------------------------------------
-- Lighting
---------------------------------------------------------------------------------------------------

local function ensure(className: string, name: string): Instance
	local existing = Lighting:FindFirstChild(name)
	if existing and existing.ClassName == className then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local instance = Instance.new(className)
	instance.Name = name
	instance.Parent = Lighting
	return instance
end

function MapBuilder.applyLighting()
	-- Future lighting with soft, warm tones: stylized but not flat
	pcall(function()
		(Lighting :: any).Technology = Enum.Technology.Future
	end)
	Lighting.ClockTime = 14.5
	Lighting.Brightness = 2.6
	Lighting.Ambient = Color3.fromRGB(70, 70, 82)
	Lighting.OutdoorAmbient = Color3.fromRGB(128, 128, 140)
	Lighting.EnvironmentDiffuseScale = 0.6
	Lighting.EnvironmentSpecularScale = 0.3
	Lighting.ShadowSoftness = 0.25
	Lighting.GlobalShadows = true
	Lighting.GeographicLatitude = 35

	local atmosphere = ensure("Atmosphere", "Atmosphere") :: Atmosphere
	atmosphere.Density = 0.28
	atmosphere.Offset = 0.15
	atmosphere.Color = Color3.fromRGB(200, 214, 230)
	atmosphere.Decay = Color3.fromRGB(110, 120, 150)
	atmosphere.Glare = 0.2
	atmosphere.Haze = 1.2

	local color = ensure("ColorCorrectionEffect", "ColorCorrection") :: ColorCorrectionEffect
	color.Saturation = 0.15
	color.Contrast = 0.08
	color.Brightness = 0.02
	color.TintColor = Color3.fromRGB(255, 250, 244)

	local bloom = ensure("BloomEffect", "Bloom") :: BloomEffect
	bloom.Intensity = 0.6
	bloom.Size = 24
	bloom.Threshold = 1.6

	local rays = ensure("SunRaysEffect", "SunRays") :: SunRaysEffect
	rays.Intensity = 0.04
	rays.Spread = 0.6

	local dof = Lighting:FindFirstChildOfClass("DepthOfFieldEffect")
	if dof then
		dof.Enabled = false
	end
end

---------------------------------------------------------------------------------------------------

function MapBuilder.build()
	local old = workspace:FindFirstChild("Map")
	if old then
		old:Destroy()
	end
	for _, name in { "Baseplate", "SpawnLocation" } do
		local default = workspace:FindFirstChild(name)
		if default then
			default:Destroy()
		end
	end

	local map = Instance.new("Folder")
	map.Name = "Map"
	map.Parent = workspace

	defineRoads()
	buildGround(map)
	buildRoads(map)
	buildDowntown(map)
	buildIndustrial(map)
	buildSouthStrip(map)
	buildWoods(map)
	buildJobPoints(map)
	MapBuilder.applyLighting()

	local count = 0
	for _, d in map:GetDescendants() do
		if d:IsA("BasePart") then
			count += 1
		end
	end
	return `Map built: {count} parts`
end

return MapBuilder
