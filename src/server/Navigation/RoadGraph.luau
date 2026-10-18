--!strict
-- The road graph MapBuilder writes to Workspace.Map.RoadGraph: one Vector3Value per node with
-- Links, LinkKinds and District attributes. Police AI drives on it and JobService measures
-- contract routes with it. (The phone GPS reads the same folder on the client.)

local RoadGraph = {}

export type Node = {
	id: string,
	position: Vector3,
	links: { string },
	kinds: { [string]: string }, -- road kind of the link to each neighbour
	district: string,
}

RoadGraph.nodes = {} :: { [string]: Node }
RoadGraph.ids = {} :: { string }

function RoadGraph.load(): boolean
	local map = workspace:FindFirstChild("Map")
	local folder = map and map:FindFirstChild("RoadGraph")
	if not folder then
		return false
	end
	table.clear(RoadGraph.nodes)
	table.clear(RoadGraph.ids)
	for _, value in folder:GetChildren() do
		if value:IsA("Vector3Value") then
			local links = string.split((value:GetAttribute("Links") :: string?) or "", ",")
			local kindList = string.split((value:GetAttribute("LinkKinds") :: string?) or "", ",")
			local kinds = {}
			for i, other in links do
				kinds[other] = kindList[i] or "street"
			end
			RoadGraph.nodes[value.Name] = {
				id = value.Name,
				position = value.Value,
				links = links,
				kinds = kinds,
				district = (value:GetAttribute("District") :: string?) or "Downtown",
			}
			table.insert(RoadGraph.ids, value.Name)
		end
	end
	-- drop links to nodes that don't exist, so nothing downstream has to check
	for _, node in RoadGraph.nodes do
		for i = #node.links, 1, -1 do
			if not RoadGraph.nodes[node.links[i]] then
				table.remove(node.links, i)
			end
		end
	end
	return #RoadGraph.ids > 0
end

function RoadGraph.nearest(position: Vector3): string
	local best, bestDistance = RoadGraph.ids[1], math.huge
	for id, node in RoadGraph.nodes do
		local d = (node.position - position).Magnitude
		if d < bestDistance then
			best, bestDistance = id, d
		end
	end
	return best
end

-- Dijkstra over ~100 nodes: cheap enough to rerun every second per pursuer. `cost` weighs each
-- link (default: its length). Returns the nodes after `fromId`, ending with `toId`, and the cost.
function RoadGraph.findPath(fromId: string, toId: string, cost: ((a: Node, b: Node) -> number)?): ({ string }, number)
	local nodes = RoadGraph.nodes
	local dist: { [string]: number } = { [fromId] = 0 }
	local prev: { [string]: string } = {}
	local open: { [string]: boolean } = { [fromId] = true }
	while next(open) do
		local current, best = nil :: string?, math.huge
		for id in open do
			if dist[id] < best then
				current, best = id, dist[id]
			end
		end
		local cur = current :: string
		open[cur] = nil
		if cur == toId then
			break
		end
		local here = nodes[cur]
		for _, linkId in here.links do
			local other = nodes[linkId]
			local step = if cost then cost(here, other) else (other.position - here.position).Magnitude
			local alt = dist[cur] + step
			if alt < (dist[linkId] or math.huge) then
				dist[linkId] = alt
				prev[linkId] = cur
				open[linkId] = true
			end
		end
	end
	local path = {}
	local step: string? = toId
	while step and step ~= fromId do
		table.insert(path, 1, step)
		step = prev[step]
	end
	return path, dist[toId] or math.huge
end

-- Length in studs of the shortest road route between two points (on and off the nearest nodes).
function RoadGraph.routeLength(from: Vector3, to: Vector3): number
	local a, b = RoadGraph.nearest(from), RoadGraph.nearest(to)
	local _, length = RoadGraph.findPath(a, b)
	return length + (RoadGraph.nodes[a].position - from).Magnitude + (RoadGraph.nodes[b].position - to).Magnitude
end

-- Estimated seconds for the fastest route at `speeds` (studs/s by road kind).
function RoadGraph.routeTime(from: Vector3, to: Vector3, speeds: { [string]: number }): number
	local a, b = RoadGraph.nearest(from), RoadGraph.nearest(to)
	local _, seconds = RoadGraph.findPath(a, b, function(x, y)
		return (y.position - x.position).Magnitude / (speeds[x.kinds[y.id]] or speeds.street)
	end)
	local offRoad = (RoadGraph.nodes[a].position - from).Magnitude + (RoadGraph.nodes[b].position - to).Magnitude
	return seconds + offRoad / speeds.street
end

return RoadGraph
