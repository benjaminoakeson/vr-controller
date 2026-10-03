class_name PoseSnapshot
extends RefCounted

## The physical layer's output for one physics tick: where the body resolved
## to, and what the layer decided about the head and the view.
##
## The physical layer allocates one and overwrites it in place every tick.
## The visual, interface and debug layers read it and never write to it.

## Physics ticks published so far, and the tick's length in seconds.
var tick := 0
var delta := 0.0
## The body's feet in world space, as of the latest physics solve, in metres.
var body_position := Vector3.ZERO
## The body's velocity in world space, in m/s.
var body_velocity := Vector3.ZERO
## The collision capsule's height from the feet to its top, in metres.
var body_height := 0.0
## The collision capsule's radius, in metres.
var body_radius := 0.0
## How far the legs are drawn up: the capsule's bottom this far above the
## feet, in metres (climbing, 2026-09-28).
var body_tuck := 0.0
## Snap turns so far.
var turns := 0
## Whether the ground is holding the body up, and which way that ground faces.
var supported := false
## Whether the legs are lifting the body up a step, or lowering it down one.
var lifting := false
var stepping_down := false
var ground_normal := Vector3.UP
## Velocity of whatever the body stands on, in m/s.
var support_velocity := Vector3.ZERO
## Movement intent handed to the static skeleton: stick times top speed, in m/s.
var commanded_travel := Vector3.ZERO
## How much of a run the arms ask for, 0 for a walk to 1 for flat out.
var run_factor := 0.0
## Horizontal offset of the tracked head's footprint from the body's feet, in
## metres.
var head_lead := Vector3.ZERO
## How far the head has gone past the first surface between it and the body,
## in metres. Zero when the way is clear.
var head_obstruction := 0.0
## 0 to 1: how far the view should be blacked out for a relocation under way.
var blackout := 0.0
## How far the rig was carried this tick with the body's own movement, in metres.
var rig_carry := Vector3.ZERO
## How far the rig was pulled back because the body could not follow the head,
## in metres: the dynamic body's push-back past its lean limit, or the
## kinematic comparison body's full pull-back.
var rig_correction := 0.0
## The walking motor's force this tick, in newtons.
var motor_force := Vector3.ZERO
## What the hands carry along with the body, in kg (CapsuleBody.carried_mass).
var carried_mass := 0.0
## How many times the rig or body has been relocated (recentre, respawn).
var relocations := 0
## The physical hands, left then right: where they are and where they are
## driven to; how far apart those are, in metres; the drive's force limit, in
## newtons; and how many contacts each hand has started.
var hands: Array[Transform3D] = [Transform3D.IDENTITY, Transform3D.IDENTITY]
var hand_targets: Array[Transform3D] = [Transform3D.IDENTITY, Transform3D.IDENTITY]
var hand_separation := PackedFloat32Array([0.0, 0.0])
var hand_force := PackedFloat32Array([0.0, 0.0])
var hand_contacts := PackedInt32Array([0, 0])
## Each hand's target before the arm's strength shaped it (the static
## skeleton's hand, within reach); how far the arm dips at the shoulder (x)
## and wrist (y) under what it bears, in radians; and the torque each of
## those joints holds, N·m.
var hand_tracked: Array[Transform3D] = [Transform3D.IDENTITY, Transform3D.IDENTITY]
var arm_sag: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO]
var arm_holding: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO]
## Whether each hand is touching something right now.
var hand_touching: Array[bool] = [false, false]
## The most a hand's drive can push, in newtons; zero without physical hands.
var hand_strength := 0.0
## Each physical hand's palm box, in metres, in hand space, and how far its
## middle sits ahead of the hand's centre (toward the fingers, -Z).
var palm_size := Vector3.ZERO
var palm_shift := 0.0
## The physical finger bones, left hand then right, each hand thumb to little
## finger, root to tip (index = side * 15 + finger * 3 + phalanx): where each
## bone's joint is, with -Z along the bone; and each bone's radius and length,
## in metres (zero until the fingers are built).
var finger_bones: Array[Transform3D] = []
var finger_sizes := PackedVector2Array()
## Per hand: the largest gap between a physical finger joint's bend and the
## static skeleton's, and the average bend of the fingers' joints, in degrees.
var finger_error := PackedFloat32Array([0.0, 0.0])
var finger_bend := PackedFloat32Array([0.0, 0.0])
## Per hand: how many finger joints turned back this tick while their pose held
## still (a twitch).
var finger_reversals := PackedInt32Array([0, 0])
## The body parts (BodyParts.Part order): where each part's shape is, and the
## shape itself, to be read and not changed. A capsule's axis is its Y.
var body_parts: Array[Transform3D] = []
var body_part_shapes: Array[Shape3D] = []
## The physical body's joints (BodyParts.Joint order), where its parts meet,
## in world space: the neck and shoulders where the head has them, the elbows
## and wrists where the physical arms are, the hips, knees and ankles where the
## physical body stands. Each foot's sole (left, right), on the ground under
## its ankle: -Z toward the toes, +Y the ground's normal. Empty until the body
## parts are built.
var body_joints: Array[Vector3] = []
var body_soles: Array[Transform3D] = []
## How far each arm is stretched past its length to stay joined, in metres.
var arm_stretch := PackedFloat32Array([0.0, 0.0])
## How many body parts (not the capsule) something is pushing on, and which:
## bit n set for BodyParts.Part n.
var parts_pressing := 0
## Which of the player's bodies pushed on a loose prop in the last step, as
## bits: 1 the body, 2 the left hand, 4 the right hand.
var prop_contact := 0
## Where the heaviest loose prop pushed in the last step is, and its mass in
## kg; zero when none was.
var prop_position := Vector3.ZERO
var prop_mass := 0.0
## Per hand, its grab (HandGrab.State: 0 idle, 1 seating, 2 holding); the
## hand's grab point and the object's (the candidate's while idle; the hand's
## own when there is none), in world space; and how far apart they are.
var grab_state := PackedInt32Array([0, 0])
var grab_hand_points: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var grab_object_points: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var grab_gap := PackedFloat32Array([0.0, 0.0])
## Per hand, how far what it holds has turned in it since its grip joint was
## made, in degrees (HandGrab.held_turn).
var grab_turn := PackedFloat32Array([0.0, 0.0])
## Per hand, its part in holding an object with the other hand (0 none, 1 the
## lead, 2 the second hand), and whether the two aim it between them.
var grab_role := PackedInt32Array([0, 0])
var grab_aiming: Array[bool] = [false, false]
## Per hand, the mass of what it is pulling in or holding, in kg, and how far
## its centre of mass is from the hand's centre, in metres; zero when it
## holds nothing.
var grab_mass := PackedFloat32Array([0.0, 0.0])
var grab_offset := PackedFloat32Array([0.0, 0.0])
## How many props each hand (left, right) has thrown, the velocity the last
## one left with, and the velocity its own last step gave it, in m/s
## (2026-09-30).
var throws := PackedInt32Array([0, 0])
var throw_velocity: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var throw_own_velocity: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
## How many strikes each hand (left, right) has made (the strike model,
## 2026-09-30: by the hand itself, by what it held, or by what it let go of),
## the last one, and where that one came from (HandStrikes.Source).
var strikes := PackedInt32Array([0, 0])
var last_strikes: Array[Strike] = [null, null]
var strike_sources := PackedInt32Array([0, 0])
## Whether each hand (left, right) holds a Climbable hold, and whether either
## does: the player is climbing (2026-09-28).
var grab_on_hold: Array[bool] = [false, false]
var climbing := false
var parts_pressed := 0
