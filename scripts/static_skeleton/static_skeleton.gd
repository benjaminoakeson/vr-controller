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
## Below this the body is standing still and has no direction of travel.
const MIN_TRAVEL_SPEED := 0.05


## What one foot remembers between frames.
##
## Every tracker above the hips is a pure function of the current pose. A foot
## is not, and cannot be - no arrangement of head and hands says where a foot
## is. It stays where it was put, which is the whole reason a step reads as a
## step rather than a slide.
##
## A step here has two separate decisions rather than one. Lifting happens as
## soon as the body leaves its base of support, which is what makes it feel
## responsive. Where the foot comes down is not decided then, and is not
## predicted: it is worked out afresh every frame and settled only at the
## moment something says to land. Nothing is scheduled, so there is nothing to
## overshoot when you stop.
class Foot:
	## The live sole transform - resting when planted, moving when not.
	var sole := Transform3D.IDENTITY
	## Where this step began, for shaping the arc.
	var lift_from := Transform3D.IDENTITY
	## Where it is heading right now. Re-derived every frame until committed.
	var target := Transform3D.IDENTITY
	var airborne := false
	## Set once a landing has been called for. The target stops chasing and the
	## foot is simply put down.
	var committed := false
	## Which way the body was going when this foot left the ground, so that a
	## change of mind can be recognised.
	var travel := Vector3.ZERO
	var airtime := 0.0
	## Height above the floor, rate limited so that a target snapping closer
	## cannot snap the foot down with it.
	var height := 0.0

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
@export var hip_tracker: Node3D
## The sole, on the floor. This is what the gait moves.
@export var left_foot_tracker: Node3D
@export var right_foot_tracker: Node3D
## The hip sockets, which are to the pelvis what the shoulders are to the chest.
@export var left_hip_tracker: Node3D
@export var right_hip_tracker: Node3D
@export var left_knee_tracker: Node3D
@export var right_knee_tracker: Node3D
@export var left_ankle_tracker: Node3D
@export var right_ankle_tracker: Node3D

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
## Chest centre down to the pelvis.
@export var hip_distance := 0.25

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

@export_group("Stance")
## Centre to centre between the feet at rest.
@export var stance_width := 0.24
## How far the feet splay outward. Feet at rest are not parallel.
@export var foot_toe_out_degrees := 4.0
## How close together the feet may be placed. Stepping sideways shuffles; it
## does not plait the legs, so a target is never allowed across the midline nor
## within this of where the other foot actually is.
@export var min_stance_separation := 0.14

@export_group("Gait")
## How far a foot may fall behind where it wants to be before it lifts, as a
## share of how far the standing leg can actually cover.
##
## Derived from the leg rather than set in metres, so a taller avatar tolerates
## more drift without anyone editing a number, and a crouching player tolerates
## more still - crouch and the horizontal reach of a leg genuinely grows.
@export_range(0.1, 1.0) var lift_lag_fraction := 0.35
## The deadzone: how far a foot may sit from directly under you, when you are
## not going anywhere, before it tidies itself up. Standing still, this is the
## whole trigger, and it is why stopping brings both feet home.
@export var deadzone_radius := 0.15
## The speed at which a foot is given the full allowance to trail behind.
@export var deadzone_speed_reference := 0.6
## How far in front of or behind you a foot may ever be placed, and how far out
## to the side. Bounds rather than targets: the stride decides where inside this
## box a foot goes, and these make sure it is a place a person could stand.
@export var max_stance_reach := 0.45
@export var max_stance_straddle := 0.38
## How much of a step survives when travel is sideways or backwards. Legs are
## hinged to swing forward, and a sidestep at the same pace is much shorter.
@export_range(0.1, 1.0) var lateral_step_scale := 0.6
@export_range(0.1, 1.0) var backward_step_scale := 0.7
## How far the hips may turn away from a foot before it steps round. Turning on
## the spot moves the body nowhere, so the deadzone never catches it.
@export var yaw_trigger_degrees := 40.0

@export_subgroup("Stride")
## How far ahead a foot reaches at a walk, and at a crawl. A slow step is a
## short one - the interesting range in a room is narrow, so both ends matter.
@export var max_step_length := 0.55
@export var min_step_length := 0.10
## The speed at which steps reach their full length. Roomscale pace, not
## treadmill pace: you cannot get far in a room before running out of room.
@export var reference_speed := 0.9
## How the range between the two lengths is traversed. Below 1 favours the slow
## end, which is where the resolution is wanted.
@export_range(0.1, 2.0) var stride_exponent := 0.7

@export_subgroup("Prediction")
## The most speed that may be used to lead a step, and how much of it to use.
## Their product is a hard ceiling on how far ahead of you anything can aim -
## about 16cm at the defaults, which is what VRIK settles on.
##
## The ceiling is the point. A velocity read off the pelvis is noisy and
## occasionally absurd, and an unbounded prediction turns an absurd reading into
## a foot flung across the room. Bounded, the worst case is merely a bit early.
@export var max_prediction_speed := 0.4
@export_range(0.0, 1.0) var prediction_factor := 0.4

