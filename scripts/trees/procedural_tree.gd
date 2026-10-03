@tool
class_name ProceduralTree
extends Node3D

## A tree grown from a species and a seed when it enters the scene, in the
## editor and in the game alike. Nothing generated is saved with the scene:
## the species and seed are the whole description.
##
## The seed picks one of the species' variants and, separately, a turn about
## the vertical and a size, so trees on the same variant still differ. Every
## tree on a variant shares its skeleton, meshes and collision shapes through
## TreeCache; they are read-only here.
##
## Detail levels: three meshes (TreeMesher.Level), each on its own instance
## whose visibility range draws it only near its distances, culled by the engine
## with no script running per frame. Where two levels meet, both are drawn and
## the tree shaders (tree_lod.gdshaderinc) dissolve one into the other over the
## species' fade band. All three share one bounding box, so the engine and the
## shaders measure the same distance.
##
## Collision: the trunk and thick branches are capsules on one static body on
## the Static layer, so bodies and hands can't pass through them. Leaf clusters
## are boxes (or spheres) on a touch-only area on the Foliage layer: nothing is
## blocked by them, but hands or props can detect them. The area doesn't
## monitor anything itself, and a static body does no work while nothing
## touches it, so a standing tree costs nothing per frame. Under a
## TreeCollisionStreamer a tree only has collision while the player is near.
## The editor never simulates physics, so there a tree only builds collision
## to show it.
##
## Chopping (2026-10-02). A tree that can be chopped (a TreeChop on it) is its
## own once the game starts (make_own), and so is every piece of one: a stump,
## and the wood of a FelledTree, which is a ProceduralTree colliding through the
## FelledTree's body (collision_host). An own tree:
## - draws the band round each segment line being chopped with its notch
##   (notch_ring), the full level open there;
## - draws its leaves apart from its wood, and loses leaf clusters (lose_leaf)
##   and twigs (TreeSkeleton.is_twig: branches with no segment line on wood to chop)
##   whole with everything growing from them (break_branch), its meshes drawn
##   again once a frame;
## - is cut through at any branch (sever): it keeps the part below, and the
##   part beyond becomes a FelledTree beside it. Its TreeChop does it, at a
##   segment line.
## Its leaf clusters, and bare twigs (TreeCollider.twigs), watch what touches
## them. Something moving through one at BREAK_SPEED or faster breaks it (a
## swing, not a hand at walking pace): a leaf on a twig breaks the twig, one on
## wood with lines to chop only itself. A piece that falls breaks them against
## anything else too. The player's body never does: walking through leaves is
## not attacking them.

## Emitted once the tree is felled, with the part that falls.
signal felled(top: FelledTree)
## Emitted when any of it is cut off, with the part that falls, before the tree
## takes the part that stays (sever).
signal severed(piece: FelledTree)
## Emitted when its skeleton has changed (sever): what was kept for it, such as
## the lines being chopped, is handed over or let go.
signal reshaped

const STATIC_LAYER := 1
const DYNAMIC_LAYER := 2
const HELD_LAYER := 8
const PLAYER_LAYER := 16
const HANDS_LAYER := 32
const ENEMY_LAYER := 256
## Layer 10, named Foliage.
const FOLIAGE_LAYER := 1 << 9
## How fast something must move through a leaf cluster or a bare twig, or strike
## a twig (TreeSkeleton.is_twig), to break it, in metres per second: a swing, not a
## hand at walking pace (2026-10-02).
const BREAK_SPEED := 2.0

@export var species: TreeSpecies:
	set(value):
		species = value
		regenerate()
## Which tree of the species this is: picks its variant, turn and size.
@export var tree_seed := 0:
	set(value):
		tree_seed = value
		regenerate()
## Rebuilds the species from its settings, after they were edited. Other trees
## of the species keep what they have until they are regenerated too.
@export_tool_button("Regenerate", "Reload") var regenerate_action := regenerate_species
## Show one detail level at every distance, for checking it; Auto picks by distance.
@export_enum("Auto", "Full", "Medium", "Far") var detail_preview := 0:
	set(value):
		detail_preview = value
		if is_node_ready():
			_apply_detail_ranges()
## Outline the collision shapes (wood orange, leaves green), for checking them
## in the editor.
@export var show_collision := false:
	set(value):
		show_collision = value
		regenerate()

## Whether this tree has collision objects. A TreeCollisionStreamer parent
## switches it; on its own a tree always has collision.
var collision_active := true:
	set(value):
		if value == collision_active:
			return
		collision_active = value
		if is_node_ready():
			_rebuild_collision()

