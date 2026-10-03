class_name TreeMesher
extends RefCounted

## Builds a tree's mesh from its skeleton: a tube of rings along each branch,
## a cone closing each tip, and an inner-wood cap under the trunk, in one
## surface; then the leaf clusters, in a second. A branch starts on its
## parent's centre line, so its base is hidden inside the parent. A tip that is
## a cut (TreeSkeleton.branch_cut) is closed by an inner-wood cap instead of a
## cone; a piece of a tree has its own trunk, whose base is capped like any.
##
## Three detail levels come from the same skeleton, so they share a shape:
## - FULL: everything.
## - MEDIUM: half the sides, no smoothing rings, the species' thinnest branches
##   left out, and one leaf cluster in a few kept, enlarged to keep the leaf area.
## - FAR: three sides, only the thick branches, and fewer, larger clusters.
##
## Texture coordinates:
## - Bark U runs around the branch, a whole number of repeats per branch, so the
##   seam matches. The repeat count is fixed along a branch, so the texture
##   narrows with the branch instead of jumping where the count would change.
##   The sides and repeats come from the branch's natural base radius, so a piece
##   cut from a branch is laid out as the whole branch was.
## - Bark V is the distance along the branch from its natural base, scaled per
##   branch so the texture keeps its proportions on thin branches too. It never
##   restarts, so any piece of a branch keeps bark matching where it came from.
## - Caps map the whole texture onto the disc, centred on the branch axis, so
##   the inner wood's rings are centred. UV2.x is 1 on caps and 0 on bark, and
##   tree_wood.gdshader uses it to pick the texture.
## - Leaf cards map the whole texture onto each quad, placed so the texture's
##   stem (TreeSpecies.leaf_card_stem) sits on the branch.
## - Clumps project their corners along a tilted axis. Along x, y or z, pairs of
##   an icosahedron's corners would land on one spot and leave faces untextured.
##
## Leaf normals point out of the crown: the normal of the ellipsoid through the
## box the skeleton recorded around its clusters, rounded a little per corner.
## This is a common way of shading stylised foliage as one soft volume instead
## of as many flat cards; whether it reads well needs judging in the headset.
## Cards are double-sided and both sides must keep this normal, which
## tree_leaf.gdshader does (Godot otherwise flips it on back faces).

enum Level { FULL, MEDIUM, FAR }

## Length of the cone closing a branch tip, as a share of the tip's radius.
const TIP_LENGTH := 1.5
## How far each leaf corner's normal leans away from the crown's outward
## direction, toward its own direction from the cluster's centre. Below 1, so
## no normal can cancel to nothing.
const LEAF_NORMAL_ROUNDNESS := 0.6
## How far a clump's centre sits out from the branch, as a share of its radius.
const CLUMP_OFFSET := 0.6
## The crown's ellipsoid is never thinner on any axis than this share of its
## longest. Each axis weighs in by one over its half size squared, so a nearly
## flat crown would otherwise point every normal across its thin axis.
const CROWN_MIN_SHARE := 0.4
const _BARK := Vector2(0.0, 0.0)
const _INNER := Vector2(1.0, 0.0)
## Columns each of the trunk's sides is drawn in, in the notched band
## (build_band), so the notch fades smoothly from side to side.
const BAND_COLUMNS_PER_SIDE := 4
# Rings this close along a branch are taken as one.
const _SAME_DISTANCE := 0.0001
const _CARD_UVS := [Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 1.0), Vector2(0.0, 1.0)]
## A unit icosahedron's corners: (±1, ±t, 0) and its turns, normalised, where t
## is the golden ratio. 0.5257311 is 1 / sqrt(1 + t²); 0.8506508 is t times that.
const _ICOSAHEDRON_CORNERS := [
	Vector3(-0.5257311, 0.8506508, 0.0), Vector3(0.5257311, 0.8506508, 0.0),
	Vector3(-0.5257311, -0.8506508, 0.0), Vector3(0.5257311, -0.8506508, 0.0),
	Vector3(0.0, -0.5257311, 0.8506508), Vector3(0.0, 0.5257311, 0.8506508),
	Vector3(0.0, -0.5257311, -0.8506508), Vector3(0.0, 0.5257311, -0.8506508),
	Vector3(0.8506508, 0.0, -0.5257311), Vector3(0.8506508, 0.0, 0.5257311),
	Vector3(-0.8506508, 0.0, -0.5257311), Vector3(-0.8506508, 0.0, 0.5257311),
]
## Clump texture axes: across and up, seen looking along (0.3, 0.5, 0.81).
const _CLUMP_UV_ACROSS := Vector3(0.9377488, 0.0, -0.3473144)
const _CLUMP_UV_UP := Vector3(-0.1739968, 0.8654601, -0.4697914)
## A unit icosahedron's triangles, clockwise seen from outside.
const _ICOSAHEDRON_FACES := [
	0, 5, 11, 0, 1, 5, 0, 7, 1, 0, 10, 7, 0, 11, 10,
	1, 9, 5, 5, 4, 11, 11, 2, 10, 10, 6, 7, 7, 8, 1,
	3, 4, 9, 3, 2, 4, 3, 6, 2, 3, 8, 6, 3, 9, 8,
	4, 5, 9, 2, 11, 4, 6, 10, 2, 8, 7, 6, 9, 1, 8,
]


