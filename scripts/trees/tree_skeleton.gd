class_name TreeSkeleton
extends RefCounted

## One tree's shape as plain data: branches, each a path of nodes with a radius,
## and the leaf clusters growing on them.
## The mesh and collision are always generated from this and never edited
## directly, so this is the tree's single source of truth.
##
## Each branch's nodes are stored together, in order from its base to its tip.
## Distances are measured along the branch from its natural base, so texture
## coordinates derived from them stay put however the branch is later divided.
## Branches are stored depth first: each is followed by everything growing from
## it, its children in order up it.
##
## A tree is cut by splitting its skeleton (split()): each piece is a skeleton of
## its own, whose cut ends are marked (branch_cut) so they are drawn as cut wood.
##
## A grown tree is made of segments (2026-10-02): every branch is a whole number
## of segment_length long, with a node at every segment line (a whole number of
## segments from its natural base), and its path never turns at a line. Each
## node keeps the frame its mesh ring is drawn in (axes, normals), worked out
## once on the whole tree, so any piece of it is drawn as the whole tree was and
## meets the other piece exactly at a cut.

## Flags in branch_cut: the branch's base, or its tip, is a cut.
const CUT_BASE := 1
const CUT_TIP := 2
# Nodes this close to a cut, along their branch, are taken as at it.
const _SAME_DISTANCE := 0.0001
# How far apart junction_span looks along a branch, in metres.
const _JUNCTION_STEP := 0.02
# A branch end this close to a segment line, as a share of a segment, is on it.
const _LINE_TOLERANCE := 0.001

# Nodes.
var positions := PackedVector3Array()
## Radius of the branch at each node, in metres.
var radii := PackedFloat32Array()
## Distance along its branch from the branch's base to each node, in metres.
var distances := PackedFloat32Array()
var node_branch := PackedInt32Array()
## The direction along its branch at each node: the stretch's at an end, else
## the average of the two stretches meeting there (compute_frames).
var axes := PackedVector3Array()
## The direction across its branch at each node, square to its axis, that its
## ring starts from: carried from the branch's base without twisting.
var normals := PackedVector3Array()

## The length of every segment, in metres; 0 for a skeleton not grown in segments.
var segment_length := 0.0
## The whole tree's trunk radius at its first segment line, kept by every piece
## of it: what a line takes to chop through scales from it (TreeChop).
var first_line_radius := 0.0
# Each branch's junction (_junction), once worked out.
var _junctions := {}

# Branches.
## 0 for the trunk, 1 for branches off the trunk, and so on.
var branch_depth := PackedInt32Array()
## The branch this one grows from; -1 for the trunk.
var branch_parent := PackedInt32Array()
## Distance along the parent where this branch grows from, in metres.
var branch_attach_distance := PackedFloat32Array()
var branch_first_node := PackedInt32Array()
var branch_node_count := PackedInt32Array()
## Radius at the branch's natural base, in metres. A piece cut from a branch
## keeps it, so its bark is laid out as on the whole branch (TreeMesher).
var branch_base_radius := PackedFloat32Array()
## Which of the branch's ends are cuts (CUT_BASE, CUT_TIP).
var branch_cut := PackedByteArray()
## Which branch of the whole tree this is: its index there, kept through every
## split and prune, so a piece's branches can be told apart from the tree's.
var branch_id := PackedInt32Array()

# Leaf clusters. Each belongs to a branch at a distance along it, so its place
# follows the branch however the branch is later divided.
var leaf_branch := PackedInt32Array()
## Distance along its branch where the cluster grows, in metres.
var leaf_distance := PackedFloat32Array()
## Unit direction the cluster grows out from its branch.
var leaf_forward := PackedVector3Array()
## Turn of the cluster around its forward direction, in radians.
var leaf_roll := PackedFloat32Array()
## Card width or clump diameter, in metres.
var leaf_size := PackedFloat32Array()
## Seed for the cluster's own shape details, such as a clump's lumps.
var leaf_seed := PackedInt32Array()
## The crown as grown: the box around every cluster's place on its branch.
## Leaf normals point out of the ellipsoid through this box. It is kept here,
## not worked out from whichever leaves are being drawn, so a piece of the tree
## keeps the shading it had on the whole tree.
var crown_middle := Vector3.ZERO
var crown_half_size := Vector3.ZERO