## Whether an impostor draws this tree beyond the species' impostor distance,
## so its far level ends there, dissolving into it. Set by a TreeScatter once
## the species' impostors are ready.
var impostor_handoff := false:
	set(value):
		impostor_handoff = value
		if is_node_ready():
			_apply_detail_ranges()

## This tree's shape, shared with every tree on its variant: read only. Once
## cut, its own.
var skeleton: TreeSkeleton
## Whether it draws and collides as its own (chopping; see above).
var own := false
## The body its wood collides through, when it is the wood of a FelledTree; a
## standing tree has a static body of its own.
var collision_host: CollisionObject3D

var _built: TreeCache.Entry
## The piece it grows from instead of its species and seed (grow_piece).
var _piece: TreeCache.Entry
## This tree's turn and size, applied to everything it draws and collides with.
var _variation := Transform3D.IDENTITY
## One instance per detail level, in TreeMesher.Level order: the whole tree, or
## an own tree's wood.
var _levels: Array[MeshInstance3D] = []
var _wood_body: StaticBody3D
var _foliage: Area3D
var _collision_outline: MeshInstance3D
# An own tree's leaves, one instance per detail level.
var _leaf_levels: Array[MeshInstance3D] = []
## Its notched lines, by Vector2i(branch, the line's number along it): the
## Dictionary TreeMesher.build_band takes, with the "instance" drawing its band,
## with the full level, and whether it is to be drawn again ("dirty").
var _rings := {}
## Which branches, and which leaf clusters, are gone (1).
var _gone := PackedByteArray()
var _gone_leaves := PackedByteArray()
# The wood's shape owners, and the branch each stands for; each touch volume's
# owner's part: (0, leaf cluster) or (1, twig's branch).
var _wood_owners := PackedInt32Array()
var _wood_parts := PackedInt32Array()
var _touch_parts := {}
# The shape owners put on the collision host, taken off again when rebuilt.
var _host_owners := PackedInt32Array()
# What to draw again at the end of the frame: the wood at every level (a branch
# is gone) or at the full level (its rings' gaps changed), the leaves.
var _wood_dirty := false
var _gaps_dirty := false
var _leaves_dirty := false


func _ready() -> void:
	for level in TreeMesher.Level.size():
		var instance := MeshInstance3D.new()
		# Internal, so the generated meshes are never saved into the scene.
		add_child(instance, false, Node.INTERNAL_MODE_FRONT)
		_levels.append(instance)
	if _piece:
		_adopt(_piece)
		_piece = null
	else:
		regenerate()


## Makes this the wood of a FelledTree: grown from `piece` with the tree's turn
## and size, own, colliding through `host`. Call before it enters the tree.
func grow_piece(tree_species: TreeSpecies, piece: TreeCache.Entry, variation: Transform3D,
		host: CollisionObject3D) -> void:
	species = tree_species
	_piece = piece
	_variation = variation
	collision_host = host
	own = true


func has_collision() -> bool:
	return _wood_body != null or not _host_owners.is_empty()


## The point every detail level, and an impostor, measures its distance to: the
## middle of the tree's bounds, turned and sized with the tree, in world space.
func detail_centre() -> Vector3:
	return global_transform * (_variation * _built.bounds.get_center()) if _built else global_position


## From the skeleton's space to the world: the tree's transform with its turn
## and size.
func skeleton_transform() -> Transform3D:
	return global_transform * _variation


## Which branches are gone (1), by index in its skeleton.
func gone_branches() -> PackedByteArray:
	return _gone


## The branch (an index in its skeleton) whose wood the `shape_index`-th
## collision shape of its body is, as a contact names it; -1 if none. Each wood
## shape is a shape owner of its own.
func branch_of_shape(shape_index: int) -> int:
	var body: CollisionObject3D = collision_host if collision_host else _wood_body
	if body == null or shape_index < 0 or shape_index >= _wood_owners.size():
		return -1
	var at := _wood_owners.find(body.shape_find_owner(shape_index))
	return _wood_parts[at] if at >= 0 else -1



## How many leaf clusters it has left.
func leaves_left() -> int:
	return _gone_leaves.count(0) if own else (skeleton.leaf_count() if skeleton else 0)


func regenerate_species() -> void:
	if species:
		TreeCache.forget(species)
		TreeImpostors.forget(species)
	regenerate()


