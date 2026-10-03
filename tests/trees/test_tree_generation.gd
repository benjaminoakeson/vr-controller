extends SceneTree

## Checks procedural tree generation headlessly: determinism, path styles,
## girth falloff, branching, leaves, texture coordinates, face winding, mesh sizes
## and collision. Timings are
## printed from this machine and say nothing about Quest 3S.
##
##   godot --headless --xr-mode off --path . -s tests/trees/test_tree_generation.gd

const SPECIES := [
	"res://assets/vegetation/trees/straight_pine.tres",
	"res://assets/vegetation/trees/angular_oak.tres",
	"res://assets/vegetation/trees/curvy_birch.tres",
]
const TOLERANCE := 0.0001
## Every check the suite makes. Update it when adding or removing a check.
const EXPECTED_CHECKS := 83

var _failures := 0
var _checks := 0


## Counts errors the engine logs while it is added.
class _ErrorCounter:
	extends Logger

	var count := 0

	func _log_error(_function: String, _file: String, _line: int, _code: String,
			_rationale: String, _editor_notify: bool, _error_type: int,
			_script_backtrace: Array[ScriptBacktrace]) -> void:
		count += 1


## Runs once the scene tree is running, so tests can add nodes to it.
func _initialize() -> void:
	_test_same_seed_same_tree()
	_test_straight_path()
	_test_node_spacing()
	_test_segments()
	_test_frames()
	_test_first_line_radius()
	_test_wood_segments()
	_test_girth_falls_off()
	_test_kinks_turn()
	_test_bend_limit()
	_test_up_bias_droops()
	_test_mesh_size()
	_test_smooth_ring_count()
	_test_bark_uv()
	_test_faces_outward()
	_test_children_attach()
	_test_attach_count()
	_test_branch_limit()
	_test_nodes_stored_together()
	_test_leaf_placement()
	_test_no_leaves()
	_test_trunk_sprouts()
	_test_tip_leaves()
	_test_leaf_anchor()
	_test_leaf_angle()
	_test_leaves_keep_branches()
	_test_style_keeps_placement()
	_test_crown_box()
	_test_leaf_mesh_size()
	_test_crown_normal()
	_test_leaf_normals()
	_test_card_layout()
	_test_clump_layout()
	_test_clump_winding()
	_test_leaf_limit()
	_test_capsules_cover_wood()
	_test_capsule_count()
	_test_twigs_pass_through()
	_test_leaf_volumes()
	# Needs the scene tree running, so a tree added to it becomes ready.
	await process_frame
	_test_tree_collision_objects()
	await _test_collision_streaming()
	await _test_streaming_without_target()
	_test_detail_levels_get_cheaper()
	_test_detail_leaves_out_thin_branches()
	_test_detail_leaf_area()
	_test_tree_detail_levels()
	_test_variants_share()
	_test_variation()
	await _test_scaled_collision()
	_test_scatter()
	_test_impostor_cards()
	_test_impostor_handoff()
	_report_timings()
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


func _species(level: TreeBranchLevel) -> TreeSpecies:
	var species := TreeSpecies.new()
	species.trunk = level
	# One segment length, so a branch's length follows from its segments.
	species.segment_length_min_m = 0.5
	species.segment_length_max_m = 0.5
	return species


func _test_same_seed_same_tree() -> void:
	for path in SPECIES:
		var species: TreeSpecies = load(path)
		var a := TreeSkeletonBuilder.build(species, 7)
		var b := TreeSkeletonBuilder.build(species, 7)
		var mesh_a := TreeMesher.build(a, species)
		var mesh_b := TreeMesher.build(b, species)
		var same := a.positions == b.positions and a.radii == b.radii \
				and a.leaf_forward == b.leaf_forward and a.leaf_size == b.leaf_size \
				and mesh_a.get_surface_count() == mesh_b.get_surface_count()
		for surface in mesh_a.get_surface_count():
			var arrays_a := mesh_a.surface_get_arrays(surface)
			var arrays_b := mesh_b.surface_get_arrays(surface)
			same = same and arrays_a[Mesh.ARRAY_VERTEX] == arrays_b[Mesh.ARRAY_VERTEX] \
					and arrays_a[Mesh.ARRAY_NORMAL] == arrays_b[Mesh.ARRAY_NORMAL] \
					and arrays_a[Mesh.ARRAY_INDEX] == arrays_b[Mesh.ARRAY_INDEX]
		_check(same, "same seed grows the same tree, leaves included: %s" % path.get_file())
	var oak: TreeSpecies = load(SPECIES[1])
	_check(TreeSkeletonBuilder.build(oak, 1).positions != TreeSkeletonBuilder.build(oak, 2).positions,
			"different seeds grow different trees")


func _test_straight_path() -> void:
	var level := TreeBranchLevel.new()
	level.segments_min = 18
	level.segments_max = 18
	var skeleton := TreeSkeletonBuilder.build(_species(level), 3)
	var off_axis := 0.0
	for position in skeleton.positions:
		off_axis = maxf(off_axis, Vector2(position.x, position.z).length())
	var top := skeleton.positions[skeleton.node_count() - 1]
	_check(off_axis < TOLERANCE and absf(top.y - 9.0) < TOLERANCE,
			"zero path style grows straight up to its length (off axis %.6f m)" % off_axis)


func _test_node_spacing() -> void:
	var level := TreeBranchLevel.new()
	level.segments_min = 7
	level.segments_max = 7
	level.steps_per_segment = 3
	level.bend_deg_per_m = 30.0
	level.kink_chance = 0.5
	var skeleton := TreeSkeletonBuilder.build(_species(level), 5)
	var step := 0.5 / 3
	var even := skeleton.node_count() == 7 * 3 + 1
	for i in range(1, skeleton.node_count()):
		var gap := skeleton.positions[i].distance_to(skeleton.positions[i - 1])
		var travelled := skeleton.distances[i] - skeleton.distances[i - 1]
		even = even and absf(gap - step) < TOLERANCE and absf(travelled - step) < TOLERANCE
	var last := skeleton.distances[skeleton.node_count() - 1]
	_check(even and absf(last - 3.5) < TOLERANCE,
			"nodes are evenly spaced, three a segment, and the last lands at seven segments' length")


## Every tree of the three species: its segment length within the species'
## range, every branch a whole number of it, the trunk's count within its range.
func _test_segments() -> void:
	var whole := true
	var lengths := PackedFloat32Array()
	for path in SPECIES:
		var species: TreeSpecies = load(path)
		for tree_seed in 8:
			var skeleton := TreeSkeletonBuilder.build(species, tree_seed)
			var segment := skeleton.segment_length
			lengths.append(segment)
			whole = whole and segment >= species.segment_length_min_m - TOLERANCE \
					and segment <= species.segment_length_max_m + TOLERANCE
			var trunk := skeleton.branch_length(0) / segment
			whole = whole and absf(trunk - roundf(trunk)) < 0.001 \
					and roundi(trunk) >= species.trunk.segments_min and roundi(trunk) <= species.trunk.segments_max
			for branch in skeleton.branch_count():
				var count := skeleton.branch_length(branch) / segment
				var steps := species.level_for_depth(skeleton.branch_depth[branch]).steps_per_segment
				whole = whole and count >= 1.0 - 0.001 and absf(count - roundf(count)) < 0.001 \
						and skeleton.branch_node_count[branch] == roundi(count) * steps + 1
	_check(whole and lengths.size() == 24 and lengths[0] != lengths[1],
			"each tree picks its segment length in the species' range; every branch is a whole number of segments, the trunk as many as its range allows")


## What a chop line takes scales from the trunk's radius at its first segment
## line (TreeChop): the builder records it, and every piece of the tree keeps it.
func _test_first_line_radius() -> void:
	var kept := true
	for path in SPECIES:
		var species: TreeSpecies = load(path)
		var skeleton := TreeSkeletonBuilder.build(species, 2)
		var expected := skeleton.sample_radius(0, skeleton.segment_length)
		kept = kept and expected > 0.0 and absf(skeleton.first_line_radius - expected) < TOLERANCE
		var pieces := skeleton.split(0, skeleton.segment_length * 3)
		var gone := PackedByteArray()
		gone.resize(skeleton.branch_count())
		var pruned := skeleton.pruned(gone, PackedByteArray())
		for piece in [pieces[0], pieces[1], pruned]:
			kept = kept and absf((piece as TreeSkeleton).first_line_radius - expected) < TOLERANCE
	_check(kept, "each tree records its trunk's radius at its first segment line, and every piece of it keeps it")


