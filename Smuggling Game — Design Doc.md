# Smuggling Game — Design Doc

Oct 17, 2026 · @Vrishank Madishetty

## Overview

A Roblox crime game where players smuggle cargo for crime syndicates without drawing police attention, and progress by surviving bigger and bigger jobs. Every job is a gamble on two fronts: whether the syndicate pays, and whether the police are building a case.

**Pillars**

- **Risk you can read.** Scams, stings and police attention have warning signs. Skilled players learn to spot them.
- **Trust is the currency.** Syndicates, contractors and members can all betray each other. Betrayal should be possible, costly and traceable.
- **The past catches up.** Evidence persists. A clean getaway today can still lead to an arrest next week.
- **No shortcuts.** No fast travel. Moving goods across the map is the gameplay.

**Setting:** a modern city. Start with one dense district (downtown, industrial area and docks, a highway, woods on the edge). New areas come later.

**Server size:** 12–15 players per server at launch, increasing as the map grows.

**Scope:** crime-focused PvE first. Player cops are a later addition.

## Core loop and jobs

A player takes a contract, moves cargo across the map without raising suspicion, decides how much to hand over, then lives with the payout and the evidence they left behind.

1. **Take a contract** on the burner phone.
2. **Agree on terms:** paid upfront, a disclosed amount on delivery, an undisclosed amount on delivery, or items.
3. **Run the job:** pick a vehicle and route, avoid patrols and witnesses.
4. **Hand over the cargo:** deliver all of it, or skim some for yourself.
5. **Get paid, get scammed, or get hunted.**
6. **Deal with the consequences:** evidence, heat, syndicate reputation.
7. **Unlock bigger jobs.**

### Payment types

| Type | Risk to player | Notes |
| --- | --- | --- |
| Upfront, fixed | Lowest | Lower pay |
| On delivery, disclosed | Medium | Can still be scammed |
| On delivery, undisclosed | High | Random amount, sometimes a big payout |
| Items | Varies | Vehicles, gear, safehouse upgrades, cosmetics. "Hot" items raise heat if kept |
| Scam | Total loss | Odds depend on the syndicate's honesty and your reputation with them |

Scams must be readable: shady dialogue, odd meeting spots, terms that are too good. A purely random scam feels unfair.

### NPC syndicates

Each of the 3–5 NPC syndicates has four traits that players learn over time:

| Trait | Affects |
| --- | --- |
| Honesty | How often they pay as promised |
| Generosity | Pay range and item quality |
| Vengefulness | How hard they retaliate against skimming or snitching |
| Police priority | How much heat their cargo carries |

### Skimming

At hand-off, a slider sets how much of the cargo is delivered (0–100%). Detection odds scale with the amount taken and the syndicate's vengefulness. Consequences escalate: warning, then fine or debt, then hit squads or a bounty, then a permanent ban from that syndicate. Rival syndicates may reward you for hurting their enemies.

## Police: heat, evidence and interrogation

Police pressure has two layers: **heat** is short-term attention that decays, and **evidence** is a lasting case file that can lead to arrest long after a job ends.

### Heat (short-term)

Raised by speeding, passing patrols, suspicious vehicles, being seen at meeting spots, and carrying cargo near checkpoints. Lowered by laying low (decay over time), changing vehicles or outfits, and bribes.

### Evidence (long-term)

Evidence is a physical or recorded trace that points to a specific player:

- Dropped bags or cash bundles
- Abandoned or damaged vehicles
- NPC witnesses
- Security cameras
- Reusing the same car or route

Evidence collects into an **investigation file**. Once it passes a threshold, police can arrest the player even after a successful job. Evidence decays slowly, and players can destroy some of it (burning a car, ditching a phone).

### Arrest and interrogation

| Choice | Outcome |
| --- | --- |
| Confess | Lighter sentence. The syndicate learns you talked: reputation loss, possible bounty |
| Play dumb | Dialogue minigame. Contradicting evidence the police hold fails it. Odds improve with a clean record and less evidence |
| Stay silent | Outcome depends only on evidence strength. Weak case: released. Strong case: maximum sentence, but the syndicate respects it (+reputation) |

**Sentence:** a timed stay in a jail area (escape possible), plus confiscated cargo and carried cash. Syndicates can choose to rescue you and break you out, but it depends on your reputation with them.&#32;

## Underground network and economy

All criminal activity runs through an in-game **burner phone**. That's the in-world reason police never see the contracts.

### Burner phone apps

- **Contract board:** visibility depends on reputation. New players see small jobs. Top-tier jobs need a vouch or an invite.
- **Encrypted messages** between syndicates and contractors.
- **Black market:**
  - *Buy:* police scanners, fake plates, vehicles with hidden compartments, disguises, burner phones that wipe links.
  - *Fence:* sell stolen items. The fence takes a cut, and hot items sell for less.
  - Prices shift with supply and local notoriety.
- **Stings (later):** some contracts are police setups with readable warning signs. Cop players can post them once that mode exists.

