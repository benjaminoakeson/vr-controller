@tool
class_name TreeScatter
extends Node3D

## Grows a forest: places ProceduralTree nodes over a rectangle centred on
## this node, from a seed, so the same seed always grows the same forest.
##
## Trees are spread by dart throwing: random points, each kept only if no tree
## already stands within the minimum spacing, so the forest is even without
## looking like a grid. None stand within the clearing around the centre, where
## a player can start. Each tree picks a species from the list (repeat one to
## make it more common) and a seed, which picks its variant, turn and size.
##
## Trees are added under the streamer, if there is one, so it gives them
## collision only near the player; they are internal children, never saved
## with the scene. The ground is taken to be flat at this node's height.
##
## Beyond each species' impostor distance its trees are drawn as cards, all of
## them in one MultiMesh per species (TreeImpostors). The cards appear, and the
## trees hand their far level over to them, once the species' pictures are
## baked, a frame or two after the forest grows; until then, and wherever they
## can't be baked, the trees draw themselves as before.

## Where trees go so their collision streams; without one, they go under this
## node and keep their collision.
@export var streamer: TreeCollisionStreamer
## What the forest grows. Repeat a species to make it more common.
@export var species: Array[TreeSpecies] = []
## Which forest grows: the same seed always grows the same trees in the same places.
@export var forest_seed := 0:
	set(value):
		forest_seed = value
		scatter()
## Size of the rectangle to fill, centred on this node, along X and Z.
@export var area_size_m := Vector2(180.0, 180.0)
## Most trees to place. Fewer fit if the spacing leaves no room.
@export_range(0, 5000, 1) var tree_count := 400
## No two trees closer than this.
@export_range(1.0, 50.0, 0.5, "suffix:m") var min_spacing_m := 7.0
## No trees within this distance of the centre.
@export_range(0.0, 100.0, 0.5, "suffix:m") var clearing_radius_m := 8.0
## Grows the forest again, rebuilding its species from their settings, after
## either was edited.
@export_tool_button("Scatter again", "Reload") var scatter_action := scatter_again

## The trees placed, in the order they were placed.
var trees: Array[ProceduralTree] = []
## One MultiMesh of impostor cards per species that has them.
var impostors: Array[MultiMeshInstance3D] = []

## Bumped whenever the forest is cleared, so a bake finishing late for an old
## forest is ignored.
var _generation := 0


func _ready() -> void:
	scatter()


func _exit_tree() -> void:
	_clear()


func scatter_again() -> void:
	for kind in species:
		if kind:
			TreeCache.forget(kind)
			TreeImpostors.forget(kind)
	scatter()


## Removes the trees placed before and places them again from the settings.
func scatter() -> void:
	_clear()
	if not is_node_ready() or species.is_empty():
		return
	var parent: Node3D = self
	if streamer:
		parent = streamer
	var to_parent := parent.global_transform.affine_inverse() * global_transform
	var rng := RandomNumberGenerator.new()
	rng.seed = forest_seed
	var half := area_size_m * 0.5
	# Cells as wide as the spacing: a point's neighbours closer than the spacing
	# can only be in its own cell or the eight around it.
	var cells := {}
	var attempts := tree_count * 30
	while trees.size() < tree_count and attempts > 0:
		attempts -= 1
		var point := Vector2(rng.randf_range(-half.x, half.x), rng.randf_range(-half.y, half.y))
		if point.length() < clearing_radius_m or _crowded(cells, point):
			continue
		var cell := Vector2i((point / min_spacing_m).floor())
		if not cells.has(cell):
			cells[cell] = PackedVector2Array()
		cells[cell].append(point)
		var tree := ProceduralTree.new()
		tree.species = species[rng.randi() % species.size()]
		tree.tree_seed = rng.randi()
		tree.transform = to_parent * Transform3D(Basis.IDENTITY, Vector3(point.x, 0.0, point.y))
		parent.add_child(tree, false, Node.INTERNAL_MODE_BACK)
		trees.append(tree)
	if streamer and not Engine.is_editor_hint():
		streamer.refresh_now()
	_add_impostors()


