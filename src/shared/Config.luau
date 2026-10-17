--!strict
-- Tunable numbers for v0.1. Shared so the client can read limits (e.g. max heat) for UI.

local Config = {
	Heat = {
		Max = 100,
		TickSeconds = 0.5,
		DecayPerSecond = 1,
		-- studs/second; walking is ~16, so this only triggers in vehicles
		SpeedingThreshold = 80,
		SpeedingHeatPerSecond = 4,
		PatrolRadius = 60,
		CargoNearPatrolHeatPerSecond = 6,
		-- become wanted at this heat, stop being wanted once heat falls to ClearThreshold
		WantedThreshold = 50,
		ClearThreshold = 20,
	},

	Jobs = {
		BoardSize = 5,
		RefreshSeconds = 60,
		MinPayout = 500,
		MaxPayout = 1500,
		InteractDistance = 15,
	},

	Syndicates = {
		"The Harbor Crew",
	},

	-- CollectionService tags placed on parts in the map
	Tags = {
		Pickup = "PickupPoint",
		Dropoff = "DropoffPoint",
		Patrol = "PolicePatrol",
	},

	Debug = {
		-- spawns a placeholder pickup and dropoff when the map has none, so the loop is testable on an empty baseplate
		SpawnTestPoints = true,
	},
}

return Config