### Dirty and clean money

| Money | Earned from | Spent on |
| --- | --- | --- |
| Dirty cash | Contract payouts, fencing | Black market, paying criminals and NPC hires |
| Clean money | Laundering, front businesses, safe bank deposits | Hideouts, legal vehicles, upgrades |

- **Bank deposits** of dirty cash raise suspicion once they pass a rolling threshold. Large or frequent deposits create evidence.
- **Front businesses** (office-building hideouts) launder money slowly.
- Cash carried on a player is lost on arrest. Cash in storage is at risk only from raids and theft.

## Solo progression

Solo players level more slowly than syndicate members but pay no upkeep, can't be betrayed by members, and unlock perks no syndicate player can get.

- **Reputation per syndicate** plus a global **Street Rep**.
- **Smuggler rank** unlocks job tiers: backpack courier, car trunk, van, boat, plane drops.
- **Crash pad:** a cheap motel room or apartment that works as a spawn point and a tiny stash.
- **Recruitment offers:** NPC syndicates offer lieutenant positions. Player syndicates can send formal offers that skip the probation rank.

### Perks (from reputation across several syndicates)

| Perk | Effect |
| --- | --- |
| Trusted Courier | Lower scam chance with every syndicate |
| Ghost | Your evidence decays faster |
| Neutral Ground | Work for rival syndicates without penalty |
| Fixer | Broker jobs between syndicates for a cut |

## Player syndicates

Players can found their own syndicates. These earn far more than solo contract work, but every piece of evidence their members leave can be traced back to the leadership.

### Founding

Founding costs a fee to discourage throwaway syndicates. Syndicate names and role names go through `TextService` filtering, as Roblox requires.

### Leadership and roles

| Rank | Powers |
| --- | --- |
| Boss (exactly 1) | Everything, plus exclusive powers: dissolve, transfer or appoint the boss, promote or demote leaders, set the succession order, approve alliances and mergers (later) |
| Underbosses (any number) | Everything else: contracts, hiring, treasury, hideouts, recruiting |
| Custom roles | Permission toggles set by leaders: post contracts, hire NPCs, withdraw, invite, vault access, negotiate |

**Two-key approval:** withdrawals over a threshold, selling a hideout and kicking a member need a second leader's sign-off. One leader can't wipe the syndicate alone; betrayal at that level needs an accomplice.

**Treasury safeguards:** per-role withdrawal limits, cooldowns and an audit log.

### Succession

1. The boss sets an ordered heir list.
2. If the boss is inactive for 14 days, the first active heir becomes boss.
3. With no heirs, the longest-serving active underboss takes over.
4. With no leaders, members vote.

### Contracts

Leaders post contracts with a job, terms and an audience: **internal** (members only), **public board** (solo players) or **NPC hire**. The same payment and scam rules apply, so player syndicates can scam contractors, and contractors can rate syndicates.

### NPC hires

| Stat | Visible? | Effect |
| --- | --- | --- |
| Skill | Yes | Success chance, evidence left behind |
| Cost | Yes | Wage per job |
| Loyalty | No (grows over time) | Resistance to bribes and police deals |
| Greed | No | Chance of skimming |
| Nerve | No | Performance in interrogation |

Hidden stats can be revealed over time or with a paid background check.

### Evidence chain

Evidence points to a member; **links** (seen together, shared vehicles, money transfers, confessions) connect members to each other and to the syndicate. Fewer links keep a syndicate hidden. Using contractors and NPCs adds insulation between leaders and evidence, at the cost of money and more chances for betrayal. A member who confesses reveals only the links they know about.

### Notoriety

| Tier | What police know | Effect |
| --- | --- | --- |
| Ghost | Nothing; separate individuals | No syndicate-level heat |
| Rumored | A group may exist | Random stops on known members |
| Known | Named organization, some members | Safehouse raids, informant offers to members |
| Wanted | Full investigation | Task-force patrols, bigger rewards for informants |
| Untouchable | Too big for local police | Local police back off; federal task forces and rivals step in |

**Anti-snowball:** upkeep grows faster than income, federal task-force events target only Untouchable syndicates, and informant rewards rise with notoriety. Staying on top is constant work.

### Betrayal

- **Police:** an arrested member is offered a reduced sentence for giving up links.
- **Rival bribes:** a secret offer to leak a route (spawns an ambush) or steal from the vault.
- **Greed:** skimming jobs or the treasury, within role limits.

Betrayers can be found through investigation, informants or audit logs, then kicked, fined or put under a bounty. Consequences stay in-game: no public "snitch" labels.

### Organization hierarchy

NPC mega-organizations post high-value contracts that only big player syndicates can take. Player syndicates subcontract to members, NPCs and solo players. Each layer takes a cut and adds insulation.

### Alliances and mergers (later)

Syndicates can team up or merge into a larger network. The data model includes an optional `networkId` from day one so this ships as an addition, not a rewrite.

## Hideouts, stashes and spawning

