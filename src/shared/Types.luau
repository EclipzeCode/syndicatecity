--!strict

export type Contract = {
	id: string,
	syndicate: string,
	pickupName: string,
	dropoffName: string,
	payout: number,
	-- what kind of job it is (Config.Jobs.Tiers): "Routine", "Standard" or "High-value"
	tier: string?,
	-- what's in the crate; flavour text
	cargo: string?,
	-- how much police attention the cargo draws (Config.Police.Detection scales by this)
	risk: number?,
	-- estimated drive from pickup to dropoff, in seconds
	routeSeconds: number?,
}

-- Sent only to the player who accepted the contract, with the "accepted" update.
export type ContractDetails = {
	-- the code word the pickup contact asks for
	passcode: string,
}

-- "accepted" | "pickedUp" | "delivered" | "failed" | "busted"
export type JobStatus = string

export type VehicleTuning = {
	Size: Vector3,
	CabinHeight: number,
	RideHeight: number,
	SpringTravel: number,
	WheelRadius: number,
	MaxSpeed: number,
	ReverseSpeed: number,
	Acceleration: number,
	Brake: number,
	TurnRate: number,
	Grip: number,
}

return {}
