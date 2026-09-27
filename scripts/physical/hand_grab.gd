class_name HandGrab
extends Node

## One hand's grab: finds what the hand could grab, and when the grip closes
## pulls it in and holds it through a joint (decided 2026-09-25; section 6.7).
##
## - The hand's grab point is fixed, just inside the palm's face.
## - While the hand holds nothing, the grab area, a ball in front of the palm,
##   is searched every tick for Grabbable bodies. The one whose surface comes
##   closest to the hand's grab point is the candidate, and that closest
##   surface point is its grab point, following the hand until the grab.
## - When the grip closes past grab_grip, the candidate is grabbed. A joint
##   from the hand keeps the object's rotation relative to the hand as it was,
##   and the joint's linear motors pull the object's grab point to the hand's,
##   quickly but no harder than grip_strength. The pull acts on both: a light
##   object comes to the hand, a heavy one pulls the hand to it (against the
##   hand's own drive), and neither passes through the level on the way.
##   Once in the hand it is locked there: the joint is remade rigid, so a held
##   object moves with the hand and cannot swing out past it however fast the
##   hand moves (held by the pull's motors, a 10 kg box swung fast lagged
##   0.33 m, and in the headset dropped). Its weight and inertia load the
##   hand, whose drive carries them.
## - While held, the object is on the Held layer, which the player's body,
##   hands and legs do not meet: the hold never fights the palm's or fingers'
##   contacts, and the object cannot push the player about. The fingers still
##   curl onto it; their checks include Held.
## - It is let go when the grip opens past release_grip, when the pull-in
##   cannot bring it within max_slip for slip_time (it is caught on something),
##   when the hand is held further than max_separation from its target for
##   slip_time (what it holds is stuck), or when the controller has been
##   untracked for tracking_loss_time. It gets its own layers back once clear
##   of the hand.

enum State { IDLE, PULLING, HOLDING }

const HELD_LAYER := 8
## A held object meets the level, loose props and enemies: section 6.8.
const HELD_MASK := 1 | 2 | 256

@export var drive: HandDrive

@export_group("Grab point and area")
## How far inside the palm's face the hand's grab point sits, in metres.
@export_range(0.0, 0.02, 0.001, "suffix:m") var grab_depth := 0.005
## The grab area: a ball of this radius, in metres...
@export_range(0.01, 0.3, 0.005, "suffix:m") var grab_radius := 0.08
## ...centred this far out from the palm's face, in metres.
@export_range(0.0, 0.2, 0.005, "suffix:m") var grab_reach := 0.03

@export_group("Grip")
## The grip squeezes past this to grab, and opens past release_grip to let go.
@export_range(0.0, 1.0, 0.05) var grab_grip := 0.7
@export_range(0.0, 1.0, 0.05) var release_grip := 0.3
## The most force the hand pulls in and holds an object with, in newtons.
@export_range(0.0, 3000.0, 10.0, "suffix:N") var grip_strength := 400.0
## How quickly the gap between the grab points closes, and at most how fast.
@export_range(1.0, 60.0, 0.5, "suffix:1/s") var pull_gain := 20.0
@export_range(0.1, 10.0, 0.1, "suffix:m/s") var max_pull_speed := 3.0
## Closer than this, the object counts as in the hand.
@export_range(0.0, 0.05, 0.001, "suffix:m") var hold_distance := 0.005

@export_group("Letting go")
## Pulled in but still further than this from the hand's grab point for
## slip_time, it is let go.
@export_range(0.0, 1.0, 0.01, "suffix:m") var max_slip := 0.12
@export_range(0.0, 2.0, 0.05, "suffix:s") var slip_time := 0.25
## Holding, a hand kept further than this from its target for slip_time lets
## go: what it holds is stuck. Less than the hand drive's own recovery, which
## would move the hand, and the held object with it, to the target.
@export_range(0.0, 1.0, 0.01, "suffix:m") var max_separation := 0.4
## An untracked controller lets go after this long.
@export_range(0.0, 5.0, 0.1, "suffix:s") var tracking_loss_time := 1.0
## A let-go object gets its own layers back once clear of the hand, or after
## this long at most.
@export_range(0.0, 3.0, 0.05, "suffix:s") var restore_limit := 1.0

var state := State.IDLE
## The candidate while idle, or the held object.
var target: RigidBody3D
## The hand's grab point, and the object's (the candidate's closest surface
## point, or where the held object's grab point is now), in world space.
var hand_point := Vector3.ZERO
var object_point := Vector3.ZERO
## How far apart the two grab points are, in metres.
var gap := 0.0
## Grabs so far.
var grabs := 0

