# Sanctum of Embers

A two-player evolution tycoon for Roblox, built in Luau with Rojo.

Two players share a **Sanctum**. At its centre floats the **Conflux** — one elemental entity the
pair grows together. Machines called **Wellsprings** condense **Essence** into **Motes** that ride
**Ley Rails** into the **Conflux Font**. Spending Essence attunes the Conflux through six Stages, and
at the last one the pair can **Transcend** for a permanent multiplier and start again stronger.

Everything — the fiction, the evolution tree, the economy, the art direction — is original. The
reference game was used for genre structure only.

---

## Quick start

**Just want to play it?** Open `SanctumOfEmbers.rbxlx` in Roblox Studio and press Play. It is a
built place file committed alongside the source, so nothing needs installing.

**Working on it?**

```bash
rokit install                    # rojo, stylua, selene, lune
rojo serve                       # then connect from Roblox Studio and Play
```

Rebuild the place file after changing anything under `src/`:

```bash
rojo build -o SanctumOfEmbers.rbxlx
```

Run the tests (needs Node 18+ and the [Luau CLI](https://github.com/luau-lang/luau/releases)):

```bash
./tests/run.sh
```

CI runs exactly this on every push, and also fails if the committed place file is stale.
That syntax-checks every file, enforces the house rules, and runs 304 tests — the whole game server
executes headlessly against a mock Roblox environment. See [docs/TESTING.md](docs/TESTING.md).

---

## The loop

1. **Claim.** You spawn and take slot 1 of a free Sanctum. Slot 2 stays open.
2. **Link.** A second player steps on the link pad and offers to join. Both confirm, and the two
   saves are **max-merged** — neither player loses anything they owned.
3. **Earn.** Wellsprings drop Motes onto the Ley Rails. Motes reaching the Font credit the shared
   Essence pool. Each occupant's contribution is tracked separately.
4. **Spend.** Walk to a pad and buy: more Wellsprings, Ley Rail and Font upgrades, or a new **Wing**
   to build in.
5. **Attune.** At each threshold the pair can advance the Conflux a Stage: new model, higher income
   multiplier, faster movement, and the next tier of Wellsprings unlocked.
6. **Choose an Affinity.** At Stage 3 the pair binds the Conflux to Ember, Tide, Terra or Zephyr.
   Each is a genuine trade-off, not an upgrade — see [docs/DECISIONS.md](docs/DECISIONS.md#10).
7. **Transcend.** At Stage 6, *both* occupants must vote yes. The Sanctum resets; every voter keeps a
   permanent multiplier, a rebirth count and a milestone badge.

---

## Layout

```
src/shared/     → ReplicatedStorage.Modules                 one source of truth for server + client
src/server/     → ServerScriptService.Core                  every authoritative decision
src/client/     → StarterPlayer.StarterPlayerScripts.Client  presentation only
tests/          (dev only — never synced to Roblox)
docs/
```

`src/shared` holds the data tables (wellsprings, upgrades, wings, stages, affinities, badges) and
the pure rules engine. **The client and the server read the same module** — `Economy.dropperStatus`
decides both whether a purchase is legal and whether the pad's label is greyed out, so the two can
never drift apart.

Full module-by-module walkthrough: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
Gameplay and balance: [docs/GAMEPLAY.md](docs/GAMEPLAY.md).

---

## Anti-exploit posture

- **Purchases never cross the wire.** Wellsprings, upgrades, wings and attunement are all
  `ProximityPrompt.Triggered` connections *on the server*. There is no "buy this" remote to forge.
- **No client→server message carries a quantity, price or balance.** The six that exist —
  `RebirthVote`, `ChooseAffinity`, `SetSetting`, `LinkResponse`, `RequestSnapshot` and a debug-gated
  `ResetData` — are each rate-limited by a token bucket and validated against a declared payload
  shape that rejects missing, mistyped *and* unexpected fields.
- **Every economy mutation goes through one function.** `EconomyService:Credit` / `:TryDebit` are the
  only writers of `Essence`.
- **Loaded saves are treated as hostile.** `StateSchema.sanitizeProfile` clamps every number, drops
  unknown ids and repairs any shape, so a corrupt or tampered profile is a non-event.

There is a spec for each of those claims.

---

## Persistence

`ProfileService` wraps `DataStoreService` with:

- exponential backoff (1, 2, 4, 8, 16s with jitter) and request-budget awareness
- **session locking** via `UpdateAsync`, with a stale-lock steal so a crashed server cannot lock a
  player out permanently
- autosave on a jittered interval, save on leave, and `BindToClose` on shutdown
- a `SchemaVersion` on every profile from day one, so the next migration is already possible

If the DataStore is unreachable the player still gets a session — on an explicitly non-saving
profile, so a transient outage can never overwrite real data with a blank one.

---

## Status

Complete against the v1 brief, and verified rather than asserted. `tests/specs/integration.spec.luau`
boots the real `Bootstrap.server.luau`, joins two players through `PlayerAdded`, links them, buys
from in-world pads by triggering the actual ProximityPrompts, attunes through all six stages, picks
an affinity, transcends on a consensus vote, and reloads everything after a simulated server
restart — then fires hostile payloads at every remote and checks that essence, stage and prestige
did not move.

Eleven defects were found and fixed along the way, and the pattern in them is worth stating: almost
none were logic errors. They were **wiring gaps** — a module correct in isolation that nothing ever
called — and **stale state**, a value left describing a world that had moved on. Every one passed
the full suite before it was found.

The three that mattered most were all the same shape, and all invisible to unit tests:

- **Linking was unreachable.** Every player auto-claims a Sanctum on join, and the link gate refused
  anyone who already had one — so the two-player hook would have refused every request in
  production.
- **Joining never loaded a profile.** Nothing called `ProfileService:LoadAsync`, so the whole chain
  hanging off `ProfileLoaded` — claiming a plot, leaderstats, replication — never started.
- **No client ever listened for the link offer.** The server pushed `LinkOffer`, the modal was
  built, and nothing consumed it, so an occupant was never asked and could not accept.

The published progression curve is now measured rather than modelled: `tests/specs/pacing.spec.luau`
plays the game and reports where each milestone falls, and guards against the curve going lumpy.
The original balance model turned out to be close; the one claim it got wrong — that rebirth cuts
the run to a third, when it halves it — is corrected.

The suite now carries a structural guard in each direction — every client→server remote must have a
handler, every server→client remote must have a listener — because those are the tests that catch a
feature nobody wired, and no per-feature test can: there is no code to write a test against.

Out of scope by design: trading between Sanctums, real developer-product purchases (the code is
structured for them — permanent progression is already separate from resettable state — but nothing
is wired), deep mobile UI polish, and custom art beyond blocky placeholders. Audio is fully wired
but silent: drop asset ids into the one table at the top of `SoundController` and it plays.
