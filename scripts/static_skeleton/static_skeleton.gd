class_name StaticSkeleton
extends Node3D

## The static layer: one transform per reference point on the body.
##
## Some points are measured (the headset, the controllers) and the rest are
## solved from them. Nothing here collides and nothing here is corrected by the
## world - this layer answers "where would this person's body be", not "where
## does the world allow it to be".
##
## Everything downstream reads trackers from here rather than reading the
## hardware directly. That way a solved point can later be replaced by a
## measured one, or vice versa, without any consumer changing.

## Solve before anything that consumes the skeleton.
const SOLVE_PRIORITY := -90
const ELEVATION_LIMIT := 0.75
## Below this, the hands are too close together to indicate a shoulder line.
const MIN_SHOULDER_SPAN := 0.05
## At or above this, the shoulder line is fully trusted.
const FULL_SHOULDER_SPAN := 0.35

@export_group("Measured")
@export var hmd: XRCamera3D
@export var left_controller: XRController3D
@export var right_controller: XRController3D

@export_group("Trackers")
## The player's eyes. Measured rather than solved - the headset sits on the
## face - so this is a pass-through that exists to keep the layer boundary.
@export var eye_tracker: Node3D
@export var head_tracker: Node3D
@export var neck_tracker: Node3D
@export var left_hand_tracker: Node3D
@export var right_hand_tracker: Node3D
@export var left_wrist_tracker: Node3D
@export var right_wrist_tracker: Node3D
@export var torso_tracker: Node3D
@export var left_shoulder_tracker: Node3D
@export var right_shoulder_tracker: Node3D
@export var left_elbow_tracker: Node3D
@export var right_elbow_tracker: Node3D

@export_group("Offsets")
@export var head_offset := Vector3(0.0, -0.02, 0.10)
@export var neck_length := 0.12
## How much the neck follows head tilt, per axis. Human cervical range of motion
## is not the same in every direction: roll distributes widely down the spine, so
## the base follows a lot, while pitch happens mostly in the upper joints.
## 0 holds the neck vertical under the pivot; 1 makes it hang straight out of the
## skull, which looks broken.
@export_range(0.0, 1.0) var neck_follow_pitch := 0.25
@export_range(0.0, 1.0) var neck_follow_roll := 0.15
## How far the neck base sits between the chest's facing and the head's. The
## cervical spine splits twist rather than transmitting all of it, so 0.5 is a
## reasonable start: turn your head 80 degrees and the base takes about 40.
@export_range(0.0, 1.0) var neck_follow_yaw := 0.5
## Controller pose to the centre of the palm, in pose-local space. Zero is
## often correct on a palm pose; anything you add here is compensating for how
## your controller sits in your hand.
@export var hand_offset := Vector3(0.025, -0.05, 0)
## Rotation from the controller's pose to a natural hand orientation, in
## degrees. A grip pose sits rotated relative to the hand it is held in:
## roughly -60 on X for Meta Touch, -40 for Pico, -45 as a generic start.
## Applied identically to both hands - only the translation mirrors.
@export var hand_rotation_degrees := Vector3(-30.0, 0.0, 0.0)
## Palm centre back to the wrist joint, in hand-local space.
@export var wrist_offset := Vector3(0.0, 0.0, 0.08)

@export_group("Torso")
## Neck base down to the centre of the chest.
@export var torso_length := 0.25
## How much of the neck's tilt the chest keeps. The spine distributes bend, so
## each segment down the chain takes less of it.
@export_range(0.0, 1.0) var torso_follow_tilt := 0.5
## How strongly the hands steer the chest's facing.
@export_range(0.0, 1.0) var hands_steer_torso := 0.75
@export var torso_yaw_smoothing := 6.0
## How far the head may twist before it drags the chest around with it.
@export var max_head_twist_degrees := 80.0

@export_group("Shoulders")
## Shoulder socket relative to the chest, in torso-local space: outward, up and
## forward. Mirrored on X for the left side. Tracking can tell you nothing about
## this - it is your body's proportions, measured once.
@export var shoulder_offset := Vector3(0.18, 0.18, 0.0)

