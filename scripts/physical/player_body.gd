class_name PlayerBody
extends CharacterBody3D

## The physical layer's body: where the world lets the player be.
##
## The static skeleton answers "where would this person's body be" and never
## touches the world. This answers the other question. It is a capsule from
## the floor to the headset that collides, falls, climbs and is pushed back,
## and its one output is the rig: every tick the XR origin is moved by
## whatever this body moved, so the headset, the controllers and the skeleton
## all go with it. The body sits beside the rig rather than under it because
## the rig is what it moves - a child of the thing it moves would spend its
## life compensating for itself.
##
## Two motions are folded together each tick. One is the player's own: they
## walk across the room and the headset moves, so the body walks under it,
## and if a wall stops the body the rig is pulled back so the headset stays
## in the world. The other is locomotion: a force from the stick, friction,
## gravity, slopes and stairs, integrated into a velocity the body moves by.
##
## Grounded is decided by a ball. It is dropped from the headset straight
## down through the body, and if it meets nothing by the feet the player is
## in the air. Where it lands says how the ground lies, and the walk vector
## follows that surface: level on the flat, uphill and downhill on a slope,
## at the same speed either way, since it is speed along the ground that is
## held to the walk speed rather than speed across the map.

## The rig this body moves, the headset it stands under, the hand that holds
## the stick, and the other one, for running.
@export var origin: XROrigin3D
@export var hmd: XRCamera3D
@export var left_controller: XRController3D
@export var right_controller: XRController3D
## The skeleton to tell where the body is being carried, so its feet can
## stride to match. Optional: without it the feet infer what they can.
@export var skeleton: StaticSkeleton
## The capsule and the ball. Their shapes are made here so that nothing in
## the scene is shared by mistake.
@export var collision: CollisionShape3D
@export var ground_cast: ShapeCast3D

@export_group("Body")
## The capsule's radius. The ball has the same, less a little so that a wall
## the body is leaning on cannot be mistaken for the floor.
@export var body_radius := 0.2
## Shorter than this and the capsule stops shrinking: a headset on the floor
## is still a person.
@export var min_body_height := 0.6
## How far below the feet the ball may still find ground and call it stood
## on. Floor snapping keeps the feet closer than this on the way down a
## slope or a step.
@export var ground_margin := 0.05

@export_group("Walking")
## The stick, and how much of its throw is ignored.
@export var move_action := &"primary"
@export var stick_deadzone := 0.15
## Speed along the ground at full stick.
@export var max_walk_speed := 3.0
## Force per unit mass toward the wanted speed, and the force that brings a
## body with no input to rest. Both act along the ground.
@export var walk_acceleration := 30.0
@export var ground_friction := 25.0
## What the stick can do in the air. Momentum is kept; this only steers it.
@export var air_acceleration := 6.0
## Steeper than this is not ground to stand on: the body slides.
@export var max_slope_degrees := 45.0

@export_group("Running")
## Running is pumping the arms. With both hands closed into fists and the
## stick pushed, how hard the hands are being swung up and down sets how much
## faster than a walk the body goes - not a switch, a throttle, so a jog and
## a sprint feel like what the arms are doing.
##
## How far the grip must be squeezed for a hand to count as a fist.
@export var run_grip_threshold := 0.7
## Speed along the ground at full stick and a full pump.
@export var max_run_speed := 6.0
## The pump: the hands' vertical speed, averaged over both and over time.
## Below the first of these it is not running; at the second the run is at
## full speed.
@export var run_pump_start := 0.6
@export var run_pump_full := 2.5
## How quickly the run follows the pumping, per second. Slow enough to see
## through a hand at the top of its swing, quick enough to answer a change.
@export var run_smoothing := 4.0
@export var grip_action := &"grip"
## The tallest step the body walks straight up, and drops straight down.
@export var max_step_height := 0.3
@export var gravity_scale := 1.0

## Whether the ball found ground under the feet this tick, and which way
## that ground faces. Exposed for whatever wants to know.
var grounded := false
var ground_normal := Vector3.UP
## How much of a run the arms are asking for, 0 for a walk to 1 for flat out.
var run_factor := 0.0

var _pump := 0.0
var _left_hand_height := 0.0
var _right_hand_height := 0.0
# Whether the ball touched anything at all, ground or not, or the capsule
# was resting against something after its last move. A body on the edge of
# a step reads as too steep to stand on while its rounded bottom rides over,
# and a step taller than the capsule's radius perches it where the narrower
# ball meets nothing at all. Neither must stop it climbing.
var _touching := false
# Whether the step-up placed the body this tick. A step's edge is a wall by
# its normal, but a wall being climbed must not take the push that climbs it.
var _stepped := false

var _gravity := 9.8
# The velocity this layer means, kept apart from `velocity`: move_and_slide
# rewrites that one against whatever it hit, and integrating from the
# rewritten value loses the downhill component on a slope every tick and
# loses all momentum against a step's edge, where a body needs to keep
# pushing to climb.
var _walking := Vector3.ZERO
var _capsule: CapsuleShape3D
var _ball: SphereShape3D


