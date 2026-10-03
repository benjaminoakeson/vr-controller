class_name HandDrive
extends Generic6DOFJoint3D

## Drives one physical hand toward the static skeleton's hand, through this
## joint from the body.
##
## The target is the static skeleton's hand shaped by the arm's strength
## (ArmStrength, decided 2026-09-26): with nothing held it is the static hand
## exactly; holding something, it dips under the weight and lags where the
## shoulder and wrist cannot move it faster. The drive puts the hand on that
## target; weight is decided there, not by the drive's own limits. The arm
## around the hand is posed, not simulated (BodyParts), bending the way
## `elbow_pole()` says.
##
## Each tick the joint's linear motors ask the hand to move at its target's
## own velocity plus a correction toward it. The force limit grows with how far
## the hand is held off its target, up to the hand's strength: a light touch
## stays light, and a hand held further off pushes harder. It also grows while
## that gap is opening and shrinks while it closes, like a damped spring, so a
## body held up or pushed by its hands settles where the push puts it instead
## of bouncing (carrying something through free air, it grows either way). The solver applies the equal and opposite reaction to the
## body once, so pushing a wall hard enough moves the body. The anchor sits at
## the hand's centre, so the linear drive never twists the hand. The joint's
## axes are world axes: the body never rotates.
##
## The hand is a flat box, the palm, so it rests and pushes on a surface and
## holds by friction instead of rolling on a point. It is built at startup
## from `palm_size` and the static skeleton's hand scale.
##
## The hand is turned by a torque of its own, not the joint's angular motors.
## The torque asks the hand to reach its target's spin plus a correction, for
## the hand's own inertia, up to a limit that grows with how far it is turned
## off. Its hold against a load therefore grows with that inertia: the palm
## alone (about 0.0013 kg·m²) held a squeezed 5 kg box so loosely that the box
## rolled the palms 28°. So the hand turns with `wrist_inertia`, as if the
## forearm were behind it. Angular motors, solved with the contacts, held loads
## rigidly but made a palm sliding on a table stick and slip, 18 times a second
## (tried 2026-09-25; in Jolt they turn about the joint's axes as they were on
## the hand when joined, the opposite way to their target, and honour a force
## limit only if it is set after the joint exists). The body cannot rotate, so
## a torque on the hand needs no reaction on it.

## A hand's first touch on something, with how fast the hand was moving, m/s.
signal contact_started(other: Node, speed: float)

enum Side { LEFT, RIGHT }

## A drive's force on any one axis is at least this share of its limit, so a
## hand can always resist a push from the side. Holding one object with the
## other hand, every axis has the full limit: shared out by the direction of
## need, a load pulling on more than one axis made the two hands' drives
## chase each other (2026-09-27, scratch tests).
const MIN_AXIS_SHARE := 0.25
## The commanded motion's force is given this much margin on each axis.
const MOTION_MARGIN := 1.3
## How long a held object's weight takes to come onto or off the arm as it
## leaves or meets a support, in seconds; and how long it must have touched
## nothing to count as off the support (it touches it on and off as it lifts).
const BEARING_TIME := 0.1
## An elbow closer than this to the line from shoulder to wrist, in metres, is
## on a straight arm and says nothing about which way the arm bends.
const STRAIGHT_ARM := 0.02
## A contact impulse below this, in N·s per tick, is not a touch.
const TOUCH_IMPULSE := 0.0005
const STATIC_LAYER := 1

@export var side := Side.LEFT
@export var hand: RigidBody3D

@export_group("Following")
## How quickly the hand closes the gap to its target.
@export_range(0.0, 60.0, 0.5, "suffix:1/s") var follow_gain := 15.0
## The correction toward the target never asks for more than this.
@export_range(0.1, 20.0, 0.1, "suffix:m/s") var max_follow_speed := 6.0
@export_range(0.0, 60.0, 0.5, "suffix:1/s") var turn_gain := 15.0
@export_range(0.1, 60.0, 0.5, "suffix:rad/s") var max_turn_speed := 20.0
## How quickly the hand's spin reaches the spin it is asked for.
@export_range(0.005, 0.5, 0.005, "suffix:s") var turn_response := 0.02