## A branch's segments of wood (TreeSkeleton.wood_segments, 2026-10-02: what a
## felled piece weighs is counted in them): those at least the species' wood
## radius thick where they start, counted here at the nodes on the segment
## lines, which every grown branch has. A twig, with no line to chop, may hold
## some; a skeleton not grown in segments holds none.
func _test_wood_segments() -> void:
	var oak: TreeSpecies = load(SPECIES[1])
	var min_radius := oak.collision_min_radius_m
	var skeleton := TreeSkeletonBuilder.build(oak, oak.variant_for(0))
	var limb := 1
	var wood := -1
	var twig := -1
	for branch in skeleton.branch_count():
		if skeleton.branch_depth[branch] == 2 and not skeleton.is_twig(branch, min_radius) and wood < 0:
			wood = branch
		if skeleton.branch_depth[branch] == 2 and skeleton.is_twig(branch, min_radius) and twig < 0:
			twig = branch
	var counted := true
	var parts := []
	for branch in [0, limb, wood, twig]:
		var counts := _wood_at_lines(skeleton, branch, min_radius) if branch >= 0 else Vector2i(-1, -1)
		var found := skeleton.wood_segments(branch, min_radius) if branch >= 0 else -2
		counted = counted and found == counts.x
		parts.append("%d of its %d" % [found, counts.y])
	_check(counted and skeleton.branch_depth[limb] == 1 and wood >= 0 and twig >= 0,
			"the oak of seed 0's segments of wood, at least %.3f m thick where they start (TreeSkeleton.wood_segments), as counted at the nodes on its segment lines: the trunk %s, limb %d %s, branch %d (depth 2, with a line to chop) %s, twig %d (depth 2) %s"
			% [min_radius, parts[0], limb, parts[1], wood, parts[2], twig, parts[3]])
	# A branch 1 m long and 0.1 m thick, built by hand.
	var bare := TreeSkeleton.new()
	bare.add_branch(0, -1, 0.0)
	bare.add_node(Vector3.ZERO, 0.1, 0.0)
	bare.add_node(Vector3.UP, 0.1, 1.0)
	var unsegmented := bare.wood_segments(0, min_radius)
	bare.segment_length = 0.5
	var segmented := bare.wood_segments(0, min_radius)
	_check(unsegmented == 0 and segmented == 2,
			"a skeleton not grown in segments (segment length 0) holds no segments of wood: %d for a branch 1 m long and 0.1 m thick, which holds %d given 0.5 m segments"
			% [unsegmented, segmented])


## A branch's segments as counted at the nodes on its segment lines, from its
## base to the last line short of its tip: (those at least `min_radius` thick,
## all of them).
static func _wood_at_lines(skeleton: TreeSkeleton, branch: int, min_radius: float) -> Vector2i:
	var segment := skeleton.segment_length
	var first := skeleton.branch_first_node[branch]
	var end := skeleton.branch_length(branch)
	var counts := Vector2i.ZERO
	for node in range(first, first + skeleton.branch_node_count[branch]):
		var at := skeleton.distances[node]
		if absf(at / segment - roundf(at / segment)) < 0.001 and at < end - 0.001 * segment:
			counts.y += 1
			if skeleton.radii[node] >= min_radius:
				counts.x += 1
	return counts


## The frame each node keeps: unit axis and normal, square to each other; at a
## segment line inside a branch, the path goes straight on.
func _test_frames() -> void:
	var square := true
	var straight := true
	for path in SPECIES:
		var species: TreeSpecies = load(path)
		var skeleton := TreeSkeletonBuilder.build(species, 3)
		square = square and skeleton.axes.size() == skeleton.node_count() \
				and skeleton.normals.size() == skeleton.node_count()
		for node in skeleton.node_count():
			square = square and absf(skeleton.axes[node].length() - 1.0) < 0.001 \
					and absf(skeleton.normals[node].length() - 1.0) < 0.001 \
					and absf(skeleton.axes[node].dot(skeleton.normals[node])) < 0.001
		for branch in skeleton.branch_count():
			var first := skeleton.branch_first_node[branch]
			var steps := species.level_for_depth(skeleton.branch_depth[branch]).steps_per_segment
			for node in range(first + steps, first + skeleton.branch_node_count[branch] - 1, steps):
				var before := skeleton.positions[node] - skeleton.positions[node - 1]
				var after := skeleton.positions[node + 1] - skeleton.positions[node]
				straight = straight and before.angle_to(after) < 0.0001
	_check(square, "every node keeps a frame: unit axis and normal, square to each other")
	_check(straight, "the three species never turn at a segment line: every line is a straight joint")


func _test_girth_falls_off() -> void:
	var levels: Array[TreeBranchLevel] = [TreeBranchLevel.new()]
	for path in SPECIES:
		levels.append((load(path) as TreeSpecies).trunk)
	for level in levels:
		var skeleton := TreeSkeletonBuilder.build(_species(level), 1)
		var shrinking := true
		for i in range(1, skeleton.node_count()):
			shrinking = shrinking and skeleton.radii[i] <= skeleton.radii[i - 1] + TOLERANCE
		var tip := skeleton.radii[skeleton.node_count() - 1]
		_check(shrinking and absf(skeleton.radii[0] - level.base_radius_m) < TOLERANCE
				and tip >= level.min_radius_m - TOLERANCE,
				"radius starts at the base radius and only shrinks (tip %.3f m)" % tip)


func _test_kinks_turn() -> void:
	var level := TreeBranchLevel.new()
	level.kink_chance = 1.0
	level.kink_angle_deg = 20.0
	var skeleton := TreeSkeletonBuilder.build(_species(level), 11)
	var smallest := INF
	var largest := 0.0
	var at_lines := 0.0
	for i in range(2, skeleton.node_count()):
		var before := skeleton.positions[i - 1] - skeleton.positions[i - 2]
		var after := skeleton.positions[i] - skeleton.positions[i - 1]
		var turn := rad_to_deg(before.angle_to(after))
		if (i - 1) % level.steps_per_segment == 0:
			at_lines = maxf(at_lines, turn)
		else:
			smallest = minf(smallest, turn)
			largest = maxf(largest, turn)
	_check(smallest >= 10.0 - 0.01 and largest <= 20.0 + 0.01,
			"every kink turns between half and all of the kink angle (%.1f° to %.1f°)" % [smallest, largest])
	_check(at_lines < 0.01, "kinks happen only between segment lines (%.3f° at the lines)" % at_lines)


func _test_bend_limit() -> void:
	var level := TreeBranchLevel.new()
	level.bend_deg_per_m = 30.0
	level.bend_frequency = 0.5
	level.steps_per_segment = 3
	var skeleton := TreeSkeletonBuilder.build(_species(level), 4)
	var largest := 0.0
	var total := 0.0
	# A segment's turning is shared by the two nodes between its lines.
	var turn_length := 0.5 / 2
	for i in range(2, skeleton.node_count()):
		var before := skeleton.positions[i - 1] - skeleton.positions[i - 2]
		var after := skeleton.positions[i] - skeleton.positions[i - 1]
		var rate := rad_to_deg(before.angle_to(after)) / turn_length
		largest = maxf(largest, rate)
		total += rate
	_check(largest <= 30.0 + 0.01 and total > 0.0,
			"bend curves the path but never faster than its rate (max %.1f°/m)" % largest)


func _test_up_bias_droops() -> void:
	var level := TreeBranchLevel.new()
	level.segments_min = 12
	level.segments_max = 12
	level.kink_chance = 1.0
	level.kink_angle_deg = 5.0
	level.up_bias_deg_per_m = -40.0
	var skeleton := TreeSkeletonBuilder.build(_species(level), 2)
	var count := skeleton.node_count()
	var tip_direction := (skeleton.positions[count - 1] - skeleton.positions[count - 2]).normalized()
	_check(tip_direction.y < 0.0, "negative up bias droops the path (tip heading y %.2f)" % tip_direction.y)


func _test_mesh_size() -> void:
	var level := TreeBranchLevel.new()
	var species := _species(level)
	var skeleton := TreeSkeletonBuilder.build(species, 1)
	var arrays := TreeMesher.build(skeleton, species).surface_get_arrays(0)
	var rings := skeleton.node_count()
	var sides := TreeMesher.sides_for(species, level.base_radius_m)
	var vertices: int = rings * (sides + 1) + sides + (sides + 1)
	var triangles: int = (rings - 1) * sides * 2 + sides + sides
	var got_vertices: int = arrays[Mesh.ARRAY_VERTEX].size()
	var got_triangles: int = arrays[Mesh.ARRAY_INDEX].size() / 3
	_check(got_vertices == vertices and got_triangles == triangles,
			"mesh size matches rings × sides plus tip and cap (%d vertices, %d triangles)" % [got_vertices, got_triangles])


func _test_smooth_ring_count() -> void:
	var level := TreeBranchLevel.new()
	level.bend_deg_per_m = 20.0
	var species := _species(level)
	var skeleton := TreeSkeletonBuilder.build(species, 1)
	var hard: int = TreeMesher.build(skeleton, species).surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
	level.smooth_mesh = true
	level.smooth_subdivisions = 3
	var smooth: int = TreeMesher.build(skeleton, species).surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
	var sides := TreeMesher.sides_for(species, level.base_radius_m)
	var extra_rings := (skeleton.node_count() - 1) * 3
	_check(smooth - hard == extra_rings * (sides + 1),
			"a smooth mesh adds its subdivisions between every pair of nodes")