func branch_count() -> int:
	return branch_depth.size()


func node_count() -> int:
	return positions.size()


func leaf_count() -> int:
	return leaf_branch.size()


## Starts a new branch. Its nodes are the ones added until the next branch starts.
func add_branch(depth: int, parent: int, attach_distance: float) -> int:
	branch_depth.append(depth)
	branch_parent.append(parent)
	branch_attach_distance.append(attach_distance)
	branch_first_node.append(positions.size())
	branch_node_count.append(0)
	branch_base_radius.append(0.0)
	branch_cut.append(0)
	branch_id.append(branch_depth.size() - 1)
	return branch_depth.size() - 1


## Adds a node to the end of the most recently started branch. The first node's
## radius is the branch's base radius, unless the branch is set otherwise after.
func add_node(position: Vector3, radius: float, distance: float) -> void:
	var branch := branch_depth.size() - 1
	assert(branch >= 0, "Start a branch before adding nodes to it.")
	if branch_node_count[branch] == 0:
		branch_base_radius[branch] = radius
	positions.append(position)
	radii.append(radius)
	distances.append(distance)
	node_branch.append(branch)
	branch_node_count[branch] += 1


func add_leaf(branch: int, distance: float, forward: Vector3, roll: float, size: float,
		shape_seed: int) -> void:
	leaf_branch.append(branch)
	leaf_distance.append(distance)
	leaf_forward.append(forward)
	leaf_roll.append(roll)
	leaf_size.append(size)
	leaf_seed.append(shape_seed)


## Where a leaf cluster starts: on its branch's bark, on the side it grows out
## toward, so a cluster on a thick trunk doesn't start buried in the wood.
func leaf_anchor(leaf: int) -> Vector3:
	var branch := leaf_branch[leaf]
	var distance := leaf_distance[leaf]
	var along := sample_direction(branch, distance)
	var outward := leaf_forward[leaf] - along * leaf_forward[leaf].dot(along)
	var point := sample_position(branch, distance)
	if outward.length_squared() < 0.00001:
		return point
	return point + outward.normalized() * sample_radius(branch, distance)


## Length of a branch along its path, in metres.
func branch_length(branch: int) -> float:
	return distances[branch_first_node[branch] + branch_node_count[branch] - 1]


## Point on a branch's path at a distance along it, between nodes if need be.
func sample_position(branch: int, distance: float) -> Vector3:
	var node := _node_before(branch, distance)
	return positions[node].lerp(positions[node + 1], _weight(node, distance))


## Radius of a branch at a distance along it.
func sample_radius(branch: int, distance: float) -> float:
	var node := _node_before(branch, distance)
	return lerpf(radii[node], radii[node + 1], _weight(node, distance))


## Direction of a branch's path at a distance along it: the direction of the
## stretch between the two nodes around that distance.
func sample_direction(branch: int, distance: float) -> Vector3:
	var node := _node_before(branch, distance)
	return (positions[node + 1] - positions[node]).normalized()


## Works out every node's frame (axes, normals), branch by branch: its axis
## from its neighbours, its normal carried from the branch's base without
## twisting. The builder does it once, on the whole tree; pieces copy theirs.
func compute_frames() -> void:
	axes.resize(node_count())
	normals.resize(node_count())
	for branch in branch_count():
		var first := branch_first_node[branch]
		var last := first + branch_node_count[branch] - 1
		for node in range(first, last + 1):
			axes[node] = (positions[mini(node + 1, last)] - positions[maxi(node - 1, first)]).normalized()
			normals[node] = TreeSkeletonBuilder.any_perpendicular(axes[node]) if node == first \
					else TreeSkeletonBuilder.carry(normals[node - 1], axes[node - 1], axes[node])


## Works out the frames if they aren't yet: for a skeleton built by hand.
func ensure_frames() -> void:
	if axes.size() != node_count():
		compute_frames()


## The frame at a distance along a branch: (axis, normal). At a node, the node's;
## between two, along the stretch, its normal carried there from the node before.
func sample_frame(branch: int, distance: float) -> PackedVector3Array:
	ensure_frames()
	var node := _node_before(branch, distance)
	for at in [node, node + 1]:
		if absf(distances[at] - distance) < _SAME_DISTANCE:
			return PackedVector3Array([axes[at], normals[at]])
	var axis := (positions[node + 1] - positions[node]).normalized()
	return PackedVector3Array([axis, TreeSkeletonBuilder.carry(normals[node], axes[node], axis)])


