extends SceneTree

## Checks the strike model's damage scale and the Health it feeds (2026-10-02)
## headlessly, without physics: the 1 to 10 scale at and between a material's
## threshold and full energy, Health counting down to 0, and an ore vein struck
## as one object through any of its bodies, which frees itself at 0. The strikes
## themselves are measured in tests/harness/run_scenarios.gd. Then the vein's
## loot: four ores dropped clear of each other and of anything in the way. Then
## what a tree's lone piece needs of them (checkpoint 1c): a Health that takes
## only the kinds it is set to, and loot laid round a centre of its own, never
## blocked by the object's own bodies.
##
##   godot --headless --xr-mode off --path . -s tests/strike/test_damage_health.gd

const MATERIALS := ["res://assets/strike/cloth.tres", "res://assets/strike/wood.tres",
		"res://assets/strike/stone.tres"]
const VEIN := "res://scenes/props/ore_vein_copper.tscn"
const ORE := "res://scenes/props/ores/copper_ore.tscn"
## Every check the suite makes. Update it when adding or removing a check.
const EXPECTED_CHECKS := 37

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_test_damage_scale()
	_test_materials()
	# Needs the scene tree running, so added nodes become ready.
	await process_frame
	_test_health()
	_test_strikes_damage_health()
	_test_health_kinds()
	await _test_vein()
	await _test_loot()
	await _test_loot_blocked()
	await _test_loot_centre()
	await _test_loot_own_bodies()
	await _test_loot_lay_down()
	# A script error ends a test early without failing a check, so count them.
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


func _test_damage_scale() -> void:
	var material := StrikeMaterial.new()
	material.blunt_threshold = 2.0
	material.blunt_full_energy = 20.0
	var blunt := Strike.Kind.BLUNT
	_check(material.damage_of(blunt, 1.99) == 0, "below the threshold: no damage")
	_check(material.damage_of(blunt, 2.0) == Strike.MIN_DAMAGE, "at the threshold: the least damage (1)")
	_check(material.damage_of(blunt, 11.0) == 6, "halfway to the full energy: 5.5, rounded to 6")
	_check(material.damage_of(blunt, 20.0) == Strike.MAX_DAMAGE, "at the full energy: the most damage (10)")
	_check(material.damage_of(blunt, 500.0) == Strike.MAX_DAMAGE, "far harder: still the most")
	var steady := true
	var last := 0
	for step in 200:
		var damage := material.damage_of(blunt, 2.0 + step * 0.1)
		steady = steady and damage >= last and damage >= Strike.MIN_DAMAGE and damage <= Strike.MAX_DAMAGE
		last = damage
	_check(steady, "from the threshold up, the damage only grows, from 1 to 10")
	material.slash_threshold = 5.0
	material.slash_full_energy = 5.0
	_check(material.damage_of(Strike.Kind.SLASH, 5.0) == Strike.MAX_DAMAGE,
			"a full energy no higher than the threshold: any damaging strike is full")


## The project's materials: every type a material takes reaches its full damage
## above its threshold.
func _test_materials() -> void:
	for path: String in MATERIALS:
		var material: StrikeMaterial = load(path)
		var sane := true
		for kind: Strike.Kind in [Strike.Kind.BLUNT, Strike.Kind.SLASH]:
			if material.takes(kind):
				sane = sane and material.full_energy_of(kind) > material.threshold_of(kind)
		_check(sane, "%s: full energy above the threshold for each type it takes" % path.get_file())


func _test_health() -> void:
	var post := _post(load(MATERIALS[1]), 30)
	var health := post.get_node(^"Health") as Health
	var seen: Array[int] = []
	var depleted := [0]
	health.changed.connect(func(current: int) -> void: seen.append(current))
	health.depleted.connect(func() -> void: depleted[0] += 1)
	_check(health.current == 30, "starts at its most (30)")
	health.take_damage(7)
	health.take_damage(0)
	health.take_damage(-3)
	_check(seen == [23], "7 damage leaves 23; none, or less, changes nothing (%s)" % str(seen))
	health.take_damage(100)
	health.take_damage(5)
	_check(health.current == 0 and seen == [23, 0], "more than is left stops at 0, and nothing after (%s)" % str(seen))
	_check(depleted[0] == 1, "running out is reported once (%d)" % depleted[0])
	post.free()