func _test_bark_uv() -> void:
	var species: TreeSpecies = load(SPECIES[2])
	var skeleton := TreeSkeletonBuilder.build(species, 1)
	var arrays := TreeMesher.build(skeleton, species).surface_get_arrays(0)
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var uv2s: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	var sides := TreeMesher.sides_for(species, species.trunk.base_radius_m)
	var repeats := uvs[sides].x
	var ring := 0
	var steady := true
	var seamless := true
	var previous_v := INF
	while (ring + 1) * (sides + 1) <= uvs.size() and uv2s[ring * (sides + 1)].x == 0.0:
		var first := ring * (sides + 1)
		# The apex vertices follow the last ring; stop where rings end.
		if uvs[first].x != 0.0:
			break
		var v := uvs[first].y
		for k in sides + 1:
			steady = steady and absf(uvs[first + k].y - v) < TOLERANCE
		seamless = seamless and absf(uvs[first + sides].x - repeats) < TOLERANCE
		steady = steady and v < previous_v
		previous_v = v
		ring += 1
	_check(ring > 2 and steady, "bark V is level around each ring and climbs steadily up the branch")
	_check(seamless and repeats >= 1.0 and absf(repeats - roundf(repeats)) < TOLERANCE,
			"bark U wraps a whole number of repeats (%d)" % int(repeats))
	var caps := 0
	for uv2 in uv2s:
		if uv2.x == 1.0:
			caps += 1
	_check(caps == sides + 1, "the trunk base cap is marked as inner wood")


func _test_faces_outward() -> void:
	for path in SPECIES:
		var species: TreeSpecies = load(path)
		var arrays := TreeMesher.build(TreeSkeletonBuilder.build(species, 1), species).surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var inward := 0
		for t in range(0, indices.size(), 3):
			var a := vertices[indices[t]]
			var winding := (vertices[indices[t + 1]] - a).cross(vertices[indices[t + 2]] - a)
			var facing := normals[indices[t]] + normals[indices[t + 1]] + normals[indices[t + 2]]
			# Godot's front faces are clockwise, so their cross product points inward.
			if winding.dot(facing) > 0.0:
				inward += 1
		_check(inward == 0, "every triangle faces outward: %s" % path.get_file())


## A trunk with one straight level of branches, for checking where they grow.
func _branching_species() -> TreeSpecies:
	var trunk := TreeBranchLevel.new()
	trunk.segments_min = 20
	trunk.segments_max = 20
	trunk.base_radius_m = 0.3
	trunk.kink_chance = 0.3
	trunk.kink_angle_deg = 15.0
	var branches := TreeBranchLevel.new()
	branches.segments_min = 8
	branches.segments_max = 8
	branches.radius_ratio = 0.5
	branches.start_fraction = 0.3
	branches.end_fraction = 0.9
	branches.density_per_m = 0.8
	branches.branches_per_whorl = 3
	branches.spread_angle_deg = 40.0
	branches.spread_jitter_deg = 10.0
	branches.min_radius_m = 0.01
	var species := _species(trunk)
	species.branch_levels = [branches]
	return species


func _test_children_attach() -> void:
	var species := _branching_species()
	var skeleton := TreeSkeletonBuilder.build(species, 9)
	var level := species.branch_levels[0]
	var on_axis := true
	var in_span := true
	var centred := true
	var thinner := true
	var smallest := INF
	var largest := 0.0
	var segment := skeleton.segment_length
	for branch in range(1, skeleton.branch_count()):
		var parent := skeleton.branch_parent[branch]
		var attach := skeleton.branch_attach_distance[branch]
		var parent_length := skeleton.branch_length(parent)
		var first := skeleton.branch_first_node[branch]
		on_axis = on_axis and skeleton.positions[first].distance_to(
				skeleton.sample_position(parent, attach)) < TOLERANCE
		# It grows in a segment whose middle is in the span, its junction centred in
		# that segment, unless its base had to stop short of the segment's line.
		var index := floori(attach / segment)
		var middle := (index + 0.5) * segment
		in_span = in_span and middle >= level.start_fraction * parent_length - TOLERANCE \
				and middle <= level.end_fraction * parent_length + TOLERANCE
		var span := skeleton.junction_span(branch)
		var at_limit := absf(attach - index * segment - 0.02) < TOLERANCE \
				or absf((index + 1) * segment - 0.02 - attach) < TOLERANCE
		centred = centred and (absf((span.x + span.y) * 0.5 - middle) < 0.03 or at_limit)
		thinner = thinner and skeleton.radii[first] <= skeleton.sample_radius(parent, attach) + TOLERANCE
		# Straight branches, so the first stretch keeps the starting direction.
		var start := (skeleton.positions[first + 1] - skeleton.positions[first]).normalized()
		var angle := rad_to_deg(start.angle_to(skeleton.sample_direction(parent, attach)))
		smallest = minf(smallest, angle)
		largest = maxf(largest, angle)
	_check(skeleton.branch_count() > 1 and on_axis and in_span and centred,
			"branches start on the parent's centre line, in a segment within its span, where they join centred in it")
	_check(thinner, "no branch starts thicker than its parent where it grows")
	_check(smallest >= 30.0 - 0.01 and largest <= 50.0 + 0.01,
			"branches leave at the spread angle ± jitter (%.1f° to %.1f°)" % [smallest, largest])


func _test_attach_count() -> void:
	var species := _branching_species()
	var skeleton := TreeSkeletonBuilder.build(species, 9)
	var level := species.branch_levels[0]
	var length := skeleton.branch_length(0)
	var span := (level.end_fraction - level.start_fraction) * length
	var segments := 0
	for index in roundi(length / skeleton.segment_length):
		var middle := (index + 0.5) * skeleton.segment_length
		if middle >= level.start_fraction * length - TOLERANCE and middle <= level.end_fraction * length + TOLERANCE:
			segments += 1
	var expected := mini(roundi(level.density_per_m * span), segments) * level.branches_per_whorl
	_check(skeleton.branch_count() - 1 == expected,
			"branch count is density × span, at most one place a segment, × whorl size (%d)" % expected)


func _test_branch_limit() -> void:
	var species := _branching_species()
	species.branch_levels[0].density_per_m = 10.0
	species.branch_levels.append(species.branch_levels[0].duplicate())
	species.max_branches = 50
	var count := TreeSkeletonBuilder.build(species, 1).branch_count()
	_check(count == 50, "growth stops at the branch limit (%d branches)" % count)


func _test_nodes_stored_together() -> void:
	var together := true
	for path in SPECIES:
		var skeleton := TreeSkeletonBuilder.build(load(path), 3)
		var next := 0
		for branch in skeleton.branch_count():
			together = together and skeleton.branch_first_node[branch] == next \
					and skeleton.branch_node_count[branch] >= 2
			for node in skeleton.branch_node_count[branch]:
				together = together and skeleton.node_branch[next + node] == branch
			next += skeleton.branch_node_count[branch]
		together = together and next == skeleton.node_count()
	_check(together, "each branch's nodes are stored together, covering every node once")


## The branching species, with a second level of branches and leaves on both.
func _leafy_species(style: TreeSpecies.LeafStyle) -> TreeSpecies:
	var species := _branching_species()
	var branches: TreeBranchLevel = species.branch_levels[0]
	branches.leaves_per_m = 2.0
	branches.leaf_start_fraction = 0.5
	var twigs: TreeBranchLevel = branches.duplicate()
	twigs.density_per_m = 1.5
	twigs.branches_per_whorl = 1
	species.branch_levels.append(twigs)
	species.leaf_style = style
	species.leaf_angle_deg = 40.0
	species.leaf_angle_jitter_deg = 15.0
	return species


## Where a leaf cluster starts, on its branch's bark.
func _anchor(skeleton: TreeSkeleton, leaf: int) -> Vector3:
	return skeleton.leaf_anchor(leaf)


func _test_leaf_placement() -> void:
	for case in ["branches and twigs", "only twigs"]:
		var species := _leafy_species(TreeSpecies.LeafStyle.CARDS)
		if case == "only twigs":
			species.branch_levels[0].leaves_per_m = 0.0
		var skeleton := TreeSkeletonBuilder.build(species, 5)
		var per_branch := {}
		var placed := true
		for i in skeleton.leaf_count():
			var branch := skeleton.leaf_branch[i]
			var level := species.level_for_depth(skeleton.branch_depth[branch])
			var length := skeleton.branch_length(branch)
			placed = placed and skeleton.leaf_distance[i] >= level.leaf_start_fraction * length - TOLERANCE \
					and skeleton.leaf_distance[i] <= length + TOLERANCE
			var found: Array = per_branch.get(branch, [])
			found.append(skeleton.leaf_distance[i])
			per_branch[branch] = found
		var counted := true
		var deepest_leafy := 0
		for branch in skeleton.branch_count():
			var level := species.level_for_depth(skeleton.branch_depth[branch])
			if level.leaves_per_m <= 0.0:
				counted = counted and not per_branch.has(branch)
				continue
			var length := skeleton.branch_length(branch)
			var expected := maxi(1, roundi(level.leaves_per_m * length * (1.0 - level.leaf_start_fraction)))
			var found: Array = per_branch.get(branch, [])
			counted = counted and found.size() == expected and absf(found.max() - length) < TOLERANCE
			deepest_leafy = maxi(deepest_leafy, skeleton.branch_depth[branch])
		_check(skeleton.leaf_count() > 0 and placed and counted and deepest_leafy == 2,
				"%s: each leafy level's branches have density × span clusters, the last at the tip; other levels have none" % case)


