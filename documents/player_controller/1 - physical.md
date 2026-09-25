# Physical layer: mass, strength, and interaction

## Status and purpose

This document records the direction established through discussion after
[the controller overview](0%20-%20player_controller_overview.md). It supersedes
that overview's initial suggestion of conditionally enabling body movement when
bracing or climbing. The new direction is a physically driven body and hands with
a shared model of strength and weight. Exact implementation and tuning remain
subject to prototyping; this document does not describe completed functionality.

The goal is a controller that lets the player intuitively interact with the world
and feel the weight of objects and their own body. Climbing, weapon handling,
pushing, lifting, throwing, and receiving impacts should follow the same physical
principles. They should not feel like separate mechanics with unrelated rules.

## Existing implementation and migration baseline

The project already has a test level, `scenes/level.tscn`, with floors, a wall,
ramps, steps, a floor-drop opening, 2/5/10 kg cube fixtures, and a stereo mirror.
Extend it rather than building a replacement
arena. The current `PlayerBody` is a `CharacterBody3D` with room-scale collision
correction, slope-aware walking, stairs, and arm-pump running. These are existing
behaviors to compare against, not evidence that the force-driven design below
has been implemented.

Preserve the static solver's `ground_probe`, `body_grounded`, and
`commanded_travel` connections and scene tuning. Its reference feet already use
world-ground observations. The single proposed locomotion sweep does not include
the static solver's existing ground rays. Physical hands and grips are still absent;
`PhysicalSkeleton` is an empty placeholder. See
[the repository review and implementation handoff](2%20-%20prototype_handoff.md)
for scene wiring, update ordering, performance context, and migration steps.

## Desired feel

The player has a weighty body. A slight push against a wall should produce little
or no perceptible body displacement. Adding a second hand must not automatically
unlock movement. Strong enough combined effort should be able to move the body.

Climbing must use that same strength model. Attached hands transmit effort to
the body, and the available strength determines how effectively the player can
support and lift their own weight. Handling heavy weapons and being struck by
heavy objects should remain consistent with that model.

The developer must be able to tune this behavior directly. The intended feel is
more important than reproducing human biomechanics exactly, but adjustments should
remain coherent across interactions.

Avoid rules such as:

- "Two hands touching a wall means the body can move."
- "This is a heavy object, so enter a separate heavy-object movement mode."
- "Climbing ignores body weight and translates the player directly."

Contact detection and simulation still run each physics step. The aim is to avoid
special-case eligibility checks for ordinary force transfer, not to eliminate
physics updates or interaction state.

## Foundation: intent and physical result

Preserve the existing static layer as the source of unconstrained reference poses.
It describes where the player intends their body and hands to be. The physical
layer describes where they actually are after forces, contacts, and constraints
have been resolved.

Physical muscles or motors pursue those reference poses using limited forces and
torques. If the world prevents a hand or held object from following, the physical
pose may lag behind the reference. The skeletal layer displays that resolved pose;
it must not visually bypass a collision by snapping to the static target.

Controllers measure motion rather than actual effort against a virtual surface.
We therefore need to infer effort from pose disagreement and relative velocity.
The mapping from disagreement to force is a central tuning decision: a blocked
hand with increasing target separation can express increasing effort, up to its
strength limit. The precise response curve and safe separation limits are open.

## Mass, support, and strength

Mass resists acceleration; it does not by itself create a force threshold below
which a free body cannot move. Even small net forces accelerate an unsupported
body. For the intended planted feeling, ground support, friction, balance, and
damping must work together with body mass.

When standing, those systems can make small pushes have little perceptible effect.
When hanging, the hands and grips must support the player's weight against gravity.
Raising the body requires sufficient upward force beyond that support requirement.
This difference should follow the physical situation rather than a hand-count rule.

Strength defines the available motor force and torque. Mass, gravity, contact,
and rotational inertia define what that effort must overcome. A long, head-heavy
weapon should resist rotation differently from a compact object with equal mass.

A shared strength model does not require one identical limit for every action.
Arms, wrists, grips, and leg support have different functions. A global strength
multiplier can scale a small set of related settings without erasing those
differences. Whether strength changes with progression or stamina is not decided.

## Force transfer must be explicit

Driving a hand toward a world-space target does not automatically transfer its
effort back to the player's body. Without coupling, the hand acts as though it
has an external power source, undermining body weight and climbing.

The implementation must connect hand effort to the body through appropriate
constraints or paired forces and torques. Account for attachment points and
rotational effects, and avoid applying the same reaction twice through both a
constraint and a manual force correction.

Two hands contribute through their actual connections and available strength.
Their combined result depends on contact, geometry, and load; it is not a fixed
bonus awarded when a second hand touches something.

