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
@export var left_forearm_tracker: Node3D
@export var right_forearm_tracker: Node3D

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
@export var hand_rotation_degrees := Vector3(-15.0, 0.0, 0.0)
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
## How fast the chest falls back under the head while a hand reading is being
## rejected. Without this a rejected reading freezes the chest, and a frozen
## chest can never come back into agreement - the gate becomes a trap.
@export var torso_recovery_rate := 3.0
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

@export_group("Elbow hint cases")
## Two poses where the base hint reads wrong. Each blends in only within its own
## configuration and fades to nothing outside it, so every arm position that
## already bends correctly is left alone. Set a strength to 0 to A/B it.
##
## Hand below the shoulder with the wrist aimed outward: the upper arm should
## carry more outward and less downward than the base hint gives it.
@export var low_outward_hint := Vector3(1.0, -0.3, 0.0)
@export_range(0.0, 1.0) var low_outward_strength := 1.0
## Hand above the shoulder and in front, wrist aimed forward: the upper arm
## should carry forward and up rather than flaring out to the side.
@export var high_forward_hint := Vector3(0.3, 0.4, -1.0)
@export_range(0.0, 1.0) var high_forward_strength := 1.0

@export_group("Shoulder limits")
## How far the upper arm may swing horizontally away from pointing straight out
## to the side, in torso space. You can bring an arm a long way across the front
## of your body but only a little way behind it, and not straight inward at all
## - that last one falls out of the other two rather than needing its own knob.
##
## Elevation is never limited, only this horizontal direction, and even that
## relaxes to nothing as the arm approaches vertical: overhead you can reach
## across freely, and near vertical the horizontal direction of an arm barely
## determines where its elbow sits.
@export var shoulder_limit_forward := 135.0
@export var shoulder_limit_backward := 50.0

@export_group("Arm twist")
## How far the forearm alone can twist, either side of neutral. Beyond this the
## shoulder has to supply the rest.
@export var forearm_twist_limit := 90.0
## How far the humerus may rotate about its own axis. It carries whatever the
## forearm could not, which is why people twist the forearm to its limit before
## the shoulder starts moving.
@export var shoulder_twist_limit := 90.0
## Zeroes the measurement against your own hand calibration. Hold a palm flat
## and downward and adjust until the reported twist reads zero.
@export var twist_neutral_degrees := 0.0
## Where along the forearm its twist tracker sits, 0 at the elbow and 1 at the
## wrist. Pronation is distributed along the bone rather than happening at a
## joint, so this position is also the share of the twist the tracker carries.
@export_range(0.0, 1.0) var forearm_twist_position := 0.5

