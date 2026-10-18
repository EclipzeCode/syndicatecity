--!strict
-- The rules for one patrol car's encounter with one player, as pure functions so they can be
-- tested without a running game. PoliceService feeds in what the patrol can see each tick.
--
-- States:
--   Patrolling    following its beat; checks nearby players for anything suspicious
--   Observing     it can see something suspicious; suspicion builds while that lasts
--   Investigating suspicion passed InvestigateThreshold: the patrol tails the player
--   Pursuing      suspicion hit PursuitThreshold: the player becomes wanted (existing chase/bust)
--   Returning     the encounter is over; driving back to its beat

local Suspicion = {}

export type State = "Patrolling" | "Observing" | "Investigating" | "Pursuing" | "Returning"

-- What a patrol can see of a player right now. Zeros when it can't see them.
export type Observation = {
	speedOver: number, -- studs/s over the speed limit (0 if not speeding)
	cargoRisk: number, -- the contract's risk if the patrol can see the cargo, else 0
	heat: number, -- the player's heat, 0..1
}

export type Config = {
	SpeedingPerSecond: number,
	SpeedingFullOver: number,
	CargoPerSecond: number,
	CargoSuspicionCap: number,
	HeatMultiplier: number,
	DecayPerSecond: number,
	InvestigateThreshold: number,
	PursuitThreshold: number,
	ClearThreshold: number,
	LoseSightSeconds: number,
	InvestigateMaxSeconds: number,
}

-- Suspicion per second from speeding and from visible cargo (before the heat multiplier).
function Suspicion.rates(obs: Observation, cfg: Config): (number, number)
	local speeding = 0
	if obs.speedOver > 0 then
		speeding = cfg.SpeedingPerSecond * math.clamp(obs.speedOver / cfg.SpeedingFullOver, 0.25, 1.5)
	end
	local cargo = cfg.CargoPerSecond * math.max(obs.cargoRisk, 0)
	return speeding, cargo
end

-- Whether anything the patrol sees is suspicious at all. Being near police isn't.
function Suspicion.isSuspicious(obs: Observation, cfg: Config): boolean
	local speeding, cargo = Suspicion.rates(obs, cfg)
	return speeding > 0 or cargo > 0
end

-- Advances suspicion by dt. Suspicion climbs toward a ceiling set by what's visible (speeding:
-- PursuitThreshold, cargo only: CargoSuspicionCap, nothing: 0) and decays toward it from above.
function Suspicion.step(value: number, obs: Observation, dt: number, cfg: Config): number
	local speeding, cargo = Suspicion.rates(obs, cfg)
	local ceiling = if speeding > 0 then cfg.PursuitThreshold elseif cargo > 0 then cfg.CargoSuspicionCap else 0
	if value < ceiling then
		local multiplier = 1 + cfg.HeatMultiplier * math.clamp(obs.heat, 0, 1)
		return math.min(ceiling, value + (speeding + cargo) * multiplier * dt)
	end
	return math.max(ceiling, value - cfg.DecayPerSecond * dt)
end

-- Adds a one-off jolt of suspicion (being rammed, being blocked), up to the pursuit threshold.
function Suspicion.bump(value: number, amount: number, cfg: Config): number
	return math.clamp(value + amount, 0, cfg.PursuitThreshold)
end

-- The next state for an encounter in progress. `unseen` is how long the patrol has gone without
-- seeing the player; `elapsed` how long it has been in `state`.
function Suspicion.nextState(state: State, value: number, unseen: number, elapsed: number, cfg: Config): State
	if state == "Observing" then
		if value >= cfg.InvestigateThreshold then
			return "Investigating"
		elseif value <= 0 or unseen >= cfg.LoseSightSeconds then
			-- it never left its route, so it just carries on
			return "Patrolling"
		end
	elseif state == "Investigating" then
		if value >= cfg.PursuitThreshold then
			return "Pursuing"
		elseif value <= cfg.ClearThreshold or unseen >= cfg.LoseSightSeconds or elapsed >= cfg.InvestigateMaxSeconds then
			return "Returning"
		end
	end
	return state
end

return Suspicion
