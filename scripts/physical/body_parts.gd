class_name BodyParts
extends Node

## The player's physical body beyond the capsule and the hands: collision
## shapes for the torso, hips, shoulders, upper arms, forearms, thighs, calves,
## feet, neck and head, posed every tick from the static skeleton.
##
## Like the fingers on the palm, the parts are shapes, not bodies: no joints,
## no weight of their own, nothing to flop. Where they live decides what the
## world does to them:
## - torso, hips, shoulders and upper arms are shapes on the body itself, so
##   walls, furniture and props stop them and push the whole player back
##   (decided 2026-09-25: "stopped by the world too");
## - each forearm is a shape on its hand, an extension of the palm, so it
##   collides as the palm does and always stays on the physical hand; it sits
##   flush with the palm's face, since a forearm thicker than the palm would
##   prop a flat hand up off a table;
## - the neck and head are shapes on a separate kinematic body that pushes
##   props but passes into the level. The head keeps the rung-2 decision that
##   a head in a wall fades the view rather than pushing back;
## - the thighs, calves and feet are on that body too, switched off, so they
##   meet nothing: still posed every tick and published. The capsule already
##   stops the body down to its feet. Calves and feet that the ground pushed
##   fought walking, stairs and slopes in every locomotion test (the body slid
##   on, rose off the steps, drifted on the ramp); thighs stopped the body
##   short of furniture the capsule had not reached, knees in a stride or a
##   squat reaching past it (the player chose to let them pass, 2026-09-25:
##   "disable the collisions between the world and the feet, calves, and
##   thighs"). Legs that met props kicked away what the player crouched to
##   pick up (switched off at the player's request, 2026-10-03).
##
## The static skeleton stands under the head, but the physical body stands
## wherever the world let it, up to the lean limit behind the head. So the hips
## and legs are posed where the physical body stands: whatever stops the hips
## moves them with the body, and they settle against it instead of staying in
## it, and the legs stay joined to them. The torso runs from those hips up to the neck, which stays with the
## head, so a head leading the body is a lean. The neck end of the torso, the
## shoulders and the upper arms' shoulder ends go with the head; one pressed
## into something pushes the body, and the push carries the view back out, as
## any push on the body does.
##
## No part separates from its neighbours: the parts on the body are all posed
## from the static skeleton's connected chain, the head and neck from the same
## chain, and each arm joins the body's shoulder to its physical hand through
## an elbow solved every tick between the shoulder and the physical wrist,
## bending the way the static skeleton's does, so the upper arm and forearm
## always meet. An arm
## straightens as far as it can; past that (a hand held further away than the
## arm reaches, which its drive pulls against) both bones lengthen to keep the
## arm joined, and the stretch is published.
##
## The capsule still does all walking, stepping and standing.

const PLAYER_LAYER := 16
const DYNAMIC_LAYER := 2
## A contact impulse below this, in N·s per tick, is not a push: the physics
## engine also reports contacts it merely expects.
const PRESSING_IMPULSE := 0.0005

@export var body: CapsuleBody

@export_group("Sizes")
## Radii of each part, in metres, at the static skeleton's proportions.
@export_range(0.02, 0.3, 0.005, "suffix:m") var torso_radius := 0.13
@export_range(0.02, 0.3, 0.005, "suffix:m") var hips_radius := 0.1
@export_range(0.02, 0.2, 0.005, "suffix:m") var shoulder_radius := 0.06
@export_range(0.01, 0.2, 0.005, "suffix:m") var upper_arm_radius := 0.045
@export_range(0.01, 0.2, 0.005, "suffix:m") var forearm_radius := 0.035
@export_range(0.02, 0.2, 0.005, "suffix:m") var thigh_radius := 0.075
@export_range(0.02, 0.2, 0.005, "suffix:m") var calf_radius := 0.055
@export_range(0.01, 0.2, 0.005, "suffix:m") var neck_radius := 0.05
@export_range(0.03, 0.2, 0.005, "suffix:m") var head_radius := 0.1
## The foot's box: width, height and length, in metres; and how far it
## reaches behind the ankle (the heel).
@export var foot_size := Vector3(0.09, 0.07, 0.25)
@export_range(0.0, 0.2, 0.005, "suffix:m") var heel_length := 0.06
## The gap kept under each foot's sole, so the feet never hold the body up.
@export_range(0.0, 0.05, 0.001, "suffix:m") var sole_clearance := 0.01

