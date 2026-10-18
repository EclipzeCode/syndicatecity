--!strict
-- Edit-mode importer for the Blender meshes (art/blender). Studio's FBX importer only runs from its
-- UI, so this rebuilds each part from the JSON written by art/blender/roblox_export.py, uploads it
-- as a Mesh asset on your account and saves templates under ServerStorage.Assets:
--   Assets.Vehicles.<Sedan|Police|Van>   (origin = Chassis centre, front = -Z)
--   Assets.Buildings.<Name>               (origin = footprint centre on the ground, street = -Z)
--   Assets.Nature.<Name>                  (trees, bush, rocks, grass tuft; origin on the ground)
--   Assets.Environment.<Name>             (road tiles, sand, water, clouds; see art/blender/environment.py)
-- Serve the JSON locally, then run from the command bar:
--   python -m http.server 8765 --bind 127.0.0.1 --directory art/export/roblox
--   require(game.ServerStorage.Tools.MeshImporter).importAll("http://127.0.0.1:8765")
-- Uploads are cached by content hash (Assets:GetAttribute("mesh_<hash>")), so re-running only
-- uploads parts whose geometry changed.
--
-- CreateAssetAsync only works in local plugins, and not on every account yet. Fallback: import
-- art/export/*.fbx, art/export/buildings/*.fbx, art/export/nature/*.fbx and art/export/environment/*.fbx with File > Import 3D (anywhere in Workspace),
-- then run MeshImporter.adoptAll("http://127.0.0.1:8765"). The JSON supplies each part's
-- placement, size, color and collision, so the import's scale and position don't matter.

local AssetService = game:GetService("AssetService")
local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")

local MeshImporter = {}

MeshImporter.Vehicles = { "Sedan", "Police", "Van" }
MeshImporter.Buildings = {
	"Shop",
	"ShopTall",
	"Midrise",
	"Office",
	"OfficeTall",
	"Tower",
	"BrickBlock",
	"PoliceStation",
	"WarehouseLarge",
	"WarehouseSmall",
	"Motel",
	"GasStation",
	"Sawmill",
	"RestStop",
	"Cabin",
	"Barn",
	"Silo",
	"Lighthouse",
	"WaterTower",
	"Hangar",
}
MeshImporter.Nature = { "TreeRound", "TreePine", "TreeTall", "Bush", "RockA", "RockB", "RockC", "GrassTuft" }
MeshImporter.Environment = {
	"RoadStreet",
	"RoadHighway",
	"RoadDirt",
	"RoadIntersection",
	"RoadCurve",
	"SandDuneA",
	"SandDuneB",
	"SandPatch",
	"BeachSlope",
	"Starfish",
	"WaterTile",
	"WaterDeep",
	"WaveCrest",
	"ShoreFoam",
	"CloudA",
	"CloudB",
	"CloudC",
}

type PartData = {
	name: string,
	color: { number },
	kind: string,
	center: { number },
	positions: { number },
	triangles: { number },
}

-- parts that players and cars collide with, by category; everything else is decoration
local COLLISION: { [string]: { [string]: Enum.CollisionFidelity } } = {
	Buildings = {
		Body = Enum.CollisionFidelity.Box,
		Shop = Enum.CollisionFidelity.Box,
		Roof = Enum.CollisionFidelity.Hull,
		Trim = Enum.CollisionFidelity.Default,
		RoofUnits = Enum.CollisionFidelity.Box,
		Stone = Enum.CollisionFidelity.Box,
		Legs = Enum.CollisionFidelity.Default,
	},
	-- tree trunks and rocks stop cars; leaves and grass don't
	Nature = {
		Trunk = Enum.CollisionFidelity.Box,
		Rock = Enum.CollisionFidelity.Hull,
	},
	Vehicles = {},
	-- pure dressing: roads keep their flat Parts underneath for driving
	Environment = {},
}

local function assetsFolder(): Folder
	local assets = ServerStorage:FindFirstChild("Assets") :: Folder?
	if not assets then
		local f = Instance.new("Folder")
		f.Name = "Assets"
		f.Parent = ServerStorage
		assets = f
	end
	return assets :: Folder
end

local function subfolder(name: string): Folder
	local assets = assetsFolder()
	local f = assets:FindFirstChild(name) :: Folder?
	if not f then
		local new = Instance.new("Folder")
		new.Name = name
		new.Parent = assets
		f = new
	end
	return f :: Folder
end

-- FNV-1a over the geometry, so identical parts (wheels, lights, sirens) share one asset
local function hashPart(part: PartData): string
	local h = 2166136261
	local function feed(n: number)
		local v = math.round(n * 1000) % 4294967296
		h = bit32.bxor(h, v)
		-- h * 16777619 mod 2^32, split (16777619 = 2^24 + 403) so it stays exact in a double
		h = ((h % 256) * 16777216 + h * 403) % 4294967296
	end
	for _, n in part.positions do
		feed(n)
	end
	for _, n in part.triangles do
		feed(n)
	end
	return string.format("%08x%04x", h, #part.triangles % 65536)
end

local function buildEditableMesh(part: PartData): EditableMesh
	local mesh = AssetService:CreateEditableMesh()
	local verts = table.create(#part.positions // 3)
	local points = table.create(#part.positions // 3)
	local p = part.positions
	for i = 1, #p, 3 do
		local v = Vector3.new(p[i], p[i + 1], p[i + 2])
		table.insert(points, v)
		table.insert(verts, mesh:AddVertex(v))
	end
	local t = part.triangles
	for i = 1, #t, 3 do
		local a, b, c = t[i] + 1, t[i + 1] + 1, t[i + 2] + 1
		local face = mesh:AddTriangle(verts[a], verts[b], verts[c])
		-- flat shading: one normal per face
		local n = (points[b] - points[a]):Cross(points[c] - points[a])
		local normal = mesh:AddNormal(if n.Magnitude > 1e-9 then n.Unit else Vector3.yAxis)
		mesh:SetFaceNormals(face, { normal, normal, normal })
	end
	return mesh
end

local function upload(part: PartData, assetName: string): number
	local assets = assetsFolder()
	local key = "mesh_" .. hashPart(part)
	local cached = assets:GetAttribute(key)
	if typeof(cached) == "number" then
		return cached
	end
	local mesh = buildEditableMesh(part)
	local result, assetId = AssetService:CreateAssetAsync(mesh, Enum.AssetType.Mesh, {
		Name = `{assetName}_{part.name}`,
		Description = "Smuggling Game mesh from art/blender",
	})
	mesh:Destroy()
	if result ~= Enum.CreateAssetResult.Success then
		error(`upload of {assetName}.{part.name} failed: {result}`)
	end
	assets:SetAttribute(key, assetId)
	return assetId
end

local meshPartCache: { [string]: MeshPart } = {}

local function meshPart(assetId: number, fidelity: Enum.CollisionFidelity): MeshPart
	local cacheKey = `{assetId}_{fidelity.Name}`
	local base = meshPartCache[cacheKey]
	if not base then
		local lastErr
		-- a fresh upload can take a moment to become loadable
		for attempt = 1, 10 do
			local ok, result = pcall(function()
				return AssetService:CreateMeshPartAsync(Content.fromUri(`rbxassetid://{assetId}`), {
					CollisionFidelity = fidelity,
					RenderFidelity = Enum.RenderFidelity.Precise,
				})
			end)
			if ok then
				base = result
				break
			end
			lastErr = result
			task.wait(attempt)
		end
		assert(base, `could not load mesh {assetId}: {lastErr}`)
		meshPartCache[cacheKey] = base
	end
	return base:Clone()
end

local function fetch(baseUrl: string, name: string): { name: string, parts: { PartData } }
	return HttpService:JSONDecode(HttpService:GetAsync(`{baseUrl}/{name}.json`))
end

-- Places, colors and sets collision on one template part from its JSON entry.
local function styleTemplatePart(mp: MeshPart, part: PartData, category: string)
	local fidelity = COLLISION[category][part.name]
	mp.Name = part.name
	mp.Anchored = true
	mp.CFrame = CFrame.new(part.center[1], part.center[2], part.center[3])
	mp.Color = Color3.fromRGB(part.color[1], part.color[2], part.color[3])
	mp.Material = if part.kind == "neon" then Enum.Material.Neon else Enum.Material.SmoothPlastic
	mp.Reflectance = if part.kind == "glass" then 0.15 else 0
	-- glass is single panes: draw both sides so it reads from inside the car and never vanishes
	mp.DoubleSided = part.kind == "glass"
	mp.CastShadow = part.kind == "solid"
	mp.CanCollide = fidelity ~= nil
	mp.CanTouch = fidelity ~= nil
	mp.CanQuery = fidelity ~= nil
	if fidelity then
		mp.CollisionFidelity = fidelity
	end
end

local function saveTemplate(model: Model, category: string)
	-- the 3D importer leaves rotated pivots on its parts; the template's pivot must be the
	-- unrotated origin or PivotTo turns the model around
	for _, p in model:GetChildren() do
		if p:IsA("BasePart") then
			p.PivotOffset = CFrame.new()
		end
	end
	local body = model:FindFirstChild("Body") :: BasePart?
	model.PrimaryPart = body
	if body then
		body.PivotOffset = body.CFrame:Inverse()
	end
	model.WorldPivot = CFrame.new()
	local folder = subfolder(category)
	local old = folder:FindFirstChild(model.Name)
	if old then
		old:Destroy()
	end
	model.Parent = folder
end

local function categoryOf(name: string): string?
	if table.find(MeshImporter.Vehicles, name) then
		return "Vehicles"
	elseif table.find(MeshImporter.Buildings, name) then
		return "Buildings"
	elseif table.find(MeshImporter.Nature, name) then
		return "Nature"
	elseif table.find(MeshImporter.Environment, name) then
		return "Environment"
	end
	return nil
end

-- Uploads (or reuses) every part of one asset and replaces its template.
function MeshImporter.importOne(baseUrl: string, name: string, category: string): Model
	local data = fetch(baseUrl, name)
	local model = Instance.new("Model")
	model.Name = name
	for _, part in data.parts do
		local assetId = upload(part, name)
		local fidelity = COLLISION[category][part.name]
		local mp = meshPart(assetId, fidelity or Enum.CollisionFidelity.Box)
		styleTemplatePart(mp, part, category)
		mp:SetAttribute("MeshAssetId", assetId)
		mp.Parent = model
	end
	saveTemplate(model, category)
	return model
end

-- Turns one model made by File > Import 3D from <name>.fbx into the template for <name>.
-- Returns warnings for parts that didn't match the JSON or arrived rotated.
function MeshImporter.adoptOne(baseUrl: string, imported: Instance, name: string): { string }
	local category = assert(categoryOf(name), `{name} is not a known asset`)
	local data = fetch(baseUrl, name)
	local byName: { [string]: PartData } = {}
	for _, part in data.parts do
		byName[part.name] = part
	end
	local warnings = {}
	local model = Instance.new("Model")
	model.Name = name
	for _, mp in imported:GetDescendants() do
		if not mp:IsA("MeshPart") then
			continue
		end
		local partName = string.gsub(string.gsub(mp.Name, "^" .. name .. "_", ""), "%.%d+$", "")
		local part = byName[partName]
		if not part then
			table.insert(warnings, `{name}: no JSON part for {mp.Name}`)
			continue
		end
		byName[partName] = nil
		-- the mesh's own extents, from the JSON (positions are centred on the bounding box)
		local hi = Vector3.zero
		for i = 1, #part.positions, 3 do
			hi = hi:Max(Vector3.new(part.positions[i], part.positions[i + 1], part.positions[i + 2]))
		end
		local expected = hi * 2
		local native = mp.MeshSize
		local ratio = native / Vector3.new(math.max(expected.X, 1e-3), math.max(expected.Y, 1e-3), math.max(expected.Z, 1e-3))
		local spread = math.max(ratio.X, ratio.Y, ratio.Z) / math.max(math.min(ratio.X, ratio.Y, ratio.Z), 1e-6)
		if spread > 1.05 and math.min(expected.X, expected.Y, expected.Z) > 0.2 then
			table.insert(warnings, `{name}.{partName}: imported {native} vs expected {expected} (rotated?)`)
		end
		for _, child in mp:GetChildren() do
			if child:IsA("SurfaceAppearance") then
				child:Destroy()
			end
		end
		mp.Size = expected:Max(Vector3.one * 0.05)
		styleTemplatePart(mp, part, category)
		mp.Parent = model
	end
	for partName in byName do
		table.insert(warnings, `{name}: {partName} missing from the import`)
	end
	saveTemplate(model, category)
	imported:Destroy()
	return warnings
end

-- Adopts every imported model in Workspace whose name is one of the assets.
function MeshImporter.adoptAll(baseUrl: string): { string }
	local report = {}
	for _, child in workspace:GetChildren() do
		local name = string.gsub(child.Name, "%.fbx$", "")
		if categoryOf(name) and child:FindFirstChildWhichIsA("MeshPart", true) then
			for _, w in MeshImporter.adoptOne(baseUrl, child, name) do
				table.insert(report, w)
			end
			table.insert(report, `adopted {name}`)
			task.wait()
		end
	end
	return report
end

function MeshImporter.importAll(baseUrl: string)
	for _, name in MeshImporter.Vehicles do
		MeshImporter.importOne(baseUrl, name, "Vehicles")
		print(`[MeshImporter] Vehicles.{name}`)
		task.wait()
	end
	for _, name in MeshImporter.Buildings do
		MeshImporter.importOne(baseUrl, name, "Buildings")
		print(`[MeshImporter] Buildings.{name}`)
		task.wait()
	end
	MeshImporter.importNew(baseUrl, MeshImporter.Nature, "Nature")
	MeshImporter.importNew(baseUrl, MeshImporter.Environment, "Environment")
end

-- Imports just the named assets of one category (e.g. after adding a few in Blender).
function MeshImporter.importNew(baseUrl: string, names: { string }, category: string)
	for _, name in names do
		MeshImporter.importOne(baseUrl, name, category)
		print(`[MeshImporter] {category}.{name}`)
		task.wait()
	end
end

return MeshImporter
