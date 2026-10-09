class_name SparkIgniter
extends Node

## Lights tinder near its sparks (2026-10-05): the flint's. Every burst its
## StrikeSparks throws lights the tinder within `reach` of where the sparks
## leave, at once, whichever way they fly (decided with the player: near, one
## strike). The sparks stay visual only; this is the rule they light by.

## Emitted for each tinder a burst lit.
signal ignited(tinder: Tinder)

## The most bodies one burst looks at.
const _MAX_FOUND := 16

## The sparks that light.
@export var sparks: StrikeSparks
## How near the strike point tinder must be to light: any part of its shapes
## within this.
@export_range(0.0, 2.0, 0.01, "suffix:m") var reach := 0.3
## Where tinder is looked for: Dynamic, Grabbable (litter piles lie on it
## alone) and Held.
@export_flags_3d_physics var tinder_mask := 2 | 4 | 8

var _query := PhysicsShapeQueryParameters3D.new()


func _ready() -> void:
	if sparks == null:
		push_error("SparkIgniter: no sparks are assigned.")
		return
	var sphere := SphereShape3D.new()
	sphere.radius = reach
	_query.shape = sphere
	_query.collision_mask = tinder_mask
	sparks.sparked.connect(_on_sparked)


func _on_sparked(point: Vector3, _direction: Vector3, _strength: float) -> void:
	var holder := get_parent() as Node3D
	if holder == null or not holder.is_inside_tree():
		return
	_query.transform = Transform3D(Basis.IDENTITY, point)
	for hit in holder.get_world_3d().direct_space_state.intersect_shape(_query, _MAX_FOUND):
		var tinder := Tinder.of(hit.collider)
		if tinder != null and tinder.ignite():
			ignited.emit(tinder)