@export_subgroup("Landing")
## How far a standing leg may be extended before the airborne foot has to come
## down, where 1 is bone straight. This is the gait's clock, and it is the only
## trigger here that is not a tuned proxy - it is the actual constraint, so it
## needs no step-period arithmetic and it gets crouching right for free.
@export_range(0.5, 1.0) var max_leg_stretch := 0.99
## Below this the body has stopped and the foot goes down where it stands.
@export var stop_speed := 0.12
## How far travel must turn from where it was heading at lift-off before the
## step is abandoned. -1 is a full reversal, 0 a right angle.
@export_range(-1.0, 1.0) var reversal_dot := 0.2
## A foot may not hang in the air longer than this whatever else is true.
@export var max_airtime := 0.45
## Nor may it come down sooner than this. Every landing reason except running
## out of reach is a judgement about what the body is doing, and all of them can
## be true the instant a foot leaves the ground - so without a floor here a step
## begins and ends in one frame and the gait becomes a vibration.
@export var min_airtime := 0.10
## And the next foot may not leave before this. One foot landing usually means
## the other is now the one out of place, so this is what stops the pair
## trading places every frame.
@export var min_support_time := 0.06

@export_subgroup("Motion")
## How fast a foot travels over the ground when the body is still.
##
## A fixed figure is not enough. The target a foot is chasing runs away at body
## speed, so what closes the gap is the difference between the two - and if that
## difference is small the foot spends most of a second in the air, the other
## foot falls further behind while it waits, and the next step is longer again.
## Hence a floor proportional to how fast you are actually going.
@export var swing_speed := 1.8
@export_range(1.5, 6.0) var swing_speed_ratio := 3.2
## Peak lift of a full-length step. Shorter steps lift proportionally less.
@export var step_height := 0.07
## How fast a foot may rise or fall. Rate limiting matters because the target
## can jump closer the instant a landing is called for, and without this the
## arc would collapse in one frame.
@export var lift_rate := 1.2
## How hard the pelvis velocity is smoothed. Read quickly: it answers which way
## you are going and whether you have stopped, and a late stop is the worst
## thing this system can do.
@export var pelvis_velocity_smoothing := 10.0
## How hard your pace is smoothed, which is a different question. The pelvis
## surges within every stride and swings when you merely turn to look, so pace
## climbs slowly - but it is never allowed above the speed actually being read,
## so it falls at once. Momentum takes work to build and none at all to lose.
@export var pace_smoothing := 4.0

@export_group("Legs")
## Hip socket relative to the pelvis, in pelvis-local space: outward and down.
## Mirrored on X. The pelvis tracker sits in the middle of the pelvis rather
## than at the joints, which is where the drop comes from.
@export var hip_offset := Vector3(0.09, -0.10, 0.0)
## Hip socket to knee.
@export var thigh_length := 0.45
## Knee to ankle. With the ankle height these have to span socket to floor:
## standing still should read a little under 1 on `left_leg_extension`.
@export var shin_length := 0.45
## The ankle joint, above the sole.
@export var ankle_height := 0.08
## Which way the knee prefers to point, in the foot's own frame: the way a shin
## points, up from the ankle and leaning forward over the toes, with a touch
## outward. Mirrored on X for the left leg. A knee bends one way only, so
## unlike the elbow this is near enough a constant.
##
## The upward part matters. A hint that only points forward puts the knee
## wherever the hips go: shift the hips sideways in a crouch and the knee
## swings round the ankle with them, down beside the foot. Pointed up the
## shin, it projects onto the knee's circle at the point above the foot, and
## the thigh angles across to meet the hips instead - which is what a knee
## does, and why one stays over its foot until the foot moves.
@export var knee_pole_hint := Vector3(0.08, 0.85, -0.5)
## Where it points instead once the leg has folded into a crouch: further out,
## so the knees splay either side of the body rather than both jutting straight
## ahead. Blended in by how far the leg has folded, so a walking knee is left
## alone. Set the strength to 0 to A/B it.
@export var crouch_knee_pole_hint := Vector3(0.25, 0.85, -0.5)
@export_range(0.0, 1.0) var crouch_knee_strength := 1.0
## A squat is a hip hinge: the hips go back as they go down, and that is what
## puts the knees up and out in front of the feet. With the hips kept directly
## over the ankles a bent leg can only fold its knee straight forward, down to
## the floor. How far back the pelvis sits from under the chest in a full
## crouch, and the drop of the hips below a straight leg at which it starts to
## sit back and at which it has sat all the way back. A shallow bend keeps the
## hips where they are and sends the knees forward instead.
@export var crouch_setback := 0.2
@export var crouch_setback_start := 0.15
@export var crouch_setback_depth := 0.45

# Total hand roll per arm, in degrees, measured against the untwisted arm.
# Exposed for inspection while this is being calibrated.
var left_arm_twist := 0.0
var right_arm_twist := 0.0

