--!strict
-- Police response to heat. v0.1 target: spawn a pursuit NPC when a player becomes wanted.

local HeatService = require(script.Parent.HeatService)

local PoliceService = {}

function PoliceService.init()
	HeatService.onWantedChanged(function(player, isWanted)
		if isWanted then
			-- TODO(v0.1): spawn a pursuit vehicle/NPC that chases the player with PathfindingService,
			-- and arrest (fail the job, confiscate cargo) if it catches them.
			print(`[Police] {player.Name} is now wanted`)
		else
			-- TODO(v0.1): despawn pursuers once the player has lost them.
			print(`[Police] {player.Name} lost the police`)
		end
	end)
end

return PoliceService
