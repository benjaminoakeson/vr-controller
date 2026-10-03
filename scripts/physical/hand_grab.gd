class_name HandGrab
extends Node

## One hand's grab: finds what the hand could grab, and when the grip closes
## seats it in the hand and holds it through a joint (decided 2026-09-25;
## section 6.7).
##
## - The hand's grab point is fixed, just inside the palm's face and toward
##   the knuckles from its centre.
## - While the hand holds nothing, the grab area, a ball in front of the palm,
##   is searched every tick for Grabbable bodies. The one whose surface comes
##   closest to the hand's grab point is the candidate, and that closest
##   surface point is its grab point, following the hand until the grab.
## - When the grip closes past grab_grip, the candidate is grabbed and seated
##   (2026-10-02, at the player's request: pulled in by a joint's motors, it
##   trailed a hand moving fast, caught on the table and props, and was welded
##   up to 5 mm off): over seat_time its grab point comes onto the hand's,
##   keeping its rotation relative to the hand (a handle turns into its seat on
##   the way). The move is in the hand's own space, eased out, the same however
##   far it comes and however the hand moves, whatever it weighs; meanwhile the
##   object is frozen and meets nothing, and its weight is not on the hand.
##   Then it is welded to the hand, so a held object moves with the hand and
##   cannot swing out past it however fast the hand moves (held by motors, a
##   10 kg box swung fast lagged 0.33 m, and in the headset dropped). Its
##   weight and inertia load the hand, whose drive carries them. Seated inside
##   something (a pommel through the table), it meets nothing until it is
##   clear, rather than being pushed out through the weld.
## - While held, the object is on the Held layer, which the player's body and
##   legs do not meet, so it cannot push the player about; nor do the hands
##   holding it (Grabbable: a collision exception each, from the grab until
##   the hand is clear of it after letting go), so the hold never fights the
##   palm's or fingers' contacts. The other hand, and what it holds, meet it
##   (2026-10-03, at the player's request): it blocks and pushes the object,
##   which pushes it back, each as its arm's strength allows. The fingers still
##   curl onto it; their checks include Held, and Seating.
## - It is let go when the grip opens past release_grip, when the hand is held
##   further than max_separation from its target for slip_time (what it holds
##   is stuck), or when the controller has been untracked for
##   tracking_loss_time; a second hand coming onto it, when that hand stays
##   further than max_slip from its grab point for slip_time. It gets its own
##   layers back once clear of the hand.
## - Two hands can hold one object (2026-09-27). The first to grab leads. The
##   other finds the held object like any other and joins the hold from the
##   moment it grips, as if it held the object already (decided with the
##   player): nothing pulls the object and that hand together (pulled in, a
##   second hand fought the first's grip and twitched, in the headset). Both
##   hands drive to one shared target, decided with the player: the middle of
##   the player's two hands, pointing along the line between them, rolled by
##   the mean of their two wrists' roll, each hand where it holds the object
##   in it, the second at its grab point. The object and the first hand move
##   into that pose as the second hand comes onto the object, riding it where
##   it is; once there, the second holds a point of it and drives to the
##   shared target too, and the lead holds a point and the object's roll about
##   the line between the two, so the object points along the line between
##   the hands. With the
##   player's hands moving together the physical hands follow them exactly;
##   moved apart, they go to the mean, and the two hands do not pull against
##   each other through the object (unless one hand's target lies beyond its
##   arm's reach, which moves that target alone). Each hand's drive gets
##   headroom for its share of the weight by the lever rule. When either lets
##   go, the other holds it alone, rigidly, as it is. Hands whose centres, as
##   they hold it, are closer than min_aim_span leave the lead holding it
##   rigidly and the other holding a
##   point; the shared target then turns by the mean of the two wrists'
##   turns. A second hand that grips while the first is still seating the
##   object waits for it to be held. Grabbable keeps who holds the object
##   and its layers.
## - A Grabbable's handles are held one way (2026-09-27, at the player's request):
##   along the fist's grip, leaned by the Grabbable's handle_lean, toward the
##   thumb or the little finger,
##   with the palm on one of the handle's sides, whichever of those four seats
##   is nearest how the hand meets it; where the hand meets it along the
##   handle, but with the palm wholly on it. A hand beyond either end of a
##   handle cannot hold it there. The fist holds the handle's centre line
##   (hand_point is then the fist's, object_point the handle's). Seating it
##   turns the handle into its seat; a second hand joining rides the object
##   onto its seat in that hand, as it rides onto any grab point, and is on it
##   once within hold_distance and hold_angle of it and settled there (or
##   passing through, once riding longer than slip_time).
## - A Climbable hold (2026-09-28, climbing) is found like an object, but it
##   cannot move and there is nothing to seat: the hand snaps onto it (its
##   grab point onto the hold's) the tick the grip closes, and is welded and
##   frozen there. Pulled in at first, a hand the player kept moving was drawn
##   off the hold by its own drive faster than the grip brought it in, never
##   locked, and the player fell when the other hand let go (headset,
##   2026-09-28: 4 of 21 grabs). Frozen, the hand is part of the world, and the
##   arm's motor pushes the body against the world itself (through a free 1 kg
##   hand welded there, the solver passed so little of it to the 75 kg body
##   that it hung 3 cm low from two hands and 7 cm from one). From then the
##   hand's drive climbs: it moves the body the opposite way to how the
##   player's hand has moved since the weld (HandDrive: climbing), with both
##   hands' moves averaged while both hold holds. None of the object's handling
##   applies (the Held layer, carrying, two-handed holds); each hand holds its
##   own hold. It lets go when the grip
##   opens, when the controller has been untracked for tracking_loss_time
##   (the body stays held meanwhile), or when the arm is held past its reach
##   by hold_tear_reach for slip_time (it cannot hold on), never by moving the
##   hand.

## SEATING: the object is coming into the hand (_seat_step); or, this hand
## joining the other's hold, the hand is coming onto the object. The values
## are recorded and drawn as numbers.
enum State { IDLE, SEATING, HOLDING }
## How a holding hand holds: rigidly; a point of the object, free to turn on
## it; or a point and the roll about the line to the other hand's grab point.
enum Hold { WELD, POINT, AIM }

const HELD_LAYER := Grabbable.HELD_LAYER
const HELD_MASK := Grabbable.HELD_MASK

@export var drive: HandDrive

