# Strike model

## Decisions (2026-09-30)

The player asked for a physical weapon model with four attack kinds (as first described;
the sticking and pushing in were dropped on 2026-10-01, below):
- **Slash:** a blade hitting an object. A sword blade never gets stuck with a slash.
- **Stab (pierce)** (folded into slash 2026-10-02): a point (a sword's, an arrow's) pushed through an object.
- **Lodge** (dropped 2026-10-02): a heavy-headed weapon such as an axe hitting an object. It sticks a little
  and takes a little force to free.
- **Blunt:** anything without a sharp edge, from the player's hands to a rock or a
  hammer, hitting with speed. It never sticks.

Materials and their thickness change how well each kind works. The test materials are:
- **cloth:** easy in all four;
- **wood:** slightly tougher in all four;
- **stone:** takes no slash, stab or lodge, only blunt. A sharp object hitting stone, or
  any material it cannot cut, strikes blunt.

Decided with the player:
- **Built one rung at a time** (ladder below). Rung 1 is blunt only, from every physical
  object: "all physical objects should deliver blunt damage if thrown or used to hit
  something. Even fists." Edges and points strike blunt until the sharp rung exists.
- **A strike's effect is a readout only.** Each target shows its damage total and the
  last strike, with a brief marker where it landed. Nothing has health or breaks;
  consequences come when a gameplay system needs them. (The first came on 2026-10-02:
  the ore veins have health and vanish at 0, below. The posts stay readouts.)
- **A slash is a plain hit plus slash damage** (later rung): "The blade doesn't have any
  special behaviours happen during a slash, it just hits the object. No forced stop or
  pass through."
- **Thickness only matters for stab.** Blunt, slash and lodge ignore it.
- **Test targets are fixed posts** east of the table: a cloth dummy, a wooden post and
  a stone block. (A 2 cm board for thickness was to come with stab; thickness is left
  out for now.)

Decided with the player after rung 1 (2026-10-01):
- **Damage types only.** "There will be no cutting. It will simply be different damage
  types. There won't be physically different effects to the types of damage." Every
  strike stays a plain collision; slash, stab, lodge and blunt differ only in the damage
  they do to each material. The planned sticking (lodge) and pushing in (stab) are
  dropped. Rung 2, the sharp damage types, completes the model.
- **A weak sharp strike stays its own type.** A light edge tap on wood is still a
  slash, and does no damage only if it is under wood's slash threshold. Stone still
  takes only blunt.
- **The pickaxe's pick deals stab** (slash since 2026-10-02, with every point).
- **Forgiving alignment:** an edge counts if it leads within about 50° of the blow, a
  point within about 35°. Tune in the headset.
- **Thickness: not yet.** It is left out of stab, too, until it matters.

Decided with the player after rung 2's headset session (2026-10-02):
- **Three types only:** "I want to simplify the types in 3 Slash, Stab, and blunt. No
  other types." Lodge is gone. The axe's bit and the pickaxe's adze, the edges that
  were lodge, now slash: every edge slashes, every point stabs, and anything else is
  blunt.
- **Two types, the same day:** "The more I think about this the less I believe we need
  stab damage. I think we need to simplify further an count for only slash and blunt
  damage." Points slash too (the player's choice: any sharp part deals slash), so a
  strike is a slash when a sharp part (an edge or a point) deals it, and blunt
  otherwise. `Sharp` markers no longer carry a type; points keep their own reach and
  angle.

Decided with the player (2026-10-02, damage scale and health):
- **A strike does 1 to 10 damage, by its strength:** "There should be a damage scalar
  depending on the strength of the hit. The damage should range from 1-10. This will
  allow us to more easily set health ranges for different entities."
- **Health:** "a health component for object such as the ore vein for now. The health
  should display above the vein. When the health reaches 0 it should simply disappear
  for now (destroying itself)."

Chosen while building it (2026-10-02), open to change after the headset:
- The strength is the strike's energy between its material's threshold (1 damage) and
  a new full energy (10), in a straight line, and the damage is a whole number. A strike
  under the threshold still does none.
- The full energies keep the materials' relative toughness from the accepted per-joule
  rates (below), rounded: cloth 60 J, wood 75 J, stone 150 J.
- An ore vein is stone, so every weapon strikes it blunt, and it has 30 health. Its
  display is always on, as "24 / 30".

Decided with the player (2026-10-02, loot), once the scale "feels pretty good":
- **Loot on death:** "give the hp component the ability to drop loot when dead... I
  would like the ores to drop 4 ores when it is destroyed. The 4 ores should spawn
  inside the vein in a way that doesn't launch them. Don't spawn them inside eachother.
  They should spawn near the center of the destroyed mesh."

Chosen while building it (2026-10-02):
- `Health` detects the death and reports it (`depleted`, once). A `LootDrop` beside it
  drops the loot, as `HealthDisplay` shows the health, so any object can reuse it.
- The ores appear at the middle of the vein's meshes and fall to the floor once the
  vein is gone: about half a metre then, about 0.43 m in the 75 % vein.

Decided with the player (2026-10-02), after the loot "looks good":
- **Ores half size:** "I would like the ores to be about 50% smaller." Each ore scene
  scales its model by 0.5, and the shared convex shape (`scenes/props/ores/ore_shape.tres`)
  has its points halved: about 13 cm across. The mass stays 2.5 kg (my choice): at half
  size that is 2.7 kg/L, about granite's density, where at full size it was 0.34 kg/L,
  lighter than water.