## The tree's mesh at a detail level: its wood (build_wood), then its leaves.
static func build(skeleton: TreeSkeleton, species: TreeSpecies, level := Level.FULL) -> ArrayMesh:
	var mesh := build_wood(skeleton, species, level)
	if skeleton.node_count() >= 2 and species.leaf_style != TreeSpecies.LeafStyle.NONE and skeleton.leaf_count() > 0:
		var leaves := _Surface.new(false)
		_add_leaves(leaves, skeleton, species, _Detail.new(species, level))
		_add_surface(mesh, leaves, species.leaf_material)
	return mesh


## Only the wood, at a detail level. Each branch in `gaps` (branch: an Array of
## Vector2, distances along it from x to y) is left open there, for
## build_band() to fill; each branch whose `gone` is set (broken off) is left out.
static func build_wood(skeleton: TreeSkeleton, species: TreeSpecies, level := Level.FULL,
		gaps := {}, gone := PackedByteArray()) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if skeleton.node_count() < 2:
		return mesh
	var detail := _Detail.new(species, level)
	var wood := _Surface.new(true)
	for branch in skeleton.branch_count():
		if branch < gone.size() and gone[branch]:
			continue
		if skeleton.branch_base_radius[branch] >= detail.min_branch_radius:
			_add_branch(wood, skeleton, species, branch, detail, gaps.get(branch, []))
	_add_surface(mesh, wood, species.wood_material)
	return mesh


## Only the leaves, at a detail level, leaving out each cluster whose `gone` is
## set (a felled tree's that touched something: FelledTree). Empty if none are left.
static func build_leaves(skeleton: TreeSkeleton, species: TreeSpecies, level := Level.FULL,
		gone := PackedByteArray()) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if species.leaf_style != TreeSpecies.LeafStyle.NONE and skeleton.leaf_count() > 0:
		var leaves := _Surface.new(false)
		_add_leaves(leaves, skeleton, species, _Detail.new(species, level), gone)
		_add_surface(mesh, leaves, species.leaf_material)
	return mesh


## Adds a surface if it has anything in it: the engine refuses empty ones.
static func _add_surface(mesh: ArrayMesh, surface: _Surface, material: Material) -> void:
	if surface.vertex_count() == 0:
		return
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface.arrays())
	mesh.surface_set_material(mesh.get_surface_count() - 1, material)


## Number of sides around a branch whose base has this radius.
static func sides_for(species: TreeSpecies, base_radius: float) -> int:
	var share := clampf(base_radius / species.full_sides_radius_m, 0.0, 1.0)
	return maxi(3, roundi(lerpf(species.min_sides, species.max_sides, share)))