enum Part {
	TORSO, HIPS, LEFT_SHOULDER, RIGHT_SHOULDER, LEFT_UPPER_ARM, RIGHT_UPPER_ARM,
	LEFT_FOREARM, RIGHT_FOREARM, LEFT_THIGH, RIGHT_THIGH, LEFT_CALF, RIGHT_CALF,
	LEFT_FOOT, RIGHT_FOOT, NECK, HEAD,
}

## The parts whose shapes are switched off: they push no props and pass into
## the level, but are still posed and published.
const LEG_PARTS: Array[int] = [Part.LEFT_THIGH, Part.RIGHT_THIGH, Part.LEFT_CALF,
		Part.RIGHT_CALF, Part.LEFT_FOOT, Part.RIGHT_FOOT]

## Where the parts meet, published for the skeletal layer.
enum Joint {
	NECK, LEFT_SHOULDER, RIGHT_SHOULDER, LEFT_ELBOW, RIGHT_ELBOW, LEFT_WRIST, RIGHT_WRIST,
	LEFT_HIP, RIGHT_HIP, LEFT_KNEE, RIGHT_KNEE, LEFT_ANKLE, RIGHT_ANKLE,
}

## How far each arm is stretched past its length to stay joined, in metres.
var arm_stretch := PackedFloat32Array([0.0, 0.0])
## How many of the body's parts (not its capsule) something pushed on in the
## last step, and which: bit n set for Part n.
var parts_pressing := 0
var parts_pressed := 0

var _physical: DynamicPhysical
var _skeleton: StaticSkeleton
var _hands: Array[RigidBody3D] = []
var _passing_body: AnimatableBody3D
var _shapes: Array[CollisionShape3D] = []
var _relocations := 0


func attach(rig: PlayerRig, physical: DynamicPhysical) -> void:
	_physical = physical
	_skeleton = rig.skeleton
	_hands = [physical.left_drive.hand, physical.right_drive.hand]


func _ready() -> void:
	# After the hand drives and fingers: the static skeleton has solved this
	# tick, and the physical hands are where the elbow solve reads them.
	process_physics_priority = StaticSkeleton.SOLVE_PRIORITY + 7
	_passing_body = AnimatableBody3D.new()
	_passing_body.name = "PropsOnlyParts"
	_passing_body.sync_to_physics = false
	_passing_body.collision_layer = PLAYER_LAYER
	_passing_body.collision_mask = DYNAMIC_LAYER
	_passing_body.top_level = true
	add_child(_passing_body)
	for part in Part.size():
		var shape := CollisionShape3D.new()
		shape.name = Part.keys()[part].to_pascal_case()
		shape.shape = _make_shape(part)
		shape.disabled = part in LEG_PARTS
		_owner_of(part).add_child(shape)
		_shapes.append(shape)
	_relocations = _physical.carrier.relocations
	# Contacts are read per part, to tell which parts the world is stopping.
	body.contact_monitor = true
	body.max_contacts_reported = 16
	var state := _physical.snapshot
	state.body_parts.resize(Part.size())
	state.body_part_shapes.resize(Part.size())
	for part in Part.size():
		state.body_part_shapes[part] = _shapes[part].shape
	state.body_joints.resize(Joint.size())
	state.body_soles.resize(2)


