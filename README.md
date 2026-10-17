# Smuggling Game

A Roblox crime game: smuggle cargo for syndicates without drawing police attention.
Design doc: https://claude.ai/code/artifact/ee206841-15b3-49f3-b33d-37a4d300e8f5

## Setup

1. Install [Rokit](https://github.com/rojo-rbx/rokit), then run `rokit install` in this folder (installs the Rojo version pinned in `rokit.toml`).
2. Install the Rojo Studio plugin: `rojo plugin install`.
3. In VS Code, install the recommended extensions (Luau LSP, Rojo).
4. Run `rojo serve`, open your place in Roblox Studio, and click **Connect** in the Rojo plugin.

Code lives in `src/` and syncs into Studio. Build the map and everything else in Studio, and save the place file.

## Project layout

| Folder | Syncs to | Contents |
| --- | --- | --- |
| `src/shared` | `ReplicatedStorage.Shared` | Config, types, remote definitions |
| `src/server` | `ServerScriptService.Server` | `Main` entry point + `Services/` |
| `src/client` | `StarterPlayer.StarterPlayerScripts.Client` | `Main` entry point + `Controllers/` |

## v0.1 loop

1. Press **P** (or click **Phone**) to open the contract board.
2. Accept a contract, drive to the pickup and hold **E** to load cargo.
3. Drive to the dropoff and deliver. Payment goes to dirty cash.
4. Speeding and carrying cargo near a police patrol raise heat. At 50 heat you're wanted.

## Map tags

Tag parts in Studio with the Tag Editor (Properties → Tags):

| Tag | Purpose |
| --- | --- |
| `PickupPoint` | Where cargo is loaded. The part's Name shows to players, so keep names unique |
| `DropoffPoint` | Where cargo is delivered |
| `PolicePatrol` | Carrying cargo within 60 studs raises heat |

With no tagged points, `Config.Debug.SpawnTestPoints` creates a test pickup and dropoff so the loop works on an empty baseplate.
