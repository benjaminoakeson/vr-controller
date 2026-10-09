extends SceneTree

## Checks the inventory slot (rung 1, 2026-10-06) headlessly, without a
## renderer:
## - the five storable props and their items;
## - the hands' point query finding a slot's zone (Jolt), and only inside it;
## - what a slot takes in and refuses (another item, a full stack, burning
##   tinder, fuel a fire has started, a body that is not storable);
## - what it shows (model and count, or nothing);
## - taking one out at a palm: turned as shown, against the palm, not in it;
## - growing while touched and back after; rounder or squarer corners;
## - facing the camera; moving with its source, the line following;
## - ejecting what it holds when its source or the slot itself is destroyed
##   (clear of each other, litter as a ball), and not when the level unloads.
##
## The hands' side (selecting, taking with the grip, storing by letting go) is
## measured in tests/harness/run_scenarios.gd (the slot_* scenarios); the look
## needs a renderer and the headset.
##
##   godot --headless --xr-mode off --path . -s tests/inventory/test_inventory_slot.gd

const SLOT := "res://scenes/inventory/inventory_slot.tscn"
const LOG := "res://scenes/props/wood/log.tscn"
const STICK := "res://scenes/props/wood/stick.tscn"
const LITTER := "res://scenes/props/oak_leaf_litter.tscn"
const STONE := "res://scenes/props/stone/stone.tscn"
const FLINT := "res://scenes/props/stone/flint.tscn"
## Every check the suite makes. Update it when adding or removing a check.
const EXPECTED_CHECKS := 31

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_test_items()
	# Needs the scene tree running, so added nodes become ready.
	await process_frame
	await _test_zone()
	await _test_store_and_show()
	await _test_take()
	await _test_hover_and_facing()
	await _test_attached()
	await _test_corners()
	await _test_eject()
	if _checks != EXPECTED_CHECKS:
		_failures += 1
		print("FAIL  %d of %d checks ran; a test stopped on a script error" % [_checks, EXPECTED_CHECKS])
	print("\n%s" % ("ALL PASSED" if _failures == 0 else "%d FAILED" % _failures))
	quit(0 if _failures == 0 else 1)


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)


## Each storable prop names its own item, which comes out as that prop.
func _test_items() -> void:
	for path: String in [LOG, STICK, LITTER, STONE, FLINT]:
		var body := (load(path) as PackedScene).instantiate()
		var storable := body.get_node_or_null(^"Storable") as Storable
		var item := storable.item if storable != null else null
		_check(item != null and item.scene == path and item.max_stack == 999 and item.model != null,
				"%s is storable, its item comes out as it, 999 to a stack" % path.get_file())
		body.free()


## The hands find a slot by a point query on the Interface layer, which only
## finds it within its zone.
func _test_zone() -> void:
	var source := _add_source(Vector3(0.0, 0.0, 20.0))
	var slot := _add_slot(source, Vector3(0.0, 1.0, 0.0))
	await physics_frame
	await physics_frame
	var query := PhysicsPointQueryParameters3D.new()
	query.collision_mask = InventorySlot.ZONE_LAYER
	query.collide_with_areas = true
	query.collide_with_bodies = false
	var space := slot.get_world_3d().direct_space_state
	query.position = slot.global_position + Vector3(0.07, 0.0, 0.0)
	var inside := space.intersect_point(query, 4)
	query.position = slot.global_position + Vector3(0.13, 0.0, 0.0)
	var outside := space.intersect_point(query, 4)
	_check(inside.size() == 1 and inside[0].collider == slot and outside.is_empty(),
			"a point 7 cm from the slot finds its zone (r %.2f m); 13 cm off, nothing" % slot.radius())
	_check(slot.contains(slot.global_position + Vector3(0.105, 0.0, 0.0), 0.01)
			and not slot.contains(slot.global_position + Vector3(0.105, 0.0, 0.0)),
			"a selected slot holds 1 cm past its zone")
	source.free()