func _ready() -> void:
	if origin == null or hmd == null or collision == null or ground_cast == null:
		push_error("PlayerBody: origin, hmd, collision and ground_cast must all be assigned.")
		set_physics_process(false)
		return

	# Before the skeleton solves, so it sees the rig where this tick put it
	# and knows what this tick asked of the body.
	process_physics_priority = StaticSkeleton.SOLVE_PRIORITY - 10
	if skeleton != null:
		skeleton.ground_probe = probe_ground
	_gravity = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
	_capsule = CapsuleShape3D.new()
	_capsule.radius = body_radius
	collision.shape = _capsule
	_ball = SphereShape3D.new()
	_ball.radius = body_radius * 0.9
	ground_cast.shape = _ball
	ground_cast.enabled = false
	ground_cast.add_exception(self)

	up_direction = Vector3.UP
	floor_max_angle = deg_to_rad(max_slope_degrees)
	floor_snap_length = max_step_height
	floor_stop_on_slope = true

	# Feet on the rig's floor, under the headset.
	global_position = Vector3(
			hmd.global_position.x, origin.global_position.y, hmd.global_position.z)


func _physics_process(delta: float) -> void:
	var height := _fit_body()
	_follow_headset()
	_check_ground(height)
	_walk(delta)

	var before := global_position
	_stepped = false
	if _touching:
		_step_up(delta)
	move_and_slide()
	# Ground the ball found but the body is not yet resting on - the end of a
	# drop, the far side of a step - is snapped to. Gravity is off while
	# grounded, so without this the body would hover inside the margin.
	if grounded and not is_on_floor():
		apply_floor_snap()
	# In the air a wall takes the momentum that was going into it. On the
	# ground the walk velocity is left alone, since the stick re-drives it
	# every tick - and so is a step being climbed, whose edge reads as a
	# wall to the body perched on it but needs the push to be climbed.
	if not grounded and not _stepped:
		for i in get_slide_collision_count():
			var normal := get_slide_collision(i).get_normal()
			if normal.angle_to(Vector3.UP) > floor_max_angle and _walking.dot(normal) < 0.0:
				_walking = _walking.slide(normal)
	# Whatever the world did to the body, the rig goes with it.
	origin.global_position += global_position - before


## The capsule spans from the feet to the headset, whatever the player's
## height is right now. The body's own origin is at the feet.
func _fit_body() -> float:
	var height := maxf(hmd.position.y, min_body_height)
	_capsule.height = height
	collision.position = Vector3(0.0, height * 0.5, 0.0)
	return height


## Walks the body under the headset. The player moved across the room, so
## the body goes where they went - and where the world stops it, the rig is
## pulled back by the same amount, so the headset stays on this side of the
## wall in the world even though the player's head is through it in the room.
func _follow_headset() -> void:
	var offset := hmd.global_position - global_position
	offset.y = 0.0
	if offset.length_squared() < 1e-8:
		return
	var hit := move_and_collide(offset)
	if hit != null:
		origin.global_position -= offset - hit.get_travel()


## Drops the ball from the headset. Grounded means it met something by the
## feet that is level enough to stand on, and that something's facing is the
## ground the walk vector follows.
func _check_ground(height: float) -> void:
	ground_cast.global_position = hmd.global_position
	ground_cast.target_position = Vector3.DOWN * (height - _ball.radius + ground_margin)
	ground_cast.force_shapecast_update()
	grounded = false
	ground_normal = Vector3.UP
	_touching = ground_cast.is_colliding() or is_on_wall() or is_on_floor()
	if ground_cast.is_colliding():
		var normal := ground_cast.get_collision_normal(0)
		if normal.angle_to(Vector3.UP) <= floor_max_angle:
			grounded = true
			ground_normal = normal
	if skeleton != null:
		skeleton.body_grounded = grounded


## The world's answer to the skeleton's "where is the floor here": the first
## thing a ray from `from` down to `to` meets, other than this body, as a
## Dictionary with `position` and `normal`, or empty. The skeleton never
## collides with anything itself; it asks, and this is what answers.
func probe_ground(from: Vector3, to: Vector3) -> Dictionary:
	var ray := PhysicsRayQueryParameters3D.create(from, to)
	ray.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(ray)
	if hit.is_empty():
		return {}
	return {"position": hit.position, "normal": hit.normal}


## The stick as a direction over the ground, in the headset's facing.
func _wish_direction() -> Vector3:
	if left_controller == null:
		return Vector3.ZERO
	var stick := left_controller.get_vector2(move_action)
	var throw := stick.length()
	if throw < stick_deadzone:
		return Vector3.ZERO
	stick = stick / throw * inverse_lerp(stick_deadzone, 1.0, minf(throw, 1.0))

	# Forward is where the headset looks, flattened. Looking straight down
	# or up leaves no forward to flatten, so the head's up axis stands in.
	var forward := -hmd.global_basis.z
	if absf(forward.y) > 0.75:
		forward = hmd.global_basis.y * -signf(forward.y)
	forward = forward.slide(Vector3.UP).normalized()
	var right := forward.cross(Vector3.UP)
	return forward * stick.y + right * stick.x