func regenerate() -> void:
	if not is_node_ready():
		return
	_variation = species.variation_for(tree_seed) if species else Transform3D.IDENTITY
	_adopt(TreeCache.fetch(species, tree_seed) if species else null)


## Draws and collides as its own from now on (chopping; see above).
func make_own() -> void:
	if own:
		return
	own = true
	_adopt(_built)


## Cuts the tree through `branch` at `distance` along it (chopping, 2026-10-02).
## Its skeleton, without what is gone, is split there (TreeSkeleton.split): the
## tree keeps the part below, its cut capped with inner wood, and everything
## beyond becomes a FelledTree beside it, in the same place, which falls. With
## `toward` (level, in the world), it first tips over that way off the cut, as
## a felled trunk does. A piece cut off a moving piece moves on as it was.
func sever(branch: int, distance: float, toward := Vector3.ZERO) -> FelledTree:
	if _built == null or branch < 0 or branch >= skeleton.branch_count():
		return null
	if distance <= skeleton.distances[skeleton.branch_first_node[branch]] or distance >= skeleton.branch_length(branch):
		return null
	var id := skeleton.branch_id[branch]
	var whole := skeleton.pruned(_gone, _gone_leaves) if own else skeleton
	var cut := whole.branch_with_id(id)
	if cut < 0:
		return null
	var pieces := whole.split(cut, distance)
	var strikeable := Strikeable.of(self)
	var piece := FelledTree.new()
	piece.setup(species, TreeCache.Entry.new(species, 0, pieces[1]), _variation,
			strikeable.material if strikeable else null)
	var world := collision_host.get_parent() if collision_host else get_parent()
	var placement := Transform3D(global_basis.orthonormalized(), global_position)
	piece.transform = (world as Node3D).global_transform.affine_inverse() * placement if world is Node3D \
			else placement
	# A moving piece cut in two moves on as it was: each part as the point its
	# centre of mass is now at did (2026-10-03, for fall damage: copying the
	# whole's velocity was metres a second off for a limb of a spinning top).
	var host := collision_host as FelledTree
	var velocity := host.linear_velocity if host else Vector3.ZERO
	var spin := host.angular_velocity if host else Vector3.ZERO
	var centre: Vector3 = host.centre_of_mass() if host else Vector3.ZERO
	world.add_child(piece)
	if host:
		piece.linear_velocity = velocity + spin.cross(piece.centre_of_mass() - centre)
		piece.angular_velocity = spin
	severed.emit(piece)
	own = true
	_adopt(TreeCache.Entry.new(species, 0, pieces[0]))
	if host:
		host.linear_velocity = velocity + spin.cross(host.centre_of_mass() - centre)
	if toward != Vector3.ZERO:
		var cut_at := skeleton.branch_with_id(id)
		piece.tip_over(toward, skeleton_transform() * skeleton.sample_position(cut_at, distance),
				skeleton.sample_radius(cut_at, distance) * _variation.basis.get_scale().x,
				_wood_body if _wood_body else collision_host as PhysicsBody3D)
	reshaped.emit()
	if skeleton.branch_depth[0] == 0 and branch == 0 and collision_host == null:
		felled.emit(piece)
	return piece


## Shows a notch cut into `branch` round `at` (a distance along it: a segment
## line; chopping, 2026-10-02): the line's side k (of as many as `openings`
## has) cut in by openings[k], from 0 to 1, as TreeMesher.build_band cuts them.
## From the first call the full detail level leaves that stretch of the branch
## out and the band is drawn in its place, on an instance of its own, so a
## strike draws only its line again; the farther levels are too far to show
## notches. Cutting the tree, or growing it again, ends them.
func notch_ring(branch: int, at: float, openings: PackedFloat32Array, depth_share: float,
		height_share: float) -> void:
	if _built == null or branch < 0 or branch >= skeleton.branch_count() or _is_gone(branch):
		return
	make_own()
	var key := Vector2i(branch, roundi(at / skeleton.segment_length) if skeleton.segment_length > 0.0
			else roundi(at * 1000.0))
	if not _rings.has(key):
		# The deepest notch's mouth, and a little more.
		var reach := depth_share * height_share * skeleton.sample_radius(branch, at) + 0.01
		var base := skeleton.distances[skeleton.branch_first_node[branch]]
		var instance := MeshInstance3D.new()
		add_child(instance, false, Node.INTERNAL_MODE_FRONT)
		instance.transform = _variation
		instance.set_instance_shader_parameter(&"lod_centre", _built.bounds.get_center())
		_match_full_level(instance)
		_rings[key] = {"branch": branch, "at": at, "instance": instance,
				"from": maxf(at - reach, base + 0.01), "to": minf(at + reach, skeleton.branch_length(branch) - 0.01)}
		_gaps_dirty = true
	var ring: Dictionary = _rings[key]
	ring.openings = openings
	ring.depth_share = depth_share
	ring.height_share = height_share
	ring.dirty = true
	_redraw_later()


