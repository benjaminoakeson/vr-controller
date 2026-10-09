class_name LootDrop
extends Node

## Drops loot when its object's health runs out (2026-10-02): `count` of the
## `loot` scene, laid in a ring around the middle of the object's meshes, or
## around `centre`. Each starts still and clear of the others and of everything
## but the object, so nothing pushes it out; once the object is gone, it falls.
## An ore vein drops four of its ore; a tree's lone segment drops logs or a
## stick round its middle (TreeChop).
##
## Its object is its parent. The loot goes to the object's parent, so it stays
## when the object frees itself in the same tick.

## Emitted once the loot is in the level.
signal dropped(items: Array[Node3D])

## A drop whose place in the ring is taken (by a weapon sunk into the object,
## say) is tried up to this many spacings higher, and left at the last.
const _RISES := 8

## The object's Health: the loot drops when it runs out.
@export var health: Health
## What drops: a scene whose root is a Node3D, usually a RigidBody3D.
@export var loot: PackedScene
## How many drop.
@export_range(0, 32, 1) var count := 1
## The space kept between two drops, in metres.
@export_range(0.0, 0.2, 0.005, "suffix:m") var gap := 0.02
## Where the ring is laid round, if set; otherwise the middle of the object's
## meshes.
@export var centre: Node3D
## Whether each drop is laid on its side, its length (its Y) level along the
## ring: for long loot, logs and sticks, which laid standing land on their ends
## and stay standing.
@export var lay_down := false


func _ready() -> void:
	if health == null:
		push_error("LootDrop: no health is assigned.")
		return
	health.depleted.connect(_drop)


func _drop() -> void:
	var object := get_parent() as Node3D
	if loot == null or count <= 0 or object == null:
		return
	var parent := object.get_parent()
	var frame := (parent as Node3D).global_transform if parent is Node3D else Transform3D.IDENTITY
	# The object's own bodies are going with it, so they do not block a drop:
	# the object itself, if it is one (a felled piece of a tree), and every one
	# below it.
	var own: Array[RID] = []
	if object is CollisionObject3D:
		own.append((object as CollisionObject3D).get_rid())
	for body in object.find_children("*", "CollisionObject3D", true, false):
		own.append((body as CollisionObject3D).get_rid())
	var space := object.get_world_3d().direct_space_state
	var items: Array[Node3D] = []
	for i in count:
		items.append(loot.instantiate() as Node3D)
	# A ring whose neighbours are a spacing apart, so no two drops overlap:
	# each lies within its reach of its origin, however it is turned.
	var spacing := 2.0 * reach_of(items[0]) + gap
	var ring := spacing / (2.0 * sin(PI / count)) if count > 1 else 0.0
	var facing := Basis(Vector3.UP, object.global_rotation.y)
	var middle := centre.global_position if is_instance_valid(centre) else _middle(object)
	for i in count:
		var angle := TAU * (i + 0.5) / count
		var pose := Transform3D(facing * Basis(Vector3.UP, -angle),
				middle + facing * Vector3(cos(angle), 0.0, sin(angle)) * ring)
		if lay_down:
			# Turned about the line out from the middle: its Y goes along the ring.
			pose.basis = pose.basis * Basis(Vector3.RIGHT, PI / 2.0)
		var rises := 0
		while rises < _RISES and not is_clear(items[i], pose, space, own):
			pose.origin.y += spacing
			rises += 1
		items[i].transform = frame.affine_inverse() * pose
		parent.add_child(items[i], true)
	dropped.emit(items)


# The middle of the object's meshes, in world space; its origin if it has none.
static func _middle(object: Node3D) -> Vector3:
	var meshes := object.find_children("*", "MeshInstance3D", true, false)
	if meshes.is_empty():
		return object.global_position
	var bounds := AABB()
	for i in meshes.size():
		var mesh := meshes[i] as MeshInstance3D
		var box := mesh.global_transform * mesh.get_aabb()
		bounds = box if i == 0 else bounds.merge(box)
	return bounds.get_center()


# How far `item`'s collision shapes reach from its origin, in metres.
static func reach_of(item: Node3D) -> float:
	var reach := 0.0
	for child in item.get_children():
		var shape := child as CollisionShape3D
		if shape == null or shape.shape == null:
			continue
		var outline := shape.shape.get_debug_mesh()
		if outline.get_surface_count() == 0:
			continue
		for point: Vector3 in outline.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
			reach = maxf(reach, (shape.transform * point).length())
	return reach


# Whether `item` at `pose` would meet nothing it collides with, the bodies in
# `ignore` aside.
static func is_clear(item: Node3D, pose: Transform3D, space: PhysicsDirectSpaceState3D,
		ignore: Array[RID]) -> bool:
	var body := item as CollisionObject3D
	if body == null:
		return true
	var query := PhysicsShapeQueryParameters3D.new()
	query.collision_mask = body.collision_mask
	query.exclude = ignore
	for child in body.get_children():
		var shape := child as CollisionShape3D
		if shape == null or shape.shape == null or shape.disabled:
			continue
		query.shape = shape.shape
		query.transform = pose * shape.transform
		if not space.intersect_shape(query, 1).is_empty():
			return false
	return true