func _test_store_and_show() -> void:
	var source := _add_source(Vector3(2.0, 0.0, 20.0))
	var slot := _add_slot(source, Vector3(0.0, 1.0, 0.0))
	await process_frame
	_check(slot.item == null and slot.count == 0 and not slot.count_label.visible
			and slot.model_holder.get_child_count() == 0 and slot.glass.visible,
			"an empty slot shows its glass and nothing in it")
	var stone := _add(STONE, Vector3(2.0, 50.0, 20.0))
	var stick := _add(STICK, Vector3(2.5, 50.0, 20.0))
	_check(slot.accepts(stone) and slot.store(stone) and slot.count == 1
			and slot.item == Storable.of(stone).item and stone.is_queued_for_deletion()
			and not Grabbable.of(stone).enabled,
			"a stone goes in: one stone, its body gone and grabbed by nothing meanwhile")
	await process_frame
	_check(slot.count_label.visible and slot.count_label.text == "1" and slot.model_holder.get_child_count() == 1,
			"it shows the stone's model and the count, 1")
	_check(not slot.accepts(stick) and not slot.store(stick) and slot.count == 1,
			"a stick does not go in with the stone")
	slot.count = 999
	var another := _add(STONE, Vector3(3.0, 50.0, 20.0))
	_check(not slot.accepts(another), "a full stack (999) takes no more")
	slot.count = 1
	_check(slot.store(another) and slot.count == 2 and slot.count_label.text == "2",
			"another stone makes two")
	var empty := _add_slot(source, Vector3(0.5, 1.0, 0.0))
	var lit := _add(LITTER, Vector3(4.0, 50.0, 20.0))
	(lit.get_node(^"Tinder") as Tinder).ignite()
	var fresh := _add(LITTER, Vector3(4.5, 50.0, 20.0))
	_check(not empty.accepts(lit) and empty.accepts(fresh), "burning litter is refused, fresh litter taken")
	(stick.get_node(^"Fuel") as Fuel).burn(1.0)
	var bare := RigidBody3D.new()
	root.add_child(bare)
	_check(not empty.accepts(stick) and not empty.accepts(bare),
			"so is a stick a fire has burnt a second of, and a body that is not storable")
	for node: Node in [source, stick, lit, fresh, bare]:
		node.free()


## Taken out at a palm: lying across it (a log's length along the fist, its
## thinnest side on the palm), its surface on the grab point, nothing of it past
## the palm; the last one out empties the slot.
func _test_take() -> void:
	var source := _add_source(Vector3(4.0, 0.0, 20.0))
	var slot := _add_slot(source, Vector3(0.0, 1.0, 0.0))
	await process_frame
	for i in 2:
		slot.store(_add(LOG, Vector3(4.0 + i, 50.0, 22.0)))
	await process_frame
	var at := Vector3(4.0, 1.2, 20.3)
	var along := Vector3.RIGHT
	var out := Vector3(0.0, 1.0, 1.0).normalized()
	var log := slot.take(at, along, out)
	_check(log != null and log.get_parent() == root and log.is_inside_tree() and slot.count == 1,
			"one log comes out, into the source's parent; one left")
	var points := _shape_points(log)
	var nearest := INF
	var deepest := INF
	for point in points:
		nearest = minf(nearest, point.distance_to(at))
		deepest = minf(deepest, (point - at).dot(out))
	_check(deepest > -0.002 and nearest < 0.01,
			"its surface is on the grab point (nearest point %.4f m) and nothing past the palm (%.4f m)" % [nearest, deepest])
	var turn := log.global_basis.orthonormalized()
	_check(absf(turn.y.dot(along)) > 0.999 and absf(turn.z.dot(out)) > 0.999,
			"its length (its Y) lies along the fist and its thinnest side (Z) on the palm")
	var last := slot.take(at + Vector3(1.0, 0.0, 0.0), along, out)
	await process_frame
	_check(last != null and slot.count == 0 and slot.item == null and not slot.count_label.visible
			and slot.model_holder.get_child_count() == 0 and slot.take(at, along, out) == null,
			"the last one out empties it: nothing shown, nothing more to take")
	for node: Node in [source, log, last]:
		node.free()