# Total hand roll per arm, in degrees, measured against the untwisted arm.
# Exposed for inspection while this is being calibrated.
var left_arm_twist := 0.0
var right_arm_twist := 0.0

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

	var head_forward := _flatten_facing(head_tracker.global_basis)

	# 1. Drift toward the hands, weighted by how much they can be trusted.
	#    `rejected` is how much of a usable reading is being thrown away, which
	#    is different from having no reading at all.
	var rejected := 0.0
	var tangent := _shoulder_tangent()
	var span := tangent.length()
	if span >= MIN_SHOULDER_SPAN:
		var hands_forward := Vector3.UP.cross(tangent / span)

		# Direction error scales inversely with span, so trust scales with it.
		var confidence := clampf(
			inverse_lerp(MIN_SHOULDER_SPAN, FULL_SHOULDER_SPAN, span), 0.0, 1.0)

		# Crossing your arms swaps which hand is on which side while your
		# shoulders stay put, so the shoulder line reverses and reads as a chest
		# facing backwards. The premise that hands mirror shoulders is simply
		# false in that pose, so fade the reading out as it diverges from where
		# the chest already points: full trust within 60 degrees, none past 90.
		var agreement := smoothstep(0.0, 0.5, hands_forward.dot(_torso_forward))
		rejected = 1.0 - agreement

		var weight := 1.0 - exp(-torso_yaw_smoothing
			* hands_steer_torso * confidence * agreement * delta)
		_torso_forward = _torso_forward.slerp(hands_forward, weight)

	# 2. While a reading is being rejected, fall back under the head. This is
	#    the way out of the deadlock where the chest lags a fast turn far enough
	#    that the reading is discarded, leaving nothing able to close the gap.
	#    Hands simply being too close together is not a rejection - there is no
	#    disagreement to escape, so the chest holds instead.
	if rejected > 0.0:
		_torso_forward = _torso_forward.slerp(
			head_forward, 1.0 - exp(-torso_recovery_rate * rejected * delta))

	# 3. The head can only twist so far before the chest has to come along.
	_torso_forward = _constrain_twist(_torso_forward, head_forward)

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
	_solve_elbow(left_shoulder_tracker, left_elbow_tracker,
			left_forearm_tracker, left_wrist_tracker, true)
	_solve_elbow(right_shoulder_tracker, right_elbow_tracker,
			right_forearm_tracker, right_wrist_tracker, false)


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
		forearm_tracker: Node3D,
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
	var hint := _elbow_hint_for(origin, wrist, is_left, torso_basis)
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

	# Clamp the upper arm into a reachable direction. When the wrist demands
	# more than that, the forearm stretches instead of the elbow jumping to a
	# different solution: a stretched arm is honest about being out of range,
	# whereas a teleported elbow invents a pose the body never passed through.
	var arm := elbow_position - origin
	if not arm.is_zero_approx():
		elbow_position = origin + _clamp_upper_arm(
				arm.normalized(), is_left) * upper_arm_length

	var to_hand := wrist.global_position - elbow_position
	if to_hand.is_zero_approx():
		return
	var forearm_axis := to_hand.normalized()

	# The elbow is a hinge. It has no roll axis, so it carries none of the
	# twist - its orientation comes purely from the arm's geometry.
	var elbow_basis := _look_along(forearm_axis, torso_basis)
	elbow.global_transform = Transform3D(elbow_basis, elbow_position)

	# Stage one: measure the hand's roll and spend it all on the forearm. Roll
	# about the forearm's own axis moves no joint, so a wrong measurement gives
	# a spinning forearm rather than a broken arm.
	var twist := _measure_arm_twist(forearm_axis, pole, wrist)
	if is_left:
		left_arm_twist = rad_to_deg(twist)
	else:
		right_arm_twist = rad_to_deg(twist)

	# The forearm takes what it can and the shoulder carries the overflow, which
	# is why a real arm pronates to its limit before the shoulder starts to
	# rotate. Both shares are spent as rolls about axes their segments already
	# lie on, so neither moves a joint - this is allocation made visible, not
	# yet allocation driving the geometry.
	var forearm_limit := deg_to_rad(forearm_twist_limit)
	var shoulder_limit := deg_to_rad(shoulder_twist_limit)
	var forearm_share := clampf(twist, -forearm_limit, forearm_limit)
	var shoulder_share := clampf(twist - forearm_share, -shoulder_limit, shoulder_limit)

	if forearm_tracker != null:
		# Position along the bone is also the share of the twist carried, and
		# the segment is measured rather than assumed so a stretched arm keeps
		# its forearm tracker in proportion.
		forearm_tracker.global_transform = Transform3D(
			elbow_basis.rotated(forearm_axis, forearm_share * forearm_twist_position),
			elbow_position + to_hand * forearm_twist_position)

	# The upper arm points at the elbow, not the wrist, and rolls by whatever
	# the forearm could not supply.
	var to_elbow := elbow_position - origin
	if not to_elbow.is_zero_approx():
		var upper_arm_axis := to_elbow.normalized()
		shoulder.global_basis = _look_along(upper_arm_axis, torso_basis).rotated(
				upper_arm_axis, shoulder_share)


