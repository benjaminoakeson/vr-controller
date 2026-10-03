# Player controller architecture

## Status

Decision record, 2026-09-25. Four whole-stack structures were compared (Appendix A);
**Option B, the dynamic body, was chosen.** This document is the structural spec for
all four layers of [the overview](0%20-%20player_controller_overview.md): what nodes
exist, who owns which transform, the order of a tick, the interfaces between layers,
and the migration ladder. It replaces the earlier physical design, handoff, baseline
and proposal documents, which were retired on the same day.

Labels used below:

- **Established**: agreed structure. Change it through discussion.
- **Initial**: a starting value or formulation to tune in the headset.
- **Decide at rung N**: a policy with a recommended default that the named rung tests.

Engine: Godot 4.7.2, Jolt, Mobile renderer, 72 Hz display and physics baseline with
the runtime's reported refresh rate followed by XR startup. No tick duration is ever
hard-coded; forces go through `apply_central_force`, impulses once per event.

## 1. Composition (Established)

```text
Player (Node3D, identity, never moved)   scripts/player/player.gd
├── Rig (XROrigin3D)                     scenes/player/rig.tscn        STATIC layer + tracking
│   ├── Head (XRCamera3D)
│   ├── LeftController / RightController (XRController3D)
│   └── StaticSkeleton (+ SkeletonDebug)  existing scripts, unchanged
├── Physical (Node3D at identity)        scenes/player/physical.tscn   PHYSICAL layer
│   ├── RigCarrier (Node)                scripts/physical/rig_carrier.gd
│   ├── Body (RigidBody3D, top_level)    scripts/physical/body.gd
│   │   ├── CollisionShape3D             capsule made at runtime, never shared
│   │   ├── GroundSensor (ShapeCast3D)   sphere
│   │   └── CeilingSensor (ShapeCast3D)  sphere, used only before growing
│   ├── GroundSense (Node)               scripts/physical/ground_sense.gd
│   ├── Locomotion (Node)                scripts/physical/locomotion.gd (coordinator)
│   │   ├── FollowHead, StickWalk, ArmPumpRun, AirControl, StepAssist, Jump, Turn, Crouch, Recovery
│   │   └── (each a LocomotionModule, scripts/physical/modules/*.gd)
│   ├── LeftHand / RightHand (RigidBody3D, top_level)  scripts/physical/hand.gd
│   │   ├── CollisionShape3D
│   │   └── Poke (Area3D)                index-finger probe for the GUI
│   ├── LeftHandDrive / RightHandDrive (Generic6DOFJoint3D)  scripts/physical/hand_drive.gd
│   ├── LeftFingers / RightFingers (Node)  scripts/physical/hand_fingers.gd  finger shapes on each hand
│   ├── BodyParts (Node)                 scripts/physical/body_parts.gd  part shapes (6.6, body parts)
│   │   └── PropsOnlyParts (AnimatableBody3D, top_level)  neck, head; thighs, calves, feet switched off; made at runtime
│   └── Interaction (Node)               scripts/physical/interaction.gd
├── Visual (Node3D)                      scenes/player/visual.tscn     SKELETAL layer
│   ├── PhysicalDebug                    scripts/debug/physical_debug.gd  hidden until B (section 8)
│   ├── CharacterModel                   assets/models/player/body1.glb (Skeleton3D + skinned mesh)
│   └── PoseMapper                       scripts/visual/pose_mapper.gd
├── Interface (Node3D)                   scenes/player/interface.tscn  GUI layer
│   ├── ViewFade, HandHaptics, SkeletonToggle  built (section 8)
│   ├── Anchors (wrist_left, wrist_right, chest, belt, head)
│   └── displays as child scenes of anchors
└── Debug (optional)                     scenes/player/debug.tscn, instanced by player.gd on demand
```

Rules:

- The player scene is `scenes/player/vr_controller.tscn` (UID kept, so the level's
  instance survives); its root node is `Player`. Rig, Physical and Debug are separate
  scenes (`rig.tscn`, `physical.tscn`, `visual.tscn`, `debug.tscn`) instanced into it
  (Visual since rung 7.1, 2026-10-02), and Interface holds what section 8 lists as built. `player.gd` holds exported refs
  to the parts, wires them in `_enter_tree` (before any child is ready), and instances
  `Debug` only when asked (section 9). XR session startup is a child node,
  `XRStartup`, running `scripts/vr_controller/vr_controller.gd`.
- Pending renames, best done in the editor's FileSystem dock so references follow:
  `vr_controller.tscn` to `player.tscn`, `vr_controller.gd` to `xr_startup.gd`, and the
  level's instance node `VrController` to `Player`. They were left alone in rung 1
  because the editor had those files open.
- Physics bodies are never children of the rig. Jolt teleports a dynamic child with a
  moving parent at zero velocity. Every physics body is `top_level`.
- `Physical` runs its stages by explicit calls inside one `_physics_process`, so the
  order within the layer is readable code. Priorities only separate layers.
- No autoload, group lookup, or tree search anywhere in the player. XR Tools nodes are
  not used (its hand meshes and animations may be reused under `Visual`).

## 2. Ownership (Established)

| Transform or state | Only writer | Notes |
| --- | --- | --- |
| Head, controllers (rig-local) | XR runtime | read only |
| `Rig` position and yaw | `RigCarrier` | carry, pull-back, turn, teleport, recenter, respawn |
| `Body` transform and velocity | Jolt | script applies forces; direct writes only inside `relocate` |
| Hand transforms | Jolt through the drive joints | direct write only in hand recovery |
| Held object | Jolt through its grip joint | layer switched while held |
| Static trackers | `StaticSkeleton` | unchanged |
| `PoseSnapshot` | `Physical` | read by Visual, Interface, Debug |
| Visual bones | `PoseMapper` | never writes physics |
| Interface anchors | `Interface` | never writes physics |

`RigCarrier.relocate(delta: Transform3D, reason)` is the one path for teleport,
recenter and respawn: it moves body, rig, hands and held objects by the same delta with
zero velocity, clears per-tick state and emits `relocated(delta, reason)` with reason in
`{CARRY, TURN, PULL_BACK, TELEPORT, RECENTER, RESPAWN}`. Recenter calls
`XRServer.center_on_hmd(XRServer.DONT_RESET_ROTATION, true)`, then re-seats body and
hands and drops grips. `RigCarrier.turn(angle)` rotates the rig about the head footprint
and rotates hands and held objects (transform and velocity) about the same pivot in the
same call, so a turn never appears as hand velocity; the body does not rotate.

## 3. Tick order (Established)

| Priority | Stage | Reads | Writes |
| --- | --- | --- | --- |
| -110 | `Striker` on each prop, weapon and hand (the strike model, 2026-09-30; `documents/strike_model.md`) | its body's contacts from the last solve, `Grabbable.holders` | strikes: the struck body's `Strikeable` totals and readout; `HandStrikes` publishes each hand's into `PoseSnapshot` |
| -100 | `Physical.step()`: RigCarrier begin, GroundSense, Locomotion modules, Body integrate, RigCarrier commit | head, stick, grips, body state from the last solve | motor force, jump/step impulses, height, rig, `body_grounded`, `commanded_travel` |
| -90 / -89 | `StaticSkeleton` / `SkeletonDebug` (unchanged) | rig after the move, `ground_probe` | static trackers |
| -85 | `HandDrive` x2 | this tick's static hand and shoulder trackers | joint motor targets and force limits |
| -80 | `Interaction` | grip and trigger, hand contacts, poke overlaps | grip joints, exceptions, layer swaps, throw velocities |
| -70 | `Physical.finish_tick()` | all above, contact monitors | `PoseSnapshot`, signals |
| -60 / -50 | `PoseMapper` / `Interface` | snapshot; for the model also the static torso, neck and hip facing and the eyes | bones / anchors |
| -88 | `Debug` (`SOLVE_PRIORITY + 2`; this row said +10 until 2026-09-30, but the code has run it here) | snapshot | CSV, readout |
| solve | Jolt | forces, motors, joints | body, hands, held objects |

The loop hand target → drive → body reaction → carry → next tick's targets closes
across ticks, never inside one. The static skeleton solves after the rig has moved for
this tick, as today.

## 4. Snapshot and events (Established)

`PoseSnapshot` (`scripts/physical/pose_snapshot.gd`, `RefCounted`) is allocated once by
`Physical` and overwritten in place each tick: tick, delta, rig transform, head
transform, tracked hands, physical hands with velocities, per-hand separation and
force limit, body foot position, body velocity, capsule height, supported, ground
normal, support velocity, commanded travel, run factor, head lead, rig delta, head
obstruction depth, held objects, physics ms; since 2026-09-30 each hand's strikes (a
count, the last `Strike`, and where it came from: the hand, what it held, or what it
let go of). Visual, Interface and Debug read
`physical.snapshot`. Nothing writes back.

Signals on `Physical`, connected by `player.gd` to whatever consumes them (haptics,
audio, GUI, gameplay): `supported_changed(bool)`, `landed(vertical_speed)`,
`stepped(height)`, `body_blocked(normal)`, `contact_started(hand, other, position,
normal, impulse)`, `contact_ended(hand, other)`, `impact(other, magnitude)`,
`grabbed(hand, object)`, `released(hand, object, linear_velocity, angular_velocity)`,
`head_obstructed(depth)`, `relocated(delta, reason)`, `interface_pressed(target)`.
Each signal is added in the rung whose consumer first needs it; rung 2 publishes
none, because the view fade and the recorder read the snapshot. Published so far:
`hand_contact(side, speed)` (rung 4), and since 2026-10-02 `hand_strike(side, strike,
source)`, the strike model's form of `impact`. Both are consumed by `HandHaptics`.

## 5. Static layer contract (Established, unchanged)

`StaticSkeleton` keeps its three inputs exactly:

| Input | Written by | Meaning |
| --- | --- | --- |
| `ground_probe: Callable` | `GroundSense`, once in `_ready` | `(from, to) -> {position, normal}` or `{}`; ray on the Static layer only, so feet no longer plant on loose props or hands |
| `body_grounded: bool` | `GroundSense`, every tick | the support classification below |
| `commanded_travel: Vector3` | `Locomotion`, every tick | world-space movement intent (stick times top speed), not measured velocity |

The static layer never resolves world collision and never learns about the physical
hands. The difference between static and physical hand poses is the effort signal the
drives use.

## 6. Physical layer, Option B

### 6.1 Body (Established structure; Initial values)

- `RigidBody3D`, mass 75 kg (initial), all angular axes locked, `can_sleep` off,
  `gravity_scale` 1, zero-friction `PhysicsMaterial` (traction comes from the motor),
  `contact_monitor` on, reporting up to 16 contacts (for `impact`, and to tell which
  body part something pushes).
- The node origin is at the feet; the capsule `CollisionShape3D` is offset up by half
  its height, so resizing never requires a transform write and the feet stay anchored.
  With rotation locked, the centre of mass position has no dynamic effect.
- Height policy: capsule height = max(head height in rig space, 0.6 m). Shrink
  immediately. Grow only when `CeilingSensor` reports clearance for the new height, and
  only when the change exceeds 1 cm, so the shape is not rebuilt every tick and the body
  cannot wedge under a low ceiling.
- Legs drawn up (**built 2026-09-28**, climbing step 2, `LegTuck` in 6.5): the capsule's
  bottom rises by `tuck` above the feet while its top stays with the head (the capsule
  never shorter than 0.6 m). The origin stays where the feet would reach, so drawing
  the legs up or letting them down moves no view. Drawing up is immediate (it only takes
  collision away); letting down goes only into the room the same sensor finds below
  (`legroom`, its ball swept down from the bottom), so the legs never push into
  anything.
- The body stands under the head's centre, not the eyes (**decided 2026-09-25**, at
  the player's request: "My body isn't in front of my eyes while standing, so the
  capsule should really center at my head"). The head's centre is the static
  skeleton's head offset from the eyes, 0.10 m behind and 0.02 m below them
  (`PlayerRig.head_centre()`). Following, the lean limit, recentring and the body's
  first placement all measure from it; the eyes still decide the head obstruction
  below. Standing upright against a wall, the eyes are now 0.1 m from it rather than
  0.2 m, and turning the head no longer swings the body.