@export_group("Grab point and area")
## How far inside the palm's face the hand's grab point sits, in metres...
@export_range(0.0, 0.02, 0.001, "suffix:m") var grab_depth := 0.005
## ...and how far from the palm's centre toward the knuckles, in metres (at a
## hand_scale of 1): grabbing at the palm's centre felt off to the player
## (2026-09-27).
@export_range(0.0, 0.05, 0.001, "suffix:m") var grab_forward := 0.035
## The grab area: a ball of this radius, in metres...
@export_range(0.01, 0.3, 0.005, "suffix:m") var grab_radius := 0.08
## ...centred this far out from the palm's face, in metres.
@export_range(0.0, 0.2, 0.005, "suffix:m") var grab_reach := 0.03

@export_group("Grip")
## The grip squeezes past this to grab, and opens past release_grip to let go.
@export_range(0.0, 1.0, 0.05) var grab_grip := 0.7
@export_range(0.0, 1.0, 0.05) var release_grip := 0.3
## How long a grabbed object takes to come from where it lies into its seat
## in the hand, in seconds, however far it comes (0: there the tick the grip
## closes). 0.08 s is 6 ticks at 72 Hz.
@export_range(0.0, 0.3, 0.01, "suffix:s") var seat_time := 0.08

@export_group("Letting go")
## A second hand coming onto the object, still further than this from its
## grab point for slip_time, lets go.
@export_range(0.0, 1.0, 0.01, "suffix:m") var max_slip := 0.12
@export_range(0.0, 2.0, 0.05, "suffix:s") var slip_time := 0.25
## Holding, a hand kept further than this from its target for slip_time lets
## go: what it holds is stuck. Less than the hand drive's own recovery, which
## would move the hand, and the held object with it, to the target.
@export_range(0.0, 1.0, 0.01, "suffix:m") var max_separation := 0.4
## An untracked controller lets go after this long.
@export_range(0.0, 5.0, 0.1, "suffix:s") var tracking_loss_time := 1.0
## Holding a hold, an arm held this far past its reach for slip_time lets go:
## the body has fallen away from the hand, or the player's hand from the hold.
@export_range(0.0, 1.0, 0.01, "suffix:m") var hold_tear_reach := 0.25
## Let go by the last hand holding it, a prop leaves with the velocity and
## spin of a fit through its last this-many seconds (ThrowHistory): 5 ticks
## at 72 Hz. Longer smooths more but lags a throw still turning (0.1 s: 9.6°
## behind the player's hand on the harness's overhand throw, 0.06 s: 2.1°).
@export_range(0.03, 0.3, 0.01, "suffix:s") var throw_window := 0.06
## A let-go object gets its own layers back once this far clear of every part
## of the hand, fingers included, in metres (a sword let go from a fist
## turned 30° got them back just clear of the palm, fell onto the still-curled
## fingers and was flung aside spinning at 7.5 rad/s)...
@export_range(0.0, 0.05, 0.001, "suffix:m") var restore_clearance := 0.01
## ...or after this long at most.
@export_range(0.0, 3.0, 0.05, "suffix:s") var restore_limit := 1.0

@export_group("Two hands")
## Two hands' centres, where each holds the object, closer than this are too
## close to aim between (the line they aim along runs between the centres,
## about 1 cm behind each palm's grab point): the lead holds the object
## rigidly and the other hand holds a point.
@export_range(0.0, 0.3, 0.005, "suffix:m") var min_aim_span := 0.05
## A second hand coming onto the object is on it within this of its grab
## point...
@export_range(0.0, 0.05, 0.001, "suffix:m") var hold_distance := 0.005
## ...and by a handle, turned to within this of its seat and spinning no
## faster than settled_spin against the object (or, riding onto it longer
## than slip_time, whatever its spin).
@export_range(0.0, 10.0, 0.1, "radians_as_degrees") var hold_angle := deg_to_rad(2.0)
@export_range(0.0, 5.0, 0.05, "suffix:rad/s") var settled_spin := 0.7

var state := State.IDLE
## The candidate while idle, or the held object or hold.
var target: PhysicsBody3D
## The hand's grab point, and the object's (the candidate's closest surface
## point, or where the held object's grab point is now), in world space.
## Holding by a handle, the fist's centre line and the handle's; a handle
## candidate's point is where the fist would hold it.
var hand_point := Vector3.ZERO
var object_point := Vector3.ZERO
## How far apart the two grab points are, in metres.
var gap := 0.0
## Grabs so far.
var grabs := 0
## How this hand holds its object while HOLDING.
var hold_kind := Hold.WELD
## Where this hand holds its object, in the object's own space.
var anchor := Vector3.ZERO
## How far the held object has turned in the hand since the grip joint was
## last made, in degrees (a weld should keep it near 0; two hands' joints let
## it turn by design). Recorded, to see the grip turn under fast twists.
var held_turn := 0.0
## The share of the object's weight this hand carries: 1 alone; between two
## hands by the lever rule, above 1 for the hand nearer the centre of mass when
## it lies beyond both hands, and below 0 for the other (it pushes down).
var share := 1.0

