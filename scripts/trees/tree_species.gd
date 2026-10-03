@tool
class_name TreeSpecies
extends Resource

## Everything that makes one kind of tree: how it grows and how it is drawn.
## A tree is this species plus a seed; the same pair always makes the same tree.
##
## Shared, read-only configuration: nothing about one particular tree is stored here.

enum LeafStyle {
	## No leaves.
	NONE,
	## Two crossed quads per cluster, drawn with an alpha-scissor leaf texture.
	CARDS,
	## An opaque low-poly blob per cluster.
	CLUMPS,
}

## How the trunk grows.
@export var trunk: TreeBranchLevel
## How the branches at each further depth grow: the first entry is branches off
## the trunk, the next is branches off those, and so on.
@export var branch_levels: Array[TreeBranchLevel] = []
## Growth stops at this many branches, trunk included, so a mistyped density
## can't stall the editor or the level load.
@export_range(1, 5000, 1) var max_branches := 500

@export_group("Segments")
## The length of every segment of a tree, picked per tree between these (each
## branch level picks how many segments its branches have). A tree can be
## chopped at every segment line, a whole number of segments along any of its
## branches, so it always comes apart in whole segments (2026-10-02).
@export_range(0.1, 4.0, 0.01, "suffix:m") var segment_length_min_m := 0.45
@export_range(0.1, 4.0, 0.01, "suffix:m") var segment_length_max_m := 0.55

@export_group("Appearance")
## Bark and inner wood in one material, so a tree's wood is one draw call.
## Expects tree_wood.gdshader, which picks inner wood where UV2.x is 1.
@export var wood_material: Material
## Width of one repeat of the bark texture around a branch. The repeat count is
## rounded to a whole number per branch, so the seam never shows.
@export_range(0.05, 4.0, 0.01, "suffix:m") var bark_tile_width_m := 0.6
## Height of one repeat of the bark texture along a branch.
@export_range(0.05, 4.0, 0.01, "suffix:m") var bark_tile_height_m := 1.0
## Sides of the tube around a branch as thick as the trunk base.
@export_range(3, 24, 1) var max_sides := 8
## Sides of the tube around the thinnest branches.
@export_range(3, 24, 1) var min_sides := 4
## A branch whose base is this thick or thicker gets the most sides. Thinner
## branches get proportionally fewer, down to the fewest. Sides stay the same
## along one branch, so its rings line up.
@export_range(0.02, 2.0, 0.01, "suffix:m") var full_sides_radius_m := 0.2

@export_group("Variety")
## How many different trees the species grows. A tree's seed picks one, and
## every tree on the same one shares its meshes and collision, so a forest
## costs this many builds per species. 0 grows a different tree for every seed.
@export_range(0, 256, 1) var variants := 8
## Largest turn about the vertical, either way, picked per tree from its seed.
@export_range(0.0, 180.0, 1.0, "suffix:°") var turn_variation_deg := 180.0
## Largest change in size, as a share of it, either way, picked per tree.
@export_range(0.0, 0.5, 0.01) var size_variation := 0.15

@export_group("Detail levels")
## From about this far away (to the middle of the tree), the medium level is
## drawn instead of the full one.
@export_range(1.0, 500.0, 0.5, "suffix:m") var lod_medium_distance_m := 25.0
## From about this far away, the far level is drawn instead of the medium one.
@export_range(1.0, 1000.0, 0.5, "suffix:m") var lod_far_distance_m := 60.0
## Beyond about this distance the tree isn't drawn at all; 0 draws it at any distance.
@export_range(0.0, 5000.0, 1.0, "suffix:m") var lod_hide_distance_m := 250.0
## Width of the band around each of those distances where one level dissolves
## into the next, instead of switching at once.
@export_range(0.5, 50.0, 0.5, "suffix:m") var lod_fade_band_m := 4.0
## The medium level leaves out branches whose base is thinner than this.
@export_range(0.0, 0.5, 0.001, "suffix:m") var lod_medium_min_branch_radius_m := 0.015
## The far level leaves out branches whose base is thinner than this.
@export_range(0.0, 1.0, 0.001, "suffix:m") var lod_far_min_branch_radius_m := 0.04
## The medium level keeps one leaf cluster in this many, each enlarged to keep
## the crown's leaf area.
@export_range(1, 16, 1) var lod_medium_leaf_step := 2
## The far level keeps one leaf cluster in this many, enlarged the same way.
@export_range(1, 32, 1) var lod_far_leaf_step := 4

@export_group("Impostors")
## Trees placed by a TreeScatter are drawn beyond about this distance as a
## picture of themselves on a card that turns to face the player: one draw call
## per species for all of them, so a forest can be seen much further. 0: no
## impostors. Needs variants, since each variant is pictured once.
@export_range(0.0, 2000.0, 1.0, "suffix:m") var impostor_distance_m := 100.0
## Width and height of each variant's picture, in pixels.
@export_range(64, 1024, 32) var impostor_resolution := 256
## Roughness the pictures are lit with.
@export_range(0.0, 1.0, 0.01) var impostor_roughness := 0.85

