# Smuggling Game

A Roblox crime game: smuggle cargo for syndicates without drawing police attention.
Design doc: https://claude.ai/code/artifact/ee206841-15b3-49f3-b33d-37a4d300e8f5

## Setup

1. Install [Rokit](https://github.com/rojo-rbx/rokit), then run `rokit install` in this folder (installs the Rojo version pinned in `rokit.toml`).
2. Install the Rojo Studio plugin: `rojo plugin install`.
3. In VS Code, install the recommended extensions (Luau LSP, Rojo).
4. Run `rojo serve`, open your place in Roblox Studio, and click **Connect** in the Rojo plugin.

Code lives in `src/` and syncs into Studio. Save the place as `SmugglingGame.rbxl` (git-ignored).

**No Rojo plugin connected?** Run `python tools/devsync.py`, enable Game Settings → Security → Allow HTTP Requests, and run `require(game.ServerStorage.Tools.DevSync:Clone())()` in the command bar (paste `src/tools/DevSync.luau`'s body the very first time).

**Building the map:** run `require(game.ServerStorage.Tools.MapBuilder:Clone()).build()` in the command bar. It deletes and regenerates `Workspace.Map` and the terrain (an island with three districts, tapered beaches, road graph for police AI and the GPS, tagged job points, spawns) and applies the lighting baseline. The layout is deterministic. Save the place afterwards.

## Project layout

| Folder | Syncs to | Contents |
| --- | --- | --- |
| `src/shared` | `ReplicatedStorage.Shared` | Config, types, remote definitions |
| `src/server` | `ServerScriptService.Server` | `Main` entry point + `Services/` |
| `src/client` | `StarterPlayer.StarterPlayerScripts.Client` | `Main` entry point + `Controllers/` |
| `src/tools` | `ServerStorage.Tools` | Edit-mode tools: `MapBuilder`, `DevSync` |

## v0.1 loop

1. Spawn at the Sunset Motel. Stand on a green pad and hold **E** to get a Sedan or Van; press **F** at your car to drive (friends can ride along). Stay on the roads: on grass or sand a car manages about a third of its top speed. Dirt roads count as roads.
2. Press **P** (or click **Phone**) to open the contract board and accept a contract. Contracts are **Routine** (short, cheap), **Standard** or **High-value** (long haul, more pay, cargo police notice more easily). Accepting gives you a **code word**; the GPS routes you to the pickup.
3. At the pickup a **contact** waits. Press **E** to talk and pick the right answer (usually your code word; wrong answers just get a retry). The crate appears on your car; deliver it and hold **E** at the dropoff. Payment goes to dirty cash.
4. Police patrol all the time (most of them downtown), alongside civilian traffic. AI cars keep to their lane and brake for anything in it, then drive around it if it won't move. A patrol that **sees** you speeding, or gets a close look at your cargo, starts watching you (the status panel outline turns blue). If it gets suspicious enough it **tails** you; drive clean and it loses interest. Keep it up and it calls a **pursuit**: you're **wanted**. Ramming a patrol car, or standing or parking in its way and not moving, gets you the same attention. Unseen speeding and gunfire also raise heat; at 50 heat you're wanted too.
5. Wanted: cops chase you with sirens. Stay out of their sight to drain heat. If a cop stays next to you while you're slow or stopped, you're **busted**: cargo confiscated, 25% of dirty cash fined, car impounded, released at the police station.

**Pistol** (on foot only): click to fire, **R** to reload. Hitting a police car 12 times disables it for 20 s, but makes you wanted. Cops fire back only at wanted players running on foot; anyone standing still gets arrested instead. No blood: hits show a white flash, and players at 0 health are "knocked out" and respawn (a wanted player who gets knocked out is arrested).

**Notifications** (contracts, police, busts) pop up on the phone, which peeks up from the bottom of the screen when it's put away. The speedometer has no number; the exact speed is on the phone's GPS.

**Studio debug:** while playing, from the server command bar: `game.ServerStorage.Debug:Invoke("heat", 60)` or `("cash", 1000)`; `print(game.ServerStorage.Debug:Invoke("test"))` runs the server tests (`src/tools/ServerTests.luau`); `game.ServerStorage.Debug:Invoke("contact")` accepts a contract and opens its contact's dialogue. Police cars carry a `PoliceState` attribute (and `Suspicion` in Studio) for watching the AI.

## The map

| District | What it's like | Job points |
| --- | --- | --- |
| Downtown (centre) | Street grid, police station, 3 of the 6 patrols | Parking Lot B; Sunset Motel, Gas Station, Back Alley |
| Industrial + docks (east, across the river) | Wide truck roads, big lots, quay and piers | Rail Yard, Cold Storage, Pier 4; Warehouse 9, Container Yard |
| Outskirts | Woods, hills, farmland, long country and dirt roads | Old Sawmill, Pine Ridge Cabins, Gravel Quarry; Highway Rest Stop, Farmstead Barn, Old Airstrip |

Downtown to the docks: the **highway** (fast, open, one patrol), **Harbor Road** (direct two-lane) or **Ridge Road** (long and quiet, north). The south farm roads and the western loop make longer, calmer routes. Estimated drives (lawful speeds): 15-40 s routine, 40-90 s standard, 90-120 s long.

## Map tags

Tag parts in Studio with the Tag Editor (Properties → Tags):

| Tag | Purpose |
| --- | --- |
| `PickupPoint` | Where the cargo contact stands. The part's Name shows to players, so keep names unique |
| `DropoffPoint` | Where cargo is delivered |
| `PolicePatrol` | Police car chassis (added at runtime) |
| `CarSpawn` | Player car spawn pad; `VehicleType` attribute is `Sedan` or `Van` |
| `PoliceRelease` | Where busted players are released |
| `StreetLight` | Lamps that switch on at night |

Map parts can carry a `Surface` attribute (`asphalt`, `dirt`, `grass`; unlabelled parts count as paved) that car physics and tire trails read; terrain goes by its material. Job point parts also carry a `District` attribute, and MapBuilder puts each in a Persistent model so the phone and GPS find it while the place streams. Road graph nodes have `Links`, `LinkKinds` and `District` attributes; police patrol beats use `District`.

With no tagged points, `Config.Debug.SpawnTestPoints` creates a test pickup and dropoff so the loop works on an empty baseplate.

## Tuning

Everything is in `src/shared/Config.luau`:

| What | Where |
| --- | --- |
| Patrol count per district, how often they stray | `Police.Beats`, `Police.BeatStayChance`, `Police.MaxCops` |
| Detection distance, line of sight, check interval | `Police.Detection.Range`, `CargoRange`, `RequireLineOfSight`, `IntervalSeconds` |
| How fast suspicion builds and fades | `Police.Detection.SpeedingPerSecond`, `CargoPerSecond`, `CargoSuspicionCap`, `HeatMultiplier`, `DecayPerSecond` |
| When a patrol tails / pursues / gives up | `Police.Detection.InvestigateThreshold`, `PursuitThreshold`, `ClearThreshold`, `LoseSightSeconds`, `InvestigateMaxSeconds`, `CooldownSeconds` |
| Heat decay, unseen speeding, wanted threshold | `Heat.DecayPerSecond`, `SpeedingHeatPerSecond`, `SpeedingGraceSeconds`, `WantedThreshold` |
| Contract tiers: drive time, payout, risk, cargo | `Jobs.Tiers`, `Jobs.RouteSpeeds` |
| Contact reach and answer debounce | `Jobs.Contact` |
| Off-road slowdown | `Vehicles.Offroad` |
| How AI cars brake, pass and notice being rammed | `Driving` |
| Ramming and blocking a patrol | `Police.Detection.RamSuspicion`, `RamFullImpact`, `BlockPatienceSeconds`, `BlockSuspicionPerSecond` |
| Civilian traffic: count, speeds, where it spawns | `Traffic` |

Contact lines, questions, decoy answers and code words are server-only, in `src/server/Jobs/ContactLines.luau`.
