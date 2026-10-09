class_name LeafLitter
extends RigidBody3D

## A pile of dead leaves the player can pick up (2026-10-04, at the player's
## request). Grabbed, it is at once a ball of the same leaves with a sphere
## collider, held and thrown like any loose prop. Held with the ground within
## place_reach straight below its centre, a green line runs down to that
## ground; let go then, it is a pile again, lying on the ground where the line
## met it. Let go anywhere else, it stays a ball, to be picked up again.
##
## One body is both. As a pile it is frozen on the Grabbable layer alone,
## meeting nothing (no body looks for that layer; only the hands' grab search
## does), so a hand finds it by its sphere while the player, props and hands
## pass through the leaves. As a ball it is a loose prop. Its origin is the
## pile's middle on the ground, with the sphere resting there.
##
## Burnt down (its Tinder, 2026-10-05), leaves lying on the ground, as a pile or
## a ball at rest, are a heap of ash there, which no hand can pick up and nothing
## meets; the fire burns on, on it. Burnt down off the ground, held or flying,
## nothing is left (decided with the player). The ash grows by ash_growth for
## each fuel the fire burns to nothing, up to ash_growth_most more (the player:
## "It should grow about 10% up to a capped 100% more").

## A ball is a loose prop: on Dynamic (and Grabbable), meeting Static,
## Dynamic, Held, Player, Hands and Enemy (architecture document, section 6.8).
const BALL_LAYER := 2 | Grabbable.GRABBABLE_LAYER
const BALL_MASK := 1 | 2 | 8 | 16 | 32 | 256
## A pile is found by the hands' grab search and meets nothing.
const PILE_LAYER := Grabbable.GRABBABLE_LAYER
const PILE_MASK := 0

enum Form { PILE, BALL, ASH }

@export var grabbable: Grabbable
## The ball's collider; a hand finds the pile by it too.
@export var sphere: CollisionShape3D
@export var pile_model: Node3D
@export var ball_model: Node3D
## The line from a held ball's centre down to where it would lie.
@export var place_line: MeshInstance3D
## What burns the leaves: they turn to ash when it has burnt them down.
@export var tinder: Tinder
## The heap of ash shown once they have, its origin on the ground.
@export var ash_model: Node3D

@export_group("Placing")
## How far below a held ball's centre the ground may be for it to lie there
## when let go, in metres.
@export_range(0.05, 1.0, 0.01, "suffix:m") var place_reach := 0.3
## The steepest ground a pile lies on.
@export_range(0.0, 89.0, 1.0, "radians_as_degrees") var max_slope := deg_to_rad(35.0)
## What a pile lies on: the Static layer.
@export_flags_3d_physics var ground_mask := 1
## How far below a loose ball's centre the ground may be for it to count as
## lying there, burnt down: its radius and a little.
@export_range(0.0, 0.5, 0.005, "suffix:m") var rest_reach := 0.07

@export_group("Ash")
## How much the ash grows for each fuel the fire burns to nothing, as a share
## of its size at first; and the most it grows.
@export_range(0.0, 1.0, 0.01) var ash_growth := 0.1
@export_range(0.0, 3.0, 0.05) var ash_growth_most := 1.0
## How long the ash takes to reach a new size: the time constant of its easing.
@export_range(0.01, 5.0, 0.01, "suffix:s") var grow_time := 0.5

var form := Form.PILE
## Whether the held ball would lie as a pile if let go now; and where: the
## ground straight below its centre, and that ground's normal.
var can_place := false
var place_point := Vector3.ZERO
var place_normal := Vector3.UP
## The ash's size against its size at first, as it grows to.
var ash_size := 1.0

var _ray := PhysicsRayQueryParameters3D.new()


func _ready() -> void:
	grabbable.grabbed.connect(_on_grabbed)
	grabbable.released.connect(_on_released)
	_ray.collision_mask = ground_mask
	_ray.exclude = [get_rid()]
	# Drawn where it is set, in the tick, as the held ball is (Grabbable).
	place_line.top_level = true
	place_line.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	ash_model.visible = false
	tinder.burnt_down.connect(_on_burnt_down)
	tinder.consumed.connect(_on_consumed)
	_lie(global_transform)
	# Only a held ball looks for ground, so the many piles lying about cost no
	# tick of their own; only growing ash eases.
	set_physics_process(false)
	set_process(false)