func _test_hover_and_facing() -> void:
	var source := _add_source(Vector3(6.0, 0.0, 20.0))
	var slot := _add_slot(source, Vector3(0.0, 1.0, 0.0))
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.global_position = slot.global_position + Vector3(1.0, 0.6, 1.5)
	camera.current = true
	for i in 30:
		slot.touch()
		await physics_frame
	await process_frame
	var grown := slot.face.global_basis.get_scale().x
	_check(slot.selected() and is_equal_approx(snappedf(grown, 0.01), 1.25),
			"touched each tick, it is selected and grows to 1.25 (%.3f)" % grown)
	var to := (camera.global_position - slot.face.global_position).normalized()
	_check(slot.face.global_basis.z.normalized().dot(to) > 0.999 and absf(slot.face.global_basis.x.normalized().y) < 0.001,
			"it faces the camera, kept level")
	for i in 30:
		await physics_frame
	await process_frame
	var back := slot.face.global_basis.get_scale().x
	_check(not slot.selected() and is_equal_approx(snappedf(back, 0.01), 1.0),
			"untouched, it shrinks back (%.3f)" % back)
	camera.free()
	source.free()


func _test_attached() -> void:
	var source := _add_source(Vector3(8.0, 0.0, 20.0))
	var slot := _add_slot(source, Vector3(0.0, 1.0, 0.3))
	await process_frame
	var line := slot.source_line.mesh as ArrayMesh
	var drawn := line.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array if line != null else PackedVector3Array()
	_check(drawn.size() == 2 and drawn[1].is_equal_approx(Vector3(0.0, -1.0, -0.3)),
			"the line runs from the slot to its source's origin")
	source.global_position += Vector3(1.0, 0.5, 0.0)
	source.rotate_y(PI / 2.0)
	await process_frame
	_check(slot.global_position.is_equal_approx(Vector3(9.3, 1.5, 20.0)),
			"moved and turned, the source takes its slot with it (%s)" % slot.global_position)
	source.free()


## The glass's corner radius: square at 0, round at half the side, as before at
## 2.5 cm, where every slot shares the scene's mesh; a slot with other corners
## has its own, and its count moves in along the diagonal to stay on the glass.
func _test_corners() -> void:
	var square := SlotBubbleMesh.outline_exponent_for(0.0)
	var round := SlotBubbleMesh.outline_exponent_for(1.0)
	var usual := SlotBubbleMesh.outline_exponent_for(0.025 / 0.075)
	_check(square <= 0.05 and is_equal_approx(round, 1.0) and absf(usual - 0.3) < 0.005,
			"corner radius 0 is square (%.3f), half the side round (%.3f), 2.5 cm as before (%.3f)" % [square, round, usual])
	var source := _add_source(Vector3(10.0, 0.0, 20.0))
	var plain := _add_slot(source, Vector3(0.0, 1.0, 0.0))
	var rounder := (load(SLOT) as PackedScene).instantiate() as InventorySlot
	rounder.corner_radius = 0.075
	rounder.position = Vector3(0.3, 1.0, 0.0)
	source.add_child(rounder)
	await process_frame
	var shared := plain.glass.mesh as SlotBubbleMesh
	var own := rounder.glass.mesh as SlotBubbleMesh
	var label := rounder.count_label.position
	_check(shared != own and absf(shared.outline_exponent - 0.3) < 0.005 and is_equal_approx(own.outline_exponent, 1.0)
			and Vector2(label.x, label.y).length() < 0.075 and plain.count_label.position.x > label.x,
			"a round slot has its own round glass, its count inside the circle (%.3f m out); the usual one keeps the shared glass"
			% Vector2(label.x, label.y).length())
	source.free()