Locomotion and balance also need defined sources of support. They must not
silently cancel every hand reaction with an unlimited body-position motor.
Conversely, moving hands freely in the air must not create unsupported propulsion
through incorrectly applied internal forces.

## Proposed standalone representation

Begin with a compact physical model:

| Element | Responsibility |
| --- | --- |
| One dynamic main body | Represents the player's primary mass and receives world and interaction forces. |
| Two physical hands | Pursue static targets, collide, and transmit manipulation forces. |
| Muscle drives | Apply bounded, damped forces and torques between the relevant physical elements. |
| Grip connections | Attach hands to held objects or climbing surfaces and transmit loads. |
| Support and balance system | Provides grounded support and controlled locomotion without erasing weight. |

This is the proposed first prototype, not a final node hierarchy. Preserve clear
ownership of each physical transform and use composed systems where useful.

Arms, legs, and fingers may initially be visually posed rather than individually
simulated. The skeletal layer can produce a detailed character from a simpler
physical representation. Add physical bodies or collision shapes only where an
interaction demonstrates a need for them.

The existing lightweight collision/body implementation will need replacement or
substantial revision. Its current behavior is not a constraint on the new design.

## How interactions should follow the model

### Pushing and touching

Hands encounter surfaces through collision. Continued reference motion generates
limited effort. The resulting body motion depends on reaction forces, body mass,
support, and friction. Gentle wall contact should remain steady; stronger effort
can displace the body without an explicit "allow pushing" switch.

### Climbing

A deliberate grab establishes an attachment to a valid surface or hold. Moving
the intended hands relative to the attached physical hands generates effort that
transfers to the body. Supporting and lifting the body must account for its weight.
One-handed and two-handed climbing use the same mechanism with different available
connections and loads.

Grip acquisition and release remain explicit interactions. Insufficient strength,
slipping, and grip failure need defined behavior; their exact rules remain open.

### Holding and swinging objects

Held objects retain meaningful mass, inertia, and world contact. Limited arm and
wrist strength produces resistance when lifting or rotating them. A second grip
changes the available force and leverage through the physical connection.

The model must handle an object wedged against geometry without accumulating
unbounded forces. Whether the grip yields, slips, or releases is a tuning/design
decision rather than a reason to bypass collisions.

### Impacts

Incoming objects affect the body through the same mass and contact model. Their
motion and mass matter; "heavy" is not an independent knockback flag. Damage rules
may consume impact information but should not duplicate physical impulses.

### Throwing

Release should preserve a coherent relationship between effort and resulting
object motion. The exact choice of physical velocity, tracked velocity, or a
bounded blend is still open. A blocked hand must not create an extreme throw
solely because its unconstrained reference moved rapidly through a wall.

## Locomotion

### Scope and ownership

Artificial movement uses smooth locomotion only; teleport locomotion is outside
the intended movement options. The right stick supports a player-selectable choice
of smooth turning or snap turning. Physical room-scale movement remains supported.

Locomotion belongs in the physical layer and acts on the same weighted body as
hand reactions, climbing, gravity, and impacts. Input supplies movement intent;
the static layer supplies reference poses; the skeletal layer follows the resolved
physical result. No second controller should independently reposition the body.

### Lightweight controller proposal

Prototype a single upright `RigidBody3D` capsule with pitch and roll locked, a
short downward sphere sweep for ground detection, and a bounded walking motor.
Capsule contacts provide normal ground support. Limited assistance may address
small ground gaps and steps without simulating physical legs, feet, or balance
joints. Visual leaning and foot placement belong to the skeletal layer.

This retains physical translation, weight, and impact response while deliberately
omitting physical toppling. A `CharacterBody3D` is not the preferred starting point
because body responses to forces would need additional authored integration.
The proposed rigid-body design still requires on-device performance validation.

Separate movement intent, ground detection, walking/support forces, step handling,
and turning into clear responsibilities. Reuse ground-query results within each
physics step rather than having each system repeat the same query.

### Slope-compensated walking

The desired behavior is approximately consistent walking speed along the surface,
whether traveling uphill or downhill, while sufficient strength and traction are
available. Uphill movement needs additional effort to counter gravity. Downhill
movement needs less forward effort and, when necessary, active uphill braking.

For supported movement on a walkable surface:

1. Project the input direction onto the ground plane and normalize it, preserving
   the original analog stick magnitude separately. Handle a near-zero projected
   direction without normalizing it.
2. Multiply that surface direction by walking speed and stick magnitude to obtain
   the desired surface velocity. Speed is measured along the slope, not as its
   horizontal projection.
3. Subtract the supporting surface's velocity at the support point from the body
   velocity, then project the result onto the ground plane.
