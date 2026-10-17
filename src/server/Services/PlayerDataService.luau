--!strict
-- In-memory player data for v0.1. Values are mirrored to Player attributes so the client HUD
-- can read them without extra remotes.
-- TODO(v0.2): persist with ProfileStore and split cash into dirty/clean.

local Players = game:GetService("Players")

type Data = {
	dirtyCash: number,
}

local PlayerDataService = {}

local data: { [Player]: Data } = {}

local function load(player: Player)
	data[player] = { dirtyCash = 0 }
	player:SetAttribute("DirtyCash", 0)
end

function PlayerDataService.getDirtyCash(player: Player): number
	local d = data[player]
	return if d then d.dirtyCash else 0
end

function PlayerDataService.addDirtyCash(player: Player, amount: number)
	local d = data[player]
	if not d then
		return
	end
	d.dirtyCash += amount
	player:SetAttribute("DirtyCash", d.dirtyCash)
end

function PlayerDataService.init()
	Players.PlayerAdded:Connect(load)
	for _, player in Players:GetPlayers() do
		load(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		data[player] = nil
	end)
end

return PlayerDataService
