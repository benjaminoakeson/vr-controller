# Player controller overview

## Purpose and current state

The player controller should give the player the freedom to intuitively interact
with the world around them. The physical layer supplies the feeling of being
present in that world; the skeletal layer makes that presence visible through a
believable character model. Body-attached interfaces make information and actions
accessible without separating the player from the experience.

The controller consists of four cooperating layers:

1. Static
2. Physical
3. Skeletal
4. GUI

The existing static layer is mostly complete and is the baseline to preserve.
Current collision and physical detection are lightweight foundations that need
replacement with more capable systems. This document defines responsibilities
and design direction; it does not claim that the proposed systems already exist.
The shared mass-and-strength direction and lightweight dynamic-body proposal are
detailed in [1 - physical.md](1%20-%20physical.md). See
[the repository review and handoff](2%20-%20prototype_handoff.md) before implementing;
the project already includes a test level and functional preliminary locomotion.

## Layer responsibilities

| Layer | Primary question | Owns |
| --- | --- | --- |
| Static | Where does the player's tracked and inferred body want to be? | Unconstrained reference poses and body structure. |
| Physical | Where can the player move, and how do they interact with the world? | Collision response, movement, physical poses, and interaction constraints. |
| Skeletal | How should the character look in the resolved physical pose? | Visual mesh, bone posing, and visual fitting. |
| GUI | What information and controls should be available around the body? | Body-attached displays, menus, and interface presentation. |

## 1. Static layer

The static layer describes the player's structure without collision response to
the world. "Static" means unconstrained by world collisions, not motionless.
It combines tracked points with inferred body points to produce the reference
that the physical layer attempts to follow.

Responsibilities:

- Represent the player's reference body positions and rotations.
- Incorporate headset and controller tracking, alongside inferred points such
  as the torso, limbs, and feet.
- Provide a consistent reference interface so a solved point can later be
  replaced by a tracked point without redesigning downstream layers.
- Maintain the existing body-solving behavior as the foundation for development.

The existing reference solver receives ground observations and locomotion state
from the physical layer for foot placement; this is not collision response.
Preserve its `ground_probe`, `body_grounded`, and `commanded_travel` interfaces.

The static layer must not resolve world collisions, push objects, or change its
reference pose to hide a blocked physical hand. The difference between intended
and physically achievable poses is valuable input to the physical layer.

The existing `StaticSkeleton` is part of this static layer despite its name. It
is distinct from the visual skeletal layer described below.

## 2. Physical layer

The physical layer handles collisions with the world and movement of all kinds.
It consumes static reference poses and movement/interaction intent, then resolves
what the player's body and held objects can actually do.

It owns the player's interactions with the world, including hands touching
surfaces, pushing, grabbing, holding, manipulating, releasing, and throwing.
It should provide the physical foundation for climbing, tools, weapons, and other
gameplay without placing all behavior in one large controller script.

### Proposed systems within the layer

- **Body and movement:** room-scale motion, artificial locomotion, turning,
  crouching, grounding, slopes, steps, falling, and movement modes such as
  climbing. These systems must coordinate rather than each moving the rig alone.
- **Collision and contact:** body and hand collision shapes, surface detection,
  penetration handling, fast-motion handling, and collision filtering.
- **Physical hands:** follow static targets while respecting contact, reach,
  and the chosen limits on strength and separation from tracked hands.
- **Grabbing and manipulation:** select valid grips, establish and release
  constraints, coordinate two-handed interactions, and define held-item collisions.
- **Throwing:** calculate release motion consistently, including angular motion,
  with an explicit policy for tracked versus physically achieved velocity.
- **Body/world coupling:** decide how pushing, pulling, climbing, impacts, and
  held objects affect the player's body and locomotion.
- **Recovery:** handle impossible targets, trapped hands, tracking loss,
  teleportation/recentering, and excessive separation without explosive forces.
- **Interaction feedback:** publish contact, grab, release, and impact events for
  haptics, sound, and gameplay consumers.

These are responsibility boundaries, not a requirement for one script or node
per bullet. Compose systems where it improves clarity and reuse.

### Physical authority

The physical layer owns resolved body poses and world interaction state. Assign
one owner to each physical transform and to locomotion changes of the XR origin.
Other layers must not independently overwrite these results.

Headset tracking remains under the XR runtime's control. A physical head/body
proxy and its visual model do not automatically become the camera's authority.
Wall penetration, body displacement, and any camera correction require an
explicit comfort policy; a simulated impact must not accidentally shake the view.

## 3. Skeletal layer

The skeletal layer is strictly visual. It presents a polished 3D character model
whose pose follows the physical layer's resolved positions and rotations.

Responsibilities:

- Map physical reference points to the character model's bones.
- Fit limbs and joints visually, using inverse kinematics or other visual posing
  where necessary between the available physical targets.
- Present appropriate hand and finger poses for resolved interactions.
- Support different character proportions without taking authority over physics.
- Provide visual attachment points where useful for the GUI and equipment.

The model must show a blocked hand where the physical hand is, not at an
unreachable static target. Visual animation and smoothing must not feed forces
back into the physical layer or change collision outcomes. This layer does not
own locomotion, grabs, damage, or world collision response.

## 4. GUI layer

The GUI layer provides health, stamina, quick menus, and other player-facing
displays and controls. Interfaces wrap around or attach to appropriate parts of
the player's body instead of assuming a conventional flat-screen HUD.

Responsibilities:

