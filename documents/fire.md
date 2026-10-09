# Fire

## Decisions (2026-10-05)

The player asked for the first fire system:

- **Lighting.** "Use the stone and flint to spark next to a flammable starter object and it
  starts it on fire."
- **Starter and fuel materials.** Today there is one starter, leaf litter (pile or ball).
  There are two fuels, logs and sticks.
- **Fuel.** "The leaf litter is a weak fuel source that might last 30 seconds without
  additional fuel." "Every stick should add maybe 1.5 min and every log should add
  5 min."
- **Feeding.** "The starter material [checks] its surrounding area by maybe 0.5 m and if the
  player has placed flammable materials next to the starter fire, then the starter fire
  will add that object to its fuel source."
- **Burn order** (revised below, 2026-10-05). "When the leaf litter is on fire and a log or
  stick is near by, it should use the fuel from those objects first as long as they are
  within its radius."
- **Ball or pile.** "The leaf litter should remain on fire whether or not it is in a ball
  or planted on the ground."
- **Readout.** "For now, have the fuel numbers show above the fuel source when near a fire."
- **Spent fuel.** "For now, the leaf litter, sticks, and logs should disappear when the
  fuel level hits 0." (The litter now turns to ash instead, below.)

Chosen with the player at plan review:

- **Sparks light by nearness.** A burst lights the tinder within about 0.3 m of where the
  sparks leave, on the first strike, whichever way they fly. Two alternatives were offered
  and not chosen: following the sparks' flight, and a chance per strike.
- **A test spot by the table.** `FireTest` holds one pile, two sticks touching it, and a
  log 1 m off, to be carried in. The harness removes it from every scenario.

Revised with the player after trying rung 1 ("This works pretty good!"):

- **A fire lights the tinder by it.** "If I bring a leaf litter ball/pile to a burning leaf
  litter, it should start the other." Unlit tinder within a fire's 0.5 m reach catches and
  burns as a fire of its own, on its own fuel. This replaces my first call, that an unlit
  pile in reach was plain fuel. A lit pile first looks round it in its next tick, so a row
  of piles catches one a tick, not all at once.

Revised with the player the same day, with the ash pile model (`assets/models/fire/ash_pile.glb`):

- **The leaves burn first, then turn to ash.** "When a leaf litter is lit on fire, I would
  like the fuel of the leaf litter to burn out first. Once it burns out the leaf pile should
  turn into a ash pile. The ash pile should not be pickupable at the current point. Once the
  leaf litter is an ash pile, then the fire should search for other fuel." This replaces
  the first burn order (nearby fuel first).
- **The ash grows.** "I think it'd be cool to see the ash pile grow every time a fuel source
  is fully consumed. It should grow about 10% up to a capped 100% more. So after burning 10
  fuel sources it should stop growing."
- **The fire grows.** "The fire should grow 10% with every fuel source up to a capped 100%
  similar to the ash pile."

Chosen with the player for that revision:

- **Fuel waits but counts.** Fuel in reach while the leaves burn is held at once: its
  readout shows and the fire grows for it, but none of it burns until the leaves are ash.
- **The fire follows the fuel it holds now.** It grows 10 % (now 20 %, below) for each
  fuel it holds, at most 100 % more, and shrinks as they burn away. It does not grow for fuel already burnt.
- **Embers wait.** Ash with nothing to burn keeps embers, a half-size fire, for 15 s. Fuel
  brought within reach then catches. Otherwise the fire goes out and the ash lies cold; it
  cannot be lit again.