## A strike judged by the Strikeable takes its damage from the Health.
func _test_strikes_damage_health() -> void:
	var wood: StrikeMaterial = load(MATERIALS[1])
	var post := _post(wood, 30)
	var health := post.get_node(^"Health") as Health
	var strikeable := post.get_node(^"Strikeable") as Strikeable
	var strike := _strike(Strike.Kind.BLUNT, 40.0)
	strikeable.receive(strike)
	_check(strike.damage == wood.damage_of(Strike.Kind.BLUNT, 40.0) and health.current == 30 - strike.damage,
			"a 40 J blow on wood does wood's damage (%d), taken from its health" % strike.damage)
	strikeable.receive(_strike(Strike.Kind.BLUNT, 1.0))
	_check(health.current == 30 - strike.damage, "a blow under wood's threshold takes nothing")
	var stone: StrikeMaterial = load(MATERIALS[2])
	var block := _post(stone, 30)
	var slash := _strike(Strike.Kind.SLASH, 60.0)
	(block.get_node(^"Strikeable") as Strikeable).receive(slash)
	_check(slash.kind == Strike.Kind.BLUNT and slash.damage == stone.damage_of(Strike.Kind.BLUNT, 60.0),
			"stone takes a slash as blunt (%d)" % slash.damage)
	post.free()
	block.free()


## A Health takes the kinds of strike it is set to (Health.kinds, 2026-10-02):
## every kind by default, as a vein's does; a tree's lone piece takes slashes
## only.
func _test_health_kinds() -> void:
	var wood: StrikeMaterial = load(MATERIALS[1])
	var post := _post(wood, 30)
	var health := post.get_node(^"Health") as Health
	var strikeable := post.get_node(^"Strikeable") as Strikeable
	var blunt := _strike(Strike.Kind.BLUNT, wood.full_energy_of(Strike.Kind.BLUNT))
	var slash := _strike(Strike.Kind.SLASH, wood.full_energy_of(Strike.Kind.SLASH))
	strikeable.receive(blunt)
	strikeable.receive(slash)
	_check(health.kinds == ((1 << Strike.Kind.BLUNT) | (1 << Strike.Kind.SLASH)) and blunt.damage == Strike.MAX_DAMAGE
			and slash.damage == Strike.MAX_DAMAGE and health.current == 30 - 2 * Strike.MAX_DAMAGE,
			"by default a Health takes every kind: a full-strength blunt blow and a full-strength slash on wood take %d each (%d of 30 left)"
			% [Strike.MAX_DAMAGE, health.current])
	post.free()
	var slashed := _post(wood, 30)
	health = slashed.get_node(^"Health") as Health
	health.kinds = 1 << Strike.Kind.SLASH
	strikeable = slashed.get_node(^"Strikeable") as Strikeable
	blunt = _strike(Strike.Kind.BLUNT, wood.full_energy_of(Strike.Kind.BLUNT))
	strikeable.receive(blunt)
	var after_blunt := health.current
	slash = _strike(Strike.Kind.SLASH, wood.full_energy_of(Strike.Kind.SLASH))
	strikeable.receive(slash)
	_check(blunt.damage == Strike.MAX_DAMAGE and after_blunt == 30 and slash.damage == Strike.MAX_DAMAGE
			and health.current == 30 - Strike.MAX_DAMAGE,
			"set to slashes only, it ignores a full-strength blunt blow (%d damage, %d left) and takes a slash's %d (%d left)"
			% [blunt.damage, after_blunt, slash.damage, health.current])
	slashed.free()


## An ore vein (a model with a body per mesh) is struck as one object, shows its
## health, and frees itself when the health runs out.
func _test_vein() -> void:
	# In a world of its own, freed with the loot the vein drops.
	var world := _floor()
	var vein := (load(VEIN) as PackedScene).instantiate() as Node3D
	world.add_child(vein)
	var strikeable := vein.get_node(^"Strikeable") as Strikeable
	var health := vein.get_node(^"Health") as Health
	var display := vein.get_node(^"HealthDisplay") as Label3D
	var bodies := vein.find_children("*", "CollisionObject3D", true, false)
	var marked := func() -> int:
		return bodies.filter(func(body: Node) -> bool: return Strikeable.of(body) == strikeable).size()
	_check(bodies.size() == 7 and marked.call() == 7, "each of the vein's 7 bodies (rock and ore) is struck as the vein")
	_check(display.text == "%d / %d" % [health.maximum, health.maximum], "it shows its full health (%s)" % display.text)
	strikeable.receive(_strike(Strike.Kind.BLUNT, 150.0))
	_check(health.current == health.maximum - Strike.MAX_DAMAGE
			and display.text == "%d / %d" % [health.current, health.maximum],
			"a full-strength blow on its stone takes 10, and the display follows (%s)" % display.text)
	world.remove_child(vein)
	_check(marked.call() == 0, "out of the tree, its bodies are no longer marked")
	world.add_child(vein)
	_check(marked.call() == 7, "back in the tree, they are marked again")
	health.take_damage(health.current)
	_check(vein.is_queued_for_deletion(), "at 0 health it frees itself")
	await process_frame
	_check(not is_instance_valid(vein), "and is gone after the frame")
	world.free()