func _process(delta: float) -> void:
	var shown := lerpf(ash_model.scale.x, ash_size, 1.0 - exp(-delta / grow_time))
	if absf(shown - ash_size) < 1e-4:
		shown = ash_size
		set_process(false)
	ash_model.scale = Vector3.ONE * shown


func _physics_process(_delta: float) -> void:
	can_place = form == Form.BALL and _find_ground(place_reach)
	place_line.visible = can_place
	if can_place:
		var from := sphere.global_position
		place_line.global_transform = Transform3D(Basis.from_scale(Vector3(1.0, from.y - place_point.y, 1.0)),
				(from + place_point) * 0.5)


## The ground within `reach` straight below the ball's centre, if a pile can
## lie on it: place_point and place_normal.
func _find_ground(reach: float) -> bool:
	var from := sphere.global_position
	_ray.from = from
	_ray.to = from + Vector3.DOWN * reach
	var hit := get_world_3d().direct_space_state.intersect_ray(_ray)
	if hit.is_empty() or (hit.normal as Vector3).angle_to(Vector3.UP) > max_slope:
		return false
	place_point = hit.position
	place_normal = hit.normal
	return true


func _on_grabbed(_hand: HandGrab) -> void:
	if form == Form.PILE:
		roll_up()
	set_physics_process(true)


func _on_released(_hand: HandGrab) -> void:
	set_physics_process(false)
	if form == Form.BALL and can_place:
		_lay_down(place_point, place_normal)
	can_place = false
	place_line.visible = false


## Picked up: a ball from this grab on, which Grabbable keeps as the body's
## own layers. Also ejected from an inventory slot, so it falls rather than
## lying fixed in the air (InventoryEject).
func roll_up() -> void:
	form = Form.BALL
	pile_model.visible = false
	ball_model.visible = true
	freeze = false
	grabbable.set_own_layers(BALL_LAYER, BALL_MASK)


## Let go over the ground: a pile again at `point`.
func _lay_down(point: Vector3, normal: Vector3) -> void:
	_lie(_pose_on(point, normal))


## Lying at `point` on ground with `normal`: upright on it, turned as the ball
## was about it.
func _pose_on(point: Vector3, normal: Vector3) -> Transform3D:
	var heading := global_basis.z.slide(normal)
	if heading.length_squared() < 1e-6:
		heading = global_basis.x.slide(normal)
	heading = heading.normalized()
	return Transform3D(Basis(normal.cross(heading), normal, heading), point)


## The leaves are burnt down: ash where they lie on the ground, or nothing.
func _on_burnt_down() -> void:
	if form == Form.PILE:
		_turn_to_ash(global_transform)
	elif grabbable.holders.is_empty() and _find_ground(rest_reach):
		_turn_to_ash(_pose_on(place_point, place_normal))
	else:
		queue_free()


## A heap of ash at `pose`, fixed there, meeting nothing, and no hand's to
## pick up.
func _turn_to_ash(pose: Transform3D) -> void:
	form = Form.ASH
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	freeze = true
	global_transform = pose
	pile_model.visible = false
	ball_model.visible = false
	ash_model.visible = true
	place_line.visible = false
	can_place = false
	set_physics_process(false)
	grabbable.enabled = false
	grabbable.set_own_layers(0, 0)


## The fire has burnt `count` fuels to nothing: the ash grows for each.
func _on_consumed(count: int) -> void:
	ash_size = 1.0 + minf(count * ash_growth, ash_growth_most)
	set_process(true)


## A pile at `pose`, fixed there. Let go just now, it gets the pile's layers
## once the hand is clear of it (Grabbable).
func _lie(pose: Transform3D) -> void:
	form = Form.PILE
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	freeze = true
	global_transform = pose
	pile_model.visible = true
	ball_model.visible = false
	place_line.visible = false
	can_place = false
	grabbable.set_own_layers(PILE_LAYER, PILE_MASK)