## Breaks off a twig (TreeSkeleton.is_twig: a branch with no segment line on
## wood to chop) with everything growing from it and their leaves (chopping,
## 2026-10-02): gone from the tree, its collision and touch volumes switched
## off, and drawn again without it at the end of the frame.
func break_branch(branch: int) -> void:
	if not own or branch < 0 or branch >= skeleton.branch_count() or _is_gone(branch):
		return
	if not skeleton.is_twig(branch, species.collision_min_radius_m):
		return
	var end := skeleton.subtree_end(branch)
	for gone in range(branch, end):
		_gone[gone] = 1
	for key: Vector2i in _rings.keys():
		if key.x >= branch and key.x < end:
			_rings[key].instance.queue_free()
			_rings.erase(key)
	for leaf in skeleton.leaf_count():
		var on := skeleton.leaf_branch[leaf]
		if on >= branch and on < end:
			_gone_leaves[leaf] = 1
	_switch_off_gone.call_deferred()
	_wood_dirty = true
	_leaves_dirty = true
	_redraw_later()


## Takes leaf cluster `leaf` away, and its touch volume; the leaves are drawn
## again without it at the end of the frame.
func lose_leaf(leaf: int) -> void:
	if not own or leaf < 0 or leaf >= _gone_leaves.size() or _gone_leaves[leaf]:
		return
	_gone_leaves[leaf] = 1
	_switch_off_gone.call_deferred()
	_leaves_dirty = true
	_redraw_later()


## Draws and collides as `entry` from now on: the variant's, its own, or the
## part that stays once cut. Its rings, and what was gone, start afresh.
func _adopt(entry: TreeCache.Entry) -> void:
	_built = entry
	skeleton = _built.skeleton if _built else null
	for ring: Dictionary in _rings.values():
		ring.instance.queue_free()
	_rings.clear()
	_wood_dirty = false
	_gaps_dirty = false
	_leaves_dirty = false
	_gone = PackedByteArray()
	_gone_leaves = PackedByteArray()
	if skeleton:
		_gone.resize(skeleton.branch_count())
		_gone_leaves.resize(skeleton.leaf_count())
	if own:
		_make_own_instances()
	for level in _levels.size():
		var whole: ArrayMesh = _built.meshes[level] if _built else null
		# An own tree's wood and leaves are each their own mesh: the variant's
		# two surfaces, split, until something changes them.
		_levels[level].mesh = _surface_of(whole, 0) if own and whole else whole
		if own:
			_leaf_levels[level].mesh = _surface_of(whole, 1) if whole and whole.get_surface_count() > 1 else null
	for instance in _all_instances():
		instance.transform = _variation
		if _built:
			instance.set_instance_shader_parameter(&"lod_centre", _built.bounds.get_center())
	_apply_detail_ranges()
	_rebuild_collision()


func _make_own_instances() -> void:
	if _leaf_levels.is_empty():
		for level in TreeMesher.Level.size():
			var instance := MeshInstance3D.new()
			add_child(instance, false, Node.INTERNAL_MODE_FRONT)
			_leaf_levels.append(instance)


func _all_instances() -> Array[MeshInstance3D]:
	var all: Array[MeshInstance3D] = []
	all.append_array(_levels)
	all.append_array(_leaf_levels)
	return all


func _apply_detail_ranges() -> void:
	if species == null:
		return
	set_detail_ranges(_levels, species, impostor_handoff, detail_preview)
	if not _leaf_levels.is_empty():
		set_detail_ranges(_leaf_levels, species, impostor_handoff, detail_preview)
	for ring: Dictionary in _rings.values():
		_match_full_level(ring.instance)


## Draws `instance` where the full level is drawn, dissolving with it.
func _match_full_level(instance: MeshInstance3D) -> void:
	var full := _levels[TreeMesher.Level.FULL]
	instance.visible = full.visible
	instance.visibility_range_begin = full.visibility_range_begin
	instance.visibility_range_end = full.visibility_range_end
	instance.set_instance_shader_parameter(&"lod_fade", full.get_instance_shader_parameter(&"lod_fade"))