# The chest's facing persists between frames. Unlike every tracker above it, the
# torso is not a pure function of the current pose - it has memory, which is
# what lets a small head turn leave it alone and a large one drag it round.
var _torso_forward := Vector3.FORWARD

# How much of its length each leg is spanning, 1 being bone straight. Exposed
# because the bone lengths cannot be eyeballed, and because the standing leg's
# value is what calls the airborne foot down.
var left_leg_extension := 0.0
var right_leg_extension := 0.0

# The point the feet stand under: where the pelvis would hang from the neck
# with the spine straight down. In a crouch the spine leans and the pelvis
# sits back from here, but the feet do not follow it - a squat moves the hips,
# not the feet.
var _balance_point := Vector3.ZERO

# The lower body's memory.
var _left_foot := Foot.new()
var _right_foot := Foot.new()
var _feet_placed := false
var _pelvis_velocity := Vector3.ZERO
var _pace := 0.0
var _since_land := 0.0
# The pelvis' frame, standing upright and facing where the hips face. Every
# placement decision below is made in it, so it is worked out once a tick
# rather than six times.
var _upright := Basis.IDENTITY
var _to_local := Basis.IDENTITY
var _previous_pelvis_position := Vector3.ZERO


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
	_solve_hips()
	_solve_hip_sockets()
	_solve_feet(delta)
	_solve_ankles()
	_solve_knees()


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

	# 4. Tilt cascades down from the neck, reduced again.
	var neck_basis := neck_tracker.global_basis
	var neck_upright := Basis.looking_at(_flatten_facing(neck_basis), Vector3.UP)
	var neck_tilt := (neck_upright.inverse() * neck_basis).get_euler()
	var tilt := Basis.from_euler(
		Vector3(neck_tilt.x * torso_follow_tilt, 0.0, neck_tilt.z * torso_follow_tilt))

	# 5. Nor can a hand cross further in front of the body than its upper arm
	#    can follow before the chest has to turn with it. This goes last so
	#    that nothing above can leave an arm without a continuous solution: the
	#    chest may lag a swing, but it may not let the hand outrun the shoulder.
	_torso_forward = _constrain_reach(_torso_forward, tilt)

	# 6. Crouching, the spine hinges forward from the neck so the hips can sit
	#    back behind the feet. Applied to the finished facing: it is a lean,
	#    not a turn, and the facing remembers nothing of it.
	var torso_basis := _crouch_lean(Basis.looking_at(_torso_forward, Vector3.UP) * tilt)
	torso_tracker.global_transform = Transform3D(
		torso_basis,
		neck_tracker.global_position - torso_basis.y * torso_length)


## Leans the spine forward from the neck by however much puts the pelvis its
## crouch setback behind where it would hang. The chest and pelvis stay one
## straight line from the neck, so the chest leans as a squatting chest does
## and the pelvis is always at the bottom of it. The lean is measured against a
## straight leg, from where the pelvis would hang with no lean at all, and
## that hanging point is also what the feet stand under.
##
## The lean is toward behind the feet, not behind wherever the chest faces:
## the feet are the base the hips are sitting back from, and a crouched player
## turning to look must not have the hips swung round underneath them.
func _crouch_lean(torso_basis: Basis) -> Basis:
	var spine := torso_length + hip_distance
	_balance_point = neck_tracker.global_position - torso_basis.y * spine

	var socket_height := (_balance_point + torso_basis * hip_offset).y \
			- (_ground_height() + ankle_height)
	var sunk := thigh_length + shin_length - socket_height
	var setback := crouch_setback * smoothstep(
			crouch_setback_start, crouch_setback_depth, sunk)
	if setback <= 0.0:
		return torso_basis

	var back := -_feet_facing(_flatten_facing(torso_basis))
	var lean := asin(clampf(setback / spine, 0.0, 1.0))
	return torso_basis.rotated(back.cross(Vector3.UP), lean)


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


## Turns the chest so that neither hand lies further across the front of the
## body than its upper arm is allowed to swing - the same forward limit the
## elbow solve clamps to. A hand past that has no continuous elbow: the upper
## arm would have to pass straight inward, which is the seam between reaching
## with the elbow forward and reaching with it back, and the clamp flips from
## one to the other there. A real body never gets to that seam because the
## chest turns first, so the chest turns here - by the excess and no more.
## Lagging a swing is still allowed; letting a hand outrun the shoulder is not.
##
## The two hands can demand opposite turns - arms crossed with both hands well
## out in front - and then nothing satisfies both. The chest splits the
## difference so that both elbows clamp equally, rather than one hand winning
## and the other's elbow flipping.
func _constrain_reach(torso_forward: Vector3, tilt: Basis) -> Vector3:
	if neck_tracker == null:
		return torso_forward

	var torso_basis := Basis.looking_at(torso_forward, Vector3.UP) * tilt
	var centre := neck_tracker.global_position - torso_basis.y * torso_length
	var right := _reach_excess(right_wrist_tracker, centre, torso_basis, false)
	var left := _reach_excess(left_wrist_tracker, centre, torso_basis, true)
	if right <= 0.0 and left <= 0.0:
		return torso_forward

	# Turning left is positive. It brings the right hand back by exactly that
	# angle and carries the left hand across by the same, so each hand is
	# turned back by its excess unless that would push the other past its
	# limit, in which case they meet halfway.
	var turn := clampf((right - left) / 2.0, -maxf(left, 0.0), maxf(right, 0.0))
	return torso_forward.rotated(Vector3.UP, turn)