@export_group("Strength")
## The force a hand has on its target, growing by the stiffness for every
## metre it is held off it, up to its strength.
@export_range(0.0, 200.0, 1.0, "suffix:N") var base_force := 20.0
@export_range(0.0, 20000.0, 50.0, "suffix:N/m") var effort_stiffness := 2000.0
## Extra force per m/s the gap to the target is opening at (less while it
## closes; carrying in free air, more either way). About critical for two
## hands carrying the 75 kg body.
@export_range(0.0, 5000.0, 10.0, "suffix:N·s/m") var effort_damping := 550.0
@export_range(0.0, 3000.0, 10.0, "suffix:N") var hand_strength := 600.0
@export_range(0.0, 10.0, 0.05, "suffix:N·m") var base_torque := 4.0
@export_range(0.0, 200.0, 1.0, "suffix:N·m/rad") var torque_stiffness := 120.0
@export_range(0.0, 200.0, 1.0, "suffix:N·m") var max_torque := 40.0
## Holding something, the wrist's turning grows by this share of the held
## object's inertia about the hand, and it steadies the object against the
## hand's acceleration, so a held object does not swing round the hand; for
## at most max_carry_mass of it.
@export_range(0.0, 1.0, 0.05) var carry_turn_share := 1.0
@export_range(0.0, 100.0, 0.5, "suffix:kg") var max_carry_mass := 15.0
## The hand turns with at least this inertia about each axis, in kg·m²: more
## than the palm's own, standing in for the forearm behind it. The turning
## torque's hold against a load grows with it (about 750 N·m/rad per kg·m² at
## the default gain and response), and so do the torque limits it needs to
## keep up with the controller.
@export_range(0.0, 0.2, 0.001, "suffix:kg·m²") var wrist_inertia := 0.04

@export_group("Climbing")
## Holding a hold (HandGrab), the drive moves the body instead of the hand
## (2026-09-28): it has this force each way, in newtons, about 1.6 times the
## 75 kg body's weight, so one arm holds the body and hauls it up at about
## 0.77 m/s and two at about 1.39 m/s (raised from 950 N, 0.45 and 1.23 m/s,
## after the 2026-09-30 headset session: one-handed climbing felt a little
## slow)...
@export_range(0.0, 5000.0, 10.0, "suffix:N") var climb_strength := 1200.0
## ...less upward the faster the body already rises past the hand, none at
## this speed (so it bounds how fast a pull can throw the body)...
@export_range(0.1, 10.0, 0.1, "suffix:m/s") var haul_speed := 2.0
## ...and up to this many times it resisting the body sinking.
@export_range(1.0, 3.0, 0.05) var lowering_share := 1.3
## The arms never push the body down: gravity lowers it, and they hold it
## back to at most this speed.
@export_range(0.1, 10.0, 0.1, "suffix:m/s") var lowering_speed := 2.0

@export_group("Arm strength")
## What the shoulder and wrist have for what the hand holds, N·m (human, a
## strong adult's, roughly; 10 kg held at arm's length strains the shoulder).
## They set how fast a held load can move and what the arm can lift at all.
@export_range(1.0, 1000.0, 1.0, "suffix:N·m") var shoulder_strength := 80.0
@export_range(0.5, 300.0, 0.5, "suffix:N·m") var wrist_strength := 15.0
## Share of a joint's strength holding may take; the rest is always kept for
## moving, so even an overloaded arm moves, slowly.
@export_range(0.1, 0.95, 0.05) var hold_share := 0.8
## How far each joint dips under the torque it holds, N·m per radian: 600 dips
## 10 kg held out at 0.9 of the arm's reach about 6 cm.
@export_range(10.0, 10000.0, 10.0, "suffix:N·m/rad") var shoulder_stiffness := 600.0
@export_range(10.0, 10000.0, 10.0, "suffix:N·m/rad") var wrist_stiffness := 100.0

@export_group("Palm")
## The palm's box in hand space, in metres, for a static skeleton hand_scale
## of 1: thickness through the palm, width across the knuckles, and length
## from just ahead of the wrist to the middle finger's knuckle; and how far its
## middle sits ahead of the static skeleton's palm centre, toward the fingers.
## Since 2026-10-02 it reaches the player model's knuckles (its palm is 115 mm
## from wrist to knuckle; the box was 95 mm long, centred, and ended short of
## the fingers' roots); its back end stays 2.5 mm ahead of the wrist.
@export var palm_size := Vector3(0.03, 0.08, 0.113)
@export_range(0.0, 0.05, 0.001, "suffix:m") var palm_shift := 0.009
## Skin on most surfaces: a pressed palm holds rather than skids.
@export_range(0.0, 2.0, 0.05) var palm_friction := 1.0

@export_group("Reach and recovery")
## How far past the arm's length (upper arm plus forearm) a target may be.
@export_range(0.0, 0.5, 0.01, "suffix:m") var reach_margin := 0.1
## A hand this far from its target for this long is moved to it, if the way
## there from the body is clear.
@export_range(0.1, 2.0, 0.05, "suffix:m") var max_separation := 0.5
@export_range(0.0, 2.0, 0.05, "suffix:s") var separation_time := 0.25

