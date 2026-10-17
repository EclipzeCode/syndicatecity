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
		InteractDistance = 20,
	},

	-- Speeds are studs/second. Displayed as mph in the HUD with MphPerStud.
	Vehicles = {
		MphPerStud = 0.63,
		SpawnCooldown = 5,
		Types = {
			Sedan = {
				Size = Vector3.new(7.4, 2.4, 15),
				CabinHeight = 3,
				RideHeight = 1.6,
				SpringTravel = 1.2,
				WheelRadius = 1.5,
				MaxSpeed = 110,
				ReverseSpeed = 35,
				Acceleration = 48,
				Brake = 110,
				TurnRate = 2.1,
				Grip = 10,
			},
			Van = {
				Size = Vector3.new(8.4, 3, 17),
				CabinHeight = 4.4,
				RideHeight = 1.8,
				SpringTravel = 1.3,
				WheelRadius = 1.7,
				MaxSpeed = 92,
				ReverseSpeed = 30,
				Acceleration = 36,
				Brake = 90,
				TurnRate = 1.7,
				Grip = 9,
			},
			Police = {
				Size = Vector3.new(7.4, 2.4, 15.5),
				CabinHeight = 3,
				RideHeight = 1.6,
				SpringTravel = 1.2,
				WheelRadius = 1.5,
				MaxSpeed = 104,
				ReverseSpeed = 35,
				Acceleration = 50,
				Brake = 120,
				TurnRate = 2.2,
				Grip = 11,
			},
		},
	},

	Police = {
		PatrolCount = 5,
		MaxCops = 8,
		PursuersPerPlayer = 2,
		PatrolSpeed = 42,
		SightRange = 240,
		-- while a pursuing cop can see you heat keeps climbing; out of sight it drains faster
		SeenHeatPerSecond = 3,
		UnseenExtraDecayPerSecond = 2,
		BustDistance = 18,
		BustMaxSpeed = 14,
		BustSeconds = 2.5,
		BustFinePercent = 0.25,
		-- cops only shoot at wanted players who are on foot
		ShootRange = 90,
		ShootInterval = 0.8,
		ShootDamage = 9,
		ShootAccuracy = 0.55,
		CarHealth = 12,
		DisabledSeconds = 20,
	},

	Weapons = {
		Pistol = {
			Damage = 15,
			FireInterval = 0.3,
			MagazineSize = 8,
			ReloadSeconds = 1.6,
			Range = 300,
			-- firing is loud: always a little heat, a lot if a cop is close
			HeatPerShot = 4,
			HeatPerShotNearPolice = 20,
			NearPoliceRadius = 150,
			HeatForHittingCop = 40,
		},
	},

	DayNight = {
		CycleMinutes = 16,
		StartClockTime = 14,
	},

	Syndicates = {
		"The Harbor Crew",
	},

	-- CollectionService tags placed on parts in the map
	Tags = {
		Pickup = "PickupPoint",
		Dropoff = "DropoffPoint",
		Patrol = "PolicePatrol",
		CarSpawn = "CarSpawn",
		PoliceRelease = "PoliceRelease",
	},

	Debug = {
		-- spawns a placeholder pickup and dropoff when the map has none, so the loop is testable on an empty baseplate
		SpawnTestPoints = true,
	},
}

return Config