var _physical: DynamicPhysical
var _controller: XRController3D
var _hand: RigidBody3D
var _side := 0
# The hand's grab point in the hand's own space, and which way its palm faces.
var _palm_point := Vector3.ZERO
var _palm_side := Vector3.ZERO
var _area := PhysicsShapeQueryParameters3D.new()
var _clear := PhysicsShapeQueryParameters3D.new()
var _joint: Generic6DOFJoint3D
# The held object's grab point in its own space, and its own layers.
var _grip_point := Vector3.ZERO
var _layer := 0
var _mask := 0
var _monitor := false
var _reported := 0
var _gripped := false
var _slipped_for := 0.0
var _untracked_for := 0.0
# Objects let go and not yet given their layers back: body, layer, mask, time.
var _letting_go: Array[Dictionary] = []


func attach(rig: PlayerRig, physical: DynamicPhysical) -> void:
	_physical = physical
	_hand = drive.hand
	var left := drive.side == HandDrive.Side.LEFT
	_side = 0 if left else 1
	_controller = rig.left_controller if left else rig.right_controller
	var skeleton := rig.skeleton
	_palm_side = skeleton.palm_direction.normalized()
	if left:
		_palm_side.x = -_palm_side.x
	var face := drive.palm_size.x * skeleton.hand_scale * 0.5
	_palm_point = _palm_side * (face - grab_depth)
	var ball := SphereShape3D.new()
	ball.radius = grab_radius
	_area.shape = ball
	_area.collision_mask = Grabbable.GRABBABLE_LAYER
	_clear.collision_mask = HELD_LAYER


func _ready() -> void:
	# Before the hand drive: the hand is where the last step left it.
	process_physics_priority = StaticSkeleton.SOLVE_PRIORITY + 4


func _physics_process(delta: float) -> void:
	if _hand == null:
		return
	hand_point = _hand.global_transform * _palm_point
	var grip := _controller.get_float(&"grip")
	var squeezed := grip >= grab_grip
	var pressed := squeezed and not _gripped
	if squeezed:
		_gripped = true
	elif grip <= release_grip:
		_gripped = false
	if state == State.IDLE:
		_find_candidate()
		if pressed and target != null:
			_grab()
	else:
		_hold(delta)
	_give_layers_back(delta)
	_publish()


## The Grabbable body in the grab area whose surface comes closest to the
## hand's grab point, and that point.
func _find_candidate() -> void:
	target = null
	gap = 0.0
	_area.transform = Transform3D(Basis.IDENTITY, hand_point + _hand.global_basis * _palm_side * grab_reach)
	_area.exclude = [_hand.get_rid()]
	var best := INF
	for hit in _hand.get_world_3d().direct_space_state.intersect_shape(_area, 16):
		var body := hit.collider as RigidBody3D
		var grabbable := Grabbable.of(body)
		if body == null or grabbable == null or not grabbable.enabled or body.freeze:
			continue
		var holder := body.shape_owner_get_owner(body.shape_find_owner(hit.shape)) as CollisionShape3D
		if holder == null:
			continue
		var closest := _closest_on(holder, hand_point)
		var distance := closest.distance_to(hand_point)
		if distance < best:
			best = distance
			target = body
			object_point = closest
			gap = distance


## Grabs the candidate at its grab point: moves it to the Held layer and joins
## it to the hand, keeping its rotation relative to the hand as it is.
func _grab() -> void:
	_grip_point = target.global_transform.affine_inverse() * object_point
	_layer = target.collision_layer
	_mask = target.collision_mask
	_monitor = target.contact_monitor
	_reported = target.max_contacts_reported
	target.collision_layer = HELD_LAYER
	target.collision_mask = HELD_MASK
	# Held, its contacts tell whether it rests on something.
	target.contact_monitor = true
	target.max_contacts_reported = maxi(_reported, 4)
	_joint = Generic6DOFJoint3D.new()
	_joint.name = "Grip"
	add_child(_joint)
	_joint.global_transform = Transform3D(_hand.global_basis, hand_point)
	_configure_joint()
	_joint.node_a = _joint.get_path_to(_hand)
	_joint.node_b = _joint.get_path_to(target)
	# Again now it exists: in Jolt some settings made before do not hold.
	_configure_joint()
	state = State.PULLING
	_slipped_for = 0.0
	_untracked_for = 0.0
	grabs += 1


