class_name GroundSense
extends Node

## Decides once per tick whether the ground is holding the body up. Every
## system reads this one result; nothing else asks where the floor is under
## the body.
##
## A ball a little smaller than the capsule is swept down from the centre of
## its lower hemisphere, so it never starts touching a wall the body leans on.
## A hit counts as support when it is close enough under the feet, flat enough
## to stand on, and the body is not moving away from it faster than a jump.
##
## Just after walking off an edge, walkable ground a step's height below means
## the body is stepping down, not falling: the legs lower it (see CapsuleBody)
## and the skeleton keeps its feet. A jump never counts as stepping down, nor
## does a body lifted above where it last stood (its hands vaulting it). This
## looks straight down from the body's centre with a ray: while the capsule's
## round bottom rolls over the edge, a ball sweep would meet the edge's corner
## first and read it as too steep.
##
## It also answers the static skeleton's "where is the floor here", against
## the level only, so reference feet never stand on loose props.

const STATIC_LAYER := 1

@export var sensor: ShapeCast3D
## How far below the feet ground still counts as holding the body up.
@export_range(0.0, 0.3, 0.005, "suffix:m") var support_distance := 0.08
## Steeper than this is not ground to stand on.
@export_range(0.0, 89.0, 1.0, "suffix:°") var max_walkable_angle := 45.0
## Moving away from the ground faster than this is leaving it, not standing on it.
@export_range(0.0, 5.0, 0.05, "suffix:m/s") var max_separation_speed := 0.5
## Ground this far below the feet, just after leaving support, is a step down.
@export_range(0.0, 0.6, 0.01, "suffix:m") var step_down_reach := 0.3
## How long after leaving support a step down can still begin.
@export_range(0.0, 1.0, 0.01, "suffix:s") var step_down_grace := 0.25

var supported := false
## Whether the body is being lowered onto ground a step below.
var stepping_down := false
var normal := Vector3.UP
## Velocity of whatever the body stands on, in m/s.
var support_velocity := Vector3.ZERO
## Distance from the feet down to the ground found, in metres; INF if none.
var gap := INF

var _body: CapsuleBody
var _ball: SphereShape3D
var _inset := 0.0
var _probe: PhysicsRayQueryParameters3D
var _step_ray: PhysicsRayQueryParameters3D
var _since_supported := INF
var _jumped := false
var _support_height := 0.0


func attach(body: CapsuleBody) -> void:
	_body = body


func _ready() -> void:
	_ball = SphereShape3D.new()
	_ball.radius = _body.radius * 0.9
	_inset = _body.radius - _ball.radius
	sensor.shape = _ball
	sensor.enabled = false
	sensor.add_exception(_body)
	sensor.position = Vector3.UP * _body.radius
	_probe = PhysicsRayQueryParameters3D.new()
	_probe.collision_mask = STATIC_LAYER
	_probe.exclude = [_body.get_rid()]
	_step_ray = PhysicsRayQueryParameters3D.new()
	_step_ray.collision_mask = sensor.collision_mask
	_step_ray.exclude = [_body.get_rid()]


## Sweeps under the body and classifies what it finds.
func sense(delta: float) -> void:
	supported = false
	stepping_down = false
	normal = Vector3.UP
	support_velocity = Vector3.ZERO
	gap = INF
	if _sweep(support_distance):
		var separating := (_body.linear_velocity - support_velocity).dot(normal)
		supported = _walkable() and separating <= max_separation_speed
	if supported:
		_since_supported = 0.0
		_jumped = false
		_support_height = _body.global_position.y
		return
	_since_supported += delta
	if _jumped or _since_supported > step_down_grace or _body.linear_velocity.y > 0.1 \
			or _body.global_position.y > _support_height + 0.01:
		return
	var feet := _body.global_position
	_step_ray.from = feet + Vector3.UP * _inset
	_step_ray.to = feet + Vector3.DOWN * step_down_reach
	var hit := _body.get_world_3d().direct_space_state.intersect_ray(_step_ray)
	if hit.is_empty():
		return
	normal = hit.normal
	gap = feet.y - hit.position.y
	if hit.collider is RigidBody3D:
		support_velocity = (hit.collider as RigidBody3D).linear_velocity
	stepping_down = _walkable()


## Marks the body as having jumped, so leaving the ground is not a step down.
func note_jump() -> void:
	_jumped = true


## Sweeps down to `reach` below the feet; true if something was hit, with
## `gap`, `normal` and `support_velocity` set from it.
func _sweep(reach: float) -> bool:
	sensor.target_position = Vector3.DOWN * (_inset + reach)
	sensor.force_shapecast_update()
	if not sensor.is_colliding():
		return false
	gap = (_inset + reach) * sensor.get_closest_collision_safe_fraction() - _inset
	normal = sensor.get_collision_normal(0)
	var below := sensor.get_collider(0)
	if below is RigidBody3D:
		support_velocity = (below as RigidBody3D).linear_velocity
	return true


func _walkable() -> bool:
	return normal.angle_to(Vector3.UP) <= deg_to_rad(max_walkable_angle)


## The static skeleton's floor query: the first level surface a ray from
## `from` down to `to` meets, as {position, normal}, or empty.
func probe_ground(from: Vector3, to: Vector3) -> Dictionary:
	_probe.from = from
	_probe.to = to
	var hit := _body.get_world_3d().direct_space_state.intersect_ray(_probe)
	if hit.is_empty():
		return {}
	return {"position": hit.position, "normal": hit.normal}
