class_name TreeSkeletonBuilder
extends RefCounted

## Grows a TreeSkeleton from a species and a seed. The same pair always grows
## the same skeleton: every random choice comes from one generator seeded here,
## drawn in a fixed order.
##
## The tree grows in segments (2026-10-02): its segment length is drawn first,
## then the trunk's segment count, so its height; every branch is a whole
## number of segments, with a node at every segment line and the path turning
## only between lines. Branches grow from the middles of their parent's
## segments, so no line runs through where one joins as far as it fits.
##
## Each branch is grown whole, then its children, each child's own children
## before its next sibling. So each branch's nodes are stored together. Leaf
## clusters are placed last, so leaf settings never change the branches.

## Seeds the bend noise's second channel away from the first, so the two don't match.
const _BEND_CHANNEL_OFFSET := 1000.0
const _EPSILON := 0.00001
## The shortest segment, whatever the species asks.
const _MIN_SEGMENT := 0.05
## How close to its segment's lines a branch's base may be moved, so its
## junction is centred in the segment.
const _LINE_CLEARANCE := 0.02


static func build(species: TreeSpecies, tree_seed: int) -> TreeSkeleton:
	var skeleton := TreeSkeleton.new()
	if species == null or species.trunk == null:
		return skeleton
	var rng := RandomNumberGenerator.new()
	rng.seed = tree_seed
	skeleton.segment_length = maxf(rng.randf_range(species.segment_length_min_m, species.segment_length_max_m),
			_MIN_SEGMENT)
	var trunk := species.trunk
	var branch := _grow_branch(skeleton, trunk, rng, 0, -1, 0.0, Vector3.ZERO, Vector3.UP,
			trunk.pick_segments(rng), trunk.base_radius_m)
	skeleton.first_line_radius = skeleton.sample_radius(branch,
			minf(skeleton.segment_length, skeleton.branch_length(branch)))
	_grow_children(skeleton, species, rng, branch)
	if species.leaf_style != TreeSpecies.LeafStyle.NONE:
		_grow_leaves(skeleton, species, rng)
		_measure_crown(skeleton)
	skeleton.compute_frames()
	return skeleton


## Records the box around where the leaf clusters grow.
static func _measure_crown(skeleton: TreeSkeleton) -> void:
	if skeleton.leaf_count() == 0:
		return
	var low := Vector3.INF
	var high := -Vector3.INF
	for i in skeleton.leaf_count():
		var anchor := skeleton.leaf_anchor(i)
		low = low.min(anchor)
		high = high.max(anchor)
	skeleton.crown_middle = (low + high) * 0.5
	skeleton.crown_half_size = (high - low) * 0.5


## Places leaf clusters on every branch whose level asks for them. Along the
## leafy part: one in each equal share of it, at the share's far end, or anywhere
## in it as far as the level's spacing jitter allows. Then any at the very tip,
## spaced evenly around it.
static func _grow_leaves(skeleton: TreeSkeleton, species: TreeSpecies,
		rng: RandomNumberGenerator) -> void:
	for branch in skeleton.branch_count():
		var level := species.level_for_depth(skeleton.branch_depth[branch])
		if level == null:
			continue
		var length := skeleton.branch_length(branch)
		if level.leaves_per_m > 0.0:
			var start := level.leaf_start_fraction * length
			var span := length - start
			var count := maxi(1, roundi(level.leaves_per_m * span))
			for i in count:
				if skeleton.leaf_count() >= species.max_leaves:
					return
				var share_end := float(i + 1)
				if level.leaf_spacing_jitter > 0.0:
					share_end -= rng.randf() * level.leaf_spacing_jitter
				_add_leaf(skeleton, species, rng, branch, start + span * share_end / count,
						rng.randf() * TAU)
		if level.tip_leaves > 0:
			var around := rng.randf() * TAU
			for i in level.tip_leaves:
				if skeleton.leaf_count() >= species.max_leaves:
					return
				_add_leaf(skeleton, species, rng, branch, length, around + TAU * i / level.tip_leaves)