var _physical: DynamicPhysical
var _controller: XRController3D
var _hand: RigidBody3D
var _side := 0
# The hand's grab point in the hand's own space, and which way its palm faces.
var _palm_point := Vector3.ZERO
var _palm_side := Vector3.ZERO
var _palm_half_width := 0.0
# Where the hand holds what it grabs, in its own space: the palm's grab point,
# or, by a handle, the fist's centre line.
var _hold_point := Vector3.ZERO
var _area := PhysicsShapeQueryParameters3D.new()
var _clear := PhysicsShapeQueryParameters3D.new()
var _meets := PhysicsShapeQueryParameters3D.new()
var _joint: Generic6DOFJoint3D
# The held object's grab point in its own space, and its Grabbable.
var _grip_point := Vector3.ZERO
var _grabbable: Grabbable
# The handle this hand holds the object by, or the candidate's; null if none.
var _handle: CollisionShape3D
# The object's seat, its pose in the hand's space once in the hand; seating
# it, where it was in the hand's space as the seat began, and for how long.
var _seat := Transform3D.IDENTITY
var _seat_from := Transform3D.IDENTITY
var _seated_for := 0.0
# The hold this hand holds or the candidate is, or null. Holding it, where the
# hand is welded in its space, and how far the player's hand was from the
# physical one when the weld was made (world space); and how many hands the
# drive last climbed with.
var _climbable: Climbable
var _on_hold := Vector3.ZERO
var _grip_offset := Vector3.ZERO
var _climbers := 0
# What the held prop did lately, for throwing it; and the relocations it has
# seen, since a recentre is no motion of the prop's.
var _throw := ThrowHistory.new()
var _throw_relocations := 0
# The other hand's grab.
var _other: HandGrab
# Whether this hand gripped an object the other hand had gripped first and is
# coming onto it (it never seats it); and whether this hand drives to the
# two hands' shared target, aiming the object between them or, too close to
# aim, turning it by the mean of the wrists' turns.
var _joining := false
var _sharing := false
var _shared_aims := false
# The shared target's frame when the two-hand hold began, the player's two
# hands' turns then (the lead's, the other's), and this hand's pose in that
# frame.
var _shared_from := Transform3D.IDENTITY
var _lead_from := Basis.IDENTITY
var _other_from := Basis.IDENTITY
var _in_shared := Transform3D.IDENTITY
# Coming onto the object, where this hand will hold it, in the object's space.
var _on_object := Transform3D.IDENTITY
var _gripped := false
var _slipped_for := 0.0
# How long this hand has been coming onto the other hand's object.
var _joining_for := 0.0
var _untracked_for := 0.0
# Objects let go and this hand not yet clear of: grabbable, body, time.
var _letting_go: Array[Dictionary] = []
# The object's rotation in the hand when the grip joint was last made.
var _turn_from := Basis.IDENTITY
var _turn_from_known := false


func attach(rig: PlayerRig, physical: DynamicPhysical) -> void:
	_physical = physical
	_hand = drive.hand
	# Frozen only while it holds a hold (_snap_onto_hold).
	_hand.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	var left := drive.side == HandDrive.Side.LEFT
	_side = 0 if left else 1
	_controller = rig.left_controller if left else rig.right_controller
	var skeleton := rig.skeleton
	_palm_side = skeleton.palm_direction.normalized()
	if left:
		_palm_side.x = -_palm_side.x
	var face := drive.palm_size.x * skeleton.hand_scale * 0.5
	_palm_point = _palm_side * (face - grab_depth) + Vector3.FORWARD * grab_forward * skeleton.hand_scale
	_hold_point = _palm_point
	_palm_half_width = drive.palm_size.y * skeleton.hand_scale * 0.5
	var ball := SphereShape3D.new()
	ball.radius = grab_radius
	_area.shape = ball
	# Held and Seating too: the other hand may hold or be seating what this one
	# grabs. And holds.
	_area.collision_mask = Grabbable.GRABBABLE_LAYER | HELD_LAYER | Grabbable.SEATING_LAYER \
			| Climbable.CLIMB_HOLD_LAYER
	_other = physical.right_grab if left else physical.left_grab
	_clear.collision_mask = HELD_LAYER
	_clear.margin = restore_clearance
	_meets.collision_mask = HELD_MASK


func _ready() -> void:
	# Before the hand drive: the hand is where the last step left it.
	process_physics_priority = StaticSkeleton.SOLVE_PRIORITY + 4


func _physics_process(delta: float) -> void:
	if _hand == null:
		return
	hand_point = _hand.global_transform * _hold_point
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
			_grab(delta)
	else:
		_hold(delta)
	_give_layers_back(delta)
	_publish()


## The Grabbable body or Climbable hold in the grab area whose surface comes
## closest to the hand's grab point, and that point; on a handle, where the
## fist would hold it, and not if the grab point is beyond either end.
func _find_candidate() -> void:
	target = null
	_handle = null
	_climbable = null
	gap = 0.0
	_area.transform = Transform3D(Basis.IDENTITY, hand_point + _hand.global_basis * _palm_side * grab_reach)
	_area.exclude = [_hand.get_rid()]
	var best := INF
	for hit in _hand.get_world_3d().direct_space_state.intersect_shape(_area, 16):
		var body := hit.collider as PhysicsBody3D
		var climbable := Climbable.of(body)
		var grabbable := Grabbable.of(body)
		if climbable != null:
			if not climbable.enabled:
				continue
		# A frozen body is fixed where it is, unless a hand is seating it.
		elif body == null or grabbable == null or not grabbable.open_to(self) \
				or ((body as RigidBody3D).freeze and grabbable.holders.is_empty()):
			continue
		var holder := body.shape_owner_get_owner(body.shape_find_owner(hit.shape)) as CollisionShape3D
		if holder == null:
			continue
		var closest := _closest_on(holder, hand_point)
		var distance := closest.distance_to(hand_point)
		if distance >= best:
			continue
		var handle: CollisionShape3D = holder if grabbable != null and holder in grabbable.handles else null
		if handle != null:
			if absf(_along(handle)) > Grabbable.handle_extent(handle.shape).y:
				continue
			closest = handle.global_transform.orthonormalized() * Vector3(0.0, _held_along(handle, grabbable), 0.0)
		best = distance
		target = body
		_handle = handle
		_climbable = climbable
		object_point = closest
		gap = closest.distance_to(hand_point)


## Grabs the candidate at its grab point (a hold: _snap_onto_hold): Grabbable
## moves it to the Held layer (if no other hand holds it), and the hand seats
## it, from this tick, keeping its rotation relative to the hand as it is, or
## by a handle turning it into its seat. If the other hand has it, this hand
## joins the other's hold instead, from now if the other already holds it.
func _grab(delta: float) -> void:
	_grip_point = target.global_transform.affine_inverse() * object_point
	_throw.clear()
	if _climbable != null:
		_snap_onto_hold()
		return
	_grabbable = Grabbable.of(target)
	if _handle != null:
		_take_seat()
	var partner := _grabbable.partner_of(self)
	_joining = partner != null
	_grabbable.hold(self)
	_forget_letting_go(target as RigidBody3D)
	state = State.SEATING
	_slipped_for = 0.0
	_joining_for = 0.0
	_untracked_for = 0.0
	grabs += 1
	if not _joining:
		_start_seat()
		_seat_step(delta)
	elif partner.state == State.HOLDING:
		_begin_shared(partner, self)


## Starts bringing the object into its seat (_seat_step), from where it lies
## in the hand's space now: by a handle, the seat _take_seat found; otherwise
## its grab point on the hand's, its rotation in the hand as it is now.
## Grabbable freezes it meanwhile, meeting nothing.
func _start_seat() -> void:
	_seat_from = _hand.global_transform.orthonormalized().affine_inverse() * target.global_transform.orthonormalized()
	if _handle == null:
		_seat = Transform3D(_seat_from.basis, _hold_point - _seat_from.basis * _grip_point)
	_seated_for = 0.0
	_grabbable.seat()


