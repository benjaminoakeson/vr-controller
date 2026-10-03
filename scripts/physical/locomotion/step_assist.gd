extends LocomotionModule

## Lifts the body up a step it walks into.
##
## While the body is supported and wants to move, it looks just ahead for a
## riser too steep to walk up. It then checks there is headroom above the
## body, room to move onto the tread at that height, and a walkable tread no
## higher than a step. If all hold, it asks the body to rise to the tread:
## quickly at first, easing off near the top so the body arrives at rest
## rather than bouncing. The view rises with it, smoothly, because the rig
## carries all vertical movement. Walking on, the body moves onto the tread.
##
## Every probe sweeps the body's capsule alone, not the whole body: the body
## also carries the physical limbs' shapes, and an arm reaching ahead or a
## foot mid-step must not read as a riser, a ceiling or a wall.

## The tallest step lifted; the smallest worth lifting.
@export_range(0.05, 0.5, 0.01, "suffix:m") var max_step_height := 0.3
@export_range(0.0, 0.1, 0.005, "suffix:m") var min_step_height := 0.03
## How far ahead of the body, beyond this tick's travel, a riser is looked for.
@export_range(0.0, 0.3, 0.01, "suffix:m") var look_ahead := 0.05
## How far past the riser the body must be able to move at tread height.
@export_range(0.05, 0.5, 0.01, "suffix:m") var tread_depth := 0.1
## The lift's top speed. Near the top it slows to what gravity alone would
## stop in the remaining height.
@export_range(0.2, 5.0, 0.05, "suffix:m/s") var lift_speed := 2.0
## A lift that has not arrived after this long is given up.
@export_range(0.1, 2.0, 0.05, "suffix:s") var lift_timeout := 0.5

## Clearance kept between the feet and the tread when lifting, in metres.
const CLEARANCE := 0.01

var _lifting := false
var _target_height := 0.0
var _elapsed := 0.0
var _query := PhysicsShapeQueryParameters3D.new()
# The last sweep's travel before contact and the contact's normal.
var _travel := Vector3.ZERO
var _normal := Vector3.UP


func contribute(frame: LocomotionFrame, delta: float) -> void:
	var body := physical.body
	var wanted := frame.desired_velocity()
	if _lifting:
		_elapsed += delta
		var remaining := _target_height - body.global_position.y
		if remaining <= 0.0 or _elapsed >= lift_timeout or wanted.is_zero_approx():
			_lifting = false
		else:
			frame.lift_speed = _speed_for(remaining, body)
		return
	# Climbing, the hands move the body; no step lift starts.
	if not physical.ground.supported or wanted.is_zero_approx() or physical.climbing():
		return
	var rise := _step_ahead(body, wanted, delta)
	if rise > 0.0:
		_lifting = true
		_elapsed = 0.0
		_target_height = body.global_position.y + rise + CLEARANCE
		frame.lift_speed = _speed_for(rise + CLEARANCE, body)


func _speed_for(remaining: float, body: CapsuleBody) -> float:
	return minf(lift_speed, sqrt(2.0 * body.get_gravity().length() * remaining))


## The height of a step just ahead of the body in `wanted`'s direction, or
## zero if there is no liftable step there.
func _step_ahead(body: CapsuleBody, wanted: Vector3, delta: float) -> float:
	var direction := wanted.normalized()
	# Swept from just above the feet: standing, the capsule rests on the floor,
	# and a sweep that starts touching it stops at once.
	var from := body.global_transform.translated(Vector3.UP * CLEARANCE)
	# Something ahead that is too steep to walk up?
	if not _sweep(body, from, direction * (look_ahead + wanted.length() * delta)):
		return 0.0
	if _is_walkable(_normal):
		return 0.0
	# Headroom above the body.
	var lift := Vector3.UP * max_step_height
	if _sweep(body, from, lift):
		lift = _travel
	if lift.y < min_step_height:
		return 0.0
	# Room to move onto the tread at that height; if not, it is a wall.
	var raised := from.translated(lift)
	var across := direction * (look_ahead + tread_depth)
	if _sweep(body, raised, across):
		return 0.0
	# A walkable tread under that spot, no higher than a step.
	if not _sweep(body, raised.translated(across), Vector3.DOWN * (lift.y + 2.0 * CLEARANCE)):
		return 0.0
	if not _is_walkable(_normal):
		return 0.0
	var rise := CLEARANCE + lift.y - _travel.length()
	return rise if rise >= min_step_height and rise <= max_step_height else 0.0


## Sweeps the body's capsule alone from `from` (the body's transform) along
## `motion`. Returns whether it hit something, leaving the travel before the
## hit and the hit surface's normal.
func _sweep(body: CapsuleBody, from: Transform3D, motion: Vector3) -> bool:
	var space := body.get_world_3d().direct_space_state
	var capsule := from * body.collision.transform
	_query.shape = body.collision.shape
	_query.collision_mask = body.collision_mask
	_query.exclude = [body.get_rid()]
	_query.margin = 0.001
	_query.transform = capsule
	_query.motion = motion
	var fractions := space.cast_motion(_query)
	if fractions[1] >= 1.0:
		_travel = motion
		_normal = Vector3.UP
		return false
	_travel = motion * fractions[0]
	_query.transform = capsule.translated(motion * fractions[1])
	_query.motion = Vector3.ZERO
	_normal = space.get_rest_info(_query).get("normal", Vector3.UP)
	return true


func _is_walkable(normal: Vector3) -> bool:
	return normal.angle_to(Vector3.UP) <= deg_to_rad(physical.ground.max_walkable_angle)
