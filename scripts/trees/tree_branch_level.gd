@tool
class_name TreeBranchLevel
extends Resource

## How the branches at one depth of a tree grow: the trunk is depth 0.
##
## Every branch is a whole number of segments long (2026-10-02): each tree has
## one segment length (TreeSpecies), and the tree can be chopped at every
## segment line along any branch. How many segments a branch has is picked here.
##
## One set of path settings makes every shape. With all of them at zero the path
## is straight. Kinks turn it sharply at single nodes (angular). Bend curves it
## smoothly and continuously (curvy). Up bias pulls it toward the sky, or toward
## the ground when negative (drooping). The path only turns between segment
## lines, so each line is a straight joint: a cut there is square to both sides.
##
## Shared, read-only configuration: nothing about one particular tree is stored here.

@export_group("Segments")
## How many segments long a branch at this depth is, picked per branch between
## these; for the trunk, per tree, so the trunk's count times the segment
## length is the tree's height. A branch's pick is scaled by
## length_along_parent, but it is at least one segment.
@export_range(1, 200, 1) var segments_min := 8
@export_range(1, 200, 1) var segments_max := 12
## Skeleton nodes per segment. The path turns only at the nodes between two
## segment lines, so 1 keeps every segment straight and the whole branch
## straight; more follow bends and kinks more closely, at more mesh rings.
@export_range(1, 8, 1) var steps_per_segment := 2

@export_group("Trunk (depth 0 only)")
## Radius where the trunk meets the ground.
@export_range(0.02, 2.0, 0.01, "suffix:m") var base_radius_m := 0.25

@export_group("Branching (depth 1 and deeper)")
## Segment count multiplier (Y) by where the branch grows on its parent (X, 0 at
## the parent's base to 1 at its tip). This shapes the crown: long low and short
## high makes a cone, a peak in the middle makes it round. Without a curve it is 1.
@export var length_along_parent: Curve
## Base radius as a share of the parent's radius where the branch grows. A branch
## is never thicker than its parent there.
@export_range(0.05, 1.0, 0.01) var radius_ratio := 0.5
## Where along the parent branches start and stop growing, as shares of its length.
@export_range(0.0, 1.0, 0.01) var start_fraction := 0.3
@export_range(0.0, 1.0, 0.01) var end_fraction := 0.95
## Places where branches grow, per metre of that span of the parent. Longer
## parents get more branches. Each place is in the middle of one of the
## parent's segments, so no segment line runs through where a branch joins: at
## most one place per segment.
@export_range(0.0, 10.0, 0.05, "suffix:1/m") var density_per_m := 1.0
## Branches sharing one place on the parent, spaced evenly around it: 1 for
## alternating branches, 3 to 5 for the rings of branches pines grow.
@export_range(1, 8, 1) var branches_per_whorl := 1
## Starting angle between a branch and its parent's direction.
@export_range(0.0, 150.0, 1.0, "suffix:°") var spread_angle_deg := 45.0
## Random change to the spread angle, up to this much either way.
@export_range(0.0, 60.0, 1.0, "suffix:°") var spread_jitter_deg := 10.0
## Turn around the parent from one place where branches grow to the next. The
## golden angle (137.5°) spreads them evenly, as many plants do.
@export_range(0.0, 360.0, 0.5, "suffix:°") var phyllotaxis_deg := 137.5
## Random change to that turn, up to this much either way.
@export_range(0.0, 180.0, 1.0, "suffix:°") var phyllotaxis_jitter_deg := 15.0

@export_group("Leaves")
## Leaf clusters per metre along the leafy part of branches at this depth; 0 for
## none. How they are drawn is set on the species.
@export_range(0.0, 20.0, 0.05, "suffix:1/m") var leaves_per_m := 0.0
## Where along a branch its leaves start, as a share of its length. They carry
## on to its tip.
@export_range(0.0, 1.0, 0.01) var leaf_start_fraction := 0.4
## How irregularly clusters are spaced. At 0 they are even, the last at the tip;
## at 1 each can be anywhere in its share of the leafy part, so a sparse density
## gives the odd cluster here and there.
@export_range(0.0, 1.0, 0.01) var leaf_spacing_jitter := 0.0
## Extra clusters at the very tip of branches at this depth, spaced evenly around
## it, so the branch ends in leaves instead of a bare point. On the trunk this
## tops the tree with leaves.
@export_range(0, 8, 1) var tip_leaves := 0

@export_group("Girth")
## Radius along the path, as a share of the base radius (Y, 0 to 1) over the
## share of the length travelled (X, 0 to 1). Without a curve the radius shrinks
## in a straight line from the base radius to the minimum radius.
@export var girth_falloff: Curve
## The radius never shrinks below this, unless the branch starts thinner.
@export_range(0.002, 0.5, 0.001, "suffix:m") var min_radius_m := 0.03

@export_group("Path style")
## Chance of a sharp turn at each node between two segment lines.
@export_range(0.0, 1.0, 0.01) var kink_chance := 0.0
## Size of a sharp turn. Each kink turns by between half and all of this.
@export_range(0.0, 90.0, 1.0, "suffix:°") var kink_angle_deg := 25.0
## Largest smooth turning rate. The rate and its direction drift along the path.
@export_range(0.0, 90.0, 0.5, "suffix:°/m") var bend_deg_per_m := 0.0
## How quickly the bend changes along the path: about how many turns per metre.
@export_range(0.01, 4.0, 0.01, "suffix:1/m") var bend_frequency := 0.3
## Turning toward straight up, or toward straight down when negative.
@export_range(-90.0, 90.0, 0.5, "suffix:°/m") var up_bias_deg_per_m := 0.0
## Round the path between nodes with a spline (curvy shapes) instead of keeping
## hard corners at each node (angular shapes).
@export var smooth_mesh := false
## Extra rings between two nodes when the mesh is smoothed.
@export_range(1, 8, 1) var smooth_subdivisions := 2


## Radius at a share t (0 to 1) of the length of a branch starting this thick.
func radius_at(t: float, base_radius: float) -> float:
	var floor_radius := minf(min_radius_m, base_radius)
	var share: float
	if girth_falloff:
		share = girth_falloff.sample_baked(clampf(t, 0.0, 1.0))
	else:
		share = lerpf(1.0, floor_radius / base_radius, clampf(t, 0.0, 1.0))
	return maxf(base_radius * share, floor_radius)


## A segment count between segments_min and segments_max, drawn from `rng`.
func pick_segments(rng: RandomNumberGenerator) -> int:
	return rng.randi_range(mini(segments_min, segments_max), maxi(segments_min, segments_max))


## Segment count multiplier for a branch growing at a share (0 to 1) of its
## parent's length.
func length_share_at(position_on_parent: float) -> float:
	if length_along_parent:
		return maxf(length_along_parent.sample_baked(clampf(position_on_parent, 0.0, 1.0)), 0.0)
	return 1.0