- **No grip inside an ore:** "I would like the center grip point to not exist so I
  cannot grip inside the mesh." The grab point on a convex shape is now the nearest
  point of its surface when the hand's grab point is inside it; it was the shape's
  centre (`HandGrab._cast_onto`; architecture document, "Grab detection").
- **Veins half size:** "can we also shrink the ore veins down by about 50% as they are
  rather large". Each vein scene scales its model by 0.5, collision included (Jolt takes
  the scaled static bodies as they are: a ray onto the top met it at 0.637 m, half the
  1.274 m before). Health (30) and loot (4 ores) are unchanged.
- **Then 75% of the original:** "Okay wow that is too small. Maybe make the veins 25%
  bigger", then "I meant 75% of the original" (I had first made them 62.5%). The models
  are scaled 0.75: a vein is 0.79 × 0.97 × 0.61 m, its health display 1.17 m up, 0.2 m
  over its top as before.

Decided in the design:
- **Detection lives on the striking object** (`Striker`). The struck body only carries
  its material (`Strikeable`), so anything can be struck, static bodies and CSG-backed
  ones included, without reporting contacts itself.
- **Rung 1 changes no motion.** It adds no forces, joints or collision exceptions;
  everything collides as before. The one setting changed is that the level's three boxes
  now report contacts (4), which every weapon already did. That needs care; see Risks.

## The model

- **What strikes.** Each tick a `Striker` reads the contacts its body reported in the
  last physics step.
  - A contact *touches* if its gap at the step's start was no more than the distance the
    bodies closed by during the step, plus 1 mm. Jolt also reports contacts about 2 cm
    short that may never close; this leaves those out.
  - A pair (the striker and one struck body) strikes on the tick it starts touching, if
    it closed at **0.5 m/s** or faster and has not struck in the last 0.1 s. It then
    stays engaged until it comes apart.
  - Resting, pressing and sliding never strike again; a bounce and a return do.
- **How hard.** `E = ½ · m_eff · v²`.
  - `v` is the closing speed along the contact normal at the middle of the pair's
    touching contacts, from the contacts' recorded (pre-impact) velocities.
  - `m_eff = 1 / (1/M + (r×n)·I⁻¹(r×n))` is the mass met there along the normal. It is
    taken from the striker rigidly joined with the hands holding it: a hand welded on
    alone adds its mass and turning inertia, and each hand of a two-handed hold adds its
    mass at its centre.
  - So a box landing flat strikes at its face centre with its whole mass, a sword's tip
    strikes lighter than its middle, and a head-heavy axe strikes hard at its head.
  - The arm's push during the impact step (follow-through) is not counted.
- **Which type** (rung 2, 2026-10-01). A strike is blunt unless a `Sharp` feature
  of the striker dealt it.
  - A feature deals a strike that lands within its reach while it leads the blow: its
    working direction must point into the struck surface, within its `max_angle` of the
    contact's motion.
  - When several fit, the one most nearly lined up with the blow wins.
  - A contact is found at the step's start, or at the impact for a continuous-collision
    hit, so both poses are tried.
  - The struck material then decides whether it takes that type; stone takes only
    blunt.
  - The type changes the damage only; nothing moves differently.
- **Feeling it** (2026-10-02). Each hand holding the striker buzzes with every strike:
  amplitude √(E / 100 J), at least 0.15, for 0.06 s (`HandHaptics`). The strike reaches
  it through `PlayerPhysical.hand_strike`. A bare hand's strikes buzz as touches
  already did, and something let go of is not felt.