## A vein whose health runs out drops four of its ore, once, into its parent:
## around the middle of its meshes, none inside another, and nothing pushes them
## as they appear (after a step they move as gravity alone moves them).
func _test_loot() -> void:
	var world := _floor()
	var vein := (load(VEIN) as PackedScene).instantiate() as Node3D
	world.add_child(vein)
	await physics_frame
	var middle := _middle_of(vein)
	var drops: Array = []
	(vein.get_node(^"LootDrop") as LootDrop).dropped.connect(func(items: Array[Node3D]) -> void:
			drops.append(items))
	var health := vein.get_node(^"Health") as Health
	health.take_damage(health.current)
	var items: Array[Node3D] = []
	if drops.size() == 1:
		items.assign(drops[0])
	_check(drops.size() == 1 and items.size() == 4 and items.all(func(item: Node3D) -> bool:
			return item.scene_file_path == ORE and item.get_parent() == world),
			"its health gone, the vein drops 4 copper ores once, into its parent")
	var reach := _ore_reach()
	var apart := INF
	for a in items.size():
		for b in range(a + 1, items.size()):
			apart = minf(apart, items[a].global_position.distance_to(items[b].global_position))
	_check(apart >= 2.0 * reach, "none appears inside another (%.3f m apart, %.3f needed)" % [apart, 2.0 * reach])
	var offsets: Array = items.map(func(item: Node3D) -> Vector3: return item.global_position - middle)
	_check(offsets.all(func(off: Vector3) -> bool:
			return absf(off.y) < 1e-4 and Vector2(off.x, off.z).length() < 0.3),
			"they appear around the middle of the vein's meshes, at its height (%s)" % str(offsets))
	await physics_frame
	var fall := Vector3.DOWN * float(ProjectSettings.get_setting("physics/3d/default_gravity")) \
			/ Engine.physics_ticks_per_second
	_check(items.all(func(item: RigidBody3D) -> bool:
			return (item.linear_velocity - fall).length() < 0.001 and item.angular_velocity.length() < 0.001),
			"nothing pushes them as they appear: after a step they only fall")
	world.free()


## A drop whose place is taken (by a weapon sunk into the vein, say) appears a
## spacing higher instead, clear of what was there; the others are unmoved.
func _test_loot_blocked() -> void:
	var world := _floor()
	var vein := (load(VEIN) as PackedScene).instantiate() as Node3D
	world.add_child(vein)
	# Where the first ore goes: a ring corner, half a spacing out along x and z.
	var middle := _middle_of(vein)
	var half := _ore_reach() + 0.01
	var block := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3.ONE * 0.1
	shape.shape = box
	block.add_child(shape)
	block.position = middle + Vector3(half, 0.0, half)
	world.add_child(block)
	await physics_frame
	var drops: Array = []
	(vein.get_node(^"LootDrop") as LootDrop).dropped.connect(func(items: Array[Node3D]) -> void:
			drops.append(items))
	var health := vein.get_node(^"Health") as Health
	health.take_damage(health.current)
	var items: Array[Node3D] = []
	if drops.size() == 1:
		items.assign(drops[0])
	var raised := items.filter(func(item: Node3D) -> bool: return item.global_position.y > middle.y + 0.01)
	_check(items.size() == 4 and raised.size() == 1 and raised[0] == items[0],
			"only the ore whose place is taken appears higher (%d raised)" % raised.size())
	var clear := 0.05 * sqrt(3.0) + _ore_reach()
	_check(not raised.is_empty() and (raised[0] as Node3D).global_position.distance_to(block.global_position) >= clear,
			"clear of what was there")
	world.free()