## The hand's wanted transform this tick: the static skeleton's hand shaped by
## the arm's strength.
var target := Transform3D.IDENTITY
## The static skeleton's hand this tick, kept within reach (or, untracked,
## held with the body): what the arm's strength shapes into `target`.
var tracked_target := Transform3D.IDENTITY
## How far the hand is from its target, in metres.
var separation := 0.0
## The drive's force limit this tick, in newtons.
var force_limit := 0.0
## All the drive may push with this tick, in newtons: force_limit plus what
## the commanded motion needs.
var drive_force := 0.0
## Whether the controller is tracked. While it is not, the target is held
## where it was relative to the body, with only the base force.
var tracked := false
## Contacts started so far.
var contacts := 0
## Times the hand was moved to its target after getting stuck.
var recoveries := 0

# What the hand is holding: its mass; the share of its inertia about the
# hand's centre (world axes) the wrist turns, and the resulting multiple of
# the hand's turning strength.
var _carried_mass := 0.0
# The part of it the arm bears (none while it rests on something), in kg,
# and the share of it borne now, which follows over BEARING_TIME: a box
# lifting off a table touches it on and off for a few ticks.
var _borne_mass := 0.0
var _borne_share := 0.0
# Whether what the hand holds rests on something (the level, a prop): it
# touched something within the last BEARING_TIME; and the held body's gravity.
var _supported := false
var _unsupported_for := 0.0
var _carried_gravity := Vector3.ZERO
var _carried_inertia := Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
var _turning := 1.0
# The carried mass the wrist steadies against the hand's acceleration, and
# where its centre is from the hand's; and the acceleration the drive asks of
# the hand this step.
var _steadied_mass := 0.0
var _carried_offset := Vector3.ZERO
var _intended_acceleration := Vector3.ZERO
var _last_hand_velocity := Vector3.ZERO
var _last_hand_spin := Vector3.ZERO
var _strength := ArmStrength.new()
# Where the wrist is in hand space (the static skeleton's).
var _wrist_on_hand := Vector3(0.0, 0.0, 0.05)
# Whether anything pushes on the hand this tick (see _pressing()).
var _touching := false
var _rig: PlayerRig
var _physical: DynamicPhysical
var _hand_tracker: Node3D
var _wrist_tracker: Node3D
var _elbow_tracker: Node3D
var _shoulder_tracker: Node3D
var _controller: XRController3D
var _arm_length := 0.7
var _palm := Vector3.ZERO
var _connected := false
var _last_target := Transform3D.IDENTITY
# The target's spin last tick, for how fast that changes.
var _last_spin := Vector3.ZERO
var _held := Transform3D.IDENTITY
# What the hand holds and where it lies in the hand's space this tick
# (holding()); null holding nothing.
var _held_body: RigidBody3D
var _held_in_hand := Transform3D.IDENTITY
var _separated_for := 0.0
var _relocations := 0
var _reach_query: PhysicsShapeQueryParameters3D

## Holding one object with the other hand (2026-09-27), HandGrab sets these
## each tick before the drive runs, from the moment the second hand grips it:
## the hand then drives to two_hand_target instead of to the static
## skeleton's hand. A hand holding the object drives to the shared target,
## worked out from both hands so the two hands' targets fit the object held
## between them (the reach limit below can still move one); the second hand,
## until it is on the object, holds nothing and rides the object where it
## will hold it. Meanwhile the arm's strength carries nothing, the first
## hand's too while it still holds the object alone: shaping each hand's
## target by its own share of the load would pull the two targets apart
## again.
var two_handed := false
var two_hand_target := Transform3D.IDENTITY
var _was_two_handed := false
var _retargeted := false

## Holding a hold (2026-09-28), HandGrab sets these each tick before the drive
## runs: the hand is welded to the hold, so the drive climbs (_hang). It
## drives toward climb_offset, how far the player's hand has moved since the
## weld (both hands' average while both hold holds).
var climbing := false
var climb_offset := Vector3.ZERO
## How far the hand is past the arm's reach from the shoulder, in metres: a
## hand welded to a hold that the body falls away from, or the player's hand
## away from.
var overreach := 0.0
var _was_climbing := false
var _last_climb_offset := Vector3.ZERO


func attach(rig: PlayerRig, physical: DynamicPhysical) -> void:
	_rig = rig
	_physical = physical
	var skeleton := rig.skeleton
	var left := side == Side.LEFT
	_hand_tracker = skeleton.left_hand_tracker if left else skeleton.right_hand_tracker
	_wrist_tracker = skeleton.left_wrist_tracker if left else skeleton.right_wrist_tracker
	_elbow_tracker = skeleton.left_elbow_tracker if left else skeleton.right_elbow_tracker
	_shoulder_tracker = skeleton.left_shoulder_tracker if left else skeleton.right_shoulder_tracker
	_controller = rig.left_controller if left else rig.right_controller
	_arm_length = skeleton.upper_arm_length + skeleton.forearm_length + reach_margin
	_build_palm(skeleton.hand_scale)
	hand.body_entered.connect(_on_hand_body_entered)