## Brings the object a tick further into its seat, placed where the hand is
## now: in the hand's space its grab point moves straight onto the hand's while
## it turns to the seat's rotation about that point, easing out over
## seat_time. Godot draws a body where its last step left it, so the object is
## drawn with the hand, and it meets nothing in the step. The last tick puts
## it exactly in its seat, moving as the hand moves, and welds it there.
func _seat_step(delta: float) -> void:
	var object := target as RigidBody3D
	var hand := _hand.global_transform.orthonormalized()
	_seated_for += delta
	if _seated_for < seat_time - 1e-4:
		var eased := 1.0 - pow(1.0 - _seated_for / seat_time, 3.0)
		var turn := _seat_from.basis.get_rotation_quaternion().slerp(_seat.basis.get_rotation_quaternion(), eased)
		var point := (_seat_from * _grip_point).lerp(_hold_point, eased)
		object.global_transform = hand * Transform3D(Basis(turn), point) * Transform3D(Basis.IDENTITY, -_grip_point)
		return
	# Unfrozen first: Jolt moves a frozen body only over the next step, and
	# would take its velocities for its surface's.
	_grabbable.seated()
	object.global_transform = hand * _seat
	_move_with_hand(object)
	_lock()
	_solidify_when_clear()


## Gives `object` the velocity and spin it would have fixed to the hand.
func _move_with_hand(object: RigidBody3D) -> void:
	var centre := object.global_transform * PhysicsServer3D.body_get_direct_state(object.get_rid()).center_of_mass_local
	object.linear_velocity = _hand.linear_velocity + _hand.angular_velocity.cross(centre - _hand.global_position)
	object.angular_velocity = _hand.angular_velocity


## Holding an object that meets nothing (just seated, or seated inside
## something): the lead makes it meet what a held object meets once none of
## its shapes overlaps any of that, so it is never pushed out of the level, a
## prop, the other hand or what that holds through the weld. The hands holding
## it never meet it, so they do not count.
func _solidify_when_clear() -> void:
	if _grabbable.solid or not _leads():
		return
	var object := target as RigidBody3D
	var space := object.get_world_3d().direct_space_state
	var exclude := _grabbable.ignored_hands()
	exclude.append(object.get_rid())
	_meets.exclude = exclude
	for owner_id in object.get_shape_owners():
		var holder := object.shape_owner_get_owner(owner_id) as CollisionShape3D
		if holder == null or holder.shape == null or holder.disabled:
			continue
		_meets.shape = holder.shape
		_meets.transform = holder.global_transform
		if not space.intersect_shape(_meets, 1).is_empty():
			return
	_grabbable.solidify()


## Seats the object, comes onto it, or holds it, and lets go when the grip
## opens, it slips, or tracking is lost.
func _hold(delta: float) -> void:
	if not is_instance_valid(target):
		_let_go()
		return
	object_point = target.global_transform * _grip_point
	# First, so a throw this tick reads the prop as it is now.
	if state == State.HOLDING and _climbable == null:
		_record_throw(delta)
	gap = hand_point.distance_to(object_point)
	var stuck := (_joining and gap > max_slip) if state == State.SEATING \
			else (drive.overreach > hold_tear_reach if _climbable != null else drive.separation > max_separation)
	_slipped_for = _slipped_for + delta if stuck else 0.0
	_untracked_for = _untracked_for + delta if not drive.tracked else 0.0
	if not _gripped or _slipped_for >= slip_time or _untracked_for >= tracking_loss_time:
		_let_go()
		return
	if state == State.HOLDING:
		if _climbable != null:
			_hang()
			return
		_solidify_when_clear()
		_share_target()
		_carry()
		drive.holding(target as RigidBody3D, _hand.global_transform.affine_inverse() * target.global_transform)
		_measure_turn()
		return
	if not _joining:
		_seat_step(delta)
		return
	# Coming onto the object the other hand holds: both drive to the shared
	# target, which brings this hand's grab point onto the object's (and by a
	# handle, the hand into its seat). On it: within hold_distance, and by a
	# handle turned into its seat and settled there (welded while still
	# turning, the longsword lurched); or, riding longer than slip_time,
	# passing through it (with the wrist moving on, the turn could never
	# settle, and the longsword swung loose in the fist for as long as the
	# wrist moved).
	_joining_for += delta
	_share_target()
	var on := gap <= hold_distance and _turn_to_seat().length() <= hold_angle and (_handle == null
			or _spin_against_hand() <= settled_spin or _joining_for >= slip_time)
	if _sharing and on:
		_lock()


## Seats a handle grab from where the hand is now: _seat, the fist's centre
## line (_hold_point), and the handle's point it holds (_grip_point). The
## handle lies along the fist's grip, the hand's Y leaned toward the fingers by
## the Grabbable's handle_lean (both hands have the thumb on +Y and the fingers
## on -Z), toward the thumb or the little finger, across the palm from one of
## its sides (its Z along the palm's facing, one way or the other): whichever
## of those four is nearest how the handle lies in the hand now. Its side rests on the palm's grab
## point (toward the knuckles by grab_forward), where the palm's grab point is
## along it but with the palm wholly on it. (The further toward the knuckles,
## the further the sword's two hands hold it off straight: harness,
## 2026-09-27, in the two-hand checks.)
func _take_seat() -> void:
	var hand := _hand.global_transform.orthonormalized()
	var handle := _handle.global_transform.orthonormalized()
	var extent := Grabbable.handle_extent(_handle.shape)
	var now := hand.basis.inverse() * handle.basis
	var best := -INF
	var turn := Basis.IDENTITY
	var grip := Vector3.UP.rotated(Vector3.LEFT, _grabbable.handle_lean)
	for toward: float in [1.0, -1.0]:
		for side: float in [1.0, -1.0]:
			var along := grip * toward
			var across := _palm_side * side
			var seated := Basis(along.cross(across), along, across)
			# The trace of the turn between them: the nearer, the larger.
			var fit := seated.x.dot(now.x) + seated.y.dot(now.y) + seated.z.dot(now.z)
			if fit > best:
				best = fit
				turn = seated
	_hold_point = _palm_point + _palm_side * extent.z
	var held := Vector3(0.0, _held_along(_handle, _grabbable), 0.0)
	var in_object := target.global_transform.affine_inverse() * handle
	_seat = Transform3D(turn, _hold_point - turn * held) * in_object.affine_inverse()
	_grip_point = in_object * held


