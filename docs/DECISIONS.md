# Design decisions

Every entry here is a fork in the road where more than one answer was defensible. The point of the
document is not to argue that the chosen answer is the only one — it is to record what was traded
away, so a future change can be made deliberately.

**Status:** every decision below has been reviewed and confirmed by the project owner. Where a
choice was put to them explicitly, the alternatives they were offered are listed with it.

---

## 1. Theme: Elemental Creatures

Taken as the brief's default. Everything is named from one fiction so the vocabulary stays
teachable:

| Concept | In-game name |
|---|---|
| plot | **Sanctum** |
| currency | **Essence** |
| dropper | **Wellspring** |
| dropped part | **Mote** |
| conveyor | **Ley Rail** |
| collector | **Conflux Font** |
| evolution | **Attunement** |
| evolution step | **Stage** |
| rebirth | **Transcendence** |
| plot expansion | **Wing** |
| element | **Affinity** |

Six Stages: Mote → Wisp → Sprite → Elemental → Warden → Primordial.
Four Affinities: Ember, Tide, Terra, Zephyr.

Nothing is borrowed from any existing game — the genre structure is the only reference.

---

## 2. Shared wallet, per-occupant contribution

**Chosen:** one Essence pool per Sanctum; each occupant's contribution is tracked separately and
shown on the leaderboard.

A split wallet makes the second player a neighbour rather than a partner: you would each be running
your own tycoon in the same postcode. The shared pool is what makes "should we buy the wing or save
for the attunement?" a conversation. Contribution tracking exists so the shared pool does not erase
individual effort — you can still see who carried.

**Traded away:** a freeloader in the second slot cannot be starved out by the mechanics. Mitigated
socially (contribution is visible) rather than mechanically, because an anti-freeloader rule would
also punish a partner who joined late or went AFK for a minute.

**Server size:** 12 players, six Sanctums on a 240-stud grid. Small enough that a plot always feels
like yours and that six simultaneous mote simulations stay cheap. *Alternatives considered: 24
players / twelve Sanctums (busier, doubles simulation load, would need the mote cap revisited); 8
players / four Sanctums (cheapest, but a full server turns partners away, which hurts the hook).*

---

## 3. Linked plots with max-merge, not independent half-plots

**Chosen:** a Sanctum has two slots and ONE progress state. The second slot is opt-in: standing on
the link pad offers a link, the occupant must accept, and the joiner must confirm.

On link, the joiner's saved `PlotState` is **max-merged** into the live Sanctum:

```
Essence          = max(a, b)
Stage            = max(a, b)
LifetimeEssence  = max(a, b)
Droppers[id]     = max(a[id], b[id])   for every id
Upgrades[id]     = max(a[id], b[id])   for every id
Sections         = union
```

Max-merge is the important part. *Both alternatives were put to the project owner and rejected;
each has a victim:*

- *Joiner adopts the host's state* — a player with more progress loses it by being sociable.
- *Joiner keeps their own, host's plot is ignored* — then it is not a shared plot at all.

Max-merge means **nobody can lose anything they owned by playing together**. The cost is that it is
generous: linking with a stronger partner is a genuine boost. That is a deliberate incentive to play
the two-player mode, which is the entire hook of the genre.

On save, the live state is written to **every current occupant's** profile, so both players carry
the shared result home. `Prestige` (rebirth count, permanent multiplier, badges) is per-player and
is **never** merged — it is the one thing you can only earn yourself.

---

## 4. Six evolution stages

The brief's default. Six is enough for the multiplier curve to feel like it has chapters (early,
mid, late) without the middle stages becoming filler. Stage costs are tuned so the first attunement
lands a few minutes in — early enough to teach the mechanic before the player decides whether to
stay.

---

## 5. Solo play is first-class

**Chosen:** a solo player occupies slot 1 of a two-slot Sanctum and plays the full game. Slot 2 stays
open to late joiners.

The alternative — matchmaking a solo joiner with a bot — was rejected. A bot partner either
contributes (making solo strictly better than it should be) or does not (making it set dressing that
still occupies the slot a real player could take).

---

## 6. A partner leaving does not pause the Sanctum

**Chosen:** when one occupant leaves, the Sanctum keeps running for whoever is left. The leaver's
profile is saved on the way out. When the last occupant leaves, the state is saved and the Sanctum
is released after a grace period so a disconnect-and-rejoin does not cost the plot.

Pausing income on a partner's departure punishes the player who stayed for something they did not
do. The grace period exists because Roblox disconnects are common and losing a plot to a dropped
connection would be the single most frustrating thing in the game.

---

## 7. Purchases go through server-listened ProximityPrompts, not a remote

**Chosen:** every purchase — wellspring, upgrade, wing, attunement — is a `ProximityPrompt.Triggered`
connection **on the server**. There is no client→server "buy this" remote at all.

This is the strongest available position: a `Triggered` event carries the player and the prompt, both
of which the server already trusts. There is no payload to forge, no id to inject, no amount to
tamper with. An exploiter's only lever is triggering a prompt they can reach, which is exactly what
a legitimate player does — and the server still re-checks affordability, unlocks and occupancy
before granting anything.

The remaining client→server remotes are the ones that genuinely need a client decision:
`RebirthVote`, `ChooseAffinity`, `SetSetting`, `LinkResponse`, `RequestSnapshot`, and a
debug-gated `ResetData`. Every one is rate-limited and payload-validated, and none of them accepts
a quantity, price or balance.