## Sides around a branch at a detail level, its bark's repeats around it, and
## the bark's repeats along it per metre (matching those around it): from the
## branch's natural base radius.
static func _bark_layout(skeleton: TreeSkeleton, species: TreeSpecies, branch: int,
		detail: _Detail) -> Vector3:
	var base_radius := skeleton.branch_base_radius[branch]
	var sides := maxi(3, roundi(sides_for(species, base_radius) * detail.sides_scale))
	var circumference := TAU * base_radius
	var repeats := maxf(1.0, roundf(circumference / species.bark_tile_width_m))
	var v_per_m := repeats / circumference * species.bark_tile_width_m / species.bark_tile_height_m
	return Vector3(sides, repeats, v_per_m)


## A branch's tube of bark, its tip and, for a trunk, its base cap. Each of
## `gaps` (Vector2: distances along it, from x to y) is left open.
static func _add_branch(surface: _Surface, skeleton: TreeSkeleton, species: TreeSpecies,
		branch: int, detail: _Detail, gaps: Array = []) -> void:
	var level := species.level_for_depth(skeleton.branch_depth[branch])
	var ends := PackedFloat32Array()
	for gap: Vector2 in gaps:
		ends.append(gap.x)
		ends.append(gap.y)
	var rings := _ring_samples(skeleton, branch, level, detail.smooth, ends)
	for gap: Vector2 in gaps:
		rings.remove_between(gap.x, gap.y)
	var count := rings.positions.size()
	if count < 2:
		return
	var layout := _bark_layout(skeleton, species, branch, detail)
	var sides := int(layout.x)
	var repeats := layout.y
	var v_per_m := layout.z
	var first_ring := surface.vertex_count()
	for j in count:
		var v := -rings.distances[j] * v_per_m
		for k in sides + 1:
			var radial := rings.radial(j, TAU * k / sides)
			surface.add(rings.positions[j] + radial * rings.radii[j], radial,
					Vector2(repeats * k / sides, v), _BARK)
	for j in count - 1:
		if _in_gap(gaps, rings.distances[j], rings.distances[j + 1]):
			continue
		var row := first_ring + j * (sides + 1)
		var next_row := row + sides + 1
		for k in sides:
			surface.quad(row + k, next_row + k, next_row + k + 1, row + k + 1)

	var last := count - 1
	# A cut tip: inner wood, its rim on the last ring.
	if skeleton.branch_cut[branch] & TreeSkeleton.CUT_TIP:
		_add_cap(surface, rings.positions[last], rings.axes[last], rings.normals[last], rings.radii[last], sides)
	else:
		_add_tip(surface, rings, rings.axes[last], first_ring + last * (sides + 1), sides, repeats, v_per_m)

	# Base cap under the trunk, where it meets the ground (or where it was cut).
	if skeleton.branch_parent[branch] == -1:
		var across := rings.normals[0]
		_add_cap(surface, rings.positions[0], -rings.axes[0], across, rings.radii[0], sides)


## Whether the stretch from one distance to another lies in one of `gaps`.
static func _in_gap(gaps: Array, from: float, to: float) -> bool:
	for gap: Vector2 in gaps:
		if from >= gap.x - _SAME_DISTANCE and to <= gap.y + _SAME_DISTANCE:
			return true
	return false


## A band of branch that build() left open (chopping, 2026-10-02), as the full
## level would draw it, with one notch running round it. The band is a
## Dictionary: "branch", its distances along it "from" and "to", and the ring's
## "at", "openings", "depth_share" and "height_share". The notch's depth goes
## smoothly round the branch (notch_depth): through openings[k] (0 to 1) at the
## middle of the ring's side k, easing between neighbours, so a side's notch
## fades into the sides next to it (a ring of one side is cut evenly all round).
## At 1 the notch's bottom is `depth_share` of the branch's radius in from the
## bark; its mouth reaches `height_share` of its depth up and down the bark from
## the ring. Each of the mesh's sides is drawn in BAND_COLUMNS_PER_SIDE columns,
## so the fade is smooth; the notch shows inner wood, laid out as on a cap.
static func build_band(skeleton: TreeSkeleton, species: TreeSpecies, band: Dictionary) -> ArrayMesh:
	var detail := _Detail.new(species, Level.FULL)
	var branch: int = band.branch
	var rings := _ring_samples(skeleton, branch, species.level_for_depth(skeleton.branch_depth[branch]),
			detail.smooth, PackedFloat32Array([band.from, band.to]))
	var layout := _bark_layout(skeleton, species, branch, detail)
	var columns := int(layout.x) * BAND_COLUMNS_PER_SIDE
	var radius := rings.radius_at(band.at)
	var depths := PackedFloat32Array()
	for column in columns + 1:
		depths.append(notch_depth(band.openings, TAU * column / columns) * band.depth_share * radius)
	var surface := _Surface.new(true)
	_Band.new(rings, layout, band.at, radius).add(surface, band.from, band.to, depths, band.height_share)
	var mesh := ArrayMesh.new()
	_add_surface(mesh, surface, species.wood_material)
	return mesh


