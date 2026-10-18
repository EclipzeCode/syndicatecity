--!strict
-- Edit-mode graybox builder for the v0.1 region. Run from Studio's command bar:
--   require(game.ServerStorage.Tools.MapBuilder).build()
-- Deletes and rebuilds Workspace.Map and the terrain, and applies the lighting baseline. Save the
-- place afterwards. The layout is deterministic (fixed seed), so rebuilding gives the same map.
--
-- Three districts, laid out so the drive between them is part of the job:
--   Downtown (centre): a tight street grid, the police station and most of the patrols.
--   Industrial + docks (east, across the river): wide truck roads, big lots, the quay and piers.
--   Outskirts (everywhere else): woods, hills, farmland and long country and dirt roads.
-- Downtown and the industrial district are linked three ways: the highway (fast, open), Harbor
-- Road (direct, two-lane) and the northern Ridge Road (long and quiet); the south farm roads and
-- the western loop make longer, calmer alternatives.

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
local WIDE_WIDTH = 48 -- industrial truck roads

-- the playable region; the sea fills everything east of COAST_X
local WORLD_X0, WORLD_X1 = -3800, 4200
local WORLD_Z0, WORLD_Z1 = -2500, 2200
local COAST_X = 3480
-- the river between downtown and the industrial district; roads cross it on bridges
local RIVER_X0, RIVER_X1 = 1100, 1260
-- water surfaces sit this far below the ground, like the old harbor
local WATER_TOP = -8
-- Parts can't be longer than 2048 studs, so long pieces are split
local MAX_PART_LENGTH = 1800

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

type Node = { id: string, position: Vector3, links: { string }, district: string }
type Edge = { a: string, b: string, kind: string }

local nodes: { [string]: Node } = {}
local edges: { Edge } = {}

-- `district` is stored on the RoadGraph node; police patrol beats stay in their district
local function node(id: string, x: number, z: number, district: string)
	nodes[id] = { id = id, position = Vector3.new(x, ROAD_TOP, z), links = {}, district = district }
end

local function link(a: string, b: string, kind: string)
	assert(nodes[a] and nodes[b], `missing road node {a} or {b}`)
	table.insert(nodes[a].links, b)
	table.insert(nodes[b].links, a)
	table.insert(edges, { a = a, b = b, kind = kind })
end

-- Downtown street grid
local GRID_X = { -480, -320, -160, 0, 160, 320, 480 }
local GRID_Z = { -480, -320, -160, 0, 160 }
-- Industrial truck-road grid; the last column is the dock road along the quay
local IND_X = { 2000, 2450, 2900, 3300 }
local IND_Z = { -1150, -700, -250, 250 }

local function gridId(xi: number, zi: number): string
	return `G{xi}_{zi}`
end

local function indId(xi: number, zi: number): string
	return `I{xi}_{zi}`
end

local function chain(kind: string, ids: { string })
	for i = 1, #ids - 1 do
		link(ids[i], ids[i + 1], kind)
	end
end

local function defineRoads()
	table.clear(nodes)
	table.clear(edges)

	-- Downtown: a full grid, so there's always another street to turn down
	for xi, x in GRID_X do
		for zi, z in GRID_Z do
			node(gridId(xi, zi), x, z, "Downtown")
		end
	end
	for zi = 1, #GRID_Z do
		for xi = 1, #GRID_X - 1 do
			link(gridId(xi, zi), gridId(xi + 1, zi), "street")
		end
	end
	for xi = 1, #GRID_X do
		for zi = 1, #GRID_Z - 1 do
			link(gridId(xi, zi), gridId(xi, zi + 1), "street")
		end
	end

	-- Industrial: wide roads and few intersections. Two missing links merge cells into the big
	-- Warehouse 9 lot (column 2, rows 1-2) and the Rail Yard (columns 1-2, row 3).
	for xi, x in IND_X do
		for zi, z in IND_Z do
			node(indId(xi, zi), x, z, "Industrial")
		end
	end
	for zi = 1, #IND_Z do
		for xi = 1, #IND_X - 1 do
			if not (xi == 2 and zi == 2) then
				link(indId(xi, zi), indId(xi + 1, zi), "wide")
			end
		end
	end
	for xi = 1, #IND_X do
		for zi = 1, #IND_Z - 1 do
			if not (xi == 2 and zi == 3) then
				link(indId(xi, zi), indId(xi, zi + 1), "wide")
			end
		end
	end

	-- the highway: west outskirts, past downtown's south edge, over the river into the industrial district
	local highway = {
		{ "HW1", -3300, 300 },
		{ "HW2", -2500, 470 },
		{ "HW3", -1700, 520 },
		{ "HW4", -1000, 460 },
		{ "H2", -480, 420 },
		{ "H3", -160, 420 },
		{ "H4", 160, 420 },
		{ "H5", 480, 420 },
		{ "HE1", 1000, 440 },
		{ "HE2", 1600, 380 },
	}
	local highwayIds = {}
	for _, h in highway do
		node(h[1], h[2], h[3], "Highway")
		table.insert(highwayIds, h[1])
	end
	chain("highway", highwayIds)
	link("HE2", indId(1, 4), "highway")
	-- on-ramps from the downtown grid
	link(gridId(1, 5), "H2", "street")
	link(gridId(3, 5), "H3", "street")
	link(gridId(5, 5), "H4", "street")
	link(gridId(7, 5), "H5", "street")

	-- Harbor Road: the direct two-lane route east
	node("HR1", 850, -160, "Outskirts")
	node("HR2", 1500, -300, "Outskirts")
	chain("street", { gridId(7, 3), "HR1", "HR2", indId(1, 3) })

	-- Ridge Road: north out of downtown, over the river, into the back of the industrial district
	node("N1", 0, -950, "Outskirts")
	node("N2", 500, -1450, "Outskirts")
	node("N3", 1350, -1650, "Outskirts")
	chain("street", { gridId(4, 1), "N1", "N2", "N3", indId(1, 1) })

	-- Old Mill Road: west through the woods to the cabins, looping back to the highway
	node("W1", -1050, -220, "Outskirts")
	node("W2", -1650, -420, "Outskirts")
	node("W3", -2300, -360, "Outskirts")
	node("W4", -2900, -560, "Outskirts")
	node("W5", -3400, -150, "Outskirts")
	chain("street", { gridId(1, 3), "W1", "W2", "W3", "W4", "W5", "HW1" })

	-- dirt roads: the sawmill and quarry loop across the north, joining Ridge Road
	node("WD", -1000, -900, "Outskirts")
	node("D1", -1800, -1000, "Outskirts")
	node("D2", -2200, -1500, "Outskirts")
	node("D3", -1500, -1950, "Outskirts")
	node("D4", -800, -2100, "Outskirts")
	node("D5", -300, -1600, "Outskirts")
	chain("dirt", { gridId(1, 1), "WD", "D1" })
	chain("dirt", { "W2", "D1", "D2", "D3", "D4", "D5", "N1" })

	-- farm roads across the south, from the west highway round to the airstrip and the industrial district
	node("S1", -1600, 1250, "Outskirts")
	node("S2", -800, 1700, "Outskirts")
	node("S3", 200, 1750, "Outskirts")
	node("S4", 1000, 1500, "Outskirts")
	node("S5", 160, 1000, "Outskirts")
	node("S6", 1700, 1300, "Outskirts")
	chain("street", { "HW3", "S1", "S2", "S3", "S4", "HE1" })
	chain("dirt", { "H4", "S5", "S3" })
	chain("street", { "S4", "S6", "HE2" })