## Adds one leaf cluster at a distance along a branch, leaving it at the leaf
## angle (plus jitter) toward a heading around the branch.
static func _add_leaf(skeleton: TreeSkeleton, species: TreeSpecies, rng: RandomNumberGenerator,
		branch: int, distance: float, heading: float) -> void:
	var along := skeleton.sample_direction(branch, distance)
	var outward := any_perpendicular(along).rotated(along, heading)
	var angle := deg_to_rad(clampf(species.leaf_angle_deg + rng.randf_range(
			-species.leaf_angle_jitter_deg, species.leaf_angle_jitter_deg), 0.0, 180.0))
	var size := species.leaf_size_m * (1.0 + rng.randf_range(
			-species.leaf_size_jitter, species.leaf_size_jitter))
	skeleton.add_leaf(branch, distance, _turn_toward(along, outward, angle),
			rng.randf() * TAU, size, rng.randi())


## Grows the branches off one branch, and theirs in turn, up to the species'
## deepest level or its branch limit. Branches grow from the middles of the
## parent's segments within its span (start to end fraction), evenly spread
## over them, at most one place a segment.
static func _grow_children(skeleton: TreeSkeleton, species: TreeSpecies,
		rng: RandomNumberGenerator, parent: int) -> void:
	var depth := skeleton.branch_depth[parent] + 1
	var level := species.level_for_depth(depth)
	if level == null or level.density_per_m <= 0.0:
		return
	var segment := skeleton.segment_length
	var parent_length := skeleton.branch_length(parent)
	var start := level.start_fraction * parent_length
	var end := level.end_fraction * parent_length
	var segments: Array[int] = []
	for index in roundi(parent_length / segment):
		var middle := (index + 0.5) * segment
		if middle >= start - _EPSILON and middle <= end + _EPSILON:
			segments.append(index)
	var places := mini(roundi(level.density_per_m * maxf(end - start, 0.0)), segments.size())
	var heading := rng.randf() * TAU
	for place in places:
		var index := segments[floori((place + 0.5) * segments.size() / places)]
		var middle := (index + 0.5) * segment
		# Drawn for every place, so the draws that follow don't depend on the curve.
		var picked := level.pick_segments(rng)
		var share := level.length_share_at(middle / parent_length)
		var count := maxi(1, roundi(picked * share)) if share > 0.0 else 0
		for member in (level.branches_per_whorl if count > 0 else 0):
			if skeleton.branch_count() >= species.max_branches:
				return
			_sprout(skeleton, species, rng, level, parent, index,
					heading + TAU * member / level.branches_per_whorl, count)
		heading += deg_to_rad(level.phyllotaxis_deg
				+ rng.randf_range(-level.phyllotaxis_jitter_deg, level.phyllotaxis_jitter_deg))


## Grows one branch, `segments` long, from its parent's centre line in the
## parent's segment `index`, turned away from the parent by the spread angle
## (plus jitter) toward a heading around it, then that branch's own children.
## Its base is moved along the parent so where it joins (from just behind the
## parent's centre line to where its bark clears the parent's,
## TreeSkeleton.junction_span) is centred in the segment, as far as the base
## stays in it.
static func _sprout(skeleton: TreeSkeleton, species: TreeSpecies, rng: RandomNumberGenerator,
		level: TreeBranchLevel, parent: int, index: int, heading: float, segments: int) -> void:
	var spread := deg_to_rad(clampf(level.spread_angle_deg
			+ rng.randf_range(-level.spread_jitter_deg, level.spread_jitter_deg), 0.0, 180.0))
	var segment := skeleton.segment_length
	var middle := (index + 0.5) * segment
	var middle_radius := skeleton.sample_radius(parent, middle)
	var radius := _base_radius(level, middle_radius)
	# A straight branch leaving at the spread angle clears its parent's bark
	# (parent and branch radii) cot(spread) further along: its junction's middle
	# is half that on from its base.
	var lean := (middle_radius + radius) / tan(maxf(spread, 0.05)) * 0.5
	var room := segment * 0.5 - _LINE_CLEARANCE
	var distance := middle - clampf(lean, -room, room)
	var parent_direction := skeleton.sample_direction(parent, distance)
	var outward := any_perpendicular(parent_direction).rotated(parent_direction, heading)
	var child := _grow_branch(skeleton, level, rng, skeleton.branch_depth[parent] + 1, parent,
			distance, skeleton.sample_position(parent, distance),
			_turn_toward(parent_direction, outward, spread), segments,
			_base_radius(level, skeleton.sample_radius(parent, distance)))
	_grow_children(skeleton, species, rng, child)