## How far along `handle` from its middle the palm's grab point lies, in
## metres.
func _along(handle: CollisionShape3D) -> float:
	return (handle.global_transform.orthonormalized().affine_inverse() * (_hand.global_transform * _palm_point)).y


## Where along `handle` of `grabbable`'s body, from its middle, the fist holds
## it: level with the palm's grab point, but with the palm wholly on the
## handle, and beside the other hand if that holds the same handle (the hands
## do not meet each other, and a second fist could be seated in the first), as
## far as the handle's length allows (the sword's grip is shorter than two
## palms).
func _held_along(handle: CollisionShape3D, grabbable: Grabbable) -> float:
	var reach := maxf(Grabbable.handle_extent(handle.shape).y - _palm_half_width, 0.0)
	var along := _along(handle)
	var partner := grabbable.partner_of(self)
	if partner != null and partner._handle == handle:
		var frame := handle.global_transform.orthonormalized()
		var theirs := (frame.affine_inverse() * (partner.target.global_transform * partner._grip_point)).y
		var apart := _palm_half_width + partner._palm_half_width
		if absf(along - theirs) < apart:
			along = theirs + (apart if along >= theirs else -apart)
	return clampf(along, -reach, reach)


## How far the object is turned from its seat in the hand, as a rotation in
## world space: none unless it is held by a handle.
func _turn_to_seat() -> Vector3:
	if _handle == null:
		return Vector3.ZERO
	return HandDrive._rotation_between(target.global_basis, _hand.global_basis * _seat.basis)


## How fast the held object spins against the hand, in radians a second.
func _spin_against_hand() -> float:
	return ((target as RigidBody3D).angular_velocity - _hand.angular_velocity).length()


## The object is in the hand: remakes the grip joint to hold it where it is
## now. The first hand holds it rigidly: it moves with the hand; a second
## hand gripping it meanwhile joins the hold from now. The second hand holds
## a point of it, and the lead then aims it (unless their centres are too
## close to aim between).
func _lock() -> void:
	anchor = target.global_transform.affine_inverse() * hand_point
	var partner := _grabbable.partner_of(self)
	state = State.HOLDING
	_slipped_for = 0.0
	if not _joining:
		_rejoin(Hold.WELD)
		if partner != null:
			_begin_shared(self, partner)
			_share_target()
		return
	_joining = false
	_rejoin(Hold.POINT)
	if _shared_aims:
		partner.aim_at(self)
	# In the shared frame where it holds the object now, so the two targets fit
	# the object exactly. It locks up to hold_distance short of where the seat
	# put it, and that stays in the aim for the hold: at most 5 mm across the
	# span (0.4-0.6° on the bars, 1.9-2.9° on the swords' grips). From riding
	# the object to the shared target, this tick: the target jumps by the
	# lead's error against its own target, carried to this hand (its offset,
	# plus its turn error times the span), plus how far this hand is off where
	# it rode: 1 cm on the sword, 2 cm on a bar gripped 0.6 m apart while it
	# lies on the table. None of it is motion of the hand's.
	_in_shared = partner._in_shared * partner._hand.global_transform.affine_inverse() * _hand.global_transform
	_share_target()
	drive.retarget()


## Takes the candidate hold: moves the hand, as it is turned, so that its grab
## point is on the hold's, welds and freezes it there, and from now its drive
## climbs (the search found the hold within grab_reach and grab_radius).
func _snap_onto_hold() -> void:
	_hand.global_position += object_point - hand_point
	_hand.linear_velocity = Vector3.ZERO
	_hand.angular_velocity = Vector3.ZERO
	hand_point = object_point
	gap = 0.0
	grabs += 1
	state = State.HOLDING
	_slipped_for = 0.0
	_untracked_for = 0.0
	_rejoin(Hold.WELD)
	_hand.freeze = true
	_on_hold = target.global_transform.affine_inverse() * _hand.global_position
	_grip_offset = drive.player_hand().origin - _hand.global_position
	_hang()


## The player snap turned by `turning` (DynamicPhysical), before this tick's
## grab: what this hand holds turns with them (moved once, by the lead, while
## both hands hold it; one being seated is placed from the turned hand), and
## the two hands' shared frame turns too. On a hold, the jump of the player's hand round them is climbing
## as a real turn is: the drive moves the body round the hold until the
## player's hands are back on it, closing the jump as it closes any gap rather
## than at the jump's speed (decided with the player 2026-09-30: re-based
## instead, the body stayed where it hung while the skeleton turned away from
## it; the slide that follows is about 25 cm over 0.3 s for 45°).
func turn(turning: Transform3D) -> void:
	if state == State.IDLE or not is_instance_valid(target):
		return
	if _climbable != null:
		drive.retarget()
		return
	_shared_from = turning * _shared_from
	_lead_from = turning.basis * _lead_from
	_other_from = turning.basis * _other_from
	_throw.turn(turning)
	if _grabbable == null or _grabbable.holders.is_empty() or _grabbable.holders[0] != self:
		return
	if state == State.SEATING:
		# This tick's seat step places it from the turned hand.
		return
	var object := target as RigidBody3D
	object.global_transform = turning * object.global_transform
	object.linear_velocity = turning.basis * object.linear_velocity
	object.angular_velocity = turning.basis * object.angular_velocity


## Holding a hold, each tick before the drive runs: tells it to climb, toward
## how far the player's hand has moved since the weld, averaged with the other
## hand's while it holds a hold too, so the two drives move the body alike
## (each after its own hand, they would pull against each other through it).
## A hold that stops being one is let go.
func _hang() -> void:
	if not _climbable.enabled:
		_let_go()
		return
	var climbers := 2 if _other != null and _other.climbing() else 1
	var offset := hang_offset()
	if climbers == 2:
		offset = (offset + _other.hang_offset()) * 0.5
	if climbers != _climbers:
		# The other hand took a hold or let go: the offset jumps to or from the
		# average, which is no motion of the player's hands.
		drive.retarget()
		_climbers = climbers
	drive.climb_offset = offset
	drive.climbing = true