## How far a hand has crossed past where its upper arm can follow, as an angle
## around the body's axis in radians, or negative by how much room it has. The
## axis is the one thing turning the chest does not move, so a turn by exactly
## this angle brings the hand to the limit - measured from the socket instead,
## the socket swings with the turn and a hand near the chest can end up
## further past the limit for having turned toward it.
##
## The limit is solved rather than stepped toward: the direction of the upper
## arm's forward limit is cast from the socket until it is as far from the
## axis as the hand is, and the hand may lie no further round than that point.
## Reaching close to the chest is done by the shoulder blade sliding, which
## nothing here models, so a hand nearer the axis than the socket has the
## socket treated as being on the axis - where the limit is simply how far
## past straight ahead the upper arm may swing - and by twice that distance
## the socket is where it really is. The result widens toward vertical the
## same way the elbow clamp does, so the two agree on where the limit is.
##
## Only the front is guarded. A hand behind the shoulder line is reaching
## round the back, where the elbow-back solve is right and the existing clamp
## holds, so it has nothing to ask of the chest.
func _reach_excess(
		wrist: Node3D,
		centre: Vector3,
		torso_basis: Basis,
		is_left: bool) -> float:
	if wrist == null:
		return -INF

	var local := torso_basis.inverse() * (wrist.global_position - centre)
	if is_left:
		local.x = -local.x
	if local.z > 0.0:
		return -INF

	# The hand around the axis: X outward, Y forward, so that atan2 of the
	# inward and forward components counts from straight ahead toward the far
	# side of the body.
	var flat := Vector2(local.x, -local.z)
	var radius := flat.length()
	if radius < 0.001:
		return -INF
	var bearing := atan2(-flat.x, flat.y)

	var socket := Vector2(shoulder_offset.x, -shoulder_offset.z) * smoothstep(
			shoulder_offset.x, 2.0 * shoulder_offset.x, radius)
	var angle := deg_to_rad(shoulder_limit_forward)
	var ray := Vector2(cos(angle), sin(angle))
	var along := ray.dot(socket)
	var reach := -along + sqrt(maxf(
			along * along + radius * radius - socket.length_squared(), 0.0))
	var at_limit := socket + ray * reach
	var limit := atan2(-at_limit.x, at_limit.y)

	var height := local.y - shoulder_offset.y
	var horizontality := radius / sqrt(radius * radius + height * height)
	limit = lerpf(limit, PI, 1.0 - horizontality)
	return bearing - limit


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


## A basis whose -Z runs along `direction` and whose Y faces the way the joint
## bends. Give both bones of a hinge the same pole and their X axes coincide:
## that shared axis is the hinge, and the two bases differ only by a turn
## about it. The pole is never along either bone - it is what the bones bend
## toward - so unlike a fixed up axis it has no degenerate case to fall out of.
func _hinge_basis(direction: Vector3, pole: Vector3) -> Basis:
	var up := pole
	if absf(direction.dot(up)) > 0.99:
		up = Vector3.UP if absf(direction.dot(Vector3.UP)) <= 0.99 else Vector3.FORWARD
	return Basis.looking_at(direction, up)


## A basis whose -Z runs along `direction`, using the reference's up axis as the
## roll hint. Falls back to the reference's forward when the arm is nearly
## parallel to that up - arms hanging at your sides is the rest pose, so this
## degenerate case is the common one rather than the rare one.
func _look_along(direction: Vector3, reference: Basis) -> Basis:
	var up := reference.y
	if absf(direction.dot(up)) > 0.99:
		up = -reference.z
	return Basis.looking_at(direction, up)


## The pelvis. It hangs below the chest and copies its rotation outright, so
## when the spine leans into a crouch it is carried back and tilted with it.
## It also inherits the chest's lean when you bend - a real pelvis stays more
## upright than the chest then, and that is a variation still to add.
func _solve_hips() -> void:
	if torso_tracker == null or hip_tracker == null:
		return

	var torso_basis := torso_tracker.global_basis
	hip_tracker.global_transform = Transform3D(
		torso_basis,
		torso_tracker.global_position - torso_basis.y * hip_distance)