func _physics_process(_delta: float) -> void:
	var s := _skeleton
	if s.hip_tracker == null or s.head_tracker == null:
		return
	# The static skeleton stands under the head; the physical body stands
	# wherever the world has let it, up to the lean limit behind the head. The
	# legs and hips go with the physical body, so what stops them moves them,
	# and the torso leans from there up to the neck, which stays with the head.
	var lead := _physical.carrier.head_lead
	var lower := Vector3(-lead.x, 0.0, -lead.z)
	var left_hip := s.left_hip_tracker.global_position + lower
	var right_hip := s.right_hip_tracker.global_position + lower
	# With the legs drawn up (climbing), the hips ride up to stay above the
	# capsule's drawn-up bottom, so they do not catch on a ledge it clears.
	var seat := body.global_position.y + body.tuck + hips_radius
	left_hip.y = maxf(left_hip.y, seat)
	right_hip.y = maxf(right_hip.y, seat)
	var left_knee := s.left_knee_tracker.global_position + lower
	var right_knee := s.right_knee_tracker.global_position + lower
	var world := {}
	world[Part.TORSO] = _segment(s.hip_tracker.global_position + lower, s.neck_tracker.global_position, Part.TORSO)
	world[Part.HIPS] = _segment(left_hip, right_hip, Part.HIPS)
	world[Part.LEFT_SHOULDER] = Transform3D(Basis.IDENTITY, s.left_shoulder_tracker.global_position)
	world[Part.RIGHT_SHOULDER] = Transform3D(Basis.IDENTITY, s.right_shoulder_tracker.global_position)
	_pose_arm(0, s.left_shoulder_tracker, s.left_hand_tracker, s.left_wrist_tracker, world)
	_pose_arm(1, s.right_shoulder_tracker, s.right_hand_tracker, s.right_wrist_tracker, world)
	world[Part.LEFT_THIGH] = _segment(left_hip, left_knee, Part.LEFT_THIGH)
	world[Part.RIGHT_THIGH] = _segment(right_hip, right_knee, Part.RIGHT_THIGH)
	world[Part.LEFT_CALF] = _segment(left_knee, s.left_ankle_tracker.global_position + lower, Part.LEFT_CALF)
	world[Part.RIGHT_CALF] = _segment(right_knee, s.right_ankle_tracker.global_position + lower, Part.RIGHT_CALF)
	world[Part.LEFT_FOOT] = _foot(s.left_foot_tracker).translated(lower)
	world[Part.RIGHT_FOOT] = _foot(s.right_foot_tracker).translated(lower)
	world[Part.NECK] = _segment(s.neck_tracker.global_position, s.head_tracker.global_position, Part.NECK)
	world[Part.HEAD] = Transform3D(s.head_tracker.global_basis.orthonormalized(), s.head_tracker.global_position)
	_move_passing_body()
	for part: int in world:
		var holder := _owner_of(part)
		_shapes[part].transform = holder.global_transform.affine_inverse() * world[part]
		_physical.snapshot.body_parts[part] = world[part]
	_physical.snapshot.arm_stretch = arm_stretch
	var joints: Array[Vector3] = _physical.snapshot.body_joints
	joints[Joint.NECK] = s.neck_tracker.global_position
	joints[Joint.LEFT_SHOULDER] = s.left_shoulder_tracker.global_position
	joints[Joint.RIGHT_SHOULDER] = s.right_shoulder_tracker.global_position
	joints[Joint.LEFT_HIP] = left_hip
	joints[Joint.RIGHT_HIP] = right_hip
	joints[Joint.LEFT_KNEE] = left_knee
	joints[Joint.RIGHT_KNEE] = right_knee
	joints[Joint.LEFT_ANKLE] = s.left_ankle_tracker.global_position + lower
	joints[Joint.RIGHT_ANKLE] = s.right_ankle_tracker.global_position + lower
	_physical.snapshot.body_soles[0] = s.left_foot_tracker.global_transform.orthonormalized().translated(lower)
	_physical.snapshot.body_soles[1] = s.right_foot_tracker.global_transform.orthonormalized().translated(lower)
	parts_pressed = _pressed_parts()
	parts_pressing = _bit_count(parts_pressed)
	_physical.snapshot.parts_pressing = parts_pressing
	_physical.snapshot.parts_pressed = parts_pressed