4. Compute a force that approaches the desired relative surface velocity and
   compensates for gravity tangent to the surface.
5. Limit the combined force by available leg strength and traction before applying
   it. Gravity compensation must not bypass the strength limit.

Conceptually, using a unit ground normal `n`:

```text
gravity_tangent = gravity - n * dot(gravity, n)
relative_velocity = body_velocity - support_velocity
surface_velocity = relative_velocity - n * dot(relative_velocity, n)
velocity_error = desired_surface_velocity - surface_velocity

requested_force = body_mass * (
    velocity_error / response_time - gravity_tangent
)
motor_force = limit_magnitude(requested_force, available_leg_force)
```

This is a design equation, not final integration code. `response_time` must be
positive and tuned for the actual physics timestep; excessively short values can
produce abrupt or unstable responses. Apply force through the physics integration
path without multiplying an engine-integrated force by delta a second time.

When walking uphill, gravity compensation increases the requested uphill force.
When walking downhill, it reduces the downhill force or produces uphill braking
to prevent unwanted acceleration. Feedback corrects remaining speed error. The
system attempts consistent speed; heavy loads or insufficient traction can still
slow the player because force is limited.

When supported and idle, target zero surface velocity to represent standing
effort on walkable slopes. This assistance remains bounded so it cannot instantly
cancel hand reactions or incoming impacts.

### Steep slopes and loss of support

Beyond the maximum walkable angle, disable the ordinary standing/walking motor
and its gravity compensation. Gravity should then drive sliding. Tune contact
friction deliberately: removing motor assistance alone does not guarantee sliding
if friction can still hold the body. The exact steep-surface friction policy is
an implementation decision to validate.

Do not apply grounded compensation while airborne or hanging without ground
support. Any air control is a separately limited force and remains to be tuned.
A nearby downward probe hit is not, by itself, permission to pull a launched or
climbing player back to the floor. Ground-support classification must account for
distance and separating motion.

### Friction, braking, and impacts

Incoming contact impulses create knockback; friction and bounded motor effort
dissipate it. Never overwrite body velocity with stick velocity or clamp total
body speed to walking speed. A hit, fall, slide, or pull may legitimately move the
player faster than their walking target.

The walking motor gradually regains control through its force limit. Avoid
combining excessive contact friction, motor braking, and global damping, which
would erase momentum and make the body feel glued down. Ground assistance must
allow upward launch and must not behave as unlimited adhesion.

### Stairs and small steps

Ascending and descending stairs are required, but the final method remains open.
The lowest-complexity proposal for authored staircases is a smooth player collision
ramp with visible steps. Hands and objects can use detailed stair collision through
appropriate filtering, while visual feet fit the rendered steps. This is a proposed
content convention, not an agreed requirement.

For irregular steps, use conditional shape sweeps when supported movement encounters
an obstacle: check maximum step height, overhead/forward clearance, and a valid
landing surface. Prototype bounded, collision-aware lifting assistance rather than
continuously searching for stairs or expecting the capsule to climb vertical faces.
Descending assistance should follow nearby steps without snapping across large drops.

### Smooth and snap turning

Both turn modes share one turning coordinator and a pivot near the player's current
standing position. Smooth turn uses a configurable angular speed; snap turn uses a
configurable angle and stick rearming behavior to prevent accidental repeated turns.

Snap turning is a deliberate orientation adjustment, not a large torque impulse.
Coordinate the XR origin, body, reference targets, and affected physical hands so
turning does not create artificial throw velocity or excessive drive forces.
Collision clearance and turning while holding a world-anchored grip need explicit
policies before implementation. Preserve runtime head tracking.

### Tuning and validation

Initial locomotion controls should include walking speed (m/s), response time (s),
maximum leg force (N), and maximum walkable angle (degrees). Ground friction,
support distance, maximum step height, and turn settings also need exposed tuning.

Slope compensation reuses the ground normal and adds only vector arithmetic; it
requires no additional collision queries by itself. Start with one shared ground
sweep per physics tick and add further probes only where tests demonstrate a need.

Compare speed along flat ground and uphill/downhill slopes at equal stick input.
Test standing on a slope, transitioning into a slide, walking under load, being hit
while moving or idle, upward launch, stair ascent/descent, and turning during grabs.
Check that compensation improves consistency without removing weight or introducing
jitter, and measure the complete controller on Quest 3S at the 72 Hz baseline.

## Tuning controls

Expose meaningful units, sensible ranges, and related settings together. Avoid
burying the feel in scattered constants.

