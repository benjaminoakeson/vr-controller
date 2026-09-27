class_name ViewFade
extends MeshInstance3D

## Darkens the view as the head goes into a surface the body could not follow
## it through, and blacks it out while the physical layer relocates the player.
##
## It is a black ball around the head, drawn over everything. It reads the
## physical layer's snapshot and writes nothing back. While clear it is
## hidden, so it costs nothing to draw.

## Head depth past the surface at which the view is fully black.
@export_range(0.01, 0.5, 0.01, "suffix:m") var full_depth := 0.1
## How long going fully black takes. The recovery module waits at least this
## long before it moves anything.
@export_range(0.01, 1.0, 0.01, "suffix:s") var darken_time := 0.15
## How long clearing from fully black takes.
@export_range(0.01, 2.0, 0.01, "suffix:s") var clear_time := 0.3

## How dark the view is now, 0 to 1.
var alpha := 0.0

var _head: Node3D
var _physical: PlayerPhysical
var _material: StandardMaterial3D


func attach(head: Node3D, physical: PlayerPhysical) -> void:
	_head = head
	_physical = physical


func _ready() -> void:
	_material = material_override as StandardMaterial3D
	visible = false
	if _head == null or _physical == null or _material == null:
		push_error("ViewFade: attach() must be called first, with a StandardMaterial3D override.")
		set_process(false)


func _process(delta: float) -> void:
	var state := _physical.snapshot
	var target := maxf(clampf(state.head_obstruction / full_depth, 0.0, 1.0), state.blackout)
	var time := darken_time if target > alpha else clear_time
	alpha = move_toward(alpha, target, delta / time)
	visible = alpha > 0.001
	if visible:
		global_position = _head.global_position
		_material.albedo_color = Color(0.0, 0.0, 0.0, alpha)