## Places a card for every tree of each species that has impostors, hidden
## until its pictures are baked.
func _add_impostors() -> void:
	var by_species := {}
	for tree in trees:
		if tree.species.has_impostors():
			if not by_species.has(tree.species):
				by_species[tree.species] = []
			by_species[tree.species].append(tree)
	for kind: TreeSpecies in by_species:
		var its_trees: Array = by_species[kind]
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.use_custom_data = true
		var quad := QuadMesh.new()
		quad.size = Vector2.ONE
		multimesh.mesh = quad
		multimesh.instance_count = its_trees.size()
		for i in its_trees.size():
			var card := card_for(its_trees[i])
			multimesh.set_instance_transform(i, card[0])
			multimesh.set_instance_custom_data(i, card[1])
		var cards := MultiMeshInstance3D.new()
		cards.multimesh = multimesh
		cards.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		cards.visible = false
		add_child(cards, false, Node.INTERNAL_MODE_BACK)
		impostors.append(cards)
		_show_impostors(cards, kind, its_trees, _generation)


## A tree's impostor card, as [transform in this node's space, custom data].
## The card is measured from where the tree's levels measure their distance
## to, and carries the tree's turn and size, and its variant's layer and the
## centre its picture was framed on, so the shader can stand the picture's
## trunk on the tree's (tree_impostor.gdshader).
func card_for(tree: ProceduralTree) -> Array:
	var kind := tree.species
	var turned := tree.global_basis * kind.variation_for(tree.tree_seed).basis
	var placed := Transform3D(global_basis.inverse() * turned, to_local(tree.detail_centre()))
	var pictured := TreeCache.fetch(kind, tree.tree_seed).bounds.get_center()
	return [placed, Color(kind.variant_for(tree.tree_seed), pictured.x, pictured.y, pictured.z)]


## Bakes a species' pictures, then shows its cards and hands its trees over.
func _show_impostors(cards: MultiMeshInstance3D, kind: TreeSpecies, its_trees: Array,
		generation: int) -> void:
	var baked := await TreeImpostors.bake(kind, self)
	if baked == null or generation != _generation or not is_instance_valid(cards):
		return
	var material := ShaderMaterial.new()
	material.shader = preload("res://assets/vegetation/trees/tree_impostor.gdshader")
	material.set_shader_parameter("color_layers", baked.color)
	material.set_shader_parameter("normal_layers", baked.normal)
	material.set_shader_parameter("card_size", baked.card_size)
	material.set_shader_parameter("fade", TreeImpostors.fade_for(kind))
	material.set_shader_parameter("roughness", kind.impostor_roughness)
	cards.material_override = material
	# Cards are placed in the shader, so the engine can't size them itself.
	var multimesh := cards.multimesh
	var reach := 0.0
	var bounds := AABB()
	var first := true
	for tree: ProceduralTree in its_trees:
		if not is_instance_valid(tree):
			continue
		var placed: Transform3D = card_for(tree)[0]
		reach = maxf(reach, placed.basis.get_scale().x * baked.card_size)
		bounds = AABB(placed.origin, Vector3.ZERO) if first else bounds.expand(placed.origin)
		first = false
	multimesh.custom_aabb = bounds.grow(reach)
	cards.visible = true
	for tree: ProceduralTree in its_trees:
		if is_instance_valid(tree):
			tree.impostor_handoff = true

func _crowded(cells: Dictionary, point: Vector2) -> bool:
	var centre := Vector2i((point / min_spacing_m).floor())
	for x in range(-1, 2):
		for y in range(-1, 2):
			for other in cells.get(centre + Vector2i(x, y), PackedVector2Array()):
				if point.distance_to(other) < min_spacing_m:
					return true
	return false


func _clear() -> void:
	_generation += 1
	for tree in trees:
		if is_instance_valid(tree):
			tree.get_parent().remove_child(tree)
			tree.queue_free()
	trees.clear()
	for cards in impostors:
		if is_instance_valid(cards):
			remove_child(cards)
			cards.queue_free()
	impostors.clear()