| Control | Intended influence |
| --- | --- |
| Body mass and mass distribution | Resistance to translation and rotation; weight during climbing. |
| Hand/object mass and inertia | Contact response and resistance during manipulation. |
| Maximum muscle force and torque | Limits on lifting, pulling, and controlling rotation. |
| Pose-following stiffness | How rapidly disagreement generates effort. |
| Damping | Oscillation control and the restrained versus springy feel. |
| Grip strength/compliance | Load transmission and how an attachment yields. |
| Ground support, friction, and balance | How planted the body feels and how it reacts to effort. |
| Separation and recovery limits | Handling of unreachable targets and interrupted tracking. |

Stiffness is not maximum strength: a drive can respond promptly while still having
a limited force budget. Tune those independently. All time-dependent calculations
must use the simulation timestep rather than assume a particular tick duration.

## Comfort, ownership, and recovery

Physical body movement and XR camera handling require deliberate coordination.
Keep runtime head tracking intact; do not directly bind camera rotation to a
tumbling physical body. How body displacement affects the XR origin, and how
wall penetration is handled, need a specific comfort policy.

Use one owner for XR-origin movement and avoid feedback loops between reference
poses and the body pursuing them. Cosmetic smoothing must not modify simulation.

Explicit handling is still required for tracking loss, recentering, spawn/respawn relocation,
trapped objects, invalid grips, and excessive hand separation. These recovery
cases must not generate explosive forces or erase normal physical resistance.
Their detailed policies remain to be designed.

## Standalone feasibility and constraints

This approach is plausible for Quest 3S at the agreed 72 Hz baseline, but remains
unproven until measured on that headset. Use Godot's Mobile renderer and Jolt.
Follow the project's confirmed-runtime-refresh policy and do not hard-code a
1/72-second timestep.

The small number of strength calculations is not expected to be the main cost.
Contacts, connected constraints, and the solver work needed for stability are
the more important risks to investigate.

- Begin with simple colliders and few active physical bodies.
- Limit and damp drives instead of aggressively chasing impossible targets.
- Evaluate mass ratios between connected bodies for stability.
- Use fast-motion collision protection selectively where testing requires it.
- Verify that the chosen joint/motor controls are supported by Godot's Jolt
  integration before depending on them; some exposed joint properties are unsupported.
- Develop and test at 72 Hz rather than relying on higher physics rates to conceal
  instability. Increasing solver work must be justified by measured results.
- Profile with representative objects and enemies as well as the controller alone.
  Leave room for the rest of the game and sustained thermal load.

Reference: [Godot's Jolt integration guidance](https://docs.godotengine.org/en/stable/tutorials/physics/using_jolt_physics.html).
Check guidance against the installed engine version when implementing.

## First prototype and acceptance criteria

Build the weighted body and two driven hands into the existing player/test-level
setup. Reuse its floors, wall, slopes, and steps; add a climbing grip and differently
balanced-object variants only where the existing 2/5/10 kg cubes do not cover
the test. Reuse the floor opening for fall/landing checks. This
prototype should establish the common physical behavior before the complete
controller is built around it.

Evaluate:

1. Gentle and strong wall pushes with one and two hands: believable continuous
   responses without hand-count gates or unwanted jitter.
2. Hanging and pulling up: body weight matters and strength settings predictably
   change the outcome.
3. Lifting and swinging: mass and balance create understandable resistance.
4. Impacts: the body responds consistently without unintended camera rotation.
5. Blocked objects and release: no explosive recovery or artificial throw energy.
6. Free hand motion: internal drives do not create unsupported body propulsion.
7. Tracking interruption and recentering: safe, predictable recovery.
8. On-device load: stable physics and frame times during representative sustained
   play, with sufficient room for other gameplay systems.

Record hand-target separation, oscillation, penetration, recovery behavior, and
physics timing alongside subjective feel. Numerical budgets and tolerances still
need to be established through Quest 3S measurements.

## Remaining decisions

Before replacing the body, resolve room-scale following/head-wall behavior,
clearance-aware capsule resizing, world-space physics-node placement, and explicit
collision/support filtering. Verify chosen Jolt motor/grip settings in the installed
engine. The [updated handoff](2%20-%20prototype_handoff.md) records current fixtures,
mask mismatches, the XR Tools inheritance chain, and the required baseline checkpoint.


- Exact motor/constraint formulation and force-transfer implementation.
- Detailed ground-support and traction implementation, stair method, and motor tuning
  within the slope-compensated locomotion direction above.
- Turn collision handling and behavior while attached to the world.
- Body mass, strength settings, and the effort response curve.
- Grip compliance, strength limits, and failure behavior.
- Hand separation limits and recovery behavior.
- Throw velocity policy and XR-origin/camera comfort policy.
- Any relationship between stamina, progression, and physical strength.

The shared weight-and-strength direction is established. These details should be
resolved through focused discussion and the prototype, rather than assumed to be
settled by this document.