## The base elbow hint, nudged toward a different one in the two configurations
## where the base reads wrong. Both weights are products of smoothsteps that go
## to zero outside their own case, so this returns the base hint unchanged for
## every pose that already bends correctly.
##
## Works in torso space with the left arm mirrored, so one set of numbers covers
## both sides. Returns the hint unmirrored, for the caller to flip.
func _elbow_hint_for(
		shoulder_position: Vector3,
		wrist: Node3D,
		is_left: bool,
		torso_basis: Basis) -> Vector3:
	var to_torso := torso_basis.inverse()
	var offset := to_torso * (wrist.global_position - shoulder_position)
	# Which way the wrist faces, as opposed to where it is. The sign is settled
	# by observation rather than by the grip pose's documented axes: +Z is what
	# actually reads as outward and forward on this hardware.
	var aim := to_torso * wrist.global_basis.z
	if is_left:
		offset.x = -offset.x
		aim.x = -aim.x

	var hint := elbow_pole_hint

	# Below the shoulder, aimed outward.
	hint = hint.lerp(low_outward_hint, low_outward_strength
			* smoothstep(0.0, 0.25, -offset.y)
			* smoothstep(0.3, 0.8, aim.x))

	# Above the shoulder, aimed forward. Deliberately not gated on being in
	# front of the body: reaching back behind your head wants the same forward
	# elbow as reaching up in front of you, and gating on it both killed the
	# case mid-reach and kept the weight from ever reaching full strength.
	hint = hint.lerp(high_forward_hint, high_forward_strength
			* smoothstep(0.0, 0.25, offset.y)
			* smoothstep(0.3, 0.8, -aim.z))

	return hint


## The hand's roll about the forearm, measured against an untwisted arm - which
## is the total twist the arm has to supply from somewhere, before deciding how
## much of it the forearm and the shoulder each contribute.
##
## The reference is the pole: with no twist anywhere, the hand's up axis sits in
## the arm's own plane, on the elbow's side of it.
func _measure_arm_twist(forearm: Vector3, pole: Vector3, wrist: Node3D) -> float:
	var reference := pole.slide(forearm)
	var actual := wrist.global_basis.y.slide(forearm)
	if reference.is_zero_approx() or actual.is_zero_approx():
		return 0.0
	return wrapf(
			reference.normalized().signed_angle_to(actual.normalized(), forearm)
			- deg_to_rad(twist_neutral_degrees),
			-PI, PI)


## Clamps an upper-arm direction into the range a shoulder can actually reach.
## Works in torso space with the left arm mirrored, so both sides share one set
## of numbers, and blends the four directional limits by how much the arm points
## each way - which is what makes the boundary lopsided rather than a cone.
func _clamp_upper_arm(direction: Vector3, is_left: bool) -> Vector3:
	if torso_tracker == null:
		return direction

	var torso_basis := torso_tracker.global_basis
	var local := torso_basis.inverse() * direction
	if is_left:
		local.x = -local.x

	# X is outward, Z is backward. How much of the arm lies in that plane is
	# also how meaningful its horizontal direction is.
	var horizontal := Vector2(local.x, local.z)
	var horizontality := horizontal.length()
	if horizontality < 0.001:
		return direction

	# Measured from straight out to the side, positive toward the back.
	var azimuth := atan2(horizontal.y, horizontal.x)

	# Both limits open out to unrestricted as the arm nears vertical.
	var widen := 1.0 - horizontality
	var forward_limit := lerpf(deg_to_rad(shoulder_limit_forward), PI, widen)
	var backward_limit := lerpf(deg_to_rad(shoulder_limit_backward), PI, widen)
	var clamped := clampf(azimuth, -forward_limit, backward_limit)
	if is_equal_approx(clamped, azimuth):
		return direction

	# Swing horizontally only - elevation is untouched, so a clamped arm slides
	# around the body rather than dropping.
	var swung := Vector2(cos(clamped), sin(clamped)) * horizontality
	local = Vector3(swung.x, local.y, swung.y).normalized()

	if is_left:
		local.x = -local.x
	return torso_basis * local


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
