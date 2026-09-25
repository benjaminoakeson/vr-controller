# Physical body and hands: implementation proposal

## Status

A proposal for step 2 of the [handoff sequence](2%20-%20prototype_handoff.md#recommended-implementation-sequence).
Nothing here is implemented. It turns the direction in [the physical design](1%20-%20physical.md)
into a concrete first prototype, answers the handoff's migration questions, and lists
the choices that are yours to make ([Decisions](#decisions-needed)). Numbers marked
*initial* are starting values for tuning, not measured optima.

Evidence used:

- **Simulated baseline:** [3 - locomotion_baseline.md](3%20-%20locomotion_baseline.md),
  a headless run of the current controller with scripted inputs.
- **Scratch tests of the installed Godot 4.7.2 with Jolt** (headless desktop, 72 Hz):
  joint drives, paired forces, single-body joints, parent motion, contact reporting
  and capsule resizing. Results are summarised in [Appendix A](#appendix-a-installed-engine-checks).
  The scratch scripts were not committed; a committed drive test is part of rung 1.
- **Not yet available:** any headset session, and any standalone Quest 3S
  measurement. Everything that depends on feel is marked as awaiting headset
  validation.

## What the prototype must answer

Before the rest of the controller is built around it, does a weighted dynamic body
with strength-limited hands feel right? That means:

- Walking and standing feel planted without feeling glued.
- Gentle contact stays still, and strong effort can move the body.
- Climbing depends on strength and weight.
- Nothing produces explosive forces or free propulsion.

It should do all that at 72 Hz within a sensible physics budget.

## Proposed representation

| Element | Node | Notes |
| --- | --- | --- |
| Body | `RigidBody3D`, capsule r 0.2 m, *initial* 75 kg | All three rotation axes locked: turning belongs to the rig, and the capsule is symmetric. Friction 0 on its physics material; traction comes from the motor. |
| Hands (rung 3) | Two `RigidBody3D`, *initial* 1 kg, simple box/sphere colliders, `gravity_scale` 0 | Own weight excluded; held-object weight still arrives through the grip. |
| Hand drives (rung 3) | One `Generic6DOFJoint3D` per hand, body ↔ hand | Linear and angular limits off, motors on (see [Hand drive](#hand-drive-and-force-transfer)). |
| Grip (rung 4) | A joint from hand to hold or object | Created on grab, removed on release. |
| Ground sensor | One downward shape cast per tick | Shared by locomotion, support classification and the static layer's `body_grounded`. |

Arms, legs and fingers stay posed by the static/visual layers; nothing else is
simulated until an interaction needs it.

### Hierarchy and transform ownership

Tested: a dynamic body under a moving parent is teleported with it, at zero
velocity. A frozen kinematic child is carried with a large implied velocity (it
would shove whatever it touches). `top_level = true` isolates both. So:

```text
VrController (Node3D; never moved during play)
├── PhysicalRig        (script: owns the XR origin, body motor, ground sensing)
│   ├── Body           (RigidBody3D, top_level)
│   ├── LeftHand       (RigidBody3D, top_level)   rung 3
│   └── RightHand      (RigidBody3D, top_level)   rung 3
└── XROrigin3D
    ├── HMD, LeftController, RightController   (XR runtime owns their poses)
    └── StaticSkeleton (+ SkeletonDebug)        (unchanged)
```

The empty `PhysicalSkeleton` placeholder under `XROrigin3D` is removed. Physics nodes
are set `top_level` even though their parent never moves, so a future spawn or respawn
of `VrController` cannot teleport them by accident.

Owners:

- **XR runtime:** headset and controller poses (room space).
- **Physics engine:** body and hand transforms and velocities. Scripts only apply
  forces or set motor targets. Direct writes are allowed only in explicit teleport
  or recovery calls.
- **`PhysicalRig`:** the only writer of the `XROrigin3D` transform. Turning, recentering
  and spawn go through its methods, never around it.
- **`StaticSkeleton`:** reference poses (unchanged).

### Migration strategy

Build the new body as a **scene variant**, `scenes/player/vr_controller_physical.tscn`,
alongside the existing player. The level keeps using the current player until the
variant passes its comparison. The baseline harness takes the player scene as a
parameter, so the same scenarios run against both controllers and produce comparable
numbers. The old `PlayerBody` is retired only after we agree the variant replaces it.

## Room-scale movement and the XR origin

This is the handoff's first open question. With a dynamic body, the rig cannot
simply "ride" the body (`origin += body motion`): the body would never catch up with
the player's real steps, because the room would move with it. Nor may real steps
teleport the body.

### Proposed rule: the rig carries everything except catching up

Each tick, with the tracked footprint `P` (the headset's position on the floor, in
world space at the current origin) and the body position `B`:

- **Separation** `E = P − B` (horizontal). It is how far the real player is from the
  physical body.
- **Catching up is locomotion.** When `|E|` exceeds a *lean allowance* (*initial*
  0.15 m), the walking motor adds a follow velocity `(|E| − allowance) / follow_time`
  toward `P`. This is a bounded force like any other, so a heavy obstacle or a wall
  stops it. Inside the allowance, a weak re-centring (*initial* 1 s time constant)
  slowly brings the body back under the head.
- **The rig follows the body, minus the catching up.** After the step, the body has
  moved by `ΔB`. The origin moves by `ΔB` less the part of it that closed the
  separation beyond the allowance:

  ```text
  closing = clamp(dot(ΔB, Ê), 0, max(|E| − allowance, 0)) · Ê
  origin += ΔB − closing        (vertical motion is always carried)
  ```

Consequences:

- **Stick walking, pushes, impacts, falls and climbing** move the body, and the
  view goes with it. The view never moves on its own.
- **A real step** moves the view immediately (it is the player's own head). The body
  follows with bounded effort and the origin does not move, so there is no artificial
  camera motion.
- **Leaning** within the allowance does not move the body. The head can lean over a
  counter or approach a wall to within a few centimetres. The baseline cannot, because
  its body is always under the head, holding the head 0.2 m off walls.
- **Walls:** when the body is blocked and the player keeps walking, the separation
  grows and the head can enter the wall. See the next section.

This uses one vector test and no extra physics queries. Its weakness: while `|E|`
exceeds the allowance, stick motion toward the head first closes the gap before the
view moves. That delay is bounded by the allowance plus the lag, and needs headset
tuning.

### When the real head goes where the body cannot

The baseline pulls the whole view back 1:1 (measured 0.199 m of pull-back for 0.2 m of
blocked head motion). Proposed instead:

1. **Head-penetration fade:** one small sphere query at the headset per tick
   (radius *initial* 0.1 m, static world only). Screen fade scales from 0 at contact to
   full black at 0.1 m depth.
2. **Recenter on excessive separation:** if `|E|` stays above *initial* 0.6 m for
   0.5 s (the player walked through a wall in their room), fade out, move the origin
   so `E = 0` under the body, then fade in. This is one explicit `PhysicalRig` method,
   also used for spawn and manual recentering.

The alternatives are listed under [Decisions](#decisions-needed): keeping the
baseline's pull-back, or pulling back only beyond the allowance.

### Crouching and body height

The capsule's height follows the head (*initial* head height minus 0.1 m, minimum
0.6 m), with the feet anchored: the shape is offset by half its height. Tested: a
one-tick shrink from 1.7 m to 1.0 m and back produced no pop. The problem is growing
into a ceiling, which leaves the body wedged and sinking 0.14–0.18 m. So:

- **Shrink immediately.**
- **Grow only after an upward shape cast** confirms clearance, and only by the clear
  amount per tick. Otherwise keep the current height. The head can still rise into
  a low ceiling, and the fade covers it.
- **Moving supports:** do not grow in the tick a support is carried upward. This is
  tested in the rung-1 harness.

## Callback sequencing

In Godot each physics tick first syncs body transforms from the previous step, then
runs `_physics_process` callbacks by priority, then steps the solver with the forces
and motor targets just set. All drives are set in `_physics_process`; none depend
on `_integrate_forces`. Proposed order:

| Priority | Node | Reads | Writes |
| --- | --- | --- | --- |
| −100 | `PhysicalRig` | Body state from the last step, the tracked headset, the stick | Origin (carry rule); ground sweep; `body_grounded`, `commanded_travel`; body motor force |
| −90 | `StaticSkeleton` | The origin as just updated; the trackers | Reference poses (unchanged) |
| −89 | `SkeletonDebug` | Reference poses | Debug meshes (unchanged) |
| −80 | Hand drives (rung 3) | This tick's reference hand poses, the hand bodies | Motor targets and force limits; grips |
| −79 | Physical debug | Everything above | Debug meshes |
| −70 | `LocomotionRecorder` | Everything above | CSV (only when asked) |

This is one pose snapshot per tick, with no same-tick circular correction. The hand ↔
body ↔ origin ↔ reference loop that climbing relies on closes across ticks. It is
deliberate and damped by force limits. The rung-1 harness verifies the one-tick
relationship by measurement, rather than assuming it from priorities.

## Ground support and walking

- **Ground sensor:** one sphere cast per tick from inside the capsule's lower
  hemisphere, down by the support distance (*initial* 0.08 m). Mask: Static and
  Dynamic props, with the player's own layers and any held object excluded. The body
  is *supported* when the hit is within range, the slope is at most the walkable angle
  (*initial* 45°), and the body is not separating upward from the support faster than
  *initial* 0.5 m/s. So a launch is not pulled back down. The support's velocity at
  the contact point (zero for static) feeds the motor.
- **Walking/standing motor:** exactly the [slope-compensated equation](1%20-%20physical.md#slope-compensated-walking),
  applied with `apply_central_force` once per tick, and never by writing velocity.
  Desired surface velocity = stick intent × walk/run speed + the follow velocity above.
  Force limited by *initial* leg force 900 N (12 m/s² on the flat at 75 kg) and
  response time 0.12 s. Idle targets zero surface velocity with the same limit, so
  standing effort is bounded and a strong push or impact still moves the body.
- **Unsupported:** no ground compensation. Air control is a separate small force
  (*initial* 150 N). Steep slopes disable the motor; with friction 0 the body slides,
  and a steep-slope fixture is added to the level to check it.
- **Static layer contract:** `ground_probe(from, to)` keeps its signature and return
  shape. It gets an explicit mask of Static only, so reference feet no longer plant
  on loose boxes or hands. `body_grounded` comes from the support classification.
  `commanded_travel` stays movement intent (stick × speed), not measured velocity.

Compared with the baseline, speed changes will no longer be instant. The baseline
reaches full walking speed in 0.08 s and stops within 4 cm. A 900 N limit gives
roughly a 0.15 s start and 0.1 m stop at 1.5 m/s. That is heavier by design, and the
number is for headset tuning.

## Hand drive and force transfer

Tested options, all between a 1 kg hand and a 70 kg body with the pair's momentum
conserved:

| Drive | Result | Verdict |
| --- | --- | --- |
| 6DOF linear **spring** | Clean tracking | No force limit, so it cannot express strength |
| 6DOF linear **motor** as a velocity servo (target velocity = gain × error, set every tick) | Force limit enforced exactly by the solver; no overshoot at gain ≤ 20/s | **Recommended** |
| Manual paired PD forces | Stable only up to about 3000 N/m; capping the force also clips damping (17 % overshoot) | Fallback |

**Recommended:** a velocity-servo motor on each hand's 6DOF joint to the body, with
two separate strength controls, as the design asks:

- **Responsiveness:** target velocity = gain × position error (*initial* gain 15/s,
  capped at *initial* 6 m/s), and the same for orientation (angular motor; Jolt's
  angular sign is inverted, as tested, and must be encoded once in the drive).
- **Effort:** the motor's force limit is set every tick to
  `min(strength, base + stiffness × |error|)` (*initial* base 20 N, stiffness 2000 N/m,
  arm strength 600 N per hand). A blocked hand therefore pushes harder the further
  the real hand goes past it, up to its strength. Gentle contact produces small forces;
  a servo with a fixed limit would push at full strength against any obstruction.

The joint applies the equal and opposite reaction to the body, once, inside the
solver. No manual reaction force is added on top. With the body's rotation locked,
reaction torque from off-centre hands is absorbed rather than turning the body. That
is acceptable for an upright prototype.

What follows from the shared model:

- **Wall pushes:** hand reaction versus the body's bounded standing force. At the
  *initial* values, one gentle hand (a few tens of newtons) stays below the 900 N leg
  limit, while two hands pushed well past the wall (up to 1200 N) can move the body.
  That is a continuous response, not a hand-count gate.
- **Free hand motion:** the body recoils by 1/75 of the hand's momentum, and the
  standing motor absorbs it. There is no net propulsion.
- **Climbing (rung 4):** a grip joint fixes the hand to the hold. Pulling the real
  hand down moves its target below the anchored hand. The motor then lifts the body,
  and the rig and the targets follow next tick. At 75 kg the body weighs 735 N:
  - two hands (1200 N) can lift it;
  - one hand (600 N) lowers slowly;
  - legs on a ledge add support.
  Whether one hand should hold full weight is a [decision](#decisions-needed).
- **Reach:** hand targets are clamped to arm length (from the static shoulder) before
  driving. If a gripping hand's target runs past *initial* 0.5 m of separation, the
  grip releases. That is a recovery rule, not a force.
- **Mass ratio:** 1:75 behaved in the scratch tests. It is re-checked under contact
  and grip load at rung 3.

## Collision layers

| Layer | Name | Members | Collides with (mask) |
| --- | --- | --- | --- |
| 1 | Static | CSG level, static bodies | nothing needed (static) |
| 2 | Dynamic | Loose props (the 2/5/10 kg boxes) | 1, 2, 5, 6 |
| 5 | Player | Body | 1, 2 |
| 6 | Hands | Both hands | 1, 2 |

- **No self-collision:** body and hands never collide with each other.
- **While an object is held,** a collision exception between it and the body stops
  the player standing on, or pushing themselves with, what they hold.
- **Queries:**
  - Ground sweep: mask 1 and 2, excluding the player's own bodies and held objects.
  - Static-layer probe: mask 1.
  - Head fade: mask 1.

Moving platforms, if wanted later, get their own layer so support is opt-in.

## Other migration effects

- **Stairs:** the capsule cannot climb the level's 0.25 m steps unaided. Rung 2 adds
  step assistance: when supported motion meets a riser, check height, clearance and
  landing surface, then lift with a bounded upward force over about 0.15 s. The
  baseline instead teleports 12–14 cm in one tick (measured), so this should also
  be more comfortable. Collision ramps are not used without agreement.
- **Arm-pump running:** the measurement moves into a small shared component, and its
  output scales the motor's desired speed exactly as today (run factor 0–1 →
  1.5–6 m/s). The simulated run scenarios must reproduce the baseline's run factors.
- **Turning:** later rung, through `PhysicalRig` (rotate the origin about the head;
  the body has no yaw). Hands and targets are rotated with it so turning never shows
  up as hand velocity.
- **Out of bounds:** the baseline falls forever off the level edge. `PhysicalRig`'s
  recenter/spawn method gets a kill height that respawns at the start with a fade.

## Tuning and debug exposure

Exported with units and ranges, grouped:

- **Body:** mass, radius, minimum height, head margin.
- **Walking:** speeds, response time, leg force, walkable angle, air force, lean
  allowance, follow time, re-centre time.
- **Head:** fade radius, fade depth, recenter distance and time.
- **Hands:** mass, gain, maximum speed, base force, stiffness, strength, angular
  equivalents, grip release distance.

Debug visuals distinguish the reference hand (existing `SkeletonDebug`) from the
physical hand and draw the separation. The recorder gains columns for:
- hand separation and motor force;
- body separation `|E|`;
- fade level;
- support state.

## Increment ladder

Each rung is built, run through the automated harness (simulated results clearly
labelled), then checked in the headset through a guided session like the baseline's,
before the next one starts.

| Rung | Builds | Automated checks | Headset questions |
| --- | --- | --- | --- |
| 1 | Scene variant; body; `PhysicalRig` carry rule; lean allowance; ground sensor; walking/standing motor; head fade/recenter; clearance-aware height; layers; committed Jolt drive test | Baseline scenarios on the variant: stand, flat, half, ramps, drop, wall, crouch. Plus steep-slope slide, box push by walking, upward launch not pulled down, one-tick sequencing | Does walking feel weighty but responsive? Real steps, leaning, the wall fade, crouching |
| 2 | Step assistance; arm-pump port | Steps and run scenarios match the baseline's outcomes | Step comfort vs the baseline's snap; running feel |
| 3 | Hands with servo drives; debug visuals | Gentle vs strong wall push (one and two hands); free-hand propulsion; hand separation and force; fast swing into wall (tunnelling) | Hand lag, blocked-hand feel, pushing |
| 4 | World grip; climbing fixture | One- and two-hand hang; pull-up; release while hanging; separation release | Climbing feel, strength settings |
| 5 | Object grip; boxes; a two-handed object; release policy | Lift/swing 2/5/10 kg; wedged object; release energy | Weight feel, throwing |
| 6 | Smooth/snap turning via `PhysicalRig` | Turn with and without grips; no hand-velocity spikes | Turn comfort |

Standalone Quest 3S profiling needs an Android export preset (4.7.2 export templates
and a debug keystore are already installed on this machine). The current headset path,
WiVRn, runs the game on the desktop, so its timings are not Quest 3S results.

## Decisions needed

Each changes how the game feels. The recommendation is listed first.

1. **Real head into a wall**
   - **Recommended:** fade by penetration depth, and recenter behind a fade when
     separation exceeds 0.6 m.
   - Keep the baseline's 1:1 pull-back.
   - Pull back only beyond the lean allowance.
2. **Leaning**
   - **Recommended:** a lean allowance (*initial* 0.15 m) so the head can lean over
     counters and approach walls.
   - Keep the body always under the head, as in the baseline.
3. **Walking response**
   - **Recommended:** accept a heavier start and stop (*initial* about 0.15 s and 0.1 m).
   - Tune toward the baseline's near-instant 0.08 s / 4 cm by raising leg force.
     That also raises standing resistance to pushes.
4. **One-hand strength**
   - **Recommended:** one hand cannot hold full body weight at default strength.
     Hanging one-handed lowers you slowly, and two hands or a foothold hold you.
   - One hand holds full weight.
5. **Migration**
   - **Recommended:** a scene variant compared side by side, retiring `PlayerBody`
     after agreement.
   - Replace `PlayerBody` in place.

Rung 1 depends on decisions 1–3 and 5. Decision 4 can wait until rung 4.

## Awaiting headset validation

Everything subjective:
- walking weight;
- the lean allowance;
- the fade and recenter;
- crouch height behaviour;
- step comfort;
- hand lag and strength numbers;
- climbing.

Plus real tracking noise and refresh-rate changes during play (WiVRn was seen moving
between 72, 90 and 120 Hz).

The baseline headset session is also still pending. It can run at any time and is not
a prerequisite for rung 1. Standalone Quest 3S cost is unmeasured.

## Appendix A: installed-engine checks

Godot 4.7.2 (Fedora build), Jolt, 72 Hz, headless desktop, gravity off unless noted,
1 kg hand and 70 kg body. These are scratch tests; the rung-1 test will repeat the
drive checks as committed code.

- **6DOF linear spring** (1000 N/m, 60 N·s/m): settles at the target in 0.25 s with no
  overshoot. The pair's momentum stays at 0.
- **6DOF linear motor with a 20 N limit:** peak hand acceleration exactly 20 m/s².
  Momentum is conserved (hand 1 kg × 1.97 m/s against body 70 kg × 0.028 m/s).
  Re-run and confirmed.
- **6DOF angular spring and motor:** they work, but the direction is inverted. A
  +0.5 rad target settles at −0.5 rad, and +3 rad/s gives −3 rad/s.
- **No unsupported-property warnings** were printed for the drive settings used.
- **Paired PD forces:** stable with critical damping up to about 3000 N/m (0.4 %
  overshoot); 10,000 N/m or more does not settle. A 50 N cap gives 17 % overshoot.
- **Velocity servo** (motor target velocity = gain × error, force limit 50 N): no
  overshoot at gain ≤ 20/s, settling in 0.22 s. Gain 40 overshoots 25 %; gain 72,
  60 %.
- **Single-body joints:** `physics/jolt_physics_3d/joints/world_node` defaults to
  Node A, so the world is A. A lone body acts as `node_b` whichever slot it is in.
- **Parent motion:** a dynamic child is teleported with its moving parent, at zero
  velocity. A frozen kinematic child is carried at an implied 7.2 m/s. `top_level`
  isolates both. Re-run and confirmed.
- **Contacts:** by default a frozen kinematic body reports contacts with dynamic
  bodies but not the static floor. `generate_all_kinematic_contacts` adds the floor
  contact.
- **Capsule resize with the feet anchored:** 1.7 → 1.0 → 1.7 m in single ticks gives
  zero vertical pop. Growing under a 1.4 m ceiling leaves the body wedged, with the
  feet sunk 0.14–0.18 m.
- **Not tested:** stability under heavy contact, held-object mass ratios, Quest CPU
  cost.