## Where a branch joins its parent, as distances along the parent: from where
## its wood starts, just behind the parent's centre line, to where its bark
## clears the parent's all round (bark_clear_distance). A cut through the
## parent between them would cut through the branch's base too.
func junction_span(branch: int) -> Vector2:
	var junction := _junction(branch)
	return Vector2(junction.x, junction.y)


## How far along a branch, from its natural base on its parent's centre line,
## its bark clears its parent's bark all round.
func bark_clear_distance(branch: int) -> float:
	return _junction(branch).z


## The segment lines strictly inside a branch, as its first and last line's
## number k (counted from its natural base, so a piece numbers them as the whole
## tree did). It is empty (x above y) if it has none: for a piece cut at line k
## and one segment long, (k + 1, k); Vector2i(1, 0) if the skeleton has no
## segments.
func line_range(branch: int) -> Vector2i:
	if segment_length <= 0.0:
		return Vector2i(1, 0)
	var base := distances[branch_first_node[branch]]
	return Vector2i(floori(base / segment_length + _LINE_TOLERANCE) + 1,
			ceili(branch_length(branch) / segment_length - _LINE_TOLERANCE) - 1)


## Whether a branch's line k is wood to chop: at least `min_radius` thick there
## and half a segment on, so the piece cut off beyond it is solid enough to land
## and be struck (2026-10-02: a piece cut where the wood only just reached it had
## a sliver of collision, and fell through the level's floor); and past where the
## branch's bark clears its parent's (closer in, a cut would run through the
## parent too).
func line_is_wood(branch: int, k: int, min_radius: float) -> bool:
	var at := k * segment_length
	if sample_radius(branch, at) < min_radius \
			or sample_radius(branch, minf(at + segment_length * 0.5, branch_length(branch))) < min_radius:
		return false
	return branch_parent[branch] < 0 or at > bark_clear_distance(branch)


## Whether a branch's line k runs through where one of its children joins it
## (TreeSkeleton.junction_span), leaving out children whose `gone` is set: a cut
## there would go through that child's base.
func line_blocked(branch: int, k: int, gone := PackedByteArray()) -> bool:
	var at := k * segment_length
	var child := branch + 1
	var end := subtree_end(branch)
	while child < end:
		if not (child < gone.size() and gone[child]):
			var span := junction_span(child)
			if span.x < at and at < span.y:
				return true
		child = subtree_end(child)
	return false


## How many of a branch's segments are wood: at least `min_radius` thick where
## they start (thinner, they are twig). 0 if the skeleton has no segments.
func wood_segments(branch: int, min_radius: float) -> int:
	if segment_length <= 0.0:
		return 0
	var base := distances[branch_first_node[branch]]
	var count := 0
	for k in range(roundi(base / segment_length), roundi(branch_length(branch) / segment_length)):
		if sample_radius(branch, maxf(k * segment_length, base)) >= min_radius:
			count += 1
	return count


## Whether a branch is a twig: neither a root nor a cut stub, and with no line
## that is wood to chop (line_is_wood). A twig breaks off whole instead
## (ProceduralTree.break_branch).
func is_twig(branch: int, min_radius: float) -> bool:
	if branch_parent[branch] < 0 or branch_cut[branch] & CUT_TIP:
		return false
	var lines := line_range(branch)
	for k in range(lines.x, lines.y + 1):
		if line_is_wood(branch, k, min_radius):
			return false
	return true


## (junction from, junction to, bark clear distance): walks the branch out from
## its base in short steps until its bark is clear of its parent's, taking in
## the extent along the parent of each ring of it on the way. Worked out once
## per branch.
func _junction(branch: int) -> Vector3:
	if not _junctions.has(branch):
		_junctions[branch] = _walk_junction(branch)
	return _junctions[branch]