## Holding a hold: how far the player's hand has moved since the weld, from
## this tick's tracking (the same whichever hand works it out first).
func hang_offset() -> Vector3:
	return drive.player_hand().origin - _grip_offset - target.global_transform * _on_hold


## Whether this hand holds a hold (climbing).
func climbing() -> bool:
	return state == State.HOLDING and _climbable != null


## Lets go of a hold this hand holds (the player is being moved: a hand
## welded to the world cannot go with them).
func release_hold() -> void:
	if _climbable != null and state != State.IDLE:
		_let_go()


## Where a hold of `kind` meets the hand, in world space: a WELD at the palm's
## grab point; a two-hand joint at the hand's centre, where the drive pushes:
## at the palm's face, the object's load twisted the hand against its wrist,
## and the two traded it back and forth (2026-09-27, scratch tests).
func joint_point(kind: Hold) -> Vector3:
	return _hand.global_transform * _palm_point if kind == Hold.WELD else _hand.global_position


## The other hand now holds this hand's object too, at `other`'s grab point:
## holds a point of it and its roll about the line to that point.
func aim_at(other: HandGrab) -> void:
	_rejoin(Hold.AIM, other)


## The other hand let go: this one holds the object alone now, rigidly as it
## is, or, still coming onto it, seats it as a first hand does.
func take_over() -> void:
	drive.two_handed = false
	_sharing = false
	if state == State.HOLDING:
		if hold_kind != Hold.WELD:
			_rejoin(Hold.WELD)
		# The whole load is this arm's before its drive's tick, whichever hand's
		# grab ran first: otherwise, taking over from the hand that ran second,
		# the arm's strength missed the jump of its target for a tick and then
		# carried that jump's speed past it (review, 2026-09-27).
		_carry()
	elif _joining:
		_joining = false
		if _handle != null:
			_take_seat()
		_start_seat()


## Starts `lead`'s and `other`'s shared target, with the lead holding the
## object and the other holding it or coming onto it: its frame from the
## player's two hands now, and each hand's pose in it, the other's as if it
## held the object at its grab point already. Aiming (the two hands' centres
## so placed at least min_aim_span apart), the object is seated in the frame
## as the player's hands hold it: the line between those centres turned onto
## the line between the player's hands, keeping its roll, its middle on
## theirs; each physical hand where that puts it. Held in one hand until now,
## it may hang off that line (a longsword held by its pommel end dipped 10°),
## and it settles onto it as the hold begins. Too close to aim, it stays as
## it is.
static func _begin_shared(lead: HandGrab, other: HandGrab) -> void:
	if other._handle != null:
		# From where that hand is now: the lead may have turned the object in.
		other._take_seat()
	var lead_hand := lead.drive.static_hand()
	var other_hand := other.drive.static_hand()
	var lead_pose := lead._holding_pose()
	var other_pose := other._holding_pose()
	var aims := lead_pose.origin.distance_to(other_pose.origin) >= lead.min_aim_span
	var middle := (lead_hand.origin + other_hand.origin) * 0.5
	var frame := Transform3D(lead_hand.basis, middle)
	var seat := Transform3D.IDENTITY
	if aims:
		var along := (other_hand.origin - lead_hand.origin).normalized()
		var up := lead_hand.basis.y - along * along.dot(lead_hand.basis.y)
		if up.length_squared() < 1e-6:
			up = lead_hand.basis.z - along * along.dot(lead_hand.basis.z)
		up = up.normalized()
		frame = Transform3D(Basis(along, up, along.cross(up)), middle)
		var start := lead_pose.origin
		var end := other_pose.origin
		seat = Transform3D(Basis(Quaternion((end - start).normalized(), along)), middle) \
				* Transform3D(Basis.IDENTITY, -(start + end) * 0.5)
	for hand: HandGrab in [lead, other]:
		hand._sharing = true
		hand._shared_aims = aims
		hand._shared_from = frame
		hand._lead_from = lead_hand.basis
		hand._other_from = other_hand.basis
	lead._in_shared = frame.affine_inverse() * seat * lead_pose
	other._in_shared = frame.affine_inverse() * seat * other_pose
	other._on_object = other.target.global_transform.affine_inverse() * other_pose


## Where this hand holds its object: where it is, or, still coming onto it,
## moved by the gap from its grab point to the object's; by a handle, in its
## seat.
func _holding_pose() -> Transform3D:
	if state == State.SEATING and _handle != null:
		return target.global_transform * _seat.affine_inverse()
	var pose := _hand.global_transform
	if state == State.SEATING:
		pose.origin += target.global_transform * _grip_point - pose * _palm_point
	return pose


## While both hands hold the object, drives this hand to the shared target:
## the frame started when the hold began, moved to the middle of the player's
## two hands and turned with them; this hand where it was in it. Aiming, the
## frame turns so its X runs along the line between the player's hands, and
## rolls about that line by the mean of the two wrists' roll since then; too
## close to aim, it turns by the mean of the two wrists' turns. Both hands
## work it out alike, from the same inputs. A second hand still coming onto
## the object rides it instead, as if it held it already: the lead may lag
## its own target (a load resting on something gives the wrist), and a hand
## driven to the shared target would then stop short of the object.
func _share_target() -> void:
	drive.two_handed = _sharing and _grabbable.holders.size() == 2
	if not drive.two_handed:
		return
	if state == State.SEATING:
		drive.two_hand_target = target.global_transform * _on_object
		return
	var lead := _grabbable.holders[0]
	var other := _grabbable.holders[1]
	var lead_hand := lead.drive.static_hand()
	var other_hand := other.drive.static_hand()
	var turn: Basis
	if _shared_aims:
		var along := (other_hand.origin - lead_hand.origin).normalized()
		var aim := Basis(Quaternion(_shared_from.basis.x, along))
		# The mean on the circle: the two rolls can lie either side of 180°.
		var lead_roll := _roll_about(along, aim * _lead_from, lead_hand.basis)
		var other_roll := _roll_about(along, aim * _other_from, other_hand.basis)
		turn = Basis(along, lead_roll + angle_difference(lead_roll, other_roll) * 0.5) * aim
	else:
		var lead_turn := Quaternion(lead_hand.basis * _lead_from.inverse())
		var other_turn := Quaternion(other_hand.basis * _other_from.inverse())
		turn = Basis(lead_turn.slerp(other_turn, 0.5))
	var middle := (lead_hand.origin + other_hand.origin) * 0.5
	drive.two_hand_target = Transform3D(turn * _shared_from.basis, middle) * _in_shared