@export_group("Elbows")
## Shoulder socket to elbow.
@export var upper_arm_length := 0.32
## Elbow to wrist.
@export var forearm_length := 0.30
## Which way the elbow prefers to point, in torso-local space: outward, down and
## back. Mirrored on X for the left arm. Only the direction matters.
@export var elbow_pole_hint := Vector3(0.5, -1.0, 0.5)

# The chest's facing persists between frames. Unlike every tracker above it, the
# torso is not a pure function of the current pose - it has memory, which is
# what lets a small head turn leave it alone and a large one drag it round.
var _torso_forward := Vector3.FORWARD


func _ready() -> void:
	process_physics_priority = SOLVE_PRIORITY

	# Fail loudly at startup rather than silently doing nothing every tick.
	if hmd == null:
		push_error("StaticSkeleton: no HMD assigned.")
	if eye_tracker == null:
		push_error("StaticSkeleton: no eye tracker assigned.")


## Solves the skeleton top-down. Order matters: each tracker may only read
## trackers solved above it.
func _physics_process(delta: float) -> void:
	_solve_eyes()
	_solve_head()
	_solve_neck()
	_solve_hands()
	_solve_torso(delta)
	_solve_shoulders()
	_solve_elbows()


## The headset pose is the eye pose.
func _solve_eyes() -> void:
	if hmd == null or eye_tracker == null:
		return
	eye_tracker.global_transform = hmd.global_transform

func _solve_head() -> void:
	if eye_tracker == null or head_tracker == null:
		return
	head_tracker.global_transform = eye_tracker.global_transform.translated_local(head_offset)

## The base of the neck, where it meets the torso. Orientation follows a
## fraction of the head's tilt per axis, and the drop runs along the neck's own
## down axis so that offset and orientation cannot disagree.
func _solve_neck() -> void:
	if head_tracker == null or neck_tracker == null:
		return

	var head_basis := head_tracker.global_basis

	# The neck base sits partway between the chest's facing and the head's.
	# `_torso_forward` is last frame's value: the torso solves after the neck,
	# and using the previous tick breaks that circular dependency. At 120Hz the
	# staleness is 8ms, which is invisible.
	var upright := Basis.looking_at(
		_torso_forward.slerp(_flatten_facing(head_basis), neck_follow_yaw),
		Vector3.UP)

	# Head orientation relative to that frame, scaled per axis. Yaw stays at
	# zero because `upright` already carries the neck's share of the twist.
	var euler := (upright.inverse() * head_basis).get_euler()
	var neck_basis := upright * Basis.from_euler(
		Vector3(euler.x * neck_follow_pitch, 0.0, euler.z * neck_follow_roll))

	neck_tracker.global_transform = Transform3D(
		neck_basis,
		head_tracker.global_position - neck_basis.y * neck_length)

## Both hands and both wrists.
func _solve_hands() -> void:
	_solve_hand(left_controller, left_hand_tracker, left_wrist_tracker, true)
	_solve_hand(right_controller, right_hand_tracker, right_wrist_tracker, false)


## Hand and wrist for one side. X is mirrored for the left hand: OpenXR's grip
## and palm poses use a convention where the X axis points out of the palm on
## one hand and into it on the other, so a shared offset needs flipping.
##
## Nothing is written when the controller is not tracking - a stale pose is far
## less misleading than a tracker snapping to the origin.
func _solve_hand(
		controller: XRController3D,
		hand: Node3D,
		wrist: Node3D,
		is_left: bool) -> void:
	if controller == null or hand == null:
		return
	if not controller.get_has_tracking_data():
		return

	var to_palm := hand_offset
	var to_wrist := wrist_offset
	if is_left:
		to_palm.x = -to_palm.x
		to_wrist.x = -to_wrist.x

	# Translate within the controller's pose frame, then rotate the result into
	# a natural hand orientation. The wrist offset below is therefore expressed
	# in hand space, not controller space.
	hand.global_transform = controller.global_transform * Transform3D(
		Basis.from_euler(hand_rotation_degrees * (PI / 180.0)),
		to_palm)

	if wrist != null:
		wrist.global_transform = hand.global_transform.translated_local(to_wrist)