## How open the notch is at an angle round the trunk, from 0 to 1: each side's
## opening at its middle, eased (smoothstep) into the next side's between.
static func notch_depth(openings: PackedFloat32Array, angle: float) -> float:
	var count := openings.size()
	if count == 0:
		return 0.0
	var place := angle / TAU * count - 0.5
	var side := floori(place)
	var opening := lerpf(openings[posmod(side, count)], openings[posmod(side + 1, count)],
			smoothstep(0.0, 1.0, place - side))
	return clampf(opening, 0.0, 1.0)


## A cone closing a branch tip to a point, one apex vertex per side so each
## keeps its U.
static func _add_tip(surface: _Surface, rings: _Rings, axis: Vector3, last_row: int, sides: int,
		repeats: float, v_per_m: float) -> void:
	var last := rings.positions.size() - 1
	var tip_length := rings.radii[last] * TIP_LENGTH
	var apex := rings.positions[last] + axis * tip_length
	var apex_v := -(rings.distances[last] + tip_length) * v_per_m
	var first_apex := surface.vertex_count()
	for k in sides:
		surface.add(apex, axis, Vector2(repeats * (k + 0.5) / sides, apex_v), _BARK)
	for k in sides:
		surface.triangle(last_row + k, first_apex + k, last_row + k + 1)


## A disc facing outward along the given direction, with inner-wood texture.
## Across is any direction in the disc's plane; the texture's U runs along it.
static func _add_cap(surface: _Surface, center: Vector3, facing: Vector3, across: Vector3,
		radius: float, sides: int) -> void:
	var other := facing.cross(across)
	var middle := surface.vertex_count()
	surface.add(center, facing, Vector2(0.5, 0.5), _INNER)
	for k in sides:
		var angle := TAU * k / sides
		var offset := Vector2(cos(angle), sin(angle))
		surface.add(center + (across * offset.x + other * offset.y) * radius, facing,
				Vector2(0.5, 0.5) + offset * 0.5, _INNER)
	for k in sides:
		surface.triangle(middle, middle + 1 + (k + 1) % sides, middle + 1 + k)


## Adds the leaf clusters the detail level keeps: one in every leaf step,
## scaled by the step's square root so they cover the same area together; none
## whose `gone` is set.
static func _add_leaves(surface: _Surface, skeleton: TreeSkeleton, species: TreeSpecies,
		detail: _Detail, gone := PackedByteArray()) -> void:
	var shape_rng := RandomNumberGenerator.new()
	var enlarge := sqrt(float(detail.leaf_step))
	for i in range(0, skeleton.leaf_count(), detail.leaf_step):
		if i < gone.size() and gone[i]:
			continue
		var anchor := skeleton.leaf_anchor(i)
		var forward := skeleton.leaf_forward[i]
		var side := leaf_side(skeleton, i)
		var outward := crown_normal(skeleton, anchor)
		var size := skeleton.leaf_size[i] * enlarge
		if species.leaf_style == TreeSpecies.LeafStyle.CARDS:
			_add_card(surface, anchor, forward, side, size,
					species.leaf_card_aspect, species.leaf_card_stem, outward)
		else:
			shape_rng.seed = skeleton.leaf_seed[i]
			_add_clump(surface, anchor, forward, side, size,
					species.leaf_clump_jitter, outward, shape_rng)


## A leaf cluster's side direction: square to its forward direction, turned by
## its roll. A card's first quad spans its height along this.
static func leaf_side(skeleton: TreeSkeleton, leaf: int) -> Vector3:
	var forward := skeleton.leaf_forward[leaf]
	return TreeSkeletonBuilder.any_perpendicular(forward).rotated(forward, skeleton.leaf_roll[leaf])