## Pulls the held object's grab point toward the hand's, or holds it there,
## and lets go when the grip opens, it slips, or tracking is lost.
func _hold(delta: float) -> void:
	if not is_instance_valid(target):
		_let_go()
		return
	object_point = target.global_transform * _grip_point
	var closing := hand_point - object_point
	gap = closing.length()
	var stuck := gap > max_slip if state == State.PULLING else drive.separation > max_separation
	_slipped_for = _slipped_for + delta if stuck else 0.0
	_untracked_for = _untracked_for + delta if not drive.tracked else 0.0
	if not _gripped or _slipped_for >= slip_time or _untracked_for >= tracking_loss_time:
		_let_go()
		return
	if state == State.HOLDING:
		_carry()
		return
	if gap <= hold_distance:
		_lock()
		return
	# The motors drive the object relative to the hand, along the hand's axes,
	# each with the full grip: an object's weight needs it whichever way the
	# gap lies.
	var wanted := (closing * pull_gain).limit_length(max_pull_speed)
	var local := _hand.global_basis.orthonormalized().inverse() * wanted
	for axis in 3:
		_param(axis, Generic6DOFJoint3D.PARAM_LINEAR_MOTOR_TARGET_VELOCITY, local[axis])
		_param(axis, Generic6DOFJoint3D.PARAM_LINEAR_MOTOR_FORCE_LIMIT, grip_strength)


## Remakes the grip joint rigid where the object is now: in the hand, it moves
## with the hand.
func _lock() -> void:
	_joint.queue_free()
	_joint = Generic6DOFJoint3D.new()
	_joint.name = "Grip"
	add_child(_joint)
	_joint.global_transform = Transform3D(_hand.global_basis, hand_point)
	_configure_lock()
	_joint.node_a = _joint.get_path_to(_hand)
	_joint.node_b = _joint.get_path_to(target)
	_configure_lock()
	state = State.HOLDING
	_slipped_for = 0.0


func _configure_lock() -> void:
	for axis in ["x", "y", "z"]:
		for kind in ["linear", "angular"]:
			_joint.set("%s_limit_%s/enabled" % [kind, axis], true)
			_joint.set("%s_motor_%s/enabled" % [kind, axis], false)
		_joint.set("linear_limit_%s/lower_distance" % axis, 0.0)
		_joint.set("linear_limit_%s/upper_distance" % axis, 0.0)
		_joint.set("angular_limit_%s/lower_angle" % axis, 0.0)
		_joint.set("angular_limit_%s/upper_angle" % axis, 0.0)


## The pull-in joint: free to move, driven by its linear motors; its rotation
## locked where it was when made.
func _configure_joint() -> void:
	for axis in ["x", "y", "z"]:
		_joint.set("linear_limit_%s/enabled" % axis, false)
		_joint.set("linear_motor_%s/enabled" % axis, true)
		_joint.set("linear_motor_%s/force_limit" % axis, grip_strength)
		_joint.set("linear_motor_%s/target_velocity" % axis, 0.0)
		_joint.set("angular_limit_%s/enabled" % axis, true)
		_joint.set("angular_limit_%s/lower_angle" % axis, 0.0)
		_joint.set("angular_limit_%s/upper_angle" % axis, 0.0)
		_joint.set("angular_motor_%s/enabled" % axis, false)


## Tells the hand drive what it carries: the held object's mass, its inertia
## about its centre of mass and where that is from the hand's centre; whether
## it is pressed on anything (the Held layer meets only the level, props and
## enemies, never the player), and its gravity.
func _carry() -> void:
	var state := PhysicsServer3D.body_get_direct_state(target.get_rid())
	var centre := target.global_position + state.center_of_mass - _hand.global_position
	drive.carry(target.mass, state.inverse_inertia_tensor.inverse(), centre, _pressed(state),
			state.total_gravity)


## Whether anything pushes on the held object. The physics engine also
## reports contacts it only expects (within a couple of centimetres) with no
## push yet; those are not a press.
static func _pressed(state: PhysicsDirectBodyState3D) -> bool:
	for i in state.get_contact_count():
		if state.get_contact_impulse(i).length() > HandDrive.TOUCH_IMPULSE:
			return true
	return false


## Lets the held object go. It keeps the Held layer until clear of the hand.
func _let_go() -> void:
	drive.carry(0.0, Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), Vector3.ZERO)
	if _joint != null:
		_joint.queue_free()
		_joint = null
	if is_instance_valid(target):
		_letting_go.append({"body": target, "layer": _layer, "mask": _mask, "monitor": _monitor,
				"reported": _reported, "time": 0.0})
	target = null
	state = State.IDLE