func _test_trunk_sprouts() -> void:
	var species := _leafy_species(TreeSpecies.LeafStyle.CARDS)
	species.trunk.leaves_per_m = 0.5
	species.trunk.leaf_start_fraction = 0.2
	species.trunk.leaf_spacing_jitter = 1.0
	var skeleton := TreeSkeletonBuilder.build(species, 5)
	var length := skeleton.branch_length(0)
	var start := 0.2 * length
	var count := roundi(0.5 * (length - start))
	var on_trunk := []
	for i in skeleton.leaf_count():
		if skeleton.leaf_branch[i] == 0:
			on_trunk.append(skeleton.leaf_distance[i])
	# Each is somewhere in its own share of the leafy part, not all at its end.
	var in_shares := on_trunk.size() == count and count > 1
	var irregular := false
	for i in (on_trunk.size() if in_shares else 0):
		var share_start := start + (length - start) * i / count
		var share_end := start + (length - start) * (i + 1) / count
		in_shares = in_shares and on_trunk[i] >= share_start - TOLERANCE and on_trunk[i] <= share_end + TOLERANCE
		irregular = irregular or absf(on_trunk[i] - share_end) > 0.01
	_check(in_shares and irregular,
			"sparse, jittered trunk sprouts: %d clusters, each somewhere in its share of the trunk" % count)


func _test_leaf_anchor() -> void:
	var species := _leafy_species(TreeSpecies.LeafStyle.CARDS)
	species.trunk.leaves_per_m = 0.5
	var skeleton := TreeSkeletonBuilder.build(species, 5)
	var on_bark := skeleton.leaf_count() > 0
	for i in skeleton.leaf_count():
		var branch := skeleton.leaf_branch[i]
		var distance := skeleton.leaf_distance[i]
		var offset := skeleton.leaf_anchor(i) - skeleton.sample_position(branch, distance)
		# Out from the centre line by the branch's radius, square to the branch,
		# on the side the cluster grows toward.
		on_bark = on_bark and absf(offset.length() - skeleton.sample_radius(branch, distance)) < TOLERANCE \
				and absf(offset.dot(skeleton.sample_direction(branch, distance))) < TOLERANCE \
				and offset.dot(skeleton.leaf_forward[i]) > 0.0
	_check(on_bark, "leaf clusters start on the bark, on the side they grow toward")


func _test_tip_leaves() -> void:
	var species := _leafy_species(TreeSpecies.LeafStyle.CARDS)
	species.trunk.tip_leaves = 4
	var skeleton := TreeSkeletonBuilder.build(species, 5)
	var length := skeleton.branch_length(0)
	var along := skeleton.sample_direction(0, length)
	var headings := []
	var angled := true
	for i in skeleton.leaf_count():
		if skeleton.leaf_branch[i] != 0:
			continue
		var forward := skeleton.leaf_forward[i]
		var angle := rad_to_deg(forward.angle_to(along))
		angled = angled and absf(skeleton.leaf_distance[i] - length) < TOLERANCE \
				and angle >= species.leaf_angle_deg - species.leaf_angle_jitter_deg - 0.01 \
				and angle <= species.leaf_angle_deg + species.leaf_angle_jitter_deg + 0.01
		headings.append(forward - along * forward.dot(along))
	# Evenly spaced around the tip: a quarter turn between neighbours.
	var even := headings.size() == 4
	for i in (headings.size() if even else 0):
		var turn := rad_to_deg(headings[i].signed_angle_to(headings[(i + 1) % 4], along))
		even = even and absf(fposmod(turn, 360.0) - 90.0) < 0.01
	_check(angled, "tip leaves sit at the trunk's tip, at the leaf angle ± jitter")
	_check(even, "tip leaves are spaced evenly around the tip")


func _test_no_leaves() -> void:
	for case in ["no level has leaves", "leaf limit of 0"]:
		var species := _leafy_species(TreeSpecies.LeafStyle.CLUMPS)
		if case == "leaf limit of 0":
			species.max_leaves = 0
		else:
			for level in species.branch_levels:
				level.leaves_per_m = 0.0
		var skeleton := TreeSkeletonBuilder.build(species, 5)
		# Godot refuses an empty surface with errors but no failure, so count them.
		var errors := _ErrorCounter.new()
		OS.add_logger(errors)
		var mesh := TreeMesher.build(skeleton, species)
		OS.remove_logger(errors)
		_check(skeleton.leaf_count() == 0 and mesh.get_surface_count() == 1 and errors.count == 0,
				"%s: no clusters, only the wood surface, no engine errors" % case)


func _test_leaf_angle() -> void:
	var species := _leafy_species(TreeSpecies.LeafStyle.CARDS)
	var skeleton := TreeSkeletonBuilder.build(species, 5)
	var smallest := INF
	var largest := 0.0
	for i in skeleton.leaf_count():
		var along := skeleton.sample_direction(skeleton.leaf_branch[i], skeleton.leaf_distance[i])
		var angle := rad_to_deg(skeleton.leaf_forward[i].angle_to(along))
		smallest = minf(smallest, angle)
		largest = maxf(largest, angle)
	_check(skeleton.leaf_count() > 0 and smallest >= 25.0 - 0.01 and largest <= 55.0 + 0.01,
			"clusters leave their branch at the leaf angle ± jitter (%.1f° to %.1f°)" % [smallest, largest])


func _test_leaves_keep_branches() -> void:
	var bare := TreeSkeletonBuilder.build(_leafy_species(TreeSpecies.LeafStyle.NONE), 5)
	var leafy := TreeSkeletonBuilder.build(_leafy_species(TreeSpecies.LeafStyle.CARDS), 5)
	_check(bare.leaf_count() == 0 and leafy.leaf_count() > 0
			and bare.positions == leafy.positions and bare.radii == leafy.radii,
			"adding leaves leaves the branches exactly as they were")


func _test_style_keeps_placement() -> void:
	var cards := TreeSkeletonBuilder.build(_leafy_species(TreeSpecies.LeafStyle.CARDS), 5)
	var clumps := TreeSkeletonBuilder.build(_leafy_species(TreeSpecies.LeafStyle.CLUMPS), 5)
	_check(cards.leaf_count() > 0 and cards.leaf_branch == clumps.leaf_branch
			and cards.leaf_distance == clumps.leaf_distance and cards.leaf_forward == clumps.leaf_forward
			and cards.leaf_size == clumps.leaf_size and cards.crown_middle == clumps.crown_middle,
			"switching between cards and clumps keeps where the leaves grow")


func _test_crown_box() -> void:
	var skeleton := TreeSkeletonBuilder.build(_leafy_species(TreeSpecies.LeafStyle.CARDS), 5)
	var low := Vector3.INF
	var high := -Vector3.INF
	for i in skeleton.leaf_count():
		low = low.min(_anchor(skeleton, i))
		high = high.max(_anchor(skeleton, i))
	_check(skeleton.leaf_count() > 0
			and skeleton.crown_middle.distance_to((low + high) * 0.5) < TOLERANCE
			and skeleton.crown_half_size.distance_to((high - low) * 0.5) < TOLERANCE,
			"the skeleton records the box around its clusters as the crown")


func _test_leaf_mesh_size() -> void:
	var bare := _leafy_species(TreeSpecies.LeafStyle.NONE)
	_check(TreeMesher.build(TreeSkeletonBuilder.build(bare, 5), bare).get_surface_count() == 1,
			"a species without leaves has only its wood surface")
	for style in [TreeSpecies.LeafStyle.CARDS, TreeSpecies.LeafStyle.CLUMPS]:
		var species := _leafy_species(style)
		var skeleton := TreeSkeletonBuilder.build(species, 5)
		var mesh := TreeMesher.build(skeleton, species)
		var per_vertices := 8 if style == TreeSpecies.LeafStyle.CARDS else 12
		var per_triangles := 4 if style == TreeSpecies.LeafStyle.CARDS else 20
		var sized := mesh.get_surface_count() == 2 and skeleton.leaf_count() > 0
		if sized:
			var arrays := mesh.surface_get_arrays(1)
			sized = arrays[Mesh.ARRAY_VERTEX].size() == skeleton.leaf_count() * per_vertices \
					and arrays[Mesh.ARRAY_INDEX].size() == skeleton.leaf_count() * per_triangles * 3 \
					and arrays[Mesh.ARRAY_TEX_UV2] == null \
					and mesh.surface_get_material(1) == species.leaf_material
		_check(sized, "%s: %d vertices and %d triangles per cluster, no UV2, the leaf material" % [
				TreeSpecies.LeafStyle.keys()[style].to_lower(), per_vertices, per_triangles])