## How far `now` is rolled about `axis` from `from`, in radians: the twist
## about the axis of the turn between them. A hand holds a handle with its Y
## nearly along it, so its Y seen across the axis says little: a few degrees
## of wrist tremble read as many degrees of roll (review, 2026-09-27).
static func _roll_about(axis: Vector3, from: Basis, now: Basis) -> float:
	var turn := Quaternion(now.orthonormalized()) * Quaternion(from.orthonormalized()).inverse()
	if turn.w < 0.0:
		turn = -turn
	return 2.0 * atan2(Vector3(turn.x, turn.y, turn.z).dot(axis), turn.w)


## This hand's part in its hold: 0 none, 1 the lead (the first to grab), 2 the
## second hand.
func role() -> int:
	if state == State.IDLE or _grabbable == null:
		return 0
	return 1 if _leads() else 2


## Whether this hand holds its object with the other hand, aiming it between
## their grab points.
func aiming() -> bool:
	if state != State.HOLDING or hold_kind == Hold.WELD:
		return false
	var partner := _grabbable.partner_of(self)
	return partner != null and partner.state == State.HOLDING \
			and (hold_kind == Hold.AIM or partner.hold_kind == Hold.AIM)


func _leads() -> bool:
	return not _grabbable.holders.is_empty() and _grabbable.holders[0] == self


## Remakes the grip joint to hold the object as `kind`, where it is now. The
## joint sits at the hand's grab point, recomputed (the other hand can call
## this in its own tick); an AIM joint's X runs along the line to `other`'s
## grab point, the rest as near the hand's axes as can be.
func _rejoin(kind: Hold, other: HandGrab = null) -> void:
	if _joint != null:
		_joint.queue_free()
	_joint = Generic6DOFJoint3D.new()
	_joint.name = "Grip"
	add_child(_joint)
	var point := joint_point(kind)
	anchor = target.global_transform.affine_inverse() * point
	var frame := _hand.global_basis
	if kind == Hold.AIM:
		var along := (target.global_transform * other.anchor - target.global_transform * anchor).normalized()
		var up := frame.y.normalized()
		up = up - along * along.dot(up)
		if up.length_squared() < 1e-6:
			up = frame.z.normalized() - along * along.dot(frame.z.normalized())
		up = up.normalized()
		frame = Basis(along, up, along.cross(up))
	_joint.global_transform = Transform3D(frame, point)
	_configure_hold(kind)
	_joint.node_a = _joint.get_path_to(_hand)
	_joint.node_b = _joint.get_path_to(target)
	_configure_hold(kind)
	hold_kind = kind
	_turn_from_known = false


## A hold's joint: every linear axis locked, and its rotation locked too
## (WELD), free (POINT), or locked only about the joint's X (AIM), the line
## between the two hands' grab points, free to swing about the rest.
func _configure_hold(kind: Hold) -> void:
	for axis in ["x", "y", "z"]:
		for type in ["linear", "angular"]:
			var locked: bool = type == "linear" or kind == Hold.WELD or (kind == Hold.AIM and axis == "x")
			_joint.set("%s_limit_%s/enabled" % [type, axis], locked)
			_joint.set("%s_motor_%s/enabled" % [type, axis], false)
		_joint.set("linear_limit_%s/lower_distance" % axis, 0.0)
		_joint.set("linear_limit_%s/upper_distance" % axis, 0.0)
		_joint.set("angular_limit_%s/lower_angle" % axis, 0.0)
		_joint.set("angular_limit_%s/upper_angle" % axis, 0.0)


## Tells the hand drive what it carries: the held object's mass, its inertia
## about its centre of mass and where that is from the hand's centre; whether
## it is pressed on anything but the player (_pressed), and its gravity. Held
## between two aiming
## hands, each carries its share of the weight at its own grab point, with no
## turning of the object: that comes from where the hands are. The second of
## two hands too close to aim carries nothing.
func _carry() -> void:
	var object := target as RigidBody3D
	var state := PhysicsServer3D.body_get_direct_state(object.get_rid())
	if hold_kind == Hold.WELD:
		share = 1.0
		var centre := object.global_position + state.center_of_mass - _hand.global_position
		drive.carry(object.mass, state.inverse_inertia_tensor.inverse(), centre, _pressed(state),
				state.total_gravity)
		return
	share = _share(state, _grabbable.partner_of(self)) if aiming() else 0.0
	drive.carry(object.mass * absf(share), Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO),
			Vector3.ZERO, _pressed(state), state.total_gravity)


## This hand's share of the weight of an object held at two points, by the
## lever rule: its centre of mass projected onto the line between them. Past
## the other hand's point, this hand's share is below 0 (it pushes down) and
## the other's above 1; the two always add up to 1.
func _share(state: PhysicsDirectBodyState3D, partner: HandGrab) -> float:
	var mine := target.global_transform * anchor
	var line := target.global_transform * partner.anchor - mine
	var centre := target.global_position + state.center_of_mass
	return 1.0 - (centre - mine).dot(line) / maxf(line.length_squared(), 1e-8)


## Whether anything but the player pushes on the held object. The physics
## engine also reports contacts it only expects (within a couple of
## centimetres) with no push yet; those are not a press. The other hand and
## what it holds do not count (2026-10-03): counted, a palm resting on the
## held object took its weight off this arm and switched its drive to giving
## way, and the two drives shook it 3.4 mm a tick (harness, held_palm_push).
func _pressed(state: PhysicsDirectBodyState3D) -> bool:
	for i in state.get_contact_count():
		var other := state.get_contact_collider_object(i)
		if other == _other.drive.hand or (other == _other.target and _other.state != State.IDLE):
			continue
		if state.get_contact_impulse(i).length() > HandDrive.TOUCH_IMPULSE:
			return true
	return false


## Measures held_turn: the object's rotation in the hand against when the
## grip joint was made.
func _measure_turn() -> void:
	var relative := _hand.global_basis.orthonormalized().inverse() * target.global_basis.orthonormalized()
	if not _turn_from_known:
		_turn_from = relative
		_turn_from_known = true
	held_turn = rad_to_deg((_turn_from.inverse() * relative).get_rotation_quaternion().get_angle())