## A branch's base radius where its parent is this thick: never thicker than it.
static func _base_radius(level: TreeBranchLevel, parent_radius: float) -> float:
	return minf(maxf(parent_radius * level.radius_ratio, level.min_radius_m), parent_radius)


## Walks one branch, `segments` long, from its base, recording a node every
## step (steps_per_segment a segment), and turning by the level's path style
## only at the nodes between segment lines, so each line is a straight joint.
static func _grow_branch(skeleton: TreeSkeleton, level: TreeBranchLevel,
		rng: RandomNumberGenerator, depth: int, parent: int, attach_distance: float,
		origin: Vector3, start_direction: Vector3, segments: int, base_radius: float) -> int:
	var branch := skeleton.add_branch(depth, parent, attach_distance)
	var segment := skeleton.segment_length
	var per_segment := level.steps_per_segment
	var steps := segments * per_segment
	var step := segment / per_segment
	var length := segments * segment
	# A segment's worth of the per-metre turning, shared by the nodes between its lines.
	var turn_length := segment / (per_segment - 1) if per_segment > 1 else 0.0
	var bend := FastNoiseLite.new()
	bend.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	bend.seed = rng.randi()
	bend.frequency = level.bend_frequency
	var bend_rate := deg_to_rad(level.bend_deg_per_m)
	var up_rate := deg_to_rad(level.up_bias_deg_per_m)

	var position := origin
	var direction := start_direction.normalized()
	# A side vector carried along the path without twisting, so the bend's
	# direction drifts only as the noise says, not as the path turns.
	var side := any_perpendicular(direction)
	for i in steps + 1:
		var distance := segment * i / per_segment
		skeleton.add_node(position, level.radius_at(distance / length, base_radius), distance)
		if i == steps:
			break
		var turned := direction
		# Only between segment lines; never at the base, so the branch leaves its
		# parent in the direction it was given.
		if i % per_segment != 0:
			# Smooth bend: a turning rate whose size and direction drift with the noise.
			var across := direction.cross(side)
			var drift := Vector2(bend.get_noise_1d(distance),
					bend.get_noise_1d(distance + _BEND_CHANNEL_OFFSET))
			var toward := side * drift.x + across * drift.y
			turned = _turn_toward(turned, toward, bend_rate * turn_length * minf(drift.length(), 1.0))
			# Kink: a sharp turn in a random direction.
			if rng.randf() < level.kink_chance:
				var heading := side.rotated(direction, rng.randf() * TAU)
				var angle := deg_to_rad(level.kink_angle_deg) * rng.randf_range(0.5, 1.0)
				turned = _turn_toward(turned, heading, angle)
			# Up bias: toward the sky, or the ground when negative, never past it.
			if up_rate > 0.0:
				turned = _turn_toward(turned, Vector3.UP, minf(up_rate * turn_length, turned.angle_to(Vector3.UP)))
			elif up_rate < 0.0:
				turned = _turn_toward(turned, Vector3.DOWN, minf(-up_rate * turn_length, turned.angle_to(Vector3.DOWN)))
		side = carry(side, direction, turned)
		direction = turned
		position += direction * step
	return branch


## Turns a direction by an angle toward another direction.
static func _turn_toward(direction: Vector3, toward: Vector3, angle: float) -> Vector3:
	var axis := direction.cross(toward)
	if angle <= 0.0 or axis.length_squared() < _EPSILON:
		return direction
	return direction.rotated(axis.normalized(), angle).normalized()


## Carries a vector perpendicular to a direction along as that direction turns.
static func carry(vector: Vector3, from: Vector3, to: Vector3) -> Vector3:
	if from.cross(to).length_squared() < _EPSILON:
		return vector
	var carried := Quaternion(from, to) * vector
	# Remove drift so it stays exactly perpendicular.
	return (carried - to * carried.dot(to)).normalized()


static func any_perpendicular(direction: Vector3) -> Vector3:
	var other := Vector3.FORWARD if absf(direction.dot(Vector3.UP)) > 0.9 else Vector3.UP
	return direction.cross(other).normalized()