## A tree's leaf arrays, or an empty array if it has no leaf surface.
func _leaf_arrays(species: TreeSpecies, skeleton: TreeSkeleton) -> Array:
	var mesh := TreeMesher.build(skeleton, species)
	return mesh.surface_get_arrays(1) if mesh.get_surface_count() == 2 else []


func _test_crown_normal() -> void:
	var skeleton := TreeSkeleton.new()
	skeleton.crown_half_size = Vector3(1.5, 3.0, 1.5)
	# On a tall ellipsoid, a point out to the side and up leans far less up than
	# its offset: (1 / 2.25, 1 / 9, 0), not (1, 1, 0) as a sphere would give.
	var tall := TreeMesher.crown_normal(skeleton, Vector3(1.0, 1.0, 0.0))
	skeleton.crown_half_size = Vector3(1.0, 1.0, 0.02)
	# A nearly flat crown is thickened to 0.4 of its longest half size, so the
	# thin axis can't take over: (0.9, 0.3, 0.02 / 0.16).
	var flat := TreeMesher.crown_normal(skeleton, Vector3(0.9, 0.3, 0.02))
	_check(tall.distance_to(Vector3(1.0 / 2.25, 1.0 / 9.0, 0.0).normalized()) < TOLERANCE
			and flat.distance_to(Vector3(0.9, 0.3, 0.125).normalized()) < TOLERANCE
			and TreeMesher.crown_normal(skeleton, Vector3.ZERO) == Vector3.UP,
			"crown normals follow the crown's ellipsoid, thickened where it is nearly flat")


func _test_leaf_normals() -> void:
	# Rounding leans a normal off the crown's by at most this much (a cosine).
	var bound := sqrt(1.0 - TreeMesher.LEAF_NORMAL_ROUNDNESS ** 2) - 0.001
	var cases := [
		[_leafy_species(TreeSpecies.LeafStyle.CARDS), "cards"],
		[_leafy_species(TreeSpecies.LeafStyle.CLUMPS), "clumps"],
		# A crown about twice as tall as it is wide, so a sphere wouldn't pass.
		[load(SPECIES[0]), "the tall pine crown"],
	]
	for case in cases:
		var species: TreeSpecies = case[0]
		var skeleton := TreeSkeletonBuilder.build(species, 5)
		var arrays := _leaf_arrays(species, skeleton)
		var per := 8 if species.leaf_style == TreeSpecies.LeafStyle.CARDS else 12
		var outward := not arrays.is_empty()
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if outward else PackedVector3Array()
		for i in (skeleton.leaf_count() if outward else 0):
			var crown := TreeMesher.crown_normal(skeleton, _anchor(skeleton, i))
			for k in per:
				var normal := normals[i * per + k]
				outward = outward and absf(normal.length() - 1.0) < 0.001 and normal.dot(crown) > bound
		_check(outward, "%s: unit normals within the rounding of the crown's normal" % case[1])


func _test_card_layout() -> void:
	for stem: Vector2 in [Vector2(0.0, 0.5), Vector2(0.03, 0.66)]:
		var species := _leafy_species(TreeSpecies.LeafStyle.CARDS)
		species.leaf_card_stem = stem
		var skeleton := TreeSkeletonBuilder.build(species, 5)
		var arrays := _leaf_arrays(species, skeleton)
		var laid_out := not arrays.is_empty()
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX] if laid_out else PackedVector3Array()
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if laid_out else PackedVector2Array()
		var expected_uvs := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
		for i in (skeleton.leaf_count() if laid_out else 0):
			var size := skeleton.leaf_size[i]
			for quad in 2:
				var first := i * 8 + quad * 4
				for k in 4:
					laid_out = laid_out and uvs[first + k] == expected_uvs[k]
				# The card spans corner 0 (UV 0, 0) along U to corner 1 and along V
				# to corner 3; the stem's point on it must be on the branch.
				var across := vertices[first + 1] - vertices[first]
				var down := vertices[first + 3] - vertices[first]
				var stem_point := vertices[first] + across * stem.x + down * stem.y
				laid_out = laid_out and stem_point.distance_to(_anchor(skeleton, i)) < TOLERANCE \
						and across.distance_to(skeleton.leaf_forward[i] * size) < TOLERANCE \
						and absf(down.length() - size * species.leaf_card_aspect) < TOLERANCE
		_check(laid_out, "cards with the stem at %s: stem on the branch, texture the right way round, height from the aspect" % stem)


func _test_clump_layout() -> void:
	var species := _leafy_species(TreeSpecies.LeafStyle.CLUMPS)
	species.leaf_clump_jitter = 0.0
	var skeleton := TreeSkeletonBuilder.build(species, 5)
	var arrays := _leaf_arrays(species, skeleton)
	var centred := not arrays.is_empty()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX] if centred else PackedVector3Array()
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if centred else PackedVector2Array()
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if centred else PackedInt32Array()
	var textured := centred
	for i in (skeleton.leaf_count() if centred else 0):
		var anchor := _anchor(skeleton, i)
		var expected := anchor + skeleton.leaf_forward[i] * skeleton.leaf_size[i] * 0.5 * TreeMesher.CLUMP_OFFSET
		var centre := Vector3.ZERO
		for k in 12:
			centre += vertices[i * 12 + k]
		centre /= 12.0
		# Out from the branch, not back into it, whatever the constant says.
		centred = centred and centre.distance_to(expected) < TOLERANCE \
				and (centre - anchor).dot(skeleton.leaf_forward[i]) > 0.0
	for t in range(0, indices.size(), 3):
		var a := uvs[indices[t]]
		textured = textured and absf((uvs[indices[t + 1]] - a).cross(uvs[indices[t + 2]] - a)) > 0.0001
	_check(centred, "clumps are centred out from the branch along their direction")
	_check(textured, "no clump face has a collapsed texture area")


func _test_clump_winding() -> void:
	var species := _leafy_species(TreeSpecies.LeafStyle.CLUMPS)
	var arrays := _leaf_arrays(species, TreeSkeletonBuilder.build(species, 5))
	var outward := not arrays.is_empty()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX] if outward else PackedVector3Array()
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if outward else PackedInt32Array()
	for t in range(0, indices.size(), 3):
		# Each clump's 12 corners are stored together; its centre is their average.
		var first := indices[t] - indices[t] % 12
		var centre := Vector3.ZERO
		for k in 12:
			centre += vertices[first + k]
		centre /= 12.0
		var a := vertices[indices[t]]
		var b := vertices[indices[t + 1]]
		var c := vertices[indices[t + 2]]
		# Godot's front faces are clockwise, so their cross product points inward.
		outward = outward and (b - a).cross(c - a).dot((a + b + c) / 3.0 - centre) < 0.0
	_check(outward, "every clump triangle faces out of its clump")


func _test_leaf_limit() -> void:
	var species := _leafy_species(TreeSpecies.LeafStyle.CARDS)
	for level in species.branch_levels:
		level.leaves_per_m = 20.0
	species.max_leaves = 40
	var count := TreeSkeletonBuilder.build(species, 5).leaf_count()
	_check(count == 40, "leaf placement stops at the leaf limit (%d clusters)" % count)


## A capsule's axis: the segment its rounded ends are centred on.
func _capsule_axis(shape: CapsuleShape3D, transform: Transform3D) -> PackedVector3Array:
	var half := transform.basis.y.normalized() * (shape.height * 0.5 - shape.radius)
	return PackedVector3Array([transform.origin - half, transform.origin + half])


func _test_capsules_cover_wood() -> void:
	var covered := true
	var total := 0
	for path in SPECIES:
		var species: TreeSpecies = load(path)
		var skeleton := TreeSkeletonBuilder.build(species, 1)
		var wood := TreeCollider.wood(skeleton, species)
		total += wood.size()
		for node in skeleton.node_count():
			var radius := skeleton.radii[node]
			if radius < species.collision_min_radius_m:
				continue
			# Some capsule's axis passes within the path tolerance of this node,
			# and is within half the radius tolerance of its radius.
			var found := false
			for i in wood.size():
				var capsule := wood.shapes[i] as CapsuleShape3D
				var axis := _capsule_axis(capsule, wood.transforms[i])
				var point := skeleton.positions[node]
				if point.distance_to(Geometry3D.get_closest_point_to_segment(point, axis[0], axis[1])) \
						<= species.collision_tolerance_m + TOLERANCE \
						and absf(capsule.radius - radius) <= species.collision_radius_tolerance_m * 0.5 + TOLERANCE:
					found = true
					break
			covered = covered and found
	_check(covered and total > 0,
			"capsules cover every solid node of the three species, within the path and radius tolerances (%d capsules)" % total)