Syndicates buy hideouts to store loot and spawn in; where they keep their money is a choice between efficiency and safety.

### Hideout types

| Type | Cost | Storage | Suspicion | Special |
| --- | --- | --- | --- | --- |
| Woods spot | Cheap | Small | Very low | Hard to find, no protection, NPCs may stumble on it |
| Warehouse | Medium | Large | Medium | Vehicle bays and loading docks; prime raid target |
| Office building | Expensive | Medium | Low | Front business: launders money, provides alibis |

### Stashes

Small drop points: lockers, buried caches, a car trunk in a parking garage. Each has its own chance of being found by police, rivals or NPCs. Keeping everything in one hideout is efficient but fragile; spreading it out is safer but harder to manage.

### Spawning and travel

- Syndicate members spawn at their hideout. Solo players spawn at their crash pad.
- **No fast travel** within the map. Joining a friend's server is allowed; you still spawn at your own hideout and drive.

### Hideouts across servers

A syndicate's members are spread across server instances, so hideouts can't be fixed plots.

- Each map has a fixed set of **lots per hideout type** (for example 6 warehouses, 6 offices, 8 woods spots).
- A syndicate owns a **type plus upgrades**. When its first member joins a server, the hideout loads into a free lot of that type.
- With 12–15 players, expect 3–6 syndicates per server; a handful of lots per type covers it.
- Stashes use the same pattern: fixed spawn points assigned to owners.

### Raids

- **Live raids** happen only when members are in that server.
- **Offline raids** are resolved by a server-side roll against stored loot; members are notified on their next login.

## Technical architecture

The server is authoritative for everything that touches money, evidence or outcomes. Clients only send requests and render state.

### Stack and workflow

| Concern | Choice |
| --- | --- |
| Language | Luau with `--!strict` typing |
| Editing | VS Code + Rojo (file sync into Studio) + Luau LSP |
| Packages | Wally |
| Version control | Git |
| Player saves | ProfileStore over DataStoreService |
| Cross-server live state | MemoryStoreService (contract board, who's online) |
| Cross-server events | MessagingService (raids, notoriety changes) |
| NPC movement | PathfindingService |

### Server modules

JobManager, PaymentManager, HeatManager, EvidenceManager, InterrogationManager, SyndicateManager, HideoutManager, MarketManager. Each is a ModuleScript under ServerScriptService.

### Rules

- Every `RemoteEvent` is an untrusted public API: validate type, range, ownership and cooldowns on the server.
- Payment rolls, scam checks, detection rolls and evidence creation happen only on the server.
- Shared balances (treasuries, vaults) change only through `UpdateAsync`, never read-then-`SetAsync`.

### Data model

```
Player(id, cleanCash, dirtyCash, heat, streetRep, crashPadId)
Syndicate(id, name, bossId, notoriety, treasuryClean, treasuryDirty, networkId?)
Role(id, syndicateId, name, rank, permissions{})
Membership(playerId, syndicateId, roleId, joinedAt, heirOrder?)
Hideout(id, ownerSyndicateId, type, upgrades{}, storage[])
Stash(id, ownerId, ownerType, slotKey, contents[], discoveryRisk)
Contract(id, issuerId, audience, terms, cargo, status, assigneeId?)
Evidence(id, pointsToPlayerId, kind, strength, decaysAt)
Link(aPlayerId, bPlayerId, kind, strength, knownToPolice)
Reputation(playerId, syndicateId, score)
```

On DataStores these become keyed stores for players, syndicates and contracts, with evidence and links stored on each player record. If the evidence graph outgrows key-value storage, move it to Postgres behind an external API called through `HttpService`.

## Monetization and Roblox compliance

The goal is a fun game that covers its own costs, not maximum revenue, so nothing sold affects risk or power.

### Monetization

- **Sell:** cosmetics, vehicle garage slots, private servers.
- **Don't sell:** loot storage, heat reduction, evidence removal, better payouts. Storage and risk are core gameplay, so selling them is pay-to-win.
- **Never** sell randomized rewards for Robux. Random payouts are fine because they're earned in-game.
- Roblox hosting is free. The only running cost would be an external backend, which is a reason to stay on native storage.

### Compliance

- **No drugs.** Cargo is cash, gold, contraband crates, stolen art and electronics.
- Stylized violence only. Fill out the Maturity & Compliance questionnaire honestly.
- No real-world gang names or symbols.
- Filter all user-created text (syndicate names, role names, messages) with `TextService`.

## Roadmap

&#91;embedded content: roadmap · 3 phases, 9 releases\]

v0.1 is the current focus. If driving cargo past police isn't fun on its own, fix that before adding any later system.

## Open questions

- [ ] Hideout lot counts per type for the first district
- [ ] Inactivity window that triggers succession (14 days proposed)
- [ ] Cash threshold for two-key approval
- [ ] Bank deposit suspicion threshold and decay rate
- [ ] Jail sentence lengths in real time
- [ ] Do NPC syndicates compete with player syndicates for the same contracts in v1?