## Gives the hand its own box and skin; neither is shared with the other hand.
## The hand's centre of mass is the palm box's and its inertia at least
## `wrist_inertia`, fixed, so finger shapes added to the hand (HandFingers) give
## it collision but no weight, and moving them never changes how the hand
## moves.
func _build_palm(hand_scale: float) -> void:
	_palm = palm_size * hand_scale
	var box := BoxShape3D.new()
	box.size = _palm
	var holder := hand.get_child(0) as CollisionShape3D
	holder.shape = box
	holder.position = Vector3(0.0, 0.0, -palm_shift * hand_scale)
	var skin := PhysicsMaterial.new()
	skin.friction = palm_friction
	hand.physics_material_override = skin
	var squares := _palm * _palm
	hand.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	hand.center_of_mass = Vector3.ZERO
	var palm_inertia := Vector3(squares.y + squares.z, squares.x + squares.z, squares.x + squares.y) \
			* (hand.mass / 12.0)
	hand.inertia = palm_inertia.max(Vector3.ONE * wrist_inertia)


func _ready() -> void:
	# After the static skeleton has solved this tick's hands.
	process_physics_priority = StaticSkeleton.SOLVE_PRIORITY + 5
	hand.gravity_scale = 0.0
	hand.can_sleep = false
	hand.continuous_cd = true
	hand.contact_monitor = true
	hand.max_contacts_reported = 4
	hand.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	hand.linear_damp = 0.0
	hand.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	hand.angular_damp = 0.0
	for axis in 3:
		_flag(axis, FLAG_ENABLE_LINEAR_LIMIT, false)
		_flag(axis, FLAG_ENABLE_ANGULAR_LIMIT, false)
		_flag(axis, FLAG_ENABLE_LINEAR_MOTOR, true)
		_flag(axis, FLAG_ENABLE_MOTOR, false)
	# Until the controller is first tracked, the hand rests at the hip.
	_held = Transform3D(Basis.IDENTITY, Vector3(-0.25 if side == Side.LEFT else 0.25, 0.9, 0.0))
	var shape := (hand.get_child(0) as CollisionShape3D).shape
	_reach_query = PhysicsShapeQueryParameters3D.new()
	_reach_query.shape = shape
	_reach_query.collision_mask = STATIC_LAYER