func _test_capsule_count() -> void:
	var trunk := TreeBranchLevel.new()
	trunk.segments_min = 18
	trunk.segments_max = 18
	trunk.girth_falloff = Curve.new()
	trunk.girth_falloff.add_point(Vector2(0.0, 1.0))
	trunk.girth_falloff.add_point(Vector2(1.0, 1.0))
	var straight := _species(trunk)
	var one := TreeCollider.wood(TreeSkeletonBuilder.build(straight, 1), straight).size()
	var curvy_level := trunk.duplicate()
	curvy_level.bend_deg_per_m = 25.0
	var curvy := _species(curvy_level)
	var skeleton := TreeSkeletonBuilder.build(curvy, 1)
	var tight := TreeCollider.wood(skeleton, curvy).size()
	curvy.collision_tolerance_m = 0.2
	var loose := TreeCollider.wood(skeleton, curvy).size()
	_check(one == 1 and tight > loose and loose >= 1,
			"a straight, even trunk is one capsule; a curvy one takes more, fewer with a looser tolerance (%d, %d)" % [tight, loose])


func _test_twigs_pass_through() -> void:
	var species := _branching_species()
	species.branch_levels[0].radius_ratio = 0.05
	species.collision_min_radius_m = 0.025
	var skeleton := TreeSkeletonBuilder.build(species, 9)
	var trunk_only := TreeSkeletonBuilder.build(_species(species.trunk), 9)
	var thin := true
	for branch in range(1, skeleton.branch_count()):
		thin = thin and skeleton.radii[skeleton.branch_first_node[branch]] < species.collision_min_radius_m
	_check(skeleton.branch_count() > 1 and thin
			and TreeCollider.wood(skeleton, species).size() == TreeCollider.wood(trunk_only, species).size(),
			"branches thinner than the minimum radius get no capsules")


func _test_leaf_volumes() -> void:
	var cards := _leafy_species(TreeSpecies.LeafStyle.CARDS)
	cards.leaf_card_stem = Vector2(0.03, 0.66)
	var skeleton := TreeSkeletonBuilder.build(cards, 5)
	var boxes := TreeCollider.leaves(skeleton, cards)
	var arrays := _leaf_arrays(cards, skeleton)
	var inside := boxes.size() == skeleton.leaf_count() and not arrays.is_empty()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX] if inside else PackedVector3Array()
	for i in (boxes.size() if inside else 0):
		var half := (boxes.shapes[i] as BoxShape3D).size * 0.5
		var into := boxes.transforms[i].affine_inverse()
		for k in 8:
			var local := into * vertices[i * 8 + k]
			inside = inside and absf(local.x) <= half.x + TOLERANCE and absf(local.y) <= half.y + TOLERANCE \
					and absf(local.z) <= half.z + TOLERANCE
	_check(inside, "each card cluster has one box holding every corner of its two quads")

	var clumps := _leafy_species(TreeSpecies.LeafStyle.CLUMPS)
	clumps.leaf_clump_jitter = 0.0
	skeleton = TreeSkeletonBuilder.build(clumps, 5)
	var spheres := TreeCollider.leaves(skeleton, clumps)
	arrays = _leaf_arrays(clumps, skeleton)
	var centred := spheres.size() == skeleton.leaf_count() and not arrays.is_empty()
	vertices = arrays[Mesh.ARRAY_VERTEX] if centred else PackedVector3Array()
	for i in (spheres.size() if centred else 0):
		var centre := Vector3.ZERO
		for k in 12:
			centre += vertices[i * 12 + k]
		centred = centred and spheres.transforms[i].origin.distance_to(centre / 12.0) < TOLERANCE \
				and absf((spheres.shapes[i] as SphereShape3D).radius - skeleton.leaf_size[i] * 0.5) < TOLERANCE
	_check(centred, "each clump has one sphere, centred on it and as big as it")


func _test_tree_collision_objects() -> void:
	var species: TreeSpecies = load(SPECIES[1])
	var tree := ProceduralTree.new()
	tree.species = species
	tree.tree_seed = 2
	root.add_child(tree)
	tree.regenerate()
	var body: StaticBody3D = tree._wood_body
	var foliage: Area3D = tree._foliage
	var wood := TreeCollider.wood(tree.skeleton, species)
	var leaves := TreeCollider.leaves(tree.skeleton, species)
	var set_up := body != null and foliage != null \
			and body.collision_layer == ProceduralTree.STATIC_LAYER and body.collision_mask == 0 \
			and foliage.collision_layer == ProceduralTree.FOLIAGE_LAYER and foliage.collision_mask == 0 \
			and not foliage.monitoring and foliage.monitorable \
			and body.get_shape_owners().size() == wood.size() \
			and foliage.get_shape_owners().size() == leaves.size() \
			and body.is_inside_tree() and foliage.is_inside_tree()
	tree.queue_free()
	_check(set_up, "a tree's wood is a static body on the Static layer and its leaves a touch-only Foliage area, one shape owner per shape")


func _collision_states(trees: Array) -> Array:
	return trees.map(func(tree: ProceduralTree) -> bool: return tree.has_collision())


func _test_collision_streaming() -> void:
	var target := Node3D.new()
	root.add_child(target)
	var streamer := TreeCollisionStreamer.new()
	streamer.target = target
	streamer.build_radius_m = 30.0
	streamer.release_radius_m = 36.0
	streamer.builds_per_tick = 1
	var species: TreeSpecies = load(SPECIES[1])
	var trees := []
	for x in [10.0, 33.0, 50.0, 100.0]:
		var tree := ProceduralTree.new()
		tree.species = species
		tree.position = Vector3(x, 0.0, 0.0)
		streamer.add_child(tree)
		trees.append(tree)
	root.add_child(streamer)
	_check(_collision_states(trees) == [true, false, false, false],
			"on load, only trees within the build radius of the target get collision")

	# Walk to x = 45 in half-metre steps: never more than one build per tick.
	var most_built_in_a_tick := 0
	var before := _collision_states(trees).count(true)
	while target.position.x < 45.0:
		target.position.x += 0.5
		await physics_frame
		var now := _collision_states(trees).count(true)
		most_built_in_a_tick = maxi(most_built_in_a_tick, now - before)
		before = now
	for i in 4:
		await physics_frame
	# 10 m tree is now 35 m away: between the radii, so it keeps its collision.
	_check(_collision_states(trees) == [true, true, true, false] and most_built_in_a_tick == 1,
			"walking builds trees coming near one per tick at most, and keeps those between the radii")

	# Jump to x = 100: everything is sorted out in the next tick.
	target.position.x = 100.0
	await physics_frame
	_check(_collision_states(trees) == [false, false, false, true],
			"after the target jumps, near trees are built and far ones freed within one tick")
	streamer.queue_free()
	target.queue_free()


func _test_streaming_without_target() -> void:
	var streamer := TreeCollisionStreamer.new()
	var species: TreeSpecies = load(SPECIES[1])
	var trees := []
	for x in [10.0, 500.0]:
		var tree := ProceduralTree.new()
		tree.species = species
		tree.position = Vector3(x, 0.0, 0.0)
		streamer.add_child(tree)
		trees.append(tree)
	root.add_child(streamer)
	await physics_frame
	_check(_collision_states(trees) == [true, true], "with no target, every tree keeps its collision")
	streamer.queue_free()


func _triangles(mesh: ArrayMesh, surface: int) -> int:
	return mesh.surface_get_arrays(surface)[Mesh.ARRAY_INDEX].size() / 3 if surface < mesh.get_surface_count() else 0


func _test_detail_levels_get_cheaper() -> void:
	var cheaper := true
	var counts := []
	for path in SPECIES:
		var species: TreeSpecies = load(path)
		var skeleton := TreeSkeletonBuilder.build(species, 1)
		var meshes := []
		for level in TreeMesher.Level.size():
			meshes.append(TreeMesher.build(skeleton, species, level))
		var wood := meshes.map(func(mesh: ArrayMesh) -> int: return _triangles(mesh, 0))
		var cards := meshes.map(func(mesh: ArrayMesh) -> int: return floori(_triangles(mesh, 1) / 4.0))
		var clusters := skeleton.leaf_count()
		cheaper = cheaper and wood[0] > wood[1] and wood[1] > wood[2] \
				and cards[0] == clusters \
				and cards[1] == ceili(clusters / float(species.lod_medium_leaf_step)) \
				and cards[2] == ceili(clusters / float(species.lod_far_leaf_step))
		counts.append("%d/%d/%d" % [wood[0] + cards[0] * 4, wood[1] + cards[1] * 4, wood[2] + cards[2] * 4])
	_check(cheaper, "each detail level has fewer wood triangles and keeps one cluster in its leaf step (triangles %s)"
			% ", ".join(counts))