## How hard the arms are pumping: each hand's vertical speed in the rig's own
## space, so the rig being carried is not mistaken for a swing, averaged over
## both hands and smoothed over time. Reads as zero unless both hands are
## fists, so opening a hand ends the run.
func _measure_pump(delta: float) -> void:
	var speed := 0.0
	if left_controller != null and right_controller != null and delta > 0.0:
		var left := left_controller.position.y
		var right := right_controller.position.y
		if _fists_closed():
			speed = (absf(left - _left_hand_height) + absf(right - _right_hand_height)) \
					* 0.5 / delta
		_left_hand_height = left
		_right_hand_height = right
	_pump = lerpf(_pump, speed, 1.0 - exp(-run_smoothing * delta))


## Whether both hands are closed into fists.
func _fists_closed() -> bool:
	return left_controller.get_float(grip_action) >= run_grip_threshold \
			and right_controller.get_float(grip_action) >= run_grip_threshold


## Integrates the tick's forces into the velocity.
func _walk(delta: float) -> void:
	var wish := _wish_direction()
	_measure_pump(delta)
	# Only a moving body runs: pumping the arms while standing is exercise.
	run_factor = 0.0 if wish.is_zero_approx() \
			else clampf(inverse_lerp(run_pump_start, run_pump_full, _pump), 0.0, 1.0)
	var top_speed := lerpf(max_walk_speed, max_run_speed, run_factor)
	if skeleton != null:
		skeleton.commanded_travel = wish * top_speed
	if grounded:
		# The wanted velocity lies along the ground: the stick's heading, laid
		# onto the surface, which takes it uphill or downhill by however much
		# the ground rises. Its length is the walk speed whichever way it
		# points, so a slope is neither slower up nor faster down. Gravity
		# does nothing here - the ground is holding the body up.
		var target := Vector3.ZERO
		if not wish.is_zero_approx():
			target = wish.slide(ground_normal).normalized() * (wish.length() * top_speed)
		var rate := ground_friction if wish.is_zero_approx() else walk_acceleration
		# Landing takes whatever was heading into the ground out first, so a
		# fall does not go on pressing into the floor.
		_walking = _walking.slide(ground_normal).move_toward(target, rate * delta)
	else:
		# In the air the stick only steers what momentum there is, level,
		# and gravity does the rest.
		var level := Vector3(_walking.x, 0.0, _walking.z)
		if not wish.is_zero_approx():
			level = level.move_toward(wish * top_speed, air_acceleration * delta)
		_walking = Vector3(level.x, _walking.y - _gravity * gravity_scale * delta, level.z)
	velocity = _walking


## Stairs. When the tick's motion would run into something that is not
## ground, look for a tread: a ray dropped just past the obstacle, from a
## step's height down to the feet. Walkable ground there, no higher than a
## step, means this is a step and not a wall - so the body is lifted, moved
## by the tick's motion, and set down on whatever is under it. That is often
## the tread's edge, met by the capsule's rounded bottom at a steep angle,
## and the next few ticks slide it up and over. If there is no tread the body
## stays where it was, for move_and_slide to stop it like any wall.
func _step_up(delta: float) -> void:
	var motion := Vector3(velocity.x, 0.0, velocity.z) * delta
	if motion.length_squared() < 1e-10:
		return
	var blocked := move_and_collide(motion, true)
	if blocked == null or blocked.get_normal().angle_to(Vector3.UP) <= floor_max_angle:
		return

	var start := global_position
	var up := move_and_collide(Vector3.UP * max_step_height, true)
	var lift := max_step_height if up == null else up.get_travel().y
	if lift < ground_margin:
		return

	# The tread, if there is one, is just past where the body was stopped.
	var beyond := start + motion.normalized() * (body_radius + ground_margin)
	var ray := PhysicsRayQueryParameters3D.create(
			beyond + Vector3.UP * (lift + ground_margin), beyond + Vector3.DOWN * ground_margin)
	ray.exclude = [get_rid()]
	var tread: Dictionary = get_world_3d().direct_space_state.intersect_ray(ray)
	if tread.is_empty() or tread.normal.angle_to(Vector3.UP) > floor_max_angle:
		return
	var rise: float = tread.position.y - start.y
	if rise > max_step_height or rise < ground_margin:
		return

	global_position.y += lift
	var across := move_and_collide(motion, true)
	var travelled := motion if across == null else across.get_travel()
	if travelled.length_squared() < 1e-10:
		global_position = start
		return
	global_position += travelled
	var down := move_and_collide(Vector3.DOWN * (lift + ground_margin), true)
	if down == null:
		global_position = start
		return
	global_position += down.get_travel()
	_stepped = true
	# The step placed the body; nothing gravity or an edge has put into the
	# vertical velocity should now pull it back down or bounce it up.
	_walking.y = 0.0
	velocity = _walking