## Which way the feet face, between the two and flattened. Read from last
## tick's soles: the feet solve after the pelvis, and where a planted foot
## points does not change from one tick to the next.
func _feet_facing(fallback: Vector3) -> Vector3:
	if not _feet_placed:
		return fallback
	var facing := _flatten_facing(_left_foot.sole.basis) \
			+ _flatten_facing(_right_foot.sole.basis)
	if facing.is_zero_approx():
		return fallback
	return facing.normalized()


## Both hip sockets. Solved before the feet because the standing leg's extension
## is measured from here, and that measurement is what ends a step.
func _solve_hip_sockets() -> void:
	_solve_hip_socket(left_hip_tracker, true)
	_solve_hip_socket(right_hip_tracker, false)


## A hip socket. Like a shoulder it is part of the pelvis rather than anything
## tracking can observe, so its position is fixed offsets and nothing else, and
## it tilts with the pelvis because the joint really is carried by that bone.
##
## The orientation here points straight down and is provisional, exactly as the
## shoulder's aim at the wrist is: the knee solve replaces it with the thigh.
func _solve_hip_socket(hip: Node3D, is_left: bool) -> void:
	if hip_tracker == null or hip == null:
		return

	var offset := hip_offset
	if is_left:
		offset.x = -offset.x

	var pelvis_basis := hip_tracker.global_basis
	hip.global_transform = Transform3D(
			_look_along(-pelvis_basis.y, pelvis_basis),
			hip_tracker.global_position + pelvis_basis * offset)


## Both feet.
func _solve_feet(delta: float) -> void:
	if hip_tracker == null:
		return

	_upright = Basis.looking_at(
			_flatten_facing(hip_tracker.global_basis), Vector3.UP)
	_to_local = _upright.inverse()

	if not _feet_placed:
		_feet_placed = true
		_previous_pelvis_position = _balance_point
		_left_foot.sole = _stance_for(true)
		_right_foot.sole = _stance_for(false)

	_track_pelvis(delta)
	_since_land += delta

	var step := _step_length()
	_advance_foot(_left_foot, true, step, delta)
	_advance_foot(_right_foot, false, step, delta)

	# One foot at a time. Both off the ground at once is a hop, and nothing at
	# this layer has been told the player jumped.
	if not _left_foot.airborne and not _right_foot.airborne \
			and _since_land >= min_support_time:
		_try_lift(step)

	if left_foot_tracker != null:
		left_foot_tracker.global_transform = _left_foot.sole
	if right_foot_tracker != null:
		right_foot_tracker.global_transform = _right_foot.sole


## The pelvis' velocity, and your pace, which are not the same question.
func _track_pelvis(delta: float) -> void:
	var position := _balance_point
	if delta > 0.0:
		var sample := (position - _previous_pelvis_position).slide(Vector3.UP) / delta
		_pelvis_velocity = _pelvis_velocity.lerp(
				sample, 1.0 - exp(-pelvis_velocity_smoothing * delta))

		var speed := _pelvis_velocity.length()
		_pace = minf(
				lerpf(_pace, speed, 1.0 - exp(-pace_smoothing * delta)), speed)
	_previous_pelvis_position = position


## Whether to lift a foot, and which one.
##
## The test is per foot - how far this one is from where it now wants to be -
## rather than a single reading of the body. The deadzone's job is to set how
## much of that is tolerated, and it tightens as the body's weight strays from
## the middle of the feet, so a lean that is going nowhere is ignored while a
## body that has genuinely set off commits almost at once.
func _try_lift(step: float) -> void:
	# How much a foot is allowed to trail is a question about speed, and only
	# about speed. Standing still it is the deadzone and nothing more, which is
	# what walks both feet back underneath you when you stop. Moving, a foot is
	# allowed to fall as far behind as the leg can still cover.
	var moving := clampf(
			_pelvis_velocity.length() / maxf(deadzone_speed_reference, 0.001),
			0.0, 1.0)
	var allowed := lerpf(deadzone_radius, _reach_allowance(step), moving)
	var turn_limit := deg_to_rad(yaw_trigger_degrees)

	var lift: Foot = null
	var lift_left := false
	var furthest := -1.0

	for is_left in [true, false]:
		var foot := _left_foot if is_left else _right_foot
		var distance := (_reach_target(is_left, step).origin
				- foot.sole.origin).slide(Vector3.UP).length()
		if distance <= allowed and _yaw_error(foot, is_left) <= turn_limit:
			continue

		# The foot with furthest to go is the one trailing the body, and that is
		# the one you step with - you cannot lift the foot your weight is about
		# to pass over. VRIK takes the shortest instead, but its targets sit
		# under the body where both feet are much of a muchness; ours reach
		# forward, so the shortest is always the front foot and picking it gives
		# a limp: the same leg shuffling while the other one is left behind.
		if distance > furthest:
			furthest = distance
			lift = foot
			lift_left = is_left

	if lift == null:
		return

	lift.airborne = true
	lift.committed = false
	lift.airtime = 0.0
	lift.lift_from = lift.sole
	lift.travel = _travel_direction()