end

local function edgeWidth(kind: string): number
	return if kind == "highway"
		then HIGHWAY_WIDTH
		elseif kind == "dirt" then DIRT_WIDTH
		elseif kind == "wide" then WIDE_WIDTH
		else STREET_WIDTH
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

-- Railings, a deck and two piers where a road crosses the river.
local function bridge(parent: Instance, a: Vector3, b: Vector3, width: number)
	if math.min(a.X, b.X) > RIVER_X1 or math.max(a.X, b.X) < RIVER_X0 then
		return
	end
	-- the stretch of the edge over the water, with a little extra on each bank
	local function at(x: number): Vector3
		local t = math.clamp((x - a.X) / (b.X - a.X), 0, 1)
		return a:Lerp(b, t)
	end
	local p0, p1 = at(RIVER_X0 - 12), at(RIVER_X1 + 12)
	local length = (p1 - p0).Magnitude
	local mid = (p0 + p1) / 2
	local cf = CFrame.lookAt(Vector3.new(mid.X, ROAD_TOP, mid.Z), Vector3.new(p1.X, ROAD_TOP, p1.Z))
	part(parent, {
		Name = "BridgeDeck",
		Size = Vector3.new(width + 4, 3, length),
		CFrame = cf * CFrame.new(0, -2.5, 0),
		Color = Palette.Curb,
	})
	for _, side in { -1, 1 } do
		part(parent, {
			Name = "BridgeRail",
			Size = Vector3.new(1.2, 3.5, length),
			CFrame = cf * CFrame.new(side * (width / 2 + 1.4), 1.75, 0),
			Color = Palette.Sidewalk,
		})
	end
	for _, z in { -length / 4, length / 4 } do
		part(parent, {
			Name = "BridgePier",
			Size = Vector3.new(width * 0.6, 22, 6),
			CFrame = cf * CFrame.new(0, -14, z),
			Color = Palette.Curb,
		})
	end
end

