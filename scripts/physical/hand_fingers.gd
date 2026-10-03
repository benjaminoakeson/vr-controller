class_name HandFingers
extends Node

## One physical hand's fingers: five chains of three capsules that are part of
## the hand's own body, like the palm, posed every tick from the static
## skeleton's fingers.
##
## The fingers have collision but no joints and no weight of their own: the
## hand's mass, centre and inertia are the palm's alone (HandDrive), so the
## fingers never flop, and whatever they touch pushes on the whole hand. Grip
## and trigger curl them through the static skeleton, without lag. Contact is
## handled by limiting the pose, before the physics step, never by springs:
## - every joint of every finger curls on its own until a bone it moves would
##   run into something: a joint stops when its own bone, or any bone past it,
##   meets a surface, and the joints past a stopped bone curl on until their
##   bones meet it too. So each finger stops where it touches, whatever the
##   others touch, and closing over an edge or a box's corner wraps the
##   fingers around it instead of through it (asked for after the body-parts
##   headset session: "each finger should curl until it has made contact");
## - a finger pressed harder than `yield_force` by a contact that turns it
##   open (on its palm side, as a tabletop under an open hand does) opens
##   toward straight just far enough to come clear, so a hand laid on a table
##   comes down flat on its palm. Opening further, it would curl straight back
##   onto the surface next tick; opening by a fixed step each tick made the
##   fingers twitch against boxes. Pushed on its back, as a fist's knuckles
##   are, or end-on, which opening would only drive further in, a finger stays
##   as it is and stops the hand.
## A joint curls again, toward its pose, as soon as it is free to.
##
## Each finger sits where the static skeleton's does, the thumb too, though it
## stands out in front of the palm: until 2026-10-02 a root was lifted flush
## with the palm's face, but the player asked for the physical thumb on the
## model's visible thumb (lifted, it sat inside the palm), so a palm pressed
## flat on a table rests on it.

const FINGERS := 5
const PHALANGES := 3
## Each finger's radius at its root, in metres at hand_scale 1, thumb to
## little finger; each bone after the root is a little thinner.
const ROOT_RADII: Array[float] = [0.0105, 0.009, 0.009, 0.0085, 0.0075]
const TAPER: Array[float] = [1.0, 0.92, 0.85]
## Fingers stop on the level, loose props and held props, the hand's own
## included (a hand's own held prop never collides with it, a collision
## exception of the prop's, and is on the Seating layer while it comes into
## the hand).
const STATIC_AND_DYNAMIC := 1 | 2 | 8 | Grabbable.SEATING_LAYER
## How many times a blocked curl is halved looking for how far it can go.
const SEARCH_STEPS := 4
## Each tick's curl is checked in this many steps, so no step moves a
## fingertip further than about its own thickness.
const CURL_SUBSTEPS := 3
## A capsule's axis is its Y; this lays it along a bone's -Z from the joint.
const CAPSULE_ALONG_BONE := Basis(Vector3.RIGHT, PI * 0.5)

@export var drive: HandDrive

@export_group("Shape")
## Multiplies every finger's radius.
@export_range(0.5, 2.0, 0.05) var thickness := 1.0

@export_group("Curling")
## The fastest a finger joint curls toward its pose, so a finger closing onto
## something finds where it meets it, a step at a time.
@export_range(90.0, 3000.0, 10.0, "suffix:°/s") var curl_speed := 720.0

@export_group("Contact")
## A finger stops curling this far short of anything in its way, in metres.
@export_range(0.0, 0.01, 0.0005, "suffix:m") var clearance := 0.002
## Pressed against something harder than this, a finger is pushed open.
@export_range(0.0, 200.0, 0.5, "suffix:N") var yield_force := 1.5
## How fast a pressed finger opens, per joint.
@export_range(10.0, 3000.0, 10.0, "suffix:°/s") var yield_speed := 1080.0
## After giving way, a finger curls again only once it would stay this much
## further clear than `clearance`, in metres: a press that comes and goes as
## the hand bobs by a millimetre must not flick the finger open and shut.
@export_range(0.0, 0.02, 0.0005, "suffix:m") var regrip_gap := 0.004

