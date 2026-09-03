# Gameplay and balance

Every number here lives in `src/shared/*Data.luau`. That is the source of truth; this document
explains the shape of the curve and why it is that shape.

---

## The economy in one paragraph

A **Wellspring** emits a **Mote** every `Interval` seconds. The Mote rides a **Ley Rail** to the
**Conflux Font**, and on arrival credits `BaseValue × multiplier` **Essence** to the Sanctum's shared
pool. Income per second is therefore just `Σ (BaseValue / Interval) × multiplier` over every
Wellspring owned. Rail travel time changes *when* Essence lands, never *how much* — so a player can
watch the rails fill without doing mental arithmetic about latency.

```
multiplier = Prestige × Stage × Affinity × Upgrades

Prestige  = 1 + Σ(0.25 × rebirths)   over both occupants   (adds, does not multiply — see DECISIONS)
Stage     = 1.0 → 5.5                 across the six stages
Affinity  = 1.00 → 1.22               depending on the elemental line
Upgrades  = 1 + Σ(GlobalIncome levels)
```

---

## Wellsprings

Ten of them, two per stage band. Each is roughly 3× the previous in Essence per second, so the
newest unlock is always clearly worth saving for, and the previous tier stays worth topping up.

| Id | Stage | Cost | Growth | Value | Interval | Essence/s | Max |
|---|---|---|---|---|---|---|---|
| `ember_vent` | 1 | 15 | 1.18 | 1 | 2.0s | 0.50 | 25 |
| `dew_font` | 1 | 150 | 1.17 | 4 | 2.2s | 1.82 | 20 |
| `loam_seep` | 2 | 350 | 1.17 | 9 | 2.4s | 3.75 | 20 |
| `gale_flue` | 2 | 1,300 | 1.16 | 26 | 2.0s | 13.0 | 16 |
| `cinder_forge` | 3 | 3,800 | 1.16 | 60 | 2.2s | 27.3 | 16 |
| `tidal_weir` | 3 | 14,000 | 1.15 | 190 | 2.0s | 95.0 | 14 |
| `quartz_bloom` | 4 | 32,000 | 1.15 | 420 | 2.2s | 191 | 12 |
| `storm_coil` | 4 | 120,000 | 1.14 | 1,400 | 2.0s | 700 | 12 |
| `magma_heart` | 5 | 1,000,000 | 1.13 | 12,000 | 2.4s | 5,000 | 10 |
| `aether_spire` | 6 | 8,000,000 | 1.12 | 90,000 | 2.5s | 36,000 | 8 |

`cost(n) = floor(BaseCost × Growth^n)`. Growth *falls* as the tiers climb (1.18 → 1.12): late
Wellsprings cost more up front but scale further, so the endgame is about breadth rather than
grinding a single machine to its cap.

A fresh Sanctum is granted one free `ember_vent`, which is why the first purchase lands about
**30 seconds** in — early enough to teach the loop before the player decides whether to stay.

---

## Stages

| # | Name | Essence to attune | Lifetime gate | Wellsprings | Income × | Walk |
|---|---|---|---|---|---|---|
| 1 | **Mote** | — | — | — | 1.0 | 16 |
| 2 | **Wisp** | 250 | 600 | 4 | 1.4 | 17 |
| 3 | **Sprite** | 12,000 | 28,000 | 10 | 2.0 | 18 |
| 4 | **Elemental** | 900,000 | 2,000,000 | 18 | 2.8 | 20 |
| 5 | **Warden** | 26,000,000 | 60,000,000 | 26 | 3.9 | 22 |
| 6 | **Primordial** | 600,000,000 | 1,400,000,000 | 34 | 5.5 | 24 |

Three gates, not one. Essence is the obvious one; **lifetime Essence** stops a player rushing a
stage by hoarding without building; the **Wellspring count** stops them skipping the middle of the
tree entirely. Attuning spends the Essence — it is a purchase, not a checkpoint.

Attunement changes the Conflux model and colour, raises the income multiplier, raises everyone's
walk speed (the Sanctum grows, so traversal has to keep up), and unlocks the next tier of
Wellsprings, upgrades and Wings.

**Measured**, not modelled. `tests/specs/pacing.spec.luau` plays the game in the harness — real
purchases through `PurchaseService`, real attunements, the real income loop, and a greedy buying
policy — and reports where the milestones actually fall:

| Milestone | Reached at |
|---|---|
| First purchase | 0.7 min |
| Stage 2 — Wisp | 6.2 min |
| Stage 3 — Sprite | 22.2 min |
| Stage 4 — Elemental | 28.9 min |
| Stage 5 — Warden | 35.1 min |
| Stage 6 — Primordial | 47.5 min |
| Transcend-ready | 49.9 min |
| Transcend-ready, 4 rebirths | 25.0 min |

238 purchases across the run. The spec asserts these stay in the right region, so a balance change
that moves the curve by a factor fails a test rather than quietly making this table wrong.

