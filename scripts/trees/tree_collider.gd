class_name TreeCollider
extends RefCounted

## Works out a tree's collision shapes from its skeleton.
##
## Wood: capsules, the cheapest shape to collide with, along each branch thick
## enough to be solid. A capsule runs from node to node while the path stays
## within a tolerance of its axis and the radius changes by no more than a
## tolerance, so straight, even stretches take one capsule, and bends and
## steep tapers take more, only where they are. Where a branch thins below the
## species' minimum radius its collision stops, so twigs pass through. The
## stretch at a cut end (TreeSkeleton.branch_cut) is a cylinder instead, flat
## at the cut: a capsule's rounded end would reach past it, into the other piece.
##
## Leaves: one box around each card cluster's two quads, or a sphere for each
## clump, meant for a touch-only area rather than a solid body. Bare twigs
## (twigs()) get touch volumes too.
##
## Takes a skeleton, not a node, so it works on any skeleton the mesher does.

## The least thickness of a bare twig's touch volume, in metres.
const TWIG_TOUCH_RADIUS := 0.03


## Shapes with their transforms in the tree's space, and the part of the
## skeleton each stands for: its branch (wood, twigs) or its leaf cluster (leaves).
class Shapes:
	var shapes: Array[Shape3D] = []
	var transforms: Array[Transform3D] = []
	var parts := PackedInt32Array()

	func size() -> int:
		return shapes.size()

	func add(shape: Shape3D, transform: Transform3D, part := -1) -> void:
		shapes.append(shape)
		transforms.append(transform)
		parts.append(part)

	## Adds every shape to a collision object, one shape owner each: no nodes.
	## Returns the owners, in the shapes' order.
	func apply_to(object: CollisionObject3D) -> PackedInt32Array:
		var owners := PackedInt32Array()
		for i in shapes.size():
			var owner_id := object.create_shape_owner(object)
			object.shape_owner_add_shape(owner_id, shapes[i])
			object.shape_owner_set_transform(owner_id, transforms[i])
			owners.append(owner_id)
		return owners

	## These shapes placed by a transform that may scale them evenly, with the
	## scale built into copies of the shapes: a rigid body's shapes take no scale.
	func baked(placement: Transform3D) -> Shapes:
		var scale := placement.basis.get_scale().x
		var turn := Transform3D(placement.basis.orthonormalized(), placement.origin)
		var result := Shapes.new()
		for i in shapes.size():
			var shape := shapes[i].duplicate() as Shape3D
			if shape is CapsuleShape3D:
				(shape as CapsuleShape3D).radius *= scale
				(shape as CapsuleShape3D).height *= scale
			elif shape is CylinderShape3D:
				(shape as CylinderShape3D).radius *= scale
				(shape as CylinderShape3D).height *= scale
			elif shape is SphereShape3D:
				(shape as SphereShape3D).radius *= scale
			elif shape is BoxShape3D:
				(shape as BoxShape3D).size *= scale
			result.add(shape, turn * Transform3D(transforms[i].basis, transforms[i].origin * scale), parts[i])
		return result


static func wood(skeleton: TreeSkeleton, species: TreeSpecies) -> Shapes:
	var result := Shapes.new()
	for branch in skeleton.branch_count():
		var samples := _solid_samples(skeleton, species, branch)
		var last := samples.positions.size() - 1
		var cut := skeleton.branch_cut[branch]
		# A cut tip only ends the samples if the branch is still solid there.
		var tip_is_cut := cut & TreeSkeleton.CUT_TIP and last >= 0 \
				and samples.positions[last].is_equal_approx(
						skeleton.positions[skeleton.branch_first_node[branch] + skeleton.branch_node_count[branch] - 1])
		# A shape at a cut end keeps to the stretch next to the cut, which is
		# square to it (a branch never turns at a segment line), so it meets the
		# other piece's shape flat instead of overlapping it.
		var base_stretch_end := samples.nodes[1] if samples.nodes.size() > 1 else last
		var tip_stretch_start := samples.nodes[-2] if tip_is_cut and samples.nodes.size() > 1 else 0
		var start := 0
		while start < last:
			var end := start + 1
			var limit := last
			if start == 0 and cut & TreeSkeleton.CUT_BASE:
				limit = mini(limit, base_stretch_end)
			if start < tip_stretch_start:
				limit = mini(limit, tip_stretch_start)
			while end < limit and _fits(samples, species, start, end + 1):
				end += 1
			var flat := (start == 0 and cut & TreeSkeleton.CUT_BASE) or (end == last and tip_is_cut) \
					or _reaches_past_cut(skeleton, branch, samples, start, end, tip_is_cut)
			_add_capsule(result, samples, start, end, flat, branch)
			start = end
	return result


