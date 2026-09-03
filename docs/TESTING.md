# Testing

The game runs headlessly. `tests/` contains a small Roblox emulator, so the whole server — plot
assignment, income, purchases, attunement, transcendence, persistence — can be exercised without
opening Studio.

```bash
./tests/run.sh              # syntax-check every .luau, then run every spec
./tests/run.sh economy      # only specs whose name contains "economy"
```

Requires Node 18+ and the [Luau CLI](https://github.com/luau-lang/luau/releases). Point `LUAU_BIN`
at the binary if it is not on `PATH`. Neither is needed to *play* the game — this is developer
tooling and is deliberately absent from `default.project.json`.

## How it works

Roblox source cannot be fed to the stock `luau` CLI: it calls `game:GetService`, builds Instances,
and requires by `script.Parent.X`. `tests/tools/bundle.mjs` bridges that:

1. Walk `src/` and map every file to the instance path Rojo would give it
   (`src/server/Services/PlotService.luau` → `ServerScriptService/Core/Services/PlotService`).
2. Wrap each file's source in `function(script, require, ...) … end`, so `script` and `require`
   become ordinary parameters the mock supplies.
3. Concatenate: mock environment → module registry → test framework → specs.
4. Run the result through `luau` as **one chunk**, so a syntax error in any file fails the build.

The only rewrite is stripping `export ` from `export type` — Luau allows exported type aliases at
module scope only, and wrapping puts them in a function body. Exported types are editor-time
metadata, so this cannot change runtime behaviour.

## What the mock provides

`tests/mock/` builds up in four layers:

| File | Provides |
|---|---|
| `Json.luau` | encode/decode behind `HttpService`, and the DataStore serialisation check |
| `Datatypes.luau` | Vector2/3, CFrame (real 3×3 basis, quaternion `Lerp`), Color3, UDim2, Enum, … |
| `Instances.luau` | the Instance tree: parenting, `IsA`, attributes, signals, `Clone`/`Destroy`, RemoteEvents |
| `Services.luau` | the virtual clock, `task.*`, Heartbeat, Players, Debris, Tween, DataStore |
| `Roblox.luau` | the control surface tests drive |

**The clock is the interesting part.** Nothing happens unless a test says so:

```lua
task.delay(2, function() print("later") end)
Mock.advance(1.5)   -- nothing yet
Mock.advance(1.0)   -- "later"
```

`task.wait` inside a scheduler-owned coroutine parks and resumes when the virtual clock reaches its
deadline. On the test thread it *fast-forwards* instead, so a spec can call a yielding API
(`ProfileService:LoadAsync`) directly and still return. Heartbeat fires ~30× per simulated second.

## Control surface

```lua
Mock.advance(seconds)              -- run the world forward
Mock.addPlayer(name, userId)       -- fires PlayerAdded, loads a character
Mock.removePlayer(player)          -- fires PlayerRemoving
Mock.triggerPrompt(prompt, player) -- a purchase, exactly as the server sees it
Mock.fireServer(name, player, ...) -- a client remote call, bypassing all client-side checks
Mock.outboxFor(remoteName)         -- everything the server replicated
Mock.asClient(player, fn)          -- run fn with RunService reporting a client context
Mock.shutdown()                    -- run BindToClose handlers
Mock.restartServer()               -- drop all runtime state, KEEP datastore contents
Mock.DataStore.failNext(n)         -- make the next n datastore calls throw
Mock.DataStore.failAlways(bool)
Mock.DataStore.setLatency(seconds)
Mock.DataStore.setBudget(n)
```

`Mock.fireServer` deliberately bypasses every client-side check — it is the exploiter's path, which
is what makes it the right tool for testing that the server does not trust the client.

## Writing a spec

A spec is a plain Luau file in `tests/specs/`. It receives `t` (the registry and assertions), plus
`Mock`, `loadModule` and `runScript` as upvalues:

```lua
local Economy = loadModule("ReplicatedStorage/Modules/Economy")

t.test("a fresh sanctum cannot afford stage 2", function()
    local ok, reason = Economy.attuneStatus({ Essence = 0, Stage = 1 })
    t.falsy(ok)
    t.eq(reason, Economy.Reason.NeedEssence)
end)
```

Assertions: `t.eq t.neq t.near t.gt t.lt t.truthy t.falsy t.deepEq t.throws t.noThrow t.fail`.

`Mock.reset()` runs before **every** test: fresh instance tree, fresh clock, fresh modules, fresh
datastores. Nothing leaks between tests.

**Load stateful services inside the test, not at the top of the file.** A service module is a
singleton holding live state — loaded profiles, memoised DataStore handles, event connections.
`Mock.reset()` clears the module cache, so a reference captured at registration time keeps pointing
at the *previous* test's instance, complete with its state and its now-detached store handle. Pure
modules (`Economy`, `StateSchema`, the data tables) are safe to capture at the top because they hold
nothing.

```lua
local function boot()
    local wrapper = loadModule("ServerScriptService/Core/Services/DataStoreWrapper")
    local profiles = loadModule("ServerScriptService/Core/Services/ProfileService")
    profiles:Init({ Get = function() return wrapper end })
    profiles:Start()
    return profiles
end

t.test("...", function()
    local ProfileService = boot()   -- fresh instance, clean world
end)
```

## The slow one

`pacing.spec` takes ~40 seconds because it genuinely plays the game twice — around 50 simulated
minutes per run, driven through the real purchase and attunement paths. Everything else finishes in
about five seconds. It earns the time: it is the only test that can catch the published progression
curve drifting away from the one the game actually delivers, which is exactly what had already
happened when it was written.

Run just the fast specs while iterating:

```bash
./tests/run.sh economy      # or any substring
```

## Conventions

- Test the *contract*, not the implementation. Reason codes, cost monotonicity and gate outcomes are
  the contract; the shape of an internal helper is not.
- Every module reachable from a remote or a DataStore gets a "survives hostile input" test. Corrupt
  saves and forged payloads are the two inputs the game does not control.
- When a test and the implementation disagree, decide which is right before changing either. Several
  bugs in this codebase were found exactly there, and at least one "failure" was the test being
  wrong in a way that would have made the code worse.
