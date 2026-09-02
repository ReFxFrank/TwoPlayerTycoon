# Architecture

Three layers, one rule: **the server decides, the client displays, and both read the same rules.**

```
ReplicatedStorage.Modules          (src/shared)   data + pure rules, no side effects
ServerScriptService.Core           (src/server)   every authoritative decision
StarterPlayerScripts.Client        (src/client)   presentation only
```

The shared layer is what keeps the other two honest. `Economy.dropperStatus(plot, def)` decides both
whether a purchase is legal *and* whether the pad's label is greyed out. There is no second
implementation of affordability on the client to drift out of sync with the first.

---

## Shared (`src/shared`)

### Data tables

`DropperData`, `UpgradeData`, `SectionData`, `EvolutionData`, `AffinityData`, `RebirthData`. Each
exposes `List` (ordered), `ById`, and `get(id)`. Pure tables — no logic, no services.

Cross-references between them (a dropper's `RequiredSection`, a stage's `UnlockedDroppers`) are
verified by `tests/specs/data.spec.luau`, which is the only thing standing between a typo and a pad
nobody can ever buy.

### Rules

| Module | Role |
|---|---|
| `Economy` | **Pure rules engine.** Cost curves, income rates, multipliers, and every purchase/attune/transcend gate. Returns closed-set reason codes, never sentences. |
| `StateSchema` | The shape of everything persisted: `newProfile`, `sanitizeProfile`, `migrate`, `mergePlotStates`. |
| `Snapshot` | Renders the StateSync payload. Split from `StateSchema` because replication is a different concern from persistence. |
| `PlotLayout` | Pure geometry: where every wing, pad, rail waypoint and spawn sits. |
| `RemoteSchema` | The wire protocol: every remote, its direction, rate limit and payload validator. |

### Utilities

`GameConfig` (tunables), `Theme` (palette), `Signal`, `TableUtil`, `Format`, `Validate`,
`ClientStore` (the client's observable snapshot).

**Everything in this layer is a total function.** `sanitizeProfile` cannot error on any input.
`Economy` cannot error on a corrupt `PlotState`. `Validate.payload` cannot error on a cyclic table
with a booby-trapped metatable. That is not defensive style for its own sake — the two inputs the
game does not control are a DataStore value and a remote payload, and both land here.

---

## Server (`src/server`)

### Wiring

`Bootstrap.server.luau` registers every service with `ServiceRegistry`, then calls `InitAll()` and
`StartAll()`.

```lua
local Service = {}
Service.Name = "PlotService"
function Service:Init(registry)  -- resolve peers, allocate state. No cross-service calls.
function Service:Start()         -- connect events, start loops.
function Service:Stop()          -- teardown, reverse order.
return Service
```

Two phases, not one. Every service is constructed before any of them starts talking to its peers,
which is what removes the circular-require problem without a dependency-injection framework.
Registration order is dependency order; `StopAll` runs in reverse.

### Services

| Service | Owns |
|---|---|
| `RateLimiter` | Token buckets per (player, remote). Cleared on `PlayerRemoving`. |
| `RemoteService` | The remote folder, and the single guarded dispatcher every inbound message passes through. |
| `DataStoreWrapper` | Retry, backoff, request-budget awareness, transient-vs-fatal classification. |
| `ProfileService` | Session-locked load/save/autosave/`BindToClose`. |
| `EconomyService` | **The only writer of `PlotState.Essence`.** `Credit` and `TryDebit`. |
| `PlotService` | The Sanctum registry: claim, link, release, occupancy, and the one Heartbeat that drives every plot. |
| `PurchaseService` | Every purchase `ProximityPrompt`, listened to **on the server**. |
| `EvolutionService` | Attunement transitions and affinity choice. |
| `RebirthService` | The consensus vote and the reset. |
| `StateReplicator` | Throttled snapshot push. |
| `LeaderboardService` | `leaderstats` mirrors. |

### Systems

`PlotBuilder` (constructs a Sanctum's Instance tree), `DropperSystem` (spawn scheduling),
`MoteSystem` (CFrame transport along rails). These are plain modules owned by `PlotService`, not
registered services — they are per-Sanctum objects, not singletons.

### The one loop

`PlotService` drives every Sanctum from a **single** `Heartbeat` connection, not one per plot:

```
Heartbeat(dt)
  for each sanctum:
      dropperRuntime:Step(dt, multipliers)   -- accumulate timers, emit OnSpawn
      moteRuntime:Step(dt)                   -- advance motes, emit OnCollected
```

`OnSpawn` asks `MoteSystem` for a mote; `OnCollected` calls `EconomyService:Credit`. Nothing in that
path yields, so a slow DataStore can never stall income.

---

## Client (`src/client`)

`ClientBootstrap.client.luau` waits for the remotes folder, builds the UI, creates a `ClientStore`,
then `Init`s and `Start`s each controller with a shared context.

Controllers **never read a remote directly**. They call `store:Observe("Plot.Stage", fn)` and are
invoked once with the current value, then only when that value genuinely changes. Essence updates
twice a second; a stage observer must not rebuild the HUD twice a second because of it.

`UiBuilder` constructs the whole `ScreenGui` in code rather than shipping a `.rbxmx`, so the UI is
reviewable in a diff.

---

## Two data paths

**Purchases do not use a remote.**

```
player holds E on a pad
  -> ProximityPrompt.Triggered fires ON THE SERVER
  -> PurchaseService: is this player an occupant of this sanctum?
  -> Economy.dropperStatus(plot, def) re-checked from scratch
  -> EconomyService:TryDebit
  -> mutate state, mark dirty, fire Fx + Notify
```

Nothing crosses the wire inbound. There is no id to inject, no price to tamper with.

**Everything else is one guarded funnel.**

```
client fires a remote
  -> RemoteService dispatcher
       is the sender a live Player?
       RateLimiter:Consume(player, remoteName, tokens, interval)
       def.Validate(payload)          -- rejects missing, mistyped AND extra keys
       handler registered?
  -> pcall(handler, player, payload)
```

A rejection is counted and logged at most once per player per ten seconds, and **nothing is sent
back explaining why** — a specific rejection reason is free reconnaissance.

---

## Where state lives

| State | Home | Lifetime |
|---|---|---|
| `PlotState` (essence, stage, droppers, upgrades, wings) | the Sanctum, shared by both occupants | resets on Transcendence |
| `Prestige` (rebirths, multiplier, badges) | each player's Profile | permanent, never merged |
| `Settings`, `Stats` | each player's Profile | permanent |
| Occupancy, contribution, votes | `PlotService` runtime | the session |
| Live motes | `MoteSystem` runtime | seconds |

Saving mirrors the live `PlotState` to **every current occupant's** profile — both players carry the
shared result home. Prestige is deliberately in a different table from anything resettable, so a bug
in the reset path cannot destroy the one thing players cannot re-earn.

---

## Testing

The whole server runs headlessly against a mock Roblox environment. See
[TESTING.md](TESTING.md). Any module reachable from a remote or a DataStore has a
"survives hostile input" spec, because those are the two inputs the game does not control.