func _walk_junction(branch: int) -> Vector3:
	var parent := branch_parent[branch]
	var attach := branch_attach_distance[branch]
	if parent < 0:
		return Vector3(attach, attach, 0.0)
	var origin := sample_position(parent, attach)
	var along := sample_direction(parent, attach)
	var parent_radius := sample_radius(parent, attach)
	var first := branch_first_node[branch]
	var distance := distances[first]
	var end := branch_length(branch)
	var low := INF
	var high := -INF
	while true:
		var offset := sample_position(branch, distance) - origin
		var radius := sample_radius(branch, distance)
		var direction := sample_direction(branch, distance)
		# A ring of the branch reaches this far along the parent either side of its middle.
		var reach := radius * sqrt(maxf(1.0 - pow(direction.dot(along), 2.0), 0.0))
		low = minf(low, offset.dot(along) - reach)
		high = maxf(high, offset.dot(along) + reach)
		var out := (offset - along * offset.dot(along)).length()
		if out > parent_radius + radius or distance >= end:
			break
		distance = minf(distance + _JUNCTION_STEP, end)
	return Vector3(attach + low, attach + high, distance)


## Cuts the tree across a branch at a distance along it, into two skeletons: the
## lower keeps the rest of the tree with the branch up to the cut; the upper is
## the branch from the cut to its tip, with every branch and leaf growing from it
## above the cut. Each piece gets a node at the cut, and the cut ends are marked
## (branch_cut). Every node, branch and leaf keeps its distance along its
## branch, each node its frame and each branch its natural base radius, so the
## pieces' bark lines up as it did. Both keep the whole tree's crown box, and so
## its leaf shading, and its segment length. The cut must leave some of the
## branch on each side.
func split(branch: int, distance: float) -> Array[TreeSkeleton]:
	var first := branch_first_node[branch]
	assert(distance > distances[first] and distance < branch_length(branch),
			"A cut must leave some of the branch on each side.")
	# The branches going up with the cut: those growing from the branch above
	# the cut, each with everything growing from it.
	var moving := {}
	var end := subtree_end(branch)
	var child := branch + 1
	while child < end:
		var child_end := subtree_end(child)
		if branch_attach_distance[child] > distance:
			for moved in range(child, child_end):
				moving[moved] = true
		child = child_end
	var lower := TreeSkeleton.new()
	var upper := TreeSkeleton.new()
	var lower_index := {}
	var upper_index := {branch: upper._add_piece(self, branch, -1, distance, INF)}
	for old in branch_count():
		if moving.has(old):
			upper_index[old] = upper._add_piece(self, old, upper_index[branch_parent[old]])
		else:
			var to := distance if old == branch else INF
			lower_index[old] = lower._add_piece(self, old, lower_index.get(branch_parent[old], -1), -INF, to)
	for leaf in leaf_count():
		var owner := leaf_branch[leaf]
		var up := moving.has(owner) or (owner == branch and leaf_distance[leaf] > distance)
		var piece := upper if up else lower
		var index: int = upper_index[owner] if up else lower_index[owner]
		piece.add_leaf(index, leaf_distance[leaf], leaf_forward[leaf], leaf_roll[leaf],
				leaf_size[leaf], leaf_seed[leaf])
	for piece in [lower, upper]:
		piece.crown_middle = crown_middle
		piece.segment_length = segment_length
		piece.first_line_radius = first_line_radius
		piece.crown_half_size = crown_half_size
	var pieces: Array[TreeSkeleton] = [lower, upper]
	return pieces


## Adds the part of another skeleton's branch between two distances along it
## (all of it by default) as a branch growing from `parent`, with a node at each
## end that is cut, each node with its frame there. Returns its index here.
func _add_piece(source: TreeSkeleton, branch: int, parent: int, from := -INF, to := INF) -> int:
	source.ensure_frames()
	var attach := source.branch_attach_distance[branch] if parent >= 0 else 0.0
	var index := add_branch(source.branch_depth[branch], parent, attach)
	var first := source.branch_first_node[branch]
	if from > -INF:
		add_node(source.sample_position(branch, from), source.sample_radius(branch, from), from)
		_add_frame(source.sample_frame(branch, from))
	for node in range(first, first + source.branch_node_count[branch]):
		var at := source.distances[node]
		if at > from + _SAME_DISTANCE and at < to - _SAME_DISTANCE:
			add_node(source.positions[node], source.radii[node], at)
			_add_frame(PackedVector3Array([source.axes[node], source.normals[node]]))
	if to < INF:
		add_node(source.sample_position(branch, to), source.sample_radius(branch, to), to)
		_add_frame(source.sample_frame(branch, to))
	branch_base_radius[index] = source.branch_base_radius[branch]
	branch_cut[index] = source.branch_cut[branch] | (CUT_BASE if from > -INF else 0) \
			| (CUT_TIP if to < INF else 0)
	branch_id[index] = source.branch_id[branch]
	return index