- **Reach 0.3 m** (asked the same day, "shrink the fuel detection range to about 0.3m
  from 0.5"). The one reach covers both fuel and lighting other tinder.
- **20 % a fuel** ("the fire needs to grow by 20% instead of 10% every fuel source"). The
  cap stays at 100 % more, so five fuels make it twice its size. The ash stays at 10 % a
  fuel consumed.
- **A big fire is a wide one** ("with the size increase of the fire, increase the radius of
  the base of the fire so it gets wider and taller"). The fire's uniform scale already
  widened its base in step with its height. Now the base spreads twice as fast
  (`base_growth`): twice as tall, three times as wide. Embers keep their shape.
- **Nothing is left off the ground.** Leaves that burn down while held, or flying as a
  thrown ball, are gone. Only leaves lying on the ground leave ash: a pile, or a ball
  resting on the ground (Static ground within 7 cm below its centre).

My calls, approved with the plan:

- **One fuel at a time.** A fire burns one fuel at a time, so the times add up. A pile with
  two sticks and a log by it burns 30 + 90 + 90 + 300 s.
- **Order.** After the leaves, fuel in reach burns in the order it came within reach,
  nearest first among fuel that came together.
- **One fire per fuel.** A fuel burns for one fire at a time. No fire takes tinder as
  fuel, so two burning piles never feed on each other.
- **Out of reach.** Fuel moved out of reach stops burning and keeps what it has left.
  Held fuel in reach still burns, and if it is spent it vanishes from the hand.
- **The readout** reads `m:ss`. It shows over the burning pile and over every fuel the
  fire holds, and is drawn over everything.
- **The flames** are the level's fire (`scenes/effects/fire.tscn`) at half size, upright
  on the leaves' centre. Sizes ease over about half a second (`grow_time`), the fire's and
  the ash's, rather than jumping 10 %.
- **The ash** meets nothing and stays where it lies.

## The model

- **`Fuel`** (`scripts/fire/fuel.gd`) sits on the litter, the stick and the log.
  - It holds `seconds` of burning: 30, 90 and 300.
  - `burn(amount)` takes up to `amount` and returns what it took.
  - At 0 it emits `spent` and, if it `vanishes` (sticks, logs), its body goes. Before that
    it wakes the rigid bodies resting on it, because Jolt leaves a sleeping body hanging
    when its support goes (as `TreeChop._break_up` does). The litter's body stays, for
    `LeafLitter` to decide.
  - It shows its readout while a fire holds it (`fire`). The `FuelDisplay` is made the
    first time it is needed, so the many unlit piles carry no label.
- **`FuelDisplay`** (`scripts/fire/fuel_display.gd`) is a billboard `Label3D`.
  - It is drawn over everything and placed each frame at `readout_height` above the
    fuel's `centre` (or its body), in world up.
  - Its text changes only when the whole second shown changes.
- **`Tinder`** (`scripts/fire/tinder.gd`) sits on the litter.
  - **Lighting.** `ignite()` refuses when the tinder is already lit or has nothing left.
    Otherwise it adds the fire scene and starts burning. It first looks round it in its
    first tick, before it burns.
  - **Each physics tick** it burns the tick's step from its own fuel while that lasts,
    then from the first fuel it holds. What one fuel lacks of the step, the next burns, so
    the times add up exactly.
  - **Burnt down**, it emits `burnt_down` and hides its own readout. Each held fuel
    burnt to nothing raises `consumed_count` and emits `consumed`.
  - **Size.** `size` is `1 + min(0.2 × fuels held, 1.0)`, or `ember_size` (0.5) once
    burnt down with nothing held. The flames ease toward it.
  - **Shape.** The fire node's Y scale is `fire_scale × size`, and its X and Z scale are
    `fire_scale × (1 + (size − 1) × base_growth)` above size 1. The flame shader takes
    the flames' height (and card width) from Y and spreads their base disc over X and Z,
    so the base widens without fattening each flame.
  - **Embers.** With nothing to burn after burning down, it keeps embers for
    `ember_seconds`. Then it emits `went_out`, its fire goes, and it lets go of
    everything.
  - **Finding fuel.** Every 0.25 s one sphere query of 0.3 m round `centre` (the leaves'
    sphere) looks for fuel. Its mask is Dynamic, Grabbable and Held: piles lie on
    Grabbable alone. A body counts when any part of its shapes is within reach.
    - Unlit tinder in reach is lit, never taken as fuel.
    - It holds new fuel no other fire holds, nearest first.
    - It lets go of fuel that is out of reach.
  - **The flames** are placed each frame, after the frame's physics, where the leaves
    are drawn. Their basis is upright and scaled, because the flame shader lays the
    flames out in the fire's own plane.
  - **Cost.** Unlit, it costs nothing each tick.
- **`LeafLitter`** (`scripts/props/leaf_litter.gd`) gains a third form, `ASH`.
  - On `burnt_down`, a pile, or a loose ball resting on the ground, becomes the ash model
    (`AshModel`), upright where it lies.
  - The ash is frozen, on no layer and meeting nothing, and its `Grabbable` is disabled.
  - Held or in the air, the body frees itself; a hand holding it lets go of a freed
    target as before.
  - On `consumed`, `ash_size` becomes `1 + min(0.1 × count, 1.0)`. The ash model eases
    toward it (processing only while it changes).
- **`SparkIgniter`** (`scripts/fire/spark_igniter.gd`) sits on the flint.
  - On each `StrikeSparks.sparked` it runs one sphere query of 0.3 m at the strike point
    and lights each `Tinder` it meets.
  - `StrikeSparks` stays visual only, and its signal is unchanged.

The components follow the props' `X.of(body)` metadata convention (`Grabbable`,
`Striker`): no groups, autoloads or scene-tree searches.

| Setting (Class) | Default |
| --- | --- |
| `seconds` (Fuel): litter, stick, log | 30, 90, 300 s |
| `readout_height` (Fuel): litter, stick, log | 0.2 m above the leaves' sphere, 0.15 m, 0.25 m |
| `reach` (Tinder) | 0.3 m (0.5 m at first) |
| `look_interval` (Tinder) | 0.25 s |
| `fire_scale` (Tinder) | 0.5 |
| `fire_growth`, `fire_growth_most` (Tinder) | 0.2 a fuel held (0.1 at first), 1.0 |
| `base_growth` (Tinder) | 2 (the base widens twice as fast as the flames rise) |
| `ember_seconds`, `ember_size` (Tinder) | 15 s, 0.5 |
| `grow_time` (Tinder, LeafLitter) | 0.5 s |
| `ash_growth`, `ash_growth_most` (LeafLitter) | 0.1 a fuel consumed, 1.0 |
| `rest_reach` (LeafLitter) | 0.07 m |
| `reach` (SparkIgniter) | 0.3 m |

## Ladder

1. **Sparks light litter, which burns the fuel by it** (built 2026-10-05, this document).
2. Later, not built (to be chosen with the player):
   - the fire's light following its size;
   - flames or char on the fuel being burnt;
   - glowing embers (they are a half-size fire now), sound, and a light flash on sparks;
   - the ash fading away, or being swept up;
   - a burning stick carried as a torch;
   - spreading;
   - cooking and forging on a fire.

## Checks

```
godot --headless --xr-mode off --path . -s tests/fire/test_fire.gd
godot --headless --xr-mode off --fixed-fps 72 --path . -s tests/harness/run_scenarios.gd -- fire_spark_light fire_spark_far fire_feed_order fire_carry fire_burn_in_hand fire_lights_tinder fire_carry_lights fire_embers fire_growth_caps
```

### Rung 1 (2026-10-05, simulated, desktop), first burn order

These results are from the first burn order (nearby fuel first). For the leaves-first order
and the ash, see the next section.

`tests/fire/test_fire.gd` (22 checks, all pass) checks:

- the readout's `m:ss`;
- the props' seconds and parts;
- a fuel burning down: partial burns, spent once, its body going;
- lighting only once;
- a fire lighting an unlit pile 0.3 m off, which then burns its own fuel;
- a readout hiding when let go;
- a burst lighting a pile 0.2 m off but not one 0.4 m off, and a strike with no sparks
  lighting nothing.

Seven harness scenarios, last in the list, all pass. Fuel seconds are shortened per
scenario.

| Scenario | Result |
| --- | --- |
| fire_spark_light | sparks_flint_skim's strike with a pile 0.3 m on: the burst (0.028 s) lit the pile in its own tick; it burns, its fire and readout showing |
| fire_spark_far | the same strike, a pile 0.45 m behind: unlit |
| fire_feed_order | lit at 0.264 s: the near stick (1 s) spent at 1.264, the log (1.5 s) at 2.764, the litter (2 s) at 4.764, each gone the tick after and each burning only once the one before was spent; the stick 0.8 m off kept all 90 s and never showed a readout |
| fire_carry | the stick 0.45 m off burnt 1.24 s before the grip while the litter kept its 30 s; gripped, a ball burning every tick, its fire on the leaves as drawn (0 mm) and upright; lifted out of reach about 2.25 s, the stick stopped at 88.01 s left and its readout hid, while the litter burnt its own (26.75 s at the end); laid down, a pile still burning |
| fire_burn_in_hand | 2.4 s of litter burnt out in the hand at 2.653 s (lit at 0.264); the hand let go the tick it found the leaves gone, stayed idle, with one grab |
| fire_lights_tinder | a pile lit at 0.264 s with piles 0.35 m and 0.7 m on in a row (3 s each): the first caught at 0.264 s (the lit pile's first tick), the second at 0.278 s (a tick later, from the first); each was spent its own 3 s after it caught; a pile 0.8 m the other way never caught |
| fire_carry_lights | the table's pile carried, lifted and laid down beside a pile burning 0.61 m from where it lay: unlit while out of reach, it caught at 3.5 s on the way down and lay there a pile, burning its own fuel (28.01 of 30 s left at the end); the fire beside burnt on, its own |

**A/B on the full harness.** Two scratch copies differed only in the fire components on
the props: 188 scenarios, the first five fire scenarios, and the 183 others.

- **Unchanged.** The 183 others gave identical values in `results.json` (`*_us` timings
  and file paths aside).
- **Same failures.** Both copies failed the same 57 criteria. These failures were already
  there in this environment before this change, as noted at HEAD on 2026-10-05.

After the revision, a full run in the main checkout (190 scenarios) matched that run
value for value. The only difference is a new logged field (when each tinder was lit).
The same 57 criteria failed as before.

What the checks do not cover:

- **The look.** Flame size on a pile or a ball, readout legibility, smoke near the face.
- **Cost.** The fire scene measured 2 draw calls and one omni light on desktop
  (2026-10-03). Each shown readout adds a `Label3D`. A burning pile has not been
  measured, and nothing has been measured on Quest.

### Leaves first, ash, embers, growth (2026-10-05, simulated, desktop)

`tests/fire/test_fire.gd` (29 checks) checks, beyond the above:

- the litter's body staying when spent while sticks and logs vanish;
- the growth rule (0, 3, 10 and 12 fuels: 1, 1.3, 2, 2);
- a pile burning down to ash that no hand picks up and nothing meets;
- its embers, then dying, the ash cold and unlightable;
- a ball burning down in the air leaving nothing.

28 checks pass. The one failure is "a stick burns 90 s": the stick scene's `seconds` is 15,
set in the editor at 20:59, and left for the player to settle.

Nine harness scenarios, last in the list, all pass:

| Scenario | Result |
| --- | --- |
| fire_feed_order | lit at 0.264 s: the litter (2 s) burnt first and lay as ash at 2.25 s; the stick (1 s) was spent at 3.25 s and the log (1.5 s) at 4.75 s, each gone the tick after and each burning only once the one before was spent; the fire's size went 1, 1.2 (two held), 1.1, 0.5 (embers); the ash's 1, 1.1, 1.2; the embers died at 5.75 s, 1 s after the log; the far stick never burnt |
| fire_carry | before the grip the litter burnt its own, the stick waiting, held (90 s left, readout showing, the fire 1.1); lifted out of reach, the stick let go (readout hidden, the fire 1), never burnt; held, the fire stood on the leaves as drawn (0 mm), upright; laid down, a pile still burning |
| fire_burn_in_hand | burnt down in the hand at 2.653 s: gone, the hand idle, one grab |
| fire_lights_tinder | as before (caught at 0.264 s and 0.278 s); each burnt its own 3 s and lies as ash |
| fire_carry_lights | as before: caught at 3.5 s on the way down, a pile burning its own |
| fire_embers | the leaves (1 s) lay as ash at 1.25 s with embers (0.5); a stick laid at 2 s caught at the next look (seen burning at 2.264 s), the fire 1.1; it was spent at 3.236 s and gone, the ash 1.1; the embers died at 5.236 s, 2 s on, and the ash lies cold, drawn at 1.100 |
| fire_growth_caps | 12 sticks held still 0.3 m round (0.2 s each): the fire's size went 1, 2 (capped), then 1.9 down to 1.1 one stick at a time once 10 were left, then 0.5; the ash's went 1.0 to 2.0 in tenths and no further, all 12 consumed, drawn at 1.991 by the end; the embers died at 3.639 s, 0.5 s after the last |

A full harness run (192 scenarios) matched the previous full run value for value on the 183
non-fire scenarios. The same 57 criteria failed.

### Reach 0.3 m, wider base (2026-10-05, simulated, desktop)

The scenarios' fuel was moved in for the 0.3 m reach:

- **fire_feed_order:** stick 0.15 m, log 0.25 m. A stick 0.4 m off, in the old reach but
  not the new, never burns.
- **fire_carry:** the stick lies 0.27 m off.
- **fire_lights_tinder:** piles 0.2 m and 0.4 m on, and 0.5 m the other way. The pile
  0.4 m off catches only from the middle pile, a tick later.
- **fire_carry_lights:** the burning pile lies 0.43 m from where the carried one lay. The
  carried pile caught at 3.75 s.
- **fire_growth_caps:** the sticks stand 0.2 m round.

All nine pass, and `fire_growth_caps` now also checks the base. At most the fire stood
1.892 times its height alone and 2.785 times its width: the base widened twice as fast,
to within 1e-3. With two fuels (`fire_feed_order`) it reached 1.199 tall and 1.399 wide.

A full run (192 scenarios) matched the previous one value for value on the 183 non-fire
scenarios, with the same 57 failing criteria. The focused test has 30 checks; 29 pass, and
the other is the stick's 15 s.

### 20 % a fuel (2026-10-05, simulated, desktop)

The harness now works out each scenario's expected fire sizes from the Tinder's own
settings. The focused test pins the player's numbers: fire 0.2 a fuel held, ash 0.1 a fuel
consumed, both capped at 1.0. All nine fire scenarios pass:

- **fire_feed_order:** the fire went 1, 1.4 (two held), 1.2, then 0.5; it reached 1.399
  tall and 1.798 wide.
- **fire_carry:** the waiting stick made the fire 1.2.
- **fire_embers:** the fire went 1, 0.5, 1.2, then 0.5.
- **fire_growth_caps:** the fire went 1, 2, 1.8, 1.6, 1.4, 1.2, then 0.5. It held at 2
  until five sticks were left, and reached 1.985 tall and 2.97 wide.

The 183 non-fire scenarios matched the previous full run value for value, with the same 57
failing criteria. The focused test has 31 checks; 30 pass, and the other is the stick's
15 s.

### Headset (pending)

Use the `FireTest` spot, on the floor 1.25 m west of the table:

1. Strike the flint on the stone just above the pile. The sticks touching it show their
   countdowns at once, and the fire is a little bigger, but the leaves burn first (30 s).
2. When the leaves turn to ash, watch the sticks burn one at a time: the fire shrinks
   10 % as each goes, and the ash grows 10 %.
3. Carry the log in before the last stick goes; the fire grows again.
4. Let the fire run out. The ash holds embers for 15 s, then goes cold.
5. Light a second pile, pick it up, and let it burn down in your hand: nothing is left.
