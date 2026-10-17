--!nocheck
-- Fallback for when the Rojo plugin isn't connected. With `python tools/devsync.py` running, run in the
-- command bar: require(game.ServerStorage.Tools.DevSync:Clone())()
-- (paste this file's body into the command bar the very first time). Mirrors src/ into the place: creates/updates scripts and deletes scripts under each root that no longer exist on disk.
-- Requires Game Settings -> Security -> Allow HTTP Requests.

return function()
local HttpService = game:GetService("HttpService")
local entries = HttpService:JSONDecode(HttpService:GetAsync("http://localhost:34873/manifest"))

local function resolveRoot(path: string): Instance
	local node: Instance = game
	for _, name in string.split(path, ".") do
		local child = node:FindFirstChild(name)
		if not child then
			child = Instance.new("Folder")
			child.Name = name
			child.Parent = node
		end
		node = child
	end
	return node
end

local keep: { [Instance]: boolean } = {}
local roots: { [Instance]: boolean } = {}
local count = 0

for _, entry in entries do
	local parent = resolveRoot(entry.root)
	roots[parent] = true
	for i = 1, #entry.path - 1 do
		local name = entry.path[i]
		local child = parent:FindFirstChild(name)
		if not child then
			child = Instance.new("Folder")
			child.Name = name
			child.Parent = parent
		end
		keep[child] = true
		parent = child
	end
	local name = entry.path[#entry.path]
	local script = parent:FindFirstChild(name)
	if script and script.ClassName ~= entry.className then
		script:Destroy()
		script = nil
	end
	if not script then
		script = Instance.new(entry.className)
		script.Name = name
		script.Parent = parent
	end
	if (script :: any).Source ~= entry.source then
		(script :: any).Source = entry.source
		count += 1
	end
	keep[script] = true
end

for root in roots do
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("LuaSourceContainer") and not keep[descendant] then
			descendant:Destroy()
		end
	end
end

return `devsync: {#entries} scripts, {count} updated`
end
