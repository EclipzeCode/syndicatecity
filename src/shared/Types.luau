--!strict

export type Contract = {
	id: string,
	syndicate: string,
	pickupName: string,
	dropoffName: string,
	payout: number,
}

-- "accepted" | "pickedUp" | "delivered" | "failed"
export type JobStatus = string

return {}
