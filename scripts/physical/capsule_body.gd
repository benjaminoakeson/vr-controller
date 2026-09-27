class_name CapsuleBody
extends RigidBody3D

## The player's body: one upright capsule that the world pushes, supports and
## stops, moved by a bounded walking motor.
##
## Rotation is locked on every axis: turning belongs to the rig, and a body
## that tipped would tip the player's sense of up. The node's origin is at the
## feet, so resizing the capsule for a crouch never moves them. Friction is
## zero, so all traction comes from the motor, and "how hard the legs can
## push" lives in one place instead of being split with the contact solver.
##
## Mass, collision layers and top_level are set in the scene. The invariants
## are enforced in _ready, so an inspector edit cannot quietly break them.
## Gravity is read from the physics server; gravity_scale is expected to be 1.

@export var collision: CollisionShape3D
## Looks for headroom before the capsule grows.
@export var ceiling_sensor: ShapeCast3D

@export_group("Shape")
@export_range(0.1, 0.4, 0.01, "suffix:m") var radius := 0.2
## The capsule is never shorter than this, however low the head goes.
@export_range(0.4, 1.2, 0.01, "suffix:m") var min_height := 0.6
## Height changes smaller than this are ignored, so the shape is not rebuilt
## every tick while the head bobs. Also the gap kept below a ceiling.
@export_range(0.0, 0.05, 0.001, "suffix:m") var resize_threshold := 0.01

@export_group("Motor")
## How quickly the motor tries to close the gap to the wanted velocity.
@export_range(0.02, 1.0, 0.01, "suffix:s") var response_time := 0.12
## The most the legs can push. Holding the body on a slope comes out of the
## same budget, so a slope too steep for it is slid down.
@export_range(0.0, 5000.0, 10.0, "suffix:N") var leg_force := 900.0
## The most the body can steer itself in the air, horizontally.
@export_range(0.0, 2000.0, 10.0, "suffix:N") var air_force := 150.0

@export_group("Standing")
## Standing still, the legs keep the body where it stands against light
## contact, like static friction: up to `hold_force` it stays put, so a hand
## resting on a wall does not slide it away. A harder push moves it, with the
## legs braking in proportion to its speed, so the body goes as far as the
## push goes and stops when the push stops: there is no threshold to break
## through. Commanded movement slower than `hold_speed` is followed while
## holding; anything faster walks.
@export_range(0.0, 900.0, 5.0, "suffix:N") var hold_force := 80.0
## How stiffly the light hold keeps its place before it gives.
@export_range(0.0, 100000.0, 500.0, "suffix:N/m") var hold_stiffness := 20000.0
@export_range(0.0, 1.0, 0.01, "suffix:m/s") var hold_speed := 0.2

@export_group("Steps")
## The most the legs can push upward while lifting the body up a step,
## including holding its weight.
@export_range(0.0, 10000.0, 50.0, "suffix:N") var step_force := 2500.0
## How quickly the lift reaches the upward speed it is asked for.
@export_range(0.01, 0.5, 0.01, "suffix:s") var lift_response := 0.05
## How fast the legs lower the body onto ground a step below.
@export_range(0.1, 5.0, 0.05, "suffix:m/s") var step_down_speed := 1.5

## The capsule's height from the feet to its top, in metres.
var height := 0.0
## The motor's force this tick, in newtons.
var motor_force := Vector3.ZERO
## The share of the force the motor asked for that the legs could deliver this
## tick, 0 to 1: below 1 while pushing at the limit.
var drive_share := 1.0

var _capsule: CapsuleShape3D
var _ball: SphereShape3D
var _holding := false
var _anchor := Vector3.ZERO


## Whether the legs are holding the body where it stands (see hold_force).
func is_holding() -> bool:
	return _holding


func _ready() -> void:
	axis_lock_angular_x = true
	axis_lock_angular_y = true
	axis_lock_angular_z = true
	can_sleep = false
	# The motor alone decides how the body slows down; the project's default
	# damping would quietly take a share of every speed (1.2 % at a walk).
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	# With rotation locked the centre of mass does nothing; pinning it at the
	# feet keeps resizing from moving it.
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3.ZERO
	var material := PhysicsMaterial.new()
	material.friction = 0.0
	physics_material_override = material
	_capsule = CapsuleShape3D.new()
	_capsule.radius = radius
	collision.shape = _capsule
	_ball = SphereShape3D.new()
	_ball.radius = radius * 0.9
	ceiling_sensor.shape = _ball
	ceiling_sensor.enabled = false
	ceiling_sensor.add_exception(self)
	_set_height(min_height)


## Puts the feet at `feet`, at rest.
func place_at(feet: Vector3) -> void:
	global_position = feet
	linear_velocity = Vector3.ZERO
	_holding = false


