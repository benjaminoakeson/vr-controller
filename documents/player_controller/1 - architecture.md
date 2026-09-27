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
│   │   └── PropsOnlyParts (AnimatableBody3D, top_level)  calves, feet, neck, head; made at runtime
│   └── Interaction (Node)               scripts/physical/interaction.gd
├── Visual (Node3D)                      scenes/player/visual.tscn     SKELETAL layer
│   ├── CharacterModel (Skeleton3D + meshes)
│   └── PoseMapper                       scripts/visual/pose_mapper.gd
├── Interface (Node3D)                   scenes/player/interface.tscn  GUI layer
│   ├── Anchors (wrist_left, wrist_right, chest, belt, head)
│   └── displays as child scenes of anchors
└── Debug (optional)                     scenes/player/debug.tscn, instanced by player.gd on demand
```

Rules:

- The player scene is `scenes/player/vr_controller.tscn` (UID kept, so the level's
  instance survives); its root node is `Player`. Rig, Physical and Debug are separate
  scenes (`rig.tscn`, `physical.tscn`, `debug.tscn`) instanced into it; Visual and
  Interface are empty `Node3D` slots until their rungs. `player.gd` holds exported refs
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
| -100 | `Physical.step()`: RigCarrier begin, GroundSense, Locomotion modules, Body integrate, RigCarrier commit | head, stick, grips, body state from the last solve | motor force, jump/step impulses, height, rig, `body_grounded`, `commanded_travel` |
| -90 / -89 | `StaticSkeleton` / `SkeletonDebug` (unchanged) | rig after the move, `ground_probe` | static trackers |
| -85 | `HandDrive` x2 | this tick's static hand and shoulder trackers | joint motor targets and force limits |
| -80 | `Interaction` | grip and trigger, hand contacts, poke overlaps | grip joints, exceptions, layer swaps, throw velocities |
| -70 | `Physical.finish_tick()` | all above, contact monitors | `PoseSnapshot`, signals |
| -60 / -50 | `PoseMapper` / `Interface` | snapshot | bones / anchors |
| +10 | `Debug` | snapshot | CSV, readout |
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
obstruction depth, held objects, physics ms. Visual, Interface and Debug read
`physical.snapshot`. Nothing writes back.

Signals on `Physical`, connected by `player.gd` to whatever consumes them (haptics,
audio, GUI, gameplay): `supported_changed(bool)`, `landed(vertical_speed)`,
`stepped(height)`, `body_blocked(normal)`, `contact_started(hand, other, position,
normal, impulse)`, `contact_ended(hand, other)`, `impact(other, magnitude)`,
`grabbed(hand, object)`, `released(hand, object, linear_velocity, angular_velocity)`,
`head_obstructed(depth)`, `relocated(delta, reason)`, `interface_pressed(target)`.
Each signal is added in the rung whose consumer first needs it; rung 2 publishes
none, because the view fade and the recorder read the snapshot.

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
This is the only ground query the physical layer makes; every module reads it.

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
| `Turn` | snap (default) or smooth yaw through `RigCarrier.turn` | player setting; pivot is the head footprint |
| `Crouch` | the height policy in 6.1 | no explicit crouch input; the headset height is the crouch |
| `Recovery` | exclusive: respawn below the kill height, unstick, tracking-loss holds | see 6.9 |

Built, in this order: Recovery, StickWalk, ArmPumpRun, FollowHead, StepAssist, Jump,
Crouch (`scripts/physical/locomotion/`).

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
| Thighs, calves, feet | capsules 0.075, 0.055, box 0.09 x 0.07 x 0.25 m (0.06 m heel, 1 cm off the ground) | `PropsOnlyParts`, a kinematic body moved with `Body` (layer Player, mask Dynamic) | props only |
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
    (HandDrive "Arm strength").
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
player), two-handed load sharing, feeding the held body its own force, and the
static skeleton's over-reach rule for the posed arm (tried: it made fingers on a box
corner twitch).

### 6.7 Interaction (Established structure)

| Action | Mechanism |
| --- | --- |
| Grab detection | **built 2026-09-25** (`HandGrab`, one per hand): the hand's grab point is fixed 5 mm inside the palm's face; every tick while the hand holds nothing, a ball (radius 0.08 m, centred 0.03 m out from the palm) is searched on the Grabbable layer; the body whose surface comes closest to the hand's grab point is the candidate, and that closest surface point its grab point (exact for boxes, spheres, capsules and cylinders; a small ball cast toward the shape otherwise). It follows the hand until the grip squeezes past 0.7 |
| Pull in and hold a prop | **built 2026-09-25**: a `Generic6DOFJoint3D` from the hand, its rotation locked where it was (the object keeps its rotation relative to the hand), its linear motors driving the object's grab point to the hand's at 20 /s, at most 3 m/s, with up to 400 N per axis (`grip_strength`). The pull acts on both: light objects come to the hand (a 2 kg box in 0.11 s), heavy ones pull the hand to them (a 40 kg box brought the hand 5.5 cm down to it and did not move), and the level stops both. Once within 5 mm it is locked there (**revised 2026-09-26**): the joint is remade rigid, so a held object cannot swing out past the hand or slip out of it; held by the motors, a 10 kg box swung fast lagged 0.33 m and dropped. While holding, the hand drive carries it (6.6, carrying). The prop moves to the Held layer, which the body, hands and legs do not meet, so the hold never fights the palm's or fingers' contacts and the prop cannot push the player; the fingers' checks include Held, so they close onto it. Weight and inertia are real: the hand carries it within its drive's strength |
| Hold the world | joint hand to the hold's static body; nothing else changes. Climbing emerges: the drive pushes the body toward its target, bounded by strength |
| Two hands on one prop | two grip joints; the solver resolves |
| Release | **built 2026-09-25**: when the grip opens past 0.3, free the joint; the prop keeps its own velocity (no throw policy yet) and gets its layers back once no part of the hand overlaps it, or after 1 s |
| Throw | `v = lerp(prop velocity, tracked hand velocity, 1 - clamp(separation / 0.1 m, 0, 1))`, capped at a maximum throw speed; angular velocity from the prop. **Decide at rung 5** |
| Grip failure | **built 2026-09-25, revised 2026-09-26**: let go when the pull-in cannot bring the object within 0.12 m for 0.25 s, when a holding hand is kept more than 0.4 m from its target for 0.25 s (what it holds is stuck; before the hand drive's own recovery would move it; the target is the strength-shaped one, 6.6.2, so a sagging or lagging load is not "stuck"), or when the controller has been untracked for 1 s |
| GUI poke | `Poke` `Area3D` on the index finger, mask Interface; emits `interface_pressed(target)` |

Props on the Dynamic layer also collide with the body (75 kg capsule shoves a 2 kg
cube), the hands, fingers and forearms, and the legs, neck and head on
`PropsOnlyParts`, as long as each prop's own mask includes Player and Hands (6.8). A
`Grabbable` component (`scripts/props/grabbable.gd`) on a prop declares it grabbable:
it puts the body on the Grabbable layer and lets a hand find it (**decided
2026-09-25**: grabbing is opt-in); a bare `RigidBody3D` on Dynamic is only pushable.
The level's three boxes carry one, as do the sword and dagger on its table
(`scenes/props/`, 2026-09-27). A prop made of several shapes sets
`max_contacts_reported` to 4: Godot's Jolt turns contact-manifold reduction off only
for bodies that report contacts, and with it on such a prop settled up to the 5 mm
penetration slop into the table. Decided 2026-09-25 with the player: the pull is
physical (not an animation), and a grabbed object keeps its rotation relative to the
hand. Wanted later, not built: authored grip poses, two-handed holds, fingertip pinch,
force grab, and a throw policy.

### 6.8 Collision layers (Established)

| Bit | Name | Members | Mask |
| --- | --- | --- | --- |
| 1 | Static | level, hold bodies | none |
| 2 | Dynamic | loose props | 1, 2, 4, 5, 6, 9 |
| 3 | Grabbable | props with a `Grabbable` component (also on 2) | query tag |
| 4 | Held | a prop while held (off 2 and 3 meanwhile) | 1, 2, 9 |
| 5 | Player | Body (capsule and body parts); PropsOnlyParts (mask 2 only) | 1, 2, 9 |
| 6 | Hands | LeftHand, RightHand (palm, fingers, forearm) | 1, 2 |
| 7 | Interface | GUI hit targets (Area3D) | queried by Poke |
| 8 | ClimbHold | climbable bodies or areas | query tag |
| 9 | Enemy | future | |

Found 2026-09-25 (Godot 4.7.2, Jolt): two bodies collide only when each one's mask
includes the other's layer. The level's boxes were on Dynamic with mask Static and
Dynamic only, so the body, hands and legs passed through them while the ground sweep,
a query that ignores the box's mask, still stood the body on them. Their masks now
follow the table: 1, 2, 4, 5, 6, 9 (315). Every prop needs the same.

Queries: ground sweep 1, 2; `ground_probe` 1; step tests 1, 2; head sphere 1; grow
clearance 1, 2; grab 3, 8; poke 7. No self-collision: body never masks 6, hands never
mask 5 or 6, held never masks 5 or 6. CCD only on the hands (fast motion) unless a
tunnelling case is demonstrated elsewhere. Demonstrated for the weapons (2026-09-27,
headless): thrown tip-first at a 1 m CSG wall, which collides as a surface with
nothing solid behind it, the dagger passed through or stuck in 11 of 35 throws at
6-25 m/s (through from 6 m/s) and the sword 4 of 35; with CCD, none of the 70 did.
Both weapons have CCD. Jolt's CCD sweeps linear motion only; spinning throws
(10-40 rad/s) stopped with or without it.

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

### 6.10 Comfort policies (Decided at rung 2, 2026-09-25)

| Source of view motion | Policy |
| --- | --- |
| Real head motion | 1:1 always, by the XR runtime |
| Stick, run, jump, steps, falls | carried 1:1 with the body (as today) |
| Pushes and impacts on the body | carried 1:1; the levers are mass and `leg_force`. If headset testing shows discomfort, evaluate a per-tick carry cap with smooth catch-up before touching physics |
| A body part pressed into something (the chest on a table's edge while leaning over it) | the push on the body is carried 1:1 like any push, which takes the parts that follow the head back out. **Headset check** (built 2026-09-25) |
| Body stopped by furniture, head clear above it | the view is pushed back once the head leads the body's centre by more than the 0.35 m lean limit (6.4) |
| Head inside static geometry | fade from 0 at contact (a 6 cm ball around the eyes, since 2026-09-25) to black at 0.1 m depth; recenter per 6.9. Chosen over the old 1:1 pull-back after the rung 2 session: the player found it more comfortable and the timing right |
| Turning | snap by default; smooth as a setting; never a torque on the body |

No system ever rotates the camera. The physical body does not become the camera's
authority; the rig follows its translation only.

## 7. Skeletal layer (Established structure)

`Visual/PoseMapper` at -60 writes bones with `Skeleton3D.set_bone_global_pose`: head,
neck, torso, hips, legs and feet from the static trackers; hands from the snapshot's
physical hands; each arm refitted to the physical hand with a shared two-bone solve
(extract `StaticSkeleton._bend` into `scripts/static_skeleton/two_bone.gd`, or use
`TwoBoneIK3D`, present in 4.7, pole-vector support unverified). Fingers follow the
static finger joints, overridden by a grab pose published by `Interaction`. The model
shows a blocked hand where the physical hand is. Nothing here writes into physics.

## 8. GUI layer (Established structure)

`Interface/Anchors` copies from the snapshot each tick: `wrist_left`, `wrist_right`
(physical hands), `chest` (static torso), `belt` (static hips), `head` (fade only).
Displays are child scenes of anchors. Every control has its own `Area3D` on the
Interface layer; presses arrive from `Physical.interface_pressed`, never from bones.
`Interface` emits `action_requested(action, payload)` and `player.gd` routes it.
Displays read gameplay state from an injected `PlayerState` reference, not a global.

## 9. Debug and test attachment (Established)

- `Debug` scene (`scenes/player/debug.tscn`, `PlayerDebug`), added by `Player` only
  for `-- --player-debug`, `-- --record-baseline`, the `debug_always` export, or a
  harness calling `enable_debug()`. It holds the `Readout` (the former rig Label3D,
  placed above the left controller each frame), a `LocomotionRecorder` (per-tick
  measurements; CSV while recording), and, for `--record-baseline`, the guided session
  driven by `BaselineChecklist`: recording starts once the headset is tracked,
  instructions show above the left hand and tick themselves off with a buzz, and the
  game quits when done. Normal play records nothing. Gameplay code has no reference
  to any of it. From rung 2 the recorder reads the snapshot instead of the body.
- `tests/harness/simulated_rig.gd` registers trackers named `head`, `left_hand`,
  `right_hand` with `XRServer` and sets `primary` and `grip`, so the unchanged rig
  nodes follow it. `tests/harness/run_scenarios.gd` runs the scenarios on fresh copies
  of the level, writes a CSV per scenario and `results.json` under
  `user://baselines/simulated/<time>/`, and exits 0 only if three checks pass:
  ACCEPTANCE (the current rung's criteria for the dynamic body, each with a stated
  tolerance, beside a printed comparison with the kinematic reference) or, with
  `--reference=`, REFERENCE (every measurement within 1 %, or 0.001 in its unit, of
  that file, e.g. `tests/harness/reference/kinematic_baseline.json` run with
  `--player=res://scenes/player/player_kinematic.tscn`); CHECKLIST (the guided
  checklist recognises every item of the guided session in the recordings); and
  GUIDED (a guided session starts recording and shows its first item). The runner
  also samples the view fade's darkness, so a fade where none belongs fails. `tests/harness/analysis.gd` measures simulated
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
  | Walking past a 12 cm box in line with the right foot | the right foot and calf kick it 0.23 m; the capsule's edge also meets its top and may step onto it (step checks include props) |

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
  mask Held (6.8); whether held weapons should meet is for the player to decide.
  Unmeasured: how far a swung sword trails the hand (by analogy with the 2 kg box it
  will), the cost of CCD and contact reporting, and draw calls (sword three surfaces,
  dagger two, each also drawn by the mirror). The guided session's items are
  unchanged, and the recording does not name what a hand holds; the headset check is
  free play recorded with `-- --record-session`: pick each weapon up with each hand,
  turn it thumb-up, swing it, lay the blade on the table and press, drop and throw it.
  Headset confirmation pending.

## 11. Cost drivers and risks (unmeasured)

Per tick: three always-awake dynamic bodies, two permanent joints plus up to two grip
joints, three contact monitors, one ground sweep, one head sweep, ceiling casts only
when growing, one forward capsule test while walking on ground (three more only when a
riser blocks it), one step-down ray only while unsupported, and the static skeleton's
existing 5 to 15 rays. Capsule rebuilds happen only on changes above 1 cm. The body
parts add five capsules and two spheres to the body's compound shape, a capsule to
each hand, and a kinematic props-only body with six shapes, all posed every tick
(capsules resized only on length changes above 1 mm), plus up to 16 reported body
contacts; about 0.09 ms per tick on the desktop. No budget is
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
- `TwoBoneIK3D` pole vectors (rung 7).
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