func _physics_process(delta: float) -> void:
	_borne_share = move_toward(_borne_share, 0.0 if _supported or _carried_mass <= 0.0 else 1.0,
			delta / BEARING_TIME)
	tracked_target = _wanted()
	var switched := two_handed != _was_two_handed or climbing != _was_climbing or _retargeted
	_was_two_handed = two_handed
	_was_climbing = climbing
	_retargeted = false
	overreach = maxf((hand.global_position - _shoulder_tracker.global_position).length() - _arm_length, 0.0)
	if climbing and _connected:
		_hang(delta, switched)
		return
	var relocated := _connected and _physical.carrier.relocations != _relocations
	# The player was moved: the arm's strength starts afresh on the player's
	# hand, at rest. Moved with its lag and motion, a held box trailing 0.64 m
	# above the hand through a fall plunged onto it at 9 m/s after the respawn.
	var wanted := _shaped(tracked_target, delta, switched or relocated)
	if not _connected:
		_connect_at(wanted)
	elif relocated:
		# The player was moved: the hand goes with them rather than chasing.
		_place_hand(wanted)
		_last_target = wanted
		_last_spin = Vector3.ZERO
	elif switched:
		# The other hand took hold too, or let go, or came onto the object: the
		# target jumps between the static skeleton's hand and the shared target
		# (or from riding the object to the shared target), by the object's
		# seating, the arm's sag, or how far the player's hands are out of step
		# with the grip. The jump is no motion of the target's, so it asks for no speed,
		# and the correction below closes it, as after letting go (ArmStrength):
		# asked, or shaped by the arm's strength, the jump flung a bar held
		# 0.1 m out of step at 7 m/s, or 3 m/s (review, 2026-09-27).
		_last_target = wanted
		_last_spin = Vector3.ZERO
	_relocations = _physical.carrier.relocations
	var velocity := (wanted.origin - _last_target.origin) / delta
	var spin := _rotation_between(_last_target.basis, wanted.basis) / delta
	_last_target = wanted
	target = wanted
	var carrying := _carried_mass > 0.0
	# Carrying something, with neither the hand nor what it holds touching
	# anything: see the damping and the wrist's torque below. An empty hand
	# keeps rung 3's drive, unchanged since the player tried it: touches
	# starting and ending under these rules made a vault overshoot 5 cm and a
	# palm push a box 0.12 m instead of 0.2 m (2026-09-26).
	_touching = _pressing()
	var free_air := tracked and carrying and not _supported and not _touching
	var error := wanted.origin - hand.global_position
	separation = error.length()
	var opening := 0.0
	if separation > 1e-4:
		opening = (velocity - hand.linear_velocity).dot(error / separation)
	# The damping adds force while the gap opens and takes it away while it
	# closes, so pushes and a body carried on the hands settle where the push
	# puts them instead of bouncing. Carrying in free air, it adds force either
	# way: taking it away left a swung load unable to stop.
	var damping := effort_damping * (absf(opening) if free_air else opening)
	force_limit = clampf(base_force + effort_stiffness * separation + damping,
			base_force, hand_strength) if tracked else base_force
	var desired := velocity + (error * follow_gain).limit_length(max_follow_speed)
	var need := desired - hand.linear_velocity
	# On top, what the commanded motion itself needs: the hand and what it
	# bears accelerating as the arm's strength lets the target move, and what
	# it bears held up. Within the arm's strength by construction; a held
	# object that rests on something is not borne, so it is not lifted by this.
	var motion := Vector3.ZERO
	if carrying:
		motion = _strength.acceleration.limit_length(_strength.free_acceleration) * (hand.mass + _borne_mass) \
				- _carried_gravity * _borne_mass
		motion = motion.clamp(-Vector3.ONE * hand_strength, Vector3.ONE * hand_strength)
	_drive_linear(desired - _physical.body.linear_velocity, need, motion)
	drive_force = force_limit + motion.length() * MOTION_MARGIN
	# What this step's drive asks of the hand, within what its force allows.
	_intended_acceleration = ((desired - hand.linear_velocity) / delta).limit_length(
			force_limit / (hand.mass + _carried_mass))
	# The wrist's limit grows with how far the hand is turned off, so a hand
	# pressed on something gives like a wrist. Carrying in free air, the wrist
	# has all its torque, plus what its target's own turning needs: growing
	# with the angle alone, a quick wrist flick with a 2 kg box left the hand
	# 17° behind its target and swung it 12° past (2026-09-26). The body
	# cannot turn, so this never pushes the player.
	var turn := _rotation_between(hand.global_basis, wanted.basis)
	var spin_change := (spin - _last_spin) / delta
	_last_spin = spin
	var desired_spin := spin + (turn * turn_gain).limit_length(max_turn_speed)
	var torque_limit := _turning * max_torque
	if not free_air:
		torque_limit = _turning * minf(max_torque, base_torque + torque_stiffness * turn.length())
		spin_change = Vector3.ZERO
	_turn(desired_spin, torque_limit, spin_change, delta)
	_recover_if_stuck(wanted, delta)
	_publish()


## The static skeleton's hand, kept within reach of its shoulder; or, while
## the controller is not tracked, the last target, carried with the body.
func _wanted() -> Transform3D:
	tracked = _controller.get_has_tracking_data()
	var body := _physical.body.global_transform
	if not tracked:
		return body * _held
	var wanted := two_hand_target if two_handed else _hand_tracker.global_transform.orthonormalized()
	var shoulder := _shoulder_tracker.global_position
	var reach := wanted.origin - shoulder
	# Climbing, the hand is on the hold and the player's hand moves the body:
	# there is nothing to keep within reach.
	if reach.length() > _arm_length and not climbing:
		wanted.origin = shoulder + reach.normalized() * _arm_length
	_held = body.affine_inverse() * wanted
	return wanted


## Where the player's hand is: the static skeleton's hand, or, while the
## controller is not tracked, where it last was, carried with the body.
func player_hand() -> Transform3D:
	if not _controller.get_has_tracking_data():
		return _physical.body.global_transform * _held
	return static_hand()


## Climbing: the hand is welded to its hold, so the drive moves the body the
## opposite way to how the player's hand moves, as fast as it moves and
## closing what is left of climb_offset at follow_gain, as the drive moves a
## free hand: pulling down lifts the body. The hand holds on with
## climb_strength each way, but upward less the faster the body already rises
## (none at haul_speed) and up to lowering_share more against sinking: one arm
## holds the body with no sag (a velocity motor held within its force limit
## meets its target) and hauls it at about 0.45 m/s; two haul it at about
## 1.2 m/s. Raising the hand lowers the body, but only as gravity takes it,
## and no faster than lowering_speed: pushed down with the whole strength as
## well, a hand raised fast flung the body down at 6 m/s, and one arm, which
## has only its strength less the body's weight to stop it, let it overshoot
## the hand by 1.5 m (headset, 2026-09-28). No reach limit, no turning (the
## weld holds the hand) and no recovery: a hand that cannot hold on is let go
## (HandGrab).
func _hang(delta: float, switched: bool) -> void:
	var rate := Vector3.ZERO if switched else (climb_offset - _last_climb_offset) / delta
	_last_climb_offset = climb_offset
	var desired := rate + (climb_offset * follow_gain).limit_length(max_follow_speed)
	var body_velocity := _physical.body.linear_velocity
	# With the hand held still, the motor leaves the body moving at its
	# velocity less `desired`: never below what gravity alone gives it this
	# tick, nor below lowering_speed down.
	var sinking := maxf(body_velocity.y + _physical.body.get_gravity().y * delta, -lowering_speed)
	desired.y = minf(desired.y, body_velocity.y - sinking)
	var rising := body_velocity.y - hand.linear_velocity.y
	var upward := maxf(climb_strength * clampf(1.0 - rising / haul_speed, 0.0, lowering_share), base_force)
	var limits := Vector3(climb_strength, upward, climb_strength)
	for axis in 3:
		_param(axis, PARAM_LINEAR_MOTOR_TARGET_VELOCITY, desired[axis] - body_velocity[axis])
		_param(axis, PARAM_LINEAR_MOTOR_FORCE_LIMIT, limits[axis])
	target = player_hand()
	separation = hand.global_position.distance_to(target.origin)
	force_limit = upward
	drive_force = limits.length()
	_last_target = tracked_target
	_relocations = _physical.carrier.relocations
	_separated_for = 0.0
	_publish()