- **Damage** (the struck body's rule; 1 to 10 since 2026-10-02). A strike under its
  type's threshold does none. Otherwise its strength
  `s = (E − threshold) / (full energy − threshold)`, held to 0..1, gives
  `round(1 + 9·s)`: 1 at the threshold, 10 at the full energy and above. Strikes under
  the threshold are still shown, as "no damage", for tuning. (Until 2026-10-02 it was
  `(E − threshold) × damage per joule`, with no top.)
- **Health** (2026-10-02). A `Health` takes the damage of its object's `Strikeable`,
  counting down from its `maximum` to 0; it reports `changed`, and `depleted` once. A
  strike does 1 to 10, so a health counts blows: an ore vein's 30 takes three
  full-strength blows, or thirty of the lightest. The vein shows it over itself
  (`HealthDisplay`) and frees itself at 0. It takes the strike kinds in its `kinds`:
  all of them by default, slashes only for a tree's lone piece (since 2026-10-02).
- **Loot** (2026-10-02). When the health runs out, a `LootDrop` lays `count` of its
  `loot` scene in a ring around the middle of the object's meshes, or around its
  `centre` if set (a tree's lone piece sets its middle). With `lay_down`, each lies on
  its side along the ring (logs and sticks), rather than standing.
  - Neighbours are `2·reach + gap` apart. The reach is how far an item's collision
    shapes reach from its origin (0.081 m for an ore at half size), so no two overlap however they
    are turned.
  - Each place is checked first with a shape query against what the item collides
    with, the dying object's own bodies aside: every body below it, and since step 1c
    of chopping the object itself if it is a body (a felled piece of a tree). A taken
    place (a weapon sunk into the vein, earlier loot) is tried again a spacing higher.
  - The items start still, in the object's parent, in the tick the object frees itself,
    so nothing pushes them: they fall. Each vein drops four of its own ore.
- **An object of several bodies.** A `Strikeable` marks its parent and every body below
  it, so an imported model with a body per mesh (an ore vein: its rock and six ore
  pieces) is struck as one object. Touching two of its bodies in one tick is one strike.
- **A tree** (chopping, 2026-10-02). A `ProceduralTree` with a wood `Strikeable` is struck
  through its wood body. The tree builds that body itself and hands it to
  `Strikeable.mark`, including each time its collision streams back in. Its `TreeChop` takes
  only slashes, on its segment lines: any line on wood thick enough to hit, standing or
  felled (since step 1b). Blunt strikes reach it as on any wood but cut nothing. A twig,
  wood too thin for a line, is the exception: any strike on it at 2 m/s or faster breaks it
  off, as its leaves are broken. A felled piece is struck through its own rigid body.
  `TreeChop` writes what it made of each strike on `Strike.judged`, which the recorder logs
  with the strike's point. A piece with no line left to chop (step 1c) gets a `Health`
  that only slashes take, 50 for trunk wood and 10 for a branch, and at 0 is gone and drops
  3 logs or a stick a segment through a `LootDrop` (`documents/procedural_trees.md`,
  Chopping, Lone pieces).
- **Sparks** (2026-10-05, a visual only). The flint's strikes on stone throw a burst of
  sparks (`StrikeSparks` on the flint, listening to its `Striker`). The rule is any strike
  that lands on a material in its list (stone: the Stone, the ore veins, the stone block),
  where the moving piece slid at 1 m/s or faster.
  - The sparks follow whichever piece moved, the way it slid across the other (decided
    with the player). If the flint is swung, they go its way. If the stone is swung into
    a still flint, they go the stone's. The rule (`slide_of`) needs `Strike.velocity` (the
    striker against the struck body) and `Strike.surface_velocity` (the struck surface's
    own motion), which the Striker has measured since 2026-10-05.
  - From the struck point they leave along the surface, the way of the slide. A skim
    raises them 15° off the surface in a 20° cone (half-angle). The straighter in the
    blow, the higher they rise and the wider the cone, up to straight off the surface in
    a 70° cone for a blow straight in.
  - 8 to 28 sparks, at 0.9 of the sliding speed (1.5 to 5 m/s), by the sliding speed
    from 1 to 6 m/s. A spark the cone sends into the surface bounces off it.
  - Each spark flies a closed-form path under gravity with air drag
    (`assets/effects/sparks/sparks.gdshader`), drawn as a streak that cools from
    white-yellow to dull red over 0.18 to 0.55 s.
  - One instanced draw per burst; three bursts per flint take turns.
  - The Stone gained a stone `Strikeable` for this, so everything that hits it now
    strikes it: readout totals only, as it has no `Health`.

| Material | `id` | Blunt: threshold → full energy | Slash |
| --- | --- | --- | --- |
| cloth (`assets/strike/cloth.tres`) | 1 | 1 J → 60 J | the same as blunt |
| wood (`assets/strike/wood.tres`) | 2 | 2 J → 75 J | the same as blunt |
| stone (`assets/strike/stone.tres`) | 3 | 6 J → 150 J | not taken: struck blunt |

These are starting values, to be tuned in the headset. The thresholds were accepted
there (2026-09-30). The full energies keep the old rates' relative toughness: at 1.0,
0.8 and 0.4 per J, the same damage took 1 : 1.25 : 2.5 times the energy above each
threshold, and the spans here (59, 73 and 144 J) are that ratio, rounded to whole full
energies. The sharp types start equal to blunt, as the
player described cloth ("super easy") and wood ("slightly tougher") the same way for
all four; each can be set apart per material.

| Weapon | Features (`Sharp` children; working direction in the weapon's space) |
| --- | --- |
| sword, dagger, longsword | `EdgeA` (+X) and `EdgeB` (-X): edges along the blade (0.44 / 0.19 / 0.66 m); `Point` (+Y): a point |
| axe | `Bit` (-X): an edge along the head's whole front face (0.216 m). It was 0.178 m until 2026-10-02, so a swing landing a corner first, 2.4 cm off its end, struck blunt. |
| pickaxe | `PickPoint` (-X, tilted 8.3° down): a point; `Adze` (+X): an edge across the head (0.068 m) |

Edges reach 2 cm from their line and count within 50° of the blow; points reach 3 cm
and count within 35° (forgiving, decided with the player). Everything else (flats,
guards, pommels, handles, the axe's back, fists, boxes) is blunt.

| Piece | File | Role |
| --- | --- | --- |
| `StrikeMaterial` | `scripts/strike/strike_material.gd` | Shared read-only config: `id`, `display_name`; per type, whether it is taken, its threshold and full energy; `damage_of()` |
| `Strike` | `scripts/strike/strike.gd` | One strike's report: type (`Kind`: blunt or slash) and the `Sharp` feature that dealt it, striker, target (the struck object), material, point, normal, speed, the striker's `velocity` against the struck body and the struck surface's own `surface_velocity` (since 2026-10-05), effective mass, energy, damage (0, or `MIN_DAMAGE` 1 to `MAX_DAMAGE` 10), holding hands (`held_by`), gap |
| `Sharp` | `scripts/strike/sharp.gd` | A `Marker3D` on a weapon: an edge or a point, whose strikes slash. Its -Z the way it works, its Y along an edge, `length` (0 for a point), `reach`, `max_angle`; `fit()` |
| `Strikeable` | `scripts/strike/strikeable.gd` | On any struck object (its parent: a body, or a model whose bodies it marks): its material (turning a type it does not take into blunt), its totals in all and by type, `struck(strike)` |
| `Health` | `scripts/props/health.gd` | Takes its `strikeable`'s damage: `maximum`, `current`, `take_damage()`; `changed(current)`, and `depleted` once at 0 |
| `HealthDisplay` | `scripts/props/health_display.gd` | A Label3D showing a `Health` as "24 / 30", updated on `changed` |
| `LootDrop` | `scripts/props/loot_drop.gd` | Beside a `Health`: on `depleted`, drops `count` of `loot` into the object's parent, clear of each other and of anything else (`gap` 2 cm); `dropped(items)` |
| Ore veins | `scenes/props/ore_vein.tscn`; `ore_vein_<ore>.tscn` | The base (a stone `Strikeable`, 30 `Health`, the display 1.17 m up, a `LootDrop` of 4, `depleted` wired to the root's `queue_free`) and one inherited scene per ore adding its model (scaled 0.75) and its ore (`scenes/props/ores/<ore>_ore.tscn`) as the loot; the level's five veins (`Copper` … `Cobalt`) instance them |
| `Striker` | `scripts/strike/striker.gd` | On every physical object that can hit: measures strikes at physics priority -110. That is before DynamicPhysical (-100) and HandGrab (-86), so `Grabbable.holders` still names who held the object during the step, and before the recorder (-88) |
| `HandStrikes` | `scripts/physical/hand_strikes.gd` | One per hand: publishes the strikes the hand made to the snapshot. Sources are the hand itself (1), what it holds (2), and what it was last to let go of, for its first strike within 2 s (3) |
| `HandHaptics` | `scripts/interface/hand_haptics.gd` | The buzz in each hand holding a striker, from `PlayerPhysical.hand_strike` (`full_strike_energy` 100 J, `strike_duration` 0.06 s); it already buzzed a bare hand's touches |
| `StrikeReadout` | `scripts/debug/strike_readout.gd` | A Label3D over a target, plus a dot that fades over 1 s where the strike landed |
| `StrikeSparks` | `scripts/effects/strike_sparks.gd` | On the flint (`Sparks`): a burst of sparks for each of its `striker`'s strikes on its `materials` (stone), the way the moving piece slid (`slide_of`, `spray_direction`, `glance_of`); tuning in m/s and degrees; `sparked(point, direction, strength)` |
| `SparkBurst` | `scripts/effects/spark_burst.gd`; `scenes/effects/spark_burst.tscn` | One burst: a MultiMesh of 32 streaks drawn by `assets/effects/sparks/sparks.gdshader` (`sparks.tres`), placed in world space without physics interpolation, set through instance uniforms, hidden between bursts |
| Targets | `scenes/props/strike_targets.tscn` | `ClothDummy` (cylinder r 0.15 m, 1.6 m), `WoodPost` (0.2 × 1.6 × 0.2 m), `StoneBlock` (0.5 × 1 × 0.5 m); instanced once in the level at (3, 0, -3.6) |

Strikers sit on the five weapons, the level's three boxes and both hands, after each
hand's `CollisionShape3D`, which `HandDrive` takes as child 0. Recordings get per-hand
columns: `*_strikes`, `*_strike_source`, `*_strike_energy`, `*_strike_damage`,
`*_strike_speed`, `*_strike_mass`, `*_strike_material`, `*_strike_kind` (since rung 2).
`Analysis.strikes(rows)` lists them, and `analyze_session.gd` prints them.

## What Jolt gives (step 0, Godot 4.7.2, scratch project)

- Contacts are reported whenever `max_contacts_reported` is above 0, with
  `contact_monitor` off. A body set to 0 reports none.
- A 15 m/s continuous-collision hit on a wall is in the next tick's contact list with gap
  0 and its pre-impact velocity (14.9 m/s), while the body itself already reads 0 m/s.
- Contact points and normals are where the step's collision test found them: at the
  step's start, one step behind the body's pose, or at the impact for a
  continuous-collision hit. The normal points out of the other body toward this one.
- The gap `(p_self − p_other)·n` is positive for look-ahead contacts (+1.75 cm seen),
  0 at a continuous-collision impact, and negative when overlapping. A contact touches
  if its gap is no more than what the bodies closed by in the step plus `touch_margin`
  (`Striker.touches`); a felled piece of a tree reads its impacts with the same test
  (fall damage, `documents/procedural_trees.md`).
- Contact velocities include the step's gravity: a box resting on a floor closes at
  0.136 m/s (`g·Δt`), well under the 0.5 m/s floor.
- Contact impulses are estimates made before solving (Godot's Jolt documentation), and
  they are non-zero for approaching look-ahead contacts 1.75 cm out. They are not used
  here.
- Without continuous collision, a 15 m/s hit is first seen 13 cm deep in the wall, still
  with the right speed.
- `inverse_inertia_tensor` is in world axes. `basisᵀ · tensor⁻¹ · basis` gives the
  body's own inertia exactly.

## Ladder

R1 and R2 are built; R3 and R4 were dropped (damage types only). Health followed on
2026-10-02.

| Rung | Adds | What the headset teaches |
| --- | --- | --- |
| R1 blunt (built 2026-09-30; accepted in the headset) | Strikes from every prop, weapon and hand; materials; readout; recording | Do the energies and thresholds match how hard each blow feels? Does each real blow register exactly once, even fast swings? |
| R2 sharp damage types (built 2026-10-01) | `Sharp` feature nodes (blade edges and points, axe bit, pickaxe pick and adze). Slash (stab and lodge until 2026-10-02) is chosen by where the contact is and how the feature leads the blow; stone takes only blunt. Damage only; nothing moves differently | Does the classification match what the player meant? |
| ~~R3 lodge~~ | Dropped 2026-10-01: damage types only, no sticking | |
| ~~R4 stab~~ | Dropped 2026-10-01: damage types only, no pushing in | |
| Health (built 2026-10-02) | Damage 1 to 10 by strength; `Health` on the level's ore veins, shown over them, gone at 0 | Does a light blow read 1 or 2 and a hard swing 10? Does a vein take the right number of blows? |
| Tree chopping, rungs 1 to 4, then steps 1a and 1b (built 2026-10-02; `procedural_trees.md`) | The level's tree struck as wood, grown in segments; slashes open its segment lines, any line on wood thick enough to hit, standing or felled. What cuts through a line scales with the wood's cross-section, 300 at the trunk's first line. A trunk line's 8 sides each take a sixth of that, and a slash also opens the sides either side by a quarter of its damage; a branch line is one side. A notch fades round the wood. Cut through, a standing trunk's top falls away from the uncut wood, hinged to the stump at first; a branch drops; a felled trunk is bucked into logs. Twigs and leaves break when something moves through them at 2 m/s or faster, never for the player's body | How many swings does a line take, and does chopping around the trunk feel right? Can the player chop above their head, cut branches at their lines and buck a lying log? Do leaves break only when swung through? |
| Tree chopping step 1c, lone pieces (built 2026-10-02; `procedural_trees.md`) | A piece with no line left to chop shows its health above it (50 trunk, 10 branch, slashes only); at 0 it is gone and drops 3 logs a segment of trunk or a stick a segment of branch; the stump goes last, the tree with it | Do logs and sticks drop where expected and settle? Do 50 and 10 feel right? |

Settled while building R2: a contact is mapped onto the weapon at both the step's
start pose and its end pose (about the impact pose for a continuous-collision hit),
and the better fit counts.

## Checks

```
godot --headless --xr-mode off --fixed-fps 72 --path . -s tests/harness/run_scenarios.gd -- strike_punch_cloth strike_punch_stone strike_press_post strike_rest_sword strike_sword_post strike_axe_stone strike_longsword_two_hand strike_box_cloth strike_box_drop strike_dagger_let_go strike_sword_flat_wood strike_sword_edge_stone strike_axe_bit_wood strike_pick_wood strike_adze_wood strike_dagger_stab_cloth strike_spin_20 strike_spin_40 strike_spin_60 strike_box_vein strike_vein_break vein_loot_drop chop_axe_tree chop_axe_fell chop_box_tree chop_axe_high chop_axe_toe chop_root_loot chop_log_loot chop_stick_loot grab_ore_pressed grab_ore_join sparks_flint_skim sparks_flint_head_on sparks_stone_swung sparks_flint_wood
godot --headless --xr-mode off --path . -s tests/strike/test_damage_health.gd
godot --headless --xr-mode off --path . -s tests/effects/test_strike_sparks.gd
```

The scenarios keep the posts they need (`"targets"`) and put them where they want them
(`"place"`). Their checks come from each scenario's `"expect"` (`_accept_strike`).
Every strike's damage must equal its material's for its energy, and its energy
`½·m·v²`. Simulated results, 2026-09-30, desktop (the energies unchanged since; damage
under the old rule and on the 1 to 10 scale of 2026-10-02):

| Scenario | Strike | Speed | Mass met | Energy | Damage (old) | Damage (1-10) |
| --- | --- | --- | --- | --- | --- | --- |
| strike_punch_cloth | the right fist, knuckles first, into cloth | 5.50 m/s | 0.96 kg | 14.5 J | 13.5 | 3 |
| strike_punch_stone | the same punch into stone | 5.51 m/s | 0.97 kg | 14.7 J | 3.5 | 2 |
| strike_press_post | an open palm pushed into wood at 0.2 m/s and held | no strike | | | | |
| strike_rest_sword | the sword let down 2 cm onto stone, left lying 3 s | 0.68 m/s, once | 1.03 kg | 0.24 J | 0 | 0 |
| strike_sword_post | the sword held in one hand, pushed edge first into wood | 4.46 m/s | 0.64 kg | 6.3 J | 3.5 | 2 |
| strike_axe_stone | the axe held in one hand, head first into stone | 4.69 m/s | 0.79 kg | 8.6 J | 1.0 | 1 |
| strike_longsword_two_hand | the longsword in both hands, thrust tip first into wood | 3.13 m/s | 2.72 kg | 13.3 J | 9.1 | 2 |
| strike_box_cloth | a 2 kg box launched face first into cloth | 3.91 m/s | 2.00 kg | 15.3 J | 14.3 | 3 |
| strike_box_drop | the 2 kg box dropped flat 0.5 m onto stone | 3.22 m/s | 2.00 kg | 10.3 J (m·g·h 9.8 J) | 1.7 | 1 |
| strike_dagger_let_go | the dagger thrown at the cloth dummy, counted for the hand that let go | 2.76 m/s | 0.26 kg | 0.98 J | 0 (glancing, under cloth's 1 J) | 0 |

The fist meets close to the hand's whole 1 kg. The box meets exactly its 2 kg face-on
and when landing flat. The sword meets 0.64 kg near its middle, while the longsword,
thrust along its length in two hands, meets 2.7 of the 3.9 kg (sword and hands) behind
it.

Rung 2 (sharp types, 2026-10-01) adds a type check to every scenario above: the
fists, boxes, the resting sword and the axe's back on stone are blunt; the sword's
edge into wood is a slash (`EdgeA`); the longsword's tip, thrust in two hands, is a
stab (`Point`; a slash since 2026-10-02). The dagger thrown glancing is blunt. It also adds six scenarios. The
axe and the pickaxe are laid turned round where their other side has to face the post.

| Scenario | Blow | Feature | Type | Speed, mass met, energy | Damage (old) | Damage (1-10) |
| --- | --- | --- | --- | --- | --- | --- |
| strike_sword_flat_wood | the sword's wrist turned a quarter, so its flat leads, into wood | none | blunt | 2.41 m/s, 1.05 kg, 3.1 J | 0.8 | 1 |
| strike_sword_edge_stone | the sword's edge into stone | `EdgeA` | blunt (stone takes no slash) | 4.70 m/s, 0.43 kg, 4.8 J | 0 | 0 |
| strike_axe_bit_wood | the axe's bit into wood | `Bit` | slash (lodge until 2026-10-02) | 4.57 m/s, 1.74 kg, 18.1 J | 12.9 | 3 |
| strike_pick_wood | the pickaxe's pick into wood | `PickPoint` | slash (stab until 2026-10-02) | 4.97 m/s, 1.40 kg, 17.3 J | 12.2 | 3 |
| strike_adze_wood | the pickaxe's adze into wood | `Adze` | slash (lodge until 2026-10-02) | 3.95 m/s, 1.86 kg, 14.5 J | 10.0 | 3 |
| strike_dagger_stab_cloth | the dagger thrust tip first into cloth | `Point` | slash (stab until 2026-10-02) | 3.40 m/s, 1.41 kg, 8.1 J | 7.1 | 2 |

A head-first or point-first blow meets much more of the weapon (1.4-1.9 kg) than the
sword's edge near its middle (0.6 kg). Every rung 1 strike keeps its energy and damage,
since the sharp types start equal to blunt.

**A/B against rung 1's full run:**
- The 114 earlier scenarios are unchanged, but for `fingers_grip_box`'s known flip.
- The measured spin scenarios moved by under 10⁻⁷ m. They now run after the six new
  scenarios, and run alone they are bit-identical.
- The same 45 failing criteria; CHECKLIST and GUIDED pass.

Measured, not checked: a sword spinning free sweeps its blade into the cloth dummy.

Its flat leads, so these strikes are blunt.

| Spin | Detected | Gap when first seen | Speed read |
| --- | --- | --- | --- |
| 20 rad/s | yes | 3.6 cm deep | 5.1 m/s |
| 40 rad/s | yes | 9.4 cm deep | 6.7 m/s (understated: the overlap turns the normal) |
| 60 rad/s | yes | 1.2 cm short (closing) | 13.9 m/s |

### Damage scale and health (2026-10-02, simulated, desktop)

The harness's pushes (3-5 m/s) all deal 1 to 3; real swings close two to two and a half
times faster (session 1). Two scenarios strike an ore vein, the copper one moved to
where the box scenarios put the posts; they run last, so the others run as before:

| Scenario | Strike | Health | Display |
| --- | --- | --- | --- |
| strike_box_vein | the 2 kg box launched at 6 m/s into the vein: struck as `Copper`, through one of its bodies; met 0.89 kg at 5.89 m/s (off its centre, so the box turned), 15.4 J on stone (the 75 % vein, the box aimed at its middle: 0.84 kg, 14.7 J, the same damage) | 30 → 28 (damage 2); the vein stays | "28 / 30" |
| strike_vein_break | the same, the vein left with 1 health | 1 → 0; `depleted`, and the vein left the level in the same tick | "0 / 1" |

`tests/strike/test_damage_health.gd` checks the rules with little physics (30 checks,
all pass): the scale's ends and middle, that it only grows within 1 to 10, the
project's materials, Health counting down (and never below 0, nor reporting `depleted`
twice), strikes reaching Health (stone taking a slash as blunt), and the vein: its 7
bodies marked, unmarked out of the tree and marked again back in, freed at 0. Then the
loot: four copper ores dropped once into the vein's parent, around its meshes' middle,
none inside another, unpushed after a step. A block where one would appear sends only
that one a spacing higher, clear of the block.

Loot (2026-10-02). `strike_vein_break` now also expects its four ores. In
`vein_loot_drop` the vein's health is emptied at once, with nothing else about:

| What | Measured |
| --- | --- |
| Where they appeared | 4 copper ores, in the tick the vein went, at the middle of its meshes (0.485 m up in the 75 % vein; 0.647 at full size), in a square 0.183 m a side around it (0.163 needed to stay clear; 0.346 and 0.326 for full-size ores), inside the vein |
| Pushed as they appeared | nothing: after the first step each moved at −0.1361 m/s, gravity's alone, unturned |
| Where they ended | at rest on the floor (0.053 m up), 0.10-0.15 m from where the 75 % vein stood (full-size ores from the full-size vein: by 1.5-1.7 s, 0.106 m up, 0.20-0.27 m) |

Grabbing the half-size ore (2026-10-02). `grab_ore_pressed`: a palm pressed onto it on
the table took hold 6.1 cm from its centre and lifted it 0.21 m. `grab_ore_join`: a second
hand whose grab point is brought to the centre of an ore the first holds took hold 4.8 cm
from the centre and held it from outside (4.4 cm at the nearest). With the old grab point
it took hold 0.8 mm from the centre and sat 2.4 cm inside, failing both checks. A/B
against the old grab point and full-size ores: only those two scenarios' recordings
change, besides `fingers_grip_box`'s known contact-reporting noise.

A/B against the same tree without the veins' `LootDrop`: the recordings of all 136
scenarios are identical but for wall-clock timing, and the only failures that differ
are the loot checks, which fail without it.

**A/B against the full run before the change** (rsync'd copies differing only in
these files):
- In the 133 earlier scenarios the recordings are identical but for the strike damage
  column and wall-clock timing. The same 45 failing criteria; CHECKLIST and GUIDED pass.
- `fingers_grip_box` is the exception, and it is noise. Its contact reporting (the right
  hand's contact count, `prop_push_hands`) read 0.097, then 0.125 twice, in three full
  runs of the new build, 0.111 in three of the old one (one with an inert node added),
  and 0.125 run alone in both. Its motion is identical in all of them.

The recorded headset blows (sessions 1 and 2, 227 strikes, a two-handed one counted
once) on the new scale, by the energies they read. Inferred, not felt:

| Blows | Cloth | Wood | Stone |
| --- | --- | --- | --- |
| Fists | median 1 (0-9) | median 2 (0-10) | median 3 (0-5) |
| Held weapons | median 7 (0-10); 25 of 60 at 10 | median 7 (0-10); 20 of 51 at 10 | median 6 (0-10); 16 of 65 at 10 |

Session 2's hard blows on stone read 0 (four light ones), 3, 6, 8, 9 (four) and 10 (ten),
so a vein's 30 health would take about four of them. On cloth and wood, about two in
five weapon blows reach the top; raising those full energies would spread hard swings
apart.

### Sparks (2026-10-05, simulated, desktop)

Four scenarios launch a piece with no hand (`_drive_sparks`, last in the list). All
pass:

| Scenario | Strike | First burst |
| --- | --- | --- |
| sparks_flint_skim | the flint at 3 m/s, 20° down, onto the stone block's top along +x: met it at (2.81, -1.30, 0) m/s | along +x, 21.9° up (0.93, 0.37, 0), strength 0.42 |
| sparks_flint_head_on | the flint dropped at 3 m/s onto the top: (0, -3.26, 0) m/s | straight up |
| sparks_stone_swung | the Stone at 3 m/s along +x, grazing the underside of a flint held still in the air: the flint's Striker met it at (-2.98, 0.54, 0) against a surface moving (2.98, -0.54, 0), normal (0.48, 0.87, 0.06) | along +x, the stone's way (0.985, -0.173, 0) |
| sparks_flint_wood | the flint at 3 m/s into the wood post's face | struck the wood, no sparks |

The Striker's own gate decides which skims strike. A pair must close at 0.5 m/s along
the normal, so at 3 m/s a skim shallower than about 10° never strikes and throws no
sparks. A sweep with gravity off, starting 2.5 cm above the top, struck at 10°, 11°,
12° and 14°, not at 4°, 6°, 8° or 9° (closing 0.52 m/s at 10°). A flint already resting
on the stone and dragged across it stays engaged and never strikes.

`tests/effects/test_strike_sparks.gd` (23 checks, all pass) checks the mover rule
(either piece moving, or both), the spray (a skim 16° up along its slide, a slide along
the surface at the lift alone, a blow straight in straight up, a 45° blow at 37°), which
strikes spark (not on wood, not under 1 m/s), the counts and speeds at both ends, the
three bursts taking turns, and the bursts hiding once their sparks are out.

Desktop render (Mobile renderer, RTX 5090, 1280 × 720, not a headset measure): a live
burst adds one draw call and 64 primitives (all 32 instances; the unused ones collapse
to a point). The streaks show over the grey block in daylight but are thin. Whether
they read in the headset, in daylight and in shade, is unverified.

### Headset session 1 (2026-09-30 22:46, free play, 216 s, desktop WiVRn, 72 Hz)

`free_2026-09-30T22-46-27.csv`. The telemetry has 185 strikes (19 two-handed). Which
1.2 kg weapon is which is inferred from the mass met: the second's heavier median
suggests the pickaxe's head.

| Striker | Strikes | Median closing speed | Median mass met | Median energy (max) |
| --- | --- | --- | --- | --- |
| Fists | 45 | 5.2 m/s | 0.97 kg | 12.8 J (86) |
| Dagger | 32 | 8.4 m/s | 0.99 kg | 31.8 J (73) |
| 1.2 kg weapon, 85-110 s | 26 | 12.7 m/s | 0.82 kg | 77 J (127) |
| Longsword, two hands | 20 | 13.0 m/s | 0.55 kg | 43.6 J (212) |
| 1.2 kg weapon, 155-169 s | 24 | 9.5 m/s | 1.51 kg | 59.8 J (326) |
| Axe | 36 | 13.0 m/s | 0.96 kg | 73.1 J (232) |

- **No missed fists:** every fist approach within 10 cm of a post faster than
  1.5 m/s struck (41). Weapon positions are not recorded, so weapon misses cannot be
  checked from the data.
- **Bounces:** three struck again 0.12-0.14 s after a blow, just past the 0.1 s re-arm.
- **Fist and dagger both counted:** three times, the hand holding the dagger struck
  the post 20-40 ms after the dagger.
- **Weapons strike harder than fists in play.** Real swings closed at two to two and a
  half times a punch's speed, unlike the harness's 4.5 m/s push, so the worry that
  weapons would read weaker than fists did not show.
- **The longsword reads lighter than the one-handed weapons:** a long blade is struck
  far out, where little of its mass is met.
- **The player's account:** "The readout felt accurate. Every blow read something. All blows counted 1 time but there were a few that bounced and hit a second time (which was fine). I did throw stuff and it felt fine."
- **Rung 1 accepted.** The bounces are kept, and the 0.1 s re-arm is unchanged. The
  three dagger-and-fist pairs were not felt as double counts, and are left as they are.
- **Throws:** of eight lets-go, three were throws (6.5-8.4 m/s). Two struck the stone
  within 0.15 s, and the other reached no post.

### Headset session 2 (2026-10-02 09:31, free play, 95 s, desktop WiVRn, 72 Hz)

`free_2026-10-02T09-31-20.csv`. The telemetry has 42 strikes. Which weapon is which is
inferred from the held mass.

| Striker | Post | Strikes by type |
| --- | --- | --- |
| axe (1.0 kg) | stone | 12 blunt (up to 201 J) |
| a 1.2 kg weapon | stone | 9 blunt |
| the same | wood | 10 stab (up to 184 J), 2 blunt bounces 0.12-0.16 s after a stab |
| longsword (1.9 kg) | cloth | 5 slash (97-165 J), 2 stab, 1 blunt (met 2.6 kg: near the hands) |
| let go | cloth | 1 blunt |

- **Stone:** no sharp type was ever recorded on it.
- **Lodge** did not occur: the axe struck only stone, and no adze strike was recorded.
  Lodge was removed the next day.
- **Found after the session:** the pickaxe's stab feature was named `Pick`, like its
  collision box. Both nodes loaded and the pick still collided, but sibling nodes with
  the same name break Godot's lookup by name, and freeing the pickaxe leaked the box
  (seen as leak messages at exit). The feature was renamed `PickPoint`. No more leaks;
  `strike_pick_wood` and `strike_adze_wood` pass.
- **The player's account:** "It feels decent." Then the types were cut to slash and
  blunt (Decisions); the two-type build is checked in the harness only. The 19 strike
  scenarios pass, with energies and damage unchanged.

## Risks

- **Fast swings.** Jolt's continuous collision sweeps only straight-line motion, so a
  turning blade can end a step deep in a target. Above, nothing was missed against the
  0.3 m dummy, but at 40 rad/s the speed read was about half the blade's. Thin targets
  (such as a 2 cm board) may be missed outright. A swept check of the blade comes only
  once that is shown in a recording.
- **Contact budget.** `max_contacts_reported = 4` keeps the deepest four contacts, so a
  weapon resting on something while it strikes could lose the strike's contact. Raising
  the count does not change how the weapons move, since they already report.
- **Follow-through.** `m_eff` leaves out the arm and body behind a blow. If punches read
  weak, an arm-mass allowance is a later choice, not built.
- **A fist holding a weapon** strikes with the hand's own mass in R1.
- **The boxes now report contacts,** which turns off Jolt's contact merging for them.
  In the harness's A/B, only `palm_push_box` moved measurably (the box pushed 2.4 mm
  less over 0.18 m), and no check changed.
- **Cost.** A Striker with no contacts, or asleep, returns at once. One in contact reads
  at most its reported contacts (4, or 16 for a hand) and allocates only when it
  strikes. The Quest 3S cost is unmeasured.
- **Ore veins are stone** (2026-10-02): every weapon strikes them blunt on one scale, so
  a pickaxe mines no faster than another weapon blow of the same energy, and fists
  (median 3 on stone in play) would break a vein in about ten punches.
- **Loot falls from the vein's middle** (about 0.43 m in the 75 % vein), as asked. A drop whose
  place stays taken for eight spacings up is left at the last; not seen. A drop costs
  a few shape queries, once, when an object breaks.
- **Health displays** are one billboard Label3D per vein (five in the level), drawn
  every frame as transparent geometry; their text is rebuilt only when the health
  changes. Their cost on Quest 3S is unmeasured.
