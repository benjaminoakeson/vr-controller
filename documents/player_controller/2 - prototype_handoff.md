# Physical prototype: repository review and implementation handoff

## Review scope

Reviewed the current project settings, main level, player scene, physical body,
static solver interfaces and update order, debug visualization, XR startup,
action map, mirror, and the small `spikey` scene. This is a source/scene review
with a brief headless load check, not a headset playtest or performance benchmark.

Read [the overview](0%20-%20player_controller_overview.md) and
[the physical design](1%20-%20physical.md) for intended behavior. This document
records the existing foundation and how to migrate it without discarding work.

## Existing test level: extend it

`scenes/level.tscn` is already the project's main scene; its UID matches
`run/main_scene`. It instances `scenes/player/vr_controller.tscn` and the stereo
mirror. Its collision-enabled CSG combiner includes:

- A main 10-by-10 floor and a lower floor.
- A large wall and upright obstacles.
- A 1-by-1 m subtraction hole in the main floor near world X/Z (-4, 2.75),
  with a roughly 4 m drop to the lower floor, usable for fall/landing tests.
- Two inclined sections (approximately 15 degrees from their transforms) and
  connecting platforms.
- Three progressively raised boxes forming step-test geometry.
- A directional light with shadows and a forest environment.

Reuse these fixtures for baseline comparisons. Do not replace the level or create
a duplicate default test arena. Add clearly grouped fixtures only for missing
cases: a slope above the chosen walkable limit, a climbing attachment, grip behavior
for the existing weighted objects, and a repeatable impact source.

The updated level already includes `Dynamic/LightBox`, `MediumBox`, and `HeavyBox`:
all are 0.1 m cubes, with masses of 2, 5, and 10 kg respectively. Their collision
layer is 2 and mask is 3. Grabbing has not been implemented. Reuse these fixtures;
do not create replacements merely because the earlier review called them missing.
The 10 kg cube has a density of 10,000 kg/m³. Treat these as deliberate compact
mass-test fixtures rather than representative everyday props. Test hand/object
mass ratios and fast contacts at 72 Hz. CCD is not enabled explicitly in the scene;
its need and cost must be assessed on moving hands and objects, not assumed from
size alone.

`scenes/enemies/spikey.tscn` contains a small rigid sphere on collision layer 2
with mask 3. It is not instanced in the main level and has no enemy behavior script.
It may be useful as a starting reference for an impact prop, but is not an existing
combat or grabbing system.

## Existing controller and behavior

`scenes/player/vr_controller.tscn` contains a root startup script, sibling
`PlayerBody` and `XROrigin3D` nodes, tracked HMD/controllers, a configured
`StaticSkeleton`, its `SkeletonDebug` child, and an empty `PhysicalSkeleton`
placeholder under the XR origin.

`scripts/physical/player_body.gd` currently extends `CharacterBody3D`. It already
implements:

- Runtime creation of a height-adjusted capsule and a spherical ground cast.
- Room-scale following beneath the headset, including XR-origin correction when
  the body cannot follow through an obstacle.
- Head-directed left-stick movement using the `primary` action and a deadzone.
- Surface-projected walking targets, acceleration/braking, gravity, and limited
  air steering. Grounded movement omits gravity and targets constant surface speed.
- Conditional stair detection, explicit step placement, and floor snapping.
- Arm-pump running while both grips are held, blended into the walking target.
- Movement, grounded state, and ground-query input to the static foot solver.

The scene overrides walking speed to **1.5 m/s** and acceleration to **15**, while
the script defaults are 3 m/s and 30. The current default maximum step height is
0.3 m and maximum slope angle is 45 degrees. Record scene overrides when comparing
feel; existing acceleration settings are not interchangeable with new force limits.

This is useful existing locomotion, not the proposed force-driven implementation.
Do not transplant `move_and_slide`, direct step translations, or `_walking`
velocity assignment into a rigid-body motor and call that force-based behavior.
No physical hand drives, grip constraints, throwing system, or smooth/snap turning
are implemented in the reviewed player scene/scripts. The empty `PhysicalSkeleton`
node does not provide those features.

The action map already binds `primary` to both left and right thumbsticks and
provides grip actions. Reuse the right controller's `primary` for turning; do not
assume the right stick needs an action named `secondary`.

## Collision filtering: current state and required design

Project layer names are 1 = Static, 2 = Dynamic, and 5 = Player (bit value 16).
Naming a layer does not assign bodies to it. `PlayerBody` currently has no scene
or script override of its default layer 1 / mask 1. The boxes are on layer 2 with
mask 3, including layer 1. The player's own movement mask does not include those
boxes; this does not establish that every contact is impossible, because the
boxes' masks include the body's layer. The actual push/contact behavior has not
been tested, and must not be described as reciprocal dynamic-body interaction.

