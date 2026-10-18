--!strict
-- The phone's GPS app: a heading-up map of the city drawn from Workspace.Map (blocks, parks,
-- lots, the quay and the RoadGraph roads), the player arrow, a route to the current destination
-- along the road graph, turn-by-turn directions, and a speed limit sign beside the current speed.
-- PhoneController builds it into a page and sets the destination from the active contract.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Theme = require(script.Parent.Theme)

local player = Players.LocalPlayer
local C = Theme.Colors
local F = Theme.Fonts

local GpsApp = {}

-- map pixels per stud before zoom; the UIScale zooms out with speed
local SCALE = 0.5
local ZOOM_ON_FOOT = 0.75
local ZOOM_DRIVING = 0.45
local LIMIT_MPH = math.floor(Config.Heat.SpeedingThreshold * Config.Vehicles.MphPerStud + 0.5)
local ROAD_WIDTH = { street = 36, wide = 48, highway = 56, dirt = 28 }
local MAP_COLORS = {
	water = Color3.fromRGB(22, 40, 62),
	land = Color3.fromRGB(26, 30, 36),
	block = Color3.fromRGB(42, 46, 56),
	park = Color3.fromRGB(34, 62, 46),
	field = Color3.fromRGB(44, 52, 38),
	lot = Color3.fromRGB(36, 39, 48),
	quay = Color3.fromRGB(48, 52, 62),
	pier = Color3.fromRGB(70, 58, 46),
	street = Color3.fromRGB(86, 92, 108),
	wide = Color3.fromRGB(96, 100, 114),
	highway = Color3.fromRGB(118, 124, 142),
	dirt = Color3.fromRGB(104, 86, 66),
}
-- map parts drawn under the roads, by name; only used when the map has no GpsAreas folder
-- (MapBuilder writes one so the GPS works while the place streams parts in and out)
local AREAS: { [string]: string } = {
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

type Area = { name: string, kind: string, position: Vector3, size: Vector2, yaw: number }
type GraphNode = { id: string, position: Vector3, links: { string }, kinds: { string } }

local nodes: { [string]: GraphNode } = {}
local edgeList: { { a: string, b: string, kind: string } } = {}
local mapBuilt = false

local destination: Vector3? = nil
local destinationName = ""
local routeColor = C.Dropoff
local route: { Vector3 } = {}
local routeTimer = math.huge

-- UI
local mapView: CanvasGroup
local pivot: Frame
local zoom: UIScale
local world: Frame
local roadLayer: Frame
local routeLayer: Frame
local pin: Frame
local compass: TextLabel
local turnChip: Frame
local turnArrow: TextLabel
local turnTitle: TextLabel
local turnSub: TextLabel
local speedValue: TextLabel
local limitSign: Frame
local limitStroke: UIStroke
local remainingLabel: TextLabel
local destLabel: TextLabel

---------------------------------------------------------------------------------------------------
-- Drawing helpers (world studs -> map pixels at SCALE)
---------------------------------------------------------------------------------------------------

local function toMap(p: Vector3): UDim2
	return UDim2.fromOffset(p.X * SCALE, p.Z * SCALE)
end

-- A straight stroke from a to b, `width` studs wide with rounded ends.
local function segment(parent: Instance, a: Vector3, b: Vector3, width: number, color: Color3): Frame
	local flat = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	local w = width * SCALE
	return Theme.new("Frame", {
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = toMap((a + b) / 2),
		Size = UDim2.fromOffset(flat.Magnitude * SCALE + w, w),
		Rotation = math.deg(math.atan2(flat.Z, flat.X)),
		Parent = parent,
	}, { Theme.corner(math.floor(w / 2)) })
end

local function dot(parent: Instance, p: Vector3, diameter: number, color: Color3): Frame
	local d = diameter * SCALE
	return Theme.new("Frame", {
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = toMap(p),
		Size = UDim2.fromOffset(d, d),
		Parent = parent,
	}, { Theme.corner(math.floor(d / 2)) })
end

local function loadGraph(): boolean
	local map = workspace:FindFirstChild("Map")
	local graph = map and map:FindFirstChild("RoadGraph")
	if not graph then
		return false
	end
	table.clear(nodes)
	table.clear(edgeList)
	for _, value in graph:GetChildren() do
		if value:IsA("Vector3Value") then
			local links = string.split((value:GetAttribute("Links") :: string?) or "", ",")
			local kinds = string.split((value:GetAttribute("LinkKinds") :: string?) or "", ",")
			nodes[value.Name] = { id = value.Name, position = value.Value, links = links, kinds = kinds }
		end
	end
	for id, n in nodes do
		for i, other in n.links do
			if nodes[other] and id < other then
				local kind = n.kinds[i]
				table.insert(edgeList, { a = id, b = other, kind = if kind and ROAD_WIDTH[kind] then kind else "street" })
			end
		end
	end
	return next(nodes) ~= nil
end

local function buildMap()
	local map = workspace:FindFirstChild("Map")
	if not map or not loadGraph() then
		return
	end
	mapBuilt = true
	-- areas, biggest first so blocks and lots land on top of the ground
	local areas: { Area } = {}
	local published = map:FindFirstChild("GpsAreas")
	if published then
		for _, value in published:GetChildren() do
			local kind = value:GetAttribute("Kind")
			local size = value:GetAttribute("Size")
			if value:IsA("Vector3Value") and typeof(kind) == "string" and MAP_COLORS[kind] and typeof(size) == "Vector2" then
				local yaw = value:GetAttribute("Yaw")
				table.insert(areas, { name = value.Name, kind = kind, position = value.Value, size = size, yaw = if typeof(yaw) == "number" then yaw else 0 })
			end
		end
	else
		for _, part in map:GetDescendants() do
			if part:IsA("BasePart") and AREAS[part.Name] then
				local _, yaw, _ = part.CFrame:ToOrientation()
				table.insert(areas, { name = part.Name, kind = AREAS[part.Name], position = part.Position, size = Vector2.new(part.Size.X, part.Size.Z), yaw = yaw })
			end
		end
	end
	table.sort(areas, function(a, b)
		return a.size.X * a.size.Y > b.size.X * b.size.Y
	end)
	for _, area in areas do
		Theme.new("Frame", {
			BackgroundColor3 = MAP_COLORS[area.kind],
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = toMap(area.position),
			Size = UDim2.fromOffset(area.size.X * SCALE, area.size.Y * SCALE),
			Rotation = -math.deg(area.yaw),
			Parent = roadLayer,
		}, { Theme.corner(if area.name == "Grass" then 0 else 3) })
	end
	-- roads: wide ones first so highways sit on top of the streets that meet them
	table.sort(edgeList, function(a, b)
		return ROAD_WIDTH[a.kind] < ROAD_WIDTH[b.kind]
	end)
	for _, edge in edgeList do
		segment(roadLayer, nodes[edge.a].position, nodes[edge.b].position, ROAD_WIDTH[edge.kind], MAP_COLORS[edge.kind])
	end
end

---------------------------------------------------------------------------------------------------
-- Routing
---------------------------------------------------------------------------------------------------

local function flatDistance(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

-- The closest point on any road to p, and the edge it lies on.
local function nearestOnRoad(p: Vector3): (Vector3?, string?, string?)
	local best, bestA, bestB, bestD = nil, nil, nil, math.huge
	for _, edge in edgeList do
		local a, b = nodes[edge.a].position, nodes[edge.b].position
		local ab = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
		local t = math.clamp(Vector3.new(p.X - a.X, 0, p.Z - a.Z):Dot(ab) / ab:Dot(ab), 0, 1)
		local q = a + ab * t
		local d = flatDistance(p, q)
		if d < bestD then
			best, bestA, bestB, bestD = q, edge.a, edge.b, d
		end
	end
	return best, bestA, bestB
end

-- Shortest road route from `from` to `to` as a polyline: from, onto the road, along the road
-- graph, off the road, to.
local function findRoute(from: Vector3, to: Vector3): { Vector3 }
	local s, sa, sb = nearestOnRoad(from)
	local d, da, db = nearestOnRoad(to)
	if not s or not d or not sa or not sb or not da or not db then
		return { from, to }
	end
	if (sa == da and sb == db) or (sa == db and sb == da) then
		return { from, s, d, to }
	end
	-- Dijkstra from the start point's two edge ends (the graph is small)
	local dist: { [string]: number } = {}
	local prev: { [string]: string } = {}
	local done: { [string]: boolean } = {}
	dist[sa] = flatDistance(s, nodes[sa].position)
	dist[sb] = flatDistance(s, nodes[sb].position)
	while true do
		local current, best = nil, math.huge
		for id, value in dist do
			if not done[id] and value < best then
				current, best = id, value
			end
		end
		if not current then
			break
		end
		done[current] = true
		for _, other in nodes[current].links do
			if nodes[other] then
				local alt = best + flatDistance(nodes[current].position, nodes[other].position)
				if alt < (dist[other] or math.huge) then
					dist[other] = alt
					prev[other] = current
				end
			end
		end
	end
	-- leave the road from whichever end of the destination's edge is cheaper overall
	local viaA = (dist[da] or math.huge) + flatDistance(nodes[da].position, d)
	local viaB = (dist[db] or math.huge) + flatDistance(nodes[db].position, d)
	local last = if viaA <= viaB then da else db
	if (dist[last] or math.huge) == math.huge then
		return { from, to }
	end
	local chain = {}
	local id: string? = last
	while id do
		table.insert(chain, 1, nodes[id].position)
		id = prev[id]
	end
	local path = { from, s }
	for _, p in chain do
		table.insert(path, p)
	end
	table.insert(path, d)
	table.insert(path, to)
	return path
end

-- The next turn along the route: (title, subtitle, arrow rotation, remaining distance).
local function directions(path: { Vector3 }): (string, string, number, number)
	local total = 0
	for i = 1, #path - 1 do
		total += flatDistance(path[i], path[i + 1])
	end
	if total < 30 then
		return "Arriving", destinationName, 0, total
	end
	local travelled = flatDistance(path[1], path[2])
	-- road nodes are path[3 .. #path - 2]
	for i = 3, #path - 2 do
		travelled += flatDistance(path[i - 1], path[i])
		-- judge the first junction from where the player actually is, not from the point where the
		-- route joins the road: that short stub would turn "straight on" into a left or right
		local from = if i == 3 then path[1] else path[i - 1]
		local into = Vector3.new(path[i].X - from.X, 0, path[i].Z - from.Z)
		local out = Vector3.new(path[i + 1].X - path[i].X, 0, path[i + 1].Z - path[i].Z)
		if into.Magnitude > 1 and out.Magnitude > 1 then
			local cos = into.Unit:Dot(out.Unit)
			if cos < math.cos(math.rad(35)) then
				local right = into:Cross(out).Y < 0
				if cos < math.cos(math.rad(150)) then
					return "Make a U-turn", `in {Theme.distance(travelled)}`, 180, total
				end
				return if right then "Turn right" else "Turn left", `in {Theme.distance(travelled)}`, if right then 90 else -90, total
			end
		end
	end
	return "Continue", `{Theme.distance(total)} to {destinationName}`, 0, total
end

local function drawRoute()
	routeLayer:ClearAllChildren()
	for i = 2, #route - 1 do
		segment(routeLayer, route[i], route[i + 1], 12, routeColor)
	end
	-- dashed-looking walk legs on and off the road, thinner
	if #route >= 2 then
		segment(routeLayer, route[1], route[2], 6, routeColor).BackgroundTransparency = 0.4
		segment(routeLayer, route[#route - 1], route[#route], 6, routeColor).BackgroundTransparency = 0.4
	end
end

---------------------------------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------------------------------

-- Where to route to (nil clears it). `color` matches the job stage: pickup amber, dropoff cyan.
function GpsApp.setDestination(position: Vector3?, name: string?, color: Color3?)
	destination = position
	destinationName = name or ""
	routeColor = color or C.Dropoff
	routeTimer = math.huge
	route = {}
	if routeLayer then
		routeLayer:ClearAllChildren()
	end
	if pin then
		pin.Visible = position ~= nil
		pin.BackgroundColor3 = routeColor
		if position then
			pin.Position = toMap(position)
		end
	end
	if turnChip then
		turnChip.BackgroundColor3 = routeColor
	end
end

function GpsApp.build(page: Frame)
	-- next-turn card
	local card = Theme.new("Frame", {
		BackgroundColor3 = C.PanelRaised,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 64),
		Parent = page,
	}, { Theme.corner(14), Theme.stroke(0.92) })
	turnChip = Theme.new("Frame", {
		BackgroundColor3 = routeColor,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(44, 44),
		Position = UDim2.fromOffset(10, 10),
		Parent = card,
	}, { Theme.corner(10) })
	turnArrow = Theme.label({
		Text = "▲",
		Font = F.Heavy,
		TextSize = 22,
		TextColor3 = Color3.fromRGB(16, 16, 20),
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		Parent = turnChip,
	})
	turnTitle = Theme.label({ Font = F.Heavy, TextSize = 18, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, -74, 0, 22), Position = UDim2.fromOffset(64, 12), Parent = card })
	turnSub = Theme.label({ TextSize = 13, TextColor3 = C.TextDim, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, -74, 0, 16), Position = UDim2.fromOffset(64, 36), Parent = card })

	-- the map
	mapView = Theme.new("CanvasGroup", {
		BackgroundColor3 = MAP_COLORS.water,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 1, -148),
		Position = UDim2.fromOffset(0, 72),
		Parent = page,
	}, { Theme.corner(14) })
	-- the player sits low on the map so more of the road ahead shows
	pivot = Theme.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(0, 0),
		Position = UDim2.fromScale(0.5, 0.68),
		Parent = mapView,
	})
	zoom = Theme.new("UIScale", { Scale = ZOOM_ON_FOOT, Parent = pivot })
	world = Theme.new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0), Parent = pivot })
	roadLayer = Theme.new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0), Parent = world })
	routeLayer = Theme.new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0), Parent = world })
	pin = Theme.new("Frame", {
		Visible = false,
		BackgroundColor3 = routeColor,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(26, 26),
		ZIndex = 3,
		Parent = world,
	}, { Theme.corner(13), Theme.new("UIStroke", { Color = Color3.new(1, 1, 1), Thickness = 3 }) })
	-- the player arrow stays put; the map turns under it
	Theme.label({
		Text = "▲",
		Font = F.Heavy,
		TextSize = 26,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeTransparency = 0,
		TextStrokeColor3 = Color3.fromRGB(30, 90, 200),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(30, 30),
		Position = UDim2.fromScale(0.5, 0.68),
		ZIndex = 5,
		Parent = mapView,
	})
	compass = Theme.label({
		Text = "N",
		Font = F.Heavy,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Center,
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = 0.2,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(22, 22),
		ZIndex = 5,
		Parent = mapView,
	})
	Theme.corner(11).Parent = compass

	-- speed and trip info
	local info = Theme.new("Frame", {
		BackgroundColor3 = C.PanelRaised,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 68),
		Position = UDim2.new(0, 0, 1, -68),
		Parent = page,
	}, { Theme.corner(14), Theme.stroke(0.92) })
	limitSign = Theme.new("Frame", {
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(40, 52),
		Position = UDim2.fromOffset(8, 8),
		Parent = info,
	}, { Theme.corner(5) })
	limitStroke = Theme.new("UIStroke", { Color = Color3.new(0, 0, 0), Thickness = 2, Parent = limitSign })
	for i, word in { "SPEED", "LIMIT" } do
		Theme.label({
			Text = word,
			Font = F.Heavy,
			TextSize = 8,
			TextColor3 = Color3.new(0, 0, 0),
			TextXAlignment = Enum.TextXAlignment.Center,
			Size = UDim2.new(1, 0, 0, 9),
			Position = UDim2.fromOffset(0, 3 + (i - 1) * 9),
			Parent = limitSign,
		})
	end
	Theme.label({
		Text = tostring(LIMIT_MPH),
		Font = F.Heavy,
		TextSize = 24,
		TextColor3 = Color3.new(0, 0, 0),
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 0, 26),
		Position = UDim2.fromOffset(0, 22),
		Parent = limitSign,
	})
	speedValue = Theme.label({ Font = F.Heavy, TextSize = 28, Size = UDim2.fromOffset(56, 30), Position = UDim2.fromOffset(56, 10), Parent = info })
	Theme.caption("mph", { Size = UDim2.fromOffset(56, 12), Position = UDim2.fromOffset(57, 42), Parent = info })
	remainingLabel = Theme.label({ Font = F.Bold, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Right, Size = UDim2.new(1, -124, 0, 20), Position = UDim2.fromOffset(112, 12), Parent = info })
	destLabel = Theme.label({ TextSize = 12, TextColor3 = C.TextDim, TextXAlignment = Enum.TextXAlignment.Right, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, -124, 0, 16), Position = UDim2.fromOffset(112, 36), Parent = info })