## Touch volumes for bare twigs (2026-10-02): twigs (TreeSkeleton.is_twig,
## branches with no segment line on wood to chop) carry their leaves' touch volumes,
## which stand for them; one with no leaves of its own gets a capsule along each
## stretch too thin to be solid wood, at least TWIG_TOUCH_RADIUS thick, so it
## can be broken as leaves are.
static func twigs(skeleton: TreeSkeleton, species: TreeSpecies) -> Shapes:
	var result := Shapes.new()
	var leafy := {}
	for leaf in skeleton.leaf_count():
		leafy[skeleton.leaf_branch[leaf]] = true
	for branch in skeleton.branch_count():
		if leafy.has(branch) or not skeleton.is_twig(branch, species.collision_min_radius_m):
			continue
		var first := skeleton.branch_first_node[branch]
		for node in range(first, first + skeleton.branch_node_count[branch] - 1):
			if skeleton.radii[node + 1] >= species.collision_min_radius_m:
				continue
			var a := skeleton.positions[node]
			var b := skeleton.positions[node + 1]
			var capsule := CapsuleShape3D.new()
			capsule.radius = maxf(skeleton.radii[node], TWIG_TOUCH_RADIUS)
			capsule.height = a.distance_to(b) + capsule.radius * 2.0
			result.add(capsule, Transform3D(_along(b - a), (a + b) * 0.5), branch)
	return result


static func leaves(skeleton: TreeSkeleton, species: TreeSpecies) -> Shapes:
	var result := Shapes.new()
	if species.leaf_style == TreeSpecies.LeafStyle.NONE:
		return result
	for i in skeleton.leaf_count():
		var anchor := skeleton.leaf_anchor(i)
		var forward := skeleton.leaf_forward[i]
		var size := skeleton.leaf_size[i]
		if species.leaf_style == TreeSpecies.LeafStyle.CARDS:
			# Bounds TreeMesher._add_card's two quads: both span U along forward,
			# one spans V along side, the other along forward × side.
			var side := TreeMesher.leaf_side(skeleton, i)
			var across := forward.cross(side)
			var stem := species.leaf_card_stem
			var height := size * species.leaf_card_aspect
			var centre := anchor + forward * size * (0.5 - stem.x) \
					+ (side + across) * height * (stem.y - 0.5)
			var box := BoxShape3D.new()
			box.size = Vector3(size, height, height)
			result.add(box, Transform3D(Basis(forward, side, across), centre), i)
		else:
			var sphere := SphereShape3D.new()
			sphere.radius = size * 0.5
			result.add(sphere, Transform3D(Basis.IDENTITY,
					anchor + forward * sphere.radius * TreeMesher.CLUMP_OFFSET), i)
	return result


## Lines outlining every shape, in one mesh: wood in one colour, leaves in
## another. For looking at collision in the editor; not used in the game.
static func debug_mesh(wood_shapes: Shapes, leaf_shapes: Shapes) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	for entry in [[wood_shapes, Color(1.0, 0.55, 0.1)], [leaf_shapes, Color(0.3, 1.0, 0.4)]]:
		var shapes: Shapes = entry[0]
		for i in shapes.size():
			var lines: PackedVector3Array = shapes.shapes[i].get_debug_mesh() \
					.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			for point in lines:
				vertices.append(shapes.transforms[i] * point)
				colors.append(entry[1])
	var mesh := ArrayMesh.new()
	if vertices.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.no_depth_test = true
	mesh.surface_set_material(0, material)
	return mesh


## The points a branch's capsules are fitted through: its nodes from the base
## up to where it thins to the minimum radius (a point between two nodes), plus
## points between nodes wherever the radius changes by more than the radius
## tolerance, so no capsule has to span more change than that.
static func _solid_samples(skeleton: TreeSkeleton, species: TreeSpecies, branch: int) -> _Samples:
	var samples := _Samples.new()
	var first := skeleton.branch_first_node[branch]
	var minimum := species.collision_min_radius_m
	if skeleton.radii[first] < minimum:
		return samples
	samples.add(skeleton.positions[first], skeleton.radii[first], true)
	for node in range(first + 1, first + skeleton.branch_node_count[branch]):
		var from := skeleton.positions[node - 1]
		var from_radius := skeleton.radii[node - 1]
		var to := skeleton.positions[node]
		var to_radius := skeleton.radii[node]
		var thins_out := to_radius < minimum
		if thins_out:
			# Stop exactly where the radius reaches the minimum.
			var weight := (from_radius - minimum) / (from_radius - to_radius)
			to = from.lerp(to, weight)
			to_radius = minimum
		var pieces := maxi(1, ceili(absf(to_radius - from_radius) / species.collision_radius_tolerance_m))
		for piece in range(1, pieces + 1):
			var weight := float(piece) / pieces
			samples.add(from.lerp(to, weight), lerpf(from_radius, to_radius, weight),
					piece == pieces and not thins_out)
		if thins_out:
			break
	# A branch that thins out right at its base has nothing to be solid.
	if samples.positions.size() >= 2 and samples.positions[-1].is_equal_approx(samples.positions[-2]):
		samples.positions.resize(samples.positions.size() - 1)
		samples.radii.resize(samples.radii.size() - 1)
	return samples