`probe_ground` supplies no query mask and excludes only the current body's RID.
Its default mask includes all layers, so loose boxes and future hands/held objects
can become reference-foot hits. A mask alone also cannot distinguish a valid floor
from an overhang on the same layer. Define explicit support layers, exclusions,
query origin/range, and surface eligibility. Decide deliberately whether selected
moving platforms are support; do not silently treat every dynamic object as floor.
Update body/hand/object masks together during migration and test both movement
queries and simulated contacts.

## Preserve the static foundation and its contracts

`scripts/static_skeleton/static_skeleton.gd` solves reference head, torso, arms,
hands/fingers, hips, legs, and feet. Its ground-aware reference posing does not
mean it performs collision response. Preserve its tuned solver and the player
scene's assigned trackers and proportion overrides.

The physical layer currently provides three specific interfaces:

| Interface | Contract to preserve or deliberately adapt |
| --- | --- |
| `ground_probe(from, to)` | Callable returning `{position, normal}` or an empty dictionary. The existing implementation raycasts and excludes the player body. |
| `body_grounded` | Whether feet should use supported poses or transition to hanging/landing behavior. |
| `commanded_travel` | World-space movement intent used for stride direction and length; not simply measured body velocity. |

The static layer falls back to the XR-origin floor plane if no probe/hit is
available. Losing the callback can therefore silently flatten reference foot
placement. A replacement probe must exclude the new player bodies and use explicit
world collision filtering without excluding legitimate supporting surfaces.

Current physics-process order is body **-100**, static solver **-90**, debug
visualization **-89**. The body updates the origin and publishes locomotion state
before static solving. A hand motor consuming static poses introduces another
dependency. Specify which snapshot it reads and how physics integration and origin
updates are sequenced; do not assume process priorities alone define rigid-body
solver callback order. Avoid same-step circular corrections and two origin writers.

The static solver also requests ground rays for its reference poses. The proposed
single locomotion sphere sweep is not a claim that the entire controller performs
only one query per tick. Profile these existing queries before changing them.

`SkeletonDebug` renders reference trackers as joints/bones, including fingers.
It is not the final visual skeletal layer and will not automatically show blocked
physical hands. Preserve it and add distinguishable physical-hand/target debug
visuals for the prototype.

## Performance and deployment context

Godot 4.7, Mobile, Jolt, and 72 physics ticks are configured. XR startup requests
72 Hz and follows reported refresh changes. Preserve this behavior.

The mirror creates two reflection viewports, each 1536 by 2560 pixels at its
default size/resolution, and updates both while the viewer is in front. It is
valuable for pose inspection but a significant potential rendering workload.
Measure physics separately and compare whole-frame results with mirror updates
enabled and disabled. Actually disable viewport updates for the comparison;
hiding its mesh alone is not sufficient. No mirror bottleneck has been measured.

The level also has shadows, a procedural environment, CSG collision, and debug
meshes. Record those conditions in performance results instead of attributing
all frame cost to the physical motor.

No project-owned automated test suite or export preset was found in this review.
Quest deployment readiness is therefore unverified. Local XR Tools and Godot AI
add-ons are referenced but ignored by Git; a clean checkout needs those dependencies.
`CLAUDE.md` is also currently ignored by Git, so these tracked-intent documents
must carry the essential design and handoff details for other checkouts.

## Migration questions to resolve before replacing the body

- **Room-scale following and head obstruction:** `_follow_headset` currently uses
  `move_and_collide` and pulls the origin back when blocked. Specify how bounded
  forces follow real-world steps without overwriting dynamic velocity, how body
  lag is handled, and what the player sees when the real head crosses a virtual
  wall. This is a first-prototype design question, not a solved migration detail.
- **Crouching and capsule growth:** `_fit_body` currently changes capsule height
  every tick. Do not copy that blindly to the dynamic body. Define foot anchoring,
  clearance checks before expansion, and behavior under a low ceiling. Test contact
  pops and moving supports when shrinking or standing up.
- **Transform ownership:** the empty `PhysicalSkeleton` is under `XROrigin3D`.
  Prefer body and hand physics nodes under a stationary world-space parent, outside
  the rig they help move. Alternatively, explicit top-level transform isolation
  needs validation. Check movement, recentering, and snap turns in Godot 4.7;
  inherited origin motion must not become unintended physics-body teleportation.