local function buildRoads(map: Instance)
	local roads = Instance.new("Folder")
	roads.Name = "Roads"

	for _, edge in edges do
		local a, b = nodes[edge.a].position, nodes[edge.b].position
		local width = edgeWidth(edge.kind)
		local total = (b - a).Magnitude
		local color = if edge.kind == "dirt" then Palette.Dirt else Palette.Asphalt
		-- long edges are laid in pieces (a part can't be longer than 2048 studs)
		local pieces = math.ceil(total / MAX_PART_LENGTH)
		for piece = 1, pieces do
			local pa, pb = a:Lerp(b, (piece - 1) / pieces), a:Lerp(b, piece / pieces)
			local length = (pb - pa).Magnitude
			local mid = (pa + pb) / 2
			local cf = CFrame.lookAt(Vector3.new(mid.X, ROAD_TOP - 0.5, mid.Z), Vector3.new(pb.X, ROAD_TOP - 0.5, pb.Z))
			part(roads, {
				Name = "Road",
				Size = Vector3.new(width, 1, length + width * 0.5),
				CFrame = cf,
				Color = color,
				CastShadow = false,
			})

			-- markings stop short of the junctions at the edge's two ends
			local trimStart = if piece == 1 then width / 2 + 2 else 0
			local trimEnd = if piece == pieces then width / 2 + 2 else 0
			local lineLength = length - trimStart - trimEnd
			local lineCf = cf * CFrame.new(0, 0.55, (trimEnd - trimStart) / 2)
			if (edge.kind == "street" or edge.kind == "wide") and lineLength > 0 then
				part(roads, {
					Name = "CenterLine",
					Size = Vector3.new(0.6, 0.1, lineLength),
					CFrame = lineCf,
					Color = Palette.LineYellow,
					CastShadow = false,
				})
			elseif edge.kind == "highway" and lineLength > 0 then
				for _, x in { -0.6, 0.6 } do
					part(roads, {
						Name = "CenterLine",
						Size = Vector3.new(0.5, 0.1, lineLength),
						CFrame = lineCf * CFrame.new(x, 0, 0),
						Color = Palette.LineYellow,
						CastShadow = false,
					})
				end
				for _, side in { -1, 1 } do
					part(roads, {
						Name = "EdgeLine",
						Size = Vector3.new(0.6, 0.1, lineLength),
						CFrame = lineCf * CFrame.new(side * (width / 2 - 2), 0, 0),
						Color = Palette.LineWhite,
						CastShadow = false,
					})
					-- sparse lane dashes: the highway is long and every dash is a part
					local dashes = math.floor(lineLength / 48)
					for i = 0, dashes - 1 do
						local z = -lineLength / 2 + 24 + i * 48
						part(roads, {
							Name = "LaneDash",
							Size = Vector3.new(0.5, 0.1, 12),
							CFrame = lineCf * CFrame.new(side * width / 4, 0, z),
							Color = Palette.LineWhite,
							CastShadow = false,
						})
					end
				end
			end
		end
		bridge(roads, a, b, width)
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
	-- kind ("street", "wide", "highway", "dirt") in the same order as Links, and District names the
	-- node's district ("Downtown", "Industrial", "Highway", "Outskirts") for police patrol beats
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
		value:SetAttribute("District", n.district)
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

-- Rolling hills in the outskirts: terrain balls sunk into the ground, kept clear of roads and
-- points of interest. Trees on a hill sit on its surface (see groundHeight).
type Hill = { center: Vector3, radius: number }
local hills: { Hill } = {}

-- spots kept free of trees and hills: rest stop, sawmill, cabins, quarry, farm, airstrip, motel strip
local CLEARINGS = {
	{ -2040, 540, -1860, 680 },
	{ -2420, -1760, -2140, -1520 },
	{ -3080, -820, -2740, -600 },
	{ -980, -2460, -520, -2120 },
	{ -1150, 1740, -620, 2080 },
	{ 1420, 1380, 2420, 1700 },
	{ -460, 180, 260, 360 },
}

local function inClearing(p: Vector3, margin: number?): boolean
	local m = margin or 0
	for _, r in CLEARINGS do
		if p.X > r[1] - m and p.X < r[3] + m and p.Z > r[2] - m and p.Z < r[4] + m then
			return true
		end
	end
	return false
end

local function inRiver(p: Vector3, margin: number): boolean
	return p.X > RIVER_X0 - margin and p.X < RIVER_X1 + margin
end

-- Which district a point belongs to, for scattering trees and hills.
local function inTown(p: Vector3, margin: number): boolean
	local downtown = p.X > GRID_X[1] - margin and p.X < GRID_X[#GRID_X] + margin and p.Z > GRID_Z[1] - margin and p.Z < 440 + margin
	local industrial = p.X > IND_X[1] - margin and p.Z > IND_Z[1] - margin and p.Z < IND_Z[#IND_Z] + margin
	return downtown or industrial
end

local function groundHeight(x: number, z: number): number
	local y = GROUND_Y
	for _, hill in hills do
		local dx, dz = x - hill.center.X, z - hill.center.Z
		local d2 = dx * dx + dz * dz
		if d2 < hill.radius * hill.radius then
			y = math.max(y, hill.center.Y + math.sqrt(hill.radius * hill.radius - d2))
		end
	end
	return y
end

local function buildGround(map: Instance)
	local ground = Instance.new("Folder")
	ground.Name = "Ground"

	-- grass in tiles (parts max out at 2048 studs), with a gap for the river and ending at the coast
	local spans = {
		{ WORLD_X0, RIVER_X0, 3 },
		{ RIVER_X1, COAST_X, 2 },
	}
	local zTiles = 3
	for _, span in spans do
		local x0, x1, count = span[1], span[2], span[3]
		local w = (x1 - x0) / count
		local d = (WORLD_Z1 - WORLD_Z0) / zTiles
		for i = 0, count - 1 do
			for j = 0, zTiles - 1 do
				part(ground, {
					Name = "Grass",
					Size = Vector3.new(w, 8, d),
					Position = Vector3.new(x0 + w * (i + 0.5), GROUND_Y - 4, WORLD_Z0 + d * (j + 0.5)),
					Color = Palette.Grass,
					CastShadow = false,
				})
			end
		end
	end

	local terrain = workspace.Terrain
	terrain:Clear()
	terrain.WaterColor = Palette.Water
	terrain.WaterTransparency = 0.6
	terrain.WaterReflectance = 0.25
	terrain.WaterWaveSize = 0.08
	terrain.WaterWaveSpeed = 6
	terrain:SetMaterialColor(Enum.Material.Grass, Palette.Grass)
	terrain:SetMaterialColor(Enum.Material.Sand, Palette.Dirt)

	-- water in z slices so each fill stays a manageable size; players can swim back to the quay
	local depth = 16
	local slices = 4
	local sliceDepth = (WORLD_Z1 - WORLD_Z0 + 200) / slices
	for i = 0, slices - 1 do
		local z = WORLD_Z0 - 100 + sliceDepth * (i + 0.5)
		for _, body in { { COAST_X, WORLD_X1 + 100 }, { RIVER_X0, RIVER_X1 } } do
			local width = body[2] - body[1]
			local x = (body[1] + body[2]) / 2
			terrain:FillBlock(CFrame.new(x, WATER_TOP - depth / 2, z), Vector3.new(width, depth, sliceDepth), Enum.Material.Water)
			terrain:FillBlock(CFrame.new(x, WATER_TOP - depth - 2, z), Vector3.new(width + 40, 4, sliceDepth), Enum.Material.Sand)
		end
		task.wait()
	end

	-- hills: balls sunk 60% into the ground, so each is a mound 0.8 radius across
	table.clear(hills)
	local attempts = 0
	while #hills < 26 and attempts < 600 do
		attempts += 1
		local radius = rng:NextNumber(110, 220)
		local p = Vector3.new(rng:NextNumber(WORLD_X0 + 150, COAST_X - 300), 0, rng:NextNumber(WORLD_Z0 + 150, WORLD_Z1 - 150))
		local footprint = radius * 0.8
		if
			not nearRoad(p, footprint + 20)
			and not inClearing(p, footprint)
			and not inRiver(p, footprint + 30)
			and not inTown(p, footprint + 60)
		then
			local center = Vector3.new(p.X, GROUND_Y - radius * 0.6, p.Z)
			table.insert(hills, { center = center, radius = radius })
			terrain:FillBall(center, radius, Enum.Material.Grass)
			task.wait()
		end
	end

	-- invisible map bounds, in pieces short enough to be parts
	local function wall(from: Vector3, to: Vector3)
		local length = (to - from).Magnitude
		local pieces = math.ceil(length / MAX_PART_LENGTH)
		for i = 1, pieces do
			local a, b = from:Lerp(to, (i - 1) / pieces), from:Lerp(to, i / pieces)
			part(ground, {
				Name = "Boundary",
				Size = Vector3.new(10, 300, (b - a).Magnitude),
				CFrame = CFrame.lookAt((a + b) / 2, b),
				Transparency = 1,
				CanQuery = false,
				CastShadow = false,
			})
		end
	end
	local y = 100
	wall(Vector3.new(WORLD_X0, y, WORLD_Z0), Vector3.new(WORLD_X1, y, WORLD_Z0))
	wall(Vector3.new(WORLD_X0, y, WORLD_Z1), Vector3.new(WORLD_X1, y, WORLD_Z1))
	wall(Vector3.new(WORLD_X0, y, WORLD_Z0), Vector3.new(WORLD_X0, y, WORLD_Z1))
	wall(Vector3.new(WORLD_X1, y, WORLD_Z0), Vector3.new(WORLD_X1, y, WORLD_Z1))
	flush(ground, map)
end

-- Downtown blocks by grid cell ("xi_zi"); anything not listed is a regular downtown block.
-- Parks, plazas and lots break up the skyline so the grid reads as streets, not a maze.
local DOWNTOWN_SPECIAL: { [string]: string } = {
	["1_3"] = "police",
	["2_2"] = "park",
	["4_1"] = "parking", -- Parking Lot B
	["3_4"] = "parking",
	["5_2"] = "park",
	["6_1"] = "parking",
	["6_3"] = "park",
}

local function buildDowntown(map: Instance)
	local downtown = Instance.new("Folder")
	downtown.Name = "Downtown"
	for xi = 1, #GRID_X - 1 do
		for zi = 1, #GRID_Z - 1 do
			local x0, x1 = GRID_X[xi], GRID_X[xi + 1]
			local z0, z1 = GRID_Z[zi], GRID_Z[zi + 1]
			local special = DOWNTOWN_SPECIAL[`{xi}_{zi}`]
			if special == "park" then
				parkBlock(downtown, x0, z0, x1, z1)
			elseif special == "parking" then
				parkingBlock(downtown, x0, z0, x1, z1)
			elseif special == "police" then
				policeStationBlock(downtown, x0, z0, x1, z1)
			elseif zi == 4 or xi == 6 then
				lowBlock(downtown, x0, z0, x1, z1)
			elseif xi == 5 then
				-- the east column: older brick buildings
				local sx, sz = blockBase(downtown, x0, z0, x1, z1)
				building(
					downtown,
					Vector3.new((x0 + x1) / 2, SIDEWALK_TOP, (z0 + z1) / 2),
					Vector3.new(sx - 14, rng:NextNumber(24, 44), sz - 14),
					pick(Palette.Industrial),
					nil
				)
			else
				downtownBlock(downtown, x0, z0, x1, z1)
			end
		end
		task.wait()
	end
	for xi = 1, #GRID_X - 1 do
		for zi = 1, #GRID_Z do
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

-- A flush concrete pad over the grass between four road centre lines, so trucks can drive straight in.
local function lotPad(parent: Instance, x0: number, z0: number, x1: number, z1: number, color: Color3?): (number, number)
	local inset = WIDE_WIDTH / 2 + 2
	local sx, sz = (x1 - x0) - inset * 2, (z1 - z0) - inset * 2
	part(parent, {
		Name = "Lot",
		Size = Vector3.new(sx, 0.4, sz),
		Position = Vector3.new((x0 + x1) / 2, ROAD_TOP - 0.1, (z0 + z1) / 2),
		Color = color or Palette.Curb,
		CastShadow = false,
	})
	return sx, sz
end

local LOT_TOP = ROAD_TOP + 0.1

-- A semi trailer: a long box on a dark base.
local function trailer(parent: Instance, cf: CFrame, color: Color3)
	part(parent, {
		Name = "Trailer",
		Size = Vector3.new(8, 9, 30),
		CFrame = cf * CFrame.new(0, 6.5, 0),
		Color = color,
	})
	part(parent, {
		Name = "TrailerBase",
		Size = Vector3.new(7, 2, 28),
		CFrame = cf * CFrame.new(0, 1, 0),
		Color = Palette.Roof,
	})
end

local function waterTower(parent: Instance, position: Vector3)
	local model = Instance.new("Model")
	model.Name = "WaterTower"
	for _, offset in { Vector3.new(-8, 0, -8), Vector3.new(8, 0, -8), Vector3.new(-8, 0, 8), Vector3.new(8, 0, 8) } do
		part(model, {
			Name = "Leg",
			Size = Vector3.new(2, 60, 2),
			Position = position + offset + Vector3.new(0, 30, 0),
			Color = Palette.Roof,
		})
	end
	part(model, {
		Name = "Tank",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(26, 30, 30),
		CFrame = CFrame.new(position + Vector3.new(0, 72, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Palette.Industrial[1],
	})
	part(model, {
		Name = "Cap",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(30, 12, 30),
		Position = position + Vector3.new(0, 85, 0),
		Color = Palette.Industrial[2],
	})
	model.Parent = parent
end

local function buildIndustrial(map: Instance)
	local industrial = Instance.new("Folder")
	industrial.Name = "Industrial"
	local X, Z = IND_X, IND_Z

	-- A: truck depot, rows of parked trailers
	do
		lotPad(industrial, X[1], Z[1], X[2], Z[2])
		local cx, cz = (X[1] + X[2]) / 2, (Z[1] + Z[2]) / 2
		for i = -3, 3 do
			trailer(industrial, CFrame.new(cx + i * 22, LOT_TOP, cz - 90), pick(Palette.Containers))
			if i % 2 == 0 then
				trailer(industrial, CFrame.new(cx + i * 22, LOT_TOP, cz + 90), pick(Palette.Containers))
			end
		end
	end

	-- B: two warehouses facing a shared loading apron
	do
		lotPad(industrial, X[1], Z[2], X[2], Z[3])
		local cx, cz = (X[1] + X[2]) / 2, (Z[2] + Z[3]) / 2
		warehouse(industrial, Vector3.new(cx - 85, LOT_TOP, cz - 90), Vector3.new(120, 34, 110), Palette.Industrial[1], Vector3.new(0, 0, 1))
		warehouse(industrial, Vector3.new(cx + 85, LOT_TOP, cz - 90), Vector3.new(120, 28, 110), Palette.Industrial[3], Vector3.new(0, 0, 1))
	end

	-- C: the big Warehouse 9 lot, three warehouses on the west side opening onto an east yard
	do
		lotPad(industrial, X[2], Z[1], X[3], Z[3])
		local cx = (X[2] + X[3]) / 2
		for i, z in { -1040, -840, -640 } do
			warehouse(industrial, Vector3.new(cx - 95, LOT_TOP, z), Vector3.new(120, 34, 110), Palette.Industrial[(i % 4) + 1], Vector3.new(1, 0, 0))
		end
		for i = 0, 3 do
			trailer(industrial, CFrame.new(cx + 150, LOT_TOP, -460 + i * 20) * CFrame.Angles(0, math.rad(90), 0), pick(Palette.Containers))
		end
	end

	-- D: Cold Storage, one big white building with reefer trailers out front
	do
		lotPad(industrial, X[3], Z[1], X[4], Z[2])
		local cx, cz = (X[3] + X[4]) / 2, (Z[1] + Z[2]) / 2
		warehouse(industrial, Vector3.new(cx, LOT_TOP, cz - 80), Vector3.new(130, 34, 120), Palette.PoliceWhite, Vector3.new(0, 0, 1))
		for i = -1, 1 do
			trailer(industrial, CFrame.new(cx + 110 + i * 14, LOT_TOP, cz + 110), Palette.PoliceWhite)
		end
	end

	-- E: container stacks
	do
		lotPad(industrial, X[3], Z[2], X[4], Z[3])
		local cx, cz = (X[3] + X[4]) / 2, (Z[2] + Z[3]) / 2
		for row = -2, 2 do
			for col = -1, 1 do
				for stack = 1, rng:NextInteger(1, 3) do
					container(industrial, CFrame.new(cx + col * 60 + row * 10, LOT_TOP + 4.3 + (stack - 1) * 8.6, cz + row * 34) * CFrame.Angles(0, math.rad(90), 0))
				end
			end
		end
	end

	-- F: the Rail Yard, three tracks of boxcars and the water tower
	do
		lotPad(industrial, X[1], Z[3], X[3], Z[4], Palette.AsphaltLight)
		local cx = (X[1] + X[3]) / 2
		for t, z in { -150, -90, -30 } do
			part(industrial, {
				Name = "TrackBed",
				Size = Vector3.new(800, 0.4, 12),
				Position = Vector3.new(cx, LOT_TOP + 0.1, z),
				Color = Palette.Dirt,
				CastShadow = false,
			})
			for _, offset in { -2.6, 2.6 } do
				part(industrial, {
					Name = "Rail",
					Size = Vector3.new(800, 0.5, 0.5),
					Position = Vector3.new(cx, LOT_TOP + 0.5, z + offset),
					Color = Palette.Roof,
					CastShadow = false,
				})
			end
			for car = 0, 2 + t do
				container(industrial, CFrame.new(cx - 300 + car * 32 + t * 60, LOT_TOP + 5.3, z) * CFrame.Angles(0, math.rad(90), 0))
			end
		end
		building(industrial, Vector3.new(X[1] + 90, LOT_TOP, 120), Vector3.new(50, 18, 40), Palette.Industrial[2], Vector3.new(0, 0, -1))
		waterTower(industrial, Vector3.new(X[3] - 80, LOT_TOP, 150))
	end

	-- G: dockside warehouse
	do
		lotPad(industrial, X[3], Z[3], X[4], Z[4])
		local cx, cz = (X[3] + X[4]) / 2, (Z[3] + Z[4]) / 2
		warehouse(industrial, Vector3.new(cx, LOT_TOP, cz - 70), Vector3.new(130, 28, 120), Palette.Industrial[4], Vector3.new(0, 0, 1))
	end

	-- the quay between the dock road and the sea
	local quayX0 = X[4] + WIDE_WIDTH / 2 + 2
	local quayWidth = COAST_X - quayX0
	local quayX = quayX0 + quayWidth / 2
	part(industrial, {
		Name = "Quay",
		Size = Vector3.new(quayWidth, 2, 1600),
		Position = Vector3.new(quayX, SIDEWALK_TOP - 1, -450),
		Color = Palette.Curb,
		CastShadow = false,
	})
	-- piers start exactly at the quay's edge: overlapping it with the same top height made the
	-- two surfaces z-fight
	local pierStart, pierEnd = COAST_X, COAST_X + 280
	for _, z in { -1000, -550, -100 } do
		part(industrial, {
			Name = "Pier",
			Size = Vector3.new(pierEnd - pierStart, 1.5, 24),
			Position = Vector3.new((pierStart + pierEnd) / 2, SIDEWALK_TOP - 0.75, z),
			Color = Palette.Wood,
		})
		for px = pierStart + 20, pierEnd - 10, 30 do
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
	crane(industrial, Vector3.new(quayX, SIDEWALK_TOP, -780))
	crane(industrial, Vector3.new(quayX, SIDEWALK_TOP, -330))
	-- the container yard at the south end of the quay
	for i = 0, 5 do
		for stack = 1, 1 + (i % 2) do
			container(industrial, CFrame.new(quayX + 30, SIDEWALK_TOP + 4.3 + (stack - 1) * 8.6, 40 + i * 28) * CFrame.Angles(0, math.rad(90), 0))
		end
	end

	-- lighthouse at the end of the north pier: the landmark you see from the highway bridge
	local lighthouse = Instance.new("Model")
	lighthouse.Name = "Lighthouse"
	local base = Vector3.new(pierEnd - 10, SIDEWALK_TOP, -1000)
	part(lighthouse, {
		Name = "Tower",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(50, 12, 12),
		CFrame = CFrame.new(base + Vector3.new(0, 25, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Palette.PoliceWhite,
	})
	part(lighthouse, {
		Name = "Band",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(8, 12.4, 12.4),
		CFrame = CFrame.new(base + Vector3.new(0, 30, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Palette.Containers[1],
	})
	local lamp = part(lighthouse, {
		Name = "Lamp",
		Size = Vector3.new(7, 6, 7),
		Position = base + Vector3.new(0, 53, 0),
		Color = Color3.fromRGB(255, 236, 190),
		Material = Enum.Material.Neon,
		CastShadow = false,
	})
	local light = Instance.new("PointLight")
	light.Range = 60
	light.Brightness = 3
	light.Color = Color3.fromRGB(255, 220, 170)
	light.Enabled = false
	light.Parent = lamp
	CollectionService:AddTag(lamp, "StreetLight")
	lighthouse.Parent = industrial
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

	-- highway rest stop, out west where the woods start
	part(south, {
		Name = "RestStopLot",
		Size = Vector3.new(120, 0.4, 50),
		Position = Vector3.new(-1950, ROAD_TOP - 0.2, 590),
		Color = Palette.AsphaltLight,
		CastShadow = false,
	})
	building(south, Vector3.new(-1950, ROAD_TOP, 630), Vector3.new(40, 14, 20), Palette.Buildings[5], Vector3.new(0, 0, -1))
	flush(south, map)
end

-- How likely a random point is to get a tree: dense woods to the west, thinner to the north,
-- scattered tree lines across the southern farmland.
local function treeDensity(p: Vector3): number
	if p.X < -900 and p.Z < 800 then
		return 1
	elseif p.Z < -800 and p.X < RIVER_X0 then
		return 0.6
	elseif p.X > RIVER_X1 and p.Z < IND_Z[1] - 150 then
		return 0.5
	elseif p.Z > 800 then
		return 0.12
	elseif p.X > GRID_X[#GRID_X] and p.X < IND_X[1] then
		return 0.25
	end
	return 0
end

local function cabin(parent: Instance, position: Vector3, facing: Vector3)
	local model = Instance.new("Model")
	model.Name = "Cabin"
	local cf = CFrame.lookAt(position, position + facing)
	part(model, { Name = "Body", Size = Vector3.new(18, 11, 14), CFrame = cf * CFrame.new(0, 5.5, 0), Color = Palette.Wood })
	part(model, { Name = "Roof", Size = Vector3.new(21, 1.6, 17), CFrame = cf * CFrame.new(0, 11.8, 0), Color = Palette.Roof })
	part(model, { Name = "Door", Size = Vector3.new(4, 7, 0.4), CFrame = cf * CFrame.new(0, 3.5, -7.1), Color = Palette.Trunk })
	part(model, { Name = "Chimney", Size = Vector3.new(2.5, 6, 2.5), CFrame = cf * CFrame.new(6, 14, 3), Color = Palette.Rock })
	model.Parent = parent
end

local function barn(parent: Instance, position: Vector3)
	local model = Instance.new("Model")
	model.Name = "Barn"
	local red = Color3.fromRGB(150, 54, 44)
	part(model, { Name = "Body", Size = Vector3.new(50, 24, 36), Position = position + Vector3.new(0, 12, 0), Color = red })
	part(model, { Name = "Roof", Size = Vector3.new(54, 3, 40), Position = position + Vector3.new(0, 25.5, 0), Color = Palette.Roof })
	part(model, { Name = "BarnDoor", Size = Vector3.new(16, 16, 0.4), Position = position + Vector3.new(0, 8, -18.2), Color = Color3.fromRGB(235, 228, 214) })
	part(model, {
		Name = "Silo",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(44, 14, 14),
		CFrame = CFrame.new(position + Vector3.new(36, 22, 6)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Palette.Sidewalk,
	})
	model.Parent = parent
end

local function radioTower(parent: Instance, position: Vector3)
	local model = Instance.new("Model")
	model.Name = "RadioTower"
	part(model, { Name = "Mast", Size = Vector3.new(4, 220, 4), Position = position + Vector3.new(0, 110, 0), Color = Palette.Containers[1] })
	for i = 1, 4 do
		part(model, { Name = "Band", Size = Vector3.new(4.4, 10, 4.4), Position = position + Vector3.new(0, i * 44, 0), Color = Palette.PoliceWhite })
	end
	part(model, {
		Name = "Beacon",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(4, 4, 4),
		Position = position + Vector3.new(0, 222, 0),
		Color = Color3.fromRGB(255, 60, 50),
		Material = Enum.Material.Neon,
		CastShadow = false,
	})
	part(model, { Name = "Shed", Size = Vector3.new(14, 9, 12), Position = position + Vector3.new(12, 4.5, 0), Color = Palette.Sidewalk })
	model.Parent = parent
end

local function billboard(parent: Instance, position: Vector3, facing: Vector3, text: string)
	local cf = CFrame.lookAt(position, position + facing)
	for _, x in { -14, 14 } do
		part(parent, { Name = "BillboardPost", Size = Vector3.new(1.6, 30, 1.6), CFrame = cf * CFrame.new(x, 15, 0.8), Color = Palette.Roof })
	end
	local board = part(parent, { Name = "Billboard", Size = Vector3.new(44, 16, 1), CFrame = cf * CFrame.new(0, 34, 0), Color = Palette.Containers[3] })
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.CanvasSize = Vector2.new(440, 160)
	gui.LightInfluence = 0.4
	gui.Parent = board
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 248, 230)
	label.Parent = gui
end

local function buildOutskirts(map: Instance)
	local outskirts = Instance.new("Folder")
	outskirts.Name = "Outskirts"

	-- farm fields: big flat patches of crop color across the south
	local fieldColors = { Color3.fromRGB(196, 170, 92), Color3.fromRGB(120, 150, 70), Color3.fromRGB(150, 120, 80) }
	local fields = 0
	local attempts = 0
	while fields < 12 and attempts < 300 do
		attempts += 1
		local size = Vector3.new(rng:NextNumber(160, 280), 0.3, rng:NextNumber(160, 280))
		local p = Vector3.new(rng:NextNumber(-3400, RIVER_X0 - 200), GROUND_Y, rng:NextNumber(900, WORLD_Z1 - 200))
		local clear = not inClearing(p, math.max(size.X, size.Z) / 2) and groundHeight(p.X, p.Z) <= GROUND_Y
		for _, corner in {
			Vector3.new(-1, 0, -1), Vector3.new(1, 0, -1), Vector3.new(-1, 0, 1), Vector3.new(1, 0, 1),
			Vector3.new(-1, 0, 0), Vector3.new(1, 0, 0), Vector3.new(0, 0, -1), Vector3.new(0, 0, 1), Vector3.zero,
		} do
			if nearRoad(p + corner * size / 2, 12) then
				clear = false
			end
		end
		if clear then
			part(outskirts, {
				Name = "Field",
				Size = size,
				Position = p + Vector3.new(0, 0.1, 0),
				Color = pick(fieldColors),
				Material = Enum.Material.Grass,
				CastShadow = false,
			})
			fields += 1
		end
	end
	task.wait()

	-- trees and rocks, in groves: clumps read as woods from the road for far fewer parts than an
	-- even scatter
	local placed = 0
	attempts = 0
	while placed < 1100 and attempts < 4000 do
		attempts += 1
		local center = Vector3.new(rng:NextNumber(WORLD_X0 + 40, COAST_X - 60), GROUND_Y, rng:NextNumber(WORLD_Z0 + 40, WORLD_Z1 - 40))
		if rng:NextNumber() < treeDensity(center) then
			local radius = rng:NextNumber(40, 110)
			for _ = 1, rng:NextInteger(6, 16) do
				local angle = rng:NextNumber() * math.pi * 2
				local r = math.sqrt(rng:NextNumber()) * radius
				local p = center + Vector3.new(math.cos(angle) * r, 0, math.sin(angle) * r)
				if not nearRoad(p, 10) and not inClearing(p) and not inRiver(p, 10) and not inTown(p, 30) and p.X < COAST_X - 30 then
					p = Vector3.new(p.X, groundHeight(p.X, p.Z) - 0.5, p.Z)
					if rng:NextNumber() < 0.08 then
						rock(outskirts, p, rng:NextNumber(0.6, 1.6))
					else
						tree(outskirts, p, rng:NextNumber(0.8, 1.5))
					end
					placed += 1
				end
			end
			task.wait()
		end
	end

	-- the Old Sawmill clearing; the shed opens east, toward the log pile
	local millCenter = Vector3.new(-2300, GROUND_Y, -1650)
	local millTemplate = buildingTemplate("Sawmill")
	local mill = if millTemplate
		then placeTemplate(outskirts, millTemplate, millCenter, Vector3.new(1, 0, 0))
		else Instance.new("Model")
	mill.Name = "OldSawmill"
	if not millTemplate then
		part(mill, { Name = "Shed", Size = Vector3.new(44, 18, 28), Position = millCenter + Vector3.new(0, 9, 0), Color = Palette.Wood })
		part(mill, { Name = "Roof", Size = Vector3.new(48, 2, 32), Position = millCenter + Vector3.new(0, 19, 0), Color = Palette.Industrial[3] })
	end
	for i = 0, 4 do
		part(mill, {
			Name = "Log",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(20, 3, 3),
			Position = millCenter + Vector3.new(35, 1.5 + (i % 2) * 2.6, 25 + i * 3.2),
			Color = Palette.Trunk,
		})
	end
	mill.Parent = outskirts

	-- Pine Ridge Cabins, off Old Mill Road
	cabin(outskirts, Vector3.new(-2980, GROUND_Y, -740), Vector3.new(0.4, 0, 1))
	cabin(outskirts, Vector3.new(-2900, GROUND_Y, -770), Vector3.new(0, 0, 1))
	cabin(outskirts, Vector3.new(-2810, GROUND_Y, -735), Vector3.new(-0.4, 0, 1))

	-- the Gravel Quarry at the top of the dirt loop
	part(outskirts, {
		Name = "Lot",
		Size = Vector3.new(380, 0.4, 280),
		Position = Vector3.new(-750, GROUND_Y + 0.1, -2270),
		Color = Palette.Dirt,
		Material = Enum.Material.Ground,
		CastShadow = false,
	})
	for _ = 1, 10 do
		rock(outskirts, Vector3.new(-750 + rng:NextNumber(-170, 170), GROUND_Y, -2340 + rng:NextNumber(-60, 40)), rng:NextNumber(1.5, 3.5))
	end
	building(outskirts, Vector3.new(-860, GROUND_Y, -2180), Vector3.new(40, 14, 20), Palette.Industrial[3], Vector3.new(0, 0, 1))

	-- Farmstead Barn on the south farm road
	part(outskirts, {
		Name = "Lot",
		Size = Vector3.new(200, 0.4, 140),
		Position = Vector3.new(-880, GROUND_Y + 0.1, 1850),
		Color = Palette.Dirt,
		Material = Enum.Material.Ground,
		CastShadow = false,
	})
	barn(outskirts, Vector3.new(-900, GROUND_Y, 1930))

	-- Old Airstrip: a runway and a hangar facing it
	part(outskirts, {
		Name = "Runway",
		Size = Vector3.new(900, 0.4, 70),
		Position = Vector3.new(1900, ROAD_TOP - 0.1, 1450),
		Color = Palette.Asphalt,
		CastShadow = false,
	})
	for i = 0, 14 do
		part(outskirts, {
			Name = "RunwayDash",
			Size = Vector3.new(24, 0.1, 1.2),
			Position = Vector3.new(1490 + i * 60, ROAD_TOP + 0.15, 1450),
			Color = Palette.LineWhite,
			CastShadow = false,
		})
	end
	part(outskirts, {
		Name = "Lot",
		Size = Vector3.new(220, 0.4, 120),
		Position = Vector3.new(1900, ROAD_TOP - 0.1, 1560),
		Color = Palette.AsphaltLight,
		CastShadow = false,
	})
	warehouse(outskirts, Vector3.new(2060, ROAD_TOP + 0.1, 1610), Vector3.new(120, 28, 110), Palette.Industrial[2], Vector3.new(0, 0, -1))

	-- landmarks to steer by
	radioTower(outskirts, Vector3.new(650, GROUND_Y, -1150))
	billboard(outskirts, Vector3.new(760, GROUND_Y, 360), Vector3.new(0, 0, 1), "PORT EAST · NEXT EXIT")
	billboard(outskirts, Vector3.new(-1300, GROUND_Y, 400), Vector3.new(0, 0, 1), "PINE RIDGE CABINS")
	flush(outskirts, map)
end

---------------------------------------------------------------------------------------------------
-- Job points
---------------------------------------------------------------------------------------------------

-- Names show to players and pair pickups with contracts, so keep them unique. `district` is
-- copied to the part's District attribute (JobService and the phone read it).
local JOB_POINTS = {
	-- pickups: a contact waits at each one while a contract needs it (JobService spawns them)
	{ name = "Parking Lot B", tag = "Pickup", district = "Downtown", position = Vector3.new(80, SIDEWALK_TOP + 0.2, -400) },
	{ name = "Rail Yard", tag = "Pickup", district = "Industrial", position = Vector3.new(2200, ROAD_TOP + 0.1, 120) },
	{ name = "Cold Storage", tag = "Pickup", district = "Industrial", position = Vector3.new(3100, ROAD_TOP + 0.1, -860) },
	{ name = "Pier 4", tag = "Pickup", district = "Docks", position = Vector3.new(3640, SIDEWALK_TOP, -550) },
	{ name = "Old Sawmill", tag = "Pickup", district = "Outskirts", position = Vector3.new(-2250, GROUND_Y, -1590) },
	{ name = "Pine Ridge Cabins", tag = "Pickup", district = "Outskirts", position = Vector3.new(-2900, GROUND_Y, -660) },
	{ name = "Gravel Quarry", tag = "Pickup", district = "Outskirts", position = Vector3.new(-750, GROUND_Y + 0.3, -2210) },
	-- dropoffs
	{ name = "Sunset Motel", tag = "Dropoff", district = "Downtown", position = Vector3.new(110, ROAD_TOP, 250) },
	{ name = "Gas Station", tag = "Dropoff", district = "Downtown", position = Vector3.new(-330, ROAD_TOP, 220) },
	{ name = "Back Alley", tag = "Dropoff", district = "Downtown", position = Vector3.new(-400, SIDEWALK_TOP, 120) },
	{ name = "Warehouse 9", tag = "Dropoff", district = "Industrial", position = Vector3.new(2750, ROAD_TOP + 0.1, -840) },
	{ name = "Container Yard", tag = "Dropoff", district = "Docks", position = Vector3.new(3370, SIDEWALK_TOP, 120) },
	{ name = "Highway Rest Stop", tag = "Dropoff", district = "Outskirts", position = Vector3.new(-1950, ROAD_TOP, 590) },
	{ name = "Farmstead Barn", tag = "Dropoff", district = "Outskirts", position = Vector3.new(-900, GROUND_Y + 0.3, 1860) },
	{ name = "Old Airstrip", tag = "Dropoff", district = "Outskirts", position = Vector3.new(1840, ROAD_TOP + 0.1, 1540) },
}

local function buildJobPoints(map: Instance)
	local points = Instance.new("Folder")
	points.Name = "JobPoints"
	for _, def in JOB_POINTS do
		local isPickup = def.tag == "Pickup"
		-- Persistent, so the phone and GPS can always find the point however far away it is
		-- (the place streams the rest of the map in and out)
		local holder = Instance.new("Model")
		holder.Name = def.name
		holder.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
		-- pickups are an invisible marker where the contact stands; dropoffs keep the glowing pad
		local pad = part(holder, {
			Name = def.name,
			Size = Vector3.new(16, 0.3, 16),
			Position = def.position + Vector3.new(0, 0.15, 0),
			Color = if isPickup then Palette.Pickup else Palette.Dropoff,
			Material = if isPickup then Enum.Material.SmoothPlastic else Enum.Material.Neon,
			Transparency = if isPickup then 1 else 0.35,
			CanCollide = false,
			CanQuery = false,
			CastShadow = false,
		})
		pad:SetAttribute("District", def.district)
		CollectionService:AddTag(pad, if isPickup then Config.Tags.Pickup else Config.Tags.Dropoff)
		holder.Parent = points
		if isPickup then
			crateStack(points, def.position + Vector3.new(11, 0, 0), 3)
		end
	end
	flush(points, map)
end

-- The GPS draws the map from these: the place streams parts in and out, but plain values always
-- replicate. One Vector3Value per area part (Value = position) with Kind, Size and Yaw attributes.
local GPS_AREAS: { [string]: string } = {
	Grass = "land",
	Sidewalk = "block",
	Lawn = "park",
	Lot = "lot",
	MotelLot = "lot",
	GasLot = "lot",
	RestStopLot = "lot",
	Runway = "lot",
	Field = "field",
	Quay = "quay",
	Pier = "pier",
}

local function buildGpsAreas(map: Instance)
	local areas = Instance.new("Folder")
	areas.Name = "GpsAreas"
	for _, d in map:GetDescendants() do
		local kind = d:IsA("BasePart") and GPS_AREAS[d.Name]
		if kind then
			local p = d :: BasePart
			local _, yaw, _ = p.CFrame:ToOrientation()
			local value = Instance.new("Vector3Value")
			value.Name = p.Name
			value.Value = p.Position
			value:SetAttribute("Kind", kind)
			value:SetAttribute("Size", Vector2.new(p.Size.X, p.Size.Z))
			value:SetAttribute("Yaw", yaw)
			value.Parent = areas
		end
	end
	areas.Parent = map
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
	buildOutskirts(map)
	buildJobPoints(map)
	buildGpsAreas(map)
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