## Per finger: how much less bent than its pose the finger is held by contact,
## at its most held joint, in radians.
var held_open := PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0])
## How many joints turned back this tick on the way they moved last tick while
## their pose held still: a twitch, counted so recordings can show it.
var reversals := 0

var _physical: DynamicPhysical
var _skeleton: StaticSkeleton
var _hand: RigidBody3D
var _left := false
var _side := 0
# Per finger: the three joints' frames with the finger straight, relative to
# the joint before (the palm for the root), and the static joints to follow.
var _rests: Array = []
var _targets: Array = []
# Per finger: the bend each joint has now, in radians; how it moved last tick,
# and its pose's bends last tick, to count twitches by.
var _bends: Array[Vector3] = []
var _last_moves: Array[Vector3] = []
var _last_targets: Array[Vector3] = []
# Per finger, as bits by joint: joints that were stopped short of their pose
# last tick without moving. Stopped again, they are not searched for a
# smaller step: they are already against what stopped them.
var _resting := PackedInt32Array([0, 0, 0, 0, 0])
# Per finger: whether it gave way to a press and has not curled since.
var _gave_way: Array[bool] = [false, false, false, false, false]
# Per finger and bone: the collision shape on the hand, its capsule and length.
var _shapes: Array[CollisionShape3D] = []
var _capsules: Array[CapsuleShape3D] = []
var _lengths := PackedFloat32Array()
# The hand body's shape index of each finger bone, to read contacts by.
var _bone_of_shape := {}
# Per finger, this tick: the contact force on it and how much pushes it open.
var _forces := PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0])
var _opening := PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0])
var _query := PhysicsShapeQueryParameters3D.new()
# A ball around each finger's reach, to skip the per-bone checks while nothing
# is near it; and each ball's radius.
var _reach_query := PhysicsShapeQueryParameters3D.new()
var _reach_ball := SphereShape3D.new()
var _reaches := PackedFloat32Array()
# Where the hand will be after this tick's step, if it keeps moving as it is:
# a finger is checked where it will be, not where it was.
var _ahead := Transform3D.IDENTITY


func attach(rig: PlayerRig, physical: DynamicPhysical) -> void:
	_physical = physical
	_skeleton = rig.skeleton
	_hand = drive.hand
	_left = drive.side == HandDrive.Side.LEFT
	_side = 0 if _left else 1
	var state := physical.snapshot
	if state.finger_bones.size() < 2 * FINGERS * PHALANGES:
		state.finger_bones.resize(2 * FINGERS * PHALANGES)
		state.finger_sizes.resize(2 * FINGERS * PHALANGES)


func _ready() -> void:
	# After the hand drive: the static skeleton has posed this tick's fingers.
	process_physics_priority = StaticSkeleton.SOLVE_PRIORITY + 6
	# Contacts are read per finger, and ten fingers' worth may touch at once. A
	# hand of the player model's (2026-10-02) resting on a table reports about 35,
	# its fingers' expected contacts among them: with 16, the palm's push was
	# left out and the hand did not count as touching (HandDrive._pressing).
	_hand.max_contacts_reported = 64
	_query.collision_mask = STATIC_AND_DYNAMIC
	_reach_query.collision_mask = STATIC_AND_DYNAMIC
	_reach_query.shape = _reach_ball
	_build()


func _physics_process(delta: float) -> void:
	if _shapes.is_empty():
		return
	if _bone_of_shape.is_empty():
		_map_shapes()
	_ahead = _predicted(delta)
	_read_contacts(delta)
	var total := 0.0
	var most_held := 0.0
	reversals = 0
	for finger in FINGERS:
		var target := _target_bends(finger)
		var bends := _next_bends(finger, _bends[finger], target, delta)
		_count_reversals(finger, bends - _bends[finger], target)
		if not bends.is_equal_approx(_bends[finger]):
			_bends[finger] = bends
			_pose(finger)
		var held := target - bends
		held_open[finger] = maxf(maxf(held.x, held.y), maxf(held.z, 0.0))
		most_held = maxf(most_held, held_open[finger])
		total += bends.x + bends.y + bends.z
	_publish(most_held, total / (FINGERS * PHALANGES))