## Gives the node just added the frame (axis, normal).
func _add_frame(frame: PackedVector3Array) -> void:
	axes.append(frame[0])
	normals.append(frame[1])


## This skeleton without the branches whose `gone` is set, nor the leaf clusters
## whose `gone_leaves` is set or that grew on a branch that is gone (broken off:
## ProceduralTree.break_branch). A branch gone takes everything growing from it.
## Distances, base radii, cuts and ids are kept, as in split().
func pruned(gone: PackedByteArray, gone_leaves: PackedByteArray) -> TreeSkeleton:
	var kept := TreeSkeleton.new()
	var index := {}
	var branch := 0
	while branch < branch_count():
		if branch < gone.size() and gone[branch]:
			branch = subtree_end(branch)
			continue
		index[branch] = kept._add_piece(self, branch, index.get(branch_parent[branch], -1))
		branch += 1
	for leaf in leaf_count():
		if index.has(leaf_branch[leaf]) and not (leaf < gone_leaves.size() and gone_leaves[leaf]):
			kept.add_leaf(index[leaf_branch[leaf]], leaf_distance[leaf], leaf_forward[leaf], leaf_roll[leaf],
					leaf_size[leaf], leaf_seed[leaf])
	kept.crown_middle = crown_middle
	kept.segment_length = segment_length
	kept.first_line_radius = first_line_radius
	kept.crown_half_size = crown_half_size
	return kept


## The branch with this id (branch_id), or -1 if this skeleton has none.
func branch_with_id(id: int) -> int:
	return branch_id.find(id)


## The index just past a branch and everything growing from it.
func subtree_end(branch: int) -> int:
	var end := branch + 1
	while end < branch_count() and branch_depth[end] > branch_depth[branch]:
		end += 1
	return end


## The branch whose bark is closest to a point (its path's distance less its
## radius there), the distance along it of the closest place, and how far the
## point is off the bark there (negative inside the wood): (branch, distance,
## gap). Only branches whose `skip` is unset. (-1, 0, INF) if none are left.
func nearest(point: Vector3, skip := PackedByteArray()) -> Vector3:
	var found := Vector3(-1.0, 0.0, INF)
	for branch in branch_count():
		if branch < skip.size() and skip[branch]:
			continue
		var on := nearest_on(branch, point)
		if on.y < found.z:
			found = Vector3(branch, on.x, on.y)
	return found


## Where `branch`'s bark is nearest a point in the skeleton's space: (the
## distance along the branch there, how far the point is from the bark,
## negative inside it).
func nearest_on(branch: int, point: Vector3) -> Vector2:
	# Compared at full precision, as nearest did, so ties at a bend go the same way.
	var best := INF
	var along := 0.0
	var first := branch_first_node[branch]
	for node in range(first, first + branch_node_count[branch] - 1):
		var closest := Geometry3D.get_closest_point_to_segment(point, positions[node], positions[node + 1])
		var span := positions[node].distance_to(positions[node + 1])
		var weight := positions[node].distance_to(closest) / span if span > 0.0 else 0.0
		var gap := point.distance_to(closest) - lerpf(radii[node], radii[node + 1], weight)
		if gap < best:
			best = gap
			along = lerpf(distances[node], distances[node + 1], weight)
	return Vector2(along, best)


## The node starting the stretch of a branch that holds a distance along it.
func _node_before(branch: int, distance: float) -> int:
	var first := branch_first_node[branch]
	var last := first + branch_node_count[branch] - 1
	assert(last > first, "A branch needs two nodes to sample.")
	var node := first
	while node < last - 1 and distances[node + 1] <= distance:
		node += 1
	return node


func _weight(node: int, distance: float) -> float:
	var span := distances[node + 1] - distances[node]
	return clampf((distance - distances[node]) / span, 0.0, 1.0) if span > 0.0 else 0.0
