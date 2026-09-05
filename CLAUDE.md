# Working on Sanctum of Embers

A two-player evolution tycoon for Roblox, Luau + Rojo. Read `docs/ARCHITECTURE.md` for the module
map and `docs/DECISIONS.md` for why the design is the way it is — several things that look odd are
deliberate and the reasoning is recorded there.

## Commands

```bash
./tests/run.sh              # syntax + house rules + 304 tests   (~45s)
./tests/run.sh economy      # only specs matching a substring    (~5s)
rojo serve                  # then connect from Studio
rojo build -o SanctumOfEmbers.rbxlx   # REQUIRED after any src/ change; CI fails on a stale file
```

Tests need Node 18+ and the [Luau CLI](https://github.com/luau-lang/luau/releases) (`LUAU_BIN` if it
is not on `PATH`). Neither is needed to play the game.

## House rules

`tests/run.sh` enforces these; it is not advisory.

- **No file over 300 lines.** When one grows past it, split along a real seam and name the new
  module for the concern, not "part two". Every existing split has one (`ProfileLock` is the lock
  protocol, `PlotTick` is the income loop, `PrestigeAward` is what a transcendence pays).
- `--!strict`, and the header comment block on every ModuleScript.
- Modern idioms only: `task.wait`/`task.spawn`/`task.defer`/`task.delay`, `:Connect`, `workspace`,
  `:Destroy()`. Never `wait`/`spawn`/`delay`/`:connect`/`game.Workspace`/`Instance:Remove()`.
- Comments explain **why**. Document each defensive check with the failure it prevents.
- Shared data tables live in `src/shared` and are read by both sides, so the client's idea of what a
  purchase costs and the server's cannot drift.

## The thing this codebase gets wrong most

**Wiring gaps.** Eleven defects were found here, and almost none were bad logic. They were modules
that were correct in isolation and that nothing ever called:

- the link gate refused every player, because everyone auto-claims a plot on join;
- nothing called `ProfileService:LoadAsync`, so no join ever loaded a profile;
- no client listened for `LinkOffer`, so nobody could accept a link;
- `SetSetting` and `ResetData` had no server handler at all.

Every module's own tests passed through all of it. Two structural guards now exist because
per-feature tests structurally cannot catch this — there is no code to write a test against:

- `regression.spec` — every client→server remote must have a handler.
- `client.spec` — every server→client remote must have a listener.

**If you add a remote, a controller or a service, add it to those lists.** And when you finish a
feature, trace it once from its real trigger — a prompt press, a `PlayerAdded`, a remote — rather
than from its entry point.

## Testing

`docs/TESTING.md` explains the harness in full. The essentials:

- The whole server runs headlessly against a mock Roblox in `tests/mock/`. `integration.spec` boots
  the real `Bootstrap.server.luau`; `client.spec` boots the real `ClientBootstrap`.
- **The clock is virtual.** Nothing happens until `Mock.advance(seconds)`.
- **Load stateful services inside a test, never at the top of the file.** `Mock.reset()` clears the
  module cache, so a reference captured at registration points at the previous test's instance.
- `Mock.fireServer` bypasses every client-side check on purpose — it is the exploiter's path, which
  is what makes it the right tool for proving the server does not trust the client.
- `pacing.spec` is the slow one (~40s); it plays ~50 simulated minutes twice.

## A caution about measurement

`pacing.spec` measures the progression curve, and it once reported a 16-minute "wall" that did not
exist: its simulated player spent every coin the instant it landed and so never banked an attunement
cost. Three documents were edited before anyone checked. The balance was nearly changed to fix a
problem the test had invented.

A measurement is only as good as the model inside it. Before acting on a number this suite produces,
ask what would have to be true for it to be measuring something other than what you think.

## Balance

Numbers live in `src/shared/*Data.luau` and are the single source of truth. `docs/GAMEPLAY.md`
publishes the measured curve, and `pacing.spec` fails if a change moves it by a factor or makes it
lumpy — so a balance change means updating the document with a fresh measurement, not adding a
global multiplier.

## Out of scope for v1

Trading between Sanctums, real developer-product purchases (structured for — `Prestige` is already
separate from resettable state — but not wired), deep mobile polish, custom art. Audio is fully
wired but silent: asset ids go in one table at the top of `SoundController`, and a missing id is a
no-op rather than an error.
