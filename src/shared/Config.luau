--!strict
-- Tunable numbers for v0.1. Shared so the client can read limits (e.g. max heat) for UI.

local Config = {
	-- Heat is short-term police attention. It decays on its own, rises with what police see (see
	-- Police.Detection) and, more slowly, with reckless driving nobody saw. Higher heat makes
	-- patrols quicker to get suspicious.
	Heat = {
		Max = 100,
		TickSeconds = 0.5,
		DecayPerSecond = 1,
		-- studs/second; walking is ~16, so this only triggers in vehicles. The GPS shows it as the limit.
		SpeedingThreshold = 80,
		-- unseen speeding: heat per second at SpeedingFullOver studs/s over the limit (25% of it
		-- just over), after SpeedingGraceSeconds of continuous speeding
		SpeedingHeatPerSecond = 1.5,
		SpeedingFullOver = 25,
		SpeedingGraceSeconds = 1.5,
		-- become wanted at this heat, stop being wanted once heat falls to ClearThreshold
		WantedThreshold = 50,
		ClearThreshold = 20,
	},

	Jobs = {
		BoardSize = 6,
		RefreshSeconds = 60,
		-- dropoff reach; pickups are handed over by a contact (see Contact)
		InteractDistance = 20,
		-- rough lawful driving speeds (studs/s) by road kind, used to estimate each route's drive time
		RouteSpeeds = { highway = 78, wide = 60, street = 55, dirt = 45 },
		-- Contracts are sorted into tiers by estimated drive time (the first tier whose
		-- MaxSeconds fits). Payout is rolled in the tier's range and paid on delivery as before;
		-- Risk scales how much police notice the cargo; Weight is how often the board offers it.
		-- The board keeps at least one of each tier when it can.
		Tiers = {
			{
				Name = "Routine",
				MaxSeconds = 40,
				Payout = { 400, 750 },
				Risk = 0.8,
				Weight = 3,
				Cargo = { "Cigarettes", "Bootleg DVDs", "Knockoff sneakers", "Untaxed perfume" },
			},
			{
				Name = "Standard",
				MaxSeconds = 90,
				Payout = { 750, 1350 },
				Risk = 1,
				Weight = 4,
				Cargo = { "Stolen electronics", "Counterfeit watches", "Car parts", "Unlicensed fireworks" },
			},
			{
				Name = "High-value",
				MaxSeconds = math.huge,
				Payout = { 1400, 2300 },
				Risk = 1.5,
				Weight = 2,
				Cargo = { "Forged paintings", "Uncut gems", "Rare whiskey", "Prototype chips" },
			},
		},
		-- the pickup contact (server: Jobs/Handoff, lines in Jobs/ContactLines)
		Contact = {
			InteractDistance = 12,
			-- minimum seconds between answers, against double clicks and remote spam
			AnswerCooldown = 0.5,
			-- how long the contact hangs around after the handoff
			LingerSeconds = 8,
		},
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
		-- the most police cars at once, patrols plus backup called in for pursuits
		MaxCops = 9,
		-- patrol cars per district (RoadGraph node District); they mostly stay on their beat, so
		-- downtown is the most watched and the outskirts the least
		Beats = { Downtown = 3, Industrial = 1, Highway = 1, Outskirts = 1 },
		BeatStayChance = 0.9,
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
		-- a car that keeps getting stuck, or ends up in the water, is replaced somewhere out of sight
		StuckReversesBeforeRespawn = 4,
		StuckWindowSeconds = 20,

		-- How patrols notice players. Each patrol car runs its own encounter:
		--   Patrolling -> Observing (it can see something suspicious; suspicion builds)
		--   -> Investigating (it tails the player) -> Pursuing (sirens; the player is wanted)
		--   -> Returning (back to its beat). Suspicion decays whenever nothing suspicious is
		--   visible, so players can talk their way out of it by driving clean.
		Detection = {
			IntervalSeconds = 0.3,
			-- a patrol can notice speeding this far away, if it has line of sight
			Range = 220,
			RequireLineOfSight = true,
			-- cargo is only noticeable up close (a glimpse of the crate); scaled by contract risk
			CargoRange = 70,
			-- suspicion per second while a speeding player is visible: SpeedingPerSecond at
			-- Heat.SpeedingFullOver over the limit, down to 25% just over it, up to 150% far over
			SpeedingPerSecond = 14,
			-- suspicion per second while cargo is visible, times the contract's risk. Cargo alone
			-- can't get past CargoSuspicionCap: a pursuit needs the player to do something
			CargoPerSecond = 6,
			CargoSuspicionCap = 60,
			-- at max heat suspicion builds (1 + HeatMultiplier) times as fast
			HeatMultiplier = 1,
			DecayPerSecond = 6,
			-- every point of suspicion a patrol builds also adds this much heat
			HeatPerSuspicion = 0.25,
			InvestigateThreshold = 35,
			PursuitThreshold = 100,
			-- an investigation ends when suspicion falls to this, the patrol loses sight of the
			-- player for LoseSightSeconds, or it has gone on for InvestigateMaxSeconds
			ClearThreshold = 5,
			LoseSightSeconds = 6,
			InvestigateMaxSeconds = 35,
			-- after an encounter, that patrol ignores that player for this long
			CooldownSeconds = 20,
			-- while investigating, the patrol tails at about this distance
			TailDistance = 45,
			-- optional radio chirp when an investigation starts ("rbxassetid://..."); empty = silent
			RadioSoundId = "",
		},
	},

	-- On-foot speeds in studs/second; hold Shift (or click the left stick) to sprint
	Movement = {
		WalkSpeed = 16,
		SprintSpeed = 26,
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