## A LootDrop given a centre lays its ring round that, not round the middle of
## its object's meshes (2026-10-02: a tree's lone piece drops round its middle).
func _test_loot_centre() -> void:
	var world := _floor()
	var vein := (load(VEIN) as PackedScene).instantiate() as Node3D
	world.add_child(vein)
	var marker := Marker3D.new()
	vein.add_child(marker)
	marker.global_position = _middle_of(vein) + Vector3(1.0, 0.5, 0.0)
	var drop := vein.get_node(^"LootDrop") as LootDrop
	drop.centre = marker
	await physics_frame
	var centre := marker.global_position
	var items := _deplete(vein)
	var ring := (2.0 * _ore_reach() + drop.gap) / (2.0 * sin(PI / 4.0))
	var off := INF if items.size() != 4 else 0.0
	for item in items:
		var offset := item.global_position - centre
		off = maxf(off, maxf(absf(Vector2(offset.x, offset.z).length() - ring), absf(offset.y)))
	_check(items.size() == 4 and off < 0.001,
			"with its centre set to a marker 1.0 m aside of the vein's middle and 0.5 m up, its 4 ores lie round the marker: each %.3f m from it (the ring for 4), level with it (%.5f m off at most)"
			% [ring, off])
	world.free()


## Nothing of a LootDrop's own object blocks its loot (2026-10-02, for a tree's
## lone piece): the object itself when it is a body, as a felled piece is, and a
## body it builds as an internal child, as a tree builds its wood.
func _test_loot_own_bodies() -> void:
	var world := _floor()
	# A still rigid body whose box takes in the ring its loot is laid on.
	var body := RigidBody3D.new()
	body.freeze = true
	body.add_child(_box(0.6))
	_looted(body)
	body.position = Vector3(0.0, 1.0, 0.0)
	world.add_child(body)
	# A plain object whose body is an internal child, marked by hand as a tree
	# marks the wood body it builds.
	var holder := Node3D.new()
	var inner := StaticBody3D.new()
	inner.add_child(_box(0.6))
	holder.add_child(inner, false, Node.INTERNAL_MODE_FRONT)
	_looted(holder)
	(holder.get_node(^"Strikeable") as Strikeable).mark(inner)
	holder.position = Vector3(3.0, 1.0, 0.0)
	world.add_child(holder)
	await physics_frame
	var items := _deplete(body)
	var raised := items.filter(func(item: Node3D) -> bool: return item.global_position.y > 1.0 + 0.0001).size()
	var meeting := items.filter(func(item: Node3D) -> bool: return _meets(item, body)).size()
	_check(items.size() == 4 and raised == 0 and meeting == 4,
			"a rigid body's 4 ores, laid round it inside its own 0.6 m box (%d of 4 meet it), are not raised (%d): the object itself is passed over"
			% [meeting, raised])
	items = _deplete(holder)
	raised = items.filter(func(item: Node3D) -> bool: return item.global_position.y > 1.0 + 0.0001).size()
	meeting = items.filter(func(item: Node3D) -> bool: return _meets(item, inner)).size()
	_check(items.size() == 4 and raised == 0 and meeting == 4,
			"an object's 4 ores, laid inside the body it holds as an internal child (%d of 4 meet it), are not raised either (%d)"
			% [meeting, raised])
	world.free()


## A LootDrop set to lay_down turns each drop on its side where it would have
## stood, its length (its Y) level along the ring (2026-10-02: logs and sticks
## laid standing land on their ends and stay standing); a vein's leaves it off,
## so its ores stand as before.
func _test_loot_lay_down() -> void:
	var standing := await _vein_drop(false)
	var laid := await _vein_drop(true)
	var upright := 0.0 if standing.poses.size() == 4 else INF
	for pose: Transform3D in standing.poses:
		upright = maxf(upright, (pose.basis.y - Vector3.UP).length())
	_check(not standing.lay_down and upright < 0.0001,
			"a vein's LootDrop leaves lay_down off: its 4 ores are laid standing, each Y straight up (%.6f off at most)"
			% upright)
	var level := 0.0 if laid.poses.size() == 4 and standing.poses.size() == 4 else INF
	var across := level
	var moved := level
	for i in mini(laid.poses.size(), standing.poses.size()):
		var pose: Transform3D = laid.poses[i]
		var out: Vector3 = pose.origin - laid.middle
		out.y = 0.0
		level = maxf(level, absf(pose.basis.y.y))
		across = maxf(across, absf(pose.basis.y.dot(out.normalized())))
		moved = maxf(moved, pose.origin.distance_to((standing.poses[i] as Transform3D).origin))
	_check(laid.lay_down and level < 0.0001 and across < 0.0001 and moved < 0.0001,
			"set to lay_down, the same vein's 4 ores lie on their sides: each Y level (%.6f off at most) and along the ring, square to the line out from its middle (%.6f off), each where it stood (%.6f m away at most)"
			% [level, across, moved])