@export_group("Collision")
## Wood this thick or thicker is solid; where a branch thins below it, its
## collision stops, so twigs pass through hands and bodies.
@export_range(0.005, 0.5, 0.005, "suffix:m") var collision_min_radius_m := 0.025
## How far the branch may stray from a collision capsule's axis before another
## capsule starts. Larger means fewer capsules, following bends less closely.
@export_range(0.005, 0.5, 0.005, "suffix:m") var collision_tolerance_m := 0.05
## How much the branch's radius may change along one capsule. Each capsule is
## the middle of that range, so it is at most half this too thick or too thin.
@export_range(0.005, 0.3, 0.005, "suffix:m") var collision_radius_tolerance_m := 0.03
## Give leaf clusters touch-only volumes on the Foliage layer.
@export var leaf_touch_volumes := true
## What a felled piece weighs for each segment of wood it holds (2026-10-02:
## "Trees are insanely heavy in real life... each segment (trunk root) should be
## 75kg and each branch segment should be 25kg"): a segment of the trunk, and a
## segment of any other branch. A piece weighs the sum of its segments
## (FelledTree). Twigs, branches with no line to chop (TreeSkeleton.is_twig),
## weigh nothing, though a few are 5 to 6 cm thick at the base: they break off
## whole, as leaves do.
@export_range(1.0, 1000.0, 0.5, "suffix:kg") var trunk_segment_mass_kg := 75.0
@export_range(1.0, 1000.0, 0.5, "suffix:kg") var branch_segment_mass_kg := 25.0

@export_group("Leaves")
## How leaf clusters are drawn. Switching style keeps where they grow. Where
## they grow, and how many, is set per branch level.
@export var leaf_style := LeafStyle.NONE
## Cards expect a material using tree_leaf.gdshader, which keeps the crown's
## normal on both sides of each card, with a texture of a spray growing
## rightward from its stem (see leaf_card_stem). Clumps expect an opaque material.
@export var leaf_material: Material
## Card width, or clump diameter.
@export_range(0.05, 3.0, 0.01, "suffix:m") var leaf_size_m := 0.5
## Random change to the size, as a share of it, either way.
@export_range(0.0, 0.9, 0.01) var leaf_size_jitter := 0.25
## Angle between a cluster and its branch's direction.
@export_range(0.0, 150.0, 1.0, "suffix:°") var leaf_angle_deg := 45.0
## Random change to that angle, up to this much either way.
@export_range(0.0, 90.0, 1.0, "suffix:°") var leaf_angle_jitter_deg := 20.0
## Card height as a share of its width. Match the leaf texture's proportions.
@export_range(0.1, 4.0, 0.01) var leaf_card_aspect := 0.69
## Where the spray's stem is in the leaf texture, in UV (0 to 1 across, 0 to 1
## down). The card is placed so this point sits on the branch.
@export var leaf_card_stem := Vector2(0.0, 0.5)
## How lumpy clumps are: random change to each corner's distance from the
## clump's centre, as a share of the radius, either way.
@export_range(0.0, 0.6, 0.01) var leaf_clump_jitter := 0.25
## Leaf clusters stop at this many, so a mistyped density can't stall the
## editor or the level load.
@export_range(0, 20000, 1) var max_leaves := 3000


## The variant a tree with this seed grows: the seed its skeleton is built from.
func variant_for(tree_seed: int) -> int:
	return posmod(tree_seed, variants) if variants > 0 else tree_seed


## The turn and size a tree with this seed gets, drawn from its own generator
## so they don't follow the variant.
func variation_for(tree_seed: int) -> Transform3D:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(tree_seed)
	var turn := deg_to_rad(rng.randf_range(-turn_variation_deg, turn_variation_deg))
	var size := 1.0 + rng.randf_range(-size_variation, size_variation)
	return Transform3D(Basis(Vector3.UP, turn).scaled(Vector3.ONE * size), Vector3.ZERO)


## Where the detail levels change, in metres from the middle of the tree:
## (full to medium, medium to far, far to hidden or to the impostor). Each is
## the middle of a fade band, and each keeps at least a band from the last. The
## last is 0 when a tree without an impostor is never hidden.
func lod_changes(to_impostor: bool) -> Vector3:
	var band := lod_fade_band_m
	var medium := maxf(lod_medium_distance_m, band * 0.5)
	var far := maxf(lod_far_distance_m, medium + band)
	var last := impostor_distance_m if to_impostor else lod_hide_distance_m
	return Vector3(medium, far, maxf(last, far + band) if last > 0.0 else 0.0)


## Whether trees of this species can hand over to impostors.
func has_impostors() -> bool:
	return impostor_distance_m > 0.0 and variants > 0


## The settings for branches at a depth (0 for the trunk), or null past the last.
func level_for_depth(depth: int) -> TreeBranchLevel:
	if depth == 0:
		return trunk
	if depth - 1 < branch_levels.size():
		return branch_levels[depth - 1]
	return null