## Sets where each of a tree's detail levels is drawn and where it dissolves
## into the next (one instance per TreeMesher.Level, in order): by distance, or
## one level everywhere for `preview` (1 to 3; 0 for by distance). `handoff`:
## an impostor takes over beyond the species' impostor distance.
static func set_detail_ranges(levels: Array[MeshInstance3D], tree_species: TreeSpecies, handoff: bool,
		preview: int) -> void:
	var band := tree_species.lod_fade_band_m
	var changes := tree_species.lod_changes(handoff)
	# Each level is drawn from its start to its end (0: no end), fading in over
	# the band after its start and out over the band before its end.
	var starts := [0.0, changes.x - band * 0.5, changes.y - band * 0.5]
	var ends := [changes.x + band * 0.5, changes.y + band * 0.5, changes.z + band * 0.5 if changes.z > 0.0 else 0.0]
	for level in levels.size():
		var instance := levels[level]
		instance.visible = preview == 0 or preview == level + 1
		var fade := Vector4.ZERO
		if preview == 0:
			instance.visibility_range_begin = starts[level]
			instance.visibility_range_end = ends[level]
			if level > 0:
				fade.x = starts[level]
				fade.y = starts[level] + band
			if ends[level] > 0.0:
				fade.z = ends[level] - band
				fade.w = ends[level]
		else:
			instance.visibility_range_begin = 0.0
			instance.visibility_range_end = 0.0
		instance.set_instance_shader_parameter(&"lod_fade", fade)


func _redraw_later() -> void:
	if not is_node_ready():
		return
	_redraw.call_deferred()


## Draws again whatever changed this frame: the wood (with its notched lines'
## gaps and without what is gone), the leaves, each line's band.
func _redraw() -> void:
	if _built == null or not own:
		return
	if _wood_dirty or _gaps_dirty:
		var gaps := {}
		for ring: Dictionary in _rings.values():
			var on: Array = gaps.get(ring.branch, [])
			on.append(Vector2(ring.from, ring.to))
			gaps[ring.branch] = on
		for level in _levels.size():
			if _wood_dirty or level == TreeMesher.Level.FULL:
				var wood := TreeMesher.build_wood(skeleton, species, level,
						gaps if level == TreeMesher.Level.FULL else {}, _gone)
				wood.custom_aabb = _built.bounds
				_levels[level].mesh = wood
		_wood_dirty = false
		_gaps_dirty = false
	if _leaves_dirty:
		_leaves_dirty = false
		for level in _leaf_levels.size():
			var leaves := TreeMesher.build_leaves(skeleton, species, level, _gone_leaves)
			leaves.custom_aabb = _built.bounds
			_leaf_levels[level].mesh = leaves if leaves.get_surface_count() > 0 else null
	for ring: Dictionary in _rings.values():
		if ring.dirty:
			ring.dirty = false
			var band := TreeMesher.build_band(skeleton, species, ring)
			band.custom_aabb = _built.bounds
			ring.instance.mesh = band