## Direction out of the crown at a point: the normal of the ellipsoid through
## the box the skeleton recorded around its leaf clusters. Straight up at the
## crown's middle.
static func crown_normal(skeleton: TreeSkeleton, point: Vector3) -> Vector3:
	var offset := point - skeleton.crown_middle
	var half := skeleton.crown_half_size
	var longest := maxf(half.x, maxf(half.y, half.z))
	if offset.length_squared() < 0.00001 or longest <= 0.0:
		return Vector3.UP
	half = half.max(Vector3.ONE * longest * CROWN_MIN_SHARE)
	# An ellipsoid's normal is the offset divided by the squared half size on each axis.
	return (offset / (half * half)).normalized()


## Two quads crossing along the cluster's direction, each with the texture's
## stem on the branch and U running out along the cluster. They are seen from
## both sides, so which side is the front doesn't matter.
static func _add_card(surface: _Surface, anchor: Vector3, forward: Vector3, side: Vector3,
		size: float, aspect: float, stem: Vector2, outward: Vector3) -> void:
	var across := forward * size
	for quad in 2:
		# Toward the texture's top (V = 0), the card's full height.
		var up := side.rotated(forward, quad * PI * 0.5) * size * aspect
		var centre := anchor + across * (0.5 - stem.x) + up * (stem.y - 0.5)
		var first := surface.vertex_count()
		for uv: Vector2 in _CARD_UVS:
			var corner := anchor + across * (uv.x - stem.x) + up * (stem.y - uv.y)
			surface.add(corner, _leaf_normal(corner - centre, outward), uv)
		surface.quad(first, first + 1, first + 2, first + 3)


## A lumpy icosahedron just past the branch's end of the cluster.
static func _add_clump(surface: _Surface, anchor: Vector3, forward: Vector3, side: Vector3,
		size: float, jitter: float, outward: Vector3, rng: RandomNumberGenerator) -> void:
	var radius := size * 0.5
	var centre := anchor + forward * radius * CLUMP_OFFSET
	var turn := Basis(side, forward.cross(side), forward)
	var first := surface.vertex_count()
	for corner: Vector3 in _ICOSAHEDRON_CORNERS:
		var direction := turn * corner
		var reach := radius * (1.0 + rng.randf_range(-jitter, jitter))
		surface.add(centre + direction * reach, _leaf_normal(direction, outward),
				Vector2(0.5 + 0.5 * corner.dot(_CLUMP_UV_ACROSS), 0.5 - 0.5 * corner.dot(_CLUMP_UV_UP)))
	for f in range(0, _ICOSAHEDRON_FACES.size(), 3):
		surface.triangle(first + _ICOSAHEDRON_FACES[f], first + _ICOSAHEDRON_FACES[f + 1],
				first + _ICOSAHEDRON_FACES[f + 2])


static func _leaf_normal(offset: Vector3, outward: Vector3) -> Vector3:
	return (outward + offset.normalized() * LEAF_NORMAL_ROUNDNESS).normalized()


## The rings a branch is drawn with: its nodes, plus spline points between them
## when its level asks for a smooth mesh, plus one at each `extra` distance along
## it, between the rings either side.
static func _ring_samples(skeleton: TreeSkeleton, branch: int, level: TreeBranchLevel,
		smooth: bool, extra := PackedFloat32Array()) -> _Rings:
	var rings := _ring_samples_along(skeleton, branch, level, smooth)
	for distance in extra:
		rings.insert(distance)
	return rings