## Which of the body's part shapes something pushed on in the last step, as
## bits by Part.
func _pressed_parts() -> int:
	var state := PhysicsServer3D.body_get_direct_state(body.get_rid())
	var pressed := 0
	for i in state.get_contact_count():
		if state.get_contact_impulse(i).length() <= PRESSING_IMPULSE:
			continue
		var holder := body.shape_owner_get_owner(body.shape_find_owner(state.get_contact_local_shape(i)))
		var part := _shapes.find(holder)
		if part >= 0:
			pressed |= 1 << part
	return pressed


static func _bit_count(bits: int) -> int:
	var count := 0
	while bits != 0:
		bits &= bits - 1
		count += 1
	return count


## One arm: the elbow solved between the static shoulder and the physical
## wrist (the static wrist's place on the physical hand), bending toward the
## drive's elbow_pole() (the static skeleton's elbow, or on a straight arm
## the way it bends). The upper arm runs shoulder to elbow on the
## body; the forearm runs elbow to wrist on the hand.
##
## Past the arm's reach both bones lengthen to meet, where the static skeleton
## lengthens only its forearm (so there the elbows differ, by 8 mm at the
## harness's rest pose). Tried 2026-09-26: the static skeleton's rule made the
## forearm on the hand longer and fingers holding a box's corner twitched
## 3.3° and shoved the hand; adding the static elbow's own motion instead
## moved the forearm on the hand whenever the static skeleton re-solved.
func _pose_arm(side: int, shoulder: Node3D, static_hand: Node3D, static_wrist: Node3D,
		world: Dictionary) -> void:
	var hand := _hands[side]
	var drive: HandDrive = _physical.left_drive if side == 0 else _physical.right_drive
	var wrist_on_hand := static_hand.global_transform.affine_inverse() * static_wrist.global_position
	var from := shoulder.global_position
	var to := hand.global_transform * wrist_on_hand
	var elbow := _elbow(side, from, to, drive.elbow_pole(),
			_skeleton.upper_arm_length, _skeleton.forearm_length)
	_physical.snapshot.body_joints[Joint.LEFT_ELBOW + side] = elbow
	_physical.snapshot.body_joints[Joint.LEFT_WRIST + side] = to
	# The forearm is raised toward the back of the hand until its underside is
	# flush with the palm's face; the upper arm meets it there.
	var palm_side := _skeleton.palm_direction.normalized()
	if side == 0:
		palm_side.x = -palm_side.x
	var back := -(hand.global_basis * palm_side).normalized()
	var face := _physical.left_drive.palm_size.x * _skeleton.hand_scale * 0.5
	var lift := back * maxf(forearm_radius - face, 0.0)
	var upper := Part.LEFT_UPPER_ARM + side
	var fore := Part.LEFT_FOREARM + side
	world[upper] = _segment(from, elbow + lift, upper)
	world[fore] = _segment(elbow + lift, to + lift, fore)


## Two-bone solve: where an elbow sits between `from` and `to` with bones of
## lengths `a` and `b`, toward the point `pole`. Out of reach, the arm lies
## straight and both bones lengthen to meet (recorded as stretch); closer
## than the bones can fold, the forearm shortens to meet.
func _elbow(side: int, from: Vector3, to: Vector3, pole: Vector3, a: float, b: float) -> Vector3:
	var span := to - from
	var distance := span.length()
	arm_stretch[side] = maxf(distance - (a + b), 0.0)
	if distance < 1e-4:
		return from + (pole - from).normalized() * a
	var direction := span / distance
	if distance >= a + b:
		return from + direction * (distance * a / (a + b))
	var reach := maxf(distance, absf(a - b) + 1e-4)
	var along := (a * a - b * b + reach * reach) / (2.0 * reach)
	var out := sqrt(maxf(a * a - along * along, 0.0))
	var bend := (pole - from).slide(direction)
	if bend.length_squared() < 1e-8:
		bend = direction.cross(Vector3.UP)
		if bend.length_squared() < 1e-8:
			bend = direction.cross(Vector3.RIGHT)
	return from + direction * along + bend.normalized() * out


