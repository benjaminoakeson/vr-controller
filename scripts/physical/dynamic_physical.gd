class_name DynamicPhysical
extends PlayerPhysical

## The dynamic physical layer: one upright RigidBody3D capsule moved by a
## bounded walking motor, with the rig carried by what the body itself does.
##
## Each physics tick, before the static skeleton solves:
## 1. the rig carrier moves the rig by the body's last solve, leaving out the
##    part that was only catching up with the head;
## 2. the ground is sensed once;
## 3. the head's lead and obstruction are measured, and the view is pushed
##    back if a clear head has got too far ahead of a stopped body;
## 4. the body is told what the hands carry (the legs move it and pay for
##    it), and locomotion plans the tick: recovery first, then stick, run, following
##    the head, step lifts, jumps, snap turns, the crouch height and the legs'
##    tuck; a snap turn turns the rig, and with it everything that keeps a
##    place or direction in the world on the player's behalf;
## 5. the capsule is resized (its top to the head, its bottom drawn up or let
##    down) and driven by one bounded force, plus a jump impulse when one was
##    asked for;
## 6. the snapshot and the static skeleton's inputs are published.
## The physics solve that follows moves the body; the next tick carries it.
## The hands are driven by their own HandDrive joints later in the same tick,
## after the static skeleton has solved where they should be, and their
## fingers by HandFingers just after them.
## See documents/player_controller/1 - architecture.md, section 6.

@export var carrier: RigCarrier
@export var body: CapsuleBody
@export var ground: GroundSense
@export var locomotion: Locomotion
@export var left_drive: HandDrive
@export var right_drive: HandDrive
@export var left_fingers: HandFingers
@export var right_fingers: HandFingers
@export var body_parts: BodyParts
@export var left_grab: HandGrab
@export var right_grab: HandGrab
@export var left_strikes: HandStrikes
@export var right_strikes: HandStrikes

## A contact impulse below this, in N·s per step, is not a push: the physics
## engine also reports contacts it merely expects.
const PUSH_IMPULSE := 0.0005

var _rig: PlayerRig


func attach_rig(rig: PlayerRig) -> void:
	if carrier == null or body == null or ground == null or locomotion == null:
		push_error("DynamicPhysical: carrier, body, ground and locomotion must all be assigned.")
		return
	_rig = rig
	carrier.attach(rig, body)
	ground.attach(body)
	locomotion.attach(rig, self)
	for drive: HandDrive in [left_drive, right_drive]:
		if drive != null:
			drive.attach(rig, self)
			drive.contact_started.connect(
					func(_other: Node, speed: float) -> void: hand_contact.emit(drive.side, speed))
	for fingers: HandFingers in [left_fingers, right_fingers]:
		if fingers != null:
			fingers.attach(rig, self)
	if body_parts != null:
		body_parts.attach(rig, self)
	for grab: HandGrab in [left_grab, right_grab]:
		if grab != null:
			grab.attach(rig, self)
	for strikes: HandStrikes in [left_strikes, right_strikes]:
		if strikes != null:
			strikes.attach(rig, self)
			strikes.struck.connect(func(strike: Strike, source: int) -> void:
					hand_strike.emit(strikes.grab.drive.side, strike, source))


func _ready() -> void:
	if _rig == null:
		push_error("DynamicPhysical: attach_rig() was not called before ready.")
		set_physics_process(false)
		return
	# Before the skeleton solves, so it sees the rig where this tick put it.
	process_physics_priority = StaticSkeleton.SOLVE_PRIORITY - 10
	var head: Vector3 = _rig.head_centre()
	body.place_at(Vector3(head.x, _rig.global_position.y, head.z))
	carrier.reset()
	_rig.skeleton.ground_probe = ground.probe_ground


func _physics_process(delta: float) -> void:
	carrier.carry()
	ground.sense(delta)
	carrier.measure_head()
	carrier.push_back()
	body.carried_mass = _carried_mass()
	var frame := locomotion.plan(delta)
	if frame.turn != 0.0:
		# A hand on a hold anchors the body: its motion stays as it hangs.
		var turning := carrier.turn(frame.turn, not climbing())
		# This tick's plan was made facing the old way: its directions turn too.
		frame.wish = turning.basis * frame.wish
		frame.follow = turning.basis * frame.follow
		_turn(turning)
	if frame.target_height >= 0.0:
		body.fit_height(frame.target_height)
	if frame.target_tuck >= 0.0:
		body.fit_tuck(frame.target_tuck)
	body.drive(frame.desired_velocity(), frame.lift_speed, ground, delta)
	if frame.jump_speed > 0.0:
		body.jump(frame.jump_speed, ground.support_velocity)
		ground.note_jump()
	carrier.expect_follow(Vector3.ZERO if frame.hold else frame.follow, delta, ground)
	_publish(frame, delta)


