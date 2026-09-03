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

Several modules were split out purely to stay inside the project's 300-line ceiling. In every case
the cut followed a real seam, so the split is worth keeping on its own merits — the sub-module is
named for a distinct concern rather than "part two".

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
| `LeaderboardService` | `leaderstats` mirrors, clamped into 32-bit range. |

Sub-modules, each owned by exactly one service above:

| Module | Owner | Role |
|---|---|---|
| `ProfileLock` | ProfileService | The session-lock protocol: how a stored record encodes ownership, when a lock may be stolen, and the lock-aware write. |
| `ProfileRemotes` | ProfileService | The two remotes it owns — the Music/Sfx toggles and the Studio-gated data reset. |
| `PlotSession` | PlotService | A player's relationship to a plot: claim, adopt, link gates, release, grace. |
| `PlotRuntime` | PlotService | One Sanctum's machinery: model, emit clock, mote pool, rail cache, wing visibility. |
| `PlotLinkController` | PlotService | The link offer book: who has been asked, and when the offer expires. |
| `PlotMirror` | PlotService | The Profile ↔ PlotState bridge. The only place that decides which direction state flows. |
| `PlotTick` | PlotService | The one income loop, and the two pieces of clock state a restart must not inherit. |
| `PrestigeAward` | RebirthService | What a Transcendence pays one player. The only code that writes what a player cannot re-earn. |
| `PurchasePads` | PurchaseService | The per-pad verdict: what a pad says and whether it is live. |

### Systems

`PlotBuilder` (constructs a Sanctum's Instance tree) with `BuildKit` (its construction primitives —
a Part factory that cannot forget to anchor, a sign factory, the shared extents; no game knowledge),
`DropperSystem` (spawn scheduling) and `MoteSystem` (CFrame transport along the rails). These are
plain modules owned by `PlotService`, not registered services — they are per-Sanctum objects, not
singletons.

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

The client decides nothing. It renders the snapshot and forwards intent; every gate it displays is
computed by the same `Economy` module the server authorises with, so the two cannot drift.

`ClientBootstrap` waits for the remote folder, builds the UI, creates the `ClientStore`, and is the
**only** place `StateSync` is read. Each controller is required and started inside a `pcall`, so one
broken controller cannot leave the player with no HUD at all.

| Controller | Role |
|---|---|
| `UiBuilder` / `UiModals` | Build the whole ScreenGui in code and return named references. No behaviour. |
| `HudController` | Essence, income, stage, multiplier, partner panel, action bar. Owns the one reason-code → text table. |
| `PromptController` / `PadVerdict` | In-world pad wording and affordability. Skips pads on other players' Sanctums, whose verdicts belong to their state, not yours. |
| `LinkController` | The link offer: shows it, runs the confirmation clock, answers with `LinkResponse`. |
| `RebirthController` | The Transcendence warning and the live consensus vote. |
| `AffinityController` | The Stage 3 elemental choice, with each element's real trade-off numbers read from data. |
| `SettingsController` | Music/Sfx toggles and the Studio-gated, hold-to-confirm data reset. |
| `NotifyController` | The toast stack, rate-limited so a burst cannot cover the screen. |
| `EvolutionFxController` | Attune/transcend/purchase/link feedback. |
| `SoundController` | Fully wired, silent until asset ids are filled in. A missing id is a no-op, never an error. |

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