func _test_detail_leaves_out_thin_branches() -> void:
	var species := _branching_species()
	species.lod_far_min_branch_radius_m = species.trunk.base_radius_m - 0.001
	var skeleton := TreeSkeletonBuilder.build(species, 9)
	var trunk_only := _species(species.trunk)
	trunk_only.lod_far_min_branch_radius_m = species.lod_far_min_branch_radius_m
	var far: int = TreeMesher.build(skeleton, species, TreeMesher.Level.FAR) \
			.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
	var trunk: int = TreeMesher.build(TreeSkeletonBuilder.build(trunk_only, 9), trunk_only, TreeMesher.Level.FAR) \
			.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
	species.lod_far_min_branch_radius_m = 10.0
	var nothing := TreeMesher.build(skeleton, species, TreeMesher.Level.FAR).get_surface_count()
	_check(skeleton.branch_count() > 1 and far == trunk and nothing == 0,
			"a detail level leaves out branches thinner than its minimum, and builds no empty surface")


func _test_detail_leaf_area() -> void:
	var species := _leafy_species(TreeSpecies.LeafStyle.CARDS)
	species.lod_medium_leaf_step = 3
	var skeleton := TreeSkeletonBuilder.build(species, 5)
	var mesh := TreeMesher.build(skeleton, species, TreeMesher.Level.MEDIUM)
	var vertices: PackedVector3Array = mesh.surface_get_arrays(1)[Mesh.ARRAY_VERTEX]
	var enlarged := vertices.size() == ceili(skeleton.leaf_count() / 3.0) * 8
	for card in (floori(vertices.size() / 8.0) if enlarged else 0):
		# The card's width is its cluster's size, times the square root of the step.
		var width := vertices[card * 8].distance_to(vertices[card * 8 + 1])
		enlarged = enlarged and absf(width - skeleton.leaf_size[card * 3] * sqrt(3.0)) < TOLERANCE
	_check(enlarged, "a detail level keeps every leaf-step-th cluster, enlarged to keep the leaf area")


## Whether a level with this fade draws a pixel with this dither threshold at
## this distance: tree_lod.gdshaderinc's rule, mirrored.
func _level_draws(fade: Vector4, distance: float, threshold: float) -> bool:
	var shown_in := clampf((distance - fade.x) / (fade.y - fade.x), 0.0, 1.0) if fade.y > fade.x else 1.0
	var shown_out := clampf((fade.w - distance) / (fade.w - fade.z), 0.0, 1.0) if fade.w > fade.z else 1.0
	return not (threshold < 1.0 - shown_in or threshold >= shown_out)


## Whether a level is drawn at a distance by its visibility range.
func _level_in_range(instance: MeshInstance3D, distance: float) -> bool:
	return distance >= instance.visibility_range_begin \
			and (instance.visibility_range_end <= 0.0 or distance <= instance.visibility_range_end)


func _test_tree_detail_levels() -> void:
	var species: TreeSpecies = load(SPECIES[1])
	var tree := ProceduralTree.new()
	tree.species = species
	tree.tree_seed = 3
	root.add_child(tree)
	var levels: Array[MeshInstance3D] = tree._levels
	var bounds: AABB = (levels[0].mesh as ArrayMesh).custom_aabb
	var shared := levels.size() == 3 and bounds.size != Vector3.ZERO
	for instance in levels:
		shared = shared and instance.mesh.custom_aabb == bounds \
				and instance.get_instance_shader_parameter(&"lod_centre") == bounds.get_center() \
				and instance.visibility_range_fade_mode == GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED \
				and instance.visibility_range_begin_margin == 0.0 and instance.visibility_range_end_margin == 0.0
	var half := species.lod_fade_band_m * 0.5
	var placed := is_equal_approx(levels[0].visibility_range_end, species.lod_medium_distance_m + half) \
			and is_equal_approx(levels[1].visibility_range_begin, species.lod_medium_distance_m - half) \
			and is_equal_approx(levels[1].visibility_range_end, species.lod_far_distance_m + half) \
			and is_equal_approx(levels[2].visibility_range_begin, species.lod_far_distance_m - half) \
			and is_equal_approx(levels[2].visibility_range_end, species.lod_hide_distance_m + half)
	_check(shared and placed, "a tree's three levels share bounds and are drawn around the species' distances")

	# Every pixel at every distance is drawn by exactly one level, until the tree is hidden.
	var once := true
	var distance := 0.5
	while distance < species.lod_hide_distance_m - half:
		for cell in 16:
			var threshold := (cell + 0.5) / 16.0
			var drawn := 0
			for instance in levels:
				var fade: Vector4 = instance.get_instance_shader_parameter(&"lod_fade")
				if _level_in_range(instance, distance) and _level_draws(fade, distance, threshold):
					drawn += 1
			once = once and drawn == 1
		distance += 0.25
	_check(once, "at every distance each pixel is drawn by exactly one level, so the fades leave no gap and draw nothing twice")

	tree.detail_preview = 3
	var previewed: bool = not levels[0].visible and not levels[1].visible and levels[2].visible \
			and levels[2].visibility_range_end == 0.0 \
			and levels[2].get_instance_shader_parameter(&"lod_fade") == Vector4.ZERO
	tree.queue_free()
	_check(previewed, "previewing a level shows only it, at any distance, without fading")


func _tree(species: TreeSpecies, tree_seed: int, position := Vector3.ZERO) -> ProceduralTree:
	var tree := ProceduralTree.new()
	tree.species = species
	tree.tree_seed = tree_seed
	tree.position = position
	return tree


func _test_variants_share() -> void:
	var species: TreeSpecies = load(SPECIES[1]).duplicate()
	species.variants = 8
	var trees := []
	for tree_seed in [3, 11, 19, 4]:
		trees.append(_tree(species, tree_seed))
		root.add_child(trees[-1])
	var shared: bool = trees[0].skeleton == trees[1].skeleton and trees[1].skeleton == trees[2].skeleton \
			and trees[0]._levels[0].mesh == trees[1]._levels[0].mesh \
			and trees[0]._levels[2].mesh == trees[2]._levels[2].mesh \
			and trees[3].skeleton != trees[0].skeleton and TreeCache.built_count(species) == 2
	var unique: TreeSpecies = load(SPECIES[1]).duplicate()
	unique.variants = 0
	var a := _tree(unique, 3)
	var b := _tree(unique, 11)
	root.add_child(a)
	root.add_child(b)
	shared = shared and a.skeleton != b.skeleton and TreeCache.built_count(unique) == 2
	for tree in trees + [a, b]:
		tree.queue_free()
	_check(shared, "trees whose seeds pick the same variant share its skeleton and meshes; 0 variants shares nothing")


func _test_variation() -> void:
	var species: TreeSpecies = load(SPECIES[1]).duplicate()
	species.variants = 8
	species.turn_variation_deg = 90.0
	species.size_variation = 0.2
	var within := true
	var turns := {}
	for tree_seed in 200:
		var variation := species.variation_for(tree_seed)
		var size := variation.basis.get_scale().x
		var turn := rad_to_deg(variation.basis.orthonormalized().get_euler().y)
		within = within and variation == species.variation_for(tree_seed) \
				and size >= 0.8 - TOLERANCE and size <= 1.2 + TOLERANCE \
				and absf(turn) <= 90.0 + 0.01 and variation.basis.orthonormalized().get_euler().x == 0.0
		turns[snappedf(turn, 1.0)] = true
	var tree := _tree(species, 11, Vector3(4.0, 0.0, 2.0))
	root.add_child(tree)
	var applied := tree.transform == Transform3D(Basis.IDENTITY, Vector3(4.0, 0.0, 2.0))
	for level in tree._levels:
		applied = applied and level.transform == species.variation_for(11)
	applied = applied and tree._wood_body.transform == species.variation_for(11) \
			and tree._foliage.transform == species.variation_for(11)
	tree.queue_free()
	_check(within and turns.size() > 100 and applied,
			"each seed gets its own turn and size within the species' limits, applied inside the tree")


func _test_scaled_collision() -> void:
	var species: TreeSpecies = load(SPECIES[1]).duplicate()
	species.size_variation = 0.3
	# A seed that makes the tree noticeably bigger.
	var tree_seed := 0
	while species.variation_for(tree_seed).basis.get_scale().x < 1.2:
		tree_seed += 1
	var size := species.variation_for(tree_seed).basis.get_scale().x
	var tree := _tree(species, tree_seed, Vector3(50.0, 0.0, 50.0))
	root.add_child(tree)
	await physics_frame
	await physics_frame
	var height := 0.6
	var query := PhysicsRayQueryParameters3D.create(Vector3(56.0, height, 50.0), Vector3(50.0, height, 50.0))
	query.collision_mask = ProceduralTree.STATIC_LAYER
	var hit := tree.get_world_3d().direct_space_state.intersect_ray(query)
	var expected := tree.skeleton.sample_radius(0, height / size) * size
	var reached := 0.0 if hit.is_empty() else Vector2(hit.position.x - 50.0, hit.position.z - 50.0).length()
	tree.queue_free()
	_check(not hit.is_empty() and absf(reached - expected) <= species.collision_radius_tolerance_m * size + 0.02,
			"a scaled tree's trunk collision is where its scaled bark is (%.3f m from the axis, bark at %.3f m)" % [reached, expected])


