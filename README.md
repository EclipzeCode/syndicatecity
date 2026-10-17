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

**Building the map:** run `require(game.ServerStorage.Tools.MapBuilder:Clone()).build()` in the command bar. It deletes and regenerates `Workspace.Map` (graybox district, road graph for police AI, tagged job points, spawns) and applies the lighting baseline. The layout is deterministic.

## Project layout

| Folder | Syncs to | Contents |
| --- | --- | --- |
| `src/shared` | `ReplicatedStorage.Shared` | Config, types, remote definitions |
| `src/server` | `ServerScriptService.Server` | `Main` entry point + `Services/` |
| `src/client` | `StarterPlayer.StarterPlayerScripts.Client` | `Main` entry point + `Controllers/` |
| `src/tools` | `ServerStorage.Tools` | Edit-mode tools: `MapBuilder`, `DevSync` |

## v0.1 loop

1. Spawn at the Sunset Motel. Stand on a green pad and hold **E** to get a Sedan or Van; press **F** at your car to drive (friends can ride along).
2. Press **P** (or click **Phone**) to open the contract board and accept a contract. A marker shows the pickup.
3. Hold **E** at the pickup to load cargo (a crate appears on your car), then deliver it. Payment goes to dirty cash.
4. Speeding (over 50 mph), carrying cargo near a patrol car and firing your pistol raise heat. At 50 heat you're **wanted**.
5. Wanted: two cops chase you. Stay out of their sight to drain heat. If a cop stays next to you while you're slow or stopped, you're **busted**: cargo confiscated, 25% of dirty cash fined, car impounded, released at the police station.

**Pistol** (on foot only): click to fire, **R** to reload. Hitting a police car 12 times disables it for 20 s, but makes you wanted. Cops fire back only at wanted players running on foot; anyone standing still gets arrested instead. No blood: hits show a white flash, and players at 0 health are "knocked out" and respawn (a wanted player who gets knocked out is arrested).

**Studio debug:** while playing, `game.ServerStorage.Debug:Invoke("heat", 60)` or `("cash", 1000)` from the server command bar.

## Map tags

Tag parts in Studio with the Tag Editor (Properties → Tags):

| Tag | Purpose |
| --- | --- |
| `PickupPoint` | Where cargo is loaded. The part's Name shows to players, so keep names unique |
| `DropoffPoint` | Where cargo is delivered |
| `PolicePatrol` | Carrying cargo within 60 studs raises heat (added to police cars at runtime) |
| `CarSpawn` | Player car spawn pad; `VehicleType` attribute is `Sedan` or `Van` |
| `PoliceRelease` | Where busted players are released |
| `StreetLight` | Lamps that switch on at night |

With no tagged points, `Config.Debug.SpawnTestPoints` creates a test pickup and dropoff so the loop works on an empty baseplate.