## Gives let-go objects their own layers back once no part of the hand
## overlaps them, or after restore_limit.
func _give_layers_back(delta: float) -> void:
	for i in range(_letting_go.size() - 1, -1, -1):
		var entry := _letting_go[i]
		var body := entry.body as RigidBody3D
		entry.time += delta
		if not is_instance_valid(body):
			_letting_go.remove_at(i)
		elif entry.time >= restore_limit or not _hand_overlaps(body):
			body.collision_layer = entry.layer
			body.collision_mask = entry.mask
			body.contact_monitor = entry.monitor
			body.max_contacts_reported = entry.reported
			_letting_go.remove_at(i)


func _hand_overlaps(body: RigidBody3D) -> bool:
	var space := _hand.get_world_3d().direct_space_state
	for owner_id in _hand.get_shape_owners():
		var holder := _hand.shape_owner_get_owner(owner_id) as CollisionShape3D
		if holder == null or holder.shape == null or holder.disabled:
			continue
		_clear.shape = holder.shape
		_clear.transform = holder.global_transform
		for hit in space.intersect_shape(_clear, 4):
			if hit.collider == body:
				return true
	return false


## The point of `holder`'s shape closest to `point`, in world space: exact for
## boxes, spheres, capsules and cylinders; otherwise where a small ball cast
## from `point` toward the shape's centre first meets it.
func _closest_on(holder: CollisionShape3D, point: Vector3) -> Vector3:
	var frame := holder.global_transform.orthonormalized()
	var local := frame.affine_inverse() * point
	var shape := holder.shape
	if shape is BoxShape3D:
		return frame * _closest_in_box(local, (shape as BoxShape3D).size * 0.5)
	if shape is SphereShape3D:
		return frame * _toward(Vector3.ZERO, local, (shape as SphereShape3D).radius)
	if shape is CapsuleShape3D:
		var capsule := shape as CapsuleShape3D
		var half := maxf(capsule.height * 0.5 - capsule.radius, 0.0)
		var on_axis := Vector3(0.0, clampf(local.y, -half, half), 0.0)
		return frame * _toward(on_axis, local, capsule.radius)
	if shape is CylinderShape3D:
		var cylinder := shape as CylinderShape3D
		var radial := Vector2(local.x, local.z)
		var height := cylinder.height * 0.5
		if radial.length() > cylinder.radius or absf(local.y) > height:
			radial = radial.limit_length(cylinder.radius)
			return frame * Vector3(radial.x, clampf(local.y, -height, height), radial.y)
		# Inside: out through whichever is nearer, the side or an end.
		if cylinder.radius - radial.length() < height - absf(local.y):
			radial = radial.normalized() * cylinder.radius if radial.length() > 1e-6 else Vector2(cylinder.radius, 0.0)
			return frame * Vector3(radial.x, local.y, radial.y)
		return frame * Vector3(local.x, signf(local.y) * height, local.z)
	return _cast_onto(holder, point)


static func _closest_in_box(local: Vector3, half: Vector3) -> Vector3:
	var clamped := local.clamp(-half, half)
	if not clamped.is_equal_approx(local):
		return clamped
	# Inside: out through the nearest face.
	var depth := half - local.abs()
	var axis := 0 if depth.x <= depth.y and depth.x <= depth.z else (1 if depth.y <= depth.z else 2)
	clamped[axis] = half[axis] * (1.0 if local[axis] >= 0.0 else -1.0)
	return clamped


## The point `radius` from `centre` toward `point`.
static func _toward(centre: Vector3, point: Vector3, radius: float) -> Vector3:
	var out := point - centre
	return centre + (out.normalized() if out.length_squared() > 1e-10 else Vector3.UP) * radius


func _cast_onto(holder: CollisionShape3D, point: Vector3) -> Vector3:
	var ball := SphereShape3D.new()
	ball.radius = 0.005
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = ball
	query.collision_mask = Grabbable.GRABBABLE_LAYER
	query.transform = Transform3D(Basis.IDENTITY, point)
	query.motion = holder.global_position - point
	query.exclude = [_hand.get_rid()]
	var space := _hand.get_world_3d().direct_space_state
	var fractions := space.cast_motion(query)
	return point + query.motion * fractions[1]


func _param(axis: int, param: Generic6DOFJoint3D.Param, value: float) -> void:
	match axis:
		0: _joint.set_param_x(param, value)
		1: _joint.set_param_y(param, value)
		2: _joint.set_param_z(param, value)


func _publish() -> void:
	var snapshot := _physical.snapshot
	snapshot.grab_state[_side] = state
	snapshot.grab_hand_points[_side] = hand_point
	snapshot.grab_object_points[_side] = object_point if target != null else hand_point
	snapshot.grab_gap[_side] = gap if target != null else 0.0