## Where a finger goes this tick, given its contacts: pushed open while
## pressed open; otherwise each joint curls toward its pose until a bone it
## moves would meet something. Joints opening toward the pose always follow at
## once.
func _next_bends(finger: int, now: Vector3, target: Vector3, delta: float) -> Vector3:
	var bends := now.min(target)
	if _forces[finger] > yield_force and _opening[finger] > 0.0:
		_resting[finger] = 0
		var given := _given_way(finger, bends, delta)
		if not given.is_equal_approx(bends):
			_gave_way[finger] = true
		return given
	if _gave_way[finger]:
		var first_step := bends
		for joint in PHALANGES:
			first_step[joint] = minf(bends[joint] + deg_to_rad(curl_speed) * delta / CURL_SUBSTEPS, target[joint])
		if not _bones_clear(finger, first_step, 0, PHALANGES - 1, clearance + regrip_gap):
			return bends
		_gave_way[finger] = false
	return _curled(finger, bends, target, delta)


## Opens a pressed finger toward straight, at most `yield_speed`, and only as
## far as brings it clear of what presses it. If opening would not free it, it
## stays.
func _given_way(finger: int, bends: Vector3, delta: float) -> Vector3:
	if _bones_clear(finger, bends, 0, PHALANGES - 1, 0.0):
		return bends
	var most := (bends - Vector3.ONE * deg_to_rad(yield_speed) * delta).max(bends.min(Vector3.ZERO))
	if not _bones_clear(finger, most, 0, PHALANGES - 1, 0.0):
		return bends
	var clear := most
	var blocked := bends
	for step in SEARCH_STEPS:
		var middle := (clear + blocked) * 0.5
		if _bones_clear(finger, middle, 0, PHALANGES - 1, 0.0):
			clear = middle
		else:
			blocked = middle
	return clear


## Curls each joint toward its pose, root first, in CURL_SUBSTEPS steps. A bone
## that would come within `clearance` of something stops the joints that carry
## it, where it meets it; the joints past it curl on. Sub-steps because level
## geometry is a surface: a fingertip that jumped right through it in one step
## would find nothing in the way.
func _curled(finger: int, bends: Vector3, target: Vector3, delta: float) -> Vector3:
	var start := bends
	var increment := deg_to_rad(curl_speed) * delta / CURL_SUBSTEPS
	if not _near_anything(finger):
		_resting[finger] = 0
		return target.min(bends + Vector3.ONE * increment * CURL_SUBSTEPS)
	var curling: Array[bool] = [bends.x < target.x, bends.y < target.y, bends.z < target.z]
	var stopped := 0
	for part in CURL_SUBSTEPS:
		var tried := bends
		var first := -1
		for joint in PHALANGES:
			if curling[joint]:
				tried[joint] = minf(bends[joint] + increment, target[joint])
				if first < 0:
					first = joint
		if first < 0:
			break
		var bone := first
		while bone < PHALANGES:
			if _bones_clear(finger, tried, bone, bone, clearance):
				bone += 1
				continue
			# Only the joints up to this bone move it: they stop where it meets
			# the surface. Joints already resting against it stay put.
			var resting := true
			for joint in range(first, bone + 1):
				if curling[joint] and not (_resting[finger] & (1 << joint)):
					resting = false
			if resting:
				for joint in range(first, bone + 1):
					tried[joint] = bends[joint]
			else:
				tried = _stopped(finger, bends, tried, first, bone)
			for joint in range(first, bone + 1):
				if curling[joint]:
					curling[joint] = false
					stopped |= 1 << joint
			first = bone + 1
			bone += 1
		bends = tried
	# Joints stopped without moving at all rest against what stopped them.
	var resting_now := 0
	for joint in PHALANGES:
		if stopped & (1 << joint) and is_equal_approx(bends[joint], start[joint]):
			resting_now |= 1 << joint
	_resting[finger] = resting_now
	return bends