## Replaces the collision with fresh objects, filled before they enter the
## physics world, so the physics engine builds each one's shapes once. The
## shapes themselves are the variant's, shared. A piece's go onto its host,
## sized there (rigid bodies take no scale).
func _rebuild_collision() -> void:
	for old in [_wood_body, _foliage, _collision_outline]:
		if old:
			old.queue_free()
	_wood_body = null
	_foliage = null
	_collision_outline = null
	for owner_id in _host_owners:
		collision_host.remove_shape_owner(owner_id)
	_host_owners = PackedInt32Array()
	_touch_parts.clear()
	if _built == null or not collision_active or (Engine.is_editor_hint() and not show_collision):
		return
	var wood := _built.wood()
	var leaves := _built.leaves()
	var sized := wood.baked(_variation)
	_wood_parts = wood.parts
	var strikeable := Strikeable.of(self)
	if collision_host:
		_host_owners = sized.apply_to(collision_host)
		_wood_owners = _host_owners
		if strikeable:
			strikeable.mark(collision_host)
	else:
		_wood_body = StaticBody3D.new()
		_wood_body.collision_layer = STATIC_LAYER
		_wood_body.collision_mask = 0
		_wood_body.transform = _variation
		_wood_owners = wood.apply_to(_wood_body)
		add_child(_wood_body, false, Node.INTERNAL_MODE_FRONT)
		# A tree that takes strikes (one that can be chopped) is struck through its wood.
		if strikeable:
			strikeable.mark(_wood_body)
	var twigs := _built.twigs() if own else TreeCollider.Shapes.new()
	if leaves.size() + twigs.size() > 0:
		_foliage = Area3D.new()
		_foliage.collision_layer = FOLIAGE_LAYER
		_foliage.collision_mask = 0
		_foliage.monitoring = false
		if own:
			# What breaks its leaves: never the player's body; for a piece, its
			# surroundings too.
			_foliage.collision_mask = DYNAMIC_LAYER | HELD_LAYER | HANDS_LAYER | ENEMY_LAYER \
					| (STATIC_LAYER if collision_host else 0)
			_foliage.monitoring = true
			_foliage.body_shape_entered.connect(_on_touched)
		for kind in 2:
			var volumes := leaves if kind == 0 else twigs
			if collision_host:
				volumes = volumes.baked(_variation)
			var owners := volumes.apply_to(_foliage)
			for i in owners.size():
				_touch_parts[owners[i]] = Vector2i(kind, volumes.parts[i])
		if not collision_host:
			_foliage.transform = _variation
		add_child(_foliage, false, Node.INTERNAL_MODE_FRONT)
	_switch_off_gone()
	if show_collision:
		_collision_outline = MeshInstance3D.new()
		_collision_outline.mesh = TreeCollider.debug_mesh(wood, leaves)
		_collision_outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_collision_outline.transform = _variation
		add_child(_collision_outline, false, Node.INTERNAL_MODE_FRONT)


## Switches off the collision and touch volumes of what is gone.
func _switch_off_gone() -> void:
	var body: CollisionObject3D = collision_host if collision_host else _wood_body
	if body:
		for i in _wood_owners.size():
			if _is_gone(_wood_parts[i]):
				body.shape_owner_set_disabled(_wood_owners[i], true)
	if _foliage:
		for owner_id: int in _touch_parts:
			var part: Vector2i = _touch_parts[owner_id]
			var gone := _gone_leaves[part.y] if part.x == 0 else int(_is_gone(part.y))
			if gone:
				_foliage.shape_owner_set_disabled(owner_id, true)


func _is_gone(branch: int) -> bool:
	return branch >= 0 and branch < _gone.size() and _gone[branch] == 1



## A body touched a leaf cluster or a bare twig: it breaks if the body moved
## through it at BREAK_SPEED or faster, or if this is a piece and the body is
## its surroundings; never for the player's body.
func _on_touched(_body_rid: RID, body: Node3D, _body_shape: int, touch_shape: int) -> void:
	if body == null or body == collision_host or body == _wood_body:
		return
	var layer: int = body.get("collision_layer") if "collision_layer" in body else 0
	if layer & PLAYER_LAYER:
		return
	var owner_id := _foliage.shape_find_owner(touch_shape)
	if not _touch_parts.has(owner_id):
		return
	var at := _foliage.global_transform * _foliage.shape_owner_get_transform(owner_id).origin
	var surroundings := collision_host != null and not layer & (HELD_LAYER | HANDS_LAYER)
	if not surroundings and _speed(body, at) < BREAK_SPEED:
		return
	var part: Vector2i = _touch_parts[owner_id]
	if part.x == 1:
		break_branch(part.y)
	elif skeleton.is_twig(skeleton.leaf_branch[part.y], species.collision_min_radius_m):
		break_branch(skeleton.leaf_branch[part.y])
	else:
		lose_leaf(part.y)


## How fast `body` moves at a point, against this tree there.
func _speed(body: Node3D, at: Vector3) -> float:
	var velocity := _velocity_at(body, at)
	if collision_host:
		velocity -= _velocity_at(collision_host, at)
	return velocity.length()


static func _velocity_at(body: Node3D, at: Vector3) -> Vector3:
	if not body is PhysicsBody3D:
		return Vector3.ZERO
	var state := PhysicsServer3D.body_get_direct_state((body as PhysicsBody3D).get_rid())
	return state.get_velocity_at_local_position(at - body.global_position) if state else Vector3.ZERO


## One surface of a mesh, as a mesh of its own with the same bounds.
static func _surface_of(mesh: ArrayMesh, surface: int) -> ArrayMesh:
	if mesh == null or surface >= mesh.get_surface_count():
		return null
	var part := ArrayMesh.new()
	part.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mesh.surface_get_arrays(surface))
	part.surface_set_material(0, mesh.surface_get_material(surface))
	part.custom_aabb = mesh.custom_aabb
	return part