## The player snap turned by `turning` (DynamicPhysical), before this tick's
## drive: the hand turns with them, placed as it was relative to them and
## moving as it was, and so does all the drive remembers in the world (its
## last targets, the arm's strength), so nothing reads the turn as the
## player's hand moving. A hand on a hold stays on it (HandGrab: the climb
## then moves the body round it).
func turn(turning: Transform3D) -> void:
	if not _connected:
		return
	_last_target = turning * _last_target
	_last_spin = turning.basis * _last_spin
	_last_hand_velocity = turning.basis * _last_hand_velocity
	_last_hand_spin = turning.basis * _last_hand_spin
	_intended_acceleration = turning.basis * _intended_acceleration
	_strength.turn(turning)
	var body := _physical.body.global_transform
	_held = body.affine_inverse() * turning * body * _held
	if climbing:
		return
	hand.global_transform = turning * hand.global_transform
	hand.linear_velocity = turning.basis * hand.linear_velocity
	hand.angular_velocity = turning.basis * hand.angular_velocity


## HandGrab calls this when it changes what the hand is driven to while
## two_handed stays on (a second hand, having ridden the object onto it, now
## drives to the shared target): as when two_handed changes, the jump this
## tick is asked for no speed.
func retarget() -> void:
	_retargeted = true


## The share of what the hand holds that its arm bears now, 0 to 1: none
## while it rests on something (carry()).
func borne_share() -> float:
	return _borne_share


## HandGrab tells the drive, each tick before it runs, what the hand holds
## (null for nothing) and where that lies in the hand's space now, so moving
## the hand with the player (a recentre, a respawn) moves it too. Both hands
## of a two-handed hold tell it before either moves.
func holding(body: RigidBody3D, in_hand: Transform3D) -> void:
	_held_body = body
	_held_in_hand = in_hand


## The static skeleton's hand now: where the player's own hand is.
func static_hand() -> Transform3D:
	return _hand_tracker.global_transform.orthonormalized()


## The static skeleton's hand `tracked`, turned into where the arm's strength
## lets the hand be this tick; `restart` puts the arm's strength on it at rest.
func _shaped(tracked: Transform3D, delta: float, restart := false) -> Transform3D:
	_wrist_on_hand = _hand_tracker.global_transform.affine_inverse() * _wrist_tracker.global_position
	_configure_strength()
	var shoulder := _shoulder_tracker.global_position
	var at_wrist := tracked * _wrist_on_hand
	if not _connected or restart:
		_strength.reset(at_wrist, tracked.basis)
	_strength.update(shoulder, at_wrist, tracked.basis, _physical.body.linear_velocity, delta)
	if not _strength.shaping():
		# Nothing held: the static skeleton's hand as it is.
		return tracked
	var turned := _strength.hand_basis
	return Transform3D(turned, _strength.wrist - turned * _wrist_on_hand)


func _configure_strength() -> void:
	var s := _strength
	s.strength = Vector2(shoulder_strength, wrist_strength)
	s.hold_share = hold_share
	s.stiffness = Vector2(shoulder_stiffness, wrist_stiffness)
	s.reach = _arm_length


## A point the arm bends toward: the static skeleton's elbow, while that lies
## clear of the line from shoulder to wrist; otherwise (a straight arm, whose
## elbow lies on the line and says nothing about which way to bend) the
## shoulder plus the direction the static skeleton bends it. The two agree
## where both are defined.
func elbow_pole() -> Vector3:
	var shoulder := _shoulder_tracker.global_position
	var elbow := _elbow_tracker.global_position
	var line := _wrist_tracker.global_position - shoulder
	if line.length_squared() > 1e-8 and (elbow - shoulder).slide(line.normalized()).length() > STRAIGHT_ARM:
		return elbow
	var skeleton := _rig.skeleton
	return shoulder + (skeleton.left_elbow_pole if side == Side.LEFT else skeleton.right_elbow_pole)