end

-- Called every frame while the GPS page is showing.
function GpsApp.update(dt: number)
	if not mapBuilt then
		buildMap()
		if not mapBuilt then
			turnTitle.Text = "No signal"
			turnSub.Text = "Waiting for the map…"
			return
		end
		if destination then
			GpsApp.setDestination(destination, destinationName, routeColor)
		end
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid then
		return
	end
	local seat = humanoid.SeatPart
	local position = root.Position
	local velocity = if seat then seat.AssemblyLinearVelocity else root.AssemblyLinearVelocity
	local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude

	-- heading-up: in a car follow the car, on foot follow the camera
	local look = if seat then seat.CFrame.LookVector else (workspace.CurrentCamera :: Camera).CFrame.LookVector
	local heading = math.deg(math.atan2(look.X, -look.Z))
	pivot.Rotation = -heading
	world.Position = UDim2.fromOffset(-position.X * SCALE, -position.Z * SCALE)
	local targetZoom = if seat then ZOOM_DRIVING + (ZOOM_ON_FOOT - ZOOM_DRIVING) * (1 - math.clamp(speed / 80, 0, 1)) else ZOOM_ON_FOOT
	zoom.Scale += (targetZoom - zoom.Scale) * math.min(1, dt * 2)
	-- the N badge rides the map edge on the north side: screen up turned by the map's rotation
	local north = math.rad(-heading)
	local size = mapView.AbsoluteSize
	local r = math.min(size.X, size.Y) / 2 - 16
	compass.Position = UDim2.new(0.5, r * math.sin(north), 0.5, -r * math.cos(north))

	-- speed against the limit
	local mph = math.floor(speed * Config.Vehicles.MphPerStud + 0.5)
	local over = seat ~= nil and speed > Config.Heat.SpeedingThreshold
	speedValue.Text = tostring(mph)
	speedValue.TextColor3 = if over then C.Wanted else C.Text
	limitStroke.Color = if over then C.Wanted else Color3.new(0, 0, 0)
	limitStroke.Thickness = if over then 4 else 2

	-- route and directions
	local target = destination
	if not target then
		turnTitle.Text = "No destination"
		turnSub.Text = "Take a contract to get directions"
		turnArrow.Rotation = 0
		turnChip.BackgroundColor3 = C.TextDim
		remainingLabel.Text = ""
		destLabel.Text = ""
		return
	end
	routeTimer += dt
	if routeTimer > 0.5 then
		routeTimer = 0
		route = findRoute(position, target)
		drawRoute()
	end
	if #route >= 2 then
		route[1] = position
		local title, sub, arrow, remaining = directions(route)
		turnTitle.Text = title
		turnSub.Text = sub
		turnArrow.Rotation = arrow
		turnChip.BackgroundColor3 = routeColor
		-- ETA at the current speed, or a typical one when crawling
		local pace = math.max(speed, if seat then 40 else 14)
		local minutes = math.max(1, math.ceil(remaining / pace / 60))
		remainingLabel.Text = `{Theme.distance(remaining)} · {minutes} min`
		destLabel.Text = destinationName
	end
end

return GpsApp