## How far a planted foot may sit from where it wants to be before it lifts.
##
## Two parts. The step it is aiming for is one: a foot heading somewhere far is
## not behind merely because it has far to go. The other is how far it may trail
## the body, which comes from the leg - a straight leg reaching sideways covers
## sqrt(L squared minus its own height), and that is a real distance that shrinks
## as you stand tall and grows as you crouch.
func _reach_allowance(step: float) -> float:
	# Measured against the whole leg rather than the stretch limit: this is how
	# far a foot may sensibly trail, not how far it may be placed.
	return step * 0.5 + _leg_reach(left_hip_tracker, 1.0) * lift_lag_fraction


## How far from a socket a leg can put a foot on the floor.
##
## A straight leg dropping to the ground covers a circle of radius
## sqrt(leg squared minus the drop squared). It is a real distance and it moves:
## it shrinks as you stand tall and opens up as you crouch, which is why a
## crouching player can reach further without anyone having said so.
##
## The socket is passed in rather than assumed, because the two are only at the
## same height while the pelvis is level - roll it and the mirrored offsets
## carry one hip lower than the other.
func _leg_reach(hip: Node3D, stretch: float) -> float:
	if hip == null:
		return 0.0

	var drop := hip.global_position.y - (_ground_height() + ankle_height)
	var limit := (thigh_length + shin_length) * stretch
	return sqrt(maxf(limit * limit - drop * drop, 0.0))


## Moves an airborne foot, and puts it down.
##
## The foot walks toward its target at a fixed speed rather than over a fixed
## duration. Nothing schedules a landing, so the target is free to change under
## it - and when a landing is called for, the target simply becomes the ground
## beneath the hips and the foot is already most of the way there.
func _advance_foot(foot: Foot, is_left: bool, step: float, delta: float) -> void:
	if not foot.airborne:
		return

	foot.airtime += delta
	if not foot.committed and _should_land(foot, is_left):
		foot.committed = true

	# A step that ends because the body stopped is not a stride any more, so it
	# stops reaching: the foot comes down in the deadzone under the hips, and
	# the other one is then out of place by more than the deadzone allows and
	# follows it home on the next tick it is permitted one.
	var aim := step
	if foot.committed and _pelvis_velocity.length() < stop_speed:
		aim = 0.0
	foot.target = _reach_target(is_left, aim)

	var to_target := (foot.target.origin - foot.sole.origin).slide(Vector3.UP)
	var travel_speed := maxf(swing_speed,
			_pelvis_velocity.length() * swing_speed_ratio)
	var reach := maxf(travel_speed, 0.01) * delta
	var arrived := to_target.length() <= reach

	var origin := foot.target.origin if arrived \
			else foot.sole.origin + to_target.normalized() * reach

	# Height follows how much of this step is left rather than how long it has
	# taken, so a target that moves closer pulls the foot down instead of
	# leaving it hanging. Sine is zero at both ends by construction: a foot
	# cannot begin or finish a step already off the ground.
	var travelled := (origin - foot.lift_from.origin).slide(Vector3.UP).length()
	var remaining := (foot.target.origin - origin).slide(Vector3.UP).length()
	var span := travelled + remaining
	var along := travelled / span if span > 0.001 else 1.0
	var peak := step_height * clampf(span / maxf(max_step_length, 0.001), 0.0, 1.0)
	foot.height = move_toward(
			foot.height, 0.0 if arrived else sin(along * PI) * peak,
			maxf(lift_rate, 0.01) * delta)

	origin.y = _ground_height() + foot.height
	foot.sole = Transform3D(foot.target.basis, origin)

	if arrived and foot.height <= 0.0:
		foot.airborne = false
		foot.committed = false
		_since_land = 0.0


## Whether the airborne foot has to come down now.
func _should_land(foot: Foot, is_left: bool) -> bool:
	# Running out of reach is the one reason that cannot wait: the standing leg
	# physically has nothing left, so this overrides the minimum air time.
	if _stance_extension(not is_left) >= max_leg_stretch:
		return true

	if foot.airtime < min_airtime:
		return false

	if _pelvis_velocity.length() < stop_speed:
		return true

	var travel := _travel_direction()
	if not travel.is_zero_approx() and not foot.travel.is_zero_approx():
		if travel.dot(foot.travel) < reversal_dot:
			return true

	return foot.airtime >= max_airtime


## How much of its length the standing leg is spanning, measured now rather than
## read back from the knee solve, which has not run yet this frame.
func _stance_extension(is_left: bool) -> float:
	var hip := left_hip_tracker if is_left else right_hip_tracker
	if hip == null:
		return 0.0

	var foot := _left_foot if is_left else _right_foot
	var ankle := foot.sole.origin + foot.sole.basis.y * ankle_height
	return hip.global_position.distance_to(ankle) \
			/ maxf(thigh_length + shin_length, 0.001)