## Tells the hand what it is holding, each tick while it holds it: the held
## body's mass, its inertia about its own centre of mass (world axes), and
## where that centre is from the hand's; whether it is pressed on anything
## this tick (a real contact), and its gravity. Zero mass when it holds
## nothing. Touching something within the last BEARING_TIME, it rests: its
## weight comes off the arm over BEARING_TIME; clear of everything, it comes
## back on over the same time.
func carry(mass: float, inertia: Basis, offset: Vector3, touching := false,
		gravity := Vector3.ZERO) -> void:
	if mass <= 0.0:
		_borne_share = 0.0
		_supported = false
		_unsupported_for = 0.0
	elif touching:
		_supported = true
		_unsupported_for = 0.0
	else:
		_unsupported_for += get_physics_process_delta_time()
		_supported = _unsupported_for < BEARING_TIME
	_carried_gravity = gravity
	_borne_mass = mass * _borne_share
	_carry_strength(mass, inertia, offset)
	var share := carry_turn_share * minf(minf(mass, max_carry_mass) / maxf(mass, 1e-6), 1.0) if mass > 0.0 else 0.0
	_carried_mass = mass
	_steadied_mass = share * mass
	_carried_offset = offset
	var about_hand := ArmStrength.add(inertia, ArmStrength.point_inertia(offset, mass))
	_carried_inertia = Basis(about_hand.x * share, about_hand.y * share, about_hand.z * share)
	var own := PhysicsServer3D.body_get_direct_state(hand.get_rid()).inverse_inertia_tensor.inverse()
	var own_size := own.x.x + own.y.y + own.z.z
	_turning = 1.0 + (_carried_inertia.x.x + _carried_inertia.y.y + _carried_inertia.z.z) / maxf(own_size, 1e-9)


## Tells the arm's strength what the hand holds: its centre from the wrist and
## its inertia about that centre, both in hand axes, and the share of its
## weight borne. Nothing while two-handed (HandGrab: from the second grip).
func _carry_strength(mass: float, inertia: Basis, offset: Vector3) -> void:
	if mass <= 0.0 or two_handed:
		_strength.carry(0.0, Vector3.ZERO, Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO))
		return
	var frame := hand.global_basis.orthonormalized()
	_strength.carry(mass, frame.inverse() * offset - _wrist_on_hand, frame.transposed() * inertia * frame,
			_borne_share)


## Puts the hand on its first target and joins it to the body there.
func _connect_at(wanted: Transform3D) -> void:
	_place_hand(wanted)
	_last_target = wanted
	global_transform = Transform3D(Basis.IDENTITY, wanted.origin)
	node_a = get_path_to(_physical.body)
	node_b = get_path_to(hand)
	_connected = true


func _place_hand(at: Transform3D) -> void:
	hand.global_transform = at
	hand.linear_velocity = Vector3.ZERO
	hand.angular_velocity = Vector3.ZERO
	if is_instance_valid(_held_body):
		# What it holds goes with it, as it lies in the hand: moved alone, the
		# hand dragged a held longsword 20 m through one step after a respawn
		# and flung it at 95 m/s (headset, 2026-10-02).
		_held_body.global_transform = at * _held_in_hand
		_held_body.linear_velocity = Vector3.ZERO
		_held_body.angular_velocity = Vector3.ZERO


## Sets the linear motors to `relative` (the hand's wanted velocity relative
## to the body), sharing the force limit along the velocity change `need`, on
## top of what `motion` (the commanded motion's own force) needs on each axis.
func _drive_linear(relative: Vector3, need: Vector3, motion: Vector3) -> void:
	var direction := need.normalized() if need.length_squared() > 1e-10 else Vector3.ZERO
	for axis in 3:
		_param(axis, PARAM_LINEAR_MOTOR_TARGET_VELOCITY, relative[axis])
		_param(axis, PARAM_LINEAR_MOTOR_FORCE_LIMIT,
				absf(motion[axis]) * MOTION_MARGIN
				+ force_limit * (1.0 if two_handed else maxf(absf(direction[axis]), MIN_AXIS_SHARE)))