## The most the joints `first` to `last` can curl from `from` (clear) toward
## `to` together, with the joints before them as in `to`, keeping the bones
## they carry `clearance` clear; found by halving SEARCH_STEPS times.
func _stopped(finger: int, from: Vector3, to: Vector3, first: int, last: int) -> Vector3:
	var clear := 0.0
	var blocked := 1.0
	for step in SEARCH_STEPS:
		var middle := (clear + blocked) * 0.5
		if _bones_clear(finger, _partly(from, to, first, last, middle), first, last, clearance):
			clear = middle
		else:
			blocked = middle
	return _partly(from, to, first, last, clear)


## `to`, with the joints `first` to `last` taken `share` of the way from `from`.
static func _partly(from: Vector3, to: Vector3, first: int, last: int, share: float) -> Vector3:
	var bends := to
	for joint in range(first, last + 1):
		bends[joint] = lerpf(from[joint], to[joint], share)
	return bends


## The bend of each of a finger's joints in the static skeleton's pose.
func _target_bends(finger: int) -> Vector3:
	var bends := Vector3.ZERO
	for phalanx in PHALANGES:
		var joint: Node3D = _targets[finger][phalanx]
		var rest: Basis = _rests[finger][phalanx].basis
		bends[phalanx] = _bend_of(rest.inverse() * joint.basis.orthonormalized())
	return bends


## From the hand body's contacts in the last step, per finger: the force
## pressing on it, in newtons, and how much of that pushes its bones toward
## their backs, which opens the finger (a table under an open hand's pads),
## rather than toward the palm side (a fist's knuckles) or along their length
## (a fingertip end-on). Only the push straight off each surface counts:
## friction dragging a fingertip along a table must not decide which way the
## finger gives.
func _read_contacts(delta: float) -> void:
	_forces.fill(0.0)
	_opening.fill(0.0)
	var state := PhysicsServer3D.body_get_direct_state(_hand.get_rid())
	var hand := _hand.global_basis
	for i in state.get_contact_count():
		var bone: int = _bone_of_shape.get(state.get_contact_local_shape(i), -1)
		if bone < 0:
			continue
		var finger := bone / PHALANGES
		var push := state.get_contact_impulse(i).project(state.get_contact_local_normal(i)) / delta
		_forces[finger] += push.length()
		# A bone's back is its +Y; the capsule shape lies along the bone.
		var back := (hand * _shapes[bone].transform.basis * CAPSULE_ALONG_BONE.inverse()).y.normalized()
		_opening[finger] += push.dot(back)


## Whether a finger bent to `bends` would keep its bones `first` to `last`
## `margin` clear of the world, where the hand will be after this step.
func _bones_clear(finger: int, bends: Vector3, first: int, last: int, margin: float) -> bool:
	_query.margin = margin
	var space := _hand.get_world_3d().direct_space_state
	var joint := Transform3D.IDENTITY
	for phalanx in last + 1:
		var index := finger * PHALANGES + phalanx
		joint = joint * _rests[finger][phalanx] * Transform3D(Basis(Vector3.RIGHT, -bends[phalanx]))
		if phalanx < first:
			continue
		_query.shape = _capsules[index]
		_query.transform = _ahead * joint * _along_bone(index)
		if not space.intersect_shape(_query, 1).is_empty():
			return false
	return true


## Counts the joints of `finger` that turned back this tick on the way they
## moved last tick, while their pose held still.
func _count_reversals(finger: int, move: Vector3, target: Vector3) -> void:
	var last := _last_moves[finger]
	var threshold := deg_to_rad(0.2)
	for joint in PHALANGES:
		var steady := absf(target[joint] - _last_targets[finger][joint]) < deg_to_rad(0.1)
		if steady and absf(move[joint]) > threshold and absf(last[joint]) > threshold \
				and signf(move[joint]) != signf(last[joint]):
			reversals += 1
	_last_moves[finger] = move
	_last_targets[finger] = target


## Whether anything lies within reach of a finger, bent any way, where the
## hand will be after this step.
func _near_anything(finger: int) -> bool:
	_reach_ball.radius = _reaches[finger]
	_reach_query.transform = Transform3D(Basis.IDENTITY, _ahead * _rests[finger][0].origin)
	return not _hand.get_world_3d().direct_space_state.intersect_shape(_reach_query, 1).is_empty()


## A finger's joint bends now, root to tip, in radians.
func bends_of(finger: int) -> Vector3:
	return _bends[finger]