## A capsule part's transform lying from `from` to `to`, and its shape made
## long enough to reach both ends, its caps covering the joints.
func _segment(from: Vector3, to: Vector3, part: int) -> Transform3D:
	var span := to - from
	var length := span.length()
	var capsule := _shapes[part].shape as CapsuleShape3D
	var height := maxf(length + 2.0 * capsule.radius, 2.0 * capsule.radius)
	if absf(capsule.height - height) > 0.001:
		capsule.height = height
	var y := span / length if length > 1e-5 else Vector3.UP
	var x := y.cross(Vector3.FORWARD)
	if x.length_squared() < 1e-6:
		x = y.cross(Vector3.RIGHT)
	x = x.normalized()
	# A capsule's axis is its Y.
	return Transform3D(Basis(x, y, x.cross(y)), (from + to) * 0.5)


## A foot's box: on the sole's frame, heel to toe along its facing, lifted
## sole_clearance off the ground.
func _foot(sole: Node3D) -> Transform3D:
	var frame := sole.global_transform.orthonormalized()
	var toe := foot_size.z - heel_length
	return frame * Transform3D(Basis.IDENTITY,
			Vector3(0.0, sole_clearance + foot_size.y * 0.5, -(toe - heel_length) * 0.5))


## Moves the props-only parts' kinematic body with the body, so it pushes
## props at the player's own speed. A relocation is a teleport, not a sweep
## through whatever lies between.
func _move_passing_body() -> void:
	var relocated := _physical.carrier.relocations != _relocations
	_relocations = _physical.carrier.relocations
	var target := Transform3D(Basis.IDENTITY, body.global_position)
	if relocated:
		PhysicsServer3D.body_set_state(_passing_body.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, target)
	_passing_body.global_transform = target


func _owner_of(part: int) -> Node3D:
	match part:
		Part.LEFT_FOREARM:
			return _hands[0]
		Part.RIGHT_FOREARM:
			return _hands[1]
		Part.NECK, Part.HEAD, Part.LEFT_THIGH, Part.RIGHT_THIGH, Part.LEFT_CALF, Part.RIGHT_CALF, \
				Part.LEFT_FOOT, Part.RIGHT_FOOT:
			return _passing_body
		_:
			return body


func _make_shape(part: int) -> Shape3D:
	match part:
		Part.LEFT_SHOULDER, Part.RIGHT_SHOULDER:
			return _sphere(shoulder_radius)
		Part.HEAD:
			return _sphere(head_radius)
		Part.LEFT_FOOT, Part.RIGHT_FOOT:
			var box := BoxShape3D.new()
			box.size = Vector3(foot_size.x, foot_size.y, foot_size.z)
			return box
	var capsule := CapsuleShape3D.new()
	capsule.radius = _radius_of(part)
	capsule.height = capsule.radius * 2.0
	return capsule


func _radius_of(part: int) -> float:
	match part:
		Part.TORSO:
			return torso_radius
		Part.HIPS:
			return hips_radius
		Part.LEFT_UPPER_ARM, Part.RIGHT_UPPER_ARM:
			return upper_arm_radius
		Part.LEFT_FOREARM, Part.RIGHT_FOREARM:
			return forearm_radius
		Part.LEFT_THIGH, Part.RIGHT_THIGH:
			return thigh_radius
		Part.LEFT_CALF, Part.RIGHT_CALF:
			return calf_radius
		_:
			return neck_radius


static func _sphere(radius: float) -> SphereShape3D:
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	return sphere
