@tool
class_name TreeCache
extends RefCounted

## Built trees, shared by every ProceduralTree of the same species and variant:
## the skeleton, the three detail meshes and the collision shapes are made once
## and reused, so a forest drawn from a small pool of variants costs a handful
## of builds, not one per tree.
##
## Everything here is shared and read-only. A tree that changes its own shape
## (cut at a segment line: ProceduralTree.sever) splits the skeleton into pieces
## of its own and builds an Entry for each outside the cache.
##
## Tool script, so its static state is set up in the editor too.

## One built variant, or one piece of a cut tree.
class Entry:
	var skeleton: TreeSkeleton
	## One per TreeMesher.Level, all with the same custom bounds.
	var meshes: Array[ArrayMesh] = []
	## Bounds shared by all the levels, in the tree's space.
	var bounds := AABB()

	var _species: TreeSpecies
	var _wood: TreeCollider.Shapes
	var _leaves: TreeCollider.Shapes
	var _twigs: TreeCollider.Shapes

	## Grows the variant's skeleton, or takes `piece` (a skeleton split off a tree).
	func _init(species: TreeSpecies, variant_seed: int, piece: TreeSkeleton = null) -> void:
		_species = species
		skeleton = piece if piece else TreeSkeletonBuilder.build(species, variant_seed)
		for level in TreeMesher.Level.size():
			var mesh := TreeMesher.build(skeleton, species, level)
			meshes.append(mesh)
			if mesh.get_surface_count() > 0:
				bounds = mesh.get_aabb() if bounds.size == Vector3.ZERO else bounds.merge(mesh.get_aabb())
		# The engine measures visibility ranges to the centre of each instance's
		# bounds; sharing them keeps every level measuring the same distance.
		for mesh in meshes:
			mesh.custom_aabb = bounds

	## Wood collision shapes, worked out the first time a tree needs them.
	func wood() -> TreeCollider.Shapes:
		if _wood == null:
			_wood = TreeCollider.wood(skeleton, _species)
		return _wood

	## Leaf touch volumes, worked out the first time a tree needs them.
	func leaves() -> TreeCollider.Shapes:
		if _leaves == null:
			_leaves = TreeCollider.leaves(skeleton, _species) if _species.leaf_touch_volumes \
					else TreeCollider.Shapes.new()
		return _leaves

	## Bare twigs' touch volumes (TreeCollider.twigs), worked out the first time a
	## tree that can lose them needs them.
	func twigs() -> TreeCollider.Shapes:
		if _twigs == null:
			_twigs = TreeCollider.twigs(skeleton, _species)
		return _twigs


## Species to {variant: Entry}.
static var _entries := {}


## The built variant a tree of this species and seed uses, building it if no
## tree has yet.
static func fetch(species: TreeSpecies, tree_seed: int) -> Entry:
	var variant := species.variant_for(tree_seed)
	if not _entries.has(species):
		_entries[species] = {}
	var variants: Dictionary = _entries[species]
	if not variants.has(variant):
		variants[variant] = Entry.new(species, variant)
	return variants[variant]


## Drops everything built for a species, after its settings were edited.
static func forget(species: TreeSpecies) -> void:
	_entries.erase(species)


## How many variants are built for a species.
static func built_count(species: TreeSpecies) -> int:
	return (_entries.get(species, {}) as Dictionary).size()