func _test_eject() -> void:
	# The source destroyed: what its slot held comes out where the slot was.
	var source := _add_source(Vector3(12.0, 0.0, 20.0))
	var slot := _add_slot(source, Vector3(0.0, 1.0, 0.0))
	await process_frame
	var at := slot.global_position
	for i in 5:
		slot.store(_add(STICK, Vector3(12.0 + i, 50.0, 24.0)))
	await process_frame
	var before := root.get_children()
	source.queue_free()
	await physics_frame
	await physics_frame
	await physics_frame
	var sticks := _new_bodies(before)
	var spread := 0.0
	var closest := INF
	for i in sticks.size():
		spread = maxf(spread, Vector2(sticks[i].global_position.x - at.x, sticks[i].global_position.z - at.z).length())
		for j in range(i + 1, sticks.size()):
			closest = minf(closest, sticks[i].global_position.distance_to(sticks[j].global_position))
	_check(sticks.size() == 5 and sticks.all(func(body: Node3D) -> bool: return Storable.of(body).item.id == &"stick"),
			"its source destroyed, the slot's five sticks come out (%d)" % sticks.size())
	_check(spread < 1.2 and closest > 0.1,
			"round where the slot was (within %.2f m), apart (closest %.2f m)" % [spread, closest])
	_check(sticks.all(func(body: Node3D) -> bool: return absf(body.global_basis.y.y) < 0.01),
			"sticks come out lying on their side")
	for stick: Node in sticks:
		stick.free()
	# The slot itself destroyed; litter comes out as a falling ball.
	source = _add_source(Vector3(16.0, 0.0, 20.0))
	slot = _add_slot(source, Vector3(0.0, 1.0, 0.0))
	await process_frame
	for i in 3:
		slot.store(_add(LITTER, Vector3(16.0 + i, 50.0, 24.0)))
	await process_frame
	before = root.get_children()
	slot.queue_free()
	await physics_frame
	await physics_frame
	await physics_frame
	var litter := _new_bodies(before)
	_check(litter.size() == 3 and litter.all(func(body: Node3D) -> bool:
			return (body as LeafLitter).form == LeafLitter.Form.BALL and not (body as RigidBody3D).freeze),
			"the slot destroyed, its three litter come out as loose balls (%d)" % litter.size())
	for node: Node in litter:
		node.free()
	source.free()
	# The level unloading: nothing comes out.
	var level := Node3D.new()
	root.add_child(level)
	source = Node3D.new()
	level.add_child(source)
	source.global_position = Vector3(20.0, 0.0, 20.0)
	slot = _add_slot(source, Vector3(0.0, 1.0, 0.0))
	await process_frame
	for i in 3:
		slot.store(_add(STONE, Vector3(20.0 + i, 50.0, 24.0)))
	await process_frame
	before = root.get_children()
	level.queue_free()
	await physics_frame
	await physics_frame
	await physics_frame
	_check(_new_bodies(before).is_empty(), "the level unloading ejects nothing")


func _add_source(at: Vector3) -> Node3D:
	var source := Node3D.new()
	source.name = "Source"
	root.add_child(source)
	source.global_position = at
	return source


func _add_slot(source: Node3D, at: Vector3) -> InventorySlot:
	var slot := (load(SLOT) as PackedScene).instantiate() as InventorySlot
	slot.position = at
	source.add_child(slot)
	return slot


func _add(path: String, at: Vector3) -> RigidBody3D:
	var body := (load(path) as PackedScene).instantiate() as RigidBody3D
	body.position = at
	root.add_child(body)
	return body


# Storable bodies in the root that were not in `before`.
func _new_bodies(before: Array[Node]) -> Array[Node3D]:
	var found: Array[Node3D] = []
	for child in root.get_children():
		if child not in before and Storable.of(child) != null:
			found.append(child as Node3D)
	return found


# `body`'s collision shapes' outline points, in world space.
func _shape_points(body: RigidBody3D) -> PackedVector3Array:
	var points := PackedVector3Array()
	for child in body.get_children():
		var shape := child as CollisionShape3D
		if shape == null or shape.shape == null:
			continue
		for point: Vector3 in shape.shape.get_debug_mesh().surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
			points.append(shape.global_transform * point)
	return points
