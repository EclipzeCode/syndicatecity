--!strict

export type Contract = {
	id: string,
	syndicate: string,
	pickupName: string,
	dropoffName: string,
	payout: number,
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