- Head obstruction: a ball (radius 0.06 m, Static layer; 0.1 m before the body moved
  under the head's centre) swept each tick from inside the capsule's top to the eyes;
  how far the eyes are past the first surface it meets feeds the comfort policy in
  6.10. The radius is a little over the camera's 5 cm near plane, so the view starts
  to darken before a wall is cut open, and leaves 4 cm of lean at a wall before it
  does. A sweep rather than an overlap test at the head,
  because level collision is a surface mesh: a head fully inside a thick wall would
  overlap nothing. Zero while the head is untracked.
- Invariants set in code, not the inspector: rotation locked, never sleeps, zero
  friction, centre of mass pinned at the feet, and linear damping replaced with zero
  (the project default of 0.1/s cost 1.2 % of walking speed against the motor).
- Standing hold (added at rung 4, revised after its headset session): once the body
  has come to rest and nothing asks it to move faster than 0.2 m/s, the legs keep it
  where it stands against light contact, up to 80 N, with a stiff spring (20,000 N/m)
  toward an anchor that moves with any slow command and slips along with the body
  under a harder push. On top, the motor's usual braking resists movement in
  proportion to speed. So a hand resting on a wall does not slide the body away, and
  a deliberate push moves the body about as far as the push goes, stopping when the
  push stops: there is no threshold to break through. Without any hold, the walking
  motor's velocity servo let a steady push slide the body away at
  `F * response_time / mass`. Walking and stopping are unchanged.

### 6.2 Ground sense and support (Established structure; Initial values)

One sphere cast per tick from inside the capsule's lower hemisphere, down by the support
distance (0.08 m initial), mask Static and Dynamic. The body is **supported** when the
hit is within range, the surface angle is at most the walkable angle (45° initial), and
the body is not separating upward faster than 0.5 m/s. Outputs: `supported`,
`ground_normal`, `support_velocity` (the collider's velocity at the contact, for moving
platforms), `near_ground` (a hit within the step height, for step-down assistance).
This is the only ground query the physical layer makes; every module reads it. With
the legs drawn up (6.1) it is the capsule's drawn-up bottom that stands or not.

### 6.3 Walking motor (Established formulation; Initial values)

`Locomotion` sums module contributions into one desired surface velocity and `Body`
applies one bounded force per tick. Velocity is never written outside `relocate`.

```text
supported:
  n      = ground_normal
  g_t    = g - n * dot(g, n)                          gravity along the slope
  v_rel  = body.linear_velocity - support_velocity
  v_s    = v_rel - n * dot(v_rel, n)                  velocity along the surface
  v_des  = desired surface velocity, projected onto the surface, |v_des| = top speed
  F      = limit_length(mass * ((v_des - v_s) / response_time - g_t), leg_force)
airborne:
  F      = limit_length(mass * (v_des_h - v_h) / response_time, air_force)   horizontal only
body.apply_central_force(F)
```

Speed is held along the slope, as today. Gravity compensation lives inside the leg
limit, so a slope the legs cannot hold is slid down. Above the walkable angle the motor
is off and gravity acts (friction material for steep surfaces is tuning). A push,
impact or fall changes velocity through the solver; the motor resists it only up to
`leg_force`. Initial values: walk 1.5 m/s, run up to 6 m/s, response time 0.12 s,
leg force 900 N, air force 150 N.

### 6.4 Room-scale carry rule (Established formulation; Initial values)

The head leads, the body follows, and only the body's own locomotion is carried into
the rig. `E` is the horizontal lead of the footprint of the head's centre (6.1) over
the body's feet; `v_head` is that point's horizontal velocity from the player's own
movement in the room (its rig-local delta per tick, turned into world space).

```text
FollowHead contributes:
  v_follow = limit(v_head + Ê * max(|E| - dead_zone, 0) / follow_time, max_follow_speed)
RigCarrier, after the body is driven (τ: motor response time; k: share of the
requested motor force the legs delivered this tick):
  s += (v_follow - s) * (δ / τ) * k          modelled horizontal velocity from following
  u  = horizontal(v + (F_motor / m + g) * δ, with the ground's support removed)
                                             what the solve would do untouched
RigCarrier, next tick (after the solve moved the body by ΔB, velocity now v'):
  c = horizontal(v') - u                     what walls and furniture changed
  s += ĉ * min(max(-s·ĉ, 0), |c|)            following that was stopped is let go
  rig.position += (ΔB_xz - s * δ) + ΔB_y     vertical always carried
RigCarrier, after measuring the head:
  if the head is clear (no obstruction) and |E| > lean_limit:
      rig.position -= Ê * (|E| - lean_limit)  the view is pushed back
```

Consequences: stick walking, pushes, impacts and falls move the view with the body; a
real step moves only the view and the body keeps up with it, so room-scale stays 1:1
and the world stays fixed to the real room; a body blocked by a wall while the player
keeps walking does not drag the view, and the head-obstruction policy takes over.
Values: dead zone 0.01 m, follow time 0.2 s, max follow speed 3 m/s, lean limit
0.35 m (the capsule's 0.2 m radius plus about 0.15 m of lean past an edge).

**Decided after rung 3 (2026-09-25):** a body stopped by furniture while the head is
clear above it pushes the view back beyond the lean limit, as the old body did, with
room to lean over a table's edge. A head inside geometry keeps the rung 2 policy
(fade, recentre if it persists), because walls obstruct the head before the lean
limit is reached. The follow model accounts for what the world stopped and for the
legs' force limit; without them, a capsule sliding along furniture while following
the head moved the view (0.39 m on an angled approach to the pedestal).

**Revised after rung 3 (2026-09-25)**, replacing the rung 2 decision to keep a 0.15 m
lean allowance: in the headset the capsule lagged the head while walking and ended up
offset from it. Measured on a scripted room walk at 0.8 m/s, the old rule let the
body trail by up to 0.36 m, stall 0.15 m away after every stop (a discontinuity at the
allowance edge left the slow drift unreachable), and drift the world 8.3 cm against
the room. With the head's velocity fed forward, a continuous correction and a modelled
follow response in the carrier: at most 0.07 m of lead at the instant a step starts,
5 mm after stopping, and no drift.

**Revised after the damped-vault session (2026-09-25):** the modelled following is
taken out whole, as `s * δ`. Before, only the body's movement along the follow
direction was taken out, clipped to between zero and `|s| * δ`. Walking in the room
against the stick, the body moves opposite to its following, so nothing was taken
out. The real step then moved the view a second time, the head fell behind the body,
and the follow correction cancelled the stick. The player reported stopping or moving
oddly, and immediate motion sickness. Walls and furniture are still handled by the
removal of stopped following above.

### 6.5 Locomotion modules (Established)

`LocomotionModule extends Node` with `contribute(frame: LocomotionFrame, delta)`. Modules
are children of `Locomotion` in scene order, cached once in `_ready`. `LocomotionFrame`
is reused each tick: wish direction, top speed, desired surface velocity, impulses to
apply, exclusive flag. An exclusive module ends the chain (`Recovery` only).

| Module | Contributes | Notes |
| --- | --- | --- |
| `FollowHead` | `v_follow` from 6.4: the head's room velocity plus a gap correction | never carried into the rig |
| `StickWalk` | head-relative stick direction times top speed | today's deadzone and forward rule |
| `ArmPumpRun` | run factor from hand vertical speed while both grips are closed | today's measurement; scales top speed 1.5 to 6 m/s |
| `AirControl` | horizontal steering while airborne | built as the motor's airborne branch in `CapsuleBody.drive()`, not a separate module |
| `StepAssist` | an upward lift speed while supported motion meets a riser with a valid tread | tread test by sweeping the capsule shape alone (`cast_motion` and `get_rest_info`, from 1 cm above the feet), not `test_move`, which with the body parts on the body would test the arms and legs too: blocked ahead by a surface too steep to walk; headroom up to 0.3 m; clear 0.15 m ahead at that height; a walkable tread 0.03 to 0.3 m up. The body lifts toward 2 m/s out of a separate 2,500 N step budget, easing to what gravity would stop in the remaining height, so it arrives at rest. **Decided at rung 3**: this smooth lift, not a position write |
| `Jump` | a take-off speed once per press of the right A button (`ax_button`) while supported | the body applies one impulse to reach it relative to its support; 0.4 m jump height. A press in the air or during recovery is dropped. **Decided at rung 3** |
| `SnapTurn` | a 45° snap yaw through `RigCarrier.turn`, about the head's centre | **built 2026-09-30**, snap only for now (decided with the player); smooth turning later |
| `Crouch` | the height policy in 6.1 | no explicit crouch input; the headset height is the crouch |
| `LegTuck` | how far the legs are drawn up (6.1), and standing up out of it | **built 2026-09-28** (climbing step 2), below |
| `Recovery` | exclusive: respawn below the kill height, unstick, tracking-loss holds | see 6.9 |

Built, in this order: Recovery, StickWalk, ArmPumpRun, FollowHead, StepAssist, Jump,
SnapTurn, Crouch, LegTuck (`scripts/physical/locomotion/`).

`SnapTurn` (**built 2026-09-30**; decided with the player: snap only, 45°, and no jank
for the physical body, held objects or climbing). The right stick pushed sideways past
0.7 turns the view 45° that way in one tick; it must come back inside 0.3 before it
turns again. The carrier turns the rig about the vertical through the head's centre
(`PlayerRig.head_centre()`, 0.1 m behind the eyes), which the body stands under, so the
body need not move and the eyes swing 7.7 cm round it, as a real head's do. Then, in the
same tick and before anything else works it out (`DynamicPhysical._turn`), everything
that keeps a place or a direction in the world for the player turns with it, places and
motion alike, so the whole player turns rigidly: the body's velocity (unless a hand
holds a hold, which anchors it) and the tick's planned wish and follow, so a walk goes
straight on the way the view now faces; each hand, as it is relative to the player,
with its velocity and what its drive and arm strength remember; what a hand holds (moved
once, by the lead, when both hands hold it; one being seated is placed from the turned
hand) and the two hands' shared frame; the static skeleton's feet, chest facing and pelvis memory (`StaticSkeleton.turn`),
so the avatar does not twist round after the view. A hand on a hold stays on it, and the
climb then moves the body round the hold until the player's hands are back on it, as it
does when the player turns for real: the turn's jump of the player's hand is closed as
the drive closes any gap, not at the jump's speed (`HandDrive.retarget`). For 45° the body
and the view slide about 25 cm over 0.3 s, at up to 2 m/s (decided with the player
2026-09-30, over turning about the hands at once or keeping the body where it hung: at
first the climb was re-based, and the player found it odd that the skeleton turned while
the physical body did not follow it). With both hands on holds the pair of the player's
hands is turned too, so each stays a few cm off its own hold; the climb closes their
mean. Tried first and dropped (harness, 2026-09-30): turning about the eyes left the
body 7.7 cm out of place, and following the head back nudged a two-handed longsword by
1-2.5°; moving the body there at once put it 3 cm into the table's edge and a dagger on
it, and the push back out, carried into the view like any push, moved the view 1.1 cm
and flung the held sword at 1.7 m/s; turning a hand's whole velocity while the body kept
its own left the hand 1.6 cm off its target. Recorder column `turns`.

`LegTuck` (**built 2026-09-28**, climbing step 2; decided with the player: the legs
draw up while a hand holds a hold **or an empty hand presses down on something** (so a
bare ledge or the table can be mantled too), to about the hips, stand up smoothly at
1 m/s, and the skeleton's legs fold with them). The arms carry the body while a hand
holds a `Climbable` hold or an empty hand touches something with its target at least
3 cm below it (`press_depth`; last tick's hands, from the snapshot). Once they have
carried it off the ground (not supported, not stepping down, and the ground more than
`landing_reach` below the feet: hauled up faster than 0.5 m/s the body is unsupported a
centimetre up, and there the legs drew up and straight back down for a tick, four
times in the 2026-09-30 headset session) the capsule's bottom rises
to 0.53 of the head's height above the feet (`tuck_share`; 0.90 m for a 1.70 m head,
the hip joints at about 0.57 of it), fixed while drawn up; meanwhile the body parts'
hips ride up to stay at least their radius above that bottom (`BodyParts`), since at
0.86 m they would otherwise be what catches on a ledge (raised from 0.47, 0.80 m, after
the 2026-09-30 headset session at the player's request: "the legs should lift up
slightly higher so it is easier to mantle things"). The legs
come down: still carried, when the ground below is within 4 cm of where the feet would
stand (`landing_reach`), so a body lowered onto a floor lands on its feet rather than
its drawn-up bottom; once nothing carries the body, at once into whatever room there
is below (hanging in the air they just drop), and what is left, when the drawn-up body
rests on something (hauled or vaulted over a ledge onto it), by standing up: the legs
lift the body through the step lift (6.3's `step_force` budget) at up to 1 m/s
(`stand_speed`), easing to what gravity would stop in the rest, the legs following
down as it rises, so the view rises smoothly by as much as they had drawn up. The
frame marks that lift as standing up, not a step (`lifting` stays a step's).

While climbing (a hand holds a `Climbable` hold, `DynamicPhysical.climbing()`, **built
2026-09-28**, 6.6.3): `StickWalk` wishes nothing (so arm-pump running stops too), `Jump`
drops presses, `StepAssist` starts no lift, and `Recovery` neither watches the head's
lead for a recentre nor recentres or respawns without letting go of the holds first.
`FollowHead` and air control stay: step 2 (legs tucked up, mantling) needs the body to
follow the head onto a ledge. Harness (simulated): walking 1 m back in the room while a
hand holds, the hold keeps the body where it is and the view is pushed back with it
once the head leads by the 0.35 m lean limit (6.10), 0.62 m of the 1 m; nothing
recentres; let go, the body goes back under the head. **Headset check.**

Step-down (built in rung 3, in `GroundSense` and `CapsuleBody`): for 0.25 s after
leaving support, while not rising and not after a jump, a ray straight down from the
body's centre that finds walkable ground within 0.3 m marks the body as stepping down.
The legs then lower it toward 1.5 m/s with gravity compensated, out of `leg_force`,
keeping traction and the skeleton's feet. A ray, not the ball sweep, because while
the capsule's round bottom rolls over an edge the ball meets the edge's corner first
and reads it as too steep. It does not apply once the body is more than 0.01 m above
where it was last supported: a body the hands have lifted (a vault) is not a step
down, and lowering it would fight the hands.

### 6.6 Hands and drives (Built at rung 4; Initial values)

- Each hand: `RigidBody3D`, 1 kg, `gravity_scale` 0, no damping, `continuous_cd` on,
  `contact_monitor` on, layer Hands, mask Static and Dynamic, so it never touches the
  player's own body. Its collider is the palm: a box 0.03 m thick, 0.08 m across the
  knuckles and 0.095 m from wrist to knuckles, centred on the static palm and scaled
  by the static skeleton's `hand_scale`, with friction 1.0. A flat palm rests, pushes
  and holds by friction instead of rolling on a point (changed from a 0.045 m sphere
  after rung 4, at the player's request). Both are built at startup by `HandDrive`,
  one per hand.
- Each drive: a `Generic6DOFJoint3D` (`HandDrive`, `scripts/physical/hand_drive.gd`)
  with `node_a` = Body and `node_b` = the hand, all limits off, linear motors on and
  angular motors off. It is joined on the first tick, with its anchor at the hand's
  centre and world axes: an anchor off the hand's centre makes the linear drive twist
  the hand (seen in a scratch test), and the body never rotates.
- Per tick at -85, after the static skeleton:

```text
target      = static hand tracker, clamped to arm length (upper arm + forearm + 0.1 m)
              from the static shoulder tracker
velocity    = the target's own velocity (its change since last tick)
desired     = velocity + limit_length((target - hand) * follow_gain, max_follow_speed)
linear motor target (relative to the body) = desired - body velocity
force_limit = clamp(base_force + effort_stiffness * |target - hand|
                    + effort_damping * opening, base_force, hand_strength)
              opening: how fast the gap to the target is growing (negative while
              it closes);
              shared across axes along the needed velocity change, each axis at least
              a quarter of it, so a hand can always resist a push from the side
turning     = a torque on the hand toward the target's spin plus
              rotation error * turn_gain, reached over turn_response, limited to
              min(max_torque, base_torque + torque_stiffness * angle)
```

The solver applies the linear drive's reaction to the body once. A light touch is
light because the limit grows with separation; a hand held against a wall reaches
`hand_strength` only when its target is well beyond it. Held against something, each
hand is a spring between the body and the surface: two hands pressing on a table hold
the 75 kg body on 4000 N/m, which alone bounces at about 1.2 Hz. The damping term
makes that pair critically damped (2 × 550 N·s/m ≈ 2√(4000 N/m × 75 kg)), so a vault
or a push settles where the hands put the body. Rotation uses a torque computed for
the hand's inertia, not the joint's angular motors, and the body's locked rotation
needs no reaction. Its hold against a load grows with that inertia, so the hand turns
with a wrist inertia of 0.04 kg·m² about each axis, standing in for the forearm
behind it (**revised 2026-09-25**, at the player's request: "the physical wrists are
way too weak. They need to be way stronger so I can push against the boxes to lift
them without any grabbing"). With the palm's own 0.0013 kg·m², the torque held
almost nothing: a 5 kg box squeezed between the palms rolled them 28°. Angular motors
held it rigidly but made a palm sliding on the table stick and slip 18 times a second,
and a pointing finger on the wall shake; the scaled-inertia torque keeps the contact
behaviour of the old one. Values: follow gain 15 /s, max follow speed 6 m/s, base
force 20 N, effort stiffness 2000 N/m, effort damping 550 N·s/m, hand strength 600 N;
turn gain 15 /s, max turn speed 20 rad/s, turn response 0.02 s, wrist inertia 0.04
kg·m², torque 4 N·m plus 120 N·m/rad up to 40 N·m (was 0.5 N·m plus 20 N·m/rad up to
20 N·m, with the palm's inertia). With 75 kg (735 N weight) two hands can lift the body
and one cannot. **Decide in the rung 4 headset session**: one hand cannot hold full
body weight.

Tracking loss on a controller: the target is held where it was relative to the body,
with only `base_force`; before a controller is first tracked, its hand rests at the
hip. When the player is relocated, the hands are placed on their targets rather than
chasing them. A hand more than 0.5 m from its target for 0.25 s is placed on it only
if a hand could get there from inside the body without passing through the level;
otherwise it keeps pushing. Each hand's first touch on something is reported as
`hand_contact(side, speed)`, which the interface turns into a controller buzz.

Fingers (`HandFingers`, `scripts/physical/hand_fingers.gd`, one per hand; **decided
2026-09-25**: the fingers are an extension of the palm, not bodies of their own):
each finger and the thumb is three capsule collision shapes on the hand's own body,
sized from the static skeleton's finger lengths and `hand_scale` (radii 10.5 mm for
the thumb, 9 to 7.5 mm for the fingers, tapering to the tip). They have no joints,
springs, mass or inertia of their own: the hand's mass, centre and inertia are fixed
at the palm box's (`HandDrive`), so the fingers never flop and anything they touch
pushes on the whole hand. Every tick, before the physics step, each finger is posed
from the static skeleton's bend for each joint (grip and trigger), limited by what it
would touch:

- Curling (**revised 2026-09-25** after the body-parts session, at the player's
  request: "Each individual finger should have its own independent curl... Each
  finger should curl until it has made contact with an object"): every joint of every
  finger curls at most 720°/s toward its pose, root first, checked in three sub-steps
  against the level and props where the hand will be after the step. A joint stops
  when a bone it moves (its own or any past it) would come within 2 mm of something,
  a four-step search finding how far it can go; the joints past a stopped bone curl on
  until their own bones meet it. So each finger stops where it touches, the others
  closing on, and a finger over an edge or a box's corner wraps around it. Sub-steps
  because the level is a surface: a fingertip that jumped through it in one step would
  find nothing in the way. A joint already resting against what stopped it is checked
  once a tick, not searched again, and a finger with nothing within its reach (one
  ball query) curls without per-bone checks. Before, a finger's three joints moved
  together and the whole finger froze at its first touch, so it could not wrap, and a
  finger brushing a box's side stayed open over nothing.
- Pressed harder than 1.5 N by a push toward the backs of its bones (a table under an
  open hand's pads), a finger opens toward straight, at most 1080°/s, just far enough
  to come clear, and curls again only once it would stay 4 mm further clear than the
  2 mm curl gap, so a hand laid on a table comes down flat on its palm. Before, it
  opened a fixed step each tick and curled straight back onto the surface: the
  fingers twitched (the player: "a little finicky when gripping on the corner of
  boxes... They twitch around sometimes"). Pushed on its palm
  side (a fist's knuckles) or end-on, it stays as it is and stops the hand. Only the
  push straight off each surface counts, not friction, and only contacts that push:
  the physics engine also reports contacts it merely expects within a couple of
  centimetres, which are not touches (the hand's `touching` state now ignores them
  too).
- Each finger's root sits no further toward the palm side than keeps it flush with
  the palm's face: the static skeleton's thumb root is 1 cm toward the palm and would
  otherwise prop a flat hand up off a table.
- Opening toward the pose always follows at once.

Rejected, 2026-09-25: a jointed chain of 15 small rigid bodies per hand on sprung
`Generic6DOFJoint3D` joints (built and tried in the headset; the player: "this is not
at all what I want... I don't want joints and floppiness"). Found building it, with
scratch tests on 4.7.2 with Jolt: torques computed in script oscillated or crept;
`HingeJoint3D` motors ignored their torque limit; `Generic6DOFJoint3D` angular
springs settled exactly but left the fingers soft and lagging a fast close by a
quarter of a second.

Carrying (**built 2026-09-26**, from the player's report that held boxes swung fast
"arced" past the hand and the heavy one dropped; the linear allowance below was
replaced the same day by the arm's strength, 6.6.2): while the hand holds something,
`HandGrab` tells the drive its mass, its inertia about its own centre of mass and where
that centre is. The linear force limit got a steady extra allowance, enough to
accelerate the held mass, counted up to 15 kg (`max_carry_mass`), at 200 m/s²
(`carry_acceleration`; revised 2026-09-26 after the headset session below: first the
whole limit was multiplied by the held mass, which multiplied its opening-rate term
too, so holding the 10 kg box the limit swung between 120 N and 3600 N every other
tick and the hand shook). The turning torque is computed for the hand's and the held
object's inertia together, its limits grow by the full held inertia
(`carry_turn_share` 1.0), and the wrist adds, beyond its limit, the torque that
accelerating the hand needs to keep an off-centre held object from swinging round it
(offset × mass × acceleration, the acceleration taken halfway between what the drive
asks this step and what the last step measured). Consequence to decide with the player: a 40 kg box, too heavy to
lift one-handed before, now lifts (0.17 m in the scenario).

**Decided 2026-09-25:** Jolt's penetration slop is 5 mm
(`physics/jolt_physics_3d/simulation/penetration_slop`, default 2 cm). The default,
sized for metre-scale bodies, let a finger rest up to 2 cm inside a wall without being
pushed out; every scenario passes with 5 mm.

Body parts (`BodyParts`, `scripts/physical/body_parts.gd`; built 2026-09-25 as the
first part of rung 5, at the player's request): the rest of the physical body as
collision shapes posed every tick from the static skeleton, like the fingers: no
joints, no mass of their own, nothing to flop. The player asked for the parts to be
"stopped by the world too", for the forearms to be an extension of the palm, and that
"none of the physical body parts should be able to separate from their connected
neighbors".

| Part | Shape (radius, m) | Lives on | Meets |
| --- | --- | --- | --- |
| Torso, hips, shoulders, upper arms | capsules 0.13, 0.1, spheres 0.06, capsules 0.045 | `Body` | level and props; a push moves the body |
| Forearms | capsule 0.035 | its hand | as the palm does |
| Thighs, calves, feet | capsules 0.075, 0.055, box 0.09 x 0.07 x 0.25 m (0.06 m heel, 1 cm off the ground) | `PropsOnlyParts`, a kinematic body moved with `Body` (layer Player, mask Dynamic) | nothing: switched off since 2026-10-03, still posed and published |
| Neck, head | capsule 0.05, sphere 0.1 | `PropsOnlyParts` | props only |

- **Where each part is posed.** The static skeleton stands under the head; the
  physical body stands wherever the world let it, up to the lean limit behind the head
  (6.4). The hips, thighs, calves and feet are posed where the physical body stands
  (the skeleton's pose shifted by the head's lead), so whatever stops them moves them
  with the body and they settle against it. The torso runs from those hips to the
  neck, which stays with the head, so a head leading the body is a lean. The neck end
  of the torso, the shoulders and the upper arms' shoulder ends go with the head: one
  pressed into something pushes the body, and that push carries the view back out, as
  any push on the body does (6.10). Before this, all parts were posed from the head;
  walking the real head into the pedestal then left the hips, thighs and torso inside
  it while their contacts shoved the capsule away at up to 0.6 m/s and lifted it 2.5
  cm onto the edge.
- **Arms.** Each elbow is solved every tick between the static shoulder and the
  physical wrist (where the static wrist sits on the physical hand), bending the way
  the static elbow does. The upper arm runs shoulder to elbow, the forearm elbow to
  wrist, so they always meet. Out of reach, both bones lengthen to stay joined and the
  stretch is published (`arm_stretch`). The forearm is raised toward the back of the
  hand until its underside is flush with the palm's face, since a forearm thicker than
  the palm would prop a flat hand off a table.
- **The capsule meets most things first.** With its 0.2 m radius, the hips, legs and
  torso sit inside the capsule's footprint standing (they reach 0.075 m ahead of its
  centre) and crouching (up to 0.14 m). So walls and furniture meet the capsule first,
  and the parts matter where they stick out: the shoulders, the arms, and a torso
  leaning ahead of the body. The knees, 0.2 m ahead of the body in a squat with the
  hands forward, pass into the level with the rest of the legs.
- **Legs pass into the level (thighs decided 2026-09-25, the player: "Since the
  capsule is handling body collisions all the way to the feet, maybe we can disable
  the collisions between the world and the feet, calves, and thighs").** The thighs
  had stopped the body 3 cm short of the table with the stick held into it, knees in a
  stride reaching past the capsule. Calves and feet (built 2026-09-25) pass too. Built on
  the body at first, the ground pushing on them fought locomotion in every test: the
  body slid on after stopping, rose off the steps, drifted on the ramp and walked 4.6 %
  fast. The capsule already stands the body on the ground. **Headset check.**
- **Legs pass through props (2026-10-03, the player: "I will crouch down to pick up
  items and my player steps on them kicking them around. I would like to disable the
  leg colliders for objects on the ground. I want to keep the colliders for the
  future").** The thighs, calves and feet are switched off (`CollisionShape3D.disabled`,
  `BodyParts.LEG_PARTS`): they meet nothing, props included, and stay on
  `PropsOnlyParts`, posed every tick and published in the snapshot (and drawn by the
  debug view), for a later hit check to query. The capsule still stands the body and
  shoves what it walks into; the neck and head still push props. **Headset check.**
- **Kept from rung 2:** the neck and head pass into the level too, so a head in a wall
  fades the view (6.10) rather than pushing it back.
- The hips' capsule reaches the floor in a squat to 0.8 m head height (not at 1.0 m; the
  static skeleton sits the hips 0.34 m behind the feet at floor level) and rests there,
  sharing the body's weight; nothing moves.
- `parts_pressing` counts the body's part shapes something pushed on in the last step
  (contact impulse above 0.0005 N·s, which leaves out the engine's merely expected
  contacts); the recorder logs it with the arm stretch.

#### 6.6.1 Jointed arm (built and removed 2026-09-26; superseded by 6.6.2)

Removed the same day at the player's verdict ("this feels like crap ... The arm no
longer matches the skeleton frame enough to even consider this passable when I'm
not interacting with anything at all"); the build is kept outside the project
(`jointed_arm_snapshot`) and described here for the record. Why it failed is in
Progress (arm redesign).


Asked for 2026-09-26 so held objects feel heavy: "try to follow the player skeleton
but drag behind because of the weight. The whole arm chain needs to work together
... If they are too heavy then the arm should naturally show that through sagging
with gravity and not being able to follow the skeleton trackers at quick speeds."
Chosen with the player: **a physically jointed arm**, for **everything the hands
do**, with **human-like** strength (shoulder about 60, elbow about 55, wrist about
12 N·m).

- **Bodies and joints** (`physical_dynamic.tscn`): per side an upper arm (2 kg) and a
  forearm (1.5 kg) `RigidBody3D` beside the hand (1 kg, now with gravity). Joints:
  the shoulder socket (body to upper arm; linear motors keep the upper arm's end at
  the static shoulder, 1500 N per axis; reaching past the arm's length it follows
  the hand up to 0.1 m), the elbow and the wrist (ball joints; the wrist is the
  `HandDrive` node itself), and the reach (body to hand; 6.6's linear drive, below).
  Upper arm and forearm have fixed weight (centre halfway, rod inertia); their
  shapes are BodyParts' (the forearm's stops 5 cm short of the wrist, raised flush
  with the palm's face every tick).
- **Joint torques** (`ArmDynamics`, a RefCounted used by `HandDrive`): each joint
  servoes its relative spin toward the pose (target spin plus 8 /s of the error, at
  most 6 rad/s, reached over 0.04 s); the torques that give the chain those
  accelerations come from its rigid-body dynamics (tau = M a, joint by joint, with
  centripetal terms; the engine adds no gyroscopic torque, checked 2026-09-26) plus
  the torque holding up everything beyond each joint. Each joint's torque is
  limited by its strength lifting what lies beyond it (60, 55, 12 N·m) or pressing
  it down (120, 55, 12 N·m), weaker while shortening fast and up to 40 % stronger
  while overpowered, never more than stops it. Holding comes first; the shoulder
  and elbow share what they have left for the servo, and the wrist takes its own.
  The hand also turns toward its target's rotation with 200 N·m/rad from 0.5° off
  (damped 1.5 N·m·s/rad), within the wrist's strength; the hand turns with at least
  0.02 kg·m² so that stays steady at 72 Hz.
- **Pose**: shoulder from the static skeleton; wrist where the controller puts the
  hand; elbow solved between them toward the static elbow. Upper arm and forearm lie
  in the bend's plane; the hand turns at the wrist. While the hand presses on
  something the arm is posed for where the hand is (at most 2 cm on).
- **Range**: elbow 0 to 150° with 10° of play; wrist 130° any way, 150° of twist
  either way from palm-in, thumb-up. Jolt's two swing limits make one cone as wide as
  the wider, so the elbow's bend is on the twist axis; Godot's limits bound the
  first body relative to the second, so they are given negated (both checked
  2026-09-26).
- **Reach** (6.6's linear drive, reinstated): velocity target as before (15 /s, at
  most 6 m/s), force limit base 20 N + 2000 N/m + 550 N·s/m of opening, now capped by
  what the arm's joints could add at the wrist in that direction on top of what they
  already give (`ArmDynamics.reach_strength()`; the cap falls over 0.15 s, rises at
  once), or 600 N while pressed on the level (the level, or a frozen body). The held
  object's weight is the reach's to carry; the carrying allowance and the wrist's
  steadying of 6.6 are gone.
- **Body**: the arms' weight bears on the body (the legs hold it up slopes and lift
  it up steps; a jump launches it); their own swinging, and a held object's, is given
  back to the body each step, so it does not push the body about; the rig carrier
  counts the whole player's momentum when it looks for what the world stopped.
- **Grip failure** (6.7): let go when held far off target only while the arm or what
  it holds presses on the level; the hand's own recovery likewise.

Rejected on the way (scratch tests and harness, 2026-09-26; details in Progress):
the engine's joint motors (needed 30 or more solver steps, still jittered under
5 kg); each joint driven alone (whipped apart under load); pushing the hand only
through joint torques (too soft against contacts at 72 Hz, and could not lift the
body in the vault's pose even at 250 and 150 N·m).

#### 6.6.2 Arm strength (built 2026-09-26, revised the same day; decided with the player)

The arm is posed, not simulated: the pre-arm build (rung 5: one physical palm-box
hand per side on 6.6's linear drive and wrist torque, arm shapes posed by BodyParts)
plus a simulated strength model that decides where the hand may be. Decided
2026-09-26: "A sounds like our move forward. Go ahead and drop the jointed arm
segments. Start at human strength. I guess we should do weight from a simulated
strength model." Revised after the first headset session (Progress): a load
**strains the arm but never makes it give way** (the player's choice), and the
model was cut down rather than added to ("Do not patch up with more and more layers
of systems and solvers. Revise the current and rebuild from that").

- **ArmStrength** (`scripts/physical/arm_strength.gd`, one per HandDrive) turns the
  static skeleton's hand (the drive's `tracked_target`) into the drive's `target`
  each tick. Only what the hand holds costs strength: with nothing held the tracked
  hand passes through untouched (letting go included), so the empty arm is the
  pre-arm build exactly.
  - Dip: the shoulder and the wrist hold the borne weight with a torque (weight
    times horizontal lever) and bend toward hanging by that torque over their
    stiffness (600 and 100 N·m/rad): the hand about the wrist, then the arm about
    the shoulder. No joint gives way. The elbow is not modelled.
  - Lag: a follower chases the dipped pose, reaching it this tick while the joints
    can supply the acceleration on top of holding, otherwise as fast as they can,
    braking with eccentric strength (1.4x) so it never swings past. Holding takes
    at most 80 % of a joint's strength, so an overloaded arm still moves, slowly;
    a load heavier than a joint can hold in its pose is never raised.
  - Strength, human (a strong adult's, roughly): shoulder 80, wrist 15 N·m
    (HandDrive "Arm strength"). The player's tuning since 2026-09-27: wrist 120 N·m
    on both hands in `physical_dynamic.tscn` (the script's default stays 15).
- **HandDrive** drives the hand to the shaped target with 6.6's drive. Carrying,
  the linear drive also gets, per axis, the force the commanded motion needs (the
  hand and the borne load accelerating, the load held up). Carrying with neither
  the hand nor the load touching anything: the effort damping adds force whether
  the gap opens or closes (it otherwise lowers the force while the gap closes,
  which left a swung load unable to stop), and the wrist has its full torque plus
  what its target's own turning needs (its limit otherwise grows only with the
  angle). An empty or touching hand keeps rung 3's drive unchanged.
- **Borne weight**: a held object's weight counts only while it touches nothing
  (HandGrab watches its contacts while held); it fades onto and off the arm over
  0.1 s as it leaves or meets a support.
- **BodyParts** bends the posed elbow toward the drive's `elbow_pole()`: the static
  elbow, or on a straight arm the way the static skeleton bends it (its
  `left_elbow_pole`, `right_elbow_pole`).
- **Telemetry**: the snapshot's `hand_tracked`, `arm_sag` and `arm_holding`
  (shoulder, wrist); recorder columns `*_command_gap`, `*_sag` (degrees),
  `*_holding` (N·m); `hand_force` is the drive's whole limit.

Not built: an in-session strength preset toggle (the debug layer never writes to the
player), the arm's strength for a load two hands share (while both hands hold one
object it carries nothing and each hand drives to the shared target, 6.7), feeding the
held body its own force, and the static skeleton's over-reach rule for the posed arm
(tried: it made fingers on a box corner twitch).

#### 6.6.3 Climbing (built 2026-09-28, step 1; decided with the player)

Decided with the player 2026-09-28: designated holds only (a `Climbable` on a
`StaticBody3D`); the grip takes a hold as it takes an object, but the hand goes to the
hold; one hand can hang and haul slowly, two haul fast, so weight shows as haul speed,
and only while holding a hold (pushing, props and empty hands unchanged); a
pure-physics throw (the body keeps the speed the pull gave it); the legs tucking up
and mantling are step 2, after the headset test.

While its hand holds a hold, a drive climbs (`HandDrive.climbing`, `_hang`): the hand
stays put and the drive moves the body the opposite way to how the player's hand has
moved since the hand locked there. `HandGrab` sets `climb_offset` every tick: the
player's hand, less where it was relative to the hand at the lock, less the hand's
point on the hold; with both hands on holds, the mean of the two, so both drives chase
one target and never pull against each other. The motor's velocity target is
`rate + follow_gain · offset`, the second term limited to `max_follow_speed` (15 /s,
6 m/s), less the body's velocity, as for a free hand; `rate` is how fast the offset
changed since the last tick (nothing on the tick climbing starts or the number of
climbing hands changes). Its force limit per axis is `climb_strength` (1,200 N, about
1.6 times the body's weight; 950 N until the 2026-09-30 headset session, when one-handed
climbing felt a little slow, decided with the player); upward it falls linearly to
nothing as the body rises at `haul_speed` (2 m/s) against the hand, and grows up to
`lowering_share` (1.3) times as it sinks. A force-velocity rule: one arm hangs without
sagging and hauls at `haul_speed` × (1 − weight / strength), about 0.77 m/s (0.45 at
950 N), two at about 1.39 m/s (1.23); one arm stops the body sinking at 11 m/s² (6.7). The arms never push the body down (**revised
2026-09-28** after the headset session): raising the hand lowers the body only as
gravity takes it, held back to at most `lowering_speed` (2 m/s); the motor's
vertical target is never below the body's velocity plus this tick's gravity, nor
below 2 m/s down. Pushed down with the whole strength as well, a hand raised fast
flung the body down at 6 m/s, and one arm, which brakes with only its strength less
the body's weight (1,235 N against 735 N, 6.6 m/s²), overshot the hand by 1.5 m to
the floor. No reach limit (the hand is on the hold), no arm strength (6.6.2), no
turning (the hand is held), no stuck-hand recovery.

The hand is frozen while it holds (kinematic, from the lock until it lets go): through
a free 1 kg hand welded to the hold, Jolt's iterations passed so little of the arm's
motor to the 75 kg body that it hung 3.1 cm low from two hands (the motor's target,
0.46 m/s, never met) and about 7 cm from one. Frozen, the hand is part of the world, the
motor pushes the body against it directly, and the body hangs within 0.1 mm.

Harness (simulated, 72 Hz, 2026-09-28; the hands take Hold1 by its front, palms to the
wall, since its top at 2.05 m is beyond the simulated 1.70 m player's reach): hands
snapped onto the hold and locked as the grip closes (2 ticks after the rig's grip),
also when gripping on the way past it at 0.7 m/s (before the snap, 1.1 s), the body
still meanwhile; hauled 0.8 m up by one hand and the hand raised 0.4 m in 0.15 s, the
body sinks at 2.00 m/s at most, never faster than it falls (before: 3.5 m/s, 26 m/s²
down), stops 0.18 m past the hand and is hauled back to it; both hands lowered
0.3 m lift the body 0.300 m and it hangs within 0.1 mm; pulled down 0.6 m fast with
both, it rises at 1.23 m/s at most and catches up (0.600 m); one hand 0.4 m, 0.45 m/s
(0.400 m); one hand with a 2 kg box in the other, 0.41 m/s; hanging by one hand while
the other lets go and swings round, still; a throw let go mid-pull flies free at
1.29 m/s (1.21 from the pull; inference: the other 0.09 m/s from the two freed hands'
drives pulling them toward the controllers 0.32 m below at their 600 N limit on the
release tick) and rises 8.3-8.5 cm, its ballistic height; both controllers lost, the body
stays held and the hands let go after 1.04 s (1 s and the rig's 3-tick delay). **The
throw is bounded by `haul_speed`: at these values a two-handed throw leaves at about
1.2-1.3 m/s, 7-9 cm of flight up. It is the value to raise in the headset.**

Not built: holds on moving bodies (freezing the hand assumes a static hold), the legs
tucking up and mantling (step 2), a hand sliding along a hold, stamina.

### 6.7 Interaction (Established structure)

| Action | Mechanism |
| --- | --- |
| Grab detection | **built 2026-09-25** (`HandGrab`, one per hand): the hand's grab point is fixed 5 mm inside the palm's face (since 2026-09-27, toward the knuckles from its centre, `grab_forward`, at the player's request: grabbing at the palm's centre felt off; 2.5 cm, then 3.5 cm as the player set it); every tick while the hand holds nothing, a ball (radius 0.08 m, centred 0.03 m out from the palm) is searched on the Grabbable layer; the body whose surface comes closest to the hand's grab point is the candidate, and that closest surface point its grab point (exact for boxes, spheres, capsules and cylinders; a small ball cast toward the shape otherwise, or, from inside the shape, the nearest point of its surface: **fixed 2026-10-02** at the player's request, since Jolt's cast does not see a shape it starts in and came back with the shape's centre, so a hand reaching into an ore the other hand held took hold of its centre, inside it). It follows the hand until the grip squeezes past 0.7. Since 2026-09-27 the search also takes the Held layer, so a hand finds an object the other hand holds (`Grabbable.open_to`: nobody holds it, or one other hand holds it; until the handle grab, also no hand that let go of it still clearing it) |
| Seat and hold a prop | **built 2026-09-25, seat since 2026-10-02** (at the player's request: "the transition should be static, not dynamic. regardless of the players hand positions, the transition should be the same"): over `seat_time` (0.08 s, eased out, 1 - (1 - s)³; locked on the 6th tick at 72 Hz) the object's grab point moves straight onto the hand's in the hand's own space, keeping its rotation relative to the hand (a handle turns into its seat, about its grab point). Meanwhile it is frozen (kinematic) on the Seating layer, meeting nothing, its weight not on the hand, placed each tick at the hand's pose as the last step left it (Godot draws a body there until the next step, so it is drawn with the hand; a prediction would put it a tick ahead). The last tick unfreezes it in its exact seat, gives it the hand's velocity and welds it: the joint is rigid (**revised 2026-09-26**: held by motors, a 10 kg box swung fast lagged 0.33 m and dropped). Every object seats the same way whatever it weighs (decided with the player 2026-10-02: a 40 kg box comes up into the hand, and its weight then takes the hand down). Seated inside something (a pommel in the table, a prop in the blade's way), it stays on Seating until none of its shapes overlaps what Held meets, then goes onto Held. Before the seat, a joint's linear motors pulled it in (20 /s, at most 3 m/s and 400 N per axis), and it locked within 5 mm. While holding, the hand drive carries it (6.6, carrying). On the Held layer, which the body, hands and legs do not meet, the hold never fights the palm's or fingers' contacts and the prop cannot push the player; the fingers' checks include Held and Seating, so they close onto it. Weight and inertia are real once held: the hand carries it within its drive's strength |
| Hold the world | **built 2026-09-28** (climbing, step 1): a `Climbable` component (`scripts/props/climbable.gd`) on a `StaticBody3D` makes it a hold: it adds the ClimbHold layer to the body's Static layer. The grab search takes ClimbHold too, and a hold is ranked with props by its closest surface. A hold cannot move and there is nothing to pull in: the tick the grip closes, the hand, as it is turned, snaps so that its grab point is on the hold's (the search bounds it to 11 cm; in the headset session the grips closed 0.4-3.6 cm off), and it is welded there and frozen, and its drive climbs (6.6.3). (**Revised 2026-09-28** after the headset session: pulled in like an object, a hand the player kept moving was drawn off the hold by its own drive, 600 N, faster than the grip's pull, 400 N per axis, brought it in; 4 of 21 grabs never locked, and twice the player fell when the other hand let go.) None of the object's handling applies (the Held layer, carrying, two-handed holds, handle seats); each hand holds its own hold, and both may hold one. It lets go when the grip opens, when the controller has been untracked for 1 s (the body stays held meanwhile), when the arm is held past its reach by 0.25 m (`hold_tear_reach`, from the static skeleton's shoulder; replaces the 0.4 m separation rule for holds) for 0.25 s, or before a recentre or respawn; never by moving the hand. The level's four red boxes on the wall are `Holds/Hold1`-`Hold4` |
| Two hands on one prop | **built 2026-09-27**, decided with the player: both hands hold a point of the object and it points along the line between them. The first hand to grab leads; the second joins the hold from the moment it grips (revised 2026-09-27 after the headset, decided with the player: pulled in, it fought the lead's grip and twitched): nothing pulls, both drives switch to the shared target at once, the object and the lead move into the two-handed pose, and the second hand rides the object onto its grab point; there it holds a point of it at its hand's centre (a `Generic6DOFJoint3D`, linear axes locked, rotation free); the lead's grip is remade to hold a point at its centre and the object's roll about the line to the other hand (rotation locked about the joint's X, along that line; free about the other two). Both drives then chase one shared target (`HandGrab._share_target`): the middle of the player's two hands, turned so its X runs along the line between them, rolled about that line by the mean of the two wrists' roll since the hold began (each wrist's twist about the line, averaged on the circle); each hand where it held the object in it. When the hold begins the object is seated with the line between its grab points on the line between the player's hands, its middle on theirs, keeping its roll. With the player's hands moving together the physical hands follow them; moved apart, they go to the mean, and the drives do not pull against each other through the object (fixed grips chasing separate controllers wobbled at 10 Hz or buzzed at 36 Hz in scratch tests); only a target beyond its arm's reach is moved alone. Meanwhile each drive has every axis's full force, headroom for its share of the weight by the lever rule (the sword's hand by the guard carries 2.5 times its weight, the other pushes down with 1.5 times), and the arm's strength carries nothing. Either hand letting go leaves the other holding it rigidly as it is (a hand still coming onto it seats it as a first hand does), with the whole load on its arm from that tick. A hand switching between its own target and the shared one (the hold beginning, the other hand letting go) is not asked to move at the jump's speed: its drive closes the jump as it closes any gap. Hands whose centres, as they hold it, are closer than 5 cm do not aim: the lead holds it rigidly, the other a point, carrying nothing; both still drive to the shared target, turned by the mean of the two wrists' turns |
| Free hand on a held prop | **built 2026-10-03**, at the player's request ("the hand not holding the object should also collide with and interact with the held object"; weapons in both hands meet too): a held prop meets the hands and other held props (6.8), but never the hands holding it, each a collision exception from its grab until clear after letting go. The other hand blocks, pushes, rests on or under it and is pushed by it, each as its drive allows, the push carried into the holding hand through the weld. The other hand and what it holds are no support (`HandGrab._pressed`): counted, a resting palm took the weight off the holding arm and switched its drive to giving way, and the two drives shook the prop. Harness: see Progress, rung 8. |
| Grab by a handle | **built 2026-09-27**, at the player's request: a `Grabbable`'s `handles` (box, capsule or cylinder shapes, each along its own Y; the weapons' `Grip` boxes) are held one way. A hand beside a handle (its palm's grab point level with it, not beyond either end) takes the nearest of four seats: the handle along the fist's grip (hand Y, leaned toward the fingers by the object's `Grabbable.handle_lean`: 15° on the sword and longsword, decided with the player 2026-09-28), toward the thumb or the little finger ("straight up or down"), the palm on either side across the shape's Z; its side on the palm's grab point; where the palm meets it along the handle but with the palm wholly on it, and a palm's width from the other hand if that holds the same handle (as far as the handle allows). A hand beyond an end cannot hold it there; the rest of the object is still grabbed as it is met. The seat turns the object into it on the way in (since 2026-10-02; before, a script torque of at most 10 N·m turned it, and it locked within 5 mm and 2° of its seat once settled, in 0.15-0.71 s). A second hand rides the object onto its seat in that hand, and is on it once within 5 mm and 2° of it and spinning under 0.7 rad/s against it (`settled_spin`), or, riding longer than 0.25 s (`slip_time`; with the wrist moving on, the turn may never settle), as it passes within 5 mm and 2°. Not joint angular motors: in a scratch test (Godot 4.7.2, Jolt) with the angular limits free they did not track their targets on two of three axes |
| Release | **built 2026-09-25**: when the grip opens past 0.3, free the joint (since 2026-09-30 at once, and the prop thrown, below) and gets its layers back once no part of the hand overlaps it, or after 1 s. Since 2026-09-27 `Grabbable` keeps the prop's own layers: it gives them back once no hand holds it and every hand that let go is clear of it; since the handle grab, clear by 1 cm (`restore_clearance`): a sword let go from a turned fist got them back just clear of the palm, landed on the still-curled fingers and spun away at 7.5 rad/s. Meanwhile either hand may grab it again (before, not until its layers were back; with the hand kept by a set-down weapon, that is up to 1 s) |
| Throw | **built 2026-09-30** (decided with the player: "use the brief history of the objects velocity", read by a curve fit): while a hand holds a prop it records the prop's centre of mass and spin each tick (`ThrowHistory`, `scripts/physical/throw_history.gd`); let go by the last hand holding it, the prop leaves with the velocity at the release of a quadratic least-squares fit through its places over the last `throw_window` (0.06 s, 5 ticks at 72 Hz), and the spin of a straight-line fit through its spins. A fit keeps up with a throw still speeding up and turning, where averaging lags it: on the harness's overhand throw of the 2 kg box (the player's hand at 6.5 m/s turning 9° a tick), the box's own velocity at the release was 5.2 m/s and 4.4° off the hand's way, a 5-tick average 4.5 m/s and 14° off, fits over 0.1/0.07/0.06/0.05 s 9.6/4.4/2.1/0.2° off (late release 4.5/0.3/1.3/2.5°). The prop is read as it is on the tick the grip opens (recorded before the release check), the grip's joint leaves at once (queued for the frame's end it held the prop through one more step), snap turns turn the history, a recentre clears it. Weight still shows: the prop is read from its own motion, which lags the hand by the arm's strength. Recorder columns `*_throw_speed`, `*_throw_off` (degrees off the player's hand) |
| Grip failure | **built 2026-09-25, revised 2026-09-26**: let go when a second hand coming onto the object stays more than 0.12 m from its grab point for 0.25 s (a seating object cannot be caught, since 2026-10-02), when a holding hand is kept more than 0.4 m from its target for 0.25 s (what it holds is stuck; before the hand drive's own recovery would move it; the target is the strength-shaped one, 6.6.2, so a sagging or lagging load is not "stuck"), or when the controller has been untracked for 1 s |
| Strike (blunt, report only) | **built 2026-09-30** (the strike model, `documents/strike_model.md`; decided with the player: "all physical objects should deliver blunt damage if thrown or used to hit something. Even fists", a readout only). A `Striker` on every physical object that can hit (the weapons, the level's boxes, both hands) reads its body's contacts after each step. A pair strikes on the tick its contact closes (a gap no more than the distance closed during the step, plus 1 mm, so Jolt's look-ahead contacts do not count), at 0.5 m/s or more, then not again until it has come apart (and 0.1 s has passed). Energy is ½ · m_eff · v², the closing speed taken at the middle of the touching contacts, before the impact, and m_eff the mass met there along the normal by the object and the hands holding it. The struck body's `Strikeable` judges damage by its material (`StrikeMaterial`: cloth, wood, stone), totals it and shows it (`StrikeReadout`). `HandStrikes` counts a strike for a hand when the hand made it, held what made it, or was last to let go of it within 2 s. Since 2026-10-01 a strike has a damage type, two since 2026-10-02: a slash if one of the striker's `Sharp` parts dealt it (an edge: blade edges, the axe's bit, the pickaxe's adze; or a point: blade points, the pickaxe's pick), landing within its reach while it leads the blow (an edge within 50°, a point within 35°), and blunt otherwise. The material decides whether it takes that type (stone: blunt only). Decided with the player: damage types only. Since 2026-10-02 each hand holding the striker buzzes, stronger for a harder strike (`HandHaptics`). Nothing moves differently: no forces, joints or exceptions |
| GUI poke | `Poke` `Area3D` on the index finger, mask Interface; emits `interface_pressed(target)` |

Props on the Dynamic layer also collide with the body (75 kg capsule shoves a 2 kg
cube), the hands, fingers and forearms, and the neck and head on `PropsOnlyParts`
(the legs pass through them since 2026-10-03), as long as each prop's own mask includes Player and Hands (6.8). A
`Grabbable` component (`scripts/props/grabbable.gd`) on a prop declares it grabbable:
it puts the body on the Grabbable layer and lets a hand find it (**decided
2026-09-25**: grabbing is opt-in); a bare `RigidBody3D` on Dynamic is only pushable.
Since rung 8.1 (2026-10-02) it also turns physics interpolation off for the body: the
avatar is posed on the physics tick, so an interpolated prop was drawn up to a tick's
motion behind the hand holding it (10-13 cm at a run).
The level's three boxes carry one, as do the sword and dagger on its table
(`scenes/props/`, 2026-09-27). A prop made of several shapes sets
`max_contacts_reported` to 4: Godot's Jolt turns contact-manifold reduction off only
for bodies that report contacts, and with it on such a prop settled up to the 5 mm
penetration slop into the table. Decided 2026-09-25 with the player: the pull is
physical (not an animation), and a grabbed object keeps its rotation relative to the
hand; revised 2026-09-27 at the player's request for handles, which turn into one of
their seats instead (the handle grab above); revised 2026-10-02 at the player's
request: the object comes into the hand by a fixed transition in the hand's space, the
seat, not a pull (above). The weapons' `Grip` boxes are their
handles; the sword's and the longsword's were cut back to where their pommels begin
(the sword's ran 1.75 cm into its pommel, whose collider then met a palm near that end
first; the longsword's 2.1 cm), the rest kept as `PommelCore` boxes so that the
colliders and mass properties are unchanged. Wanted later, not built: a hand sliding
along a held handle, fingertip pinch, force grab, and a throw policy.

### 6.8 Collision layers (Established)

| Bit | Name | Members | Mask |
| --- | --- | --- | --- |
| 1 | Static | level, hold bodies | none |
| 2 | Dynamic | loose props | 1, 2, 4, 5, 6, 9 |
| 3 | Grabbable | props with a `Grabbable` component (also on 2) | query tag |
| 4 | Held | a prop while held (off 2 and 3 meanwhile) | 1, 2, 4, 6, 9 (since 2026-10-03; the hands holding it are excepted) |
| 5 | Player | Body (capsule and body parts); PropsOnlyParts (mask 2 only) | 1, 2, 9 |
| 6 | Hands | LeftHand, RightHand (palm, fingers, forearm) | 1, 2 |
| 7 | Interface | GUI hit targets (Area3D) | queried by Poke |
| 8 | ClimbHold | bodies with a `Climbable` component (also on 1; built 2026-09-28) | query tag |
| 9 | Enemy | future | |
| 11 | Seating | a prop while a hand seats it, and until it is clear of what Held meets (off 4 meanwhile; built 2026-10-02) | none |

Found 2026-09-25 (Godot 4.7.2, Jolt): two bodies collide only when each one's mask
includes the other's layer. Not so for a frozen (kinematic) body (2026-10-02, harness):
on the Held layer with an empty mask, a seating sword still flung a prop whose mask has
Held 1 m, so the seat uses the Seating layer, which no mask has. Measured again 2026-10-03
(headless repro, then the harness): between dynamic bodies one mask is enough; a hand
(mask 1, 2) met a held prop once the prop's mask had Hands. The level's boxes were on Dynamic with mask Static and
Dynamic only, so the body, hands and legs passed through them while the ground sweep,
a query that ignores the box's mask, still stood the body on them. Their masks now
follow the table: 1, 2, 4, 5, 6, 9 (315). Every prop needs the same.

Queries: ground sweep 1, 2; `ground_probe` 1; step tests 1, 2; head sphere 1; grow
clearance 1, 2; grab 3, 4 (Held: an object the other hand holds), 11 (Seating: one it is seating) and 8
(holds); fingers 1, 2, 4, 11; poke 7. No self-collision: body never masks 6, hands never
mask 5 or 6, held never masks 5. Held masks 6 and 4 (2026-10-03, at the player's request):
the other hand, and what it holds, meet a held prop; the hands holding it never do, each
a collision exception of the prop from its grab until it is clear after letting go
(`Grabbable.hold()`, `clear_of()`; Jolt counts exceptions, so each is added once). CCD only on the hands (fast motion) unless a
tunnelling case is demonstrated elsewhere. Demonstrated for the weapons (2026-09-27,
headless): thrown tip-first at a 1 m CSG wall, which collides as a surface with
nothing solid behind it, the dagger passed through or stuck in 11 of 35 throws at
6-25 m/s (through from 6 m/s) and the sword 4 of 35; with CCD, none of the 70 did.
Both weapons have CCD. Jolt's CCD sweeps linear motion only; spinning throws
(10-40 rad/s) stopped with or without it.

The strike model (2026-09-30) adds no layers. Its posts (`Targets/ClothDummy`,
`WoodPost`, `StoneBlock`) are Static, mask none, like the level. A `Striker` reads the
contacts its own body reports, so the level's three boxes now report 4, as the weapons
already did. Jolt then stops merging their contacts (above): in the harness A/B only
`palm_push_box` moved, the box pushed 2.4 mm less over 0.18 m, and no check changed.

### 6.9 Recovery policies (Established structure; Decide details at the rung named)

| Situation | Policy | Rung |
| --- | --- | --- |
| Below the kill height | fade, `relocate` to spawn with zero velocity, drop grips | 2 |
| Head lead beyond 0.6 m for 0.5 s (walked through a wall) | fade to black, `relocate` the rig so the head is back over the body, fade in | 2 |
| Body wedged (no support, no motion, contacts on opposite sides) | shrink first; if still stuck, nudge up by the step height, else relocate | 3 |
| Hand separation beyond 0.5 m for 0.25 s | place the hand on its target with zero velocity, if the way from the body is clear of the level; otherwise keep pushing. Release grips (rung 5) | 4, built |
| Controller tracking lost | hold target body-local, soften drive to the base force; release grips after 1 s (rung 5) | 4, built |
| Head tracking lost | freeze carry and motor input; keep gravity | 2 |
| Held prop trapped | grip releases by the separation rule; no explosive recovery | 5 |
| Climbing (a hand on a hold) | no head-lead recentre while holding; a recentre or respawn lets go of the holds first; a hold is let go after 1 s untracked, or held 0.25 m past the arm's reach for 0.25 s (6.7) | 6, built 2026-09-28 |

### 6.10 Comfort policies (Decided at rung 2, 2026-09-25)

| Source of view motion | Policy |
| --- | --- |
| Real head motion | 1:1 always, by the XR runtime |
| Stick, run, jump, steps, falls | carried 1:1 with the body (as today) |
| Pushes and impacts on the body | carried 1:1; the levers are mass and `leg_force`. If headset testing shows discomfort, evaluate a per-tick carry cap with smooth catch-up before touching physics |
| A body part pressed into something (the chest on a table's edge while leaning over it) | the push on the body is carried 1:1 like any push, which takes the parts that follow the head back out. **Headset check** (built 2026-09-25) |
| Body stopped by furniture, head clear above it | the view is pushed back once the head leads the body's centre by more than the 0.35 m lean limit (6.4) |
| Head inside static geometry | fade from 0 at contact (a 6 cm ball around the eyes, since 2026-09-25) to black at 0.1 m depth; recenter per 6.9. Chosen over the old 1:1 pull-back after the rung 2 session: the player found it more comfortable and the timing right |
| Standing up after a mantle (legs drawn up while climbing, 6.5) | the view rises with the body by as much as the legs had drawn up (about 0.8 m), at up to 1 m/s, easing to rest (**decided with the player 2026-09-28**; **headset check**) |
| Turning | snap, 45° per push of the right stick, about the head's centre (the eyes swing 7.7 cm round it, as a real head's do) (**built 2026-09-30**; **headset check**); smooth turning not built; never a torque on the body |

No system ever rotates the camera. The physical body does not become the camera's
authority; the rig follows its translation only.

## 7. Skeletal layer (Established structure; built at rung 7.1, 2026-10-02)

The character model is `Body1`, the player's mannequin from `craftables.blend`
(adventurer-vr): 54 bones named as Godot's humanoid profile, an A-pose, every vertex
weighted to one bone (two at the finger splits), 28 flat-coloured materials. It is
fitted to the static skeleton's proportions in Blender before export, so at rest it
stands as the static skeleton does, eyes at 1.68 m:

- `tools/blender/fit_player_proportions.py`, run in the player's Blender session, copies
  `Body1_Rig`/`Body1` to `Body1_Fit_Rig`/`Body1_Fit`, straightens the copy's fingers (modelled
  curled), turns its inside-out right side outward, and moves its joints to the static
  skeleton's standing pose (its constants are copied there with their source).
  Each part goes with its bone, lengthened or shortened along it, never thickened.
  Body1's A-pose directions, depths and the shapes of its head, hands and feet stay.
  The player then tweaks the copy by hand and saves.
- `tools/blender/export_player.py` (headless) writes `assets/models/player/body1.glb`:
  Subdivision applied at level 1 (35,904 triangles, faceted as modelled), back-face
  culling on, life size, no animation.

`Visual/PoseMapper` (`scripts/visual/pose_mapper.gd`, physics priority -60) poses it every
tick from the snapshot, where the **physical** body is: the player chose to attach the
model to the physical player, and since rung 5 the physical lower body stands at the
capsule, not under the head. `BodyParts` publishes the joints it already solves
(`PoseSnapshot.body_joints`, `body_soles`): neck and shoulders with the head; elbows and
wrists on the physical arms; hip sockets, knees, ankles and soles where the physical body
stands. Two kinds of bone:

- A **segment** (hips, spine, chest, neck, upper and lower arms and legs) runs between
  two joints, stretched or shortened along its length to reach, turned about its length
  toward a reference:
  - torso and neck: the static torso's and neck's facing;
  - upper arm: the way the elbow sticks out between its two bones; on an arm too straight
    or folded to tell (`HINGE_BIAS`, about 6°), the way it last faced, kept in the torso's
    frame so it turns with the body (the drive's elbow pole jumps as an arm straightens: a
    93° twist in one tick with the arm still);
  - forearm: the hand's thumb side;
  - thigh and shin: the way the knee bends, forward only (bent the other way, as the
    physical legs fold when drawn up, it keeps its front in front rather than turning the
    leg round), and on a leg too straight or folded to tell, a quarter turn forward of
    each bone about the hips' left-right axis (a standing leg's front forward, a raised
    thigh's up, a shin folded back under it down). Not the static knee pole: taken from
    the foot, it swung 49° in one tick round a straight trailing leg.
- A **rigid** bone keeps its shape on a frame: head and eyes on the headset (the model's
  eye midpoint on the player's eyes), collarbones on the torso with their outer ends on
  the shoulder sockets, each hand on its physical hand (wrist on the physical wrist,
  middle finger's root where the static hand has it), each foot on its physical sole
  (its ankle Body1's own height above it, 0.11 m), toes with the foot. Each finger bone
  keeps the model's length and points along its physical finger bone, so the fingers
  curl as far as the physical fingers do and stop where they stop.

The rest pose is measured against the same frames once, so each bone keeps its rest
relation to them. Every bone is made parentless at load, each keeping where it stood:
a skeleton's bone poses hold no skew, so a stretched parent would distort its children
(checked headless: the skinned mesh moves 4e-7 m, and a stretched bone moves only its own
vertices). The model shows a blocked hand where the physical hand is, and nothing here
writes into physics. Its head and neck are drawn only in reflections (since 2026-10-03,
at the player's request): at load `Visual/MirrorOnlyParts` moves the surfaces skinned only
to the head, the eyes and the neck to a copy of the model's mesh instance (same skin and
skeleton) on render layer 3 (`RenderLayers.MIRROR_ONLY`), which `PlayerRig` leaves out of
the headset camera and the mirror's cameras draw. Until then the head was drawn in first
person, the camera inside it, the inside unseen through back-face culling.

Since 2026-09-30 the physical layer also tells the static skeleton of a snap turn
(`turn()`): its feet, chest facing and pelvis memory turn with the rig, so the avatar
turns at once.

The static skeleton takes one more input from the physical layer since 2026-09-28,
`leg_tuck` (the body's tuck, 6.1): while it is above zero the feet hang no lower than
that above the floor, grounded or not, the knees bending up in front, and when it is
zero again they come down where they are, as on landing.

`PhysicalDebug`, the physical layer drawn from the snapshot (2026-09-27, at the player's
request), stays in the slot under the model, hidden until B shows it (section 8). It
shows the body's capsule (faint; its axis is 10 cm behind the eyes, so they sit about
2 cm above its rounded top and, looking down, see a thin band of it 5 to 8 cm away), the
palms (white, red under full drive), the finger capsules, the body parts (blue) and the
grab points, each shape where the engine has it and as big (the `skeleton_toggle`
scenario checks all 49). Its meshes are unshaded and cast no shadows; the mirror shows
them too. It skips its work while hidden.

## 8. GUI layer (Established structure)

`Interface/Anchors` copies from the snapshot each tick: `wrist_left`, `wrist_right`
(physical hands), `chest` (static torso), `belt` (static hips), `head` (fade only).
Displays are child scenes of anchors. Every control has its own `Area3D` on the
Interface layer; presses arrive from `Physical.interface_pressed`, never from bones.
`Interface` emits `action_requested(action, payload)` and `player.gd` routes it.
Displays read gameplay state from an injected `PlayerState` reference, not a global.

Built so far: `ViewFade` (6.9), `HandHaptics` (a buzz when a physical hand starts
touching; since 2026-10-02 also when something it holds strikes, in each holding hand:
amplitude √(energy / 100 J), at least 0.15, for 0.06 s), and `SkeletonToggle` (2026-09-27): the right controller's B (`by_button`)
shows or hides the debug drawings over the character model, together: the static
skeleton's, `SkeletonDebug`, which `PlayerRig` names as `skeleton_view`, and the physical
layer's, `PhysicalDebug` (`Player.physical_view`, since 2026-10-02). Only the drawings are
switched; the layers keep solving. They start hidden (until 2026-10-02 B hid only the
static skeleton, which started shown) and this is not remembered between runs.

## 9. Debug and test attachment (Established)

- `Debug` scene (`scenes/player/debug.tscn`, `PlayerDebug`), added by `Player` only
  for `-- --player-debug`, `-- --record-baseline`, `-- --record-session`, the
  `debug_always` export, or a
  harness calling `enable_debug()`. It holds the `Readout` (the former rig Label3D,
  placed above the left controller each frame), a `LocomotionRecorder` (per-tick
  measurements; CSV while recording), and, for `--record-baseline`, the guided session
  driven by `BaselineChecklist`: recording starts once the headset is tracked,
  instructions show above the left hand and tick themselves off with a buzz, and the
  game quits when done. Normal play records nothing. Gameplay code has no reference
  to any of it. From rung 2 the recorder reads the snapshot instead of the body. The
  physical layer's drawing, `PhysicalDebug`, left it for the player's Visual slot on
  2026-09-27 (section 7).
- `tests/harness/simulated_rig.gd` registers trackers named `head`, `left_hand`,
  `right_hand` with `XRServer` and sets `primary`, `grip`, `trigger`, and the right
  controller's `ax_button` (A) and `by_button` (B), so the unchanged rig nodes follow
  it. `tests/harness/run_scenarios.gd` runs the scenarios on fresh copies
  of the level, writes a CSV per scenario and `results.json` under
  `user://baselines/simulated/<time>/`, and exits 0 only if three checks pass:
  ACCEPTANCE (the current rung's criteria for the dynamic body, each with a stated
  tolerance, beside a printed comparison with the kinematic reference) or, with
  `--reference=`, REFERENCE (every measurement within 1 %, or 0.001 in its unit, of
  that file, e.g. `tests/harness/reference/kinematic_baseline.json` run with
  `--player=res://scenes/player/player_kinematic.tscn`); CHECKLIST (the guided
  checklist recognises every item of the guided session in the recordings); and
  GUIDED (a guided session starts recording and shows its first item). The runner
  also samples the view fade's darkness, so a fade where none belongs fails. Since
  2026-09-28 the scenarios keep the numbers of the arena they were written in and find
  the level's features by name (`ARENA`, `_feature_pose`): each names one ("at") and
  runs with the level turned and moved along the floor so that feature lies where it
  was. The names are the `Static` pieces `Floor`, `Table`, `Step1`-`Step3`, `Wall`,
  `Ramp15`, `PitHole`, `PitFloor`, `PitRamp`, the `Dynamic` boxes and weapons, the
  climbing holds `Holds/Hold1`-`Hold4` (since 2026-09-28; the scenarios use Hold1 and
  Hold4), the `Notch` cut into the Wall's top and the `Platform` behind it (renamed by
  Claude in the editor, 2026-09-28), and the markers `OpenFloor` (where standing scenarios start, facing its -Z) and `OpenLane`
  (a 9.2 m straight walk ending 0.1 m from the level's edge, along its -Z).
  Since 2026-09-30 the struck posts (`TARGETS`: `Targets/ClothDummy`, `WoodPost`,
  `StoneBlock`) are taken out of each scenario's level like the weapons, unless it keeps
  them (`"targets"`). A scenario may put kept nodes where it wants them, in its own
  frame (`"place"`), and the strikes on kept posts go into its results (`"strikes"`).
  `tests/harness/analysis.gd` measures simulated
  and headset recordings with the same code; `tests/harness/analyze_session.gd`
  reports a headset session item by item.

```sh
# All scenarios and checks (options: --level=, --player=, --reference=, --write-reference,
# --no-comparison; bare names limit the scenarios)
godot --headless --xr-mode off --fixed-fps 72 --path . -s tests/harness/run_scenarios.gd
# Guided headset session (WiVRn connected), then its analysis
godot --path . -- --record-baseline
godot --headless --xr-mode off --path . -s tests/harness/analyze_session.gd
```

  `--write-reference` replaces the reference; use it only after a deliberate level or
  body change, once the change is understood.
- Scenarios: the eleven baseline cases (stand, flat full, flat half, steps up and down,
  ramps, drop, head into wall, crouch, run moderate and hard) from rung 1, then hand
  into wall, push cube, grab and throw, climb ledge as the rungs add them.
- Simulated and headset results are always labelled separately. Desktop WiVRn sessions
  are not Quest 3S numbers.

## 10. Migration ladder (Established sequence; one rung at a time)

Each rung is built, checked headlessly, then tested in one guided headset session before
the next starts. Nothing is committed or pushed unless asked.

| Rung | Build | Kept / retired | Headless check | Headset check | Decisions |
| --- | --- | --- | --- | --- | --- |
| 1 | Player scene with Rig, Physical, Visual, Interface slots and an on-demand Debug; the existing `PlayerBody` moved under `Physical` unchanged; recorder, guided session and harness rebuilt | everything kept; `Readout` moved to Debug | the eleven scenarios reproduce the simulated baseline (section 12) within 1 % | the ten-item guided session (drop optional), which also gives the kinematic body's first headset baseline | none |
| 2 | dynamic `Body`, `RigCarrier`, `GroundSense`, `Locomotion` with FollowHead, StickWalk, ArmPumpRun, AirControl, Crouch, Recovery (kill height, head-in-wall); explicit layers; `PoseSnapshot` | old `PlayerBody` kept as the comparison scene until rung 3 passes | speed, rise and stop times, ramps, wall, crouch against the baseline; no drift standing; Jolt joint and motor scratch checks | walk, lean into the wall, crouch, fall through the hole | lean allowance; head-in-wall policy; accept the heavier response |
| 3 | `StepAssist`, step-down, `Jump` | `_step_up` math retired in favour of the force-based assist | three steps up and down, no single-tick teleports, landing speeds | steps, hole, jump | lift method |
| 4 | hands, drives, contact events, `PhysicalDebug` separation readout | | hand into wall: bounded body displacement, no oscillation above 1 cm, no wind-up; angular sign | hand on wall and pedestal, no visible jitter | one-hand weight rule |
| 5 | `Interaction`: grab, hold, release, throw on the 2, 5 and 10 kg cubes | | grab and throw scenario; held 10 kg sag within limits | cubes | throw policy |
| 6 | `Turn`, world holds and climbing, remaining recovery | | climb ledge scenario | turn comfort, ledge | snap angle |
| 7 | `Visual` PoseMapper, `Interface` anchors and poke | | pose continuity | model, wrist display | |
| 8 | One physical system (decided 2026-10-02): 8.1 holding is solid; 8.2 load-aware legs; 8.3 the whole body meets the world | | held objects at a run; speed against load, pushing, slopes; overhangs, a caught hand | each sub-rung in its own session | see Progress, rung 8 |

Rung 5 was revised on 2026-09-25 at the player's request: the rest of the physical body
(6.6, body parts) is built first, and interaction (grab, hold, release, throw) follows.

Rung 2 carries this option's riskiest assumptions: carry-rule comfort, motor stability,
and the capsule's behaviour on CSG step edges. If they cannot be made comfortable, the
fallback in Appendix A replaces only `Body` and `RigCarrier`.

### Progress

- **Rung 1, built 2026-09-25; simulated checks pass; headset session pending.** On the
  level as it was when the baseline was recorded (commit d4f017d), the restructured
  player reproduced the reference run cell for cell: all 85,561 recorded values across
  the eleven scenarios were identical. The level was then adjusted (commit 2f0ed43
  mirrored the ramps and shrank the lower floor), so the two ramp scenarios were
  mirrored to match and the reference was re-recorded on the current level. Its
  headline numbers equal section 12. REFERENCE, CHECKLIST and GUIDED all pass, and two
  consecutive runs match.
- **Rung 1 headset session, 2026-09-25 16:24** (`headset_2026-09-25T16-24-37.csv`;
  Quest via WiVRn, game running on the desktop RTX 5090, so no timing here is a Quest 3S
  result). Player's report: it felt the same as before the restructure. Telemetry:
  - All ten guided items completed, including the drop, in 85 s of recording.
  - The runtime started at 120 Hz and accepted the 72 Hz request; physics followed and
    ran at 72 ticks/s for 84.9 s.
  - Full-stick walk 1.50 m/s, stopping in 0.07 s; hard arm-pump run 5.83 m/s at run
    factor 1.00. Both match the simulated baseline.
  - Step-up still lifts the body 0.10-0.12 m in a single tick (simulated: 0.13 m).
  - The head was held 0.2 m from the wall face while the rig was pulled back. The
    0.28 m of pull-back logged under the crouch item happened in its first 0.9 s at
    standing height, at the wall; by timestamps it was the wall lean continuing after
    that item ticked off, not the crouch. The crouch itself (head down to 0.73 m) had
    none.
  - Physics process time: slow ticks only in the first 2.2 s (startup, up to 41 ms);
    afterwards mean 0.77 ms, p99 1.29 ms, max 10.5 ms.
- **Rung 2, built 2026-09-25; simulated checks pass; headset session pending.** The
  level's player is now the dynamic body (`scenes/player/physical_dynamic.tscn`); the
  kinematic body stays as `scenes/player/player_kinematic.tscn` and still reproduces
  its reference exactly (526 measurements). Collision layer names 3 to 9 were added.
  All 13 acceptance scenarios pass, including a head walked 1.5 m into the wall
  (recentred once, view fully black first) and a walk off the level (respawned at the
  start, view fully black first); the view fade stayed clear in every other scenario.
  Simulated, dynamic body against the kinematic reference:

  | Scenario | Dynamic | Kinematic |
  | --- | --- | --- |
  | Full-stick walk | 1.50 m/s; 90 % in 0.26 s; stops in 0.40 s over 0.18 m | 1.50 m/s; 0.08 s; 0.07 s over 0.04 m |
  | Hard arm-pump run | 5.75 m/s held, 5.91 top; stops over 1.57 m | 5.84 m/s; stops over 0.68 m |
  | 15° ramps, down and up | 1.50 m/s along the slope both ways, never airborne | same |
  | Three 0.25 m steps | stops at the first riser (step assist is rung 3) | climbs, 0.13 m single-tick lifts |
  | Head 1 m into the wall | no rig pull-back; head 0.16 m into the wall, view black at the peak | rig pulled back 0.20 m, head held 0.2 m off the wall |
  | Crouch to 0.8 m | capsule shrinks to 0.80 m and grows back | capsule unchanged |
  | Floor hole | one fall, lands with a 17 mm rebound | one fall, no rebound |

  The walk timings are what a first-order motor with a 0.12 s response time predicts
  (90 % in about 0.28 s, coasting about 0.18 m), which the acceptance checks confirm;
  whether that weight feels right is the headset's question. Walking in the room at
  0.5 m/s, the head leads the body by about 0.28 m (lean allowance plus follow lag).
  Decisions for the headset session: lean allowance, the fade and recentre policy
  against the old pull-back, and the heavier walk and run. All three were settled by
  that session (see the decision record below).
- **Rung 2 headset session, 2026-09-25 17:08** (`headset_2026-09-25T17-08-18.csv`;
  Quest via WiVRn, game on the desktop, so no timing here is a Quest 3S result).
  Player's report: starting and stopping felt weighty and good; the view went dark
  with the head in the wall, the timing felt right, and it was more comfortable than
  the old pull-back; everything felt good. Telemetry, with inferences marked:
  - All eight guided items completed in 64 s of recording. No recentre or respawn
    fired, and recovery never blacked the view out.
  - WiVRn switched 72 to 90 to 120 and back to 72 Hz within 0.15 s near the start;
    physics followed each change and the body's motion stayed continuous. On the
    switch ticks the physics step and the reported delta disagreed for one tick,
    which shows up only as a one-tick glitch in recorded speed.
  - In the same tick as the first rate change, the reported head position jumped
    0.42 m; the body then walked under the head over about 2 s, and that catch-up
    was not carried into the view. The cause of the jump is not known from telemetry.
  - Full-stick walk 1.50 m/s, stopping in 0.40 s, as simulated. A second stop logged
    1.33 s because the body was still following real head movement (lead rising to
    0.13 m after release; inferred from the lead column).
  - The body reached the wall at about 1.7 m/s after a run-up and stopped at the wall
    face. The lean into the wall came after the wall item ticked off at 5 cm (the item
    boundary is when the instruction changed, not what the player did): the head went
    up to 0.36 m past the surface for about 1.2 s under the crouch item's label, which
    requests a fully black view. Whether it rendered black is not measured.
  - Crouch: the capsule followed the head down to 0.68 m.
  - Physics process time: slow ticks only between 0.5 and 1.5 s (startup, up to
    41 ms); afterwards mean 0.77 ms, p99 2.16 ms, max 2.16 ms.
- **Decision record, rung 2 (2026-09-25):** the heavier motor response is accepted
  (response time 0.12 s, leg force 900 N, air force 150 N); head in a wall fades and
  recentres instead of pulling the rig back; the lean allowance stays 0.15 m. Rung 2
  is complete. The kinematic comparison body stays until rung 3 passes.
- **Rung 3, built 2026-09-25; simulated checks pass; headset session pending.**
  Step assist, step-down and jump, as decided: smooth lift, A-button jump. All 15
  acceptance scenarios pass (two new: a standing and a walking jump), no lift fires
  outside the steps, and the kinematic comparison body still matches its reference.
  Simulated:

  | Scenario | Rung 3 dynamic body | Kinematic body |
  | --- | --- | --- |
  | Three 0.25 m steps up | top in 2.51 s; one 0.19 s lift per step; at most 0.022 m of rise per tick | top in 2.1 s; 0.13 m single-tick snap per step |
  | Back down | three controlled step-downs, never airborne; at most 0.023 m per tick | three 0.19 m drops, 0.11 s airborne each |
  | Jump, standing or walking | rises 0.38 m, 0.51 s in the air, lands at 2.24 m/s; walking speed kept | none |

  The jump peaks 0.02 m under its 0.4 m setting, as expected from the engine's
  per-tick integration. The guided session for this rung is steps up, steps down,
  jump, and the optional drop.
- **Rung 3 headset session, 2026-09-25 17:39** (`headset_2026-09-25T17-39-25.csv`;
  Quest via WiVRn, game on the desktop). Player's report: pending. Telemetry:
  - All four items completed in 24 s. The runtime started at 120 Hz and accepted 72 Hz
    within 0.2 s; physics followed. No recentre, respawn or head obstruction.
  - Steps up: three lifts of 0.18 to 0.19 s, each rising 0.21 to 0.22 m while lifting,
    at most 0.022 m in one tick, as simulated. One further lift began the tick after
    reaching the top and ended the next tick without moving the body; a false trigger
    to watch for, with no measured effect.
  - Steps down: three controlled step-downs of 0.13 to 0.14 s, never airborne.
  - Jump: one standing jump, 0.38 m high and 0.51 s in the air, as simulated. The item
    ticked off after that first jump, so no walking jump was recorded.
  - Physics process time after startup: mean 0.79 ms, max 1.25 ms.
  - Player's report: stepping up, stepping down and the jump all felt smooth. Two
    problems, both seen with the editor's Visible Collision Shapes on: large red
    diamond artifacts at collisions blocked the view at times, and the capsule was
    slow to follow the headset while walking in the room, ending up far enough off
    that it hit the table before the skeleton got there.
- **Fixes after the rung 3 session (2026-09-25):** the red diamonds are the collision
  debug view's contact points (`debug/shapes/collision/contact_color`, up to 10,000
  drawn); `debug/shapes/collision/max_contacts_displayed` is now 0, so debug runs still
  show the capsule but no contacts. Room-scale following was rewritten (section 6.4).
  A new `room_walk` scenario (real walking, no stick) checks it: lead at most 0.1 m,
  back under the head within 0.02 m, view drift at most 0.01 m; the wall scenario also
  checks drift. All 16 scenarios pass. Headset confirmation of the new following is
  pending.
- **Furniture push-back (2026-09-25):** reported in the headset: stepping into the
  table gave "weird movement" instead of being pushed back. Simulated, the head went
  out over the table with nothing stopping it, and an angled approach slid the view
  0.39 m as the capsule slid along the table's edge. Now a clear head is held to the
  lean limit and nothing but the push-back moves the view. New scenarios, all with the
  stick untouched: `table_straight` (pushed back 0.30 m, view moved 0.30 m),
  `table_oblique` (0.20 m and 0.20 m), and `slope_walk` on the 15° ramp (lead 0.06 m,
  view drift 1 mm). All 19 scenarios pass; the kinematic comparison body is unchanged.
  Headset confirmation pending.
- **Free-play headset session, 2026-09-25 18:01** (`free_2026-09-25T18-01-56.csv`,
  recorded with the new `-- --record-session`; collision shapes visible with
  `--debug-collisions`; desktop via WiVRn). Player's report: everything felt good
  (following, the table push-back, the wall). Rung 3 and its fixes are complete.
  Telemetry:
  - Room walking without the stick: head lead median 0.03 m, p95 0.14 m. Standing:
    median 0.01 m.
  - Two walks into the pedestal: the body stopped at its face both times, the head
    led by the 0.35 m lean limit, and the view was pushed back 0.12 m and 0.16 m.
  - Leaning into the big wall: the head went up to 0.71 m in for about 2 s, which
    recentred once with the view blacked out (lead over 0.6 m for 0.5 s).
  - At the start, as tracking began, the head was 0.35 m from where the body had
    been placed and the view was pushed back 0.09 m.
  - Physics process time after startup: mean 1.08 ms, max 3.16 ms.
- **Rung 4, built 2026-09-25; simulated checks pass; headset session pending.** Two
  physical hands on joint drives from the body, contact haptics, effort-coloured debug
  spheres, and the standing hold. Five new scenarios; all 24 pass:

  | Scenario | Result |
  | --- | --- |
  | Both hands tracing 0.15 m circles at 1 Hz | within 0.011 m of their targets; body moved 0.3 mm |
  | One hand pushed into the wall | stopped at the surface (0.045 m sphere at 3.955 m), no measurable shake; 230 N; body held within 1.2 cm |
  | Both hands pushed hard into the wall | the legs gave at 900 N together: body pushed back 6.2 cm, kept 1.7 cm after release; the view moved with it |
  | Right hand turned 90° about each axis | at most 1.1° behind, settling within 0.3° |
  | Right controller lost while walking | its hand stayed within 1 mm of its held place |

  Head-only scenarios (wall, recentre, tables) now run with the controllers
  untracked, so hands at the sides do not reach walls before the head. With hands
  held forward, walking the head into a wall lets the hands stop the body first; that
  is how it will feel in the headset. The guided session for this rung is: press a
  hand on the table, then push the wall hard with both hands.
- **Rung 4 headset session, 2026-09-25 18:23** (`headset_2026-09-25T18-23-23.csv`;
  desktop via WiVRn, collision shapes visible). Player's report: the table felt fine.
  Pushing the wall had a threshold: past it "the hands auto pushed for me", which
  felt unnatural; pushing should stay under control throughout, a little or a lot.
  Telemetry:
  - Both items completed in 25 s. No relocations; the body never left the ground.
  - Table press: the right hand was held off its target for 1 s by the table; the
    body did not rise.
  - Wall push: both hands pushed up to about 500 N each. When together they passed
    the legs' 900 N, the body was pushed back at up to 0.4 m/s; at about 880 N it held.
    In all the push moved the body 0.12 m.
  - While pressing steadily, each hand moved 1 to 4 cm over half a second. Telemetry
    cannot separate real hand movement along the surface from drive jitter.
  - At the start, as tracking began, the hands jumped from the hip to the real hands
    (0.5 m for two ticks).
  - Physics process time after startup: mean 1.08 ms, max 1.73 ms.
- **Proportional pushing (2026-09-25), from that report.** The first standing hold
  held like a stiff spring up to the legs' full 900 N and then slipped; past it the
  body slid back on its own momentum (0.4 m/s in the session). Now the hold resists
  only 80 N and the legs brake in proportion to speed (section 6.1), so the body
  follows the push. A new `push_steps` scenario checks it: a small push moved the body
  back 3.8 cm and a bigger one to 15.7 cm, each stopping when the push stopped, and it
  kept 15.4 cm after release. The guided items changed with it: the press item now
  presses a hand on the table (`hand_table_press`: the hand stops on the tabletop,
  steady at 264 N, the body stays put), and the push item asks the player to push
  themselves away from the wall, counting 10 cm of movement while both hands push. All
  26 scenarios pass. **Decision:** pushing off with the hands is continuous and
  proportional, with no strength threshold; this replaces the idea that a slight push
  does nothing and only a strong combined push moves the body. Headset confirmation
  pending.
- **Proportional-push headset sessions, 2026-09-25 18:35 to 18:40** (desktop via
  WiVRn). The first ended when the headset connection was lost
  (`XR_ERROR_SESSION_LOST`). In the second (`headset_2026-09-25T18-38-25.csv`) both
  hands were still pressing down on the table (about 550 N and 400 N, together more
  than the body's 735 N weight) when the push item began, so the body lifted 0.1 m off
  the floor, and the guided push item wrongly counted that as a push. The items now
  need the hands to be touching something, and the push item counts only horizontal
  movement away from the hands; replaying that recording no longer completes it. In the
  third (`headset_2026-09-25T18-39-50.csv`) one two-hand push at shoulder height on the
  wall (270 N and 205 N) moved the body back 0.09 m in 0.5 s, peaking at 0.35 m/s, and
  completed the item; the body stayed on the floor throughout. Player's report:
  pushing felt good. Keep the vault (lifting the body by pressing both hands down on
  the table), but it was "super springy"; it should feel controlled and responsive
  while staying physical.
- **Damped vault (2026-09-25), from that report.** Reproduced headlessly: pressing both
  hands down on the table bounced the body between the floor and 0.28 m at about
  1.1 Hz. Two causes: each hand's force limit acted as an undamped spring, and the
  step-down assist lowered the body whenever it rose off the floor. The force limit
  now also grows while the gap to the target opens (effort damping, section 6.6), and
  step-down no longer applies above the last support (section 6.5). A new `vault`
  scenario presses both hands down on the table, then deeper, then lets go:

  | Phase | Result |
  | --- | --- |
  | First press | rises to 0.10 m, overshooting by 1.9 cm |
  | Deeper press | rises to 0.21 m, overshooting by 0.5 cm |
  | Held | shake under 5 mm; each hand carries 368 N, half the body's weight |
  | Release | lands at 0.51 m/s without bouncing |

  `push_steps` is unchanged in effect (3.6 cm, then 15.3 cm, 14.9 cm kept). All 27
  scenarios pass. The guided session is now: vault on the table, then push away from
  the wall; the checklist counts a vault once both touching hands lift the body 5 cm
  and it lands. **Decision:** the vault stays, as a consequence of the hands'
  physics rather than a separate move. Headset confirmation pending.
- **Damped-vault headset session, 2026-09-25 18:48** (`headset_2026-09-25T18-48-07.csv`;
  desktop via WiVRn, 72 Hz). Player's report: pending. Telemetry:
  - Five lifts on the table. Each held steady once the body stopped rising: the first
    between 0.09 and 0.11 m, the others within 2 mm. No relocations or blackouts.

    | Lift | Height | Fastest rise | Fastest descent |
    | --- | --- | --- | --- |
    | 1 | 0.11 m | 0.42 m/s | 0.61 m/s |
    | 2 | 0.18 m | 0.77 m/s | 0.86 m/s |
    | 3 | 0.14 m | 0.68 m/s | 1.08 m/s |
    | 4 | 0.17 m | 0.75 m/s | 0.94 m/s |
    | 5 | 0.64 m | 0.71 m/s | 1.36 m/s |

  - In the fifth lift the player crouched to a head height of 0.80 m in the room while
    the body rose 0.64 m. Across all five, the view stayed between 1.39 and 1.57 m
    above the floor.
  - Holding the body up took each hand about 360 N, 0.17 m off its target. Rising
    fast, both hands reached their 600 N strength.
  - The vault item counted only the second lift. The body counts as supported up to
    0.08 m above the floor, so the item measured the first lift from 0.08 m. It now
    measures from where the body last stood still; replayed, the first lift counts.
  - The push item did not finish. The recording ends at 29 s, 0.7 s after both hands
    reached the wall, with the body 6 cm back. Replaying showed the item summed only
    movement away from the hands, so wobble added up; movement back toward the hands
    now subtracts. The earlier genuine push (18:39) still counts and the 18:38
    lift-off still does not.
  - Physics process time after startup: mean 0.76 ms, max 0.96 ms.

  Player's report: the vault felt controlled now, and pushing felt good. Walking in
  the room while using the stick caused a desync: "I stop moving or move weird", and
  it immediately caused motion sickness. Moving with room-scale and the stick
  together must be seamless.
- **Seamless stick and room-scale walking (2026-09-25), from that report.** In the
  recording at 23.4 s the stick asked for 1.5 m/s, but the body slowed to 0.1 m/s while
  the head fell 0.29 m behind it, with the legs far below their force limit. Cause: the
  carry rule's clipped projection (section 6.4, revised). A new `stick_room_walk`
  scenario holds full stick for 4.5 s while the real head walks 0.8 m along the stick,
  0.8 m back against it, then 1.2 m across it, past the stick's release:

  | Measure | Before | After |
  | --- | --- | --- |
  | View's velocity off the stick's, steady stick | 1.50 m/s, a stall | 0.03 m/s |
  | Head lead, largest | 0.34 m | 0.07 m |
  | View moved sideways by walking across | 0.41 m | 0.004 m |
  | Stick travel, expected 6.75 m | 4.25 m | 6.73 m |

  The pedestal, wall and room-walk results are unchanged; all 28 scenarios pass.
  Recordings now also carry the player's walking speed in the room, the view's
  velocity and the stick's velocity, so headset sessions measure the same thing. The
  guided session is one item: hold the stick forward and really walk around the room,
  counting 2 m of real walking with the stick held. Headset confirmation pending.
- **Stick and room-scale headset session, 2026-09-25 19:02** (`headset_2026-09-25T19-02-02.csv`;
  desktop via WiVRn, 72 Hz). Player's report: pending. Telemetry:
  - The stick was held for 5.3 s while the player walked 2.1 m in the room at up to
    0.8 m/s, turning as they went. The item was not ticked off: 2.00 m of that walking
    was at 0.2 m/s or more, just short of the threshold, and the recording ends at 12 s.
  - The view followed the stick exactly as the walking motor delivers it, a 0.12 s
    first-order response one tick behind the command: within 0.015 m/s throughout,
    turns included. The recorded check now compares against that response instead of
    waiting for a steady stick, which never happened while turning.
  - The head stayed within 0.07 m of the body, and the body never slowed below
    1.05 m/s with the stick held.
  - Both grips were squeezed while walking, so the arm-pump run added up to 0.21 of a
    run from the arms' movement; the stick's speed rose to 2.3 m/s at times.
  - Physics process time after startup: mean 0.7 ms, max 0.8 ms.

  Player's report: "It felt smooth now, no desync."
- **Flat palms (2026-09-25), at the player's request** before moving on to
  interactions: palms should be boxes rather than rolling spheres, so they behave
  properly with friction; fingers come next, on top of them (section 6.6). Simulated
  scenarios now turn the controllers so the palms face the surface, as a player's do:
  flat against the wall for pushes, flat on the table for presses and vaults. A new
  `palm_slide` scenario rests a palm on the table, slides it, then presses and pulls.
  All 29 scenarios pass:

  | Scenario | Result |
  | --- | --- |
  | Palm pushed into the wall | stops flat at the surface: centre 0.015 m off it |
  | Palm pressed on the table | stops flat, steady; pressed past arm's reach, the gripping palm draws the body 7 cm toward the table, then it holds |
  | Palm slid lightly along the table | stays in contact, flat within 0.1 mm, on its target; body moved 2 mm |
  | Palm pressed 4 cm and pulled 0.1 m back | grips, then slides; the pull drew the body 5 cm toward the table |
  | Vault | rises to 0.10 m, then 0.18 m, steady, lands without bouncing |
  | Push steps | 4.0 cm, then 17.1 cm, kept 16.7 cm |

  A gripping palm pulls the body the way a pushing palm pushes it: the legs hold only
  80 N against a steady pull (section 6.1). Whether that feels right when pressing
  and pulling on a table is for the headset. The guided session is: slide a palm on
  the table, then press and pull; vault; push off the wall. Headset confirmation
  pending.
- **Flat-palm headset session, 2026-09-25 19:23** (`headset_2026-09-25T19-23-31.csv`;
  desktop via WiVRn, 72 Hz). Player's report: pending. Telemetry:
  - Palm slide: the right palm rested flat on the tabletop (centre 1.01 to 1.02 m) and
    slid 0.3 m around it; the item completed at 8.2 s. Pressed at the 600 N cap and
    pulled back, it still slid 14 cm in 0.25 s and came off the table's near edge. The
    body was already against the table's edge, so it could not be drawn in.
  - Vault: both palms flat on the table, together up to about 1,000 N; the player
    crouched to a head height of 0.72 m in the room and the body rose to 0.67 m. As it
    rose, the arm's reach limit pulled both palm targets back toward the shoulders;
    the palms slid 4 cm to the table's near edge and came off it at 22.07 s. Once
    they were slipping, the drive's damping cut their force to the base 20 N, and the
    body fell 0.67 m, landing at 3.5 m/s. The view dropped with it, from 1.34 m to
    0.85 m above the floor, before the player stood up.
  - Push: both palms flat on the wall at 29.5 s, pushing up to 375 N; the body had
    moved back 7 cm when the recording ended at 30.8 s, short of the item's 10 cm.
  - Physics process time after startup: mean 0.7 to 1.1 ms by phase, max 3.2 ms.

  Player's report: "Palms felt good, go ahead with the full finger chain."
- **Physical fingers (2026-09-25), at the player's request** (section 6.6, fingers).
  Four new scenarios; all 32 pass:

  | Scenario | Result |
  | --- | --- |
  | Both hands close, open, make fists, point | every joint within 0.54° of its static bend once settled; closed bends the fingers 66° past open; palms stayed on target |
  | Hands still | finger joints within 0.01° |
  | Right hand turned 90° about each axis | fingers at most 3.1° behind |
  | Hands tracing 1 Hz circles | fingers up to 10° behind, swinging with the hand |
  | Open hand pressed flat on the table | fingers bend back onto the tabletop and stay out of it; the palm comes down flat; still within 0.5° |
  | Pointing index pushed into the wall | the finger folds out of the way, its tip at most 9 mm into the wall while folding (4.7 cm before the 12° minimum bend), then still |

  Every earlier scenario still passes with fingers on: palms, vault, pushes, walking.
  The simulated controllers now also have triggers. Recordings carry each hand's
  largest finger error and average bend, and the session analysis reports them.
  Frame time on this PC, headless, standing with both hands opening and closing: 0.46
  ms with fingers against 0.39 ms without, about 0.07 ms more; not a Quest 3S figure.
  The guided session is: open and close both hands (four closings, either hand), press
  a hand flat on the table, vault, push off the wall. Headset confirmation pending.
- **Finger headset session, 2026-09-25 19:58** (`headset_2026-09-25T19-58-05.csv`;
  desktop via WiVRn, 72 Hz). Player's report: pending. Telemetry:
  - Open, the fingers averaged a 12.4° bend and closed 78.3°, as in the simulation.
    Held still in the air, every joint stayed within 0.7° of its pose (median), 3.9°
    at most.
  - On each fast close or open, some joint trailed the pose by more than 10° for 0.22
    to 0.35 s, peaking at 54 to 55°: the springs follow the static fingers about a
    quarter of a second behind.
  - A palm pressed on the table at up to 550 N: the fingers lay back on the tabletop
    (average bend 6 to 9°, below the 12° minimum, as a surface may press them) and
    held there within a few degrees. Against the wall the same.
  - Vault: both palms on the table at 400 to 590 N lifted the body 0.26 m; it landed
    when the hands let go. The vault item had ticked off at 8 cm up, mid-vault,
    because the body counts as supported up to 8 cm above the floor; it now counts
    only once the hands have let go and the body stands again where it started.
    Replayed, the three sessions with vaults now count them at their landings.
  - Push: both palms on the wall pushing up to 490 N; the recording ends at 29.2 s,
    8 cm into the item's 10 cm.
  - Physics process time after startup: mean 0.87 ms, max 1.23 ms, against 0.7 to
    1.1 ms in the sessions before the fingers (desktop).

  Player's report: "Though this is a cool implementation of the fingers, this is not
  at all what I want." Fingers should have collision but be stable, not flop, curl
  with grip and trigger, and be an extension of the palm rather than bodies with
  weight and joints, for control and stability in interactions; dynamic only in that
  "if they grab onto something like the wall, the fingers stop curling when they're
  stopped by an object."
- **Fingers rebuilt as part of the palm (2026-09-25), from that report** (section
  6.6, fingers). The jointed chain is gone; the hand's mass properties are the palm's;
  Jolt's penetration slop is 5 mm. Two scenarios changed with it: the stepped wall
  push now pushes palm-first, as the others do (it had pushed knuckles-first, which
  with rigid fingers pushes through the fingertips), with a first push 3 cm deeper so
  it is still small; and scenarios that lay a palm on the table start 10 cm further
  back, since the resting hand's fingers otherwise reach the table's edge before the
  scenario begins. A new `fingers_close_on_table` scenario holds an open hand 4 cm
  above the table and closes it. All 33 scenarios pass, in two runs:

  | Scenario | Result |
  | --- | --- |
  | Close, open, fist, point in the air | fingers exactly on the static pose, no lag |
  | Hand turned 90° about each axis, hands circling | fingers exactly on the pose (rigid on the palm) |
  | Open hand closed just above the table | fingers stop 2 mm from the tabletop, held 82° short of a fist; the hand is not shoved; lifted clear, they close fully |
  | Open hand pressed flat on the table | fingers laid flat on it, at most 1.4 mm in; the palm comes down flat |
  | Pointing hand pushed into the wall | fingers out of the wall while pushing; at most 5.5 mm in for a moment as the hand turns away |
  | Light palm slide | 0.7 mm up and down, 1.3 cm behind its target, in contact throughout |
  | Vault; stepped push | 0.10 m then 0.18 m, steady; 3.6 cm then 12.0 cm, kept 11.6 cm |

  Frame time on this PC, headless, both hands opening and closing continuously: 0.54
  ms with fingers against 0.37 ms without; the checks while curling are most of it.
  Not a Quest 3S figure. The guided session is: open and close both hands; close a hand
  against the table or wall (counts once fingers are held 20° short of their pose for
  0.5 s); press a hand flat on the table; vault; push off the wall. Headset
  confirmation pending.
- **Palm-finger headset session, 2026-09-25 20:39** (`headset_2026-09-25T20-39-02.csv`;
  desktop via WiVRn, 72 Hz). Player's report at the end. Telemetry:
  - In the air the fingers sat exactly on the pose, open (9°), fist (63°) and closed
    (78°). On three fast closes they trailed it by more than 10° for at most 0.11 s,
    peaking at 32°: the 720°/s curl limit catching up with the static fingers.
  - Closing onto the table: the right hand lay on it for 2.1 s with grip and trigger
    closed; the fingers stayed laid on the tabletop (bend 2 to 5°), held up to 100°
    short of a fist, and the item completed. The press item completed in 1 s at up to
    157 N.
  - Vault: both palms on the table at up to 475 and 600 N lifted the body 0.35 m; the
    fingers stayed flat on the table under grip; it landed when the hands let go.
  - Push: the recording ends at 43.1 s, just after both hands reached the wall.
  - Physics process time after startup: mean 0.98 ms, max 1.40 ms (desktop).

  Player's report: "Fingers feel good now."
- **Body parts (first part of rung 5), built 2026-09-25; simulated checks pass;
  headset session pending** (section 6.6, body parts). Also changed with it:
  - `StepAssist` sweeps the capsule shape alone (6.5), since the body now carries the
    part shapes.
  - Jolt contacts on the body are read per part; `parts_pressing` and `arm_stretch`
    are recorded.
  - Harness: scenarios without hands (wall, recentre, pedestal, lean) used to start
    with the static skeleton's chest facing its initial -Z while the head faced +X or
    +Z. With the controllers untracked the chest turns only past the 80° neck limit,
    so those scenarios ran with the body sideways; the first results with body parts
    (torso stopping the body at walls, hips hitting the pedestal first) came from
    that and were discarded. They now settle for 2 s with the controllers tracked at
    the body's sides, then drop tracking as recording starts. A scenario may start at
    its own head height (the vault, at 1.45 m: dropping the head 0.25 m in one tick
    swung the knees into the pedestal and shoved the body back at 1.07 m/s). Part
    depth is measured by the physics engine's overlap query, so a capsule's side
    across an edge counts. The kinematic reference was re-recorded: every value is
    unchanged except the wall scenario's highest foot (0.031 m, was 0.062 m; the
    static skeleton's step as the chest turned now happens before recording), and the
    measurements added since rung 4 are now in it.
  - A new scenario, `lean_over_table`, leans the head 0.3 m out over the table and
    down to 1.15 m. The wall and wall-through criteria are rung 2's again (the head
    reaches the wall first).

  | Scenario | Result, with parts (without) |
  | --- | --- |
  | Stand, flat, half stick, steps, ramps, slope, drop, jumps, runs, room walks | recorded identically |
  | Head walked into the pedestal, straight and oblique | the capsule stops at the edge (x 0.550); no part touches it; the torso leans over it from the hips; the view moves only by the push-back past the lean limit |
  | Leaning out over the table | the chest meets the table's edge for 2.4 s: at most 2.8 cm in for a moment, 7 mm while held; the view is pushed back 0.16 m over the lean in and out; the head stays clear, no fade (the head went 0.20 m into the table and faded) |
  | Head walked into the wall | the head reaches the wall first and the view fades, as at rung 2: head 0.128 m in (0.143 m); the torso's top then meets the wall for 1.2 s and pushes the view back 1.5 cm |
  | Walked on through the wall | recentred once |
  | Crouch to 0.8 m | the hips rest on the floor behind the feet for 2 s; nothing moves |
  | Vault | knees against the pedestal's face for 0.04 s; lifted 0.164 m (0.166 m); top horizontal speed 0.22 m/s (0.18 m/s) |
  | Hands on the wall and table, slide, push, fingers | within 5 mm of the runs without parts |

  Arm stretch, where a hand's target is beyond the static skeleton's arm (its drive
  allows arm length plus 0.1 m): 5 to 8 cm with hands at rest or on the table, 11 to
  14 cm reaching into the wall, turning a hand or running hard, 14 cm in the pedestal
  walks (untracked hands held at the body while the torso leans), 17 cm in the fall,
  and 37 cm at the wall-through recentre, which happens with the view black. Frame
  time on this PC (Ryzen 9 9950X3D), headless: the whole harness took 11.10 s with
  parts and 9.71 s without, the mean of four runs each, about 0.09 ms more per
  physics tick. Not a Quest 3S figure. The guided session is: steps up and down,
  lean into the wall, crouch, lean the chest over the table (counts after 0.3 s of
  part contact), press a hand on the table, push off the wall, vault, walk the room
  with the stick held. Headset confirmation pending.
- **Body-parts headset session, 2026-09-25 22:13** (`headset_2026-09-25T22-13-40.csv`;
  desktop via WiVRn, 72 Hz after a start at 120 Hz). All nine items completed (the
  analyser now replays the recording through the checklist to judge the last item,
  instead of assuming it unfinished). Player's report at the end. Telemetry:
  - Wall: the stick took the body to the wall; a body part then pressed for 1.9 s in
    all while the body slid 0.26 m back from the wall in half a second and the head
    moved only 0.1 m forward. The head led the body to the 0.35 m lean limit and the
    view was pushed back 0.145 m. The head never entered the wall and the hands were
    not on it. Which part pressed was not recorded; in a scripted replay of the
    approach, the static skeleton's stride put the right knee 0.22 m ahead of the
    body, against the wall, and the standing hold held it there. Recordings now name
    the parts pressed (`parts_pressed`, by `BodyParts.Part`).
  - Leaning over the table: 19.5 s of leaning with the head at 1.45 to 1.67 m, up to
    0.15 m past the edge. The lean limit pushed the view back 0.36 m in all before
    the chest met the table; a part pressed for 0.31 s in all, at the end.
  - Pressing a hand on the table: a part pressed for 2.0 s. Vault: none; the body
    lifted and landed. Arms stayed joined within 9 cm of stretch (under 6 cm after
    the first item).
  - Physics process time after the first 2 s: mean 1.05 ms, max 1.54 ms (desktop);
    a 41.6 ms frame at startup.

  Player's report: "The body parts felt good, the wall push-back felt good."
- **Per-joint finger curl, 2026-09-25** (section 6.6, fingers), from the player's
  report after the body-parts session: "The fingers tend to be a little finicky when
  gripping on the corner of boxes and such. They twitch around sometimes." Twitches
  are now counted: a joint that turns back on the way it moved the tick before while
  its pose holds still (at least 0.2° each way), recorded per hand
  (`left_finger_reversals`, `right_finger_reversals`). Two scenarios were added:
  `fingers_wrap_edge` (a palm against the table's front face, knuckles 1.5 cm above
  its edge, tilted 20°, closed) and `fingers_grip_box` (a palm on the light box, index
  and middle over its far edge, ring and little finger past its side, closed). All 36
  scenarios pass; the guided checklist's finger-wrap item now replays the box grip.

  | Scenario | Before | After |
  | --- | --- | --- |
  | Twitches (joint reversals): palm slide, vault, hand press, poke, flat on table | 138, 72, 39, 30, 9 | 0, 3, 0, 0, 0 |
  | Closing over the table's edge, tilted | fingers froze at first touch: the little finger's joints 33/35/29° | each joint curls on: index 61/70/51°, middle 58/66/49°, ring 53/60/45°, little 32/67/50°, each finger stopped at its own place (roots 29° apart); at most 0.4 mm in |
  | Closing over the box's corner | index and middle 31/33/28° and 35/37/31°; the little finger, touching the box's side, stuck 75° short over nothing | index 31/55/42° and middle 35/60/45° wrap the edge; ring and little close fully (85/100/70°); the box does not move; no twitch |

  Finger cost per hand per tick on this PC, headless: 36 to 46 µs holding a grip,
  against 19 to 27 µs before; 41 to 44 µs closing in the air, against 44 to 46 µs. Not
  a Quest 3S figure. The guided session is: open and close both hands; close a hand
  over a box's edge or corner and the table's edge, and hold it; press a hand flat on
  the table; slide a palm; vault.
- **Per-joint finger headset session, 2026-09-25 22:37** (`headset_2026-09-25T22-37-57.csv`;
  desktop via WiVRn, 72 Hz after a start at 120 Hz). All five items completed.
  Player's report at the end. Telemetry:
  - No finger joint turned back while its pose held still, in any item: 0 twitches
    in 40.8 s (the previous logic counted 9 to 138 per scenario in simulation).
  - The wrap item completed on the table's front edge: the right hand touching at
    (0.72, 0.98, 0.40), fingers held 81° short of a fist, their average bend steady
    at 23 to 24° for 0.5 s.
  - The hands spent under 0.2 s where the boxes started; box positions are not
    recorded, so whether the fingers closed on a box is not known from the recording.
  - Arm stretch up to 0.19 m for a tick or two during fast hand swings; otherwise
    under 0.04 m. Physics process time after the first 2 s: mean 1.19 ms, max 1.43
    ms (desktop); a 41.5 ms frame at startup.

  Player's report: "Fingers feel good now."
- **Body under the head's centre, 2026-09-25** (section 6.1), from the player's
  report: "The capsule collider that sits at my center while player has become
  problematic as it doesn't sit behind my eyes... the capsule should really center at
  my head. It seems to center now at my eyes." The body now follows the head's centre
  (the static skeleton's head, 0.1 m behind the eyes) instead of the eyes; the head
  obstruction ball around the eyes is 6 cm instead of 10 cm. Scenario changes: the
  lean over the table starts 0.1 m further forward and leans 0.1 m less, so the
  capsule and the head end where they did; a momentary chest depth of up to 4.5 cm is
  allowed there (4.0 cm measured, 2.8 cm before; the thighs, then still meeting the
  level, were the deepest part, see the next entry), and up
  to 3 cm of view push-back at the wall (2.4 cm measured, 1.5 cm before: the chest's
  top, which follows the head, meets the wall as the view starts to darken). The
  harness's simulated head turns about the eyes, not the neck, so its 180° turns now
  move the body 0.2 m; a real head turns about the neck. All 36 scenarios pass; the
  kinematic reference was re-recorded with the new twitch measurement only.

  | Scenario | Before | After |
  | --- | --- | --- |
  | Standing | body under the eyes | body 0.1 m behind the eyes |
  | Head walked into the wall | head 0.128 m in, view black | 0.072 m in, view 72 % dark |
  | Head walked into the pedestal | view pushed back 0.30 m past the lean limit | 0.20 m: the head's centre may lead 0.35 m, the eyes 0.45 m |
  | Room walks, stick walks, steps, ramps, runs, jumps | all criteria pass | all criteria pass |

  Headset confirmation pending.

- **Head-centred body headset session, 2026-09-25 22:51** (`headset_2026-09-25T22-51-48.csv`;
  desktop via WiVRn, 72 Hz after a start at 120 Hz). All five items completed.
  Player's report at the end. Telemetry:
  - The stair climb itself was clean: full 1.5 m/s, normal step lifts, no body part
    pressed. The steps item ran 20 s because the player first spent 16 s at the table
    after the lean item: with the stick held into it, the left thigh stopped the body
    3 cm before the capsule would have; leaning down over it, the chest rested on its
    edge and lifted the body 0.11 m off the floor for about 0.5 s.
  - Walking the room into the big wall (stick-and-room item): with the head in the
    wall (view 57 to 85 % dark), the torso, right shoulder and right upper arm, which
    follow the head, pushed the body 0.4 m back from the wall at up to 0.55 m/s while
    the head stayed; the head led the body by up to 0.5 m, short of the 0.6 m
    recentre. The same pattern as the 0.26 m slide in the body-parts session.
  - Wall item: head at most 0.052 m in.
  - Physics process time after startup: p95 1.31 ms (desktop); a 42.6 ms frame at
    startup.

  Player's report: "The capsule feels better behind my eyes now."
- **Thighs pass into the level, 2026-09-25** (section 6.6, body parts), at the
  player's request. They push props like the calves and feet. All 36 scenarios pass;
  the lean over the table now takes the chest at most 2.6 cm into its edge for a
  moment (4.0 cm with the thighs, which the depth measure had counted), so its limit
  is back to 3.5 cm. Only the torso and hips now meet the level in the scenarios: the
  torso at the wall and table, the hips on the floor in a deep crouch. Found while
  checking it: the vault's steady hold bobs 4.2 to 4.4 mm or 8.2 mm depending on
  which scenarios ran before it in the same run, with or without this change (the
  physics engine's solve order; nothing in the scripts depends on the frame count),
  so its limit is 1 cm rather than 5 mm. Headset confirmation pending.

- **Pushing props (first part of interaction), 2026-09-25**, at the player's request:
  "Lets start with just allowing the physical body to push around and interact with
  rigidbodies. Currently it cannot." Cause: the level's boxes did not mask Player or
  Hands, and in Jolt each side of a contact must mask the other (6.8); a probe showed
  the palm passing through the light box and the capsule walking through a 5 kg box
  while its ground sweep lifted it 4 cm onto it. Fixed in the level data: the three
  boxes' masks follow the layer table (315). No player code changed for it; the
  snapshot now reports which of the body and hands pushed a loose prop
  (`prop_contact`, recorded), and the harness reference check lists measurements
  added after the reference was recorded instead of failing on them. New scenarios:

  | Scenario | Result |
  | --- | --- |
  | Palm pushes the light box 0.2 m along the table, leaning out to reach | box moved 0.20 m; it rocks and skews (friction 1 at a push through its middle is at the edge of tipping), rising at most 3.2 cm; not thrown (0.34 m/s); the palm 7.8 to 12.4 mm into it while pushing, by solve order |
  | Walking at full stick into an 8 kg crate on the floor | shoved about 1 m, then off to the side of the round capsule, which walks on past it; the body stays on the floor |
  | Walking past a 12 cm box in line with the right foot | the right foot and calf kick it 0.23 m; the capsule's edge also meets its top and may step onto it (step checks include props). Since 2026-10-03 the legs pass through it |

  The hands now meet the table's boxes in the vault and the box grip, where they used
  to pass through; both still pass. All 39 scenarios pass. The guided session is:
  push the boxes with the hands, knock one onto the floor and walk into it (counts
  after 1 s of pushing); close a hand on a box; vault. Headset confirmation pending.

- **Stronger wrists, 2026-09-25** (section 6.6, hands), at the player's request. A new
  scenario, `palms_lift_box`, squeezes a 20 cm box between the palms (turned to face
  each other) and lifts it 0.15 m with no grip. The hand's turning torque, a velocity
  servo computed for the hand's inertia, held a load with only about 1 N·m/rad against
  the palm's 0.0013 kg·m², so the box rolled the palms. Tried first: the joint's
  angular motors (6.6, 13); they held loads rigidly but palm slide, finger poke and
  box grip failed on stick-slip and shaking at every strength tried. Chosen: the same
  torque with a wrist inertia of 0.04 kg·m² and limits of 4 N·m plus 120 N·m/rad up
  to 40 N·m. Turning in the air is unchanged (a 90° controller turn followed within
  1.1°).

  | Box squeezed and lifted 0.15 m | Before | After |
  | --- | --- | --- |
  | 2 kg | | lifted 0.15 m, tilted 5°, palms within 3.5° of their targets |
  | 5 kg | lifted 0.14 m, rolling the palms and itself 24 to 28° | lifted 0.14 m, tilted 6°, palms within 2.6° |
  | 8 kg | | lifted 0.125 m, tilted 7.5° |
  | 10 kg | | lifted 0.09 m, tilted 16°, palms within 4°: the squeeze's friction, not the wrists, is now the limit |

  Criteria re-baselined for a hand that no longer rolls freely, each noted in the
  code: closing over the light box, the fingertips hook its edge fully while the
  middle joints curl 20 to 35° (the check is now middle plus tip at least 60°), the
  box is nudged 1.2 cm (at most 2 cm) and a finger may sit 4 mm into it; the palm
  pushes the box 0.15 to 0.2 m by solve order (at least 0.12 m); pressed past its
  reach on the table the palm grips over its whole face and the body's draw toward the
  table settles about 0.4 s later (creep at most 1 cm). All 40 scenarios pass twice.
  The guided session is: push the boxes; squeeze one between the palms and lift it
  (counts once both hands on a prop rise 8 cm); close a hand on a box; press a hand on
  the table; slide a palm; vault. Headset confirmation pending.

- **Stronger-wrist headset session, 2026-09-25 23:33** (`headset_2026-09-25T23-33-23.csv`;
  desktop via WiVRn, 72 Hz). All six items completed. Player's report at the end.
  Telemetry:
  - Palm lift: both palms pressed on props for about 0.9 s and rose 0.10 m together,
    18 to 20 cm apart; the left palm pushed with up to 159 N, the right with its base
    20 N. Whether a box rose with them was not recorded: recordings now carry the
    heaviest prop being pushed (`prop_x`, `prop_y`, `prop_z`, `prop_mass`), and the
    analysis reports how far a prop pushed by both hands rose (`prop_lift`; 0.142 m
    for the 5 kg box in `palms_lift_box`).
  - Pushing props: the head went down to 0.64 m (reaching to the floor) and the arm
    stretched up to 0.23 m; the lean limit pushed the view back 0.19 m.
  - Finger twitches: 5 while pushing props, 3 in the vault, none elsewhere.
  - Physics process time p95 1.56 ms (desktop); a 41.8 ms frame at startup.

  Player's report: "Wrists feel good now."
- **Grabbing, first part (rung 5), 2026-09-25**, at the player's request: grab
  rigidbodies anywhere on their surface, the object's grab point the closest point
  to a grab point just inside the palm, found continuously until the grab, the
  object then pulled into the hand "smoothly but quickly", with a configurable grab
  area where the nearest contender wins. Built as above (6.7): `Grabbable`,
  `HandGrab` per hand, the Held layer, finger checks that include it, debug dots and
  lines (yellow candidate, orange pulling, green holding), and per-hand grab state
  and gap in recordings. New scenarios, all passing with the other 40:

  | Scenario | Result |
  | --- | --- |
  | Grip 4 cm above the light box, lift 0.2 m, hold, let go | pulled into the palm in 0.11 s; held within 4.6 mm of the grab point; rose 0.24 m with the hand; its rotation relative to the hand unchanged (0.0°); the hand held within 9 mm of its target; let go, it landed where it started |
  | Grip between two boxes, 1 cm from one's edge and 4 cm from the other's | the nearer box grabbed and lifted 0.16 m; the other did not move |
  | Grip 5 cm above a 40 kg box | the hand came 5.5 cm down to it; the box did not move, nor lift after |
  | Close both hands in the air | nothing grabbed |

  Changed with it: the box-grip finger scenario turns the boxes' `Grabbable` off, to
  stay about the fingers; scenarios working at the table's boxes may start with the
  resting hands raised (`hand_height`), since resting hands at table height shoved the
  boxes during the settle; the respawn scenario raises its kill height to -6 m, since
  the level's new terrain catches a fall off the edge at about -8.3 m. The kinematic
  reference differs from the current level in 29 ground measurements (foot heights,
  step landings) and matches the level as it was before the player's edits (terrain,
  a cut in the big wall): to re-record once the level settles. The guided session is:
  grab a box, lift and turn it, let it go (counts once something has been held 1 s
  and let go); squeeze a box between the palms; push boxes. Headset confirmation
  pending.

- **Grab headset session, 2026-09-26 00:14** (`headset_2026-09-26T00-14-28.csv`;
  desktop via WiVRn, 72 Hz after a start at 120 Hz). All three items completed.
  Player's report at the end. Telemetry:
  - Grab: one grab, the box in the hand 0.056 s after the grip closed, held 4.0 s
    within 4.4 mm of its grab point, then let go; no finger twitches.
  - Palm lift: both palms raised the 5 kg box 0.089 m; a grab with the grip during
    the item pulled in within 0.07 s and held 3.1 s.
  - Pushing: the 5 kg box rose 0.20 m under both hands.
  - Physics process time 1.0 to 1.7 ms per tick after the first 2 s (desktop); about
    10.6 ms per tick through the first 2 s of startup, longer than before (the
    level's new terrain loading is a guess, not measured).

  Player's report: "Grabbing felt really good except I had 2 issues. When I held
  the medium box and swung extremely fast, I could see the box arcing really hard
  because of the weight... I swung with the heavy box and it arced as well but then
  dropped it. I would like the objects being held to be under more control when
  swinging around because they really shouldnt arc beyond the hands placement if
  being held by that hand."
- **Held objects under control, 2026-09-26** (6.6 carrying, 6.7), from that report.
  New scenarios swing the medium (5 kg) and heavy (10 kg) boxes fast across and
  back twice, 0.5 m each way in 0.2 s (peaking near 4 m/s). Step by step, for the
  10 kg box:

  | Change | Box off the hand's grab point | Hand off its target | Wrist turned | Box past the swing's end (hand's own) |
  | --- | --- | --- | --- | --- |
  | Before (held by the pull's motors) | 0.335 m | 0.27 m | | 0.117 m |
  | Locked rigid in the hand | 0.006 m | 0.405 m | | 0.088 m |
  | Hand strength carries half the held mass | 0.005 m | 0.070 m | 37° | 0.047 m (0.016 m) |
  | Turning computed with the held inertia | 0.004 m | 0.069 m | 26° | 0.043 m (0.019 m) |
  | Wrist steadies against the hand's acceleration | 0.005 m | 0.071 m | 9.7° | 0.030 m (0.020 m) |

  The 5 kg box ends at 0.005 m, 0.053 m, 5.9° and 0.032 m (0.026 m). An empty hand
  overshoots the same swing by 0.030 m. Carrying the full held mass (share 1)
  improved little over half (0.038 m against 0.047 m past, before the wrist
  changes), so half is kept, leaving some weight to feel. All 45 scenarios pass.
  The guided session is: grab a box, lift it and swing it fast, let go (the medium
  and heavy boxes too); squeeze a box between the palms. Headset confirmation
  pending.

- **Held-object headset session, 2026-09-26 00:41** (`headset_2026-09-26T00-41-10.csv`;
  desktop via WiVRn, 72 Hz). Both items completed. Player's report: pending.
  Telemetry: the grabbed boxes stayed within 1 cm of the grab point (5 cm once, in
  a whip); holding the heavy box, the hand's force limit swung between 120 N and
  3600 N every other tick on 683 of 2952 holding ticks and the hand shook 7.5 to 10
  cm about its target; in the player's fastest swings the hand fell 0.3 to 0.7 m
  behind the controller. The simulated swing showed the same swing of the limit (37
  of 277 ticks), unchecked until now.
- **Carrying revised, 2026-09-26** (6.6 carrying), from that session: a steady force
  allowance for the held mass (200 m/s² over up to 15 kg) instead of multiplying the
  hand's limit, and the wrist's steadying from the acceleration halfway between what
  the drive asks and what was measured. A new scenario whips the 10 kg box 0.6 m
  each way in 0.12 s (peaking near 7.5 m/s); the swing scenarios now also check that
  the hand's force limit holds steady (at most one tick in 50 halving or doubling).

  | Scenario | Hand off target | Wrist turned | Box past the swing's end (hand's own) |
  | --- | --- | --- | --- |
  | 5 kg, fast swing | 0.050 m | 2.0° | 0.026 m (0.024 m) |
  | 10 kg, fast swing | 0.063 m | 5.8° | 0.017 m (0.018 m) |
  | 10 kg, whip | 0.150 m | 8.8° | 0.042 m (0.033 m) |
  | Empty hand, whip | 0.110 m | 0.4° | (0.067 m) |

  Before the revision the whip gave 0.388 m, 20.1° and 0.094 m. A larger allowance
  (300 or 400 m/s²) changed nothing: the hand's following, not its force, then
  limits. A 40 kg box still lifts one-handed (0.167 m). All 46 scenarios pass.

- **Revised-carry headset session, 2026-09-26 00:47** (`headset_2026-09-26T00-47-08.csv`;
  desktop via WiVRn, 72 Hz). Both items completed. Player's report: pending.
  Telemetry: the force limit halved or doubled between ticks on 28 of 3118 holding
  ticks (683 of 2952 before the revision). The player whipped the 10 kg box about
  once a second with the hand at 9 to 12 m/s; the box stayed within 1 to 2.5 cm of
  the grab point (4 cm at most), and the hand, at its 2600 N limit (600 N own plus
  2000 N carrying), fell up to 0.57 m behind the controller: about 3000 to 4500 N
  would be needed to follow. The hand was over 0.2 m behind for 1.25 s in all. No
  finger twitches. Squeezed between the palms, the 10 kg box rose 0.023 m.
  Player's report (2026-09-26): "Feels extremely better now", but "the 10kg box feels
  the same as the 1kg until I start swinging ... I can pick it up and it still feels
  weightless"; asked for the arm chain to show the weight (6.6.1).

- **Jointed arm feasibility, 2026-09-26** (scratch scene, not in the project: a
  frozen torso, upper arm 2 kg, forearm 1.5 kg, hand 1 kg; Jolt, 72 Hz). Hand error
  and jitter holding a load straight out (0.55 m) for 5 s:

  | Drive | Solver steps | 1 kg | 5 kg | 10 kg |
  | --- | --- | --- | --- | --- |
  | Jolt joint motors | 10 (project) | 0.098 m, 3.2 cm/tick | 0.164 m, 3.2 cm/tick | 0.21 m |
  | Jolt joint motors | 30 | 0.003 m | 0.033 m, 1.0 cm/tick | 0.21 m |
  | Each joint alone, explicit torque | 10 | fell, flailed | fell | fell |
  | Chain dynamics, explicit torque | 10 | 0.002 m, steady | 0.007 m, steady | sagged 0.20 m, no bobbing |

  Raising solver steps is global, so the chain dynamics (`ArmDynamics`) were built.
- **Jointed arm built, 2026-09-26** (6.6.1; `arm_dynamics.gd`, `hand_drive.gd`
  rewritten, `body_parts.gd`, `capsule_body.gd`, `rig_carrier.gd`,
  `dynamic_physical.gd`, `hand_grab.gd`; the snapshot's hand force became
  `arm_effort`, 0 to 1 of the arm's strength, and `arm_stretch` the widest joint gap).
  Two new scenarios hold a box out at arm's length. Simulated (48 scenarios):

  | Scenario | Result |
  | --- | --- |
  | 2 kg held out | sagged 0.001 m |
  | 10 kg held out | sank to 0.23 m below the target, at most 3 mm a tick, arm at full strength, still held |
  | 5 kg, fast swing | hand dragged 0.57 m behind, box in the hand (0.007 m), held |
  | 10 kg, fast swing / whip | dragged 0.62 / 0.47 m, held |
  | Free hands tracing circles | within 0.01 m |
  | Vault, walls, table press, palms lift a 5 kg box, walking, slopes, steps | pass |

  To get there (each measured in the harness): the arms' weight counted in jumps
  and on slopes; their swinging given back to the body (the view drifted 2.2 cm
  walking about the room); the carrier counting the whole player's momentum; a
  firmer wrist (fingertips brushing a pedestal turned the hand 19°); forearms passing
  through the level (on tables they propped the hand up 4 cm and caught the table's
  edge; upper arms still meet the level); the forearm's shape ending short of the
  wrist; the reach reinstated with the arm's cap (6.6.1).

  Known regressions, still failing (14 criteria in 7 scenarios, the same on two
  runs): `wall_through` never recentres (the head leads by at most 0.58 m of the 0.6 m
  limit: without the upper-arm shapes on it, the torso alone stops the body 2 cm
  nearer the wall, and it then creeps toward the head); `table_oblique` view pushed
  back 0.096 of 0.1 m; `vault` a deeper press lifts 0.035 m more, not 0.05, and it
  lands with a bounce; `palm_slide` the palm lags 0.026 m (0.02 allowed);
  `fingers_wrap_edge` two fingers miss the edge; `fingers_grip_box` the little finger,
  over nothing, is stopped 74° short; `finger_poke` the hand moves 0.036 m pushing.
  The swing checks were rewritten for the weight now showing (held, in the hand, not
  far past it, dragging 0.15 to 0.8 m, the wrist within its range) in place of the
  strong wrist's 12° and 0.1 m. Headset session pending.

- **Arm redesign, 2026-09-26.** Player's report on the jointed arm: "this feels like
  crap. It is super buggy in all senarios. The arm no longer matches the skeleton
  frame enough ... It should be dang near 1:1 when not holding anything ... The
  strength of the arm needs to be really strong but ... controlled meaning it doesn't
  spring around everywhere. We might have to artificially simulate the joints torque
  strengths." Measured then (simulated, scratch copies; no headset telemetry of that
  build): facing +X the idle left elbow was 189 mm off the static skeleton (1 mm
  facing -Z: the wrist's twist range was built from a world axis); past full reach
  the fixed-length bones slid the shoulder up to 10 cm; a straight arm let rounding
  pick the bend axis (a 127° pose step in one tick); the wrist spring was unstable at
  72 Hz (36 Hz buzz); the elbow lagged 4 cm on walk starts and overshot 2 cm at swing
  turnarounds. Four scratch prototypes on one test set:

  | Prototype | Free arm | 0.2 m step | 10 kg held out | Cost per arm |
  | --- | --- | --- | --- | --- |
  | P2 posed arm, physical hand, simulated strength | exact | no overshoot, 3 ticks | steady sag, by preset (0.38 m human) | 1 body, 1 joint |
  | P4 segments on Jolt springs + simulated sag | 0.4 mm slow, 7 mm at 3.6 m/s | no overshoot | model-dependent | 3 bodies, 3 springs, 2 joints |
  | P1 segments on Jolt velocity motors | 0.2 mm slow, 4.5 mm fast | pressed 1660 to 2255 N | flailed without a mode switch | 3 bodies |
  | P3 velocity overwrite, strength-capped | 1 mm | none | 5.4 cm (strong) | script-heavy; stiffness tied to tick rate |

  All four agreed weight has to come from a simulated torque budget that moves the
  target, not from motor or torque limits (a limits-based version flailed 0.73 m with
  10 kg). Chosen with the player: P2's approach (6.6.2), human strength, jointed
  segments dropped. Built by restoring the pre-arm build (all 46 scenarios passed
  again) and adding ArmStrength. Along the way: the strength-shaped target first
  lifted a 40 kg box off the table (the drive was far stronger than the arm), so the
  drive is capped by the arm's capacity while holding and a load resting on something
  is not borne; the carrying allowance became the commanded motion's own force; and
  anything that moved the empty arm off the pre-arm build by even rounding (the
  target rebuilt from the wrist, the static skeleton's over-reach rule, adding the
  static elbow's own motion) made the fingers on a box's corner twitch 3 to 7°, so
  the empty arm is the pre-arm build exactly. All 46 scenarios pass. Holding the
  2 kg box out lowers the hand's target 7.6 mm (0.8° at the shoulder, 8 N·m).

  Verification (simulated, 2026-09-26; no headset session yet). Twelve scenarios
  were added for the arm: the idle arm in four facings, reach poses past full
  reach, a hand turn, a hand resting on the table, room-scale walk starts and stops,
  2 kg and 10 kg held out and let go, a 0.15 m controller jump with 10 kg held, and a
  steady 50 N push on a free hand. 51 of 58 pass (all 46 earlier ones). Held out at
  0.9 of full reach, 2 kg lowers the command 12.6 mm and settles in 4 ticks; 10 kg
  sags the shoulder 58.8° (0.46 m, 58 N·m asked of 45) and settles in about 0.5 s.
  The controller jump first jumped the 10 kg command 6.4 mm in one tick (feed-forward
  about 365 N): the static skeleton turned the elbow's bend plane 53° in that tick
  and the sagged elbow swung the load round with it. The bend plane now follows at
  the arm's strength (6.6.2), which removed the jump and changed nothing else in the
  58 scenarios except that jump's peak force (637 to 600 N). Still failing, with
  their measured causes:

  | Scenario | Criterion missed | Measured cause |
  | --- | --- | --- |
  | arm_reach_poses, arm_hand_turn, arm_room_walk | moving hand within 1 mm (1°) of the static hand beyond a tick's motion: 3.0 mm, 1.02°, 4.7 mm | the strength model is not shaping (pass-through); the rung-3 drive's following (15 /s) |
  | arm_table_rest | hand at rest within 1 mm and 1° of the static hand: 2.3 mm, 2.3° | fingers and palm resting on the table hold it there (touching 112 of 293 ticks) |
  | grab_hold_out_heavy | no bob while sinking: 1 reversal | after sinking the hand rose 1.6 mm over 1 s as the static shoulder settled 1.3 mm forward after the reach; the sag never passes its equilibrium |
  | grab_step_heavy | overshoot at most 1 mm: 2.3 mm, 2 reversals | the command does not overshoot (0 mm); the drive puts the hand a tick of motion ahead and brakes 11 kg within the arm's capped force |
  | push_free_hand | no ringing under a steady push: 70 reversals, 2.9 mm a tick | rung 3's effort damping on an empty hand (a known 36 Hz swing) |

- **Arm revision, 2026-09-26 (evening).** Headset session 21:48 (WiVRn, desktop;
  the guided session closed itself after its two items, 37 s, so the heavy boxes
  were tried outside it). Player's report: "The 2kg box feels fine until I make
  quick movements like flick my wrist quickly. Then I notice the springyness and
  awkwardness ... the heavy box is buggy. The physical hand just drops and feels
  like it gives up but if I lift past the height of my shoulders then it matches up
  with my skeletal hand pretty well. The strength scaling on the heavy objects does
  not feel good at all. Do not patch up with more and more layers of systems and
  solvers." Telemetry: a 2 kg box swung at up to 8.9 m/s lagged its tracked hand by
  up to 0.36 m, and the hand its target by up to 0.21 m while shaken. Causes found:
  at 45 N·m the shoulder gave way beyond 37 cm from itself (10 kg held out dropped
  0.46 m; above the shoulder the lever is short, so it held); the wrist's torque
  limit, growing only with the angle, let a flick leave the hand 17.5° behind its
  target and swing it 11.8° past (the empty hand does the same: 29° and 11.8°); and
  the effort damping, lowering the force while the gap closes, left a swung load
  unable to stop. Chosen with the player: a load strains the arm, never drops.
  Revised (6.6.2): ArmStrength cut from 785 to 313 lines (the give-way solvers, the
  elbow and its bend plane, remembered sag axes and the catch-up after letting go
  removed; a closed-form dip at the shoulder and wrist); strength 80 and 15 N·m; the
  drive's capacity cap and held damping removed; carrying in free air, damping both
  ways and the wrist's full torque with its target's turning fed forward. Tried and
  dropped: braking at full strength when overtaking (switched every tick: a free
  hand pushed chattered 5 mm a tick), asking for the target's next-step velocity
  (turned target noise into a 0.25 mm-a-tick buzz on a still hold), scaling the
  drive's effort by the borne mass (letting go of 10 kg overshot 18 mm), and the
  same free-air rules for an empty hand (a vault overshot 5 cm and a palm pushed a
  box 0.12 m instead of 0.2 m). Simulated results, 60 scenarios, 53 pass; the 49
  that hold nothing are unchanged to the last digit:

  | Measurement | Before | After |
  | --- | --- | --- |
  | 10 kg held out at 0.9 reach | dropped 0.46 m (gave way) | dips 5.9 cm, settles in 0.1 s |
  | 2 kg held out | 12.6 mm | 10.9 mm |
  | 2 kg wrist flick (70° in 0.08 s): hand behind the static hand | 21.6°, 23 mm | 9.2°, 18 mm |
  | the same: swung past it afterwards | 11.8° | 5.9° |
  | letting go of 2 kg / 10 kg: overshoot | 0 / 0 mm | 0 / 0 mm |
  | 40 kg box | not lifted | not lifted |

  Still failing besides the pre-existing five (arm_reach_poses, arm_hand_turn,
  arm_table_rest, arm_room_walk, push_free_hand): 10 kg bounces 0.6 mm settling into
  the hold, and after a 0.2 m jump of the controller it overshoots 13 mm (its target
  4 mm). The box hangs on the 1 kg hand by a joint the solver cannot fully converge
  at 10:1: with 40 velocity steps the overshoot fell to 9.4 mm and the held box's
  steady 5.7 mm below its target to 0.2 mm (diagnostic only; not changed). Fixing it
  properly means changing how a held object is attached, or the solver's steps
  (cost on the Quest); for the player to decide. Headset session 23:24 (free play,
  55 s; WiVRn, desktop): 2, 5 and 10 kg boxes held and swung (telemetry: holding up
  to 15, 37 and 69 N·m, dips up to 1.6°, 3.5° and 6.8°). Player: "This honestly felt
  the best out of all the attempts. I think we should stick with this current setup
  and run with it." **Accepted: this is the arm.**

- **Weapons on the table, 2026-09-27**, at the player's request: the dagger and sword
  from `craftables.blend` (adventurer-vr; its saved file and the open session's
  autosave have the same meshes), grabbable, on the table.
  `tools/blender/export_weapons.py` (headless only) writes them to
  `assets/models/weapons/{dagger,sword}.glb` at 0.1 scale (the file models at ten
  times life size; adventurer-vr's copies use the same scale): dagger 0.34 m, sword
  0.68 m, origin in the grip, blade along +Y, back faces culled.
  `scenes/props/{dagger,sword}.tscn` are a `RigidBody3D` (Dynamic, mask 315; 0.45 and
  1.2 kg, as in adventurer-vr) with the model, box colliders on the grip, guard, blade
  and pommel (boxes give exact grab points) and a `Grabbable`. The blade boxes run
  full width to the point, so the tips collide square: their corners stand up to 2.2
  cm clear of the mesh, and a tip meeting a surface at an angle stops short of it. The
  automatic centre of mass balances the sword about 7.5 cm past its guard and the
  dagger just past its grip, so none is set. Both lie flat on the table's +Z half,
  blades toward the boxes, the sword's grip out over the table's end: picked up
  palm-down in the right hand, the blade leaves the thumb side, so turning the hand
  thumb-up holds it edge-forward. Found on the way: several-shape props sank into the
  table (6.7; the dagger 2.2 mm where it lies, 0 with contacts reported) and tunnelled
  (6.8; CCD). Harness: the table scenarios put their hands and crates where the
  weapons lie (a review run keeping them there failed five, palms_lift_box's spawned
  crate landing on the sword), so each scenario takes them out of its level before it
  enters the tree unless it sets `weapons`; the 60 existing scenarios' 4958 results
  are unchanged to the last digit (53 pass, the same seven fail). New, all passing
  (simulated, not headset):

  | Scenario | Result |
  | --- | --- |
  | weapons_rest | from where the level lays them: sword 0.5 mm and 0.5°, dagger 1.3 mm and 1.1° (each rocks onto its blade's tip within 0.1 s), then still for 3 s; lowest corner 0.4 mm (sword) and 0.0 mm (dagger) into the top |
  | grab_sword_table | grabbed by the grip, in the palm in 0.11 s, lifted 0.24 m, turned 0.0° in the hand, hand at most 6 mm off its target; let go, it landed 4.6 mm from where it lay |
  | grab_dagger_table | the same: 0.11 s, 0.24 m, 0.0°, 4 mm; landed 0.6 mm away |

  A review pressed and chopped a held weapon into the table (scratch runs): the grip
  held, nothing launched or passed through. Unchanged and still wanted later: grip
  poses (a weapon is held at whatever angle the palm met it), two-handed holds and a
  throw policy. A weapon in each hand passes through the other, since Held does not
  mask Held (6.8); whether held weapons should meet is for the player to decide
  (decided 2026-10-03: they meet).
  Unmeasured: how far a swung sword trails the hand (by analogy with the 2 kg box it
  will), the cost of CCD and contact reporting, and draw calls (sword three surfaces,
  dagger two, each also drawn by the mirror). The guided session's items are
  unchanged, and the recording does not name what a hand holds; the headset check is
  free play recorded with `-- --record-session`: pick each weapon up with each hand,
  turn it thumb-up, swing it, lay the blade on the table and press, drop and throw it.
  Headset confirmation pending.

- **Weapons headset session, 2026-09-27 10:23** (`free_2026-09-27T10-23-02.csv`; free
  play with `-- --record-session`, 107 s; WiVRn, desktop; 72 Hz after a start at
  120 Hz, 0.04 s at 90 Hz). Player's report: "It feels fine for now." Telemetry: four
  grabs, all right-handed (the dagger 19 s; the sword 19, 24 and 24 s, the last picked
  off the floor 6 m from the table), each held until the grip opened; holding up to
  10 N·m with the sword and 3.5 N·m with the dagger, dips up to 1.8°; the hand up to
  12.8 m/s; no fade, recentre or hand recovery; physics 1.7 ms a tick on average
  (desktop, not a Quest 3S figure). The grip stretched more than with the boxes the
  night before: the held grip's gap was at most 18 mm 95 % of the time and 53 mm at
  worst with the hand clear of the table and floor (boxes: 11 and 22 mm), and up to
  149 mm with it within a blade's reach of the table or boxes, inferred (not recorded:
  the recording does not log what a held object touches) to be the blade striking
  them. The dagger's pull-in took 0.44 s, the hand lifting as the gap closed. Accepted
  for now.

- **Physical layer view and skeleton toggle, 2026-09-27**, at the player's request:
  "see the physical layer without having to turn on the debug visual collision shapes"
  and "hide the static skeleton with the B button on the right controller".
  `PhysicalDebug`, which drew the palms, fingers, body parts and grab points in debug
  runs only, moved from `debug.tscn` to the player's Visual slot (sections 1 and 7;
  `player.gd` wires it as `physical_view`) and now draws the body's capsule too (the
  snapshot gained `body_radius`), so every run shows the physical layer, the mirror
  included. `SkeletonToggle` (section 8) flips `SkeletonDebug.visible` on the right
  controller's B (`by_button`, already in the action map and unused); `PlayerRig`
  names the drawing as `skeleton_view`. Nothing new writes to the physical layer or
  the skeleton, and the hidden drawing skips its per-tick update. Harness:
  `SimulatedRig` presses B (`right_b`), and `skeleton_toggle` checks that B at 0.5 s
  and 1.5 s leaves the skeleton shown, hidden and shown again without a jump, and that
  all 49 of the player's collision shapes are drawn with their type, size and axis
  where the engine has them (worst 0.0 mm). Run on two copies of the project differing
  only in this change, the other 63 scenarios' 5195 results are identical. The same
  morning the player lengthened the table to 1.5 m and edited `physical_dynamic.tscn`;
  on those, with or without this change, `fingers_grip_box` fails (a finger joint
  moved 2.29° in a tick) and the other results shift slightly: 56 of 64 pass.
  Unmeasured: the cost of about 50 unshaded translucent meshes drawn in every run (no
  shadows), including one or two capsule meshes rebuilt on about half of the frames
  while walking (about 10 µs each on the desktop's CPU), against the 115 shaded,
  alpha-blended ones (which cast no shadows) the skeleton's drawing and its per-tick
  update remove when hidden. Headset confirmation pending: B hides and shows the
  skeleton, left Y does nothing, A still jumps, and whether the capsule's band below
  the eyes when looking down bothers the player (if it does: fade it near the camera,
  or leave it to the mirror).

- **Physical view headset session, 2026-09-27 13:30** (`free_2026-09-27T13-30-20.csv`;
  free play with `-- --record-session`, 50 s; WiVRn, desktop; 72 Hz after a start at
  120 Hz). Player's report: "Works well, B hides the skeleton fine. So far it handles
  pretty good." Telemetry: one right-handed grab of the sword, held 19 s (pulled in
  0.11 s, holding up to 9.6 N·m, the held grip's gap at most 38 mm, the hand up to
  8.2 m/s); no fade or recentre; physics 1.14 ms a tick on average after the first 2 s
  (1.24 ms in the morning's session; desktop, not a Quest 3S figure). The recording
  does not log button presses or what is drawn, so B and the view rest on the player's
  report. Accepted.

- **Two-handed holds, 2026-09-27**, at the player's request ("start to work on two
  handing objects"), planned with the player: both hands hold a point and the object
  aims between them (chosen over one hand rigid and the other pivoting, and over both
  rigid); when the lead lets go the other takes over rigidly; wrist strength stays the
  player's 120 N·m; the LongSword from `craftables.blend` joins the table as the
  two-handed test item (`scenes/props/longsword.tscn`, 1.9 kg as in adventurer-vr,
  0.985 m, grip 19 cm; box colliders; balance 14 cm past the guard; lies along the
  table at x 1.10, its settle 0.9 mm and 0.4°). Scratch tests first (S0-S3, headless):
  a joint freed and remade in one tick never overlaps; a layer change shows in queries
  the same tick; a linear motor's target turns with node_a (the hand), so the existing
  pull conversion also holds for a hand pulling with rotation free; the aim joint
  swings freely, holds its roll, and rolls 30° with a 30° hand roll, but snaps near
  180° of swing; two hands chasing their own controllers through one rigid object
  fought (a 10 Hz wobble or a 36 Hz buzz) whatever the damping. The player rejected a
  sliding second hand and chose a shared target: the mean of the two hands' positions
  and rotations (6.7). The drive's two-hand rules were agreed with the player (full
  force on every axis, headroom by the lever share, the joints at the hands' centres,
  the arm's strength idle); the empty and one-hand paths are untouched. Harness
  (simulated): seven new scenarios pass, and the 66 existing ones' 5432 results are
  unchanged to the last digit (run on two copies of the project differing only in this
  change); 65 of 73 pass, the eight failures unchanged from before.

  | Scenario | Result |
  | --- | --- |
  | two_hand_sword | right by the pommel leads, left by the guard: shares left 2.45, right -1.45; aim 1.6° off the grip points, 5.5° off the player's hands; left lets go, the right holds it rigidly, turned 0° |
  | two_hand_sword_swap | the lead lets go first: the left takes over rigidly, turned 0° |
  | two_hand_longsword | 13 cm between the hands: aim 1.1° off the grip points, 5.0° off the player's hands; the left hand raised 5 cm: 5.1° off; one wrist rolled 30°: the sword rolls 14° |
  | two_hand_bar_aim | 0.8 m bar, hands 0.6 m apart: points along the player's hands within 0.05°; the left raised 0.2 m, the same; one wrist rolled 30°, the bar 14°; shares 0.5 |
  | two_hand_share | 10 kg bar, hands 0.4 m apart: shares 0.5; the lead's shoulder and wrist hold nothing two-handed (47 and 20 N·m one-handed), and both hands dip 2 mm (3.5 cm one-handed). When the left lets go, the right takes all of it at once: the bar swings (up to 1.4 m/s, the hand dipping 4.2 cm) and is still 1 s later |
  | two_hand_pull_apart | the player's hands pulled 0.2 m, then 0.5 m apart each: both still hold it, on their shared targets, under 200 N; let go, it drops without a pop |
  | two_hand_close | palms 3 cm apart: no aiming, the lead keeps it welded |
  | two_hand_release_apart | 0.8 m bar held 0.5 m apart, the left leading; the player's hands pulled 0.1 m further apart each: both stay on their shared targets, under 50 N; the right lets go: the left takes the bar to its own hand, 0.1 m, at up to 1.3 m/s |
  | two_hand_close_apart | palms 3 cm apart, the player's hands pulled 0.1 m apart each: both stay on the shared target, under 50 N; the lead lets go: the other takes it rigidly, at up to 1.1 m/s |
  | two_hand_bar_yawed | the wrists turned 6° and -4° about the palms and trembling 0.2° a tick: raising the left hand 0.2 m rolls the bar 0.16° at most |

  The swords' short grips carry the blade as a lever that the solver does not converge
  at its 10 velocity steps: the hands sit 3-6 mm off their targets and the grip joints
  stretch 2-3 mm, so the blade points a few degrees off the player's hands. The player
  accepted this for the headset to judge. With 30 velocity steps (a diagnostic run,
  not adopted: it costs every body, unmeasured on the Quest) the blade came within
  about 0.6° of the grip points, but still 1.3-1.6° off the player's hands (the
  review's rerun; the first run's "both within 1°" held only for the grip points).
  Two-handed, the arm's strength does not dip or lag a held load; for two hands it is
  to be designed later. Relocation still does not drop grips (6.9).

  Review, the same day (a multi-agent review of the change; each finding rerun
  before it was accepted). Fixed:
  - The two wrists' roll is averaged on the circle. Averaged plainly, rolls either
    side of 180° gave a mean 180° off, and the object would spin about its grip.
  - Each wrist's roll is its twist about the grip line. A hand holds a handle with
    its Y nearly along it, so its Y seen across the line read a raised hand with 0.2°
    of tremble as 3.3° of roll; now 0.16° (`two_hand_bar_yawed`).
  - Grab points too close to aim drive to the shared target too. Chasing its own
    controller, the second hand fought the lead at 600 N once the player's hands
    parted (`two_hand_close_apart`).
  - The hand that takes over gets the whole load before its drive's tick,
    whichever hand's grab runs first.
  - A hand switching between its own target and the shared one is not asked to
    move at the jump's speed. Let go 0.1 m out of step, a bar was flung at 7 m/s;
    with the switch shaped by the arm's strength alone, at 3 m/s; now it moves at
    1.3 m/s, as the drive closes any 0.1 m gap (`two_hand_release_apart`).
  - The longsword scenarios start where the body can stand, at x 0.65 as the
    sword's do. At 0.75 the table pushed the body back 10 cm and the palms reached
    the grip short, so the longsword numbers above were re-recorded and the 5 cm
    limit on how far it lands aside restored.

  Not changed:
  - The reach limit still moves one hand's target alone when the shared target lies
    beyond that arm's reach, so the hands can strain at full stretch.
  - No scenario exercises the drive's full force on every axis while two-handed;
    the rule stays, as agreed.

  Harness (simulated): three new scenarios; all ten two-hand scenarios and the
  longsword's pass. The 65 scenarios this round leaves alone give all 5352 of their
  results unchanged to the last digit (A/B on two copies of the project). 68 of 76
  pass; the eight failures are the same as before.

  Headset: the session below.

- **Two-handed headset session, 2026-09-27 16:07** (`free_2026-09-27T16-07-30.csv`;
  free play with `-- --record-session`, 196 s; WiVRn, desktop, 72 Hz throughout).
  Player's report: "I am shocked how smooth this feels. Two handing objects is dang
  near perfect in its handling. There is 1 issue I ran into and its a small issue. I
  noticed with the debug visual on that grabbing objects can tend to cause the hand to
  twitch and jitter all over the place when the dot from the palm to the grabbable
  object is orange." Telemetry:
  - 14 two-handed holds, 100 s in all, all aiming; 7-10 cm between the hands on the
    shorter grips, 11-16 cm on the longer (the objects are not logged). No close
    grip. The right hand led 13 times; the left let go first 13 times.
  - Letting go with one hand: the other was 2-14 cm from its own controller and
    closed to under 1 cm in 55-195 ms, at 0.4-3.0 m/s (1.3-3.6 m/s beforehand in the
    faster ones, so partly the player's own motion).
  - Swings reached 11 m/s two-handed. Above 6 m/s the hands trailed their targets by
    9.4 cm (95th percentile), as one-handed (10.1 cm); the grip points drifted up to
    7.4 cm apart (3.5 cm one-handed), mostly the second hand on the longer grips.
  - The orange line is the pull-in. All eight pulls on a loose object took 3-21
    ticks. Of 20 second-hand pulls onto a held object, 10 lasted 0.6-4.5 s: the gap
    stuck at 1-8 cm, the drive at its 600 N cap, the hand's motion reversing almost
    every tick, the hand dragged 9-37 cm off its target (inference: the pull fought
    the lead's grip; the free-turning pull's anchor on the object sat where the palm
    was, so turning the object about the lead could move it without closing the gap).
  - Physics 1.27 ms a tick at the median, 2.6 ms at the 99th percentile, 6.1 ms at
    most after startup (desktop, not a Quest 3S figure).

- **The second hand joins the hold as it grips, 2026-09-27**, the player's design:
  "When 1 hand is already grabbing the object and the other grabs another spot, the
  object and physical hand holding that object need to accommodate for the new hand
  and act as if it is already attached (meaning it moves into position as if it
  already was being 2 handed) ... I don't want any fighting eachother. From the moment
  the second hand grabs it, it should already behave like it is being 2 handed."
  - A second hand's grip makes no joint and pulls nothing. If the lead holds the
    object, the shared target begins at once, the second hand's pose taken where it
    will hold the object (its grab point on the object's). The lead and the object
    move into that pose; the second hand rides the object, so it reaches its grab
    point even where the lead lags its own target (the lead's wrist gives 1.4° under
    a bar resting on the table at one end, 1.4 cm across 0.6 m).
  - At 5 mm it holds a point, and the lead aims. Its place in the shared frame is
    taken where it now holds the object, so the targets fit the grip joints exactly;
    the switch from riding to the shared target is not asked as speed
    (`HandDrive.retarget()`, as when two-handed begins or ends).
  - A second hand gripping while the first is still pulling the object in waits for
    it to be held. If the lead lets go meanwhile, the other pulls the object in as a
    first hand does.
  - Harness: the second hand gripping 8 cm beyond the handle (the old pull took 12
    ticks on the longsword and never locked on the sword), gripping 5 cm beyond it and
    drifting 10 cm further (stuck at 600 N before), and the longsword's tip resting on
    the table while the second hand joins.

  | Scenario | Result (10 velocity steps) |
  | --- | --- |
  | two_hand_reach_longsword | comes onto the handle in 10 ticks, no twitch, the hold quiet (it rang with the old pull); 1.6° off the grip points, 6.0° off the player's hands |
  | two_hand_reach_sword | 9 ticks; 3.4° / 4.8° off (the old pull never locked) |
  | two_hand_reach_sword_drift | 8 ticks, under 110 N; 2.7° / 7.0° off |
  | two_hand_table_join | **fails**: while the tip rests on the table the two hands trade its load every tick (1.2 mm a tick, 42 turn-backs in 43 ticks); lifted, it is steady |
  | two_hand_sword | 3.0° off the grip points (1.6° before), 4.2° off the player's hands (5.5°) |
  | two_hand_longsword | 2.0° / 4.2° (1.1° / 5.0° before); the left raised 5 cm: 3.7° off |
  | the bars | 0.4-0.6° off the player's hands (0.02° before); everything else as above |

  Review, the same day (a second multi-agent review; each finding rerun). Fixed:
  - The lead switches to the shared target on the tick it locks, as the second
    hand does, and `_joining` clears once the hand holds.
  - Doc comments: `two_handed` is on from the second grip; `min_aim_span` compares
    hand centres; the size of the lock's jump (1 cm on the sword, 2 cm on a bar
    gripped 0.6 m apart while it lies on the table).
  - Harness: the reach cases at 8 cm and the drift and table cases (above); the
    stretch metric measured at each joint's own point (`HandGrab.joint_point`); the
    object's spin recorded while joining.

  Learned (measured in scratch copies):
  - At Jolt's 10 velocity steps the two-hand loop with a lever load does not
    converge, and how far it falls short follows the order Jolt solves the joints
    in, set by their creation history, not the targets (they fit the joints to
    0.01 mm). Remaking one hold joint in place moves the sword between 1.4 and 2.7 mm
    of stretch. The second hand no longer making a pull joint changed that history:
    that, not the targets, is why the swords now stretch 2.7-2.9 mm (1.4-1.5 mm
    before). At 15 steps the reach-longsword ringing stops in every variant; at 30,
    stretch is 0.7-0.9 mm in both codes. The short-grip limits are 4° off the grip
    points and 9° off the player's hands.
  - The second hand locks up to 5 mm short of where the seat put it, and that stays
    in the aim for the hold: 0.4-0.6° on the bars, 1.9-2.9° on the swords' grips.
    Taking only its span from the lock fixes the bars but, at 10 steps, brings the
    reach-longsword twitch back.

  Harness (simulated): the 66 scenarios outside two-hand holds give all 5432 of
  their results unchanged to the last digit (A/B on two copies of the project);
  71 of 80 pass: the eight failures from before, and `two_hand_table_join`.
  Headset confirmation pending: the second hand gripping a held weapon off its
  handle, while moving, and with the tip on the table (watch the orange line); a
  quick tap of the second grip (the object swings into the two-handed pose and
  back).

  Open, for the player to decide:
  - **The table-rest fight** (`two_hand_table_join`). More velocity steps make it
    worse (2.0 mm a tick at 15, 2.3 at 30). Re-seating both hands where they are at
    the lock stops it, but keeps the table's offset for the whole hold (the hands
    stay off the player's after lifting) and brings the reach-longsword twitch back.
    Giving a two-handed carrying drive the free-air damping rule stopped it in one
    variant only; not adopted.
  - **Velocity steps** (a global solver cost, unmeasured on Quest 3S).
  - **A one-hand pull stall**, from before this change: a grab 5 cm or more to the
    side of a 4 cm bar leaves the pull 0.8-1.5 cm short, with no contacts, and never
    locks; a second hand waiting on it lets go if the object is carried 12 cm from
    it.
  - **Harness order**: at 10 steps the short-grip numbers depend on which
    scenarios ran before in the same process; a fresh physics space per scenario
    would remove that but moves existing results (palm_slide would fail).
  - The second hand joining beyond its arm's reach never locks (low).

- **Joining headset session, 2026-09-27 17:29** (`free_2026-09-27T17-29-30.csv`, 137 s;
  WiVRn, desktop; started at 120 Hz, 72 Hz from 0.2 s). Player's report: "Joining feels
  smooth now, the orange line is gone. One issue I noticed is when picking up to 10kg
  box and holding out my hand, my wrist jitters like crazy." Telemetry: 24 grabs; the
  second-hand joins took 4-20 ticks, 0-3 reversals, all held (at 16:07, 10 of 20
  second-hand pulls stuck for 0.6-4.5 s). The table-rest fight showed twice for
  about a second in a two-handed hold (97.2-98.2 s, 100.5-102.0 s): the load swapped
  hands every tick, then one drive sat at its 600 N cap and the other near 23 N,
  both hands 5-16 cm off their targets, with nothing touching the hands (inference:
  the longsword's tip on the table, `two_hand_table_join`).

- **Heavy-hold wrist buzz, 2026-09-27**, from the player's report above. The recorder
  gained wrist columns (each hand's spin and whether it turned back, its turn error,
  its target's per-tick step and turn, which on a still hand is the tracking's
  tremble, and the held mass and how far its centre is from the hand's), and a
  session recorded the player repeating it (`free_2026-09-27T17-46-46.csv`, 40 s):
  - Three episodes holding the 10 kg box (9.0-11.0 s, 17.0-17.5 s, 30.5-33.0 s): the
    wrist spinning 15-22 rad/s and turning back every tick (36 Hz), 10-40° off its
    target, the drive at 250-900 N and 5-9 cm off, the body shaking with it; the
    player's hand still meanwhile (under 1 mm and 0.6° a tick). Started by a grab as
    the box lifted off, or a quick wrist turn (5-12° a tick); each died out on its
    own after 0.5-2.5 s. Calm between.
  - Not tremble: harness hands trembling 0.1-1 mm and 0.3-1° a tick never did this.
  - Reproduced in the harness with no other change than where the palm grips: by a
    top corner, the box's centre 10 cm from the hand's (6.7 cm gripped centrally),
    204 ticks in a row, 16 rad/s, 600 N, 5 cm off, the hand's centre swinging on an
    8 cm radius (headset 6.3-7.9 cm). Edge and central grips never sustain it.
  - Cause (measured by differencing twin runs, and ablations): the drive does not pin
    the hand's centre, so the hand and a heavy held object turn about their shared
    centre of mass, and the hand's centre swings round it. The wrist's steadying
    torque took its measured half at the hand's centre: one tick late, it fed that
    swing back, and with the wrist's turning sized for the hand's centre the loop
    passed its limit. (That the headset grips were near a corner is inference: the
    recording had no offset column; it has one now.)
  - Fixed: the measured acceleration is taken where the hand and what it holds share
    their centre of mass (`HandDrive._turn()`; one line and one remembered spin).
    Tried and not taken: steadying from the asked acceleration only (the swing's
    tilt doubled, and the 2 kg flick swung past 6.8°); turning inertia about the
    shared centre (the flick failed, 15 kg still buzzed); the full force limit on
    every axis (only shortened it).
  - Harness (simulated): `grab_hold_out_heavy_corner` (new): 204 ticks of buzz before,
    none after. In the reviewers' scratch runs every reproduction and stress case
    (15 kg by a corner, grabs yanked off the table with the body swaying, wrist flicks,
    72/90/120 Hz physics) went from 27-310 ticks to 0-2. Swinging and whipping the
    10 kg box tilt the wrist 2.9-3.1° (3.0-3.1° before); the 2 kg flick lags 8.6°
    (9.2°) and swings past 6.4° (6.2°, limit 6.5). A/B on two copies of the project
    (with and without the fix and the new telemetry): the 53 scenarios that never
    hold anything are unchanged to the last digit; the 28 that hold something change
    in their numbers but none passes or fails differently (19 failed criteria either
    way, all failing before). With the old wrist, `grab_hold_out_heavy_corner` fails
    (204 ticks, 20.9 rad/s).
  - Headset confirmation pending: grab the 10 kg box by a corner and by its middle,
    hold it out, sway, yank it off the table, flick the wrist while holding it; swing
    and whip it; flick the 2 kg box.

- **Handle grab type, 2026-09-27**, at the player's request: "I have handles on these
  sword that I would like to give the grab type 'handle'. It should only allow hand
  poses to hold the object straight up or down relative to the handle. The hand should
  only be able to hold it from the side of the handle too. This grab type should be
  applicable to any grabbable type of object. The grip should allow the grab to attach
  anywhere on the handle just with those predefined object rotations." Built as 6.7's
  grab by a handle (`Grabbable.handles`, `HandGrab._take_seat`, `_turn_in`). Free grabs
  keep their pull and hold; the release's 1 cm clearance and the regrab while clearing
  (6.7, release) apply to every grab.
  - My reading, to confirm with the player: four seats (up or down, the palm on either
    flat), so a turn about one axis is at most 90° (120° at worst) and the palm never
    rests on the narrow edge; the roll is fixed by the shape's Z, round handles too;
    the palm is kept wholly on the handle; a hand beyond an end cannot hold the handle
    there; blades, guards and pommels are still grabbed as met (a hand 5-8 cm off the
    grip may take the guard or pommel); the turn's torque does not push back on the hand;
    a second hand joining is turned to its seat (the hand, not the object, which the
    first hand holds), so it may sit off its controller for the two-hand hold.
  - Tried and dropped: joint angular motors for the turn (above); the handle 2 cm
    toward the fingers (the fingers closed round the grips no further, 73/74/69° against
    74/70/69° on the middle finger, and two hands on the sword aimed up to 6.4° off
    their grab points; a hand joining 8 cm off the longsword's handle strained to 614 N);
    a turn that followed pull_gain whatever the torque (the longsword swung up to 31°
    past its seat and welded while turning); locking the seat within 1-2 mm to align
    two-hand holds (no better).
  - Harness (simulated, not the headset): 90 scenarios. The 9 that failed before still
    fail, 19 criteria (`two_hand_table_join`'s three now include a hand ringing at rest
    in place of one twitching as the hands come together). 64 of the 81 older ones are
    unchanged to the last digit; four free grabs change only in how often the hand
    touches a let-go prop, and `fingers_grip_box`'s `prop_push_hands` changes between
    runs with no change at all (1.44 or 0.097). Eight new one-hand handle scenarios pass:
    turned 45° and 135° (blade toward the little finger; 0.22 s), 30° across the fingers
    (seats once lifted off the table, 0.67 s), 80° on the longsword (0.53 s, 0.8° past its
    seat), palms near the grips' ends (the fist moved in), a palm beyond the dagger's
    butt (no grab), a 1 kg code-built cylinder. Picked up square, the sword and longsword
    lock in 0.11 s as before, the dagger in 0.125 s (0.11 before).
  - Open: in two-hand holds each hand sits 8.1-8.7° off the handle (the swords, the
    window that opens as the join's swing ends; settling to 7.1-7.9°), and about 21° with
    the controllers 7 cm apart: `two_hand_longsword_beside` fails on that, on steadiness
    and on aim, with or without its fists kept a palm's width apart (which it checks,
    and that passes). The hand left holding keeps about 7° when the other lets go. Not
    the locks' leeway (tested); inference: the object aims along the line between the
    player's hands while each hand keeps its own turn. The sword's grip (14.6 cm) is
    shorter than two palms (16 cm), so its fists overlap by at least 1.4 cm. A seat the
    table blocks (a blade turned into it) keeps the object on the pull, soft, until it
    is lifted clear; one too heavy for 10 N·m would stay there. A grip let go mid-turn
    leaves the object its turn's spin, as a pull let go leaves its speed.
  - Headset checks pending: pick each weapon up by the grip at various angles (the
    snap's speed; the fingers on the grip; a long blade swinging near the face while
    it turns in), also while moving the wrist; near the pommel and the guard; reversed
    grips; the dagger from its butt; blades and guards still grabbed freely; two-handed
    on the longsword and the sword, then let go with either hand; set a weapon down and
    pick it straight back up; let go and drop them (no fling).

- **Grab point toward the knuckles, 2026-09-27**, from the player's first try of the
  handle grab ("Seems to work pretty good on the sword handles ... grabbing things in
  the center of the palm area feels slightly off"): the palm's grab point moved 2.5 cm
  from its centre toward the knuckles for every grab (`HandGrab.grab_forward`), so a
  handle sits under the fingers' roots and a box's face meets the fingers' end of the
  palm. Harness (simulated), on a copy of the project with the level as it was before
  the 22:05 save below: one-hand grabs unchanged in outcome (pulls 0.10-0.15 s; the
  turned handle grabs lock sooner, the longsword's 80° in 0.47 s); the sword held in two
  hands is held further off straight, its hands 16.8° off its handle and aiming 9.1° off
  their grab points (8.7° and 2.6° at the palm's centre; 10.1° and 3.8° at 1 cm, 14.4° and
  7.5° at 2 cm), so `two_hand_sword` and `two_hand_sword_swap` fail; the longsword's two
  hands stay within their limits (9.8-10.4°, 4.0°). Inference: the handle hangs that much
  forward of the line between the hands' centres, where the two-hand joints are.
  The value is the player's to set by feel; the two-hand cost is part of the open
  two-hand alignment question above.
  - The level saved at 22:05 (terrain heightmap and a stone texture set) makes the
    harness fail throughout on the live tree (193 criteria: the body falls at the start
    points, the weapons lie 0.2 m below where the harness takes the tabletop to be).
    Not investigated further; the harness needs the test arena as it was, or its
    positions updated.

- **Swords lean forward in the fist, 2026-09-28**, at the player's request ("I want the
  swords to lean forward slightly"); decided with the player: a lean per object
  (`Grabbable.handle_lean`, 0 by default), 15° on the sword and the longsword. The
  handle's seat turns the fist's grip line (hand Y) toward the fingers by it; a reverse
  grip leans the other end toward the wrist, along the same line. The player had also
  set `grab_forward` to 3.5 cm. Harness (simulated), on the copy with the level as it
  was before the 22:05 save, 3.5 cm both runs: one-hand handle grabs lock within
  1.3° of the leaned seat, the swords picked up in 0.15-0.25 s, turned in 0.18-0.69 s;
  the dagger and the cylinder unchanged. Two hands: at 3.5 cm and no lean the sword's
  hands sat 25° off its handle and the longsword's 12-13° (both failing); leaned, the
  sword 16-17° (still failing) and the longsword within its limits;
  `two_hand_reach_sword_drift` now fails (its hands 13.5° off, aiming 8.6° off its grab
  points). The weapons are let go about the grab point's offset toward the fingers
  from where they lay, which the handle scenarios' drop check now allows for.

- **Harness on the rebuilt test level, 2026-09-28.** The player rebuilt
  `scenes/level.tscn` as a test level (flat floor, steps, a 15° and a 30° ramp, a
  climbing wall, a 3 m table, a pit with a hole and one 30° ramp down to its floor 4 m
  below, ore veins and a tree to test later) after it had become a world. Its pieces
  were named (Claude renamed them in the file and reloaded it in the editor) and two
  markers added; the harness now lays the level for each scenario by those names
  (section 9) instead of fixed positions. Changed with the level: `ramp` and
  `lower_ramp` walk the pit's 30° ramp (down 4 m and back; up from the pit's floor,
  starting 0.3 m before the ramp's foot), `slope_walk` stands 2 m down `Ramp15`, and the
  table's scenarios are laid by the boxes. Harness (simulated): 90 scenarios, 46
  criteria in 18 scenarios failing, all the walking, pit, wall, table-edge and respawn
  scenarios passing, CHECKLIST passing. Failing with the level: `hand_table_press`
  (the pressed hand drifts 1.2 cm; passes run alone, so it depends on what ran before)
  and `palm_slide` (the palm stays on the table at its resting height throughout, but
  the touch it reports flickers: the table stands 1.002 m, and at 1.0 m it passes,
  while the weapons, laid for 1.002 m, then sink 1.1 mm into it). Borderline:
  `two_hand_longsword` (4.5° off its grab points, limit 4) and `handle_sword_tilt`
  (3.0° and 3.5°, limits 3). The rest fail as before the level changed (the 9 older
  failures, and the two-hand holds the 3.5 cm grab point costs).

- **Climbing, step 1, built 2026-09-28** (rung 6's world holds, at the player's
  request: "fully climb and throw myself"; decided with the player: one hand hangs,
  two haul fast, a pure-physics throw, legs and mantling next). The four red boxes on
  the wall, which were part of the `Static` combiner, are now `Holds/Hold1`-`Hold4`
  (`StaticBody3D`s at the same places, the same red material, each with a
  `Climbable`). The grip takes holds (6.7), the drive climbs (6.6.3), locomotion stands
  down while climbing (6.5), and recovery lets go first (6.9). The snapshot carries
  `climbing` and `grab_on_hold`; the recorder `left_on_hold`, `right_on_hold`.
  Harness (simulated): 9 climbing scenarios added (`climb_*`, at Hold1), all passing
  (numbers in 6.6.3); the 90 older scenarios give the same summaries and the same 45
  failing criteria as before the change, to the digit. Found on the way: through a
  free hand, the arm's motor could not hold the body (the hand is now frozen while it
  holds). Headset: pending (list in the step's report).
  - **Headset session 2026-09-28 23:09** (79 s free play, `--record-session`; Quest 3S
    over WiVRn on the desktop, so no Quest timings; 72 Hz after 0.1 s at 120). The
    player's report: "felt pretty good" (of earlier, unrecorded editor runs). Telemetry:
    four climbs, the feet up to 4.1 m (hands at Hold4). Hauling behind the hands, one
    arm rose at 0.45 m/s (median, 19 s) and two at up to 1.23 m/s, as designed; the
    player's hand ran a median 0.16 m (p90 0.55 m) from the hand on the hold. Of 21 hold
    grabs, 16 locked within 0.11 s, one after 0.85 s and 4 never did (all the right
    hand): gripped 1-3 cm from the hold, the player's hand moved on and the arm's drive
    (600 N) drew the hand off it faster than the grip's pull (400 N per axis) brought it
    in, so it never came within the 5 mm lock; twice the other hand then let go and the
    player fell (2 m and 3.5 m). Raising the holding hand while still gripping lowers
    the body 1:1 (1 m at 2.4 m/s at 15.4 s, clean), but once, raised fast, the drive
    pushed the body down at its whole strength plus gravity to 6.0 m/s and one arm could
    brake it at only 6.6 m/s² (1,235 N against 735 N of weight): it overshot the hand
    by 1.5 m and hit the floor from 2.1 m. After the one let-go while rising (1.0 m/s),
    both hands stayed pressed on the hold and held the body up for 0.6 s, as on a
    table. Four falls landed at 4.4-7.7 m/s with no fade. Not exercised: walking back
    while holding (head lead at most 0.16 m); the stick and A while hanging (no input
    column; nothing moved). Physics 1.49 ms mean while climbing, 1.46 ms otherwise
    (desktop).
  - **Fixed after the session, 2026-09-28, the player's choice:** a hold grab snaps the
    hand onto the hold as the grip closes (no pull), and the arms never push the body
    down, lowering it no faster than 2 m/s (6.6.3, 6.7). Two harness scenarios
    reproduce the session's failures (`climb_grab_moving`, `climb_lower_fast`; on the
    code before, a lock 1.1 s late and a 3.5 m/s sink at 26 m/s²) and pass now; the
    other 9 climbing scenarios pass and the 90 older ones are unchanged. Headset:
    pending (hand over hand while moving; raising a holding hand fast; the post-release
    hover, kept for step 2).
  - **Headset session 2026-09-28 23:25** (56 s free play, recorded; WiVRn on the
    desktop, 72 Hz throughout), with both fixes. All 28 hold grabs locked on the tick
    the grip closed, none failed (the hand snapped 0.5-9.7 cm, median 2.7 cm; 6 of 28
    over 5 cm). Every lowering by a raised hand was held to 2.00 m/s, never faster than
    it falls. Hauls as designed (one arm 0.45 m/s median, two 1.18 median, 1.23 at
    most). Twice the player let go and caught a hold on the way down, at 5.4 and 4.5 m/s:
    one arm braked it at 6.5 m/s² (its 1,235 N less the weight), not enough to stop
    before the floor, so the body fell up to 1.8 m past the hand on the hold, which let
    go only as the body landed, at 2.3-2.5 m/s instead of about 7. No throw was tried.
    Physics (Godot's once-a-second sample) 1.5 ms median, 1.8 ms p95, one 7.5 ms sample
    at 31.2 s, not attributable at that sampling (both hands had just let go and one
    grabbed again).

- **Climbing, step 2 (legs drawn up, mantling), built 2026-09-28** at the player's
  request, decided with them (6.5 `LegTuck`, 6.1, 6.10, section 7). The level already
  had its mantle: the Wall's top has a 2 m wide `Notch` down to 5.0 m, the `Platform`
  behind it level with its floor, and Hold4 on its lip; in the first headset session the
  player hauled their feet to 4.1 m on Hold4, 0.9 m short of getting over. Harness
  (simulated): 3 scenarios added and passing. `climb_mantle_notch` (starting on a stool
  at 3.3 m, taken away once both hands hold Hold4): the legs draw up 0.80 m, the hands
  pulled down 1.0 m and back 0.7 m haul the body over the lip, and let go it stands up
  onto the Notch's floor at 1.00 m/s, ending at 5.000 m with its legs down.
  `climb_mantle_table` (pressing, not holding): pressed 0.5 m into the table the legs
  draw up 0.68 m, leaning on over it and lifting the hands it stands up onto it at
  1.0 m/s (one tick at 1.05), ending at 1.002 m. `climb_land_on_feet`: hanging 0.3 m up
  with the legs drawn up, lowered onto the floor it lands on its feet while still
  holding. `climb_hang_two` also checks that let go in the air the legs just drop. The
  other 101 scenarios match the run before (the same 45 failing criteria; `vault` and
  `climb_tracking_loss` 0.1 s and 0.03 s longer airborne, the drawn-up legs off the
  ground). Headset: pending.
  - **Headset session 2026-09-30 18:48** (127.5 s free play, recorded; WiVRn on the
    desktop, 72 Hz but for 0.1 s at 120 at the start and 0.08 s at 90 during a tracking
    loss, none while climbing). Telemetry: both climbs to Hold4 ended in a mantle over
    the Notch's lip: drawn up 0.79-0.81 m, the body hauled over the lip came to rest on
    the Notch's floor, and let go it stood up 0.8 m at 1.00 m/s onto it (5.00 m), the
    player already walking on with the stick as it rose; twice more the player mantled
    onto the table by pressing (drawn up 0.66-0.69 m, standing at 1.01-1.03 m). After
    each notch mantle the player ran back off the lip and jumped down (5 m falls,
    landing at 9.9 m/s, no fade). All 22 hold grabs locked on the grip's tick (snaps
    0.8-9.3 cm). Let go in the air (2.46 m), the legs dropped with no lift. Lowering
    onto the floor while holding was not tried. Four times the legs drew up for one or
    two ticks as a climb left the floor (fixed: above), which `climb_pull_two` and
    `climb_throw` reproduced; a check now counts such flickers (none), and the full
    harness is otherwise unchanged. The player: "It felt good, standing up was
    comfortable. I believe the legs should lift up slightly higher so it is easier to
    mantle things but other than that it felt great."
  - **Legs drawn up higher, 2026-09-30**, at that request: `tuck_share` 0.47 to 0.53
    (0.80 m to 0.90 m at a 1.70 m head), with the hips riding up while drawn up (6.5).
    Harness (simulated), the Notch mantle by hauling up less: the old tuck fails at
    0.85 m and mantles at 0.9 m; the new one fails at 0.75 m and mantles at 0.8 m, so
    about 10 cm less. `climb_mantle_notch` now hauls 0.85 m (fails on the old tuck).
    On the level as it was, every other scenario was unchanged. The player has since
    put `Hold5` on the wall at 1.0 m under Hold1: walking into the wall now meets it
    (`wall`, `wall_through`, `walk_push_crate` changed, still passing), and the free hand
    of the one-hand climbing scenarios, resting in front of the body at 1.0 m, pushed
    on it and added lift (`climb_pull_one` rose at 1.13 m/s); that hand now rests down
    at the side. Full harness on the live tree: the same 45 failing criteria, all 14
    climbing scenarios passing.
  - **Headset session 2026-09-30 19:10** (70.6 s free play, recorded; WiVRn on the
    desktop, 72 Hz after 0.1 s at 120), the legs drawn up higher. The player: "It felt
    really good"; Hold5 is theirs for testing climbing down to the floor. Telemetry:
    a Notch mantle (drawn up 0.83 m, stood up onto 5.00 m); jumped back off it and
    caught holds twice on the way down with both hands, at 5.0 and 5.5 m/s, braked at
    about 23 m/s² (two arms' 2,470 N less the weight); lowered onto the floor from
    Hold5, the legs came down as the feet met it and the body landed on them while
    still holding (twice, hopping about 5 cm up and down). All 15 hold grabs locked on
    the grip's tick. No one- or two-tick tucks (the lift-off fix held); once the legs
    dropped for one tick between letting go of a hold and pressing on it (the press is
    read from the last tick's hands, and a frozen hand reports no contacts). Physics
    1.36 ms mean while climbing (desktop).

- **Snap turning, built 2026-09-30** (rung 6's `Turn`, snap only; decided with the
  player: 45°, and snapping must not jank the physical body, held objects or climbing).
  6.5 `SnapTurn`, 6.10, section 7. Harness (simulated): 7 scenarios added and passing,
  each checking around every turn that the view turned 45° in one tick about the head's
  centre, which went on as it was (0.0000 m; 0.0018 m walking); the feet turned with it
  (0.00°); the body did not jump; nothing pushed the view after (0.0000 m); a hand stayed
  on its target (at most 1 mm further off); what a hand held stayed in it with no speed
  added; a hanging body stayed still (at most 2.9 mm, the box in its other hand
  settling). `turn_snap_stand` turns four times (one turn per push, the stick held 1 s
  once) and ends facing where it began; `turn_snap_walk` walks straight on the way the
  view now faces (0.00°); `turn_snap_reach` (hands out in front), `turn_snap_sword` (held
  in one hand: 0.000 m, 0.00°), `turn_snap_longsword` (both hands, held steady: 0.90°
  of settling in the hands over 0.5 s against 0.09° without a snap; snapped while the
  second hand had only just joined, 2.5° against 0.66°), `turn_snap_climb` (hanging by
  both hands, right then left) and `turn_snap_climb_prop` (one hand on the hold, a 2 kg
  box in the other). The other 104 scenarios give the same summaries and the same 45
  failing criteria.
  - **Headset session 2026-09-30 19:36** (114 s free play, recorded; WiVRn on the
    desktop, 72 Hz but for a moment at 120 at the start and at 90 during a tracking loss
    before any snap). 62 snaps: 26 standing (once eight in 1.2 s), 13 walking, 16 with
    the sword in one hand or the longsword in both, 20 hanging from holds. The body never
    jumped (at most 3 mm in a turn's tick) and nothing pushed the view after a snap. The
    hands turned with each snap exactly (45.0° in its tick, no added turn error); the
    right hand's 2-13° behind its target after quick snaps was the wrist itself turning
    1-4° a tick as the thumb flicked the stick. What a hand held stayed where it was
    (0.0-1.6 mm after a snap with none following it); the recorder shows a one-tick blip
    of 18-30 mm in the held mass's distance from the hand after each snap (inference:
    the physics state's centre of mass is read at its old angle in the turn's tick; the
    recorder also takes the hands a tick late, running before them). Hanging from both
    hands, ten snaps held; from one hand, the fifth snap in a row left the player's hand
    1.3 m from the hold and the arm, held past its reach, let go 0.26 s later (the
    0.25 s rule), and the player fell. The player: "felt clean, didn't notice the eye
    swing. leave the one-hand release. Turning while climbing was odd because it kept my
    position and turned my skeleton but the physical body didn't attempt to follow the
    skeleton." Decided with them: the body slides round the holds after a snap (6.5;
    measured in a scratch copy first: 25 cm over 0.3 s at up to 2 m/s, a box in the
    other hand jolted 5°). Harness: hanging, the climb's offset is back within 0.03 m in
    0.5 s (0.000-0.025 m), sliding 0.24 m at most at 2.1 m/s at most; every other check
    and the 104 older scenarios unchanged.
  - **Headset session 2026-09-30 19:53** (67 s, recorded; WiVRn on the desktop, 72 Hz):
    17 snaps, 11 of them hanging from holds by both hands, all held through. The body
    slid 45-53 cm after a single snap, at up to 3.3-3.7 m/s, settled in about 0.3 s:
    twice the harness's, the player's hands further from the head (overhead, at arm's
    length) than the simulated player's, so a 45° turn swings them further. Quick snaps
    (0.15-0.3 s apart) started before the slide had settled. The player: "That feels
    great. I do think the 1 handed climbing is a little bit too slow." Decided with them:
    `climb_strength` 950 to 1,200 N (6.6.3). Harness: one arm hauls at 0.77 m/s, two at
    1.39 m/s (the checks now work the speed out from the drive's values); a two-handed
    throw leaves at 1.45 m/s and rises 10 cm; one arm stops a fast-lowered body 5 cm past
    the hand (18 cm before); only the climbing scenarios' numbers changed, all passing,
    the same 45 failing criteria elsewhere.
  - **Headset session 2026-09-30 20:00** (47 s, recorded; WiVRn on the desktop, 72 Hz),
    1,200 N arms. Hauling behind the hands, one arm rose at 0.78 m/s (median, 5 s) and
    two at 1.37 m/s, as designed; all 10 hold grabs locked on the grip's tick; lowering
    by a raised hand held to 2.0 m/s, never faster than a fall; one climb ended in a
    Notch mantle (stood up 0.84 m). No throw was tried. The player's account: pending.

- **Throwing props, built 2026-09-30** at the player's request ("It should use the brief
  history of the objects velocity to get a accurate reading on the velocity and
  direction"; decided with them: a curve fit through the prop's own recent motion). 6.7
  Throw. Measured first on two new harness throws (the 2 kg box wound up over the
  shoulder and thrown overhand, let go near the top of the swing or late): released as
  before, the box kept its last step's velocity, lagging the player's hand by 20 % on
  the upswing (inference: the arm's strength) and running on past it on a late
  release; plain averages of its history lagged further, and the fit's window was
  chosen from 0.05-0.1 s. Harness (simulated): `throw_box_overhand` leaves at 5.58 m/s,
  2.1° off the player's hand (6.53 m/s), `throw_box_late` 7.99 m/s, 1.3° off (7.07);
  both checked within 3° and 20 %. The other 111 scenarios unchanged but for 0.01 m/s in
  one that drops a box. Headset session 1 (the player: "The throws feel fine now!"; so
  the late releases and the flicked sword below are left as they are). Telemetry: 11
  throws over 2 m/s and 18 gentle lets-go of the 5 and 10 kg boxes (these left at 0.04-2.1
  m/s, near the hand's own speed). The grip opened 1-6 ticks after the controller's
  fastest point, by when it had slowed by up to 68 % (a 2 kg box: 5.6 m/s peak, 1.8 at the
  release, thrown 2.5). Two sword throws with a hard wrist flick (the controller turning
  48-53 rad/s) left at 17.2 and 19.7 m/s. Reproduced in the harness (`throw_sword_flick`,
  measured, not checked): with the wrist turning ~45 rad/s the sword's centre of mass,
  about a blade's half-length out, swings round the hand, so its speed changes from tick
  to tick (11.0, then 8.1, then 2.6 m/s); let go mid-flick, the fit read 12.3 m/s against
  the sword's own 11.0. Recorder column `*_throw_own` added (the prop's own speed at the
  release) to measure the fit against it in the headset.

- **Blunt strikes, built 2026-09-30** (rung 1 of the strike model, `documents/strike_model.md`;
  6.7 Strike).
  - **The request:** a physical weapon model for slash, stab, lodge and blunt across
    cloth, wood and stone.
  - **Decided with the player:**
    - blunt first, from every physical object ("Even fists");
    - a readout only;
    - a slash is a plain hit ("No forced stop or pass through");
    - thickness only for stab;
    - fixed test posts.
  - **Built:**
    - `Striker` on the five weapons, the level's three boxes (which now report 4
      contacts) and both hands;
    - `Strikeable` and `StrikeMaterial` (cloth 1 J × 1.0, wood 2 J × 0.8, stone
      6 J × 0.4, starting values);
    - the posts scene `scenes/props/strike_targets.tscn`, instanced at (3, 0, -3.6);
    - `HandStrikes` per hand;
    - snapshot strike fields and recorder columns `*_strikes`, `*_strike_source`,
      `*_strike_energy`, `*_strike_damage`, `*_strike_speed`, `*_strike_mass`,
      `*_strike_material`;
    - `Analysis.strikes`, with `analyze_session.gd` printing the list.
  - **Step 0** (scratch project): the Jolt facts in section 13.
  - **Harness (simulated):** 13 new scenarios (`strike_*`), all passing; the measured
    strikes are tabled in the strike model doc.
    - The fist meets 0.96 kg at 5.5 m/s (14.5 J: cloth damage 13.5, stone 3.5).
    - The box dropped 0.5 m strikes with its whole 2 kg at 3.22 m/s, 10.3 J against
      m·g·h 9.8 J.
    - The one-hand sword meets 0.64 kg near its middle; the two-hand longsword, thrust
      along its length, meets 2.72 kg.
    - A palm pressed in at 0.2 m/s and a sword let down onto stone do not strike again.
    - The thrown dagger strikes once, counted for the hand that let go, glancing at
      2.8 m/s (0.98 J, under cloth's threshold).
    - Measured, not checked: a sword spinning free at 20/40/60 rad/s was always caught,
      but at 40 rad/s first seen 9.4 cm into the dummy, reading 6.7 m/s.
  - **A/B on scratch copies:**
    - Stages 1 and 2 (the classes, posts, weapon and hand Strikers, recording) left
      all 114 earlier scenarios identical to the last digit.
    - `fingers_grip_box` flips 0.111/0.125 for `prop_push_hands` between identical
      full runs of the same copy (seen twice), and is always 0.125 run alone: it
      depends on the scenarios run before it.
    - Stage 3 (the boxes reporting contacts): `palm_push_box` pushed the box 2.4 mm
      less over 0.18 m, its hand ended 0.16 mm further and its wrist 1.1° further off
      its target, and `grab_picks_closest` moved by 10⁻⁷ m. No check changed (the same
      45 failing criteria), and CHECKLIST and GUIDED still pass.
  - **Headset confirmation pending.** Free play with `-- --record-session`: punch each
    post softly and hard; hit each with the sword's flat and edge, the axe, the pickaxe
    and the longsword two-handed; throw a box and the dagger at each; lay a weapon on
    the stone. Then: do the readouts match how hard each blow felt, and did each blow
    register once?
  - **Headset session 1, 2026-09-30 22:46** (`free_2026-09-30T22-46-27.csv`; free play
    with `-- --record-session`, 216 s; WiVRn, desktop, 72 Hz throughout).
    - **Telemetry:** 204 strike rows make 185 strikes, 19 of them two-handed and
      logged on both hands.
      - Fists: 45 strikes, median 12.8 J at 5.2 m/s, meeting 0.97 kg (0.76-1.00).
        All 41 fist approaches that came within 10 cm of a post faster than 1.5 m/s
        struck; none were missed.
      - Held weapons struck at a median 8.4-13 m/s, up to 24 m/s, with a median 32-77 J
        per weapon and up to 326 J.
      - The two-handed longsword met a median 0.55 kg, lighter than the one-handed
        weapons (0.8-1.5 kg). The inference is that its blows landed toward its long
        tip.
      - Light blows: 12 of 44 held strikes and 4 of 17 punches on stone fell under its
        6 J threshold.
    - **Found:**
      - Three bounces struck again 0.12-0.14 s after a blow (0.19, 1.24 and 12.3 J),
        just past the 0.1 s re-arm.
      - Three times the hand holding the dagger struck the post 20-40 ms after the
        dagger did, so one blow counted twice.
      - Only two let-go strikes were recorded, both on stone: 1.45 kg met at 4.4 m/s,
        and 9.0 kg met at 4.7 m/s. The inference is the light box and the heavy box.
    - **Physics:** 1.50 ms a tick on average, p99 1.79 ms, after the first second
      (desktop, not Quest 3S).
    - **The player's account:** "The readout felt accurate. Every blow read something. All blows counted 1 time but there were a few that bounced and hit a second time (which was fine). I did throw stuff and it felt fine."
    - **Resolution:** rung 1 is accepted.
      - The bounces are kept, and the 0.1 s re-arm is unchanged.
      - The three dagger-and-fist pairs in the telemetry did not register with the
        player as double counts, and are left as they are.
      - Of eight lets-go, three were throws (6.5-8.4 m/s); two struck the stone within
        0.15 s, and the other reached no post.
      - Next: the sharp kinds (R2), discussed before building.

- **Sharp damage types, built 2026-10-01** (rung 2 of the strike model, the last;
  `documents/strike_model.md`; 6.7 Strike).
  - **Decided with the player:**
    - "There will be no cutting. It will simply be different damage types. There won't
      be physically different effects to the types of damage." The planned lodge
      sticking and stab pushing-in are dropped.
    - A weak sharp strike stays its type.
    - The pickaxe's pick stabs.
    - Alignment is forgiving.
    - Thickness: not yet.
  - **Built:**
    - `Sharp` (a `Marker3D`) features on the weapons: blade edges (slash) and points
      (stab), the axe's bit (lodge), the pickaxe's pick (stab) and adze (lodge).
    - The `Striker` gives each strike the type of the best-fitting feature: within reach
      (2 cm for an edge, 3 cm for a point), working into the surface, within 50° (edge)
      or 35° (point) of the blow. It tries the step's start and end poses, since contacts
      are found at either.
    - `StrikeMaterial` gets per-type takes, threshold and damage. Sharp types start equal
      to blunt; stone takes none.
    - `Strikeable` turns an untaken type blunt and totals damage by type; the readout
      shows the type, the feature and the totals.
    - Recorder column `*_strike_kind`.
  - **Harness (simulated):** 19 strike scenarios, all passing. Every rung 1 strike keeps
    its energy and damage and gains its type. Six new ones:
    - the sword's flat leading (blunt);
    - its edge on stone (blunt);
    - the axe's bit (lodge, 1.74 kg met);
    - the pick (stab);
    - the adze (lodge);
    - the dagger's thrust (stab).
  - **A/B against rung 1's full run:** the 114 earlier scenarios are unchanged but for
    `fingers_grip_box`'s known flip. The measured spin scenarios moved by under
    10⁻⁷ m; they now run after the six new ones, and are bit-identical run alone. The
    same 45 failing criteria; CHECKLIST and GUIDED pass.
  - **Headset confirmation pending.** Free play with `-- --record-session`: hit each
    post with a weapon's edge, flat, point and back, the axe's bit and back, the
    pickaxe's pick and adze. Then: does the readout's type match the part that hit?
  - **Headset session 2, 2026-10-02 09:31** (`free_2026-10-02T09-31-20.csv`; free play,
    95 s; WiVRn, desktop; 72 Hz but 0.3 s at start-up).
    - **Telemetry:** 42 strikes.
      - The axe on stone: 12 blunt.
      - A 1.2 kg weapon on stone: 9 blunt; on wood: 10 stab, plus 2 blunt bounces.
      - The longsword on cloth: 5 slash, 2 stab, 1 blunt (met 2.6 kg, inferred near the
        hands).
      - No sharp type on stone; lodge did not occur.
    - **Found:** the pickaxe's stab feature shared its name, `Pick`, with its collision
      box. Both loaded and the pick collided, but duplicate sibling names break lookup
      by name and leaked the box on free (exit messages). Renamed `PickPoint`; the
      pickaxe scenarios pass, with no leak.
    - **The player's account:** pending. Then the player chose: "I want to simplify the
      types in 3 Slash, Stab, and blunt. No other types."
  - **Revised 2026-10-02: three types.** `Strike.Kind` is blunt, slash or stab, and
    lodge is gone. The axe's bit and the pickaxe's adze, the edges that were lodge, now
    slash. The materials lose their lodge values, the readout shows three totals, and
    `strike_axe_bit_wood` and `strike_adze_wood` expect slash. All 19 strike scenarios
    pass, with energy and damage unchanged.
    - **The player's account of session 2:** "It feels decent."
  - **Revised again 2026-10-02: two types.** The player: "simplify further an count for
    only slash and blunt damage", choosing that points slash too.
    - `Strike.Kind` is blunt or slash. A strike any `Sharp` part (an edge or a point)
      deals is a slash; anything else is blunt.
    - `Sharp` no longer carries a type, and the materials lose their stab values.
    - Recordings keep the codes, and `Analysis.KIND_NAMES` still reads the earlier stab
      code.
    - All 19 strike scenarios pass, with energy and damage unchanged.

- **Strike haptics, built 2026-10-02**, at the player's request; I had suggested it.
  - **Before:** a held weapon's strikes gave no buzz. A bare hand's touches already did,
    through `hand_contact`, but a hand never touches what it holds.
  - **Now:**
    - `HandStrikes` emits `struck(strike, source)`; `DynamicPhysical` forwards it as
      `PlayerPhysical.hand_strike(side, strike, source)`.
    - `HandHaptics` buzzes each hand that held the striker, for every strike: amplitude
      √(energy / 100 J), so it grows with the blow's speed as a touch's does, at least
      0.15, for 0.06 s.
    - A hand's own strikes keep their touch buzz, and things let go of are not felt.
  - **Harness (simulated):** every strike scenario checks one buzz per holding hand per
    held strike, and none otherwise. A one-handed weapon buzzes the right hand once, the
    two-handed longsword both hands, and fists, boxes and throws add none. The harness's
    gentle pushes (3-18 J) give amplitudes of 0.17-0.43. The real swings of headset
    session 1 (median 32-77 J) would give 0.57-0.88.
  - **Headset confirmation pending:** does a weapon's hit feel right in the hand?

- **Rung 7.1, the character model on the physical player, built 2026-10-02** (the
  skeletal layer, section 7). The player asked to bring their Blender player model over
  and attach it to the physical player, and chose: `Body1` (the mannequin rigged that
  day); re-proportioned in Blender first, on a copy of the rig, by a script I wrote that
  they run in their session; the full body including the head shown in first person;
  the model alone by default, B showing the debug drawings over it.
  - **Fit (Blender, headless on a copy of the session's autosave):** eyes 1.58 -> 1.68 m,
    height 1.70 -> 1.79 m; upper arm 0.198 -> 0.30 m (x1.51), forearm x1.18, thigh x1.10,
    shin x1.10 (to Body1's own ankle, 0.11 m, so the soles stay on the floor), neck x0.73,
    hand x0.87, fingers to `FINGER_LENGTHS`. The static skeleton's shoulder sockets sit
    7 cm below its neck base (Body1's 11.6 cm), so the fitted copy looks shrugged with a
    short neck; the player decides whether to tweak the art or the static skeleton.
    The player then saw the right arm and leg inside out in Godot: Body1's whole right
    side (21 of its 49 parts, mirrored copies, ear and eyelids included) faced inward,
    unseen in Blender, which draws both sides, but culled in Godot. The fit script now
    turns every part outward and drops the custom normals, which only repeated the flat
    faces; the exported GLB has none inside out.
    Next the player found the little finger crooked in play. Body1's fingers are modelled
    curled (a relaxed hand; the little finger about 70° over its length), so each rigid
    finger part was a banana, and laid straight along the physical fingers they formed a
    wave. The fit script now first straightens each finger of the copy along its own
    middle line (cross-sections kept, bones laid along it, 0° between them), then fits the
    lengths; the model's fingers bend only as the physical ones do. Fingers in the harness:
    every bone along its physical bone within 0.0004°.
  - **The static and physical hands take the model's layout (2026-10-02),** at the
    player's request ("I just want their default positions to change to be uniform with
    the new body model"; nothing reads the skeletal layer). The thumb had looked crushed:
    the model kept its root on its own hand but pointed it along the physical thumb, 17 mm
    further out and 19° further across the palm.
    - The fit script now keeps Body1's own hand (115 mm wrist to middle knuckle) and
      fingers, straightened along each finger's own middle line (a curve through the
      knuckles pulled onto the finger's slices; the bones cut across the little finger),
      and prints the static constants it measures.
    - `StaticSkeleton`: `FINGER_ROOTS`, `FINGER_LENGTHS`, `FINGER_SPREADS` and
      `thumb_spread_degrees` (31.3, was 50) are the model's. Its fingers also tilt toward
      the palm (thumb 18.7°, others -9 to 7°); the player chose the thumb flat, and the
      fingers lie flat too (the open curl already bends them): tilted, a palm pressed on a
      table rested on the thumb 7 mm up, and fingers under a flat palm pushed into what it
      lay on.
    - `HandDrive`: the palm box reaches the model's knuckles, the player's choice
      (113 mm, its middle 9 mm ahead of the palm centre, its back still 2.5 mm ahead of
      the wrist; was 95 mm, centred, ending short of the finger roots); a hand is touching
      when its contacts' pushes together pass the threshold, and `HandFingers` has the
      hand report up to 64 (the wider fingers split a palm's press on the table's edge
      until no single contact counted, and their expected, pushless contacts filled the
      16 reported, so the table mantle's legs never drew up; a hand resting on a table
      now reports about 35, read each tick by the touch test, fingers and strikes:
      unmeasured on Quest).
    - Harness (simulated), full run against the same tree before (with the same day's
      feet fix in both): the model's finger roots on the static layout within 0.07 mm;
      `hand_table_press` now passes; four new failures, all near their limits:
      `fingers_close_on_table` (closing moved the hand 6 mm, <= 5) and `fingers_grip_box`
      (the index wrapped the edge 39°, >= 60), both order-sensitive (each passed run
      alone); `finger_poke` (the hand crept 10.2 mm while pressing, <= 10; the index now
      reaches 14 mm further); `climb_mantle_table` (the legs drew up, and once for only a
      tick or two). `handle_sword_tilt` swings past its seat 5.0° (6.1° before); the
      two-hand sword checks moved within 1°. `fingers_grip_box` moves the other two
      boxes along the table: the wider hand put its little finger over the medium one.
    - Headset 2026-10-02 18:39 (recorded, 45.6 s free play): "the thumb was in a really
      bad position, inset into the side of the palm". The model's thumb was pointed along
      the flat physical thumb, pivoting 47 mm back inside the hand at its first bone's root,
      so its visible part rose about 15 mm into the palm piece. The player chose to keep
      the modelled tilt: each model finger bone now turns with its physical bone from the
      model's own rest (`PoseMapper._measure_fingers`), so the thumb sits 18.7° in front of
      the palm as in Blender and bends as the physical one does; with a palm pressed flat
      on a table its tip dips about 2 cm into it. Harness: each model finger bone keeps its
      relation to its physical bone within 0.06°.
    - The player then: "the static skeleton finger is mispositioned within the palm ... the
      skeletal layer modeled hand should be where the static skeleton's thumb should be
      placed". The static (and so the physical) thumb and fingers take the model's tilts
      again (`FINGER_PITCHES`, `thumb_pitch_degrees` 18.7; the root frame points along
      forward + tan(spread) toward the thumb + tan(pitch) toward the palm): every static
      finger joint now lies on the model's within 0.1° and 0.1 mm (flat, the thumb's tip
      was 23 mm off, inside the palm). Harness, full run: 19 failing (17 with the old
      hand, 20 flat); against the old hand a pressed palm rests on the thumb again
      (`fingers_table` 7 mm up, `palms_lift_box` 31°), the index and middle press into the
      grip box's top instead of wrapping its edge, `fingers_wrap_edge` twitches 3.3°,
      `finger_poke` creeps 11 mm, `palm_push_box` (order-sensitive) fails; the table
      mantle, `handle_sword_tilt` and `fingers_close_on_table` pass. A thumb and fingers
      that fold flat when the palm presses would answer the first three (not built).
    - Headset 19:18 (recorded, 92 s): "looks the same, misaligned": the static and physical
      thumbs' first bone, the metacarpal (47 mm), ran inside the model's palm from near the
      wrist, while Body1's visible thumb is only its last two parts. The player chose the
      whole thumb on the visible thumb: the fit script re-splits each visible thumb into
      three bones from where it leaves the palm (`_resplit_thumbs`: the first part halved,
      the tip part kept; 17.4, 17.4, 32.8 mm; root at 13.8, 41.0, 22.9 mm), the static
      thumb takes that root and those lengths, and `HandFingers` no longer lifts a root
      flush with the palm's face (it had moved the physical thumb 5.3 mm off the static
      one; it would have been 20 mm, into the palm). Static and physical thumbs now lie on
      the model's within 0.1 mm and 0.1°, both hands. Harness, full run against the tree
      before: 18 failing (19); `fingers_wrap_edge` and `palm_push_box` pass; a pressed palm
      rests on the thumb 9 mm up (7 before), `palms_lift_box` tilts 21.5° (30.8°),
      `climb_throw` shows one leg flicker.
    - Headset: "positioned correctly. Why is it tilted? ... should be 1:1 with the model's
      default thumb position". The open hand still bent the thumb 20, 15 and 15° at its
      joints (`thumb_curl_degrees`); now 0, so the open thumb is the model's own (0.0° and
      0.0 mm on its hand, both hands); it still closes to 45, 50 and 60° with the grip. The
      fingers' open curl (8, 4, 10°, `rig.tscn`) is kept: open, they sit 22° from the
      model's straight fingers at their tips. Harness: 16 failing (18); `finger_poke` and
      `climb_throw` pass, nothing new fails.
    - **Headset confirmation pending:** the thumb and fingers in the mirror, B overlay on
      the model's fingers, grips, pressing on the table, the table mantle.
  - **Built:** `tools/blender/fit_player_proportions.py`, `tools/blender/export_player.py`,
    `assets/models/player/body1.glb` (from the untweaked fit until the player saves theirs),
    `scenes/player/visual.tscn`, `PoseMapper`; `BodyParts` publishes its joints and soles
    (physics untouched); `SkeletonToggle` switches both drawings; `PhysicalDebug` skips its
    work while hidden.
  - **Harness (simulated):** every scenario checks the model each tick (146 scenarios,
    56,902 ticks): each segment's ends on its physical joints (worst 1.5e-6 m), the
    wrists, the middle finger roots, the eyes and the ankles likewise; hands rigid on the
    physical hands (0.06°), the head on the headset (0°), fingers along the physical
    fingers and feet along their soles (0.0003°); no bone flips about its length (worst
    59° in a tick, a knee turning to the static leg's outward bend on the steps); standing,
    every segment within 5 % of its rest length (0.975-1.029). A/B against the same tree
    without the change: all 146 scenarios' results and recordings identical, and the same
    17 scenarios fail on both (none of the failures is new).
  - **Found, for the player (physical and static layers, now visible on the model):**
    - The static gait stretches shins far past their length before a step lifts: 1.5x
      walking at full stick, 1.8x running moderately, 2.8x running hard, 1.96x on the steps
      and 1.8x on the ramps (the physical calf stretches the same).
    - Drawing the legs up when climbing raises the tuck 0 -> 0.90 m in one tick: the
      static feet jump to hip height and the knees hang below them, so the shins turn
      180° in a tick. Doc section 7's "knees bending up in front" is not what the legs do.
    - Overhand throws and sword flicks swing the physical forearm up to 150° in a tick as
      the hand passes the shoulder; landing from the drop and the vault swing the shins
      127-143°; leaning over the table, 135°.
    The model shows each as it is; nothing smooths them.
  - **Headset confirmation pending:** look down while standing, walking and crouching; in
    the mirror, wave, reach out fully, raise both hands, crouch, step; press a palm into
    the wall and pull back (the model's hand stays at the wall, the arm stretching); grab
    the sword; climb Hold1; turn the head fast (anything of your own head in view?); B
    (the drawings over the model). Physics interpolation does not cover bone poses.
- **Feet kept on the body's floor, fixed 2026-10-02** (the static gait). The player: the
  feet "attach to walls and get stuck so the feet infinitely stretch", on the level's tree
  and on hilly terrain. The gait's floor ray took the first Static surface within 1 m
  above the rig's floor, so a foot near the trunk stood on its rounded foot (0.3 to 1 m
  up, 56-77°), and a drop was judged from the other foot's height, so each foot then held
  the other there while the body walked away. Now a foot stands only where the ground is
  at most 45° steep and within 0.3 m of the body's floor, above or below
  (`foot_step_limit`, `max_foot_slope_degrees`); elsewhere it goes to the edge toward the
  body, or stays level with the body's floor. The floor under the head counts only on the
  same terms against the rig's plane, and a planted foot further than that from it lifts.
  - **Harness (simulated):** new `tree_feet` (stick into the trunk, lean over its foot,
    stick about 2.8 m back): before, the feet stood 0.6-1.06 m up the trunk and the legs reached
    3.84x their length; after, feet at most 0.07 m up (swing height), legs 1.18x walking
    and 1.03x standing. `lean_over_table` checks the same: a swinging foot rode onto the
    table top (1.04 m), now 0.05 m. Full run A/B: no new failures, the same pre-existing
    ones; only `climb_mantle_table` moved (kneeling on the edge 4 cm higher, since the
    pelvis no longer crouches against the table top under the head; up 0.15 s sooner).
  - **Headset confirmation pending:** walk into and around the tree, lean over the stump,
    step onto and off a felled log; walk up, down and across steep hills on terrain;
    mantle onto the table.

- **The grab's seat, built 2026-10-02** (section 6.7), at the player's request: an object
  being pulled in "doesn't move into place fast enough causing a loose feeling grip ...
  when the player is moving his hands around quickly"; "nothing should be getting in the
  way", "the transition should be static, not dynamic ... the same regardless of the
  players hand positions". Decided with the player: 0.08 s eased out; every object the
  same, heavy ones too; the second hand's join unchanged for now.
  - **Why it felt loose (from the code, confirmed in the harness):** the pull's motors
    closed the gap at 20 /s, capped at 3 m/s and 400 N, and turned a handle with at most
    10 N·m and 10 rad/s, so the approach took longer the further and the more it turned,
    and a turning wrist outran it. It met the table and props on the way, and it locked
    within 5 mm, holding the object up to 5 mm off for good.
  - **Built:** `HandGrab` seats the object (`_seat_step`): frozen and on the new Seating
    layer (11), placed each tick at the hand's pose times an eased path in the hand's
    space, then unfrozen in its exact seat with the hand's velocity and welded. Seated
    inside something, it meets nothing until clear (`_solidify_when_clear`). Removed: the
    pull joint and motors, the handle's turn torque, and `grip_strength`, `pull_gain`,
    `max_pull_speed`, `grip_torque`, `max_turn_speed`, `turn_response` (about 90 lines).
    Fixed on the way: grabbed again before the hand was clear of it, a prop kept the Held
    layer as its own for good (`Grabbable` now keeps its own layers once).
  - **Harness (simulated), before -> after:**

    | Case | Pulled in | Seated |
    | --- | --- | --- |
    | Time to held, hand still (box; sword; longsword; sword turned 45°/135°; tilted 30° into the table; longsword turned 80°) | 0.11; 0.15; 0.25; 0.18/0.22; 0.69-0.71; 0.40 s | 0.069 s every one |
    | Gripped mid-sweep at 1 / 2.5 m/s (box) | 0.11 s, up to 23/24 mm off a fixed path, held 4.5/5 mm off its grab point | 0.069 s, on the path (0.0001 mm), held 0.1 mm off |
    | Gripped mid-sweep at 2.5 m/s, wrist rolling 4 rad/s (sword) | 0.33 s, its turn trailing up to 23° and swinging back 10° | 0.069 s, on the path, in its seat (0.0004°) |
    | After the lock, the sweep stopping in 0.06 s (the weld's give) | 0.9 mm/0.6°; 2.8 mm/1.4° | 0.8 mm/0.5°; 2.3 mm/1.2° |
    | A 0.3 kg box where the seat puts the sword's blade | flung 1.01 m | stays (0.002 mm); the sword meets nothing until lifted clear |
    | 40 kg box | the hand went 5 cm down to it | seated, then its weight took the hand 5.3 cm down and the box back onto the table; 0.5 m/s at most once held |
    | Gripped again before the hand was clear | kept the Held layer | its own layers back |

    New scenarios: `grab_box_moving_slow`, `grab_box_moving`, `grab_sword_moving`,
    `grab_regrab_box`, `handle_sword_yaw45_box`. Full run: 56 failed criteria before,
    37 after; no scenario that passed fails now (`handle_sword_tilt` now passes;
    `two_hand_close_apart` and `two_hand_longsword` too, not investigated).
  - **Found, open (two hands):** `two_hand_longsword_beside` (failing before, on its
    aim) now also fails steady and ringing: with both fists on the longsword's handle the
    object shakes 1.7 mm a tick and both drives turn back every tick, as
    `two_hand_table_join` already did before. It depends on where the first fist sits to a
    few millimetres: the seat puts it exactly on its grab point, where the pull left it
    about 4-5 mm short; moved 4 mm along the handle or across it one way the shake goes,
    the other way it stays (scratch test, seat shifted on purpose). So the two-hand
    hold has a geometry where its drives fight, and the exact seat lands on it in this
    case. Not fixed here (the second hand's join is the next step, by the player's
    choice); offsetting the seat to dodge it would hide it.
  - **Headset confirmation pending:** grab the boxes, sword and longsword at rest and
    sweeping the hand fast: in the grip at once, no trailing, nothing on the table knocked.
    Grab a weapon lying flat with the wrist rolled (pommel through the table): no jolt.
    Lift the 10 kg and 40 kg boxes: how the weight comes on at the lock. A large turn
    (the longsword turned 80°) happens in the same 0.08 s: is it too quick a flick?
    Tune `seat_time`.

- **Rung 8, one physical system: decided 2026-10-02; 8.1 step 1 built the same day.**
  The player asked for the physical systems to work as one: movement "physically felt"
  (what they move into, their body's weight and what they hold slow them), movement that
  respects the whole body (an overhang catches the head unless they kneel), and held
  objects "as if welded to the players hand" (running while holding, the object drifted
  out of the grip), keeping the simulated hand strength. Model: strength is a budget; a
  load takes its share and the rest moves you (ArmStrength's hold share, climbing's
  `haul_speed·(1 − W/F)`, and the legs to come).
  - **Ladder, one sub-rung and headset session at a time:** 8.1 holding is solid; 8.2
    load-aware legs (motor mass = body + borne held mass; a force-velocity leg budget
    `leg_force·s·(1 − v/v_wish)`, braking 1.4×, `s = 1 − carried weight / capacity`, so
    resistance R gives `v = v_wish·(1 − R/F0)`); 8.3 the whole body meets the world (the
    capsule's top at the top of the head; past arm's reach the drive stiffens toward
    `climb_strength`, so a caught hand or held object holds the body back).
  - **Decided with the player:** holding first; slopes count in the legs' budget (uphill
    slower, about 20 % on 15°); a caught hand or held object holds the body back and
    strain never breaks the grip (only lost tracking or walking far away in the room).
  - **Found (harness, simulated):** new scenarios `run_hold_sword`, `run_hold_heavy_box`,
    `run_hold_longsword` lift the object, then pump both hands hard (0.25 m, 2.5 Hz) with
    the stick full back. Held in one hand, the weld held at a run (grab points 0.6 mm and
    1.5 mm apart, 1.1° and 2.9° turned in the hand), but the object was **drawn** 100 mm
    and 127 mm off the hand: a probe showed every frame draws a body's node as the tick
    began (202 of 202 ticks synced at the tick's start, 201 of 201 frames unchanged since,
    the server a step ahead), while physics interpolation drew the prop between its last
    two ticks, a tick behind the avatar posed on the tick. Snap turns drew a held prop up
    to 452 mm off, throws 137 mm, strikes 50-70 mm. The physical give is elsewhere:
    strikes and chops open the grip 9-24 mm, two hands 6-35 mm (35 mm at the run, the
    longsword also turning up to 33° on the lead hand, which only its roll couples).
  - **Built (8.1 step 1):** `Grabbable` turns physics interpolation off for its body
    (above, 6.7). The recorder's new `*_drawn_slip` columns measure, per drawn frame, the
    held object's grab point as drawn against the avatar's hand (`HandGrab.drawn_gap`,
    sampled from `PlayerDebug._process`); `Analysis` reports `drawn_slip_held_max`.
    Result: drawn slip equals the physics gap (100 -> 0.6 mm, 127 -> 1.5 mm); all 162
    scenarios' physics columns identical to before. Full run: 51 failed criteria, from 56;
    every other scenario's result unchanged (3 are the drawn checks, 2 the two-hand run's
    turn-in-hand checks, now kept to one-hand holds since two hands turn on the object by
    design). Still failing there: the two-hand run's 35 mm, and `run_hold_heavy_box`'s
    model upper arm flipping 66° in a tick (the skeletal layer, 7.1).
  - **Tried and reverted (8.1 step 2, the planned weld):** the arm's drive re-pointed
    from the hand to the held object (the hand riding it welded), both hands welded in a
    two-hand hold. Gains were modest (the 10 kg box at a run 1.5 -> 0.3 mm; a sword strike
    on the post 24 -> 12 mm), and it broke tuned behaviour: two-hand holds aimed up to 15°
    off and shook 0.6-0.8 mm a tick with the wrists fighting (7-16° off their targets, the
    welded hands counter-rotating about the grip line; giving the wrists only the roll did
    not fix it), a 2 kg wrist flick lagged 47°, the dagger's let-go strike missed: 74
    failed criteria. Inference: the hand (1 kg, 0.04 kg·m²) is not light next to most
    props (dagger 0.45 kg, swords 1.2-1.9 kg; a blade's roll inertia is far below the
    hand's), so whichever of the two is driven, the other is not a light passenger.
  - **Open for the player:** the remaining physical give (strikes, two hands). The exact
    fix is one body: the held object's shapes and mass on the holding hand's body while
    held (no weld), at the cost of re-plumbing what reads the prop as its own body
    (strikes, support, throw history, finger checks, two-hand holds).
  - **Headset confirmation pending (8.1 step 1):** run with the sword, the 10 kg box and
    the longsword in both hands, pumping hard; snap turn while holding; throw; strike the
    posts. The held object should stay in the fist as drawn. Check a held sword looks as
    steady as a bare hand while running (the XR origin's own interpolation is unverified).
  - **Headset 2026-10-02 21:12 (78.6 s, recorded):** telemetry: in every hold the object
    was drawn where the physics put it (drawn minus grip gap 0 mm). The player: "my hand
    did stay with the object", but running with the longsword and the 10 kg cube "my hand
    stretched like crazy ... being drug behind like crazy. It should never allow for that
    kind of stretch and physically slow my movement to compensate for the heavy item";
    one-hand swings "feel nice", two hands "a lot more floaty and inaccurate"; the grip
    "seems to rotate after doing some crazy rapid movements and twists"; snap turning
    "feels and looks good". Telemetry: ArmStrength's command trailed the player's hand by
    51 cm (median) and up to 1.96 m with the cube at a run, up to 25 cm with the
    longsword; one-hand grip gaps p95 7-31 mm, two hands about 20 mm even standing. A fall
    off the level while holding the longsword ended in the respawn dragging it 20 m through
    one step and flinging it at 95 m/s.

- **Rung 8.2, the load moves with you: built 2026-10-02.** Chosen by the player after the
  21:12 session (next: this before two hands or the grip's turn; a 10 kg load slows the run
  by about a tenth). Pushing resistance and slopes are left for the step after, so this
  test changes carrying only.
  - **Cause (code and telemetry):** ArmStrength's follower lagged in the world: the body's
    own speeding up counted against the shoulder's strength, so the legs ran on (the
    motor knew only the 75 kg body) while the arm could not keep the load up with them.
  - **Built:** ArmStrength is carried along by the body's horizontal velocity, changing at
    most at `max_carry_acceleration` (15 m/s²; a harder stop, against a wall, the arm
    takes); the shoulder and wrist strength now only resist the hand's motion on top of
    that, and its target never goes past the arm's reach of the shoulder (`reach`). The
    legs move what the arms bear (`CapsuleBody.carried_mass`, summed from each hand's
    lever share times its borne share, `HandGrab.carried_mass()`): the motor works on body
    plus load, and the load's weight takes its share of the legs' strength,
    `strength_share() = 1 − W / carry_capacity` (981 N), scaling the leg and step forces
    and the stick's top speed (`LocomotionFrame.strength`; following the head is not
    slowed). The rig carrier predicts with the same moved mass. A relocation moves what a
    hand holds with it (`HandDrive.holding()`) and restarts the arm's strength on the
    player's hand at rest (removed: `ArmStrength.shift()`, which kept a fall's 9 m/s and
    0.64 m lag through a respawn). New telemetry: `*_held_turn` (the object's turn in the
    hand since its grip joint was made) and `carried_mass`.
  - **Harness (simulated), before -> after:** 10 kg box at a run: the command 0.65 m off
    the player's hand -> 0.47 m, all of it vertical (the box cannot follow 25 cm arm
    pumping), none behind; the hand 54 -> 33 mm off its command; top speed 5.64 -> 4.87 m/s
    over the 0.8 s push. Sword: 5.43 -> 5.39 m/s, longsword 5.44 -> 5.35. A longer run
    before the change lost the box (hand 0.83 m behind, recovered by teleport, 104° in
    the hand). New `respawn_holding`: the box came with the hand (1.5 mm) and 0.3 m/s
    after, against 6 m apart and flung at 38 m/s before. Full run: 59 failed criteria ->
    51; all 96 scenarios that hold nothing are identical; the one check worse is
    `grab_step_heavy`'s settle overshoot, 13.2 -> 15.2 mm (failing before).
  - **Still failing, for the player:** `run_hold_heavy_box`'s model forearm flips about
    its length while the box is pumped (89° before, 163° now; the skeletal layer's twist
    rule, 7.1); the two-hand run's 31 mm grip gap (two hands are next in line).
  - **Headset confirmation pending:** run with the 10 kg cube and the longsword, pumping:
    the hand should stay with you (it may lag your pumping with the cube, not your run),
    the run slower by about a tenth with the cube; pick up a weapon and run (barely
    slower); fall off the level holding something: it comes back with you.
- **The head and neck in the mirror only, built 2026-10-03** (section 7). The player: "I
  want to be able to see my head in the mirror, but no where else", so it never shows
  while moving about, and looks normal in a reflection. They chose the neck as well (with
  the head gone it would sit just under the view). Revises rung 7.1's head in first person.
  - **Built:** render layer 3, `RenderLayers.MIRROR_ONLY`. `MirrorOnlyParts`
    (`scripts/visual/mirror_only_parts.gd`, in `visual.tscn`) finds at load the model's
    surfaces skinned only to `Head`, `LeftEye`, `RightEye` and `Neck` (8 of 28: head, ears,
    nose, nose bridge, eyes, eyelids, neck), and splits the mesh: two copies, each with the
    other's surfaces removed (`surface_remove`, keeping materials and levels of detail), the
    head and neck on a copy of the mesh instance on that layer, same skin and skeleton,
    under the model. `PlayerRig` leaves the layer out of the headset camera; the mirror's
    cameras draw every layer but its surface's. No re-export, PoseMapper untouched.
  - **Harness (simulated):** `skeleton_toggle` checks the 8 parts are drawn apart and not
    with the rest (20 + 8 of 28), on layer 3 alone, on the model's skin and skeleton, not by
    the player's camera, by both of the mirror's eyes; it fails with the camera's mask left
    whole. Full run before -> after: the same 51 criteria fail (all present before), and
    every scenario's measurements are identical.
  - **Headset confirmation pending:** look down hard, walk, run, swing: no head or neck in
    view; at the mirror the head, eyes, ears and neck as before, moving with you, no gap at
    the collar. Unverified: whether the head keeps its shadow on the floor in your own view
    (a camera's cull mask may drop an object's sun shadow in that view too).
- **The body sits back when looking down, built 2026-10-03** (the static neck).
  The player: "When I look down, the body of the player isn't sitting far enough back ...
  the players body should step back some to allow the player to see more clearly", without
  the neck stretching.
  - **Cause:** the static neck took a quarter of the head's pitch, so looking down was the
    head folding over an upright neck hung from the head's centre. The neck base stayed as
    close behind the eyes as when level (10 cm level, 9.8 at 60°, 7.8 at 80°), and the
    chest, 13 cm deep in front of it, all but hid the toes. On the model the head folded
    81° on a neck that bent 29° backward. Bending the whole neck to look down, as a person
    looking at their feet does, the static body slid up to 7.7 cm forward under the eyes.
  - **Built:** `neck_follow_pitch` (0.25) splits by direction: `neck_follow_flexion` 0.75
    looking down, so the neck takes most of the nod and the head the rest (about 40° and
    30° at the feet), and `neck_follow_extension` 0.25 looking up, as before. The chest
    keeps `torso_follow_flexion` 0.17 of a neck bent forward, the eighth of the nod it
    always kept, so the hips do not swing back; `torso_follow_tilt` (0.5) still covers
    looking up and tilting aside. Neck length, head centre and the capsule's follow point
    are unchanged; looking level, up or aside is unchanged.
  - **Harness (simulated):** `SimulatedRig.pitch` is new, and so are two scenarios, to
    60° and held, to 80° and held, then level: `look_down` bends the whole neck (two
    thirds about the neck base, the rest at the skull's joint, the model's points) and
    `look_down_nod` nods the head alone (about a point 7.5 cm below and 8 cm behind the
    eyes, the long-standing default VR neck model: the eyes drop less, the hardest case).
    Before -> after, at 60° / 80°: neck base behind the eyes 9.8 / 7.8 -> 15.2 / 14.1 cm;
    the toes in sight past the chest (a 13 cm torso) by 0.8 / 0.0 -> 6.1 / 6.1 cm bending
    the neck, 1.4 / 0.7 -> 6.7 / 6.7 cm nodding (level, hidden by 0.6 cm, as before); the
    model's head on its neck 81° / 105° -> 25° / 34°, its neck on the chest -29° / -35° ->
    +27° / +35°; the model's neck 0.82-1.02 -> 0.83-0.98 of its length. Bending the neck,
    the body stands still: the neck base moves 7.7 -> 1.4 cm and rises 0.2 cm, the hips
    sit back 1.1 -> 7.5 cm over the planted feet, the legs reach 0.001 -> 0.011 further.
    Nodding the head alone, the body rises 0.4 -> 3.4 cm with the eyes and the legs reach
    0.006 -> 0.062 further (the shin takes it). The feet stay planted in both. Full run before -> after: the same 51
    criteria fail (all present before), every other scenario's measurements are identical,
    and both new ones pass.
  - **Headset confirmation pending:** stand and look at your feet: the toes in view past
    the chest, the body not sliding forward under you, nothing stretched; nod a little at
    the mirror: the neck bends forward with the head; B: the static skeleton's neck leans
    forward as you look down. Looking down at the table while working, the shoulders now
    sit a few cm further back.
- **Legs pass through props, built 2026-10-03** (section 6.6, body parts). The player:
  "I will crouch down to pick up items and my player steps on them kicking them around.
  I would like to disable the leg colliders for objects on the ground. I want to keep the
  colliders for the future". Their one future use, an enemy's attack meeting a leg, is
  not built.
  - **Built:** the thighs, calves and feet are switched off (`BodyParts.LEG_PARTS`,
    `CollisionShape3D.disabled`), so they meet nothing; still on `PropsOnlyParts`, posed
    every tick, published and drawn. The neck and head still push props.
  - **Harness (simulated), before -> after:** `walk_kick_box` (now: no leg touches the
    box): the right foot and calf kicked it 0.14 m at 1.44 m/s -> only the capsule's edge
    met it, 3 mm. The capsule still steps up onto it (0.11 m, both runs; step checks
    include props). `walk_push_crate`: the legs knocked the 8 kg crate aside after 0.93 m,
    off the capsule's side -> the capsule pushed it straight ahead 3.6 m (2.6 s against
    0.17 s), top speed 1.50 -> 1.46 m/s; all its checks pass. Full run: the same 51
    criteria fail (all present before); the other 165 scenarios are identical.
  - **Headset confirmation pending:** crouch over items on the floor and shuffle your
    feet, walk through loose loot and logs, kick at a box: the legs move nothing. An item
    you stand right over can still meet the capsule (pushed, or stepped onto if small).

- **The hands meet held objects: built 2026-10-03** (the player: "the hand not holding the
  object should also collide with and interact with the held object"; they chose that
  weapons in both hands meet too).
  - **Before:** a held prop was on the Held layer, which no hand meets, so the free hand
    and forearm passed through it, and two held weapons passed through each other.
  - **Built:**
    - Held masks Hands and Held (6.8).
    - Each hand holding a prop, or not yet clear of it after letting go, is a collision
      exception of the prop (`Grabbable.hold()`, `clear_of()`, `ignored_hands()`).
    - The seat's solidify check leaves the holding hands out. A free hand overlapping a
      seated prop keeps it meeting nothing until clear, as the level does: in
      `two_hand_longsword` the hovering left palm kept the sword unsolid from the right's
      seat until the left gripped.
    - `HandGrab._pressed()` ignores the other hand and what it holds.
  - **Step 0 (headless repro):**
    - An exception holds per pair (a third body still met the prop).
    - It survives the grip joint being made, re-made and freed on the same pair.
    - Removed, the pair meets again.
    - Jolt counts duplicate adds.
  - **Harness (simulated), new scenarios:**
    - `held_palm_under`: the palm under the blade, 2.9 mm in; the sword steady
      (0.04 mm a tick); the grip 0.1°.
    - `held_clash`: the sword pushed at 2 m/s into the held dagger, 2 cm past.
      - The blades met, 2.9 mm in at most, and neither passed through.
      - Both grips held, at 2.8° and 0.3°, with gaps of 0.6 and 1.3 mm.
      - The dagger moved 0.56 m/s at most and then stood steady.
    - `held_strike_palm`: the palm stopped the blade 4.9 cm short of its centre; the
      holding wrist gave instead (the sword yawed about 7°).
    - `held_palm_push` fails: a 3 cm press from above sank 9.1 mm, and the sword shook
      2.7 mm a tick (the limit is 0.3 mm). `held_strike_palm` shook 1.05 mm a tick.
      - Cause: the holding wrist rings against the driven palm through the contact
        (0.1-0.45° a tick, up to 33°/s), the same coupling as two hands' twitching.
      - Before `_pressed()` was revised it was worse: the palm counted as support, the
        holding drive switched to its signed damping and swung 23 to 215 N every tick,
        3.4 mm a tick.
    - Recorded, not judged:
      - `held_clash_fast` (5 m/s): no pass-through; the sword's grip gave 21 mm and 4.7°.
      - `held_clash_deep` (10 cm past): the sword rode over the dagger; its grip gave
        16 mm.
      - `held_slap_fast` (palm at 5 m/s, its target 15 cm beyond): the hand got past the
        blade, 20 mm in at most, knocking the sword aside at 3.5 m/s.
  - **Regressions:** full run, 51 -> 59 failed criteria (172 scenarios, 7 new).
    - `run_hold_sword` (+4): the pumping left hand now strikes the sword carried across
      the body. Blocked, its drive presses up to 600 N on the blade, and the weld bends:
      46.8° and 12 cm in the hand.
      - Doubling Jolt's solver steps (20/4) still left 43° and 7 cm.
      - This is the weld's give; only one body would end it (rung 8.1 notes).
    - `two_hand_longsword` (+2): aim 4.37° (limit 4) and 9.08° (limit 9), the late solid
      above.
    - `two_hand_longsword_beside`: steadiness and ringing now pass, but the aim along the
      grab points fails (4.74°); net one fewer failure.
    - `grab_ore_join` passes, its drive corrected: its target followed the ore, which the
      hand now pushes, and chased it away.
  - **For the player:**
    - Whether a hard, unfelt push (pumping through a carried sword) may bend the grip, or
      the free hand's push on the player's own held objects should be capped, or held
      objects should become one body with the hand.
    - The resting-palm shiver belongs with two hands, next in line.
  - **Headset pending:**
    - Rest the left palm on a sword held in the right, press, and slide along it.
    - Swing the sword slowly into the left palm and forearm.
    - Clash the sword and the dagger, and hold them crossed.
    - Two-hand the longsword starting from a touch.
    - Run while holding the sword.

## 11. Cost drivers and risks (unmeasured)

Per tick: three always-awake dynamic bodies, two permanent joints plus up to two grip
joints, three contact monitors, one ground sweep, one head sweep, ceiling casts only
when growing, one forward capsule test while walking on ground (three more only when a
riser blocks it), one step-down ray only while unsupported, and the static skeleton's
existing 5 to 15 rays. Capsule rebuilds happen only on changes above 1 cm. The body
parts add five capsules and two spheres to the body's compound shape, a capsule to
each hand, and a kinematic props-only body with six shapes, all posed every tick
(capsules resized only on length changes above 1 mm), plus up to 16 reported body
contacts; about 0.09 ms per tick on the desktop. Each `Striker` (strike model,
2026-09-30; on the weapons, boxes and hands) returns at once with no contacts or
asleep. In contact, it reads at most its reported contacts and allocates only when it
strikes. The character model (rung 7.1) is one skinned mesh of 35,904 triangles in 28
surfaces, split at load into two instances on one skeleton: 20 surfaces drawn in the
player's own view and 28 in the mirror (the head and neck, 8, only there, 2026-10-03),
casting shadows, posed by 54 bone writes per tick; merging its flat colours into one material would cut the draw
calls and is left until Quest profiling asks for it. No budget is
established until Quest 3S measurements exist; the mirror and debug meshes are
accounted separately.

Risks: motor versus joint versus contact tuning; solver jitter visible in the view;
capsule catching on CSG step edges (Jolt's enhanced internal edge removal setting is a
candidate, name unverified); wedging under ceilings; recoil from free hand swings; the
carry rule's comfort; and attribution of a wrong feel to a parameter. The ladder keeps
one parameter set per rung to keep attribution possible.

## 12. Baseline reference (simulated, retired harness, 2026-09-25)

Godot 4.7.2, Jolt, 72 ticks, `--fixed-fps 72`, head at 1.7 m, the kinematic body with
walk 1.5 m/s and acceleration 15 m/s². These are the numbers rung 1 must reproduce and
rung 2 is compared against. They are simulated, not headset, results. Re-recorded on
the adjusted level after rung 1 (`tests/harness/reference/kinematic_baseline.json`);
every value below was unchanged at the precision shown, with the ramps now mirrored.

| Scenario | Result |
| --- | --- |
| Stand | no drift; body 0.6 mm above the floor |
| Flat, full stick | 1.50 m/s; 90 % in 0.083 s; stop in 0.069 s over 0.035 m |
| Flat, half stick | 0.62 m/s (deadzone remap) |
| Steps up (3 x 0.25 m) | top at 0.755 m in 2.1 s; single-tick lifts of 0.125 to 0.136 m |
| Steps down | 0.19 m drops, 0.111 s airborne, landing at 2.05 m/s |
| 15° ramps | 1.50 m/s both ways, never airborne |
| Floor hole | 3.93 m in 0.79 s, landing at 8.05 m/s |
| Head into wall | rig pulled back 0.199 m for 0.2 m of head travel; head held 0.20 m from the wall |
| Crouch | body height unchanged (kinematic capsule shrinks with the head) |
| Run, moderate pump | run factor 0.22, 2.21 m/s |
| Run, hard pump | run factor 1.00, 5.83 to 6.00 m/s; 90 % in 0.32 s; stop in 0.25 s over 0.68 m |

## 13. Unverified until the rung that uses them

- `PhysicsDirectBodyState3D` contact data for `support_velocity` on moving platforms
  (rung 2, only if a platform exists).
- Bone poses written on the physics tick are not physics-interpolated (interpolation is
  on in `project.godot`); physics follows the display rate, so no judder is expected.
  Rung 7.1's headset session checks it.
- Capsule shape rebuild cost under Jolt at the 1 cm threshold (needs an on-device profile).
- The view fade's no-depth-test sphere with the Mobile renderer in the headset (rung 2
  headset session; the harness can only check its alpha).

Found building the body parts, on 4.7.2 with Jolt: a body's reported contacts carry
the index of its own sub-shape (`get_contact_local_shape`), which `shape_find_owner`
maps back to the part's `CollisionShape3D`; `PhysicsDirectSpaceState3D.collide_shape`
returns point pairs whose distance is the overlap depth; the contact impulse on a
part held deep in a surface levelled off at 12.5 N·s per tick in these tests.

Found building the fingers, on 4.7.2 with Jolt: finger shapes on the hand body hold
against a wall under a 600 N joint motor even while the hand turns, in isolation; a
fast turn (8 rad/s) can still sweep a fingertip about 1 to 2 cm into a wall for a
tick, since contact prediction covers straight movement, not turns. Earlier, for the
jointed chain: `HingeJoint3D` turns about its own Z
and its limits run opposite to body B's turn; a `Generic6DOFJoint3D` angular spring
on X with a positive equilibrium turns body B toward -Y about X (the static
skeleton's bend), and its X limits run in the same sense; a body allowed to sleep
stops after 0.5 s of slow movement even under a motor; raising velocity or position
steps, or lowering the penetration slop, did not stop a straight finger pushed into
a wall from going in.

Found at rung 4, on 4.7.2 with Jolt: a `Generic6DOFJoint3D` linear motor drives the
relative velocity to its target exactly, limited by its force limit, conserving
momentum; its angular motors run opposite to their target and their axes turn with
body B once it rotates, so the hands turn by torque instead. Refined 2026-09-25 with
scratch tests: the angular motors' axes are the joint's axes as they lay on body B
when the joint was made, turning with it from then on; and an angular motor's force
limit is honoured only if it is set after the joint exists (set before, a 3 N·m limit
held an 8 N·m load). The rung-4 finding that `HingeJoint3D` motors ignore their torque
limit may be the same timing; not rechecked.

Found for the strike model (2026-09-30, a scratch project on 4.7.2 with Jolt; details
in `documents/strike_model.md`):
- Contacts are reported whenever `max_contacts_reported` is above 0, with
  `contact_monitor` off.
- A body's contact velocities are its velocities before the step's solve, the step's
  gravity already added: a 15 m/s continuous-collision hit reads 14.9 m/s on the next
  tick while the body itself reads 0. A resting box closes at 0.136 m/s.
- Contact points are where the step's collision test found them: the step's start, or
  the impact for a continuous-collision hit.
- The gap `(p_self − p_other)·n` is positive for look-ahead contacts and negative when
  overlapping.
- `inverse_inertia_tensor` is in world axes.

Found building the character model (rung 7.1, 2026-10-02, on 4.7.2, headless):
`Skeleton3D.set_bone_parent(bone, -1)` at run time, with each bone's rest and pose set
to where it stood, leaves the skinned mesh where it was (4e-7 m), and a bone posed with
a scale along its Y then stretches only its own vertices; under a parent, the child of
a bone scaled (1, 1.5, 1) came out skewed (1.005, 1.46, 1.05). A skeleton's global poses
read back correctly only after its first update (a script reading in the same frame it
was added saw stale ones). `MeshInstance3D.bake_mesh_from_current_skeleton_pose` needs a
registered skin, which the headless renderer does not make. Blender's glTF exporter
keeps bone Y along each bone into Godot (to 0.00002°). `TwoBoneIK3D` takes a pole, but
only as a node (it is not used: the arms run between the physical joints instead).

Confirmed on 4.7.2: `Generic6DOFJoint3D` motor target velocity, force limit and enable
flags; `RigidBody3D.freeze` and `FREEZE_MODE_KINEMATIC`; `XRServer.center_on_hmd`;
`Skeleton3D.set_bone_global_pose`; `TwoBoneIK3D` under `IKModifier3D`;
`XRPose.linear_velocity`; `PhysicsServer3D.body_add_collision_exception`;
`PhysicsBody3D.get_gravity()`; `XRPose.has_tracking_data` (set by `set_pose`); and
Jolt's enhanced internal edge removal, which exists and is on by default for
simulation. `XRCamera3D` has no tracking flag of its own (it is a `Camera3D`), so head
tracking is read from the XR server's `head` tracker.

## Appendix A: options considered

All four share sections 1 to 5, 7, 8 and 9. They differ in the physical layer.

**A, kinematic core.** `CharacterBody3D` body with today's math split into modules;
`AnimatableBody3D` hands swept toward the static targets; props frozen kinematic or
held through a force-limited servo joint; wall pushes and climbing as authored
displacement rules. Best comfort and stairs, lowest cost, deterministic; weight is
faked and every interaction adds a rule. Rejected: its ceiling for weapons and body
presence is too low for the game's first pillar.

**C, hybrid.** Kinematic body kept, hands as real `RigidBody3D`s, and one explicit
exchange module that books the hands' effort into the body through the mass and
strength model (a gentle push is resisted by the legs, a strong one moves the body,
vertical effort beyond support lifts it). Two mechanisms: C1, a script PD force per
hand whose exact value is ledgered (no joints, stiffness ceiling near 3000 N/m at 72
ticks); C2, joint motors anchored to a non-colliding 75 kg shadow body reset to the
body's pose and velocity each tick, whose velocity change after the solve is the
reaction (stiffer servo; per-tick write on a joint anchor unverified). This was the
recommendation and is the **fallback for Option B**: if rung 2 or 3 fails on comfort
or steps, `Body` becomes kinematic again, `RigCarrier` reverts to carry-by-delta with
pull-back, an `Exchange` module joins `Locomotion`, and the hand drives anchor to the
shadow body. Rig, static, hands, interaction, visual, interface and debug are unchanged.

**D, XR Tools composition.** `XRToolsPlayerBody`, movement providers, collision hands
and pickables behind a bridge. Fastest to features; held objects are frozen kinematic,
no mass model, group and name lookups, gitignored addon, layer clash. Rejected as the
controller; usable for hand meshes and grab-point conventions.

| Criterion | A | B (chosen) | C | D |
| --- | --- | --- | --- | --- |
| Head authority / comfort | best | weakest, policy-dependent | good | best |
| Reciprocal force | authored | emergent, full | real hands, explicit body | none |
| Stairs | proven | riskiest | proven | no step logic |
| Tuning | low | high | medium | low |
| Physics cost | lowest | highest | low-medium | low |
| Migration risk | lowest | highest | low | low |
| Ceiling for combat weight | medium | high | high | low |
