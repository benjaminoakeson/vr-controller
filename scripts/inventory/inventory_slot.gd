class_name InventorySlot
extends Area3D

## A slot holding a stack of one InventoryItem, floating where it is placed on
## its source (2026-10-06, at the player's request; documents/inventory.md).
##
## - It shows as clear glass, a flat bubble (2026-10-07; a flat pane at first)
##   whose face is a rounded square, its depth behind, always turned to face
##   the player: empty, nothing in it; holding something, the item's model and,
##   in its top-right corner, how many.
## - Its zone is a ball (its Zone shape) on the Interface layer, which nothing
##   meets. A hand whose palm's grab point is in the zone selects it, without a
##   button (HandGrab finds and touches it each tick): it grows by hover_scale.
## - A hand that grips in it takes one out: the item appears in the hand, held
##   as if picked up (HandGrab). A hand that lets go of a Storable item in it,
##   holding it alone, puts it in, if the slot is empty or holds that item and
##   is not full; anything else falls as it would.
## - It moves with its source, which it is placed on (a child of). A slot that
##   is destroyed, or whose source is (freed by queue_free), ejects what it
##   holds where it was (InventoryEject). Leaving the tree any other way (the
##   level unloading, the slot moved elsewhere) ejects nothing.
## - A faint line runs from it to its source's origin, for placing slots.
##
## Taken out or ejected, an item goes into the source's parent (as LootDrop's
## loot goes into the object's parent), so it stays when the source goes.

## The Interface layer (layer 7): slots' zones, which only the hands' slot
## search looks for.
const ZONE_LAYER := 64

## What the slot is attached to: its parent if unset.
@export var source: Node3D
## What it holds, and how many (it starts with these).
@export var item: InventoryItem
@export_range(0, 9999, 1) var count := 0

@export_group("Look")
## The glass's side, in metres.
@export_range(0.05, 0.5, 0.005, "suffix:m") var size := 0.15
## How deep the glass bubble is, front to back, in metres: it reaches back
## from where its face is, and the item sits in its middle.
@export_range(0.0, 0.2, 0.001, "suffix:m") var depth := 0.035
## How round the glass's corners are, face on: their radius, in metres, from 0
## (square) to half of size (round). The count stays inside the corner.
@export_range(0.0, 0.25, 0.001, "suffix:m") var corner_radius := 0.025
## How much bigger the slot shows while a hand is in it.
@export_range(1.0, 2.0, 0.05) var hover_scale := 1.25
## How quickly it grows and shrinks: the time constant of its easing, in
## seconds (0: at once).
@export_range(0.0, 0.5, 0.01, "suffix:s") var grow_time := 0.05
## How much of the glass's face the item's model fills, across its larger
## side.
@export_range(0.1, 1.0, 0.05) var model_fill := 0.7
## Whether the line to its source is drawn.
@export var show_source_line := true

@export_group("Parts")
@export var zone: CollisionShape3D
## Turned to face the player each frame; the pane, the model and the count.
@export var face: Node3D
@export var glass: MeshInstance3D
@export var model_holder: Node3D
@export var count_label: Label3D
@export var source_line: MeshInstance3D

var _touched_tick := -2
var _shown_scale := 1.0
var _shown_item: InventoryItem
var _model: Node3D
var _line_to := Vector3.INF


func _ready() -> void:
	if source == null:
		source = get_parent() as Node3D
	face.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	# The bubble mesh is one unit across each way.
	glass.scale = Vector3(size, size, maxf(depth, 0.001))
	glass.position = Vector3(0.0, 0.0, -depth * 0.5)
	model_holder.position = Vector3(0.0, 0.0, -depth * 0.5)
	var corner := _round_corners()
	count_label.position = Vector3(corner, corner, 0.01)
	source_line.visible = show_source_line
	if count <= 0:
		item = null
		count = 0
	_show()


func _process(delta: float) -> void:
	var target := hover_scale if selected() else 1.0
	_shown_scale = target if grow_time <= 0.0 else lerpf(_shown_scale, target, 1.0 - exp(-delta / grow_time))
	var turn := face.global_basis.orthonormalized()
	var camera := get_viewport().get_camera_3d()
	if camera != null:
		var to := camera.global_position - face.global_position
		if to.length_squared() > 1e-6 and absf(to.normalized().y) < 0.999:
			turn = Basis.looking_at(to, Vector3.UP, true)
	face.global_basis = turn * _shown_scale
	if show_source_line and is_instance_valid(source):
		_draw_line_to(global_transform.affine_inverse() * source.global_position)