## The hand's transform after `delta` more seconds at its current velocity.
func _predicted(delta: float) -> Transform3D:
	var hand := _hand.global_transform
	var spin := _hand.angular_velocity
	var basis := hand.basis
	if spin.length_squared() > 1e-8:
		basis = Basis(spin.normalized(), spin.length() * delta) * basis
	return Transform3D(basis, hand.origin + _hand.linear_velocity * delta)


## Lays a finger's three capsules on the hand at its current bends.
func _pose(finger: int) -> void:
	var joint := Transform3D.IDENTITY
	for phalanx in PHALANGES:
		var index := finger * PHALANGES + phalanx
		joint = joint * _rests[finger][phalanx] * Transform3D(Basis(Vector3.RIGHT, -_bends[finger][phalanx]))
		_shapes[index].transform = joint * _along_bone(index)


func _build() -> void:
	for finger in FINGERS:
		var rests: Array[Transform3D] = []
		var targets: Array[Node3D] = []
		var lengths: Vector3 = StaticSkeleton.FINGER_LENGTHS[finger] * _skeleton.hand_scale
		var root_radius := ROOT_RADII[finger] * thickness * _skeleton.hand_scale
		for phalanx in PHALANGES:
			rests.append(_skeleton.finger_rest(_left, finger, phalanx))
			targets.append(_skeleton.finger_joint(_left, finger, phalanx))
			var capsule := CapsuleShape3D.new()
			capsule.radius = ROOT_RADII[finger] * TAPER[phalanx] * thickness * _skeleton.hand_scale
			capsule.height = maxf(lengths[phalanx], capsule.radius * 2.0)
			var shape := CollisionShape3D.new()
			shape.name = "Finger%d%d" % [finger, phalanx]
			shape.shape = capsule
			_hand.add_child(shape)
			_shapes.append(shape)
			_capsules.append(capsule)
			_lengths.append(lengths[phalanx])
		_rests.append(rests)
		_targets.append(targets)
		_reaches.append(lengths.x + lengths.y + lengths.z + root_radius + clearance)
		_bends.append(Vector3.ZERO)
		_last_moves.append(Vector3.ZERO)
		_last_targets.append(Vector3.ZERO)
	for finger in FINGERS:
		_pose(finger)
	_query.exclude = _own_bodies()
	_reach_query.exclude = _query.exclude


## The hand body's shape index for each finger bone. Shapes are indexed in
## the order the physics server holds them, so this is read back, not assumed.
func _map_shapes() -> void:
	for index in PhysicsServer3D.body_get_shape_count(_hand.get_rid()):
		var holder := _hand.shape_owner_get_owner(_hand.shape_find_owner(index))
		var bone := _shapes.find(holder as CollisionShape3D)
		if bone >= 0:
			_bone_of_shape[index] = bone


## The player's own bodies, which a finger never has to keep clear of.
func _own_bodies() -> Array[RID]:
	var bodies: Array[RID] = [_physical.body.get_rid()]
	for other: HandDrive in [_physical.left_drive, _physical.right_drive]:
		if other != null:
			bodies.append(other.hand.get_rid())
	return bodies


## A bone's capsule, from its joint along -Z.
func _along_bone(index: int) -> Transform3D:
	return Transform3D(CAPSULE_ALONG_BONE, Vector3(0.0, 0.0, -_lengths[index] * 0.5))


## A joint's bend toward the palm from the turn `turn` about the bone's own X.
static func _bend_of(turn: Basis) -> float:
	var q := Quaternion(turn)
	return wrapf(-2.0 * atan2(q.x, q.w), -PI, PI)


func _publish(most_held: float, average_bend: float) -> void:
	var state := _physical.snapshot
	var first := _side * FINGERS * PHALANGES
	var hand := _hand.global_transform
	for index in _shapes.size():
		var bone := hand * _shapes[index].transform * _along_bone(index).affine_inverse()
		state.finger_bones[first + index] = bone
		state.finger_sizes[first + index] = Vector2(_capsules[index].radius, _lengths[index])
	state.finger_error[_side] = rad_to_deg(most_held)
	state.finger_bend[_side] = rad_to_deg(average_bend)
	state.finger_reversals[_side] = reversals