- **Jolt capabilities:** a documentation check was performed against the
  [Godot 4.7 Jolt integration guide](https://docs.godotengine.org/en/4.7/tutorials/physics/using_jolt_physics.html).
  Unsupported settings include PinJoint bias/damping/impulse clamp, HingeJoint
  bias/softness/relaxation, SliderJoint angular settings and several soft-limit
  settings, ConeTwist bias/relaxation/softness, and Generic6DOF limit softness,
  restitution, damping, and ERP. Limit damping is not the same as motor/spring
  damping. Select the actual drive and grip properties explicitly and run a small
  installed-engine behavior test; documentation review is not that test.
- **XR Tools reference:** the installed `hands/collision_hand.gd` extends
  `XRToolsForceBody`, whose base is `AnimatableBody3D` in
  `objects/force_body/force_body.gd`. It is not a CharacterBody3D in this checkout.
  It moves kinematically, uses `top_level = true`, and the base can apply impulses
  to contacted bodies. It does not implement the proposed reciprocal player-body
  coupling. Use it as a collision/target-handling reference, not a drop-in motor.

## Baseline checkpoint

The reviewed working tree has uncommitted settings, layer names, level fixtures,
XR startup, README, ignore rules, and untracked controller documents. Review and
commit an intentional baseline before prototype code changes so the current
behavior can be recovered and compared. No commit was created by this review.
Do not indiscriminately stage unrelated edits. `CLAUDE.md` remains local and ignored;
the README should link to the repository controller documents instead.

## Recommended implementation sequence

1. Capture the existing level's movement, stairs, crouching, room-scale correction,
   static foot placement, and arm-pump running as the comparison baseline.
   Simulated baseline done; headset session pending. See [3 - locomotion_baseline.md](3%20-%20locomotion_baseline.md).
2. Resolve the migration questions above in a concrete proposal: room-scale and
   head obstruction, capsule resizing, hierarchy, collision filtering, verified
   motor/grip properties, force coupling, and update/origin ownership.
   Proposed in [4 - physical_body_proposal.md](4%20-%20physical_body_proposal.md); awaiting decisions.
3. Replace the active character-body movement with the compact dynamic body and
   bounded slope-compensated motor. Keep only one active body/origin authority.
   Preserve the static contracts and expose tuning settings with units.
4. Add driven physical hands and a minimal grip/climbing connection; reuse the
   existing 2/5/10 kg boxes and floor-drop fixture. Check reciprocal force transfer and recovery.
5. Add smooth/snap right-stick turning with safe target coordination. Grips during
   turns need an explicit policy. Keep this a separate increment if coupling is
   not yet stable.
6. Validate stairs using the existing step geometry before choosing an approach.
   Do not replace it with collision ramps without agreement. Preserve arm-pump
   running or explicitly agree to defer it; do not silently remove existing behavior.
7. Profile at 72 Hz on Quest 3S with the rendering conditions recorded. Expose
   physics timing and target separation; distinguish estimated from measured costs.

The first milestone can stop after body/hand coupling, basic gripping/climbing,
and slope locomotion work. Report deferred turning, stairs, running, or recovery
work explicitly; that milestone is not a feature-complete replacement controller.

## Suggested starting instruction for Claude

> Read CLAUDE.md when available and all documents under documents/player_controller.
> Review scenes/level.tscn, scenes/player/vr_controller.tscn, and their scripts before
> proposing changes. Extend the existing test level; preserve the static solver,
> tracker assignments, ground_probe/body_grounded/commanded_travel contracts, and
> existing XR refresh handling. Propose the minimal dynamic body and hand prototype,
> explaining force transfer, ground support, callback sequencing, and single-owner
> XR-origin movement before coding. Reuse the existing slopes and steps and add only
> missing interaction fixtures. Resolve the documented migration questions first,
> including room-scale/head obstruction, capsule growth, hierarchy, masks, and
> installed Jolt joint behavior. Reuse the floor drop and 2/5/10 kg boxes.
> Identify migration effects on room-scale movement,
> stair traversal, and arm-pump running. Expose tuning and debug measurements,
> compare against the current behavior, and report deferred features. Validate
> script/scene loading separately from headset feel and Quest 3S performance;
> account for the stereo mirror and debug rendering when profiling.

## Verification performed during this review

- Existing `player_body.gd` passed Godot 4.7.2's headless script check.
- The main scene ran for three headless frames with XR disabled. The startup script
  emitted its expected "Open XR not initialized" error; no additional errors were
  reported in that short run.
- No headset interaction, graphical mirror check, Android export, or on-device
  performance validation was performed.

The later fixture/filtering review was source-based; the earlier headless result
does not validate contact behavior of the newly added boxes.