## Where a foot stands when the body is still: under the balance point, half a
## stance width out to the side, on the floor. Used to put the feet somewhere on
## the very first tick, before there is a stance for them to be measured against.
func _stance_for(is_left: bool) -> Transform3D:
	var local := Vector3((-0.5 if is_left else 0.5) * stance_width, 0.0, 0.0)
	var origin := _balance_point + _upright * local
	origin.y = _ground_height()
	return Transform3D(_upright.rotated(Vector3.UP, _toe_out(is_left)), origin)


## How far the toes splay outward, signed. Feet at rest are not parallel, and a
## positive rotation about UP turns to the left, so the sign follows the side.
func _toe_out(is_left: bool) -> float:
	var angle := deg_to_rad(foot_toe_out_degrees)
	return angle if is_left else -angle


## Where a foot is heading, worked out entirely in a frame standing upright at
## the pelvis and facing the way the hips face.
##
## Doing it in that frame rather than in world space is the point. "Too far
## forward", "across the midline", "further out than a person stands" are all
## statements about a body, and they can only be bounded in a frame the body
## owns. Built in world space, a velocity pointing somewhere odd puts a foot
## somewhere odd, and there is no axis left to say so.
##
## The stride decides where inside those bounds the foot goes. The bounds decide
## that it is somewhere a person could stand.
func _reach_target(is_left: bool, step: float) -> Transform3D:
	var local := Vector3((-0.5 if is_left else 0.5) * stance_width, 0.0, 0.0)

	# Half a step, because that is what a footfall is: the foot lands half a
	# step in front of you and lifts again half a step behind, and the stride
	# from one to the next is the whole of it.
	var travel := _travel_direction()
	if not travel.is_zero_approx():
		local += (_to_local * travel) * (step * 0.5)
	local += _to_local * _prediction()
	local.y = 0.0

	# Its own side of the body, clear of where the other foot actually is, and
	# no wider than a stance. A planted foot keeps sitting where it was put
	# while the body moves out from under it, so the midline alone is not
	# enough - two individually legal placements can still end up touching.
	var other := _right_foot if is_left else _left_foot
	var beside := (_to_local * (other.sole.origin - _balance_point)).x
	var gap := min_stance_separation
	if is_left:
		local.x = clampf(local.x, -max_stance_straddle,
				minf(-gap * 0.5, maxf(beside - gap, -max_stance_straddle)))
	else:
		local.x = clampf(local.x,
				maxf(gap * 0.5, minf(beside + gap, max_stance_straddle)),
				max_stance_straddle)

	local.z = clampf(local.z, -max_stance_reach, max_stance_reach)
	local = _clamp_to_leg(local, is_left)

	var origin := _balance_point + _upright * local
	origin.y = _ground_height()
	return Transform3D(_upright.rotated(Vector3.UP, _toe_out(is_left)), origin)


## Pulls a placement in until the leg can actually get to it.
##
## A straight leg dropping to the floor covers a circle of radius
## sqrt(leg squared minus the drop squared), and that is a real distance: it
## shrinks as you stand tall and opens up as you crouch, so a crouching player
## can reach further without anyone saying so.
func _clamp_to_leg(local: Vector3, is_left: bool) -> Vector3:
	var hip := left_hip_tracker if is_left else right_hip_tracker
	if hip == null:
		return local

	var socket := _to_local * (hip.global_position - _balance_point)
	var radius := _leg_reach(hip, max_leg_stretch)

	var flat := Vector2(local.x - socket.x, local.z - socket.z)
	if flat.length() <= radius or flat.length() < 0.0001:
		return local

	flat = flat.normalized() * radius
	return Vector3(socket.x + flat.x, 0.0, socket.z + flat.y)


## How long a step is, from your pace. Both ends of the range are set rather
## than just the top, because the band a room affords is narrow and a slow step
## still has to be a step.
func _step_length() -> float:
	var normalised := clampf(_pace / maxf(reference_speed, 0.001), 0.0, 1.0)
	var step := lerpf(
			min_step_length, max_step_length, pow(normalised, stride_exponent))

	var travel := _travel_direction()
	if not travel.is_zero_approx():
		step *= _directional_scale(travel)

	return step


## How much of a step a direction of travel is worth. Forward is worth all of
## it, backward less, sideways least.
func _directional_scale(travel: Vector3) -> float:
	var along := travel.dot(-_upright.z)
	var straight := 1.0 if along >= 0.0 else backward_step_scale
	return lerpf(lateral_step_scale, straight, absf(along))


## How far anything is allowed to lead the body. Bounded on purpose.
func _prediction() -> Vector3:
	return _pelvis_velocity.limit_length(max_prediction_speed) * prediction_factor


## Which way the body is going, or nothing if it is not going anywhere.
func _travel_direction() -> Vector3:
	var speed := _pelvis_velocity.length()
	return _pelvis_velocity / speed if speed > MIN_TRAVEL_SPEED else Vector3.ZERO


## How far a foot is turned away from where it would stand.
func _yaw_error(foot: Foot, is_left: bool) -> float:
	var stance := (-_upright.z).rotated(Vector3.UP, _toe_out(is_left))
	return absf(_flatten_facing(foot.sole.basis).signed_angle_to(
			stance, Vector3.UP))