## A ring at every node, in the node's own frame (TreeSkeleton.axes, normals),
## and, when smooth, rings on a curve between each two nodes that leaves each
## node along its axis: it depends only on those two nodes, so a piece of the
## branch curves as the whole branch did, up to its cut.
static func _ring_samples_along(skeleton: TreeSkeleton, branch: int, level: TreeBranchLevel,
		smooth: bool) -> _Rings:
	skeleton.ensure_frames()
	var rings := _Rings.new()
	var first := skeleton.branch_first_node[branch]
	var count := skeleton.branch_node_count[branch]
	var between := level.smooth_subdivisions if level.smooth_mesh and smooth else 0
	for i in count:
		var node := first + i
		rings.add(skeleton.positions[node], skeleton.radii[node], skeleton.distances[node],
				skeleton.axes[node], skeleton.normals[node])
		if i == count - 1:
			break
		var next := node + 1
		var start := skeleton.positions[node]
		var end := skeleton.positions[next]
		# Hermite tangents along each node's axis, as long as the stretch.
		var chord := start.distance_to(end)
		var leaving: Vector3 = skeleton.axes[node] * chord
		var arriving: Vector3 = skeleton.axes[next] * chord
		for s in between:
			var t := float(s + 1) / (between + 1)
			var t2 := t * t
			var t3 := t2 * t
			var position := start * (2.0 * t3 - 3.0 * t2 + 1.0) + leaving * (t3 - 2.0 * t2 + t) \
					+ end * (-2.0 * t3 + 3.0 * t2) + arriving * (t3 - t2)
			var axis := (start * (6.0 * t2 - 6.0 * t) + leaving * (3.0 * t2 - 4.0 * t + 1.0)
					+ end * (-6.0 * t2 + 6.0 * t) + arriving * (3.0 * t2 - 2.0 * t)).normalized()
			rings.add(position, lerpf(skeleton.radii[node], skeleton.radii[next], t),
					lerpf(skeleton.distances[node], skeleton.distances[next], t), axis,
					TreeSkeletonBuilder.carry(skeleton.normals[node], skeleton.axes[node], axis))
	return rings


## What a detail level keeps.
class _Detail:
	var sides_scale := 1.0
	var smooth := true
	var min_branch_radius := 0.0
	var leaf_step := 1

	func _init(species: TreeSpecies, level: Level) -> void:
		match level:
			Level.MEDIUM:
				sides_scale = 0.5
				smooth = false
				min_branch_radius = species.lod_medium_min_branch_radius_m
				leaf_step = species.lod_medium_leaf_step
			Level.FAR:
				# Three sides, whatever the branch.
				sides_scale = 0.0
				smooth = false
				min_branch_radius = species.lod_far_min_branch_radius_m
				leaf_step = species.lod_far_leaf_step