func _exit_tree() -> void:
	if item == null or count <= 0 or not _destroyed():
		return
	var world := _world()
	if world == null:
		return
	var eject := InventoryEject.new()
	eject.item = item
	eject.count = count
	eject.at = global_position
	count = 0
	# Deferred: the source's parent is busy taking the source out, if it is
	# the source that is going.
	world.add_child.call_deferred(eject)


## A hand is in the zone this tick.
func touch() -> void:
	_touched_tick = Engine.get_physics_frames()


## Whether a hand is in the zone (touched it this tick or the last).
func selected() -> bool:
	return Engine.get_physics_frames() - _touched_tick <= 1


## The zone's radius, in metres.
func radius() -> float:
	var ball := zone.shape as SphereShape3D
	return ball.radius if ball != null else 0.0


## Whether `point` is within the zone, or `margin` beyond it.
func contains(point: Vector3, margin := 0.0) -> bool:
	return global_position.distance_to(point) <= radius() + margin


## Whether the slot would take `body` in now: a Storable that may be stored,
## into an empty slot or one holding its item and not full.
func accepts(body: Node) -> bool:
	var storable := Storable.of(body)
	if storable == null or not storable.can_store():
		return false
	if item == null or count <= 0:
		return true
	return storable.item == item and count < item.max_stack


## Takes `body` in, if it accepts it: one more of its item, and the body is
## gone. Whether it did.
func store(body: RigidBody3D) -> bool:
	if not accepts(body):
		return false
	var grabbable := Grabbable.of(body)
	if grabbable != null:
		# Nothing grabs it in the rest of this tick, before it goes.
		grabbable.enabled = false
	item = Storable.of(body).item
	count += 1
	body.queue_free()
	_show()
	return true


## Takes one out, into a hand whose grab point is at `at`, whose fist runs along
## `along` and whose palm faces `out` (world space, at right angles): the
## item's prop lies across the palm as a log or a stick is held, its longest
## side along the fist and its thinnest on the palm, its shapes' middle on the
## palm's line out from `at` and their surface on `at`. (Turned as the slot
## shows it, a log met the palm by a corner 7 cm from the grab point.) Its
## transform is set before it enters the tree, so the physics server has it
## there this tick. Null if the slot is empty.
func take(at: Vector3, along: Vector3, out: Vector3) -> RigidBody3D:
	if item == null or count <= 0:
		return null
	var scene := item.packed_scene()
	var world := _world()
	if scene == null or world == null:
		return null
	var body := scene.instantiate() as RigidBody3D
	if body == null:
		return null
	var bounds := _shape_bounds(body)
	var middle := bounds.get_center()
	var turn := _in_hand(bounds.size, along, out)
	# The palm's facing, square to the fist.
	var palm := (out - along.normalized() * out.dot(along.normalized())).normalized()
	var reach := _support(body, middle, turn.inverse() * -palm)
	var pose := Transform3D(turn, at + palm * reach - turn * middle)
	var frame := (world as Node3D).global_transform if world is Node3D else Transform3D.IDENTITY
	body.transform = frame.affine_inverse() * pose
	world.add_child(body)
	count -= 1
	if count <= 0:
		count = 0
		item = null
	_show()
	return body


# Gives the glass corners of corner_radius: its own bubble mesh, unless the
# scene's (shared by every slot) already has them. Where the count goes: its
# top-right corner, just inside the glass's corner on the diagonal.
func _round_corners() -> float:
	var exponent := SlotBubbleMesh.outline_exponent_for(corner_radius / (size * 0.5))
	var bubble := glass.mesh as SlotBubbleMesh
	if bubble != null and absf(bubble.outline_exponent - exponent) > 0.005:
		bubble = bubble.duplicate() as SlotBubbleMesh
		bubble.outline_exponent = exponent
		glass.mesh = bubble
	return size * 0.5 * SlotBubbleMesh.diagonal_reach(exponent) * 0.97


# Where taken and ejected items go: the source's parent.
func _world() -> Node:
	var attached := source if is_instance_valid(source) else get_parent()
	return attached.get_parent() if attached != null else null


