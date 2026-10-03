class_name RigCarrier
extends Node

## The only writer of the XR origin's transform.
##
## Each tick it moves the rig by however far the body moved in the last
## physics solve, except the part of that movement that was only the body
## catching up with the head. A real step already moved the view; the body
## following it must not move the view a second time. Vertical movement is
## always carried. The following part is taken from a model of how the body
## responds to the follow command (the motor's first-order response), so the
## body still settling after the player stops is left out too. Whatever the
## world stopped is taken out of that model: comparing the velocity each solve
## produced with the one it would have produced untouched (ground support
## included) shows what walls and furniture removed. So a body sliding along
## furniture while following the head never moves the view.
##
## When the body is stopped but the head is clear, the head may lead it by
## `lean_limit`, enough to lean over a table's edge; beyond that the view is
## pushed back. A head inside geometry is left to the fade and recentring. So stick walking, pushes, impacts and falls move the view
## with the body, and room-scale walking stays one to one.
##
## It also measures where the head is relative to the body: how far the
## footprint of the head's centre (behind the eyes) leads the feet, and how far
## the eyes have gone into a surface the body could not follow them through. Relocations, for recentring and respawning,
## go through here too.

const STATIC_LAYER := 1

## The ball swept from the body's top to the eyes to find what lies between:
## a little larger than the camera's 5 cm near plane, so the view starts to
## darken before a wall is cut open in front of the eyes. With the body under
## the head's centre, a player standing against a wall has their eyes 0.1 m
## from it; this ball leaves them 4 cm to lean before the view darkens.
@export_range(0.02, 0.3, 0.01, "suffix:m") var head_radius := 0.06
## How far a clear head may lead the body's centre before the view is pushed
## back: the body's radius plus how far the player may lean past an edge,
## measured at the head's centre (the eyes are 0.1 m further).
@export_range(0.0, 1.0, 0.01, "suffix:m") var lean_limit := 0.35

## How far the head's footprint leads the body's feet, horizontally, in metres.
var head_lead := Vector3.ZERO
## How far the head has gone past the first surface between it and the body,
## in metres. Zero when the way is clear or the head is not tracked.
var head_obstruction := 0.0
var head_tracked := false
## How far the rig was carried this tick, in metres.
var carried := Vector3.ZERO
## How far the view was pushed back this tick, in metres.
var pushed_back := 0.0
## Recentres and respawns so far.
var relocations := 0
## Snap turns so far.
var turns := 0

var _rig: PlayerRig
var _body: CapsuleBody
var _last_body := Vector3.ZERO
# The body's modelled horizontal velocity from following alone, in m/s.
var _follow_response := Vector3.ZERO
# The horizontal velocity the coming solve would give the body if nothing but
# the ground touched it, and the length of that solve.
var _untouched := Vector3.ZERO
var _solve_delta := 0.0
var _predicted := false
var _head_query: PhysicsShapeQueryParameters3D


func attach(rig: PlayerRig, body: CapsuleBody) -> void:
	_rig = rig
	_body = body


func _ready() -> void:
	var ball := SphereShape3D.new()
	ball.radius = head_radius
	_head_query = PhysicsShapeQueryParameters3D.new()
	_head_query.shape = ball
	_head_query.collision_mask = STATIC_LAYER
	_head_query.exclude = [_body.get_rid()]


## Starts measuring the body's movement from where it is now.
func reset() -> void:
	_last_body = _body.global_position
	_follow_response = Vector3.ZERO
	_predicted = false


## Moves the rig by the body's own movement since the last tick.
func carry() -> void:
	var moved := _body.global_position - _last_body
	_last_body = _body.global_position
	var closing := Vector3.ZERO
	if _predicted:
		_remove_what_was_stopped()
		# Taken out whole, not as the share of the movement along it: walking
		# in the room against the stick, the body's movement runs opposite to
		# its following, and the view must still move with the stick alone.
		closing = _follow_response * _solve_delta
	carried = _horizontal(moved) - closing + Vector3.UP * moved.y
	_rig.global_position += carried