class _Rings:
	var positions := PackedVector3Array()
	var radii := PackedFloat32Array()
	var distances := PackedFloat32Array()
	## Each ring's axis, the way it faces, and the normal its first side starts
	## from: carried from ring to ring without twisting, so the texture doesn't
	## spiral round a curving branch.
	var axes := PackedVector3Array()
	var normals := PackedVector3Array()

	func add(position: Vector3, radius: float, distance: float, axis: Vector3, normal: Vector3) -> void:
		positions.append(position)
		radii.append(radius)
		distances.append(distance)
		axes.append(axis)
		normals.append(normal)

	## Leaves out the rings strictly between two distances.
	func remove_between(from: float, to: float) -> void:
		for j in range(distances.size() - 1, -1, -1):
			if distances[j] > from + _SAME_DISTANCE and distances[j] < to - _SAME_DISTANCE:
				positions.remove_at(j)
				radii.remove_at(j)
				distances.remove_at(j)
				axes.remove_at(j)
				normals.remove_at(j)

	## Adds a ring at a distance between the first and last, on the straight
	## line between the rings either side, facing along it; none where one
	## already is.
	func insert(distance: float) -> void:
		for j in distances.size() - 1:
			if absf(distances[j] - distance) < _SAME_DISTANCE or absf(distances[j + 1] - distance) < _SAME_DISTANCE:
				return
			if distances[j] < distance and distance < distances[j + 1]:
				var weight := (distance - distances[j]) / (distances[j + 1] - distances[j])
				var axis := (positions[j + 1] - positions[j]).normalized()
				positions.insert(j + 1, positions[j].lerp(positions[j + 1], weight))
				radii.insert(j + 1, lerpf(radii[j], radii[j + 1], weight))
				distances.insert(j + 1, distance)
				axes.insert(j + 1, axis)
				normals.insert(j + 1, TreeSkeletonBuilder.carry(normals[j], axes[j], axis))
				return

	## The outward direction at an angle round ring j, from its normal.
	func radial(j: int, angle: float) -> Vector3:
		return normals[j] * cos(angle) + axes[j].cross(normals[j]) * sin(angle)

	## The radius at a distance between rings.
	func radius_at(distance: float) -> float:
		var j := _before(distance)
		return lerpf(radii[j], radii[j + 1], _weight(j, distance))

	## The outward direction at an angle round the branch, at a distance.
	func radial_at(distance: float, angle: float) -> Vector3:
		var frame := frame_at(distance)
		return frame.x * cos(angle) + frame.y * sin(angle)

	## The point on the bark at a distance and an angle, `inset` in from it.
	func point_at(distance: float, angle: float, inset := 0.0) -> Vector3:
		var j := _before(distance)
		var weight := _weight(j, distance)
		var centre := positions[j].lerp(positions[j + 1], weight)
		return centre + radial_at(distance, angle) * (lerpf(radii[j], radii[j + 1], weight) - inset)

	## The middle of the branch at a distance.
	func centre_at(distance: float) -> Vector3:
		var j := _before(distance)
		return positions[j].lerp(positions[j + 1], _weight(j, distance))

	## The frame at a distance: its normal, the direction a quarter turn on, and
	## its axis (as a basis's x, y and z).
	func frame_at(distance: float) -> Basis:
		var j := _before(distance)
		var weight := _weight(j, distance)
		var axis := axes[j].lerp(axes[j + 1], weight).normalized()
		var normal := normals[j].lerp(normals[j + 1], weight)
		normal = (normal - axis * normal.dot(axis)).normalized()
		return Basis(normal, axis.cross(normal), axis)

	func _before(distance: float) -> int:
		var j := 0
		while j < distances.size() - 2 and distances[j + 1] <= distance:
			j += 1
		return j

	func _weight(j: int, distance: float) -> float:
		var span := distances[j + 1] - distances[j]
		return clampf((distance - distances[j]) / span, 0.0, 1.0) if span > 0.0 else 0.0