# A wide floor, its top at 0, in a world of its own added to the tree.
func _floor() -> Node3D:
	var world := Node3D.new()
	var floor := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(30.0, 1.0, 30.0)
	shape.shape = box
	floor.add_child(shape)
	floor.position = Vector3.DOWN * 0.5
	world.add_child(floor)
	root.add_child(world)
	return world


# The middle of `object`'s meshes, in world space.
func _middle_of(object: Node3D) -> Vector3:
	var bounds := AABB()
	var meshes := object.find_children("*", "MeshInstance3D", true, false)
	for i in meshes.size():
		var mesh := meshes[i] as MeshInstance3D
		var box := mesh.global_transform * mesh.get_aabb()
		bounds = box if i == 0 else bounds.merge(box)
	return bounds.get_center()


# How far an ore's convex shape reaches from its origin.
func _ore_reach() -> float:
	var ore := (load(ORE) as PackedScene).instantiate() as Node3D
	var reach := 0.0
	for point in ((ore.get_node(^"Shape") as CollisionShape3D).shape as ConvexPolygonShape3D).points:
		reach = maxf(reach, point.length())
	ore.free()
	return reach


# A struck post as the level's are, with a Health: a StaticBody3D with a
# Strikeable of `material` and a Health of `maximum`, added to the tree.
func _post(material: StrikeMaterial, maximum: int) -> StaticBody3D:
	var post := StaticBody3D.new()
	var strikeable := Strikeable.new()
	strikeable.name = "Strikeable"
	strikeable.material = material
	post.add_child(strikeable)
	var health := Health.new()
	health.name = "Health"
	health.maximum = maximum
	health.strikeable = strikeable
	post.add_child(health)
	root.add_child(post)
	return post


func _strike(kind: Strike.Kind, energy: float) -> Strike:
	var strike := Strike.new()
	strike.kind = kind
	strike.energy = energy
	return strike


# Gives `object` what a vein has to drop its loot: a Strikeable of wood, a
# Health of 10 and a LootDrop of 4 copper ores.
func _looted(object: Node3D) -> void:
	var strikeable := Strikeable.new()
	strikeable.name = "Strikeable"
	strikeable.material = load(MATERIALS[1])
	object.add_child(strikeable)
	var health := Health.new()
	health.name = "Health"
	health.maximum = 10
	health.strikeable = strikeable
	object.add_child(health)
	var drop := LootDrop.new()
	drop.name = "LootDrop"
	drop.health = health
	drop.loot = load(ORE)
	drop.count = 4
	object.add_child(drop)


# A copper vein's loot as it drops, in a world of its own, its LootDrop laying it
# down if `lay_down` (else as the vein has it): whether it lays it down
# ("lay_down"), the middle of the vein's meshes ("middle") and each ore's
# transform as it appears ("poses").
func _vein_drop(lay_down: bool) -> Dictionary:
	var world := _floor()
	var vein := (load(VEIN) as PackedScene).instantiate() as Node3D
	world.add_child(vein)
	var drop := vein.get_node(^"LootDrop") as LootDrop
	if lay_down:
		drop.lay_down = true
	await physics_frame
	var found := {"lay_down": drop.lay_down, "middle": _middle_of(vein), "poses": []}
	for item in _deplete(vein):
		(found.poses as Array).append(item.global_transform)
	world.free()
	return found


# Runs `object`'s Health out; what its LootDrop dropped.
func _deplete(object: Node3D) -> Array[Node3D]:
	var items: Array[Node3D] = []
	(object.get_node(^"LootDrop") as LootDrop).dropped.connect(func(dropped: Array[Node3D]) -> void:
			items.append_array(dropped))
	var health := object.get_node(^"Health") as Health
	health.take_damage(health.current)
	return items


# A box of `size` metres a side, as a collision shape.
func _box(size: float) -> CollisionShape3D:
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3.ONE * size
	shape.shape = box
	return shape


# Whether `item`'s shapes, where it is, meet `body`.
func _meets(item: Node3D, body: CollisionObject3D) -> bool:
	var solid := item as CollisionObject3D
	if solid == null:
		return false
	var query := PhysicsShapeQueryParameters3D.new()
	query.collision_mask = body.collision_layer
	query.exclude = [solid.get_rid()]
	for child in solid.get_children():
		var shape := child as CollisionShape3D
		if shape == null or shape.shape == null:
			continue
		query.shape = shape.shape
		query.transform = solid.global_transform * shape.transform
		for hit: Dictionary in solid.get_world_3d().direct_space_state.intersect_shape(query, 32):
			if hit.collider == body:
				return true
	return false