**Traded away:** a menu-driven shop UI. In-world pads are more work to lay out and mean the player
must walk to buy things. For a tycoon that is a feature, not a cost.

---

## 8. Motes are CFrame-driven along a path, not physics parts

**Chosen:** a Mote is an anchored part advanced along a precomputed rail path by a single server
`Heartbeat` loop. It is collected when its path progress reaches 1 — no `Touched`, no collision
queries, no physics solver.

Sixty simulated parts per Sanctum × six Sanctums is 360 unanchored parts under the physics solver in
the naive version, plus a `Touched` connection each. The path model costs one table update per mote
per tick and is deterministic, which is also what makes the income tests reproducible.

Live motes are capped per Sanctum. Past the cap, income is **credited immediately without spawning a
part** — so a player who lets motes pile up loses visual feedback, never Essence. Every part also
gets a `Debris:AddItem` lifetime as a leak backstop.

---

## 9. Transcendence needs consensus from both occupants

**Chosen:** Transcendence resets the whole shared Sanctum, so every occupant must vote yes inside a
30-second window. All voting occupants receive the reward. The vote auto-cancels if someone leaves.

A shared plot with a unilateral reset button is a griefing tool. Requiring consensus turns the
biggest decision in the game into the one that most needs a conversation, which is the point of a
two-player mode. A solo occupant's single yes is unanimous, so playing alone is never blocked.

*Alternatives considered: either occupant can trigger it (simpler, no vote UI — but one player can
erase an hour of the other's work with one prompt); only the original claimer decides (unambiguous
authority, but the partner has no say in the biggest decision affecting a plot they built).*

---

## 10. Prestige adds, it does not multiply

`sanctumMultiplier = 1 + Σ(0.25 × rebirths)` across occupants, rather than the product of each
player's personal multiplier.

Multiplying would make two 10-rebirth veterans earn 12.25× — an incentive to only ever play with
someone at your exact level. Adding gives 6×: a veteran still meaningfully lifts a newcomer's
Sanctum, and pairing up is always worth it, but the gap between "played with a veteran" and "played
alone" does not become the whole game.

---

## 11. Reason codes are a closed set

`Economy` returns codes (`locked_stage`, `insufficient`, `max_owned`, …), never sentences. The
client owns the wording. This keeps a single source of truth for *whether* something is allowed
while letting the UI localise, and it stops the server leaking internal detail into a string an
exploiter can read.

---

## 12. Schema version from day one

Every profile carries `SchemaVersion`. `StateSchema.migrate` dispatches on it and
`StateSchema.sanitizeProfile` repairs anything that arrives malformed — the version field is what
makes the *next* change safe, and the sanitiser is what makes a corrupt or tampered save a
non-event instead of a crash loop.

---

---

## 13. Pacing: ~55 minutes to transcend-ready

Measured by playing the game in the harness (`tests/specs/pacing.spec.luau`), not modelled: first
purchase at 0.7 min, Stage 2 at 6.2 min, Stage 6 at 47.5 min, transcend-ready at 49.9 min, dropping
to 25.0 min at four rebirths. Long enough that reaching Primordial feels earned, short enough to
reach in one sitting.

An earlier version of this document published 4.3 min for Stage 2 and claimed rebirth cut the run to
a third. Both came from a balance model rather than a measurement, and both were wrong — Stage 2 is
44% later than claimed, and prestige halves the run rather than thirding it. The numbers above are
now asserted by a test, so the document cannot drift from the game again. See GAMEPLAY.md for the
stage-2→3 wall the measurement also exposed.

*Alternatives considered: ~25 minutes (better for an audience that decides in ten minutes, but the
mid-game thins out and the six stages start to blur); ~2 hours (makes rebirth multipliers matter
more and suits a return-daily audience, riskier for first-visit retention).*

The numbers in `src/shared/*Data.luau` are the tuning. Changing pacing means changing them, not
adding a global multiplier.

---

## 14. The data-reset button is Studio-only

The settings menu has a hold-to-confirm "reset my save" action. It is gated twice:
`GameConfig.Debug.AllowDataReset` compiles the feature in at all, and
`GameConfig.Debug.DataResetStudioOnly` keeps it out of players' reach on a live server.
`ProfileService` enforces this authoritatively; `SettingsController` hides the button under the same
condition. Both checks exist because the client hiding a button is a courtesy, not a control.

*Alternatives considered: ship it to players (some tycoons do — accept that a few will destroy their
save and ask for it back); remove it entirely (smallest attack surface, but test data then has to be
cleared by hand through the DataStore).*

---

## 15. Audio is wired but silent

`SoundController`, the Music/SFX toggles and every play call are complete. Every Roblox asset id
lives in one table at the top of the file, empty and marked `TODO`. A missing id makes the call a
silent no-op rather than an error, so the game is fully playable before any audio exists and becomes
audible the moment ids are filled in.

Inventing plausible-looking asset ids was rejected: an id that cannot be verified is either silent
anyway or, worse, the wrong sound shipped confidently.

---

## Deliberately out of scope for v1

Trading between Sanctums, real developer-product purchases (the code is structured to accept them —
`Prestige` is already separated from resettable state — but nothing is wired), deep mobile UI
polish, and custom art beyond blocky placeholders.