**The curve is lumpy, and stage 2→3 is the problem.** Gaps between stages run
6.2 → **16.0** → 6.7 → 6.2 → 12.4 minutes. Sprite costs more than twice its neighbours: after the
first attunement teaches the mechanic at 6 minutes, the player spends a quarter of an hour before
the next one. Two things drive it — `wing_tide_basin` at 45,000 is the first wing that costs
meaningfully more than the wellsprings it unlocks, and stage 3's own 12,000 essence lands before the
stage-2 wellsprings have compounded. Halving one of those would flatten it. It is left as it is
because the pacing was signed off before it was measured; it is the first thing to revisit if the
mid-game reads as a grind.

Prestige compresses the run to **half**, not a third: 25.0 minutes at four rebirths against 49.9
cold. Four rebirths is ×2 income, so half is exactly what the multiplier predicts — the earlier
"about a third" was arithmetic that no one had checked.

---

## Wings

| Id | Stage | Cost |
|---|---|---|
| `wing_core` | 1 | free, always unlocked |
| `wing_ember_forge` | 2 | 2,500 |
| `wing_tide_basin` | 3 | 45,000 |
| `wing_terra_vault` | 4 | 700,000 |
| `wing_zephyr_spire` | 5 | 15,000,000 |

Wings are physical space. Each hosts a band of Wellsprings and upgrades, so buying one is what makes
the *next* tier reachable. A locked Wing is reparented out of the world entirely rather than made
transparent — it costs nothing to render until it exists.

---

## Upgrades

| Id | Effect | Max | Cost | Per level |
|---|---|---|---|---|
| `ley_flow` | Rail speed | 10 | 500 | −6% travel time |
| `font_resonance` | Font yield | 12 | 900 | +5% Mote value |
| `wellspring_cadence` | Spawn rate | 12 | 2,500 | −4% interval |
| `mote_lattice` | Mote capacity | 8 | 6,000 | +10 live Motes |
| `conflux_attunement` | Global income | 15 | 15,000 | +4% |
| `primordial_echo` | Global income | 20 | 2,500,000 | +6% |

`mote_lattice` is the one that looks cosmetic and is not. Live Motes are capped per Sanctum; past
the cap, income is credited **immediately without spawning a part**, so a full rail never costs
Essence — but it does cost the visual feedback that makes the Sanctum feel alive. Tide players hit
the cap first, which is exactly the trade-off that affinity is meant to create.

---

## Affinities

Chosen once at **Stage 3**, cleared only by Transcendence.

| | Income | Spawn rate | Mote value | Rail speed | Walk |
|---|---|---|---|---|---|
| **Ember** | ×1.22 | — | — | ×0.95 | — |
| **Tide** | — | ×1.28 | ×0.95 | — | +1 |
| **Terra** | — | ×0.88 | ×1.38 | ×0.92 | +2 |
| **Zephyr** | ×1.06 | ×1.12 | ×1.02 | ×1.35 | +6 |

Raw income lands within **1%** across all four (1.2109 – 1.2200), and a spec enforces both that band
and the stronger property: **no affinity strictly dominates another** on all five axes. What differs
is feel — Ember is flat and safe, Tide is a busy rail that wants `mote_lattice`, Terra is rare
enormous Motes, Zephyr is the traversal pick for a 200×200 stud Sanctum.

---

## Transcendence

Requires **Stage 6** and **3.5 billion lifetime Essence** — meaningfully past the stage-6 gate, so
reaching Primordial is a milestone and transcending is a decision made afterwards.

Both occupants must vote yes within 30 seconds. Every voter receives:

- `+1` rebirth and `+0.25` permanent multiplier
- any milestone badge crossed
- their lifetime totals carried forward

The Sanctum then resets to a blank `PlotState`. Prestige is stored separately from resettable state,
so nothing permanent can be lost to a reset bug.

| Badge | At |
|---|---|
| Ember Initiate | 1 |
| Wisp Walker | 3 |
| Sprite Sovereign | 5 |
| Elemental Adept | 10 |
| Warden Eternal | 25 |
| Primordial Ascendant | 50 |

Rebirths are tracked to 100 for multiplier purposes, so a tampered profile claiming 1e300 rebirths
gets the cap rather than an infinite economy.

---

## Two players

The hook is not "two plots side by side" — it is one Sanctum with two people in it.

- **One wallet.** Every Mote either of you collects lands in the same pool.
- **Prestige adds across occupants.** A 10-rebirth veteran raises a newcomer's Sanctum from ×1 to
  ×3.5. Adding rather than multiplying means pairing up is always worth it without making
  level-matched pairs the only viable way to play.
- **Linking is non-destructive.** The two saves are max-merged, so nobody loses a Wellspring by
  being sociable.
- **Both carry the result home.** Saves mirror to every occupant.
- **The reset button needs both of you.** Transcendence is a consensus vote, which turns the
  biggest decision in the game into the one that most needs a conversation.