## The floor the player is standing on.
##
## No raycast, and that is deliberate: the XR origin's plane is the floor the
## headset was calibrated against, so reading it is a measurement rather than a
## question put to the world. Ground that is not flat is a correction the world
## applies, and belongs to whatever layer comes after this one.
func _ground_height() -> float:
	return global_position.y


## Both ankles.
func _solve_ankles() -> void:
	_solve_ankle(left_ankle_tracker, left_foot_tracker)
	_solve_ankle(right_ankle_tracker, right_foot_tracker)


## The ankle sits straight up from the sole, in the foot's own frame rather than
## along world up, so that a foot which later stands on a slope carries its
## ankle with it instead of leaning away from the leg.
func _solve_ankle(ankle: Node3D, foot: Node3D) -> void:
	if ankle == null or foot == null:
		return
	ankle.global_transform = foot.global_transform.translated_local(
			Vector3(0.0, ankle_height, 0.0))


## Both knees.
func _solve_knees() -> void:
	_solve_knee(left_hip_tracker, left_knee_tracker, left_ankle_tracker, true)
	_solve_knee(right_hip_tracker, right_knee_tracker, right_ankle_tracker, false)


## Two-bone IK, for the same reason as the elbow: hip and ankle are both known,
## the bones are fixed, and that leaves the knee free on a circle which nothing
## in the tracking can pick a point on.
##
## This is the easy half of that problem. A knee bends one way only, so the hint
## barely varies and needs none of the per-pose correction the elbow does, and
## there is no twist to distribute - a shin does not pronate.
func _solve_knee(hip: Node3D, knee: Node3D, ankle: Node3D, is_left: bool) -> void:
	if hip == null or knee == null or ankle == null or hip_tracker == null:
		return

	var pelvis_basis := hip_tracker.global_basis
	var origin := hip.global_position
	var to_ankle := ankle.global_position - origin
	var chord := to_ankle.length()
	if chord < 0.001:
		return
	var axis := to_ankle / chord

	var extension := chord / maxf(thigh_length + shin_length, 0.001)
	if is_left:
		left_leg_extension = extension
	else:
		right_leg_extension = extension

	# The hint is taken in the foot's frame, not the pelvis'. A knee tracks over
	# its toes, and the foot is the one thing here that is planted: a hint
	# carried by the pelvis pitches when you bend at the waist and swings the
	# knees round when you so much as turn your head, and a folded leg holds
	# its knee far enough out that a few degrees of that is a hand's width.
	#
	# Folded past a walking bend the hint gives way to the crouching one. The
	# fold is measured against the whole leg, so 0.4 is a hip most of the way
	# down to the ankles.
	var hint := knee_pole_hint.lerp(crouch_knee_pole_hint,
			crouch_knee_strength * smoothstep(0.0, 0.4, 1.0 - extension))
	if is_left:
		hint.x = -hint.x
	var pole := (ankle.global_basis * hint).slide(axis)
	if pole.is_zero_approx():
		# The leg lies along its own hint, which takes a leg raised straight out
		# in front. Up still separates the two halves of the circle, and a knee
		# raised that high can only be on the upper one.
		pole = Vector3.UP.slide(axis)
		if pole.is_zero_approx():
			return
	pole = pole.normalized()

	var knee_position: Vector3
	if chord >= thigh_length + shin_length:
		# Standing taller than the leg is long. It straightens and the shin
		# stretches rather than the foot being dragged up off the floor - the
		# same bargain the arm strikes, and for the same reason: a stretched
		# segment is honest about being out of range, where a moved foot would
		# invent a step the player never took.
		knee_position = origin + axis * thigh_length
	else:
		# Law of cosines: how far along the chord the circle sits, and its radius.
		var along := (thigh_length * thigh_length - shin_length * shin_length
				+ chord * chord) / (2.0 * chord)
		var radius := sqrt(maxf(thigh_length * thigh_length - along * along, 0.0))
		knee_position = origin + axis * along + pole * radius

	# A knee is a hinge, and a hinge has no roll of its own: it faces the way
	# it bends, which is the pole. Rolling it from the pelvis instead turns it
	# with the chest and flips it right round the moment a standing leg starts
	# to bend, where the pelvis' up axis stops being usable as a reference.
	var to_foot := ankle.global_position - knee_position
	if to_foot.is_zero_approx():
		return
	knee.global_transform = Transform3D(
			_hinge_basis(to_foot.normalized(), pole), knee_position)

	# The thigh runs hip to knee, so the socket's provisional downward aim is
	# replaced now that the knee is actually known. It faces the same pole, so
	# thigh and shin share a hinge axis and differ only by a turn about it.
	var thigh := knee_position - origin
	if not thigh.is_zero_approx():
		hip.global_basis = _hinge_basis(thigh.normalized(), pole)


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