func _test_scatter() -> void:
	var target := Node3D.new()
	root.add_child(target)
	var streamer := TreeCollisionStreamer.new()
	streamer.target = target
	root.add_child(streamer)
	var scatter := TreeScatter.new()
	scatter.streamer = streamer
	var pine: TreeSpecies = load(SPECIES[0])
	var oak: TreeSpecies = load(SPECIES[1])
	scatter.species = [pine, oak, oak]
	scatter.area_size_m = Vector2(120.0, 120.0)
	scatter.tree_count = 120
	scatter.min_spacing_m = 7.0
	scatter.clearing_radius_m = 10.0
	scatter.forest_seed = 4
	root.add_child(scatter)
	var trees := scatter.trees
	var spread := trees.size() > 60 and trees.size() <= 120
	var nearest := INF
	for i in trees.size():
		var here := Vector2(trees[i].position.x, trees[i].position.z)
		spread = spread and absf(here.x) <= 60.0 and absf(here.y) <= 60.0 and here.length() >= 10.0 \
				and trees[i].get_parent() == streamer
		for j in range(i + 1, trees.size()):
			nearest = minf(nearest, here.distance_to(Vector2(trees[j].position.x, trees[j].position.z)))
	# Collision only near the target, at the centre.
	var streamed := true
	for tree in trees:
		streamed = streamed and tree.has_collision() == (tree.position.length() <= streamer.build_radius_m)
	var placements := trees.map(func(tree: ProceduralTree) -> Vector3: return tree.position)
	var seeds := trees.map(func(tree: ProceduralTree) -> int: return tree.tree_seed)
	scatter.scatter()
	var same: bool = scatter.trees.map(func(tree: ProceduralTree) -> Vector3: return tree.position) == placements \
			and scatter.trees.map(func(tree: ProceduralTree) -> int: return tree.tree_seed) == seeds
	var builds := TreeCache.built_count(pine) + TreeCache.built_count(oak)
	scatter.queue_free()
	streamer.queue_free()
	target.queue_free()
	_check(spread and nearest >= 7.0 and same,
			"a scatter fills its area, keeps its spacing (nearest %.1f m) and clearing, and grows the same forest from the same seed (%d trees)"
			% [nearest, trees.size()])
	_check(streamed and builds <= pine.variants + oak.variants,
			"scattered trees stream their collision and share at most the species' variants (%d built)" % builds)


## A small forest of two species, one with impostors and one without.
func _impostor_forest() -> TreeScatter:
	var with_cards: TreeSpecies = load(SPECIES[1]).duplicate()
	with_cards.impostor_distance_m = 100.0
	var without: TreeSpecies = load(SPECIES[2]).duplicate()
	without.impostor_distance_m = 0.0
	var scatter := TreeScatter.new()
	scatter.species = [with_cards, without]
	scatter.area_size_m = Vector2(80.0, 80.0)
	scatter.tree_count = 40
	scatter.position = Vector3(30.0, 0.0, -20.0)
	scatter.rotation_degrees = Vector3(0.0, 25.0, 0.0)
	scatter.forest_seed = 7
	root.add_child(scatter)
	return scatter


func _test_impostor_cards() -> void:
	var scatter := _impostor_forest()
	var with_cards: TreeSpecies = scatter.species[0]
	var trees := scatter.trees.filter(func(tree: ProceduralTree) -> bool: return tree.species == with_cards)
	# The MultiMesh's own instance data can't be read back without a renderer,
	# so check what the scatter fills it with.
	var placed := scatter.impostors.size() == 1 and trees.size() > 5 \
			and scatter.impostors[0].multimesh.instance_count == trees.size()
	for i in (trees.size() if placed else 0):
		var tree: ProceduralTree = trees[i]
		var filled := scatter.card_for(tree)
		var card: Transform3D = filled[0]
		var custom: Color = filled[1]
		var pictured := Vector3(custom.g, custom.b, custom.a)
		# The shader finds the tree's foot as the card's origin less its turned
		# picture centre; it must be where the tree stands.
		var foot := scatter.to_global(card.origin - card.basis * pictured)
		placed = placed and scatter.to_global(card.origin).distance_to(tree.detail_centre()) < TOLERANCE \
				and foot.distance_to(tree.global_position) < TOLERANCE \
				and int(custom.r) == with_cards.variant_for(tree.tree_seed) \
				and absf(card.basis.get_scale().x - with_cards.variation_for(tree.tree_seed).basis.get_scale().x) < TOLERANCE
	_check(placed, "a species with impostors gets one card per tree, standing on the tree, with its turn, size and variant; one without gets none")
	# Headless, nothing can be baked: the cards stay hidden and the trees keep their far level.
	var kept := not TreeImpostors.can_bake() and not scatter.impostors[0].visible \
			and scatter.trees.all(func(tree: ProceduralTree) -> bool: return not tree.impostor_handoff)
	scatter.queue_free()
	_check(kept, "without a renderer no pictures are baked, the cards stay hidden and every tree keeps its own far level")


func _test_impostor_handoff() -> void:
	var species: TreeSpecies = load(SPECIES[1]).duplicate()
	species.impostor_distance_m = 100.0
	var tree := _tree(species, 3)
	root.add_child(tree)
	tree.impostor_handoff = true
	var far: MeshInstance3D = tree._levels[TreeMesher.Level.FAR]
	var card_fade := TreeImpostors.fade_for(species)
	var once := is_equal_approx(far.visibility_range_end, 100.0 + species.lod_fade_band_m * 0.5)
	# From where the far level is fully in, past the handoff.
	var distance := species.lod_changes(true).y + species.lod_fade_band_m * 0.5
	while distance < 140.0:
		for cell in 16:
			var threshold := (cell + 0.5) / 16.0
			var drawn := 0
			if _level_in_range(far, distance) and _level_draws(far.get_instance_shader_parameter(&"lod_fade"), distance, threshold):
				drawn += 1
			# A card nearer than its fade collapses to nothing.
			if distance >= card_fade.x and _level_draws(card_fade, distance, threshold):
				drawn += 1
			once = once and drawn == 1
		distance += 0.25
	tree.queue_free()
	_check(once, "handing over, a tree's far level and its card draw each pixel exactly once across the band")


func _report_timings() -> void:
	print("\nGeneration time on this machine (desktop, not Quest 3S), 100 builds each:")
	for path in SPECIES:
		var species: TreeSpecies = load(path)
		var start := Time.get_ticks_usec()
		var mesh: ArrayMesh
		var skeleton: TreeSkeleton
		for i in 100:
			skeleton = TreeSkeletonBuilder.build(species, i)
			mesh = TreeMesher.build(skeleton, species)
		var each := (Time.get_ticks_usec() - start) / 100.0
		start = Time.get_ticks_usec()
		var lower := []
		for level in [TreeMesher.Level.MEDIUM, TreeMesher.Level.FAR]:
			var lower_mesh: ArrayMesh
			for i in 100:
				lower_mesh = TreeMesher.build(skeleton, species, level)
			lower.append("%d wood + %d leaf" % [_triangles(lower_mesh, 0), _triangles(lower_mesh, 1)])
		print("  %-18s medium: %s triangles, far: %s triangles; both levels %.0f µs to build" % [
				path.get_file(), lower[0], lower[1], (Time.get_ticks_usec() - start) / 100.0])
		start = Time.get_ticks_usec()
		var wood_shapes: TreeCollider.Shapes
		var leaf_shapes: TreeCollider.Shapes
		for i in 100:
			wood_shapes = TreeCollider.wood(skeleton, species)
			leaf_shapes = TreeCollider.leaves(skeleton, species)
		var collider_each := (Time.get_ticks_usec() - start) / 100.0
		print("  %-18s collision: %d capsules, %d leaf volumes, %.0f µs to work out" % [
				path.get_file(), wood_shapes.size(), leaf_shapes.size(), collider_each])
		var wood := mesh.surface_get_arrays(0)
		var leaf_triangles := 0
		if mesh.get_surface_count() > 1:
			leaf_triangles = mesh.surface_get_arrays(1)[Mesh.ARRAY_INDEX].size() / 3
		print("  %-18s %7.1f µs per tree, %3d branches, %5d wood triangles, %4d clusters (%s), %5d leaf triangles" % [
				path.get_file(), each, skeleton.branch_count(), wood[Mesh.ARRAY_INDEX].size() / 3,
				skeleton.leaf_count(), TreeSpecies.LeafStyle.keys()[species.leaf_style].to_lower(),
				leaf_triangles])