func _publish(frame: LocomotionFrame, delta: float) -> void:
	snapshot.tick += 1
	snapshot.delta = delta
	snapshot.body_position = body.global_position
	snapshot.body_velocity = body.linear_velocity
	snapshot.body_height = body.height
	snapshot.body_radius = body.radius
	snapshot.body_tuck = body.tuck
	snapshot.supported = ground.supported
	snapshot.lifting = frame.lift_speed > 0.0 and not frame.standing_up
	snapshot.stepping_down = ground.stepping_down
	snapshot.ground_normal = ground.normal
	snapshot.support_velocity = ground.support_velocity
	snapshot.commanded_travel = frame.commanded_travel()
	snapshot.run_factor = frame.run_factor
	snapshot.head_lead = carrier.head_lead
	snapshot.head_obstruction = carrier.head_obstruction
	snapshot.blackout = frame.blackout
	snapshot.rig_carry = carrier.carried
	snapshot.rig_correction = carrier.pushed_back
	snapshot.motor_force = body.motor_force
	snapshot.carried_mass = body.carried_mass
	snapshot.relocations = carrier.relocations
	snapshot.turns = carrier.turns
	snapshot.climbing = climbing()
	snapshot.prop_contact = _prop_contacts()
	# On its feet while the legs lift or lower it a step, too.
	_rig.skeleton.body_grounded = ground.supported or snapshot.lifting or ground.stepping_down
	_rig.skeleton.commanded_travel = snapshot.commanded_travel
	_rig.skeleton.leg_tuck = body.tuck


## A snap turn, `turning` about the vertical through the head's centre, before
## anything else works out this tick: the body's motion (unless a hand holds a
## hold), the static skeleton's feet and facing, the hands and what they hold
## turn with the view, places and motion alike, so the whole player turns
## rigidly: a held sword stays where it was in the player's hands and the
## avatar does not twist round after it. A hand on a hold stays on it, and
## the climb then moves the body round the hold, as when the player turns.
func _turn(turning: Transform3D) -> void:
	_rig.skeleton.turn(turning)
	for drive: HandDrive in [left_drive, right_drive]:
		if drive != null:
			drive.turn(turning)
	for grab: HandGrab in [left_grab, right_grab]:
		if grab != null:
			grab.turn(turning)


## What the hands carry along with the body, in kg: the weight their arms
## bore of what they held, as of the last tick.
func _carried_mass() -> float:
	var carried := 0.0
	for grab: HandGrab in [left_grab, right_grab]:
		if grab != null:
			carried += grab.carried_mass()
	return maxf(carried, 0.0)


## Whether a hand holds a Climbable hold: the body hangs on the hands, and
## moves as they climb.
func climbing() -> bool:
	return (left_grab != null and left_grab.climbing()) or (right_grab != null and right_grab.climbing())


## Lets go of every hold, before the player is moved (a recentre, a respawn):
## a hand welded to the world cannot go with them.
func release_holds() -> void:
	for grab: HandGrab in [left_grab, right_grab]:
		if grab != null:
			grab.release_hold()


## Which of the player's bodies pushed on a loose prop (a rigid body that is
## not frozen) in the last step, as bits: 1 the body, 2 the left hand, 4 the
## right hand. Also publishes where the heaviest prop pushed is, and its mass.
func _prop_contacts() -> int:
	var pushers: Array[RigidBody3D] = [body, left_drive.hand if left_drive != null else null,
			right_drive.hand if right_drive != null else null]
	var bits := 0
	var heaviest: RigidBody3D = null
	for i in pushers.size():
		if pushers[i] == null:
			continue
		var prop := _pushed_prop(pushers[i])
		if prop != null:
			bits |= 1 << i
			if heaviest == null or prop.mass > heaviest.mass:
				heaviest = prop
	snapshot.prop_position = heaviest.global_position if heaviest != null else Vector3.ZERO
	snapshot.prop_mass = heaviest.mass if heaviest != null else 0.0
	return bits


## The heaviest loose prop `pusher` pushed on in the last step, or null.
static func _pushed_prop(pusher: RigidBody3D) -> RigidBody3D:
	var state := PhysicsServer3D.body_get_direct_state(pusher.get_rid())
	var heaviest: RigidBody3D = null
	for i in state.get_contact_count():
		var other := state.get_contact_collider_object(i) as RigidBody3D
		if other != null and not other.freeze and state.get_contact_impulse(i).length() > PUSH_IMPULSE \
				and (heaviest == null or other.mass > heaviest.mass):
			heaviest = other
	return heaviest