- Anchor displays to defined body locations and maintain comfortable readability.
- Present health, stamina, and other values supplied by gameplay systems.
- Present quick-menu choices and emit action requests to the appropriate system.
- Support interaction using the resolved physical hands where applicable.
- Define visibility, scale, handedness, and occlusion behavior for each interface.

The GUI displays gameplay state; it does not own vitals or apply movement and
physics directly. Visual bone anchors can place a display, but authoritative
interaction tests must use an explicitly defined physical/interface target rather
than letting cosmetic bone motion alter the simulation.

## How the layers cooperate

The main pose flow is:

```text
XR tracking + body calibration
              |
              v
     Static reference poses
              |
              v
     Physical resolution <--- movement/input intent + world contacts
              |
              +-----------> Skeletal model
              |
              +-----------> GUI body anchors

Gameplay state -----------> GUI displays
GUI action requests ------> Relevant gameplay/interaction systems
```

Use explicit coordinate spaces and a consistent pose snapshot for each simulation
step. Locomotion changes the XR origin and therefore the world-space reference
poses; apply that change once through the agreed owner. Avoid a feedback loop in
which the static and physical layers repeatedly correct one another in the same
step. Visual presentation reads resolved results without changing simulation.

Example: when the real hand moves into a wall, its static target continues to
represent the intended position. The physical hand stops at the wall according
to the selected interaction policy. The skeletal hand follows that stopped pose,
and a wrist display follows its chosen body anchor. How much the body moves,
how resistance feels, and how the hand recovers remain physical-layer decisions.

## Choosing the physical method

The desired feel is not determined by a physics node type alone. It depends on
tracking responsiveness, collision authority, permitted hand lag, player strength,
object inertia, body coupling, and recovery behavior. The following approaches
are candidates, not approved implementation decisions.

| Approach | How it works | Potential benefit | Main tradeoff |
| --- | --- | --- | --- |
| Kinematic | Move collision-aware body/hand proxies toward targets using sweeps and explicit movement rules. | Direct control over responsiveness and recovery. | Weight, reciprocal pushing, and some interactions require authored responses. |
| Active rigid-body | Drive simulated body parts toward reference poses with forces, torques, and constraints. | Contact, inertia, and reciprocal forces can contribute directly to the feel. | More difficult tuning, unwanted oscillation, solver cost, and potentially uncomfortable body motion. |
| Hybrid | Use controlled body locomotion with physically driven hands and held objects, joining them through explicit rules. | Tune hand/object physicality separately from body movement and comfort. | The boundary between systems needs carefully designed force transfer and recovery. |

### Current direction after discussion

Use a shared model of mass, bounded strength, and reciprocal force transfer so
pushing, climbing, weapons, and impacts behave consistently. Body movement should
not be gated by hand count or an explicit bracing mode.

The current prototype proposal is one upright dynamic capsule and two physical
hands, with bounded drives, ground support, and slope-compensated locomotion.
This replaces the earlier recommendation of a character-like body with conditional
hand-driven displacement. Detailed formulation and tuning remain to be validated.
See [the physical design](1%20-%20physical.md) for the controlling specification.

A detailed visual skeleton does not require a fully simulated ragdoll. Preserve
the static solver and add physical detail only where an interaction needs it.
The existing CharacterBody3D is a migration baseline, not the final architecture.

BONEWORKS and Blade & Sorcery can help us discuss resistance, weapon handling,
and body presence; A Township Tale can help frame tactile tools and everyday
manipulation. These are experience references, not claims about those games'
internal controller implementations.

### Questions to settle through discussion and prototypes

1. How should strength, support, and friction be tuned so gentle wall contact
   stays steady while sufficient effort can move the body?
2. How much separation between the real and virtual hands feels acceptable?
   What recovery behavior should occur when that separation becomes excessive?
3. Should heavy objects lag behind the hands, resist lifting, require two hands,
   or use a combination? How should strength limits work?
4. Should enemies and loose objects displace the player's body? Which effects
   should be conveyed through the model and haptics rather than camera movement?
5. When a held object is trapped, should the grip yield, slip, release, or remain
   firm up to a force limit?
6. Should throwing primarily reflect physical object motion, tracked hand intent,
   or a bounded blend? How do we prevent blocked-hand motion creating extreme throws?

## Performance and validation

Target standalone Meta Quest 3S with the Mobile renderer and the agreed 72 Hz
display/physics baseline. Follow confirmed runtime refresh rates as established
by XR startup; never assume fixed timestep constants in controller calculations.

Budget active bodies, contacts, constraints, and collision queries. Do not assume
the proposed dynamic-body approach is fast enough without measurement, or raise the global physics
rate to conceal instability. Test responsiveness, stability, and frame-time cost
together on the headset.

Use the existing `scenes/level.tscn`, which already contains floors, a wall,
ramps, steps, a floor opening for fall tests, 2/5/10 kg cube fixtures, and a stereo
mirror. Reuse these; add grip behavior, a two-handed object, a climbing grip, and
a steep-slope fixture only where missing, without replacing the arena. Exercise fast movement,
blocked grabs, trapped objects, release/throwing, tracking loss, and recentering.
Record hand separation, jitter, penetration, recovery behavior, and physics cost.
The first prototype should answer whether the chosen approach feels right before
expanding the complete controller.

## Scope of this overview

The four-layer structure and preservation of the static foundation are established
direction. The shared strength model is the chosen direction; the lightweight
dynamic-body implementation remains a proposal requiring prototype validation.
Detailed movement, contact, hand, grip, visual rig, and GUI specifications should
be developed in follow-up documents under this directory as decisions are made.