# Whether this slot, its source or a node between is being destroyed (queued
# for deletion); not something above the source, the level unloading.
func _destroyed() -> bool:
	var node: Node = self
	while node != null:
		if node.is_queued_for_deletion():
			return true
		if node == source:
			return false
		node = node.get_parent()
	return false


# Shows what it holds: the item's model, fitted to the pane, and the count.
func _show() -> void:
	var shown := item if item != null and count > 0 else null
	count_label.visible = shown != null
	count_label.text = str(count) if shown != null else ""
	if shown == _shown_item:
		return
	_shown_item = shown
	if is_instance_valid(_model):
		_model.queue_free()
	_model = null
	if shown == null or shown.model == null:
		return
	_model = shown.model.instantiate() as Node3D
	var turn := Basis.from_euler(shown.display_rotation * (PI / 180.0))
	var bounds := _turned_bounds(_model, turn)
	var widest := maxf(bounds.size.x, bounds.size.y)
	var fit := model_fill * size / widest if widest > 1e-6 else 1.0
	_model.transform = Transform3D(turn * fit, -bounds.get_center() * fit)
	for part in _model.find_children("*", "GeometryInstance3D", true, false):
		(part as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	model_holder.add_child(_model)


# A two-point line from the slot to `to`, in its own space; rebuilt only when
# that has moved.
func _draw_line_to(to: Vector3) -> void:
	if to.is_equal_approx(_line_to):
		return
	_line_to = to
	var mesh := source_line.mesh as ArrayMesh
	if mesh == null:
		mesh = ArrayMesh.new()
		source_line.mesh = mesh
	mesh.clear_surfaces()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, to])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)


# The box round `model`'s meshes, turned by `turn`, in the model's own space.
static func _turned_bounds(model: Node3D, turn: Basis) -> AABB:
	var bounds := AABB()
	var first := true
	for node in [model] + model.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if mesh == null or mesh.mesh == null:
			continue
		var place := Transform3D(turn, Vector3.ZERO) * _within(mesh, model)
		var box := mesh.mesh.get_aabb()
		for i in 8:
			var corner := place * box.get_endpoint(i)
			if first:
				bounds = AABB(corner, Vector3.ZERO)
				first = false
			else:
				bounds = bounds.expand(corner)
	return bounds


# `node`'s transform in `root`'s space, through the transforms between (it
# need not be in the tree).
static func _within(node: Node3D, root: Node3D) -> Transform3D:
	var place := Transform3D.IDENTITY
	var at: Node = node
	while at != null and at != root:
		if at is Node3D:
			place = (at as Node3D).transform * place
		at = at.get_parent()
	return place


# The points of `body`'s collision shapes (their debug outlines), in its own
# space.
static func _shape_points(body: Node3D) -> PackedVector3Array:
	var points := PackedVector3Array()
	for child in body.get_children():
		var shape := child as CollisionShape3D
		if shape == null or shape.shape == null or shape.disabled:
			continue
		var outline := shape.shape.get_debug_mesh()
		if outline.get_surface_count() == 0:
			continue
		for point: Vector3 in outline.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
			points.append(shape.transform * point)
	return points


# How a body whose shapes' box is `extent` lies in a hand: its longest axis
# along `along`, its thinnest along `out`.
static func _in_hand(extent: Vector3, along: Vector3, out: Vector3) -> Basis:
	var longest := extent.max_axis_index()
	var thinnest := extent.min_axis_index()
	if thinnest == longest:
		thinnest = (longest + 1) % 3
	var length := Vector3.ZERO
	length[longest] = 1.0
	var thin := Vector3.ZERO
	thin[thinnest] = 1.0
	var own := Basis(length, thin, length.cross(thin))
	var fist := along.normalized()
	var palm := (out - fist * out.dot(fist)).normalized()
	return Basis(fist, palm, fist.cross(palm)) * own.inverse()


# The box round `body`'s collision shapes, in its own space.
static func _shape_bounds(body: Node3D) -> AABB:
	var points := _shape_points(body)
	if points.is_empty():
		return AABB()
	var bounds := AABB(points[0], Vector3.ZERO)
	for point in points:
		bounds = bounds.expand(point)
	return bounds


# How far `body`'s collision shapes reach from `middle` along `direction`
# (unit, in its own space), in metres.
static func _support(body: Node3D, middle: Vector3, direction: Vector3) -> float:
	var reach := 0.0
	for point in _shape_points(body):
		reach = maxf(reach, (point - middle).dot(direction.normalized()))
	return reach