## Whether a capsule from sample start to sample end would reach, with its
## rounded ends, through a cut end of its branch into the other piece: on thick
## wood a stretch is shorter than the radius, so one near a cut does. Such a
## shape is made a cylinder instead.
static func _reaches_past_cut(skeleton: TreeSkeleton, branch: int, samples: _Samples, start: int,
		end: int, tip_is_cut: bool) -> bool:
	var radius := 0.0
	for i in range(start, end + 1):
		radius = maxf(radius, samples.radii[i])
	var first := skeleton.branch_first_node[branch]
	var last := first + skeleton.branch_node_count[branch] - 1
	skeleton.ensure_frames()
	for end_node in [first, last]:
		var is_cut: bool = skeleton.branch_cut[branch] & TreeSkeleton.CUT_BASE != 0 if end_node == first else tip_is_cut
		if not is_cut:
			continue
		# Out of the piece, through its cut face.
		var out: Vector3 = -skeleton.axes[end_node] if end_node == first else skeleton.axes[end_node]
		for i in [start, end]:
			if (samples.positions[i] - skeleton.positions[end_node]).dot(out) + radius > 0.001:
				return true
	return false


## Whether one capsule from sample start to sample end stays close to the
## branch: every sample between within the tolerance of its axis, and the
## radius changing by no more than the radius tolerance along it.
static func _fits(samples: _Samples, species: TreeSpecies, start: int, end: int) -> bool:
	var a := samples.positions[start]
	var b := samples.positions[end]
	var thinnest := INF
	var thickest := 0.0
	for i in range(start, end + 1):
		thinnest = minf(thinnest, samples.radii[i])
		thickest = maxf(thickest, samples.radii[i])
		var point := samples.positions[i]
		if point.distance_to(Geometry3D.get_closest_point_to_segment(point, a, b)) \
				> species.collision_tolerance_m:
			return false
	return thickest - thinnest <= species.collision_radius_tolerance_m


## A capsule along the branch from sample start to sample end, as thick as the
## middle of the radii along it, so it is never more than half the radius
## tolerance too thick or too thin; or, if `flat`, a cylinder ending at both.
## It stands for `branch`.
static func _add_capsule(shapes: Shapes, samples: _Samples, start: int, end: int, flat: bool,
		branch: int) -> void:
	var thinnest := INF
	var thickest := 0.0
	for i in range(start, end + 1):
		thinnest = minf(thinnest, samples.radii[i])
		thickest = maxf(thickest, samples.radii[i])
	var a := samples.positions[start]
	var b := samples.positions[end]
	var radius := (thinnest + thickest) * 0.5
	var shape: Shape3D
	if flat:
		var cylinder := CylinderShape3D.new()
		cylinder.radius = radius
		cylinder.height = a.distance_to(b)
		shape = cylinder
	else:
		var capsule := CapsuleShape3D.new()
		capsule.radius = radius
		# A capsule's height includes its two rounded ends.
		capsule.height = a.distance_to(b) + radius * 2.0
		shape = capsule
	shapes.add(shape, Transform3D(_along(b - a), (a + b) * 0.5), branch)


## A basis turning a shape's Y (a capsule's or cylinder's length) along `way`.
static func _along(way: Vector3) -> Basis:
	var axis := way.normalized()
	return Basis(Quaternion(Vector3.UP, axis)) if axis.dot(Vector3.UP) > -0.9999 else Basis(Vector3.RIGHT, PI)


class _Samples:
	var positions := PackedVector3Array()
	var radii := PackedFloat32Array()
	## Which samples are the branch's nodes, in order.
	var nodes := PackedInt32Array()

	func add(position: Vector3, radius: float, node := false) -> void:
		if node:
			nodes.append(positions.size())
		positions.append(position)
		radii.append(radius)