## Resizes the capsule toward `target`: shrinking at once, growing only into
## headroom the ceiling sensor confirms, so it cannot wedge under a ceiling.
func fit_height(target: float) -> void:
	target = maxf(target, min_height)
	if target < height - resize_threshold:
		_set_height(target)
	elif target > height + resize_threshold:
		var room := _headroom(target - height)
		if room > resize_threshold:
			_set_height(height + room)


## Applies the walking motor: one bounded force toward the wanted horizontal
## velocity. On the ground it works along the surface and holds the body
## against the slope, both out of the legs' budget. Lifting up a step, the
## legs also push the body up toward `lift_speed`, out of a separate step
## budget. Stepping down, they lower it at a steady speed instead of letting
## it drop. In the air it can only steer. The engine integrates the force
## over the tick.
func drive(wanted: Vector3, lift_speed: float, ground: GroundSense, delta: float) -> void:
	var gravity := get_gravity()
	if lift_speed > 0.0 or not ground.supported:
		_holding = false
	if lift_speed > 0.0:
		var horizontal := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
		var push := _limited(mass * (wanted - horizontal) / response_time, leg_force)
		var up := clampf(mass * ((lift_speed - linear_velocity.y) / lift_response - gravity.y),
				0.0, step_force)
		motor_force = push + Vector3.UP * up
	elif ground.stepping_down:
		var target := wanted + Vector3.DOWN * step_down_speed
		motor_force = _limited(mass * ((target - linear_velocity) / response_time - gravity),
				leg_force)
	elif ground.supported:
		var normal := ground.normal
		var along_slope := gravity - normal * gravity.dot(normal)
		var relative := linear_velocity - ground.support_velocity
		var along_surface := relative - normal * relative.dot(normal)
		var target := Vector3.ZERO
		if not wanted.is_zero_approx():
			# The same speed along the slope as on the flat, up or down.
			target = wanted.slide(normal).normalized() * wanted.length()
		if _should_hold(target, along_surface):
			motor_force = _limited(_hold_force(target, along_surface, normal, delta)
					- mass * along_slope, leg_force)
		else:
			motor_force = _limited(mass * ((target - along_surface) / response_time - along_slope),
					leg_force)
	else:
		var horizontal := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
		motor_force = _limited(mass * (wanted - horizontal) / response_time, air_force)
	apply_central_force(motor_force)


## Whether the legs should hold the body where it stands: nothing asks it to
## move faster than hold_speed, and it has come to rest (or is already held).
func _should_hold(target: Vector3, along_surface: Vector3) -> bool:
	if target.length() >= hold_speed:
		_holding = false
		return false
	if not _holding and along_surface.length() >= hold_speed:
		return false
	if not _holding:
		_anchor = global_position
		_holding = true
	return true


## The legs standing: the motor's usual braking toward the (slow) commanded
## velocity, plus a light spring toward where the body stands, no stronger
## than hold_force. The spring's anchor moves with any slow command and slips
## along with the body once a push is stronger than it. Together the spring
## and braking are critically damped.
func _hold_force(target: Vector3, along_surface: Vector3, normal: Vector3, delta: float) -> Vector3:
	_anchor += target * delta
	var offset := (_anchor - global_position).slide(normal)
	var slip := hold_force / hold_stiffness
	if offset.length() > slip:
		_anchor -= offset.normalized() * (offset.length() - slip)
		offset = offset.limit_length(slip)
	var braking := mass * (target - along_surface) / response_time
	var extra_damping := maxf(2.0 * sqrt(hold_stiffness * mass) - mass / response_time, 0.0)
	var keeping := (hold_stiffness * offset + extra_damping * (target - along_surface)) \
			.limit_length(hold_force)
	return braking + keeping


## `requested` cut to `limit`, noting in drive_share how much of it survived.
func _limited(requested: Vector3, limit: float) -> Vector3:
	var size := requested.length()
	drive_share = minf(limit / size, 1.0) if size > 1e-6 else 1.0
	return requested.limit_length(limit)


## Sets the body rising at `speed` relative to what it stands on, with one
## impulse. A body already rising faster is left alone.
func jump(speed: float, support_velocity: Vector3) -> void:
	var rising := (linear_velocity - support_velocity).y
	if rising < speed:
		apply_central_impulse(Vector3.UP * (mass * (speed - rising)))


## How far the capsule can grow, up to `rise`, keeping a small gap below
## anything overhead. The sensor's ball sits just inside the capsule's top,
## so the distance it travels is measured from there.
func _headroom(rise: float) -> float:
	var inset := radius - _ball.radius
	var reach := rise + inset + resize_threshold
	ceiling_sensor.position = Vector3.UP * (height - radius)
	ceiling_sensor.target_position = Vector3.UP * reach
	ceiling_sensor.force_shapecast_update()
	if not ceiling_sensor.is_colliding():
		return rise
	var travel := reach * ceiling_sensor.get_closest_collision_safe_fraction()
	return minf(rise, travel - inset - resize_threshold)


func _set_height(value: float) -> void:
	height = value
	_capsule.height = value
	collision.position = Vector3.UP * (value * 0.5)