## Remembers how much of the coming solve's movement is the body catching up
## with the head, commanded at `follow` m/s, and what the solve would do to the
## body untouched, so the next carry() can leave the following out. Call after
## the body has been driven for this tick.
func expect_follow(follow: Vector3, delta: float, ground: GroundSense) -> void:
	# The body approaches the command at the motor's rate, slowed to the share
	# of force the legs could actually give this tick. While the legs hold it,
	# it follows a slow command closely instead.
	if _body.is_holding():
		_follow_response = _horizontal(follow)
	else:
		_follow_response += (_horizontal(follow) - _follow_response) \
				* minf(delta / _body.response_time, 1.0) * _body.drive_share
	var velocity := _body.linear_velocity \
			+ (_body.motor_force / _body.moved_mass() + _body.get_gravity()) * delta
	if ground.supported or ground.stepping_down:
		# The ground holding the body up is expected, not an obstacle.
		velocity -= ground.normal * minf(velocity.dot(ground.normal), 0.0)
	_untouched = _horizontal(velocity)
	_solve_delta = delta
	_predicted = true


## Pushes the view back when the body is stopped but the head, clear of
## geometry, has led it by more than `lean_limit`. Call after measure_head().
func push_back() -> void:
	pushed_back = 0.0
	if not head_tracked or head_obstruction > 0.0:
		return
	var distance := head_lead.length()
	if distance <= lean_limit:
		return
	var back := head_lead / distance * (distance - lean_limit)
	_rig.global_position -= back
	head_lead -= back
	pushed_back = back.length()


## Measures the head against the body, after this tick's carry.
func measure_head() -> void:
	var head: Vector3 = _rig.head_centre()
	var feet := _body.global_position
	head_lead = Vector3(head.x - feet.x, 0.0, head.z - feet.z)
	head_tracked = _is_head_tracked()
	head_obstruction = _obstruction(_rig.head.global_position, feet) if head_tracked else 0.0


## Turns the rig `angle` radians about the vertical through the head's centre
## (a snap turn), which the body stands under: the body need not move, and
## the eyes swing 7.7 cm round it, as they do when a real head turns. Turned
## about the eyes instead, the body was left 7.7 cm out of place: following
## the head back nudged what both hands held by 1-2.5°, and moved there at
## once, it was pushed back off the table's edge and a dagger on it, the push
## carried into the view (harness, 2026-09-30). With `with_body` the body's
## motion turns too, so a walk goes on the way the view now faces. Returns
## the turn, for everything else that turns with the player (DynamicPhysical).
func turn(angle: float, with_body: bool) -> Transform3D:
	var pivot: Vector3 = _rig.head_centre()
	var turning := Transform3D(Basis(Vector3.UP, angle), pivot) * Transform3D(Basis.IDENTITY, -pivot)
	_rig.global_transform = turning * _rig.global_transform
	if with_body:
		_body.turn(turning.basis)
		_follow_response = turning.basis * _follow_response
		_untouched = turning.basis * _untouched
	turns += 1
	return turning


## Moves only the rig, e.g. to bring the head back over the body.
func move_rig(offset: Vector3) -> void:
	_rig.global_position += offset
	relocations += 1


## Takes out of the follow response the part the world stopped: the velocity
## contacts removed from the last solve, where it opposed the following.
func _remove_what_was_stopped() -> void:
	var change := _horizontal(_body.linear_velocity) - _untouched
	var amount := change.length()
	if amount < 1e-6:
		return
	var outward := change / amount
	var blocked := -_follow_response.dot(outward)
	if blocked > 0.0:
		_follow_response += outward * minf(blocked, amount)


func _horizontal(vector: Vector3) -> Vector3:
	return Vector3(vector.x, 0.0, vector.z)


## Moves the body and the rig together, and stops the body.
func relocate(offset: Vector3) -> void:
	_body.place_at(_body.global_position + offset)
	_rig.global_position += offset
	_last_body = _body.global_position
	_follow_response = Vector3.ZERO
	_predicted = false
	relocations += 1


## How far a ball swept from inside the body's top to the eyes travels past
## the first surface it meets. A sweep is used rather than an overlap test at
## the head because level geometry is a surface mesh: a head fully inside a
## thick wall would overlap nothing.
func _obstruction(eyes: Vector3, feet: Vector3) -> float:
	var from := feet + Vector3.UP * maxf(_body.height - _body.radius, _body.radius)
	var motion := eyes - from
	var distance := motion.length()
	if distance < 1e-4:
		return 0.0
	_head_query.transform = Transform3D(Basis.IDENTITY, from)
	_head_query.motion = motion
	var fractions := _body.get_world_3d().direct_space_state.cast_motion(_head_query)
	return (1.0 - fractions[0]) * distance


func _is_head_tracked() -> bool:
	var tracker := XRServer.get_tracker(&"head") as XRPositionalTracker
	if tracker == null:
		return false
	var pose := tracker.get_pose(&"default")
	return pose != null and pose.has_tracking_data