## Lets the held object go. It keeps the Held layer until clear of the hand
## (and of the other hand, if that let go too); a hand still holding it holds
## it alone from now. Let go while being seated, it moves on as the hand did;
## and let go by the last hand, it meets what it meets again.
func _let_go() -> void:
	drive.two_handed = false
	drive.climbing = false
	_hand.freeze = false
	drive.carry(0.0, Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), Vector3.ZERO)
	drive.holding(null, Transform3D.IDENTITY)
	held_turn = 0.0
	_turn_from_known = false
	var throwing := state == State.HOLDING and _climbable == null and _throw.ready()
	if _joint != null:
		# Out of the tree now, not at the frame's end, so the grip does not
		# hold the prop through one more step after it is thrown.
		remove_child(_joint)
		_joint.queue_free()
		_joint = null
	if is_instance_valid(target) and is_instance_valid(_grabbable):
		var partner := _grabbable.partner_of(self)
		if state == State.SEATING and not _joining:
			_grabbable.seated()
			_move_with_hand(target as RigidBody3D)
		if partner == null and not _grabbable.solid:
			_grabbable.solidify()
		if throwing and partner == null:
			_throw_prop(target as RigidBody3D)
		_grabbable.let_go(self)
		_letting_go.append({"grabbable": _grabbable, "body": target, "time": 0.0})
		if partner != null:
			partner.take_over()
	target = null
	_grabbable = null
	_handle = null
	_climbable = null
	_climbers = 0
	_hold_point = _palm_point
	state = State.IDLE
	hold_kind = Hold.WELD
	share = 1.0
	_joining = false
	_sharing = false


## Each tick a prop is held: its centre of mass and spin, for throwing it.
func _record_throw(delta: float) -> void:
	var object := target as RigidBody3D
	if _physical.carrier.relocations != _throw_relocations:
		_throw_relocations = _physical.carrier.relocations
		_throw.clear()
	_throw.window = throw_window
	var centre := object.global_transform * PhysicsServer3D.body_get_direct_state(object.get_rid()).center_of_mass_local
	_throw.add(delta, centre, object.angular_velocity)


## Lets `object` go with the velocity and spin of the fit through its last
## moments (decided with the player 2026-09-30: "use the brief history of the
## objects velocity"); before, it kept the velocity of its last step, which on
## the harness's overhand throw lagged the player's hand by 20 %.
func _throw_prop(object: RigidBody3D) -> void:
	_physical.snapshot.throw_own_velocity[_side] = object.linear_velocity
	object.linear_velocity = _throw.velocity()
	object.angular_velocity = _throw.spin()
	_physical.snapshot.throws[_side] += 1
	_physical.snapshot.throw_velocity[_side] = object.linear_velocity


## Drops a let-go entry for `body`, which this hand grabs again.
func _forget_letting_go(body: RigidBody3D) -> void:
	for i in range(_letting_go.size() - 1, -1, -1):
		if _letting_go[i].body == body:
			_letting_go.remove_at(i)


## Tells let-go objects' Grabbable once every part of the hand is
## restore_clearance clear of them, or after restore_limit; it gives them their
## own layers back once no hand holds them or is still clearing them.
func _give_layers_back(delta: float) -> void:
	for i in range(_letting_go.size() - 1, -1, -1):
		var entry := _letting_go[i]
		var body := entry.body as RigidBody3D
		entry.time += delta
		if not is_instance_valid(body) or not is_instance_valid(entry.grabbable):
			_letting_go.remove_at(i)
		elif entry.time >= restore_limit or not _hand_overlaps(body):
			(entry.grabbable as Grabbable).clear_of(self)
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
## from `point` toward the shape's centre first meets it, or, from inside the
## shape, its surface's nearest point. Never inside the shape.
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
	query.collision_mask = Grabbable.GRABBABLE_LAYER | HELD_LAYER | Grabbable.SEATING_LAYER
	query.transform = Transform3D(Basis.IDENTITY, point)
	query.exclude = [_hand.get_rid()]
	var space := _hand.get_world_3d().direct_space_state
	# A ball already in the shape (the palm pressed into it, or reaching into
	# something the other hand holds) goes out the shortest way, to the nearest
	# point of its surface. The cast does not see a shape it starts in, and
	# came back with the shape's centre: a grab inside the object (2026-10-02).
	var body := holder.get_parent() as CollisionObject3D
	var others: Array[RID] = [_hand.get_rid()]
	var inside := false
	for hit in space.intersect_shape(query, 8):
		if hit.rid == body.get_rid():
			inside = true
		else:
			others.append(hit.rid)
	query.exclude = others
	if inside:
		var rest := space.get_rest_info(query)
		if not rest.is_empty():
			return rest.point
	query.motion = holder.global_position - point
	var fractions := space.cast_motion(query)
	return point + query.motion * fractions[1]


## The mass of what this hand holds that it carries along with the body, in
## kg: its share of the object's weight (the two hands' shares add up to the
## whole) times the share its arm bears now (none while it rests on something).
func carried_mass() -> float:
	if state != State.HOLDING or _climbable != null or not is_instance_valid(target):
		return 0.0
	return (target as RigidBody3D).mass * share * drive.borne_share()


## How far the held object's grab point is drawn from the grab point of
## `drawn_hand` (the hand as the avatar shows it), in metres; zero holding
## nothing. Read while a frame is drawn: physics interpolation draws a body
## between its last two steps, while the avatar is posed on the tick.
func drawn_gap(drawn_hand: Transform3D) -> float:
	if state != State.HOLDING or _climbable != null or not is_instance_valid(target):
		return 0.0
	return (target.get_global_transform_interpolated() * _grip_point).distance_to(drawn_hand * _hold_point)


func _publish() -> void:
	var snapshot := _physical.snapshot
	snapshot.grab_state[_side] = state
	snapshot.grab_hand_points[_side] = hand_point
	snapshot.grab_object_points[_side] = object_point if target != null else hand_point
	snapshot.grab_gap[_side] = gap if target != null else 0.0
	snapshot.grab_turn[_side] = held_turn
	snapshot.grab_role[_side] = role()
	snapshot.grab_aiming[_side] = aiming()
	var object := target as RigidBody3D
	snapshot.grab_mass[_side] = object.mass if state != State.IDLE and object != null else 0.0
	snapshot.grab_offset[_side] = 0.0
	snapshot.grab_on_hold[_side] = climbing()
	if state != State.IDLE and object != null:
		var centre := object.global_position + PhysicsServer3D.body_get_direct_state(object.get_rid()).center_of_mass
		snapshot.grab_offset[_side] = centre.distance_to(_hand.global_position)