## Turns the hand toward `spin` with a torque, at most `torque_limit` plus
## what turning it (and what it holds) at `spin_change` (rad/s², the target's
## own) takes, reaching it over turn_response.
func _turn(spin: Vector3, torque_limit: float, spin_change: Vector3, delta: float) -> void:
	var state := PhysicsServer3D.body_get_direct_state(hand.get_rid())
	var acceleration := (spin - hand.angular_velocity) / maxf(turn_response, delta)
	var own := state.inverse_inertia_tensor.inverse()
	var inertia := Basis(own.x + _carried_inertia.x, own.y + _carried_inertia.y, own.z + _carried_inertia.z)
	var torque := inertia * acceleration
	# A held object's centre lies off the hand's, so accelerating the hand
	# would swing it round the hand; the wrist pushes back as it accelerates.
	# The acceleration is taken halfway between what the drive asks this step
	# and what the last step measured: the measured one alone, a step late,
	# let a 10 kg box whipped fast tilt the hand 22°; the asked one alone
	# overshot and tilted it 13° the other way on a plain fast swing.
	# Measured where the hand and what it holds share their centre of mass,
	# not at the hand's centre: the drive does not pin the hand's centre, so
	# the pair turns about that shared centre, and the hand's centre swings
	# round it. Steadying on that swing, a step late, pushed it on: 10 kg held
	# by a corner buzzed at 36 Hz, 16-20 rad/s, for seconds (headset and
	# harness, 2026-09-27).
	var centre := _carried_offset * (_carried_mass / (_carried_mass + hand.mass))
	var measured := (hand.linear_velocity - _last_hand_velocity
			+ (hand.angular_velocity - _last_hand_spin).cross(centre)) / delta
	_last_hand_velocity = hand.linear_velocity
	_last_hand_spin = hand.angular_velocity
	var acceleration_now := (_intended_acceleration + measured) * 0.5
	var steadying := _carried_offset.cross(acceleration_now * _steadied_mass)
	# The steadying torque comes on top of the turning limit: it is what the
	# held object's inertia takes, not turning the hand toward its target.
	var limit := torque_limit + steadying.length() + (inertia * spin_change).length() * MOTION_MARGIN
	hand.apply_torque((torque + steadying).limit_length(limit))


## A hand held too far from its target for too long is moved to it, but only
## if a hand could get there from inside the body without passing through the
## level; otherwise it keeps pushing.
func _recover_if_stuck(wanted: Transform3D, delta: float) -> void:
	if not tracked or separation <= max_separation:
		_separated_for = 0.0
		return
	_separated_for += delta
	if _separated_for < separation_time:
		return
	var body := _physical.body
	var from := body.global_position + Vector3.UP * maxf(body.height - body.radius, body.radius)
	_reach_query.transform = Transform3D(wanted.basis, from)
	_reach_query.motion = wanted.origin - from
	_reach_query.exclude = [body.get_rid(), hand.get_rid()]
	var fractions := body.get_world_3d().direct_space_state.cast_motion(_reach_query)
	if fractions[0] >= 1.0:
		_place_hand(wanted)
		recoveries += 1
		_separated_for = 0.0


func _publish() -> void:
	var state := _physical.snapshot
	state.hands[side] = hand.global_transform
	state.hand_targets[side] = target
	state.hand_tracked[side] = tracked_target
	state.arm_sag[side] = _strength.sag
	state.arm_holding[side] = _strength.holding
	state.hand_separation[side] = separation
	state.hand_force[side] = drive_force
	state.hand_contacts[side] = contacts
	state.hand_touching[side] = _touching
	state.hand_strength = hand_strength
	state.palm_size = _palm
	state.palm_shift = (hand.get_child(0) as CollisionShape3D).position.z * -1.0


## Whether anything is pushing on the hand. The physics engine also reports
## contacts it only expects (within a couple of centimetres) with no push yet;
## those are not a touch. The pushes of all its contacts count together: a
## hand resting on the palm and its fingers at once shares one push among
## them (the player model's wider fingers, 2026-10-02, split a press on a
## table's edge until no single contact counted).
func _pressing() -> bool:
	var state := PhysicsServer3D.body_get_direct_state(hand.get_rid())
	var push := 0.0
	for i in state.get_contact_count():
		push += state.get_contact_impulse(i).length()
	return push > TOUCH_IMPULSE


## The rotation that turns `from` into `to`, as an axis scaled by its angle.
static func _rotation_between(from: Basis, to: Basis) -> Vector3:
	var turn := Quaternion(to.orthonormalized()) * Quaternion(from.orthonormalized()).inverse()
	if turn.w < 0.0:
		turn = -turn
	var angle := turn.get_angle()
	return turn.get_axis() * angle if angle > 1e-5 else Vector3.ZERO


func _on_hand_body_entered(other: Node) -> void:
	contacts += 1
	contact_started.emit(other, hand.linear_velocity.length())


func _flag(axis: int, flag: Flag, value: bool) -> void:
	match axis:
		0: set_flag_x(flag, value)
		1: set_flag_y(flag, value)
		_: set_flag_z(flag, value)


func _param(axis: int, param: Param, value: float) -> void:
	match axis:
		0: set_param_x(param, value)
		1: set_param_y(param, value)
		_: set_param_z(param, value)