## A band of branch build_band() draws: one surface round the branch, in
## columns. Each column, from the bottom up, is bark from the band's lower end
## to the notch's mouth, the notch's lower face in to its bottom at the ring,
## its upper face out to the mouth above, and bark on to the upper end. The
## bark lies on the trunk's flat sides; the band is short, so it runs straight
## from each end to the mouth.
class _Band:
	# Rows down each column: bark, bark (mouth), notch, notch (bottom), notch
	# (bottom), notch, bark (mouth), bark. Mouth and bottom are each two rows, so
	# the bark and the notch's two faces keep their own textures and normals.
	const _INNER_ROWS := [false, false, true, true, true, true, false, false]
	# The strips between rows: bark, the notch's lower face, its upper face, bark.
	const _STRIPS := [0, 2, 4, 6]

	var _rings: _Rings
	var _sides: int
	var _repeats: float
	var _v_per_m: float
	var _ring: float
	var _radius: float
	var _centre: Vector3
	var _frame: Basis

	func _init(rings: _Rings, layout: Vector3, ring: float, radius: float) -> void:
		_rings = rings
		_sides = int(layout.x)
		_repeats = layout.y
		_v_per_m = layout.z
		_ring = ring
		_radius = radius
		_centre = rings.centre_at(ring)
		_frame = rings.frame_at(ring)

	## The band from `from` to `to`, its notch `depths[c]` in at column c (round
	## from the normal; the last column is the first again), its mouth
	## `height_share` of that up and down the bark from the ring.
	func add(surface: _Surface, from: float, to: float, depths: PackedFloat32Array, height_share: float) -> void:
		var columns := depths.size() - 1
		var room := minf(_ring - from, to - _ring) - _SAME_DISTANCE
		var rows: Array[PackedVector3Array] = []
		var heights: Array[PackedFloat32Array] = []
		for row in _INNER_ROWS.size():
			rows.append(PackedVector3Array())
			heights.append(PackedFloat32Array())
		for column in columns + 1:
			var half := minf(depths[column] * height_share, room)
			var bottom := _inward(_bark(_ring, column, columns), depths[column])
			var at: Array[float] = [from, _ring - half, _ring - half, _ring, _ring, _ring + half, _ring + half, to]
			for row in rows.size():
				rows[row].append(bottom if row == 3 or row == 4 else _bark(at[row], column, columns))
				heights[row].append(at[row])
		var first := surface.vertex_count()
		for row in rows.size():
			for column in columns + 1:
				var position := rows[row][column]
				if _INNER_ROWS[row]:
					var offset := position - _centre
					surface.add(position, _inner_normal(rows, row, column, columns),
							Vector2(0.5, 0.5) + Vector2(offset.dot(_frame.x), offset.dot(_frame.y)) / _radius * 0.5,
							_INNER)
				else:
					surface.add(position, _bark_normal(heights[row][column], column, columns),
							Vector2(_repeats * column / columns, -heights[row][column] * _v_per_m), _BARK)
		for row: int in _STRIPS:
			var lower := first + row * (columns + 1)
			var upper := lower + columns + 1
			for column in columns:
				surface.quad(lower + column, upper + column, upper + column + 1, lower + column + 1)

	# The point on the bark at a distance, at a column: on the trunk's flat side
	# between the corners either side, as _add_branch's rings lay it.
	func _bark(distance: float, column: int, columns: int) -> Vector3:
		var place := float(column) * _sides / columns
		var side := mini(floori(place), _sides - 1)
		return _rings.point_at(distance, TAU * side / _sides).lerp(
				_rings.point_at(distance, TAU * (side + 1) / _sides), place - side)

	func _bark_normal(distance: float, column: int, columns: int) -> Vector3:
		var place := float(column) * _sides / columns
		var side := mini(floori(place), _sides - 1)
		return _rings.radial_at(distance, TAU * side / _sides).lerp(
				_rings.radial_at(distance, TAU * (side + 1) / _sides), place - side).normalized()

	# A point `depth` in from the bark, toward the trunk's middle.
	func _inward(point: Vector3, depth: float) -> Vector3:
		var offset := point - _centre
		var across := offset - _frame.z * offset.dot(_frame.z)
		return point - across.normalized() * minf(depth, across.length() * 0.95)

	# A notch face's normal at a vertex, seen from the notch: square to its slope
	# (from the strip's lower row to its upper) and to the way round the trunk.
	func _inner_normal(rows: Array[PackedVector3Array], row: int, column: int, columns: int) -> Vector3:
		var low := row - row % 2
		var slope := rows[low + 1][column] - rows[low][column]
		var around := rows[row][mini(column + 1, columns)] - rows[row][maxi(column - 1, 0)]
		if column == 0 or column == columns:
			around = rows[row][1] - rows[row][columns - 1]
		var normal := -slope.cross(around)
		if normal.length_squared() < 1e-12:
			return _bark_normal(_ring, column, columns)
		return normal.normalized()


class _Surface:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var indices := PackedInt32Array()
	var _uses_uv2: bool

	## Only the wood needs UV2, to tell bark from inner wood.
	func _init(uses_uv2: bool) -> void:
		_uses_uv2 = uses_uv2

	func vertex_count() -> int:
		return vertices.size()

	func add(vertex: Vector3, normal: Vector3, uv: Vector2, uv2 := Vector2.ZERO) -> void:
		vertices.append(vertex)
		normals.append(normal)
		uvs.append(uv)
		if _uses_uv2:
			uv2s.append(uv2)

	## Godot treats clockwise triangles as front faces.
	func triangle(a: int, b: int, c: int) -> void:
		# One at a time: an array literal here would allocate on every call.
		indices.append(a)
		indices.append(b)
		indices.append(c)

	func quad(a: int, b: int, c: int, d: int) -> void:
		triangle(a, b, c)
		triangle(a, c, d)

	func arrays() -> Array:
		var result := []
		result.resize(Mesh.ARRAY_MAX)
		result[Mesh.ARRAY_VERTEX] = vertices
		result[Mesh.ARRAY_NORMAL] = normals
		result[Mesh.ARRAY_TEX_UV] = uvs
		if _uses_uv2:
			result[Mesh.ARRAY_TEX_UV2] = uv2s
		result[Mesh.ARRAY_INDEX] = indices
		return result