## The chest. Position and tilt cascade down from the neck; facing drifts toward
## whatever the hands suggest and is then constrained by how far a head can
## actually twist. Those last two are a suggestion and a limit, not two
## opinions averaged - blending them would let the chest drift on a glance and
## still end up impossibly twisted.
func _solve_torso(delta: float) -> void:
	if neck_tracker == null or head_tracker == null or torso_tracker == null:
		return

	# 1. Drift toward the hands, weighted by how much they can be trusted.
	var tangent := _shoulder_tangent()
	var span := tangent.length()
	if span >= MIN_SHOULDER_SPAN:
		# Direction error scales inversely with span, so trust scales with it.
		var confidence := clampf(
			inverse_lerp(MIN_SHOULDER_SPAN, FULL_SHOULDER_SPAN, span), 0.0, 1.0)
		var hands_forward := Vector3.UP.cross(tangent / span)
		var weight := 1.0 - exp(
			-torso_yaw_smoothing * hands_steer_torso * confidence * delta)
		_torso_forward = _torso_forward.slerp(hands_forward, weight)

	# 2. The head can only twist so far before the chest has to come along.
	_torso_forward = _constrain_twist(
		_torso_forward, _flatten_facing(head_tracker.global_basis))

	# 3. Tilt cascades down from the neck, reduced again.
	var neck_basis := neck_tracker.global_basis
	var neck_upright := Basis.looking_at(_flatten_facing(neck_basis), Vector3.UP)
	var neck_tilt := (neck_upright.inverse() * neck_basis).get_euler()
	var torso_basis := Basis.looking_at(_torso_forward, Vector3.UP) * Basis.from_euler(
		Vector3(neck_tilt.x * torso_follow_tilt, 0.0, neck_tilt.z * torso_follow_tilt))

	torso_tracker.global_transform = Transform3D(
		torso_basis,
		neck_tracker.global_position - torso_basis.y * torso_length)


## The shoulder line the hands imply, flattened. Length carries how far apart
## they are, which is how much the direction can be trusted.
func _shoulder_tangent() -> Vector3:
	if left_hand_tracker == null or right_hand_tracker == null:
		return Vector3.ZERO
	var tangent := right_hand_tracker.global_position - left_hand_tracker.global_position
	return tangent.slide(Vector3.UP)


## Rotates the chest only once the head has twisted past what a neck allows,
## and then only by the excess.
func _constrain_twist(torso_forward: Vector3, head_forward: Vector3) -> Vector3:
	var limit := deg_to_rad(max_head_twist_degrees)
	var twist := torso_forward.signed_angle_to(head_forward, Vector3.UP)
	if absf(twist) <= limit:
		return torso_forward
	return torso_forward.rotated(Vector3.UP, twist - signf(twist) * limit)


## Both shoulders.
func _solve_shoulders() -> void:
	_solve_shoulder(left_shoulder_tracker, left_wrist_tracker, true)
	_solve_shoulder(right_shoulder_tracker, right_wrist_tracker, false)


## A shoulder socket. Position is rigidly fixed to the chest, because a shoulder
## is part of the torso rather than something tracking can observe.
##
## Orientation aims down the arm at the wrist. That is a stand-in: the upper arm
## actually points at the elbow, so this only reads true with a straight arm.
## It is worth having anyway, because the shoulder-to-wrist line is precisely the
## axis the elbow solve will rotate around.
func _solve_shoulder(shoulder: Node3D, wrist: Node3D, is_left: bool) -> void:
	if torso_tracker == null or shoulder == null:
		return

	var offset := shoulder_offset
	if is_left:
		offset.x = -offset.x

	var torso_basis := torso_tracker.global_basis
	var shoulder_position := torso_tracker.global_position + torso_basis * offset
	var shoulder_basis := torso_basis

	if wrist != null:
		var to_wrist := wrist.global_position - shoulder_position
		if not to_wrist.is_zero_approx():
			shoulder_basis = _look_along(to_wrist.normalized(), torso_basis)

	shoulder.global_transform = Transform3D(shoulder_basis, shoulder_position)


## Both elbows.
func _solve_elbows() -> void:
	_solve_elbow(left_shoulder_tracker, left_elbow_tracker, left_wrist_tracker, true)
	_solve_elbow(right_shoulder_tracker, right_elbow_tracker, right_wrist_tracker, false)


## Two-bone IK. The shoulder and wrist are both known and the bone lengths are
## fixed, which pins the elbow to a circle around the shoulder-to-wrist axis.
## Every point on that circle is an equally valid solution and nothing in the
## tracking says which - so a pole hint picks one, and the hint is anatomy
## rather than measurement.
##
## This also corrects the shoulder to aim at the elbow. The upper arm runs
## shoulder-to-elbow, so that direction genuinely belongs to this solve; the
## wrist-aiming in _solve_shoulder is only a provisional value.
func _solve_elbow(
		shoulder: Node3D,
		elbow: Node3D,
		wrist: Node3D,
		is_left: bool) -> void:
	if shoulder == null or elbow == null or wrist == null or torso_tracker == null:
		return

	var torso_basis := torso_tracker.global_basis
	var origin := shoulder.global_position
	var to_wrist := wrist.global_position - origin
	var chord := to_wrist.length()
	if chord < 0.001:
		return
	var axis := to_wrist / chord

	# The hint, projected into the plane the elbow circle lies in. A hint
	# parallel to the arm says nothing about which way round the circle to go.
	var hint := elbow_pole_hint
	if is_left:
		hint.x = -hint.x
	var pole := (torso_basis * hint).slide(axis)
	if pole.is_zero_approx():
		pole = (torso_basis * Vector3.DOWN).slide(axis)
		if pole.is_zero_approx():
			return
	pole = pole.normalized()

	# Law of cosines: how far along the chord the circle sits, and its radius.
	# A chord longer than both bones together means the arm cannot reach, the
	# circle collapses to a point, and the arm straightens.
	var elbow_position: Vector3
	if chord >= upper_arm_length + forearm_length:
		elbow_position = origin + axis * upper_arm_length
	else:
		var along := (upper_arm_length * upper_arm_length
				- forearm_length * forearm_length
				+ chord * chord) / (2.0 * chord)
		var radius := sqrt(maxf(
				upper_arm_length * upper_arm_length - along * along, 0.0))
		elbow_position = origin + axis * along + pole * radius

	var to_hand := wrist.global_position - elbow_position
	var elbow_basis := torso_basis
	if not to_hand.is_zero_approx():
		elbow_basis = _look_along(to_hand.normalized(), torso_basis)
	elbow.global_transform = Transform3D(elbow_basis, elbow_position)

	# The upper arm points at the elbow, not the wrist.
	var to_elbow := elbow_position - origin
	if not to_elbow.is_zero_approx():
		shoulder.global_basis = _look_along(to_elbow.normalized(), torso_basis)


## A basis whose -Z runs along `direction`, using the reference's up axis as the
## roll hint. Falls back to the reference's forward when the arm is nearly
## parallel to that up - arms hanging at your sides is the rest pose, so this
## degenerate case is the common one rather than the rare one.
func _look_along(direction: Vector3, reference: Basis) -> Basis:
	var up := reference.y
	if absf(direction.dot(up)) > 0.99:
		up = -reference.z
	return Basis.looking_at(direction, up)


## A basis's forward direction, flattened to horizontal. Near-vertical forward
## can't be flattened, so the up axis stands in - the same degenerate case as
## every other projection onto a plane.
func _flatten_facing(basis: Basis) -> Vector3:
	var forward := -basis.z
	var elevation := forward.dot(Vector3.UP)
	if elevation > ELEVATION_LIMIT:
		return (-basis.y).slide(Vector3.UP).normalized()
	elif elevation < -ELEVATION_LIMIT:
		return basis.y.slide(Vector3.UP).normalized()
	return forward.slide(Vector3.UP).normalized()
