extends SceneTree

## Checks chopping at segment lines (2026-10-02, checkpoint 1b) headlessly. A
## tree that takes strikes is struck through its wood body, also once its
## collision is rebuilt as it streams. Every segment line on wood thick enough to
## hit chops the same way, standing or felled: a slash opens the side of the line
## it lands on by its damage, and on a trunk line the sides either side by spill,
## each up to its cap, the sides numbered round the node frame the notch is drawn
## in; it counts on the line being chopped while near it, else on the nearest
## line within band that can be chopped; what a line takes scales with the wood's
## cross-section. Through, TreeChop cuts the tree there itself: the skeleton
## splits, the pieces' bark and collision meeting at the line; a standing tree's
## trunk line tips the part above over, hinged to its stump, any other line lets
## the part beyond fall, and each piece chops on with the lines it carries. A
## line a limb's junction crosses can't be chopped; twigs (branches with no line
## that is wood, however deep) and leaf clusters break off whole. A piece left
## with no line that can be chopped is lone (checkpoint 1c; a standing tree only
## once its trunk is cut): it shows its health, 50 for trunk and 10 for a branch,
## which every slash on it takes, and at 0 is gone (the stump with its tree),
## waking what rests on it and dropping 3 logs a segment of trunk or a stick a
## segment of branch round its middle; a lone felled piece damps its spin against
## rolling by lone_angular_damp (2026-10-03). Every piece cut off weighs its segments
## of wood, 75 kg a segment of trunk and 25 kg of any other branch, a twig
## nothing, and is weighed again as it is cut; a log weighs 8 kg and a stick
## 2.5 kg, both damped against rolling. A felled piece's branch that hits
## something solid at impact_speed or faster breaks at its line nearest the hit,
## as if chopped through (fall damage, 2026-10-03), one such cut a tick across
## every tree; a part cut off a moving piece moves on as it was. The strikes are
## fed to the tree's Strikeable as a Striker would; the striking and the falls
## are measured in tests/harness/run_scenarios.gd.
##
##   godot --headless --xr-mode off --path . -s tests/trees/test_tree_chop.gd

const SPECIES := "res://assets/vegetation/trees/angular_oak.tres"
## Its thin upper limbs have no line that is wood: twigs, off the trunk.
const PINE := "res://assets/vegetation/trees/straight_pine.tres"
## It grows bare twigs: limbs with no line that is wood and no leaves of their own.
const BIRCH := "res://assets/vegetation/trees/curvy_birch.tres"
const WOOD := "res://assets/strike/wood.tres"
const LEVEL := "res://scenes/level.tscn"
## What a lone piece drops: logs from trunk, sticks from a branch.
const LOG := "res://scenes/props/wood/log.tscn"
const STICK := "res://scenes/props/wood/stick.tscn"
## The oak whose trunk leans past where any_perpendicular changes the direction
## it measures from: the node frames, carried up its trunk, are turned about 80°
## from it at lines 3 to 6.
const LEANING_SEED := 4
## The oak with a trunk line a limb's junction crosses: line 4 (2.00 m up),
## crossed by limb 1's junction (1.99 to 2.50 m).
const BLOCKED_SEED := 3
## Every check the suite makes. Update it when adding or removing a check.
const EXPECTED_CHECKS := 155
# What breaks a tree's leaves: hands, held items, props and enemies.
const _BREAKERS := ProceduralTree.DYNAMIC_LAYER | ProceduralTree.HELD_LAYER | ProceduralTree.HANDS_LAYER \
		| ProceduralTree.ENEMY_LAYER
# A strike judged on any side of its line (_judged).
const _ANY_SIDE := -2

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


func _initialize() -> void:
	await _test_tree_is_struck_through_its_wood()
	await _test_unchoppable_trunk()
	await _test_sides()
	await _test_opening()
	await _test_snapping()
	await _test_damage_scaling()
	await _test_side_caps()
	await _test_wood_lines()
	_test_split()
	_test_cut_pieces()
	await _test_notches()
	await _test_fall_direction()
	await _test_felling()
	await _test_high_cut()
	await _test_branch_lines()
	await _test_bucking()
	await _test_blocked_lines()
	await _test_twigs()
	await _test_limb_twigs()
	await _test_breaking_leaves()
	await _test_bare_twigs()
	await _test_verdicts()
	await _test_display()
	await _test_lone_pieces()
	await _test_lone_blocked()
	await _test_lone_stub()
	await _test_lone_health()
	await _test_lone_readout()
	await _test_lone_breaking()
	await _test_lone_twigs()
	await _test_lone_wakes()
	_test_segment_masses()
	_test_piece_segments()
	await _test_piece_weights()
	await _test_thin_piece_weight()
	_test_loot_weights()
	await _test_impacts()
	await _test_impact_breaks()
	await _test_shape_branches()
	await _test_velocity_handoff()
	await _test_drops()
	_test_level_wiring()
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


## A tree as the level sets one up: a Strikeable of wood, a TreeChop and its
## readout on it. The oak, unless another species is given.
func _add_tree(tree_seed := 0, species: TreeSpecies = null) -> TreeChop:
	var tree := ProceduralTree.new()
	tree.species = species if species else load(SPECIES)
	tree.tree_seed = tree_seed
	var strikeable := Strikeable.new()
	strikeable.material = load(WOOD)
	var chop := TreeChop.new()
	chop.strikeable = strikeable
	var display := TreeChopDisplay.new()
	display.chop = chop
	tree.add_child(strikeable)
	tree.add_child(chop)
	tree.add_child(display)
	root.add_child(tree)
	await process_frame
	return chop


## A strike of `kind` at `point` doing `damage` (0: one too weak to do any), as a
## Striker would deliver it.
func _strike(chop: TreeChop, kind: Strike.Kind, point: Vector3, damage: int, speed := 4.0) -> Strike:
	var strike := Strike.new()
	strike.kind = kind
	strike.point = point
	strike.speed = speed
	var material := chop.strikeable.material
	if damage <= 0:
		strike.energy = material.threshold_of(kind) * 0.5
	else:
		var share := (damage - Strike.MIN_DAMAGE) / float(Strike.MAX_DAMAGE - Strike.MIN_DAMAGE)
		strike.energy = lerpf(material.threshold_of(kind), material.full_energy_of(kind), share)
	chop.strikeable.receive(strike)
	return strike


## Whether `strike` was judged `outcome` on a branch of `depth`, at `line` (the
## one it counted on, or the nearest), on `side` (_ANY_SIDE: any), `offset`
## metres along the branch from the line (NAN: anywhere).
static func _judged(strike: Strike, outcome: TreeChop.Outcome, depth: int, line: int, side: int,
		offset := NAN) -> bool:
	var judged := strike.judged
	if judged.size() != 5:
		return false
	var on_side: bool = judged.side >= 0 if side == _ANY_SIDE else judged.side == side
	return judged.outcome == outcome and judged.depth == depth and judged.line == line and on_side \
			and (is_nan(offset) or absf(judged.offset - offset) < 0.005)


## A point on the bark at the middle of `line`'s side, in the world.
func _on_side(chop: TreeChop, line: TreeChop.Line, side: int) -> Vector3:
	return chop.centre(line) + chop.side_direction(line, side) * chop.radius(line)


## A point on `branch`'s bark `distance` along it, in the world, where a strike
## finds that branch (TreeSkeleton.nearest) as near `distance` along it as it
## can be found: tried round it, from the middle of a side of its node frame
## on. Vector3.INF if a strike finds that branch nowhere round it within 6 cm.
func _bark_point(chop: TreeChop, branch: int, distance: float) -> Vector3:
	var tree := chop.tree
	var skeleton := tree.skeleton
	var frame := skeleton.sample_frame(branch, distance)
	var centre := skeleton.sample_position(branch, distance)
	var radius := skeleton.sample_radius(branch, distance)
	var best := Vector3.INF
	var off := 0.06
	for step in 16:
		var local := centre + frame[1].rotated(frame[0], (step + 0.5) * TAU / 16) * radius
		var found := skeleton.nearest(local, tree.gone_branches())
		if int(found.x) == branch and absf(found.y - distance) < off:
			off = absf(found.y - distance)
			best = tree.skeleton_transform() * local
	return best


## How far along its branch a strike at `point` (in the world) lands, as the
## tree finds it (TreeSkeleton.nearest).
static func _found_along(chop: TreeChop, point: Vector3) -> float:
	var tree := chop.tree
	return tree.skeleton.nearest(tree.skeleton_transform().affine_inverse() * point, tree.gone_branches()).y


## Openings that cut `line` through: its sides opened in turn, each up to its
## cap, until the total.
static func _through(line: TreeChop.Line) -> PackedInt32Array:
	var openings := PackedInt32Array()
	var left := line.total
	for side in line.depths.size():
		var depth := mini(left, line.cap)
		openings.append(depth)
		left -= depth
	return openings


## Openings one short of cutting `line` through, its last two sides shut.
static func _one_short(line: TreeChop.Line) -> PackedInt32Array:
	var openings := PackedInt32Array()
	var left := line.total - 1
	for side in line.depths.size():
		var depth := mini(left, line.cap) if side < line.depths.size() - 2 else 0
		openings.append(depth)
		left -= depth
	return openings


## What a line `k` along `branch` takes to cut through, by the rule
## (2026-10-02): max(10, round(300·(r / r₁)²)), r₁ the trunk's at its first line.
static func _formula(skeleton: TreeSkeleton, branch: int, k: int) -> int:
	var share := skeleton.sample_radius(branch, k * skeleton.segment_length) / skeleton.first_line_radius
	return maxi(10, roundi(300.0 * share * share))


## The first line along `branch` that can be chopped, or -1.
static func _first_choppable(chop: TreeChop, branch: int) -> int:
	var span := chop.tree.skeleton.line_range(branch)
	for k in range(span.x, span.y + 1):
		if chop.choppable(branch, k):
			return k
	return -1


## How much is open on all of `chop`'s lines: every side's depth, summed here,
## not Line.open, which only an opening works out again.
static func _open_total(chop: TreeChop) -> int:
	var open := 0
	for line: TreeChop.Line in chop.lines.values():
		for depth in line.depths:
			open += depth
	return open


## What `chop` reports felling, as [distance, toward, the length of the tree's
## trunk then] each.
static func _fells_of(chop: TreeChop) -> Array:
	var fells := []
	chop.felled.connect(func(distance: float, toward: Vector3) -> void:
			fells.append([distance, toward, chop.tree.skeleton.branch_length(0)]))
	return fells


## The pieces cut off `tree`, as they come.
static func _pieces_of(tree: ProceduralTree) -> Array[FelledTree]:
	var pieces: Array[FelledTree] = []
	tree.severed.connect(func(piece: FelledTree) -> void: pieces.append(piece))
	return pieces


## The readout of `chop`: the TreeChopDisplay beside it on its tree.
static func _display_of(chop: TreeChop) -> TreeChopDisplay:
	if chop == null or chop.tree == null:
		return null
	for child in chop.tree.get_children():
		if child is TreeChopDisplay and (child as TreeChopDisplay).chop == chop:
			return child
	return null


## Whether `piece` is hinged to `stump`, about a level axis square to `toward`.
static func _hinged(piece: FelledTree, stump: PhysicsBody3D, toward: Vector3) -> bool:
	var hinge := piece._hinge
	return hinge != null and hinge.get_node(hinge.node_a) == piece and hinge.get_node(hinge.node_b) == stump \
			and absf(hinge.global_basis.z.dot(Vector3.UP)) < 0.001 and absf(hinge.global_basis.z.dot(toward)) < 0.001


func _test_tree_is_struck_through_its_wood() -> void:
	var errors := _ErrorCounter.new()
	OS.add_logger(errors)
	var chop := await _add_tree()
	var first_body: StaticBody3D = chop.tree._wood_body
	_check(first_body != null and Strikeable.of(first_body) == chop.strikeable,
			"the tree's wood body is struck as the tree")
	chop.tree.collision_active = false
	chop.tree.collision_active = true
	await process_frame
	var second_body: StaticBody3D = chop.tree._wood_body
	_check(second_body != null and second_body != first_body and Strikeable.of(second_body) == chop.strikeable,
			"its collision rebuilt (as it streams in again), the new wood body is struck as the tree too")
	OS.remove_logger(errors)
	_check(errors.count == 0, "no errors: the tree builds its body after its Strikeable looked (%d)" % errors.count)
	chop.tree.free()


## A tree with a TreeChop is its own from the start whatever its trunk's first
## line is (make_own at ready): one with no line to chop at all still has its
## leaves watch what breaks them. A standing tree is lone only once its trunk is
## cut (checkpoint 1c, 2026-10-02 review: the root "wont move but if the segment
## above the first root segment is chopped"), so one with nothing to chop stays
## whole; cut through all the same, its stump is lone.
func _test_unchoppable_trunk() -> void:
	var species := _sapling()
	var chop := await _add_tree(0, species)
	var tree := chop.tree
	# A frame more, past the look TreeChop takes at the end of its first.
	await process_frame
	var span := tree.skeleton.line_range(0)
	var choppable := 0
	for k in range(span.x, span.y + 1):
		if chop.choppable(0, k):
			choppable += 1
	var display := _display_of(chop)
	_check(span.y >= span.x and choppable == 0 and tree.own and chop.current == null and chop.lines.is_empty()
			and not (tree.skeleton.branch_cut[0] & TreeSkeleton.CUT_TIP) and not chop.is_lone() and chop.health == null
			and tree.get_node_or_null(^"Health") == null and display != null and not display.visible
			and tree.leaves_left() > 0 and tree._foliage != null and tree._foliage.monitoring
			and tree._foliage.collision_mask == _BREAKERS,
			"a sapling whose trunk, %.3f m in radius, is too thin to chop at any of its %d lines (wood is %.3f m): its own all the same, no line being chopped, the readout hidden, and its %d leaf clusters watch what breaks them; its trunk uncut, it stays whole, not lone: no health, two frames on"
			% [species.trunk.base_radius_m, span.y - span.x + 1, species.collision_min_radius_m, tree.leaves_left()])
	var pieces := _pieces_of(tree)
	var segment := tree.skeleton.segment_length
	tree.sever(0, segment)
	var health := chop.health
	var shown: HealthDisplay = display._health if display else null
	_check(tree.skeleton.branch_cut[0] & TreeSkeleton.CUT_TIP and chop.is_lone() and health != null
			and health.get_parent() == tree and health.maximum == 50 and display.visible and shown != null
			and shown.text == "50 / 50",
			"cut through its trunk all the same at line 1, %.2f m up (ProceduralTree.sever, as nothing can chop it), its stump is lone at once: a Health of %d on the tree, its readout showing it ('%s')"
			% [segment, health.maximum if health else -1, shown.text if shown else ""])
	_free_all(pieces + [tree])


## A species whose trunk is thinner than wood to chop (collision_min_radius_m)
## all the way up, topped with leaves.
static func _sapling() -> TreeSpecies:
	var trunk := TreeBranchLevel.new()
	trunk.segments_min = 4
	trunk.segments_max = 4
	trunk.base_radius_m = 0.02
	trunk.tip_leaves = 3
	var species := TreeSpecies.new()
	species.trunk = trunk
	species.leaf_style = TreeSpecies.LeafStyle.CARDS
	return species


## A trunk line's sides are numbered round it from the node frame its notch is
## drawn in (TreeSkeleton.sample_frame, carried up the tree from its base), so
## a side's number and its notch agree however the trunk leans.
func _test_sides() -> void:
	var chop := await _add_tree()
	var found := _sides_found(chop, chop.line_at(0, 1))
	_check(found == PackedInt32Array(range(8)),
			"trunk line 1: the bark at each side's middle is on that side, in turn round the trunk: %s" % found)
	chop.tree.free()
	chop = await _add_tree(LEANING_SEED)
	var tree := chop.tree
	var skeleton := tree.skeleton
	# The line above the first whose frame is turned most from any_perpendicular's.
	var high := -1
	var turn := 0.0
	var span := skeleton.line_range(0)
	for k in range(span.x + 1, span.y + 1):
		var frame := skeleton.sample_frame(0, k * skeleton.segment_length)
		var angle := frame[1].angle_to(TreeSkeletonBuilder.any_perpendicular(frame[0]))
		if chop.choppable(0, k) and angle > turn + 0.001:
			high = k
			turn = angle
	var line := chop.line_at(0, high) if high >= 0 else null
	found = _sides_found(chop, line)
	_check(line != null and found == PackedInt32Array(range(8)),
			"trunk line %d of the leaning oak (seed %d), %.2f m up: the same, %s"
			% [high, LEANING_SEED, high * skeleton.segment_length, found])
	# Each side opened alone: the notch drawn is deepest at that side's middle.
	var worst := INF
	if line:
		worst = 0.0
		for side in line.depths.size():
			var openings := PackedInt32Array()
			openings.resize(line.depths.size())
			openings[side] = int(line.cap * 0.5)
			chop.preset(0, high, openings)
			tree._redraw()
			worst = maxf(worst, _deepest_notch(chop, line).angle_to(chop.side_direction(line, side)))
	_check(turn > deg_to_rad(10.0) and worst < 0.01,
			"there the node frame, carried up the leaning trunk, is turned %.1f° from what any_perpendicular gives; each side's notch, opened alone, is still drawn deepest at that side's middle (within %.2f°)"
			% [rad_to_deg(turn), rad_to_deg(worst)])
	tree.free()


## The side of `line` the bark at each side's middle is found on.
func _sides_found(chop: TreeChop, line: TreeChop.Line) -> PackedInt32Array:
	var found := PackedInt32Array()
	if line != null:
		for side in line.depths.size():
			found.append(chop.side_at(line, _on_side(chop, line, side)))
	return found


## The way out from the branch, in the world, to the deepest point of `line`'s
## notch as drawn.
func _deepest_notch(chop: TreeChop, line: TreeChop.Line) -> Vector3:
	var tree := chop.tree
	var branch := tree.skeleton.branch_with_id(line.id)
	var ring: Dictionary = tree._rings.get(Vector2i(branch, line.k), {})
	if ring.is_empty() or ring.instance.mesh == null:
		return Vector3.ZERO
	var axis := tree.skeleton.sample_frame(branch, line.at)[0]
	var centre := tree.skeleton.sample_position(branch, line.at)
	var nearest := INF
	var way := Vector3.ZERO
	for vertex: Array in _inner_wood(ring.instance.mesh):
		var offset: Vector3 = vertex[0] - centre
		var across := offset - axis * offset.dot(axis)
		if across.length() < nearest:
			nearest = across.length()
			way = across
	return (tree.skeleton_transform().basis * way).normalized()


## Slashes on trunk line 1 open the side they land on by their damage and the
## sides either side by spill, each up to the cap; a full side, a blunt strike
## and a slash too weak to do damage open nothing.
func _test_opening() -> void:
	var chop := await _add_tree()
	var line := chop.current
	var spill := roundi(Strike.MAX_DAMAGE * chop.spill_share)
	var went := PackedInt32Array()
	var counted := true
	for blow in 5:
		var strike := _strike(chop, Strike.Kind.SLASH, _on_side(chop, line, 2), Strike.MAX_DAMAGE)
		counted = counted and _judged(strike, TreeChop.Outcome.COUNTED, 0, 1, 2, 0.0)
		went.append(line.depths[2])
	_check(went == PackedInt32Array([10, 20, 30, 40, 50]) and line.depths[2] == line.cap and counted,
			"five full-strength slashes on side 2 of line 1, each COUNTED there, open it to its cap: %s" % went)
	_check(line.depths[1] == 5 * spill and line.depths[3] == 5 * spill and line.open == line.cap + 10 * spill,
			"each also opened the sides either side by %d (%.2f of 10, rounded): %d each, %d open in all"
			% [spill, chop.spill_share, 5 * spill, line.open])
	# Every side's depth, not Line.open, which the full side's path never works out again.
	var depths := line.depths.duplicate()
	var full := _strike(chop, Strike.Kind.SLASH, _on_side(chop, line, 2), Strike.MAX_DAMAGE)
	_check(line.depths == depths and _judged(full, TreeChop.Outcome.FULL_SIDE, 0, 1, 2, 0.0),
			"a full side takes no more, nor spreads any (FULL_SIDE, the sides still %s): chop around" % line.depths)
	# Line 2 being chopped, a slash back on line 1's full side brings the readout back to line 1.
	var second := chop.line_at(0, 2)
	var told := []
	chop.changed.connect(func(to: TreeChop.Line) -> void: told.append(to))
	_strike(chop, Strike.Kind.SLASH, _on_side(chop, second, 0), Strike.MAX_DAMAGE)
	var moved := chop.current == second and second.open > 0
	var back := _strike(chop, Strike.Kind.SLASH, _on_side(chop, line, 2), Strike.MAX_DAMAGE)
	var display := _display_of(chop)
	var shown := PackedStringArray()
	for label in display._side_labels:
		shown.append(label.text)
	var expected := PackedStringArray()
	for depth in line.depths:
		expected.append(str(depth))
	_check(moved and _judged(back, TreeChop.Outcome.FULL_SIDE, 0, 1, 2, 0.0) and chop.current == line
			and told == [second, line] and line.depths == depths and display.visible and shown == expected
			and display._total.text == "%d / %d" % [line.open, line.total],
			"line 2 slashed (%d / %d), and so being chopped, a slash on line 1's full side 2 is FULL_SIDE but makes line 1 the line being chopped again, told by changed: the readout shows it, '%s', its sides %s"
			% [second.open, second.total, display._total.text, shown])
	_strike(chop, Strike.Kind.SLASH, _on_side(chop, line, 3), 7)
	for blow in 5:
		_strike(chop, Strike.Kind.SLASH, _on_side(chop, line, 3), Strike.MAX_DAMAGE)
	_check(line.depths[3] == line.cap and line.depths[2] == line.cap,
			"more slashes open a side only to its cap, %d, and spread none past a full side" % line.cap)
	var before := line.depths.duplicate()
	var blunt := _strike(chop, Strike.Kind.BLUNT, _on_side(chop, line, 5), 9)
	var weak := _strike(chop, Strike.Kind.SLASH, _on_side(chop, line, 5), 0)
	_check(blunt.damage == 9 and _judged(blunt, TreeChop.Outcome.BLUNT, 0, 1, -1, 0.0)
			and weak.damage == 0 and _judged(weak, TreeChop.Outcome.NO_DAMAGE, 0, 1, -1, 0.0) and line.depths == before,
			"a blunt strike is still a strike (9 damage) but opens nothing (BLUNT), nor does a slash too weak to do damage (NO_DAMAGE)")
	chop.tree.free()


## Where a slash counts (2026-10-02, forgiving): on the line being chopped while
## within min(band_m, 0.75 of a segment) of it along its branch, else on the
## nearest line within band_m that can be chopped.
func _test_snapping() -> void:
	var chop := await _add_tree()
	var skeleton := chop.tree.skeleton
	var segment := skeleton.segment_length
	var first := chop.current
	# Bark just past a node where the trunk thins is found at the node, against
	# its thicker radius: here the node 0.235 m below line 1.
	var below_point := _bark_point(chop, 0, segment - 0.2)
	var below_at := _found_along(chop, below_point)
	var below := _strike(chop, Strike.Kind.SLASH, below_point, 4)
	_check(chop.current == first and below_at <= segment - 0.2 + 0.0001
			and _judged(below, TreeChop.Outcome.COUNTED, 0, 1, _ANY_SIDE, below_at - segment) and first.open > 0,
			"a slash on the bark 0.20 m below trunk line 1 counts on it (found %.3f m below it, at the node there; %d open)"
			% [segment - below_at, first.open])
	var above := _strike(chop, Strike.Kind.SLASH, _bark_point(chop, 0, segment + 0.3), 4)
	_check(chop.current == first and _judged(above, TreeChop.Outcome.COUNTED, 0, 1, _ANY_SIDE, 0.3),
			"line 1 being chopped, a slash 0.30 m above it still counts on it, though line 2 is nearer (%.2f m)"
			% (segment - 0.3))
	var past := chop.band_m + 0.01
	var next := _strike(chop, Strike.Kind.SLASH, _bark_point(chop, 0, segment + past), 4)
	var second: TreeChop.Line = chop.lines.get(Vector2i(0, 2))
	_check(second != null and chop.current == second and second.open > 0
			and _judged(next, TreeChop.Outcome.COUNTED, 0, 2, _ANY_SIDE, past - segment),
			"one %.2f m above it, past band_m, starts line 2 (%.2f m below it)" % [past, segment - past])
	# A band wider than three quarters of a segment: line 1 keeps slashes only that far.
	chop.band_m = 0.6
	var back := _strike(chop, Strike.Kind.SLASH, _on_side(chop, first, 0), 1)
	var reach := 0.75 * segment + 0.02
	var beyond := _strike(chop, Strike.Kind.SLASH, _bark_point(chop, 0, segment + reach), 4)
	_check(_judged(back, TreeChop.Outcome.COUNTED, 0, 1, 0, 0.0) and chop.current == second
			and _judged(beyond, TreeChop.Outcome.COUNTED, 0, 2, _ANY_SIDE, reach - segment),
			"with band_m widened to 0.60 m, line 1 being chopped keeps slashes only 0.75 of a segment (%.3f m) off it: one %.3f m above it starts line 2"
			% [0.75 * segment, reach])
	chop.band_m = 0.35
	chop.current = null
	var nearer_second := _strike(chop, Strike.Kind.SLASH, _bark_point(chop, 0, segment + 0.3), 4)
	chop.current = null
	var nearer_first := _strike(chop, Strike.Kind.SLASH, _bark_point(chop, 0, segment + 0.18), 4)
	_check(_judged(nearer_second, TreeChop.Outcome.COUNTED, 0, 2, _ANY_SIDE, 0.3 - segment)
			and _judged(nearer_first, TreeChop.Outcome.COUNTED, 0, 1, _ANY_SIDE, 0.18),
			"with no line being chopped, a slash between lines 1 and 2 counts on the nearer: 0.30 m above line 1 on line 2, 0.18 m above it on line 1")
	# Limb 1's line 1 is inside its junction: a slash nearer it counts on line 2.
	var limb := _thickest_limb(skeleton)
	var limb_k := _first_choppable(chop, limb)
	var skipped := (limb_k - 1) * segment + 0.15
	var on_limb := _strike(chop, Strike.Kind.SLASH, _bark_point(chop, limb, skipped), 4)
	_check(limb_k >= 2 and not chop.choppable(limb, limb_k - 1)
			and _judged(on_limb, TreeChop.Outcome.COUNTED, 1, limb_k, 0, skipped - limb_k * segment),
			"on limb %d, a slash 0.15 m past its line %d, which can't be chopped, counts on line %d, the nearest that can (%.2f m on)"
			% [limb, limb_k - 1, limb_k, limb_k * segment - skipped])
	# A limb whose first line to chop is within band_m of its junction.
	var junction_limb := -1
	var junction_k := -1
	var inside := 0.0
	var clear := 0.0
	for branch in skeleton.branch_count():
		if skeleton.branch_depth[branch] != 1 or junction_limb >= 0:
			continue
		var k := _first_choppable(chop, branch)
		var at := maxf(skeleton.bark_clear_distance(branch) - 0.04, k * segment - chop.band_m + 0.02)
		if k >= 1 and at < skeleton.bark_clear_distance(branch) and _bark_point(chop, branch, at) != Vector3.INF:
			junction_limb = branch
			junction_k = k
			inside = at
			clear = skeleton.bark_clear_distance(branch)
	var in_junction := Strike.new()
	if junction_limb >= 0:
		in_junction = _strike(chop, Strike.Kind.SLASH, _bark_point(chop, junction_limb, inside), 4)
	_check(junction_limb >= 0 and _judged(in_junction, TreeChop.Outcome.COUNTED, 1, junction_k, 0, inside - junction_k * segment),
			"on limb %d, a slash on its bark inside its junction (%.2f m along it; its bark clears the trunk's at %.2f m) counts on its first line to chop, %d (%.2f m)"
			% [junction_limb, inside, clear, junction_k, junction_k * segment])
	chop.tree.free()


## What a line takes to cut through scales with the wood's cross-section there:
## first_line_total at the trunk's first line, as much less as the wood is
## thinner in cross-section, least_total at the least.
func _test_damage_scaling() -> void:
	var chop := await _add_tree()
	var skeleton := chop.tree.skeleton
	var segment := skeleton.segment_length
	var first := chop.line_at(0, 1)
	_check(first.total == 300 and first.cap == 50 and first.depths.size() == 8
			and is_equal_approx(skeleton.first_line_radius, skeleton.sample_radius(0, segment)),
			"trunk line 1 (r %.3f m, the tree's first line radius) takes %d to cut through, %d a side, 8 sides"
			% [skeleton.first_line_radius, first.total, first.cap])
	var top_k := skeleton.line_range(0).y
	var high := chop.line_at(0, top_k)
	var expected := _formula(skeleton, 0, top_k)
	_check(high != null and high.total == expected and high.cap == ceili(expected / 6.0) and high.depths.size() == 8,
			"trunk line %d (r %.3f m) takes 300·(r/r₁)², %d, and a sixth of it a side, rounded up, %d"
			% [top_k, skeleton.sample_radius(0, top_k * segment), high.total if high else -1, high.cap if high else -1])
	var limb := _thickest_limb(skeleton)
	var limb_k := _first_choppable(chop, limb)
	var limb_line := chop.line_at(limb, limb_k)
	_check(limb_line != null and limb_line.total == _formula(skeleton, limb, limb_k) and limb_line.total > 10
			and limb_line.depths.size() == 1 and limb_line.cap == limb_line.total,
			"limb %d's line %d (r %.3f m) takes %d the same way, all on its one side"
			% [limb, limb_k, skeleton.sample_radius(limb, limb_k * segment), limb_line.total if limb_line else -1])
	var thin: TreeChop.Line = null
	var raw := 0.0
	var where := Vector2i(-1, -1)
	for branch in skeleton.branch_count():
		var span := skeleton.line_range(branch)
		for k in range(span.x, span.y + 1):
			var share := skeleton.sample_radius(branch, k * segment) / skeleton.first_line_radius
			if thin == null and chop.choppable(branch, k) and 300.0 * share * share < 9.5:
				thin = chop.line_at(branch, k)
				raw = 300.0 * share * share
				where = Vector2i(branch, k)
	_check(thin != null and thin.total == 10,
			"a thin line, branch %d's line %d (300·(r/r₁)² = %.1f), takes the least, %d"
			% [where.x, where.y, raw, thin.total if thin else -1])
	chop.tree.free()


## Six full sides always cut a trunk line through: each side takes its total
## over sides_to_cut rounded up (2026-10-02; rounded to the nearest, six full
## sides fell a point or two short on some lines).
func _test_side_caps() -> void:
	var lines := 0
	var reach := true
	var fell_short := 0
	# The pine's last line where rounding to the nearest fell short, and what it gave a side.
	var short: TreeChop.Line = null
	var rounded := -1
	var fells := []
	for path: String in [SPECIES, PINE]:
		var chop := await _add_tree(0, load(path))
		var span := chop.tree.skeleton.line_range(0)
		for k in range(span.x, span.y + 1):
			var line := chop.line_at(0, k)
			if line == null:
				continue
			lines += 1
			reach = reach and line.cap == ceili(line.total / chop.sides_to_cut) and chop.sides_to_cut * line.cap >= line.total
			var nearest := roundi(line.total / chop.sides_to_cut)
			if nearest * chop.sides_to_cut < line.total:
				fell_short += 1
				if path == PINE:
					short = line
					rounded = nearest
		if path == PINE and short != null:
			# Six of its sides full, the last two shut.
			var six := PackedInt32Array([short.cap, short.cap, short.cap, short.cap, short.cap, short.cap, 0, 0])
			fells = _fells_of(chop)
			var pieces := _pieces_of(chop.tree)
			chop.preset(0, short.k, six)
			await process_frame
			for piece in pieces:
				piece.free()
		chop.tree.free()
	_check(lines > 0 and reach and short != null and rounded * 6 < short.total and short.cap * 6 >= short.total
			and fells.size() == 1,
			"on all %d trunk lines of the oak and the pine (seed 0) that can be chopped, six full sides cut through, each side taking the total over 6 rounded up (on %d, rounded to the nearest they fell short): the pine's line %d takes %d, %d a side, where rounding gave %d, %d in six; its six sides full, %d open, fell it there (%d fell)"
			% [lines, fell_short, short.k if short else -1, short.total if short else -1, short.cap if short else -1,
			rounded, rounded * 6, short.open if short else -1, fells.size()])


## A line is wood to chop only where the wood is thick enough to hit there and
## half a segment on (TreeSkeleton.line_is_wood, 2026-10-02: a piece cut where
## the wood only just reached the line had a sliver of collision, and fell
## through the floor). Found on the oaks of seeds 0 to 15: a line thick enough,
## past its branch's junction, that thins below it within half a segment.
func _test_wood_lines() -> void:
	var species: TreeSpecies = load(SPECIES)
	var min_radius := species.collision_min_radius_m
	var found := Vector3i(-1, -1, -1)
	for tree_seed in 16:
		var grown := TreeSkeletonBuilder.build(species, species.variant_for(tree_seed))
		var segment := grown.segment_length
		for branch in grown.branch_count():
			var span := grown.line_range(branch)
			for k in range(span.x, span.y + 1):
				var at := k * segment
				var on := minf(at + segment * 0.5, grown.branch_length(branch))
				if found.x < 0 and grown.sample_radius(branch, at) >= min_radius and grown.sample_radius(branch, on) < min_radius \
						and (grown.branch_parent[branch] < 0 or at > grown.bark_clear_distance(branch)):
					found = Vector3i(tree_seed, branch, k)
		if found.x >= 0:
			break
	if found.x < 0:
		_check(false, "no oak of seeds 0 to 15 has a line thick enough that thins below wood within half a segment")
		return
	var chop := await _add_tree(found.x)
	var skeleton := chop.tree.skeleton
	var branch := found.y
	var k := found.z
	var segment := skeleton.segment_length
	var others := PackedInt32Array()
	var span := skeleton.line_range(branch)
	for other in range(span.x, span.y + 1):
		if other != k and skeleton.line_is_wood(branch, other, min_radius):
			others.append(other)
	var twig := skeleton.is_twig(branch, min_radius)
	_check(not skeleton.line_is_wood(branch, k, min_radius) and not chop.choppable(branch, k)
			and chop.line_at(branch, k) == null and twig == others.is_empty(),
			"the oak of seed %d: branch %d (depth %d)'s line %d is %.4f m in radius, wood enough, but %.4f m half a segment on: not wood, so it can't be chopped; %s"
			% [found.x, branch, skeleton.branch_depth[branch], k, skeleton.sample_radius(branch, k * segment),
			skeleton.sample_radius(branch, minf((k + 0.5) * segment, skeleton.branch_length(branch))),
			"with no other line that is wood, the branch is a twig" if others.is_empty()
			else "its lines %s are wood, so it is no twig" % [others]])
	chop.tree.free()


## The oak's skeleton split at trunk line 1: the trunk in both pieces, every
## other branch and every leaf in one, each piece keeping the line's node frame.
func _test_split() -> void:
	var whole := TreeSkeletonBuilder.build(load(SPECIES), 0)
	var cut := whole.segment_length
	var pieces := whole.split(0, cut)
	var stump := pieces[0]
	var top := pieces[1]
	_check(stump.branch_count() + top.branch_count() == whole.branch_count() + 1
			and stump.leaf_count() + top.leaf_count() == whole.leaf_count(),
			"split at trunk line 1 (%.3f m up): the trunk in both pieces, every other branch and every leaf in one" % cut)
	_check(stump.node_count() + top.node_count() == whole.node_count() + 1,
			"the line's node ends the stump and starts the top; every other node is kept")
	var tip := stump.branch_node_count[0] - 1
	_check(is_equal_approx(stump.distances[tip], cut) and stump.positions[tip].is_equal_approx(whole.sample_position(0, cut))
			and stump.branch_cut[0] == TreeSkeleton.CUT_TIP,
			"the stump's trunk ends at the cut, marked as cut")
	_check(is_equal_approx(top.distances[0], cut) and top.positions[0].is_equal_approx(whole.sample_position(0, cut))
			and top.branch_cut[0] == TreeSkeleton.CUT_BASE and top.branch_parent[0] == -1
			and is_equal_approx(top.branch_base_radius[0], whole.branch_base_radius[0]),
			"the top's trunk starts at the cut, marked, and keeps the trunk's natural base radius")
	var frame := whole.sample_frame(0, cut)
	var kept := true
	for piece in pieces:
		kept = kept and is_equal_approx(piece.segment_length, whole.segment_length)
		kept = kept and is_equal_approx(piece.first_line_radius, whole.first_line_radius)
	kept = kept and stump.axes[tip].is_equal_approx(frame[0]) and stump.normals[tip].is_equal_approx(frame[1])
	kept = kept and top.axes[0].is_equal_approx(frame[0]) and top.normals[0].is_equal_approx(frame[1])
	_check(kept, "both keep the segment length (%.3f m), the first line's radius (%.3f m) and the line's node frame at the cut"
			% [whole.segment_length, whole.first_line_radius])
	var grows := true
	for branch in range(1, top.branch_count()):
		var parent := top.branch_parent[branch]
		grows = grows and parent >= 0 and parent < branch and top.branch_depth[branch] == top.branch_depth[parent] + 1
		if parent == 0:
			grows = grows and top.branch_attach_distance[branch] > cut
	_check(grows, "every branch of the top grows from one before it, those on the trunk above the cut")
	var leaves := true
	for leaf in top.leaf_count():
		leaves = leaves and (top.leaf_branch[leaf] != 0 or top.leaf_distance[leaf] > cut)
	for leaf in stump.leaf_count():
		leaves = leaves and stump.leaf_branch[leaf] == 0 and stump.leaf_distance[leaf] <= cut
	_check(leaves, "the leaves on the trunk go with the side of the cut they grow on")


## The pieces' meshes and collision meet at every line the skeleton is split
## at: each trunk line, and a limb's.
func _test_cut_pieces() -> void:
	var species: TreeSpecies = load(SPECIES)
	var whole := TreeSkeletonBuilder.build(species, 0)
	var segment := whole.segment_length
	var cuts: Array[Vector2i] = []
	var span := whole.line_range(0)
	for k in range(span.x, span.y + 1):
		cuts.append(Vector2i(0, k))
	var limb := _thickest_limb(whole)
	var limb_span := whole.line_range(limb)
	for k in range(limb_span.x, limb_span.y + 1):
		if whole.line_is_wood(limb, k, species.collision_min_radius_m):
			cuts.append(Vector2i(limb, k))
			break
	var rings := PackedInt32Array()
	var rings_meet := true
	var worst_ring := 0.0
	var capped := true
	var worst_reach := 0.0
	var cylinders := true
	var worst_shape := 0.0
	for cut in cuts:
		var at := cut.y * segment
		var id := whole.branch_id[cut.x]
		var pieces := whole.split(cut.x, at)
		var lower := pieces[0]
		var upper := pieces[1]
		var low := lower.branch_with_id(id)
		var up := upper.branch_with_id(id)
		var point := whole.sample_position(cut.x, at)
		var axis := whole.sample_frame(cut.x, at)[0]
		# The cut branch alone, every other branch left out.
		var lower_mesh := TreeMesher.build_wood(lower, species, TreeMesher.Level.FULL, {}, _all_but(lower, low))
		var upper_mesh := TreeMesher.build_wood(upper, species, TreeMesher.Level.FULL, {}, _all_but(upper, up))
		var lower_ring := _wood_in_plane(lower_mesh, point, axis, false)
		var upper_ring := _wood_in_plane(upper_mesh, point, axis, false)
		rings.append(lower_ring.size())
		rings_meet = rings_meet and lower_ring.size() > 0 and lower_ring.size() == upper_ring.size()
		for i in mini(lower_ring.size(), upper_ring.size()):
			worst_ring = maxf(worst_ring, maxf((lower_ring[i][0] as Vector3).distance_to(upper_ring[i][0]),
					(lower_ring[i][1] as Vector2).distance_to(upper_ring[i][1])))
		capped = capped and not _wood_in_plane(lower_mesh, point, axis, true).is_empty() \
				and not _wood_in_plane(upper_mesh, point, axis, true).is_empty()
		worst_reach = maxf(worst_reach, maxf(_wood_reach(lower_mesh, point, axis).y, -_wood_reach(upper_mesh, point, axis).x))
		var lower_shapes := _shapes_of(TreeCollider.wood(lower, species), low)
		var upper_shapes := _shapes_of(TreeCollider.wood(upper, species), up)
		cylinders = cylinders and lower_shapes.size() > 0 and upper_shapes.size() > 0 \
				and lower_shapes.shapes[-1] is CylinderShape3D and upper_shapes.shapes[0] is CylinderShape3D
		if lower_shapes.size() > 0 and upper_shapes.size() > 0:
			worst_shape = maxf(worst_shape, maxf(_shapes_reach(lower_shapes, point, axis).y,
					-_shapes_reach(upper_shapes, point, axis).x))
	var where := "trunk lines %d to %d and limb %d's line %d" % [span.x, span.y, limb, cuts[-1].y]
	_check(cuts.size() == span.y - span.x + 2 and rings_meet and worst_ring < 0.0001,
			"split at each of %s, the lower piece's last ring of bark and the upper's first are the same vertices (%s), with the same texture coordinates (worst %.6f)"
			% [where, rings, worst_ring])
	_check(capped and worst_reach < 0.0001,
			"there both cut faces are inner wood, and neither piece's cut branch reaches past the cut: no tip cone (worst %.6f m)"
			% worst_reach)
	_check(cylinders and worst_shape < 0.001,
			"and the cut branch's collision ends flat at the cut on both pieces, a cylinder each, neither reaching past it (worst %.4f m)"
			% worst_shape)


## A gone mask (TreeMesher.build_wood) leaving every branch out but `branch`.
static func _all_but(skeleton: TreeSkeleton, branch: int) -> PackedByteArray:
	var gone := PackedByteArray()
	gone.resize(skeleton.branch_count())
	gone.fill(1)
	gone[branch] = 0
	return gone


## The shapes standing for `branch`.
static func _shapes_of(shapes: TreeCollider.Shapes, branch: int) -> TreeCollider.Shapes:
	var result := TreeCollider.Shapes.new()
	for i in shapes.size():
		if shapes.parts[i] == branch:
			result.add(shapes.shapes[i], shapes.transforms[i], branch)
	return result


## The wood vertices lying in the plane through `point` across `axis`, inner
## wood or bark, in order: [position, UV] each.
static func _wood_in_plane(mesh: ArrayMesh, point: Vector3, axis: Vector3, inner: bool) -> Array:
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var uv2s: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	var found := []
	for i in vertices.size():
		if absf((vertices[i] - point).dot(axis)) < 0.0001 and (uv2s[i].x > 0.5) == inner:
			found.append([vertices[i], uvs[i]])
	return found


## How far the wood reaches below (x) and above (y) the plane through `point`
## across `axis`.
static func _wood_reach(mesh: ArrayMesh, point: Vector3, axis: Vector3) -> Vector2:
	var reach := Vector2(INF, -INF)
	for vertex: Vector3 in mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
		var along := (vertex - point).dot(axis)
		reach = Vector2(minf(reach.x, along), maxf(reach.y, along))
	return reach


## How far collision shapes (capsules and cylinders along their Y) reach below
## (x) and above (y) the plane through `point` across `axis`.
static func _shapes_reach(shapes: TreeCollider.Shapes, point: Vector3, axis: Vector3) -> Vector2:
	var reach := Vector2(INF, -INF)
	for i in shapes.size():
		var shape := shapes.shapes[i]
		var place := shapes.transforms[i]
		var tilt := absf(place.basis.y.normalized().dot(axis))
		var spread := 0.0
		if shape is CylinderShape3D:
			var cylinder := shape as CylinderShape3D
			spread = tilt * cylinder.height * 0.5 + cylinder.radius * sqrt(maxf(1.0 - tilt * tilt, 0.0))
		else:
			var capsule := shape as CapsuleShape3D
			spread = tilt * (capsule.height * 0.5 - capsule.radius) + capsule.radius
		var middle := (place.origin - point).dot(axis)
		reach = Vector2(minf(reach.x, middle - spread), maxf(reach.y, middle + spread))
	return reach


## The notches (2026-10-02): the tree draws the band of wood round each line
## being chopped itself, the full level open there, and cuts each side's notch
## into it as the side opens.
func _test_notches() -> void:
	var chop := await _add_tree()
	var tree := chop.tree
	var skeleton := tree.skeleton
	var first := chop.current
	var key := Vector2i(0, 1)
	var ring: Dictionary = tree._rings.get(key, {})
	_check(not ring.is_empty() and ring.instance.mesh != null and ring.from < first.at and first.at < ring.to,
			"a choppable tree draws the band of trunk round line 1 itself, from the start (%.2f to %.2f m up)"
			% [ring.get("from", 0.0), ring.get("to", 0.0)])
	var inside := _inside_band(tree, ring)
	_check(inside == 0, "the full detail level leaves that band of trunk out (%d vertices in it)" % inside)
	_check(_band_meets(tree, ring), "the band's bark meets the trunk's at both ends: its corners, texture and flat sides")
	var openings := PackedInt32Array()
	openings.resize(8)
	openings[2] = int(first.cap * 0.5)
	chop.preset(0, 1, openings)
	# The bands are drawn again at the end of the frame; here, to time it.
	var started := Time.get_ticks_usec()
	tree._redraw()
	var rebuild_ms := (Time.get_ticks_usec() - started) / 1000.0
	var frame := skeleton.sample_frame(0, first.at)
	var axis := frame[0]
	var normal := frame[1]
	var radius := skeleton.sample_radius(0, first.at)
	var depth := float(openings[2]) / first.cap * chop.notch_depth_share * radius
	var centre := skeleton.sample_position(0, first.at)
	var side_width := TAU / 8
	var deepest := 0.0
	var at_corner := 0.0
	var reach := Vector2(INF, -INF)
	var within := true
	for vertex: Array in _inner_wood(ring.instance.mesh):
		var offset := (vertex[0] as Vector3) - centre
		var along := offset.dot(axis)
		var across := offset - axis * along
		var angle := fposmod(atan2(across.dot(axis.cross(normal)), across.dot(normal)), TAU)
		# How far in from the bark: the trunk's flat side lies at r·cos(22.5°) at its middle.
		var from_middle := fposmod(angle, side_width) - side_width * 0.5
		var inset := radius * cos(side_width * 0.5) / cos(from_middle) - across.length()
		reach = Vector2(minf(reach.x, along), maxf(reach.y, along))
		if inset > 0.001:
			within = within and angle > side_width * 1.5 - 0.001 and angle < side_width * 3.5 + 0.001
			deepest = maxf(deepest, inset)
		if absf(angle - side_width * 3.0) < 0.001:
			at_corner = maxf(at_corner, inset)
	_check(within and absf(deepest - depth) < 0.003,
			"side 2 half open: the notch is %.3f m deep at its middle (%.3f expected), fading to nothing at the middles of sides 1 and 3 (rebuilt in %.2f ms)"
			% [deepest, depth, rebuild_ms])
	_check(absf(at_corner - depth * 0.5) < 0.003,
			"at the corner with side 3 it is half as deep, %.3f m: it fades into the next side" % at_corner)
	_check(reach.x < 0.0 and absf(-reach.x - depth * chop.notch_height_share) < 0.003
			and absf(reach.y - depth * chop.notch_height_share) < 0.003,
			"its mouth reaches %.3f m up and down the bark from the line at its deepest" % (depth * chop.notch_height_share))
	# A second line notched: line 3.
	var third_openings := PackedInt32Array([0, 0, 0, 0, 20, 0, 0, 0])
	var third := chop.preset(0, 3, third_openings)
	tree._redraw()
	var second: Dictionary = tree._rings.get(Vector2i(0, 3), {})
	var gaps := Vector2i(_inside_band(tree, ring), _inside_band(tree, second) if not second.is_empty() else -1)
	_check(third != null and not second.is_empty() and gaps == Vector2i.ZERO and _band_meets(tree, ring)
			and _band_meets(tree, second),
			"a second line notched, line 3: the full level leaves both bands out (%d and %d vertices in them), and both bands' bark meets the trunk's at both ends"
			% [gaps.x, gaps.y])
	var tops := _pieces_of(tree)
	chop.preset(0, 1, _through(first))
	await process_frame
	var top_ring: Dictionary = tops[0].piece._rings.get(Vector2i(0, 3), {}) if tops.size() == 1 else {}
	_check(tree._rings.is_empty() and tops.size() == 1 and not tops[0].piece._rings.has(key) and not top_ring.is_empty()
			and is_equal_approx((top_ring.openings as PackedFloat32Array)[4], 20.0 / third.cap),
			"cutting through line 1 ends its notch on both pieces, cut flat; line 3's notch goes with the top, drawn there as it was")
	for top in tops:
		top.free()
	tree.free()


## How many of the full level's wood vertices lie within a notched line's band,
## round its branch.
func _inside_band(tree: ProceduralTree, ring: Dictionary) -> int:
	if ring.is_empty():
		return -1
	var skeleton := tree.skeleton
	var branch: int = ring.branch
	var axis := skeleton.sample_frame(branch, ring.at)[0]
	var lower := skeleton.sample_position(branch, ring.from)
	var span := (skeleton.sample_position(branch, ring.to) - lower).dot(axis)
	var round_it := 2.0 * skeleton.sample_radius(branch, ring.at)
	var inside := 0
	var full: ArrayMesh = tree._levels[TreeMesher.Level.FULL].mesh
	for vertex: Vector3 in full.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
		var along := (vertex - lower).dot(axis)
		if along > 0.001 and along < span - 0.001 and (vertex - lower - axis * along).length() < round_it:
			inside += 1
	return inside


## Whether a notched line's band meets the full level's bark at both its ends:
## every corner of the branch's ring there is one of the band's, with its
## texture, and the band's other vertices lie on the flat sides between them.
func _band_meets(tree: ProceduralTree, ring: Dictionary) -> bool:
	if ring.is_empty() or ring.instance.mesh == null:
		return false
	var skeleton := tree.skeleton
	var branch: int = ring.branch
	var axis := skeleton.sample_frame(branch, ring.at)[0]
	var full: ArrayMesh = tree._levels[TreeMesher.Level.FULL].mesh
	var meets := true
	for end: float in [ring.from, ring.to]:
		var point := skeleton.sample_position(branch, end)
		var trunk_ring := _wood_in_plane(full, point, axis, false)
		var band_ring := _wood_in_plane(ring.instance.mesh, point, axis, false)
		meets = meets and not band_ring.is_empty() and not trunk_ring.is_empty()
		for corner: Array in trunk_ring:
			var found := false
			for vertex: Array in band_ring:
				found = found or ((vertex[0] as Vector3).distance_to(corner[0]) < 0.0001
						and (vertex[1] as Vector2).distance_to(corner[1]) < 0.0001)
			meets = meets and found
		for vertex: Array in band_ring:
			var on_side := false
			for i in trunk_ring.size() - 1:
				var from_side := Geometry3D.get_closest_point_to_segment(vertex[0], trunk_ring[i][0], trunk_ring[i + 1][0])
				on_side = on_side or (vertex[0] as Vector3).distance_to(from_side) < 0.0001
			meets = meets and on_side
	return meets


## The inner-wood vertices of a mesh's wood: [position, UV] each.
static func _inner_wood(mesh: ArrayMesh) -> Array:
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var uv2s: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	var found := []
	for i in vertices.size():
		if uv2s[i].x > 0.5:
			found.append([vertices[i], uvs[i]])
	return found


## A tree falls away from the wood left uncut; away from the last slash's side
## when what is left is even all round.
func _test_fall_direction() -> void:
	var chop := await _add_tree()
	var line := chop.current
	var cap := line.cap
	var away := -(chop.side_direction(line, 2) + chop.side_direction(line, 3))
	away.y = 0.0
	var fells := _fells_of(chop)
	var pieces := _pieces_of(chop.tree)
	chop.preset(0, 1, PackedInt32Array([cap, cap, 0, 0, cap, cap, cap, cap]))
	_check(fells.size() == 1 and (fells[0][1] as Vector3).angle_to(away.normalized()) < 0.01,
			"sides 2 and 3 left uncut: it falls away from between them")
	for piece in pieces:
		piece.free()
	chop.tree.free()
	chop = await _add_tree()
	line = chop.current
	fells = _fells_of(chop)
	pieces = _pieces_of(chop.tree)
	away = -chop.side_direction(line, 5)
	away.y = 0.0
	chop.preset(0, 1, PackedInt32Array([cap, cap, 0, cap, cap, cap - 10, 0, cap]))
	_strike(chop, Strike.Kind.SLASH, _on_side(chop, line, 5), 10)
	_check(fells.size() == 1 and (fells[0][1] as Vector3).angle_to(away.normalized()) < 0.01,
			"two opposite sides uncut, even: it falls away from the side the last slash opened")
	for piece in pieces:
		piece.free()
	chop.tree.free()


## Felling at trunk line 1: the tree keeps its stump, and the part above becomes
## a FelledTree beside it, which tips over hinged to the stump and chops on with
## the lines it carries.
func _test_felling() -> void:
	var chop := await _add_tree()
	var tree := chop.tree
	var display := _display_of(chop)
	var fells := _fells_of(chop)
	var tops: Array[FelledTree] = []
	tree.felled.connect(func(top: FelledTree) -> void: tops.append(top))
	var whole := tree.skeleton
	var segment := whole.segment_length
	var standing := tree.global_transform
	var min_radius := tree.species.collision_min_radius_m
	# A limb's line opened part way first: the top takes it as it was.
	var limb := _thickest_limb(whole)
	var limb_id := whole.branch_id[limb]
	var limb_k := _first_choppable(chop, limb)
	_strike(chop, Strike.Kind.SLASH, _bark_point(chop, limb, limb_k * segment), 10)
	var limb_line: TreeChop.Line = chop.lines.get(Vector2i(limb_id, limb_k))
	# One short of felling, the last two sides shut.
	var line := chop.line_at(0, 1)
	chop.preset(0, 1, _one_short(line))
	_check(fells.is_empty() and line.open == line.total - 1 and limb_line != null and limb_line.open == 10,
			"%d of %d open on line 1: still standing" % [line.open, line.total])
	# Where it should fall: away from the wood left uncut, each side weighing as
	# much as is left of it, once side 6 takes the last point.
	var left := line.depths.duplicate()
	left[6] += 1
	var hinge_side := Vector3.ZERO
	for side in line.depths.size():
		hinge_side += chop.side_direction(line, side) * (line.cap - left[side])
	hinge_side.y = 0.0
	var last := _strike(chop, Strike.Kind.SLASH, _on_side(chop, line, 6), 1)
	var toward: Vector3 = fells[0][1] if fells.size() == 1 else Vector3.ZERO
	var trunk_then: float = fells[0][2] if fells.size() == 1 else 0.0
	_check(fells.size() == 1 and _judged(last, TreeChop.Outcome.COUNTED, 0, 1, 6, 0.0) and is_equal_approx(fells[0][0], segment)
			and absf(toward.y) < 0.0001 and toward.angle_to(-hinge_side.normalized()) < 0.01
			and is_equal_approx(trunk_then, whole.branch_length(0)),
			"the slash that opens the %dth fells it, at line 1 (%.3f m up), level and away from the wood left uncut; felled is told before the tree is cut (its trunk still %.2f m)"
			% [line.total, segment, trunk_then])
	# The stump, with no line left on it, is lone from that tick (checkpoint 1c).
	var after := _strike(chop, Strike.Kind.SLASH, _on_side(chop, line, 7), 10)
	_check(fells.size() == 1 and _judged(after, TreeChop.Outcome.LONE, 0, 1, -1, 0.0) and chop.health != null
			and chop.health.current == chop.health.maximum - 10,
			"felled once only: a slash where line 1 was finds no line to chop; the stump, lone now, takes it from its health instead (LONE, %d of %d left)"
			% [chop.health.current if chop.health else -1, chop.health.maximum if chop.health else -1])
	await process_frame
	_check(is_instance_valid(tree) and tops.size() == 1 and tops[0].get_parent() == tree.get_parent(),
			"the tree stays, as its stump, and the part above becomes a FelledTree beside it")
	var top := tops[0]
	_check(is_equal_approx(tree.skeleton.branch_length(0), segment) and tree.skeleton.line_range(0) == Vector2i(1, 0)
			and chop.lines.is_empty() and chop.current == null and tree.has_collision()
			and Strikeable.of(tree._wood_body) == chop.strikeable,
			"the stump: the trunk up to line 1, %.3f m, with no line left on it, still solid and struck as the tree" % segment)
	_check(top.skeleton.branch_count() + tree.skeleton.branch_count() == whole.branch_count() + 1
			and is_equal_approx(top.skeleton.distances[0], segment),
			"the top: the trunk from line 1 up, with the %d branches above it" % (top.skeleton.branch_count() - 1))
	_check(top.collision_layer == ProceduralTree.STATIC_LAYER and top.collision_mask == FelledTree.MASK
			and top.mass > 100.0,
			"the top is on the Static layer and meets everything props do, the player and hands too (%d kg)" % top.mass)
	_check(top.continuous_cd,
			"it collides continuously, as every piece cut off does, so a thin one falling fast can't pass through the level's thin floor between two ticks")
	_check(top.global_transform.is_equal_approx(standing), "it starts where the tree stood")
	var top_display := _display_of(top.chop)
	_check(top.chop != null and Strikeable.of(top) == top.chop.strikeable and top_display != null,
			"the top chops as the tree did: a TreeChop of its own, struck through its body, and a readout of it")
	var top_lines := top.skeleton.line_range(0)
	var second := top.chop.line_at(0, 2) if top.chop else null
	_check(top_lines == Vector2i(2, 8) and second != null and second.depths.size() == 8
			and second.total == _formula(whole, 0, 2) and top.chop.line_at(0, 1) == null
			and not chop.lines.has(Vector2i(0, 1)) and not top.chop.lines.has(Vector2i(0, 1)),
			"its trunk lines run %d to %d, each of 8 sides (line 2 takes %d, as on the tree); line 1 is on neither piece"
			% [top_lines.x, top_lines.y, second.total if second else -1])
	var top_limb := top.skeleton.branch_with_id(limb_id)
	var handed: TreeChop.Line = top.chop.lines.get(Vector2i(limb_id, limb_k)) if top.chop else null
	var notch: Dictionary = top.piece._rings.get(Vector2i(top_limb, limb_k), {})
	_check(handed != null and handed == limb_line and handed.depths == PackedInt32Array([10]) and not notch.is_empty()
			and is_equal_approx((notch.openings as PackedFloat32Array)[0], 10.0 / handed.total),
			"limb %d's line %d, opened 10 of %d before the fell, is the top's now as it was, its notch drawn there"
			% [limb, limb_k, handed.total if handed else -1])
	var stump_health: HealthDisplay = display._health if display else null
	_check(display != null and display.visible and not display._total.visible and display._side_labels.is_empty()
			and stump_health != null and stump_health.text == "40 / 50" and top_display != null and not top_display.visible,
			"no line being chopped on either piece: the top's readout is hidden; the stump's shows its health instead ('%s'), the chop's numbers hidden"
			% (stump_health.text if stump_health else ""))
	await physics_frame
	await physics_frame
	_check(_hinged(top, tree._wood_body, toward),
			"as it starts to tip it is hinged to the stump, about a level axis square to the way it falls")
	var wood := top.piece
	var clusters := top.skeleton.leaf_count()
	_check(clusters > 0 and wood._foliage != null and wood._foliage.monitoring
			and wood._foliage.collision_mask == _BREAKERS | ProceduralTree.STATIC_LAYER
			and _touch_count(wood, 0) == clusters and top.leaves_left() == clusters,
			"each of the top's %d leaf clusters has a touch volume, watching what breaks a tree's leaves, and its surroundings too"
			% clusters)
	# On a branch two below the trunk, which was a twig by its depth alone before
	# is_twig: it has a line that is wood.
	var leaf := _leaf_on(wood.skeleton, min_radius, false, 2)
	var on := wood.skeleton.leaf_branch[leaf] if leaf >= 0 else -1
	var drawn := (wood._leaf_levels[0].mesh as ArrayMesh).surface_get_array_len(0)
	var ground := StaticBody3D.new()
	var player := _player()
	_touch(wood, player, 0, leaf)
	_touch(wood, top, 0, leaf)
	_touch(wood, ground, 0, leaf)
	_touch(wood, ground, 0, leaf)
	await process_frame
	_check(leaf >= 0 and top.leaves_left() == clusters - 1 and wood.gone_branches().count(1) == 0
			and (wood._leaf_levels[0].mesh as ArrayMesh).surface_get_array_len(0) == drawn - 8
			and wood._foliage.is_shape_owner_disabled(_touch_owner(wood, 0, leaf)),
			"cluster %d, on branch %d (depth %d) but wood with a line to chop, touches the ground at rest: it is gone alone (its 8 corners and its touch volume), once, the branch staying; the player's body and its own wood break nothing"
			% [leaf, on, wood.skeleton.branch_depth[on] if on >= 0 else -1])
	var twig_leaf := _leaf_on(wood.skeleton, min_radius, true)
	var twig := wood.skeleton.leaf_branch[twig_leaf]
	var with_it := _leaves_from(wood.skeleton, twig)
	_touch(wood, ground, 0, twig_leaf)
	await process_frame
	_check(wood.gone_branches()[twig] == 1 and top.leaves_left() == clusters - 1 - with_it,
			"a cluster on a twig that touches the ground breaks the twig off, with its %d clusters" % with_it)
	ground.free()
	player.free()
	top.free()
	tree.free()


## A trunk line high up cut through (2026-10-02: "If the player decides to chop
## above his head and he does enough damage, then the tree should separate from
## that point"): the part above tips over off it, hinged to the stump, which
## keeps its own lines below.
func _test_high_cut() -> void:
	var chop := await _add_tree()
	var tree := chop.tree
	var segment := tree.skeleton.segment_length
	var k := 4
	var fells := _fells_of(chop)
	var tops := _pieces_of(tree)
	chop.preset(0, k, _through(chop.line_at(0, k)))
	await process_frame
	var toward: Vector3 = fells[0][1] if fells.size() == 1 else Vector3.ZERO
	_check(fells.size() == 1 and is_equal_approx(fells[0][0], k * segment) and absf(toward.y) < 0.0001
			and is_equal_approx(toward.length(), 1.0),
			"trunk line %d (%.2f m up) cut through on the standing tree: felled once, there, the way level" % [k, k * segment])
	_check(tops.size() == 1 and is_equal_approx(tree.skeleton.branch_length(0), k * segment)
			and is_equal_approx(tops[0].skeleton.distances[0], k * segment)
			and tree.skeleton.line_range(0) == Vector2i(1, k - 1) and not chop.lines.has(Vector2i(0, k)),
			"the stump is the trunk up to it, %.2f m, with lines 1 to %d still on it; the top a FelledTree from there up"
			% [k * segment, k - 1])
	var top: FelledTree = tops[0] if tops.size() == 1 else null
	await physics_frame
	await physics_frame
	var hinged := top != null and _hinged(top, tree._wood_body, toward)
	for tick in 20:
		await physics_frame
	var tilt := Vector3.UP.angle_to(top.global_basis.y) if top else 0.0
	_check(hinged and top.global_basis.y.dot(toward) > 0.0 and tilt > deg_to_rad(1.0),
			"the top is hinged to the stump's body about a level axis square to the way it falls, and tips that way (%.1f° in 22 ticks)"
			% rad_to_deg(tilt))
	var first: TreeChop.Line = chop.lines.get(Vector2i(0, 1))
	var opened := first.open if first else -1
	var slash := _strike(chop, Strike.Kind.SLASH, _bark_point(chop, 0, segment), 10)
	_check(first != null and _judged(slash, TreeChop.Outcome.COUNTED, 0, 1, _ANY_SIDE, 0.0) and first.open > opened,
			"the stump's line 1 still opens on a slash (%d open)" % (first.open if first else -1))
	if top:
		top.free()
	tree.free()


## Every branch thick enough to hit has lines of one side along it, from where
## its bark clears its parent's: cut through, the part beyond comes off as a
## FelledTree of its own and falls, the stub capped.
func _test_branch_lines() -> void:
	var chop := await _add_tree()
	var tree := chop.tree
	var whole := tree.skeleton
	var segment := whole.segment_length
	var min_radius := tree.species.collision_min_radius_m
	var limb := _thickest_limb(whole)
	var id := whole.branch_id[limb]
	var span := whole.line_range(limb)
	var first := _first_choppable(chop, limb)
	var clear := whole.bark_clear_distance(limb)
	var totals := PackedInt32Array()
	var formula := PackedInt32Array()
	var one_sided := first >= 1
	for k in range(first, span.y + 1):
		var line := chop.line_at(limb, k)
		totals.append(line.total if line else -1)
		formula.append(_formula(whole, limb, k))
		one_sided = one_sided and line != null and line.depths.size() == 1 and line.cap == line.total
	_check(one_sided and totals == formula,
			"limb %d's lines %d to %d are of one side, each taking what its cross-section gives: %s" % [limb, first, span.y, totals])
	_check(first > span.x and first * segment > clear and (first - 1) * segment <= clear
			and not whole.line_is_wood(limb, first - 1, min_radius),
			"its first line that can be chopped is line %d (%.2f m along it), the first past where its bark clears the trunk's (%.2f m)"
			% [first, first * segment, clear])
	var cut_k := mini(first + 1, span.y)
	var on_line := _bark_point(chop, limb, cut_k * segment)
	var blunt := _strike(chop, Strike.Kind.BLUNT, on_line, 10)
	var off_at := first * segment - chop.band_m - 0.04
	var off := _strike(chop, Strike.Kind.SLASH, _bark_point(chop, limb, off_at), 10)
	var nearest := roundi(off_at / segment)
	_check(_open_total(chop) == 0 and _judged(blunt, TreeChop.Outcome.BLUNT, 1, cut_k, -1, 0.0)
			and _judged(off, TreeChop.Outcome.OFF_LINE, 1, nearest, -1, off_at - nearest * segment),
			"a blunt blow on line %d, and a slash %.2f m short of line %d (nearer line %d, inside its junction), cut nothing: BLUNT, OFF_LINE"
			% [cut_k, chop.band_m + 0.04, first, nearest])
	var pieces := _pieces_of(tree)
	var fells := _fells_of(chop)
	var tree_fells: Array[FelledTree] = []
	tree.felled.connect(func(top: FelledTree) -> void: tree_fells.append(top))
	var cut_line := chop.line_at(limb, cut_k)
	var slashes := 0
	while chop.lines.has(Vector2i(id, cut_k)) and slashes < 10:
		_strike(chop, Strike.Kind.SLASH, on_line, 10)
		slashes += 1
	await process_frame
	var piece: FelledTree = pieces[0] if pieces.size() == 1 else null
	_check(piece != null and fells.is_empty() and tree_fells.is_empty() and piece.skeleton.branch_id[0] == id
			and is_equal_approx(piece.skeleton.distances[0], cut_k * segment) and piece.skeleton.branch_cut[0] & TreeSkeleton.CUT_BASE
			and piece.skeleton.branch_count() + tree.skeleton.branch_count() == whole.branch_count() + 1,
			"%d slashes put line %d through (%d to cut): the limb comes off there, %.2f m along it, as a FelledTree of its own, with all growing from it; no felled signal"
			% [slashes, cut_k, cut_line.total, cut_k * segment])
	var stub := tree.skeleton.branch_with_id(id)
	var stub_span := tree.skeleton.line_range(stub) if stub >= 0 else Vector2i(1, 0)
	var wood_only := stub >= 0
	var choppable := PackedInt32Array()
	for k in range(stub_span.x, stub_span.y + 1):
		if chop.choppable(stub, k):
			choppable.append(k)
		wood_only = wood_only and chop.choppable(stub, k) == tree.skeleton.line_is_wood(stub, k, min_radius)
	var handed := piece != null and piece.chop != null and not chop.lines.has(Vector2i(id, cut_k)) \
			and not piece.chop.lines.has(Vector2i(id, cut_k))
	for k in range(cut_k + 1, span.y + 1):
		handed = handed and piece.chop.lines.has(Vector2i(id, k)) and not chop.lines.has(Vector2i(id, k))
	_check(wood_only and handed and tree.skeleton.branch_cut[stub] & TreeSkeleton.CUT_TIP
			and is_equal_approx(tree.skeleton.branch_length(stub), cut_k * segment) and stub_span == Vector2i(1, cut_k - 1)
			and choppable == PackedInt32Array(range(first, cut_k)),
			"the stub is capped, %.2f m long, with lines %d to %d, of which only those that are wood can be chopped (%s); line %d is on neither piece, lines %d to %d went with the limb"
			% [cut_k * segment, stub_span.x, stub_span.y, choppable, cut_k, cut_k + 1, span.y])
	_check(piece != null and piece.mass > 1.0 and piece.chop != null and Strikeable.of(piece) == piece.chop.strikeable
			and _display_of(piece.chop) != null and piece.leaves_left() > 0 and piece._toward == Vector3.ZERO,
			"the limb is wood still, struck through its body and chopped with a readout, not set to tip over (%d kg, %d leaf clusters)"
			% [piece.mass if piece else 0.0, piece.leaves_left() if piece else 0])
	# It slides off its stub's cut, then drops.
	var height := _centre_of_mass(piece).y if piece else 0.0
	for frame in 30:
		await physics_frame
	var dropped := height - _centre_of_mass(piece).y if piece else 0.0
	_check(piece != null and dropped > 0.1 and piece._hinge == null,
			"it falls, hinged to nothing (%.2f m in 30 ticks)" % dropped)
	if piece:
		piece.free()
	tree.free()


## Bucking a felled top at one of its trunk lines: two FelledTrees, the new one
## neither tipping nor hinged, each chopping on with the tree's settings and the
## lines it carries.
func _test_bucking() -> void:
	var errors := _ErrorCounter.new()
	OS.add_logger(errors)
	var chop := await _add_tree()
	var tree := chop.tree
	var segment := tree.skeleton.segment_length
	# Settings off their defaults, so the pieces can be seen to copy them.
	var settings := {&"band_m": 0.3, &"sides": 10, &"first_line_total": 320, &"least_total": 12, &"sides_to_cut": 6.5,
			&"spill_share": 0.3, &"notch_depth_share": 0.8, &"notch_height_share": 0.3, &"impact_speed": 3.5}
	for setting: StringName in settings:
		chop.set(setting, settings[setting])
	var tops := _pieces_of(tree)
	chop.preset(0, 1, _through(chop.line_at(0, 1)))
	await process_frame
	var top: FelledTree = tops[0] if tops.size() == 1 else null
	var logs := _pieces_of(top.piece)
	var top_fells := _fells_of(top.chop)
	var beyond := top.chop.preset(0, 6, PackedInt32Array([5]))
	var at := 4
	top.chop.preset(0, at, _through(top.chop.line_at(0, at)))
	await process_frame
	var log: FelledTree = logs[0] if logs.size() == 1 else null
	_check(log != null and top_fells.is_empty() and is_equal_approx(log.skeleton.distances[0], at * segment)
			and is_equal_approx(top.skeleton.distances[0], segment) and is_equal_approx(top.skeleton.branch_length(0), at * segment),
			"the felled top bucked at its line %d: a second FelledTree from %.2f m up, the top kept from %.2f to %.2f m; no felled signal"
			% [at, at * segment, segment, at * segment])
	for tick in 3:
		await physics_frame
	_check(log != null and log._toward == Vector3.ZERO and log._hinge == null,
			"the log neither tips over nor is hinged: it falls as it will")
	var both := true
	for piece: FelledTree in [top, log]:
		both = both and piece != null and piece.chop != null and _display_of(piece.chop) != null
		for setting: StringName in settings:
			both = both and piece != null and piece.chop != null and piece.chop.get(setting) == settings[setting]
	_check(both, "both chop on, each with a TreeChop and its readout, and the tree's settings, fall damage's impact_speed among them (%s)"
			% [settings.values()])
	var on_log: TreeChop.Line = log.chop.lines.get(Vector2i(0, 6)) if log else null
	_check(on_log != null and on_log == beyond and on_log.depths.size() == 10 and on_log.depths[0] == 5
			and not top.chop.lines.has(Vector2i(0, 6)) and not top.chop.lines.has(Vector2i(0, at))
			and not log.chop.lines.has(Vector2i(0, at)) and top.skeleton.line_range(0) == Vector2i(2, at - 1)
			and log.skeleton.line_range(0) == Vector2i(at + 1, 8),
			"line 6, opened 5, went with the log as it was; line %d is on neither piece; the top keeps lines 2 to %d, the log %d to 8"
			% [at, at - 1, at + 1])
	# The top's body was marked as struck when it was made, and again as it was cut.
	var marks := Vector2i(top.chop.strikeable._marked.count(top) if top and top.chop else -1,
			log.chop.strikeable._marked.count(log) if log and log.chop else -1)
	if log:
		log.free()
	if top:
		top.free()
	tree.free()
	await process_frame
	OS.remove_logger(errors)
	_check(errors.count == 0 and marks == Vector2i.ONE,
			"each piece's body marked as struck once (top %d, log %d), though the top's collision was built again as it was cut; no engine errors as the tree is felled and bucked and the pieces are freed (%d)"
			% [marks.x, marks.y, errors.count])


## A line a limb's junction crosses can't be chopped: a cut there would go
## through the limb's base.
func _test_blocked_lines() -> void:
	var chop := await _add_tree(BLOCKED_SEED)
	var tree := chop.tree
	var skeleton := tree.skeleton
	var segment := skeleton.segment_length
	var min_radius := tree.species.collision_min_radius_m
	var k := -1
	var span := skeleton.line_range(0)
	for line_k in range(span.x, span.y + 1):
		if k < 0 and skeleton.line_is_wood(0, line_k, min_radius) and skeleton.line_blocked(0, line_k, tree.gone_branches()):
			k = line_k
	var at := k * segment
	var limb := -1
	var junction := Vector2.ZERO
	for child in range(1, skeleton.branch_count()):
		if skeleton.branch_parent[child] == 0 and limb < 0:
			var across := skeleton.junction_span(child)
			if across.x < at and at < across.y:
				limb = child
				junction = across
	_check(k >= 1 and limb >= 1 and not chop.choppable(0, k) and chop.line_at(0, k) == null,
			"the oak of seed %d: trunk line %d (%.2f m up) is wood, but limb %d's junction (%.3f to %.3f m) crosses it: it can't be chopped"
			% [BLOCKED_SEED, k, at, limb, junction.x, junction.y])
	var opened := _open_total(chop)
	var on_it := _strike(chop, Strike.Kind.SLASH, _bark_point(chop, 0, at), 10)
	_check(_judged(on_it, TreeChop.Outcome.BLOCKED, 0, k, -1, 0.0) and _open_total(chop) == opened
			and not chop.lines.has(Vector2i(0, k)),
			"a full-strength slash on it opens nothing: BLOCKED, on line %d" % k)
	var below := _strike(chop, Strike.Kind.SLASH, _bark_point(chop, 0, at - 0.2), 10)
	_check(_judged(below, TreeChop.Outcome.COUNTED, 0, k - 1, _ANY_SIDE, segment - 0.2) and _open_total(chop) > opened,
			"one 0.20 m below it, within band_m of line %d, counts there instead, as the rule has it" % (k - 1))
	# Cut off at its first line, the limb leaves its stub, whose base still crosses the line.
	var pieces := _pieces_of(tree)
	var limb_k := _first_choppable(chop, limb)
	chop.preset(limb, limb_k, _through(chop.line_at(limb, limb_k)))
	await process_frame
	var stub := tree.skeleton.branch_with_id(skeleton.branch_id[limb])
	tree.break_branch(stub)
	_check(pieces.size() == 1 and stub >= 0 and tree.gone_branches()[stub] == 0 and not chop.choppable(0, k),
			"cut off at its line %d, limb %d leaves its stub, whose base still crosses line %d, and which no strike breaks off: still blocked"
			% [limb_k, limb, k])
	# Gone from the tree, as a twig broken off is, it no longer blocks the line.
	for gone in range(stub, tree.skeleton.subtree_end(stub)):
		tree._gone[gone] = 1
	var freed := _strike(chop, Strike.Kind.SLASH, _bark_point(chop, 0, at), 10)
	var line: TreeChop.Line = chop.lines.get(Vector2i(0, k))
	_check(chop.choppable(0, k) and line != null and line.open > 0
			and _judged(freed, TreeChop.Outcome.COUNTED, 0, k, _ANY_SIDE, 0.0),
			"with the limb gone from the tree (its gone flag set, as break_branch sets a twig's), line %d can be chopped: a slash there counts (%d of %d open)"
			% [k, line.open if line else -1, line.total if line else -1])
	for piece in pieces:
		piece.free()
	tree.free()


## A twig, a branch with no line that is wood (TreeSkeleton.is_twig), breaks
## off whole on a strike at BREAK_SPEED or faster, with everything growing from
## it and their leaves; a branch with a line to chop never does.
func _test_twigs() -> void:
	var chop := await _add_tree()
	var tree := chop.tree
	var skeleton := tree.skeleton
	var min_radius := tree.species.collision_min_radius_m
	var to_strike := _twig_to_strike(chop)
	var twig: int = to_strike[0]
	var point: Vector3 = to_strike[1]
	var with_it := _leaves_from(skeleton, twig) if twig >= 0 else 0
	var clusters := tree.leaves_left()
	var drawn := (tree._levels[0].mesh as ArrayMesh).surface_get_array_len(0)
	var leaves_drawn := (tree._leaf_levels[0].mesh as ArrayMesh).surface_get_array_len(0)
	var slow := ProceduralTree.BREAK_SPEED * 0.75
	var fast := ProceduralTree.BREAK_SPEED * 1.5
	# Judged at the nearest whole segment along it, though it has no line.
	var along := _found_along(chop, point) if twig >= 0 else 0.0
	var nearest := roundi(along / skeleton.segment_length)
	var offset := along - nearest * skeleton.segment_length
	var held := _strike(chop, Strike.Kind.SLASH, point, 10, slow)
	var depth := skeleton.branch_depth[twig] if twig >= 0 else -1
	_check(twig >= 0 and tree.gone_branches()[twig] == 0 and _judged(held, TreeChop.Outcome.TWIG_HELD, depth, nearest, -1, offset),
			"twig %d (depth %d: no line that is wood) slashed at %.1f m/s holds (TWIG_HELD, %.2f m along it, judged at segment %d)"
			% [twig, depth, slow, along, nearest])
	var broken := _strike(chop, Strike.Kind.SLASH, point, 10, fast)
	await process_frame
	var still := 0
	for i in tree._wood_owners.size():
		if tree._wood_parts[i] >= twig and tree._wood_parts[i] < skeleton.subtree_end(twig) \
				and not tree._wood_body.is_shape_owner_disabled(tree._wood_owners[i]):
			still += 1
	_check(twig >= 0 and _judged(broken, TreeChop.Outcome.TWIG_BROKEN, depth, nearest, -1, offset)
			and tree.gone_branches()[twig] == 1 and tree.leaves_left() == clusters - with_it and still == 0
			and (tree._levels[0].mesh as ArrayMesh).surface_get_array_len(0) < drawn and _open_total(chop) == 0,
			"slashed at %.1f m/s it breaks off whole (TWIG_BROKEN): its wood, its collision and its %d leaf clusters gone, nothing opened"
			% [fast, with_it])
	# Headset bug (2026-10-02): the wood, drawn again, brought every leaf back with it.
	var wood_only := true
	for instance in tree._levels:
		wood_only = wood_only and (instance.mesh as ArrayMesh).get_surface_count() == 1
	_check(wood_only and (tree._leaf_levels[0].mesh as ArrayMesh).surface_get_array_len(0) == leaves_drawn - 8 * with_it,
			"the wood drawn again is wood only, at every level, and its %d clusters' leaves are no longer drawn" % with_it)
	# A branch two below the trunk with a line to chop.
	var wood := -1
	var on_wood := Vector3.INF
	for branch in skeleton.branch_count():
		if wood < 0 and skeleton.branch_depth[branch] == 2 and not skeleton.is_twig(branch, min_radius):
			var k := _first_choppable(chop, branch)
			var found := _bark_point(chop, branch, k * skeleton.segment_length) if k >= 1 else Vector3.INF
			if found != Vector3.INF:
				wood = branch
				on_wood = found
	var blow := _strike(chop, Strike.Kind.BLUNT, on_wood, 10, fast)
	_check(wood >= 0 and tree.gone_branches()[wood] == 0 and _judged(blow, TreeChop.Outcome.BLUNT, 2, _first_choppable(chop, wood), -1, 0.0),
			"branch %d, two below the trunk but with a line to chop, struck blunt at %.1f m/s does not break (BLUNT)" % [wood, fast])
	tree.free()


## A pine's thin upper limbs, off the trunk, have no line that is wood: they
## are twigs, as a branch further out is (2026-10-02: whether a branch has a
## line to chop decides, not its depth), and break off whole.
func _test_limb_twigs() -> void:
	var chop := await _add_tree(0, load(PINE))
	var tree := chop.tree
	var skeleton := tree.skeleton
	var min_radius := tree.species.collision_min_radius_m
	var limbs := PackedInt32Array()
	for branch in skeleton.branch_count():
		if skeleton.branch_depth[branch] == 1 and skeleton.is_twig(branch, min_radius):
			limbs.append(branch)
	var to_strike := _twig_to_strike(chop, 1)
	var twig: int = to_strike[0]
	var point: Vector3 = to_strike[1]
	var with_it := _leaves_from(skeleton, twig) if twig >= 0 else 0
	var clusters := tree.leaves_left()
	var along := _found_along(chop, point) if twig >= 0 else 0.0
	var nearest := roundi(along / skeleton.segment_length)
	var fast := ProceduralTree.BREAK_SPEED * 1.5
	var broken := _strike(chop, Strike.Kind.SLASH, point, 10, fast)
	_check(twig >= 0 and _judged(broken, TreeChop.Outcome.TWIG_BROKEN, 1, nearest, -1, along - nearest * skeleton.segment_length)
			and tree.gone_branches()[twig] == 1 and tree.leaves_left() == clusters - with_it and _open_total(chop) == 0,
			"the pine of seed 0 has %d limbs with no line that is wood; one, limb %d (%.3f m at its base), slashed at %.1f m/s breaks off whole (TWIG_BROKEN), its %d leaf clusters with it"
			% [limbs.size(), twig, skeleton.branch_base_radius[twig] if twig >= 0 else 0.0, fast, with_it])
	# Another, by one of its own clusters.
	var other := -1
	var leaf := -1
	for cluster in skeleton.leaf_count():
		var on := skeleton.leaf_branch[cluster]
		if other < 0 and limbs.has(on) and not tree.gone_branches()[on]:
			other = on
			leaf = cluster
	var left := tree.leaves_left()
	var with_other := _leaves_from(skeleton, other) if other >= 0 else 0
	var prop := _prop()
	root.add_child(prop)
	prop.linear_velocity = Vector3(0.0, 0.0, fast)
	_touch(tree, prop, 0, leaf)
	var gone := tree.gone_branches().slice(other, skeleton.subtree_end(other)) if other >= 0 else PackedByteArray()
	_check(other >= 0 and gone.count(0) == 0 and tree.leaves_left() == left - with_other and with_other > 1,
			"a prop swung through cluster %d, on limb %d, at %.1f m/s takes the whole limb: %d branches gone with what grows from it, and all %d of their clusters"
			% [leaf, other, fast, gone.size(), with_other])
	prop.free()
	tree.free()


## The twig with the most leaf clusters with it (of those `depth` below the
## trunk, if given), and a point on its bark a strike finds it at, 0.3 of the
## way along it: [twig, point], or [-1, INF].
func _twig_to_strike(chop: TreeChop, depth := -1) -> Array:
	var skeleton := chop.tree.skeleton
	var min_radius := chop.tree.species.collision_min_radius_m
	var twig := -1
	var point := Vector3.INF
	for branch in skeleton.branch_count():
		if not skeleton.is_twig(branch, min_radius) or chop.tree.gone_branches()[branch] \
				or (depth >= 0 and skeleton.branch_depth[branch] != depth):
			continue
		var base := skeleton.distances[skeleton.branch_first_node[branch]]
		var found := _bark_point(chop, branch, base + 0.3 * (skeleton.branch_length(branch) - base))
		if found != Vector3.INF and (twig < 0 or _leaves_from(skeleton, branch) > _leaves_from(skeleton, twig)):
			twig = branch
			point = found
	return [twig, point]


## A standing tree's leaves and bare twigs break only when something moves
## through them at BREAK_SPEED or faster: never the player's body. A cluster on
## a twig takes the twig with it; one on wood with a line to chop goes alone.
func _test_breaking_leaves() -> void:
	var chop := await _add_tree()
	var tree := chop.tree
	var min_radius := tree.species.collision_min_radius_m
	_check(tree.own and tree._foliage.monitoring and tree._foliage.collision_mask == _BREAKERS,
			"a choppable tree's leaves watch hands, held items, props and enemies; not the player's body nor the level")
	var clusters := tree.leaves_left()
	# On a branch two below the trunk, which was a twig by its depth alone before
	# is_twig: it has a line that is wood.
	var leaf := _leaf_on(tree.skeleton, min_radius, false, 2)
	var on := tree.skeleton.leaf_branch[leaf] if leaf >= 0 else -1
	var player := _player()
	var prop := _prop()
	root.add_child(player)
	root.add_child(prop)
	player.velocity = Vector3(0.0, 0.0, 5.0)
	_touch(tree, player, 0, leaf)
	_touch(tree, prop, 0, leaf)
	prop.linear_velocity = Vector3(0.0, 0.0, ProceduralTree.BREAK_SPEED * 0.75)
	_touch(tree, prop, 0, leaf)
	_check(tree.leaves_left() == clusters,
			"walking through a cluster, or a prop at rest or at %.1f m/s, breaks nothing" % (ProceduralTree.BREAK_SPEED * 0.75))
	prop.linear_velocity = Vector3(0.0, 0.0, ProceduralTree.BREAK_SPEED * 1.5)
	_touch(tree, prop, 0, leaf)
	_check(leaf >= 0 and tree.leaves_left() == clusters - 1 and tree.gone_branches().count(1) == 0,
			"a prop swung through it at %.1f m/s breaks that cluster, %d, alone: it grows on branch %d (depth %d), wood with a line to chop, which stays"
			% [ProceduralTree.BREAK_SPEED * 1.5, leaf, on, tree.skeleton.branch_depth[on] if on >= 0 else -1])
	var twig_leaf := _leaf_on(tree.skeleton, min_radius, true)
	var twig := tree.skeleton.leaf_branch[twig_leaf]
	var with_it := _leaves_from(tree.skeleton, twig)
	_touch(tree, prop, 0, twig_leaf)
	_check(tree.gone_branches()[twig] == 1 and tree.leaves_left() == clusters - 1 - with_it,
			"swung through a cluster on twig %d, it breaks the twig off with its %d clusters" % [twig, with_it])
	# Every twig of this oak has leaves of its own (the birch grows bare ones:
	# _test_bare_twigs); one whose leaves are taken away is bare.
	var grown := tree.skeleton
	var bare := -1
	for branch in grown.branch_count():
		if bare < 0 and grown.is_twig(branch, min_radius) and not tree.gone_branches()[branch]:
			bare = branch
	var gone_leaves := PackedByteArray()
	gone_leaves.resize(grown.leaf_count())
	for cluster in grown.leaf_count():
		gone_leaves[cluster] = int(grown.leaf_branch[cluster] == bare)
	var twiggy := ProceduralTree.new()
	twiggy.grow_piece(tree.species, TreeCache.Entry.new(tree.species, 0, grown.pruned(tree.gone_branches(), gone_leaves)),
			Transform3D.IDENTITY, null)
	root.add_child(twiggy)
	var bare_twig := twiggy.skeleton.branch_with_id(grown.branch_id[bare])
	var touched := _touch_owner(twiggy, 1, bare_twig) >= 0
	prop.linear_velocity = Vector3(0.0, 0.0, ProceduralTree.BREAK_SPEED * 0.75)
	_touch(twiggy, prop, 1, bare_twig)
	var held := twiggy.gone_branches()[bare_twig] == 0
	prop.linear_velocity = Vector3(0.0, 0.0, ProceduralTree.BREAK_SPEED * 1.5)
	_touch(twiggy, prop, 1, bare_twig)
	_check(touched and held and twiggy.gone_branches()[bare_twig] == 1,
			"a bare twig's thin wood has touch volumes (%d) and breaks as leaves do: not at %.1f m/s, at %.1f m/s"
			% [_touch_count(twiggy, 1), ProceduralTree.BREAK_SPEED * 0.75, ProceduralTree.BREAK_SPEED * 1.5])
	twiggy.free()
	player.free()
	prop.free()
	tree.free()


## The birch grows bare twigs: limbs with no line that is wood and no leaves of
## their own, only on the twigs growing from them. A standing birch's own thin
## wood there has touch volumes (TreeCollider.twigs), so a swing through one
## breaks it off with everything growing from it.
func _test_bare_twigs() -> void:
	var chop := await _add_tree(0, load(BIRCH))
	var tree := chop.tree
	var skeleton := tree.skeleton
	var min_radius := tree.species.collision_min_radius_m
	var bare := -1
	var count := 0
	for branch in skeleton.branch_count():
		if skeleton.branch_depth[branch] == 1 and skeleton.is_twig(branch, min_radius) \
				and not skeleton.leaf_branch.has(branch):
			count += 1
			if bare < 0 or _leaves_from(skeleton, branch) > _leaves_from(skeleton, bare):
				bare = branch
	var volumes := 0
	for part: Vector2i in tree._touch_parts.values():
		if part == Vector2i(1, bare):
			volumes += 1
	var clusters := tree.leaves_left()
	var with_it := _leaves_from(skeleton, bare) if bare >= 0 else 0
	var prop := _prop()
	root.add_child(prop)
	prop.linear_velocity = Vector3(0.0, 0.0, ProceduralTree.BREAK_SPEED * 0.75)
	_touch(tree, prop, 1, bare)
	var held := bare >= 0 and tree.gone_branches()[bare] == 0 and tree.leaves_left() == clusters
	prop.linear_velocity = Vector3(0.0, 0.0, ProceduralTree.BREAK_SPEED * 1.5)
	_touch(tree, prop, 1, bare)
	var gone := tree.gone_branches().slice(bare, skeleton.subtree_end(bare)) if bare >= 0 else PackedByteArray()
	_check(bare >= 0 and tree.own and volumes > 0 and held and gone.count(0) == 0 and with_it > 0
			and tree.leaves_left() == clusters - with_it,
			"the birch of seed 0 grows %d bare twigs off its trunk; one, limb %d, standing, has %d touch volumes of its thin wood: swung through at %.1f m/s it holds, at %.1f m/s it breaks off with the %d twigs growing from it and their %d leaf clusters"
			% [count, bare, volumes, ProceduralTree.BREAK_SPEED * 0.75, ProceduralTree.BREAK_SPEED * 1.5, gone.size() - 1,
			with_it])
	prop.free()
	tree.free()


## Every strike the tree judges carries what it came to (Strike.judged), for the
## recorder: the outcome, the branch's depth, the line it counted on or the
## nearest, how far along the branch from it, and the side.
func _test_verdicts() -> void:
	var chop := await _add_tree()
	var line := chop.current
	var off_point := chop.centre(line) + chop.side_direction(line, 0) * (chop.radius(line) + 0.3)
	var off_bark := _strike(chop, Strike.Kind.SLASH, off_point, 10)
	_check(_judged(off_bark, TreeChop.Outcome.OFF_BARK, -1, -1, -1, 0.0) and line.open == 0,
			"a slash 0.30 m off the bark: OFF_BARK, on no branch, no line, no side")
	var segment := chop.tree.skeleton.segment_length
	var low := segment - chop.band_m - 0.04
	var low_point := _bark_point(chop, 0, low)
	var off_line := _strike(chop, Strike.Kind.SLASH, low_point, 10)
	_check(_judged(off_line, TreeChop.Outcome.OFF_LINE, 0, 0, -1, low) and line.open == 0,
			"a slash on the trunk %.2f m up, %.2f m below line 1 and out of its band: OFF_LINE, the nearest line the trunk's base (0), %.2f m from it"
			% [low, segment - low, low])
	# The recorder asks locate() whether a strike counted on the line being chopped.
	var twig_point: Vector3 = _twig_to_strike(chop)[1]
	_check(chop.locate(_on_side(chop, line, 3)) == line and chop.locate(_bark_point(chop, 0, segment + 0.3)) == line
			and chop.locate(off_point) == null and chop.locate(low_point) == null
			and twig_point != Vector3.INF and chop.locate(twig_point) == null,
			"locate() names the line a slash at a point would count on: line 1 on it, and 0.30 m above it while it is being chopped; none 0.30 m off the bark, out of band below it, or on a twig")
	chop.tree.free()


## The readout follows the line last struck: on a trunk line a number at each
## side and "open / total" above the line in world up; on a branch line the
## total alone; nothing while no line is being chopped.
func _test_display() -> void:
	var chop := await _add_tree()
	var tree := chop.tree
	var display := _display_of(chop)
	var line := chop.current
	var middle := chop.centre(line)
	var placed := display != null and display._side_labels.size() == 8
	if placed:
		for side in 8:
			var label := display._side_labels[side]
			placed = placed and label.text == "0" and chop.side_at(line, label.global_position) == side \
					and absf(label.global_position.distance_to(middle) - chop.radius(line) - display.side_offset_m) < 0.001
	_check(placed and display.visible and display._total.text == "0 / 300",
			"at ready the readout shows trunk line 1: a number at each of its 8 sides, out from the bark there, and '%s'"
			% (display._total.text if display else ""))
	_strike(chop, Strike.Kind.SLASH, _on_side(chop, line, 2), 10)
	var texts := PackedStringArray()
	for label in display._side_labels:
		texts.append(label.text)
	_check(texts == PackedStringArray(["0", "3", "10", "3", "0", "0", "0", "0"]) and display._total.text == "16 / 300"
			and display._total.global_position.is_equal_approx(middle + Vector3.UP * display.total_height_m),
			"a slash on side 2: the sides read %s, the total '%s', %.2f m above the line in world up"
			% [texts, display._total.text, display.total_height_m])
	var limb := _thickest_limb(tree.skeleton)
	var limb_k := _first_choppable(chop, limb)
	var on_limb := _bark_point(chop, limb, limb_k * tree.skeleton.segment_length)
	_strike(chop, Strike.Kind.SLASH, on_limb, 10)
	var limb_line := chop.current
	_check(limb_line != null and limb_line.id == tree.skeleton.branch_id[limb] and display.visible
			and display._side_labels.is_empty() and display._total.text == "10 / %d" % limb_line.total
			and display._total.global_position.is_equal_approx(chop.centre(limb_line) + Vector3.UP * display.total_height_m),
			"a slash on limb %d's line %d: the readout follows it, the total alone ('%s'), above that line"
			% [limb, limb_k, display._total.text])
	var pieces := _pieces_of(tree)
	var slashes := 0
	while chop.current != null and slashes < 10:
		_strike(chop, Strike.Kind.SLASH, on_limb, 10)
		slashes += 1
	await process_frame
	_check(pieces.size() == 1 and chop.current == null and not display.visible,
			"once that line is cut through, no line is being chopped: the readout hides")
	for piece in pieces:
		piece.free()
	tree.free()


## A piece of a tree with no line left that can be chopped is lone (checkpoint
## 1c, 2026-10-02): a standing tree is not; felled at trunk line 1, the stump is
## lone in the tick it is cut, the top not; the top bucked at its line 2 keeps
## one segment, lone, while the log cut off it is not. A lone piece's body damps
## its spin by lone_angular_damp (2026-10-03: "the individual stick and log
## segments also roll way too easily"), any other felled piece by
## FelledTree.ROLLING_DAMP; the stump is static, with nothing to damp.
func _test_lone_pieces() -> void:
	var errors := _ErrorCounter.new()
	OS.add_logger(errors)
	var chop := await _add_tree()
	var tree := chop.tree
	var segment := tree.skeleton.segment_length
	var span := tree.skeleton.line_range(0)
	_check(not chop.is_lone() and chop.health == null and tree.get_node_or_null(^"Health") == null
			and tree.get_node_or_null(^"LootDrop") == null,
			"a standing oak, its trunk lines %d to %d still to chop, is not lone: no health, no loot" % [span.x, span.y])
	var tops := _pieces_of(tree)
	chop.preset(0, 1, _through(chop.line_at(0, 1)))
	var top: FelledTree = tops[0] if tops.size() == 1 else null
	var health := chop.health
	var top_then := top != null and not top.chop.is_lone() and top.chop.health == null
	_check(chop.is_lone() and health != null and health.get_parent() == tree and health.current == 50
			and tree.skeleton.line_range(0) == Vector2i(1, 0),
			"felled at trunk line 1, the stump (to %.2f m up, no line on it) is lone in that tick: a Health of %d on the tree itself"
			% [segment, health.maximum if health else -1])
	var stump := tree._wood_body
	var stump_place := stump.global_transform if stump else Transform3D()
	var top_damp := top.angular_damp if top else -1.0
	await process_frame
	for tick in 3:
		await physics_frame
	_check(top_damp == FelledTree.ROLLING_DAMP and top.angular_damp == FelledTree.ROLLING_DAMP
			and stump is StaticBody3D and is_instance_valid(stump) and stump.global_transform == stump_place
			and errors.count == 0,
			"the top, not lone, damps its spin by FelledTree.ROLLING_DAMP (%.1f /s), in that tick and after; the stump, lone, stays the tree's static wood (a StaticBody3D, unmoved 3 ticks on), nothing on it to damp (no engine errors)"
			% (top.angular_damp if top else -1.0))
	var top_span := top.skeleton.line_range(0) if top else Vector2i(1, 0)
	_check(top_then and not top.chop.is_lone() and top.chop.health == null and top.get_node_or_null(^"Health") == null,
			"the top, its trunk lines %d to %d and its limbs' still to chop, is not, in that tick nor after the frame"
			% [top_span.x, top_span.y])
	var logs := _pieces_of(top.piece)
	top.chop.preset(0, 2, _through(top.chop.line_at(0, 2)))
	var at_once := top.chop.health != null
	var damp_at_once := top.angular_damp
	await process_frame
	var log: FelledTree = logs[0] if logs.size() == 1 else null
	var log_span := log.skeleton.line_range(0) if log else Vector2i(1, 0)
	_check(at_once and top.chop.is_lone() and top.chop.health != null and top.chop.health.get_parent() == top
			and top.chop.health.maximum == 50 and is_equal_approx(top.skeleton.distances[0], segment)
			and is_equal_approx(top.skeleton.branch_length(0), 2.0 * segment) and log != null and not log.chop.is_lone()
			and log.chop.health == null,
			"the top bucked at its line 2 keeps one segment of trunk, %.2f to %.2f m (%d branch): lone after the frame, as from the cut, a Health of 50 on its body; the log cut off it, from %.2f m with lines %d to %d, is not"
			% [segment, 2.0 * segment, top.skeleton.branch_count(), 2.0 * segment, log_span.x, log_span.y])
	var damp := chop.lone_angular_damp
	_check(damp != FelledTree.ROLLING_DAMP and damp_at_once == damp and top.angular_damp == damp
			and top.chop.lone_angular_damp == damp and log != null and log.angular_damp == FelledTree.ROLLING_DAMP,
			"lone, that segment of trunk damps its spin by the tree's lone_angular_damp (%.1f /s), from the tick it was bucked (%.1f) on; the log cut off it, not lone, keeps FelledTree.ROLLING_DAMP (%.1f)"
			% [damp, damp_at_once, log.angular_damp if log else -1.0])
	_free_all([log, top, tree])
	await process_frame
	OS.remove_logger(errors)


## A piece whose only line a junction crosses is lone too (2026-10-02: a blocked
## line keeps no piece attached, so every tree breaks up completely), and drops
## for every segment of wood it holds.
func _test_lone_blocked() -> void:
	var chop := await _add_tree(BLOCKED_SEED)
	var tree := chop.tree
	var skeleton := tree.skeleton
	var segment := skeleton.segment_length
	var min_radius := tree.species.collision_min_radius_m
	var blocked := _blocked_line(skeleton, min_radius)
	var k := blocked.x
	var limb := blocked.y
	var limb_k := _first_choppable(chop, limb)
	var pieces := _pieces_of(tree)
	# The limb cut off first, at its first line to chop: its stub still blocks line k.
	chop.preset(limb, limb_k, _through(chop.line_at(limb, limb_k)))
	chop.preset(0, k - 1, _through(chop.line_at(0, k - 1)))
	await process_frame
	var top: FelledTree = pieces[1] if pieces.size() == 2 else null
	var logs := _pieces_of(top.piece)
	top.chop.preset(0, k + 1, _through(top.chop.line_at(0, k + 1)))
	var drop := top.get_node_or_null(^"LootDrop") as LootDrop
	_check(k >= 2 and top.skeleton.line_range(0) == Vector2i(k, k) and top.skeleton.line_is_wood(0, k, min_radius)
			and not top.chop.choppable(0, k) and top.chop.is_lone() and top.chop.health != null and drop != null
			and drop.loot.resource_path == LOG and drop.count == top.chop.logs_per_segment * 2,
			"the oak of seed %d, limb %d cut off at its line %d, then felled at trunk line %d and bucked at %d: the piece between, %.2f to %.2f m up, holds only line %d, wood but blocked by the limb's stub; lone all the same, it drops %d logs a segment for its 2 segments, %d"
			% [BLOCKED_SEED, limb, limb_k, k - 1, k + 1, (k - 1) * segment, (k + 1) * segment, k,
			top.chop.logs_per_segment, drop.count if drop else -1])
	# Nothing else near it: the stump, the limb and the log go.
	_free_all(logs + [pieces[0], tree])
	await physics_frame
	var marker := top.get_node_or_null(^"LoneMiddle") as Node3D
	var items := _drops_of(drop)
	var base := top.skeleton.distances[0]
	var blows := _break(top.chop, _bark_point(top.chop, 0, base + 0.3 * (top.skeleton.branch_length(0) - base)))
	var middle := marker.global_position if marker else Vector3.INF
	var fit := _ring_of(items, middle, drop.gap if drop else 0.0)
	var queued := top.is_queued_for_deletion()
	await process_frame
	_check(blows == 5 and queued and not is_instance_valid(top) and items.size() == 6
			and items.all(func(item: Node3D) -> bool: return item.scene_file_path == LOG)
			and fit.off < 0.0001 and fit.apart >= 2.0 * fit.reach,
			"five full-strength slashes break it, its body freed after the frame: its 6 logs lie round its middle, each %.3f m from it (the ring for 6), level with it, none raised, %.3f m apart (%.3f needed)"
			% [fit.ring, fit.apart, 2.0 * fit.reach])
	_free_all(items)


## A limb's stub with a line still to chop keeps a piece from being lone until
## that line is cut: the oak's upper limb cut off at its line 2 leaves line 1 on
## its stub.
func _test_lone_stub() -> void:
	var chop := await _add_tree()
	var tree := chop.tree
	var skeleton := tree.skeleton
	var segment := skeleton.segment_length
	var limb := _highest_limb(skeleton)
	var id := skeleton.branch_id[limb]
	var first := _first_choppable(chop, limb)
	var junction := skeleton.junction_span(limb)
	# The trunk lines either side of where the limb joins it.
	var below := floori(junction.x / segment)
	var above := ceili(junction.y / segment)
	var pieces := _pieces_of(tree)
	chop.preset(limb, first + 1, _through(chop.line_at(limb, first + 1)))
	chop.preset(0, below, _through(chop.line_at(0, below)))
	await process_frame
	var top: FelledTree = pieces[1] if pieces.size() == 2 else null
	var logs := _pieces_of(top.piece)
	top.chop.preset(0, above, _through(top.chop.line_at(0, above)))
	await process_frame
	var stub := top.skeleton.branch_with_id(id)
	var left := _choppable_lines(top.chop)
	_check(above == below + 1 and stub >= 1 and left.size() == 1 and left[0] == Vector2i(stub, first)
			and not top.chop.is_lone() and top.chop.health == null,
			"the oak's upper limb, %d, cut off at its line %d, the trunk felled at line %d and bucked at %d, either side of the limb's junction: the piece between holds no trunk line, but its stub's line %d can still be chopped: not lone, after the frame either"
			% [limb, first + 1, below, above, first])
	top.chop.preset(stub, first, _through(top.chop.line_at(stub, first)))
	var drop := top.get_node_or_null(^"LootDrop") as LootDrop
	_check(top.chop.is_lone() and top.chop.health != null and top.chop.health.maximum == 50 and drop != null
			and drop.count == 3,
			"that line cut through, the piece is lone at once: trunk, with health %d and %d logs for its one segment"
			% [top.chop.health.maximum if top.chop.health else -1, drop.count if drop else -1])
	_free_all(logs + pieces + [tree])


## A lone piece's health is fixed by its kind (2026-10-02): trunk_segment_health
## (50) for a piece of trunk, branch_segment_health (10) for a branch's; only
## slashes take it, each judged LONE; and the pieces cut off a tree take its
## settings.
func _test_lone_health() -> void:
	var chop := await _add_tree()
	var tree := chop.tree
	var skeleton := tree.skeleton
	var segment := skeleton.segment_length
	var limb := _thickest_limb(skeleton)
	var last := _last_choppable(chop, limb)
	var pieces := _pieces_of(tree)
	chop.preset(limb, last, _through(chop.line_at(limb, last)))
	chop.preset(0, 1, _through(chop.line_at(0, 1)))
	await process_frame
	var tip: FelledTree = pieces[0] if pieces.size() == 2 else null
	var stump_drop := tree.get_node_or_null(^"LootDrop") as LootDrop
	var tip_drop: LootDrop = null
	if tip:
		tip_drop = tip.get_node_or_null(^"LootDrop") as LootDrop
	_check(chop.health != null and chop.health.maximum == 50 and stump_drop != null and stump_drop.loot.resource_path == LOG
			and tip != null and tip.chop.is_lone() and tip.chop.health != null and tip.chop.health.maximum == 10
			and tip_drop != null and tip_drop.loot.resource_path == STICK and tip_drop.count == 1,
			"felled at line 1, the stump is a piece of trunk: health %d, logs to drop; limb %d cut off at its last line to chop, %d (%.2f m along it), leaves its tip lone, a piece of a branch: health %d, %d stick to drop"
			% [chop.health.maximum if chop.health else -1, limb, last, last * segment,
			tip.chop.health.maximum if tip and tip.chop.health else -1, tip_drop.count if tip_drop else -1])
	var felled_top: FelledTree = pieces[1] if pieces.size() == 2 else null
	_check(tip != null and tip.angular_damp == chop.lone_angular_damp and felled_top != null
			and felled_top.angular_damp == FelledTree.ROLLING_DAMP,
			"lone, the tip, a segment of branch, damps its spin by the tree's lone_angular_damp (%.1f /s); the felled top, not lone, keeps FelledTree.ROLLING_DAMP (%.1f)"
			% [tip.angular_damp if tip else -1.0, felled_top.angular_damp if felled_top else -1.0])
	var point := _bark_point(chop, 0, 0.4 * segment)
	var along := _found_along(chop, point)
	var nearest := roundi(along / segment)
	var offset := along - nearest * segment
	var blunt := _strike(chop, Strike.Kind.BLUNT, point, Strike.MAX_DAMAGE)
	var weak := _strike(chop, Strike.Kind.SLASH, point, 0)
	_check(blunt.damage == Strike.MAX_DAMAGE and _judged(blunt, TreeChop.Outcome.BLUNT, 0, nearest, -1, offset)
			and weak.damage == 0 and _judged(weak, TreeChop.Outcome.NO_DAMAGE, 0, nearest, -1, offset)
			and chop.health.current == 50,
			"a full-strength blunt blow on the stump (%d damage) takes none of its health (BLUNT), nor does a slash too weak to do damage (NO_DAMAGE): %d left"
			% [blunt.damage, chop.health.current])
	var slash := _strike(chop, Strike.Kind.SLASH, point, Strike.MAX_DAMAGE)
	_check(_judged(slash, TreeChop.Outcome.LONE, 0, nearest, -1, offset) and chop.health.current == 40
			and TreeChop.Outcome.LONE == 10,
			"a full-strength slash takes its %d (LONE, the outcome added last, 10, for the recorder): %d left"
			% [slash.damage, chop.health.current])
	_free_all(pieces + [tree])
	# Settings off their defaults on a tree's chop, before it is cut, reach the
	# pieces cut off it and those cut off them.
	chop = await _add_tree()
	tree = chop.tree
	var settings := {&"log_scene": load(STICK), &"logs_per_segment": 2, &"stick_scene": load(LOG),
			&"sticks_per_segment": 4, &"trunk_segment_health": 40, &"branch_segment_health": 20,
			&"lone_angular_damp": 9.5}
	for setting: StringName in settings:
		chop.set(setting, settings[setting])
	var tops := _pieces_of(tree)
	chop.preset(0, 1, _through(chop.line_at(0, 1)))
	await process_frame
	var top: FelledTree = tops[0] if tops.size() == 1 else null
	var logs := _pieces_of(top.piece)
	var at := top.skeleton.line_range(0).y
	top.chop.preset(0, at, _through(top.chop.line_at(0, at)))
	await process_frame
	var log: FelledTree = logs[0] if logs.size() == 1 else null
	var copied := log != null
	for setting: StringName in settings:
		copied = copied and log.chop.get(setting) == settings[setting]
	var log_drop: LootDrop = null
	if log:
		log_drop = log.get_node_or_null(^"LootDrop") as LootDrop
	_check(copied and log.chop.health != null and log.chop.health.maximum == 40 and log_drop != null
			and log_drop.count == 2 and log_drop.loot == settings[&"log_scene"] and log.angular_damp == 9.5
			and top.angular_damp == FelledTree.ROLLING_DAMP,
			"the lone pieces' settings, set off their defaults on the tree's chop before it is cut (healths 40 and 20, 2 logs and 4 sticks a segment, the two scenes swapped, a spin damp of 9.5 /s), reach the pieces: the top's last segment, bucked off at its line %d, lone as it is cut off, has health %d, drops %d of the scene set and damps its spin by %.1f /s; the top, not lone, by FelledTree.ROLLING_DAMP (%.1f)"
			% [at, log.chop.health.maximum if log and log.chop.health else -1, log_drop.count if log_drop else -1,
			log.angular_damp if log else -1.0, top.angular_damp if top else -1.0])
	_free_all([log, top, tree])


## A lone piece's readout (2026-10-02): its health in place of the chop's
## numbers, above its bark at its middle in world up, depth-tested as a vein's
## is, kept there as the piece moves.
func _test_lone_readout() -> void:
	var chop := await _add_tree()
	var tree := chop.tree
	var segment := tree.skeleton.segment_length
	var display := _display_of(chop)
	var limb := _thickest_limb(tree.skeleton)
	var last := _last_choppable(chop, limb)
	var pieces := _pieces_of(tree)
	chop.preset(limb, last, _through(chop.line_at(limb, last)))
	chop.preset(0, 1, _through(chop.line_at(0, 1)))
	var label: HealthDisplay = display._health
	var skeleton := tree.skeleton
	var middle := tree.skeleton_transform() * skeleton.sample_position(0, 0.5 * segment)
	var radius := skeleton.sample_radius(0, 0.5 * segment) * tree.skeleton_transform().basis.get_scale().x
	var above := chop.lone_centre() + Vector3.UP * (chop.lone_radius() + display.total_height_m)
	_check(label != null and display.visible and label.visible and label.text == "50 / 50" and label.health == chop.health
			and not display._total.visible and display._side_labels.is_empty() and chop.lone_centre().is_equal_approx(middle)
			and is_equal_approx(chop.lone_radius(), radius) and label.global_position.is_equal_approx(above)
			and not label.no_depth_test and label.billboard == BaseMaterial3D.BILLBOARD_ENABLED,
			"felled at line 1, the stump's readout gives way to its health in that tick: '%s', facing the viewer and depth-tested, as a vein's is, %.3f m up, its radius there (%.3f m) and %.2f m above its middle (%.3f m up); the chop's numbers hidden"
			% [label.text if label else "", above.y, radius, display.total_height_m, middle.y])
	_strike(chop, Strike.Kind.SLASH, _bark_point(chop, 0, 0.4 * segment), Strike.MAX_DAMAGE)
	_check(label != null and label.text == "40 / 50" and label.global_position.is_equal_approx(above),
			"a full-strength slash on it, and it reads '%s', where it stood" % (label.text if label else ""))
	# Nothing in the tip's way as it falls: the top goes.
	var tip: FelledTree = pieces[0] if pieces.size() == 2 else null
	_free_all(pieces.slice(1))
	await process_frame
	var tip_display := _display_of(tip.chop)
	var start := tip.chop.lone_centre()
	for tick in 20:
		await physics_frame
	# Once the frame has placed it (TreeChopDisplay._process), before the next
	# tick moves the piece on.
	await create_timer(0.0).timeout
	var tip_label: HealthDisplay = tip_display._health if tip_display else null
	var tip_above := tip.chop.lone_centre() + Vector3.UP * (tip.chop.lone_radius() + tip_display.total_height_m)
	var fallen := start.y - tip.chop.lone_centre().y
	_check(tip_label != null and tip_label.text == "10 / 10" and fallen > 0.1
			and tip_label.global_position.is_equal_approx(tip_above),
			"limb %d's tip, cut off at its line %d, is lone and falls: its readout, '%s', is kept above its bark at its middle, %.2f m lower 20 ticks on"
			% [limb, last, tip_label.text if tip_label else "", fallen])
	_free_all([tip, tree])


## At 0 a lone piece is gone (2026-10-02): the stump frees its tree, a piece its
## body; its loot lies still in a ring round its middle, on its side and clear of
## each other, 3 logs a segment of trunk or a stick a segment of branch, none
## raised by the piece's own wood.
func _test_lone_breaking() -> void:
	var chop := await _add_tree()
	var tree := chop.tree
	var world := tree.get_parent()
	var segment := tree.skeleton.segment_length
	var limb := _thickest_limb(tree.skeleton)
	var last := _last_choppable(chop, limb)
	var pieces := _pieces_of(tree)
	chop.preset(limb, last, _through(chop.line_at(limb, last)))
	chop.preset(0, 1, _through(chop.line_at(0, 1)))
	await process_frame
	var tip: FelledTree = pieces[0] if pieces.size() == 2 else null
	# Nothing else near the stump: the top goes, and the tip is far off it.
	_free_all(pieces.slice(1))
	await physics_frame
	var drop := tree.get_node_or_null(^"LootDrop") as LootDrop
	var marker := tree.get_node_or_null(^"LoneMiddle") as Node3D
	var wood := tree._wood_body
	var logs := _drops_of(drop)
	var blows := _break(chop, _bark_point(chop, 0, 0.4 * segment))
	var middle := marker.global_position if marker else Vector3.INF
	var fit := _ring_of(logs, middle, drop.gap if drop else 0.0)
	var in_wood := logs.filter(func(item: Node3D) -> bool: return _meets(item, wood)).size()
	var logs_down := drop != null and drop.lay_down
	var logs_lying := _lying(logs, middle)
	var queued := tree.is_queued_for_deletion()
	await process_frame
	_check(blows == 5 and queued and not is_instance_valid(tree) and logs.size() == 3
			and logs.all(func(item: Node3D) -> bool: return item.scene_file_path == LOG and item.get_parent() == world),
			"five full-strength slashes take the stump's 50: it drops 3 logs, for its one segment, into the tree's parent, and its tree is freed after the frame")
	_check(fit.off < 0.0001 and fit.apart >= 2.0 * fit.reach and in_wood == 3,
			"they lie round its middle (%.3f m up), each %.3f m from it (the ring for 3), level with it, %.3f m apart (%.3f needed); none raised, though all %d are in the stump's own wood body"
			% [middle.y, fit.ring, fit.apart, 2.0 * fit.reach, in_wood])
	var tip_drop: LootDrop = null
	var tip_marker: Node3D = null
	if tip:
		tip_drop = tip.get_node_or_null(^"LootDrop") as LootDrop
		tip_marker = tip.get_node_or_null(^"LoneMiddle") as Node3D
	var sticks := _drops_of(tip_drop)
	var base := tip.skeleton.distances[0]
	var tip_blows := _break(tip.chop, _bark_point(tip.chop, 0, base + 0.4 * (tip.skeleton.branch_length(0) - base)))
	var tip_middle := tip_marker.global_position if tip_marker else Vector3.INF
	var at_middle := sticks.size() == 1 and sticks[0].global_position.distance_to(tip_middle) < 0.0001
	var in_own := sticks.size() == 1 and _meets(sticks[0], tip)
	var stick_down := tip_drop != null and tip_drop.lay_down
	var stick_lying := _lying(sticks, tip_middle)
	var tip_queued := tip.is_queued_for_deletion()
	await process_frame
	_check(tip_blows == 1 and tip_queued and not is_instance_valid(tip) and sticks.size() == 1
			and sticks[0].scene_file_path == STICK and at_middle and in_own,
			"limb %d's tip, lone, takes one full-strength slash for its 10: its body is freed after the frame, and it drops 1 stick, for its one segment of branch, at its middle, not raised though that is in the tip's own wood"
			% limb)
	_check(logs_down and stick_down and logs.size() == 3 and logs_lying.x < 0.0001 and logs_lying.y < 0.0001
			and sticks.size() == 1 and stick_lying.x < 0.0001,
			"a lone piece's LootDrop lays its loot down (lay_down): the stump's 3 logs lie with their length (Y) level (%.6f off at most) along their ring, square to the line out from its middle (%.6f off); the tip's stick lies level too (%.6f off)"
			% [logs_lying.x, logs_lying.y, stick_lying.x])
	_free_all(logs + sticks)


## Every slash that does damage on a lone piece goes to its health, judged LONE,
## wherever it lands (2026-10-02 review): on a twig, which it also breaks off if
## fast enough, as any fast strike breaks a twig, or off the bark. A blunt blow
## still breaks a twig off, and takes none of the health.
func _test_lone_twigs() -> void:
	var made: Array = await _lone_twig_piece()
	var tree: ProceduralTree = made[0]
	var piece: FelledTree = made[1]
	var segment := piece.skeleton.segment_length
	var health := piece.chop.health
	var to_strike := _twig_to_strike(piece.chop)
	var twig: int = to_strike[0]
	var point: Vector3 = to_strike[1]
	var depth := piece.skeleton.branch_depth[twig] if twig >= 0 else -1
	var along := _found_along(piece.chop, point) if twig >= 0 else 0.0
	var nearest := roundi(along / segment)
	var offset := along - nearest * segment
	var slow := ProceduralTree.BREAK_SPEED * 0.5
	var fast := ProceduralTree.BREAK_SPEED * 1.5
	var slash := _strike(piece.chop, Strike.Kind.SLASH, point, Strike.MAX_DAMAGE, slow)
	var after_slow := health.current if health else -1
	var kept := twig >= 0 and piece.piece.gone_branches()[twig] == 0
	var fast_slash := _strike(piece.chop, Strike.Kind.SLASH, point, Strike.MAX_DAMAGE, fast)
	var after_fast := health.current if health else -1
	# Off the trunk's bark near the piece's lower end, on the side farthest from any bark.
	var off: Array = _off_bark(piece.chop, 0, (made[4] - 0.8) * segment, 0.3)
	var off_slash := _strike(piece.chop, Strike.Kind.SLASH, off[0], Strike.MAX_DAMAGE)
	_check(health != null and twig >= 0 and _judged(slash, TreeChop.Outcome.LONE, depth, nearest, -1, offset)
			and after_slow == 40 and kept and fast_slash.judged.get("outcome") == TreeChop.Outcome.LONE
			and after_fast == 30 and piece.piece.gone_branches()[twig] == 1 and off[1] > 0.1
			and off_slash.judged.get("outcome") == TreeChop.Outcome.LONE and health.current == 20,
			"on the oak of seed %d's lone piece, a full-strength slash on twig %d (depth %d) is judged LONE and takes its 10, wherever it lands: at %.1f m/s it leaves the twig on (%d left); at %.1f m/s it breaks it off as well, as any fast strike breaks a twig (%d left); so is one %.2f m off the bark, past the %.2f m a slash may be off it (%d left)"
			% [BLOCKED_SEED, twig, depth, slow, after_slow, fast, after_fast, off[1], 0.1,
			health.current if health else -1])
	_free_all(made[2] + made[3] + [tree])
	# The same piece again, for a blunt blow on its twig.
	made = await _lone_twig_piece()
	tree = made[0]
	piece = made[1]
	health = piece.chop.health
	to_strike = _twig_to_strike(piece.chop)
	twig = to_strike[0]
	var blunt := _strike(piece.chop, Strike.Kind.BLUNT, to_strike[1], Strike.MAX_DAMAGE, fast) if twig >= 0 \
			else Strike.new()
	_check(health != null and twig >= 0 and blunt.damage == Strike.MAX_DAMAGE
			and blunt.judged.get("outcome") == TreeChop.Outcome.TWIG_BROKEN
			and piece.piece.gone_branches()[twig] == 1 and health.current == 50,
			"a full-strength blunt blow at %.1f m/s on that twig of the same piece, cut again, breaks it off (TWIG_BROKEN) and takes none of the health (%d damage, %d left)"
			% [fast, blunt.damage, health.current if health else -1])
	_free_all(made[2] + made[3] + [tree])


## The oak of seed BLOCKED_SEED cut down to the lone piece whose only line its
## limb's stub blocks (_test_lone_blocked), with the twigs growing from the
## stub: [the tree, the piece, the log cut off it, the tree's pieces, the
## blocked line's number].
func _lone_twig_piece() -> Array:
	var chop := await _add_tree(BLOCKED_SEED)
	var tree := chop.tree
	var blocked := _blocked_line(tree.skeleton, tree.species.collision_min_radius_m)
	var limb := blocked.y
	var limb_k := _first_choppable(chop, limb)
	var pieces := _pieces_of(tree)
	chop.preset(limb, limb_k, _through(chop.line_at(limb, limb_k)))
	chop.preset(0, blocked.x - 1, _through(chop.line_at(0, blocked.x - 1)))
	await process_frame
	var piece: FelledTree = pieces[1] if pieces.size() == 2 else null
	var logs := _pieces_of(piece.piece)
	piece.chop.preset(0, blocked.x + 1, _through(piece.chop.line_at(0, blocked.x + 1)))
	return [tree, piece, logs, pieces, blocked.x]


## A lone piece wakes what rests on it as it goes (2026-10-02 review: Jolt left a
## body asleep on a freed stump hanging in the air): a box asleep on the stump's
## cut face sleeps on as the stump takes slashes, is woken in the tick its health
## runs out, and falls to the floor below.
func _test_lone_wakes() -> void:
	var ground := _floor_body()
	root.add_child(ground)
	var chop := await _add_tree()
	var tree := chop.tree
	var segment := tree.skeleton.segment_length
	var pieces := _pieces_of(tree)
	chop.preset(0, 1, _through(chop.line_at(0, 1)))
	# Nothing else on the stump: the top goes.
	_free_all(pieces)
	var cut := tree.skeleton_transform() * tree.skeleton.sample_position(0, segment)
	var box := _crate(0.2, 2.0)
	box.position = cut + Vector3.UP * 0.11
	root.add_child(box)
	var ticks := 0
	while not box.sleeping and ticks < 4 * Engine.physics_ticks_per_second:
		await physics_frame
		ticks += 1
	var rest := box.global_position
	var point := _bark_point(chop, 0, 0.4 * segment)
	for blow in 4:
		_strike(chop, Strike.Kind.SLASH, point, Strike.MAX_DAMAGE)
		await physics_frame
	for tick in 10:
		await physics_frame
	_check(box.sleeping and absf(rest.y - cut.y - 0.1) < 0.01 and box.global_position.distance_to(rest) < 0.0001
			and chop.health != null and chop.health.current == 10,
			"a 2 kg box set down on the stump's cut face, %.3f m up, falls asleep there in %d ticks, and sleeps on, unmoved, as four full-strength slashes a tick apart take the stump to %d, and 10 ticks more"
			% [cut.y, ticks, chop.health.current if chop.health else -1])
	var logs := _drops_of(tree.get_node_or_null(^"LootDrop") as LootDrop)
	_strike(chop, Strike.Kind.SLASH, point, Strike.MAX_DAMAGE)
	var woken := not box.sleeping
	var queued := tree.is_queued_for_deletion()
	var still := -1
	for tick in Engine.physics_ticks_per_second:
		await physics_frame
		if still < 0 and box.linear_velocity.length() < 0.01 and rest.y - box.global_position.y > 0.1:
			still = tick + 1
	var fallen := rest.y - box.global_position.y
	_check(woken and queued and not is_instance_valid(tree) and still > 0 and absf(box.global_position.y - 0.1) < 0.02,
			"the slash that takes it to 0 wakes the box in that tick; the stump gone, the box falls %.3f m to the floor below, at rest %d ticks on (%.2f s)"
			% [fallen, still, still / float(Engine.physics_ticks_per_second)])
	_free_all(logs + [box, ground])


## A felled piece weighs by the segment (2026-10-02: "each segment (trunk root)
## should be 75kg and each branch segment should be 25kg"), set on the species,
## in place of a density by volume.
func _test_segment_masses() -> void:
	var fresh := TreeSpecies.new()
	var kept := true
	for path in [SPECIES, PINE, BIRCH]:
		var species: TreeSpecies = load(path)
		kept = kept and species.trunk_segment_mass_kg == fresh.trunk_segment_mass_kg \
				and species.branch_segment_mass_kg == fresh.branch_segment_mass_kg
	var by_volume := false
	for property in fresh.get_property_list():
		by_volume = by_volume or property.name == "wood_density_kg_m3"
	_check(fresh.trunk_segment_mass_kg == 75.0 and fresh.branch_segment_mass_kg == 25.0 and kept and not by_volume,
			"a felled piece weighs %.0f kg for each segment of trunk it holds and %.0f kg for each of any other branch (TreeSpecies' defaults, which the oak, the pine and the birch keep); wood_density_kg_m3, a mass by volume, is gone"
			% [fresh.trunk_segment_mass_kg, fresh.branch_segment_mass_kg])


## A piece cut off at a segment line holds only its own segments of wood
## (TreeSkeleton.wood_segments): split at each of the oak's trunk lines, and at
## limb 1's first line that is wood, the two pieces share the branch's segments.
func _test_piece_segments() -> void:
	var species: TreeSpecies = load(SPECIES)
	var min_radius := species.collision_min_radius_m
	var whole := TreeSkeletonBuilder.build(species, 0)
	var segment := whole.segment_length
	var cuts: Array[Vector2i] = []
	var span := whole.line_range(0)
	for k in range(span.x, span.y + 1):
		cuts.append(Vector2i(0, k))
	var limb := _thickest_limb(whole)
	var limb_span := whole.line_range(limb)
	for k in range(limb_span.x, limb_span.y + 1):
		if whole.line_is_wood(limb, k, min_radius):
			cuts.append(Vector2i(limb, k))
			break
	var shared := cuts.size() == span.y - span.x + 2
	var counts := PackedStringArray()
	for cut in cuts:
		var branch := cut.x
		var all := roundi(whole.branch_length(branch) / segment)
		var pieces := whole.split(branch, cut.y * segment)
		var lower := pieces[0].wood_segments(pieces[0].branch_with_id(whole.branch_id[branch]), min_radius)
		var upper := pieces[1].wood_segments(0, min_radius)
		# Every segment of the trunk and of limb 1 is wood: each piece holds as
		# many as it is segments long.
		shared = shared and whole.wood_segments(branch, min_radius) == all and lower == cut.y and upper == all - cut.y
		counts.append("%d + %d" % [lower, upper])
	var limb_k := cuts[cuts.size() - 1].y
	_check(shared,
			"split at each of trunk lines %d to %d, and at limb %d's line %d, each piece of the oak of seed 0 holds only its own segments of wood (TreeSkeleton.wood_segments): the stump as many as the line's number, the top the rest of the trunk's %d (%s); limb %d's stub and the limb cut off %s of its %d"
			% [span.x, span.y, limb, limb_k, whole.wood_segments(0, min_radius), ", ".join(counts.slice(0, counts.size() - 1)),
			limb, counts[counts.size() - 1], whole.wood_segments(limb, min_radius)])


## Every piece cut off weighs its segments of wood (FelledTree, 2026-10-02: "the
## weight of the new chunk should be the combined weight of all the connecting
## segments"): trunk_segment_mass_kg each on its trunk, branch_segment_mass_kg
## each on any other branch but a twig, which weighs nothing; weighed again as it
## is cut, so a cut's two pieces weigh what the piece did. The oak of seed 0 cut
## up: limb 1 off at its line 2, the limb's tip off at its last line, the top
## felled at line 1, a twig broken off it, and the top bucked at its line 2.
func _test_piece_weights() -> void:
	var chop := await _add_tree()
	var tree := chop.tree
	var min_radius := tree.species.collision_min_radius_m
	var pieces := _pieces_of(tree)
	var limb := _thickest_limb(tree.skeleton)
	var limb_k := _first_choppable(chop, limb)
	chop.preset(limb, limb_k, _through(chop.line_at(limb, limb_k)))
	var limb_piece: FelledTree = pieces[0] if pieces.size() == 1 else null
	var limb_weighed := _weighed(limb_piece)
	var tips := _pieces_of(limb_piece.piece)
	var tip_k := _last_choppable(limb_piece.chop, 0)
	limb_piece.chop.preset(0, tip_k, _through(limb_piece.chop.line_at(0, tip_k)))
	var tip: FelledTree = tips[0] if tips.size() == 1 else null
	var tip_weighed := _weighed(tip)
	var limb_left := _weighed(limb_piece)
	chop.preset(0, 1, _through(chop.line_at(0, 1)))
	var top: FelledTree = pieces[1] if pieces.size() == 2 else null
	var top_weighed := _weighed(top)
	# The twig on the top with the most segments thick enough to be wood.
	var skeleton := top.skeleton
	var twig := -1
	for branch in skeleton.branch_count():
		if skeleton.is_twig(branch, min_radius) and (twig < 0
				or skeleton.wood_segments(branch, min_radius) > skeleton.wood_segments(twig, min_radius)):
			twig = branch
	var twig_id := skeleton.branch_id[twig] if twig >= 0 else -1
	var twig_wood := skeleton.wood_segments(twig, min_radius) if twig >= 0 else -1
	var also := skeleton.subtree_end(twig) - twig - 1 if twig >= 0 else 0
	var with_it := _leaves_from(skeleton, twig) if twig >= 0 else 0
	var clusters := top.leaves_left()
	top.piece.break_branch(twig)
	await process_frame
	var twig_gone := twig >= 0 and top.piece.gone_branches()[twig] == 1 and top.leaves_left() == clusters - with_it
	var after_twig := _weighed(top)
	var rests := _pieces_of(top.piece)
	top.chop.preset(0, 2, _through(top.chop.line_at(0, 2)))
	var rest: FelledTree = rests[0] if rests.size() == 1 else null
	var log_weighed := _weighed(top)
	var rest_weighed := _weighed(rest)
	var named := ["limb %d cut off at its line %d" % [limb, limb_k], "its tip cut off at line %d" % tip_k,
			"the top felled at line 1", "the one-segment log the top is left as, bucked at its line 2"]
	var parts := PackedStringArray()
	var right := true
	for index in named.size():
		var weighed: Dictionary = [limb_weighed, tip_weighed, top_weighed, log_weighed][index]
		right = right and weighed.right
		parts.append("%s, %.0f kg (%d of trunk + %d of branch%s)" % [named[index], weighed.kg, weighed.trunk,
				weighed.other, "; its twigs' %d left out" % weighed.twigs if weighed.twigs > 0 else ""])
	_check(right and log_weighed.trunk == 1 and log_weighed.other == 0,
			"each piece cut off weighs its segments of wood, %.0f kg each of trunk + %.0f kg each of any other branch but a twig, which weighs nothing (at least 1 kg), its body and the physics engine alike: %s"
			% [tree.species.trunk_segment_mass_kg, tree.species.branch_segment_mass_kg, "; ".join(parts)])
	_check(limb_left.right and rest_weighed.right and limb_left.kg < limb_weighed.kg and log_weighed.kg < after_twig.kg
			and is_equal_approx(limb_weighed.kg, limb_left.kg + tip_weighed.kg)
			and is_equal_approx(after_twig.kg, log_weighed.kg + rest_weighed.kg),
			"weighed again as it is cut, a chunk weighs the segments joined to it: limb %d, %.0f kg, is its tip, %.0f kg, and the %.0f kg left; the top, %.0f kg, the one-segment log it is left as, %.0f kg, and the %.0f kg above its line 2"
			% [limb, limb_weighed.kg, tip_weighed.kg, limb_left.kg, after_twig.kg, log_weighed.kg, rest_weighed.kg])
	_check(twig_gone and after_twig.right and is_equal_approx(after_twig.mass, top_weighed.mass),
			"twig %d (depth %d), %d segments of it thick enough to be wood but no line to chop, broken off the felled top (break_branch) with %d more growing from it and their %d leaf clusters: the top weighed %.0f kg before and %.0f kg after, a twig weighing nothing"
			% [twig_id, skeleton.branch_depth[twig] if twig >= 0 else -1, twig_wood, also, with_it, top_weighed.mass,
			after_twig.mass])
	_free_all([rest, top, tip, limb_piece, tree])


## A piece with no segment of wood, only wood too thin to chop, still weighs the
## least a piece may, 1 kg: the sapling's top, cut off as nothing can chop it.
func _test_thin_piece_weight() -> void:
	var species := _sapling()
	var chop := await _add_tree(0, species)
	var tree := chop.tree
	var pieces := _pieces_of(tree)
	var segment := tree.skeleton.segment_length
	tree.sever(0, segment)
	var top: FelledTree = pieces[0] if pieces.size() == 1 else null
	var weighed := _weighed(top)
	var segments := roundi((top.skeleton.branch_length(0) - top.skeleton.distances[0]) / segment) if top else 0
	_check(top != null and weighed.trunk == 0 and weighed.other == 0 and weighed.right and top.mass == 1.0,
			"the sapling's top, cut off at line 1 (ProceduralTree.sever, as nothing can chop it): its %d segments of trunk, %.3f m thick at most, none of them wood, weigh the least a piece may, %.0f kg"
			% [segments, species.trunk.base_radius_m, top.mass if top else 0.0])
	_free_all(pieces + [tree])


## What `piece` weighs by the rule (FelledTree): its segments of wood on its
## trunk ("trunk") and on its other branches but twigs ("other"), and the kg
## they come to, at least 1 ("kg"); its twigs' segments thick enough to be wood,
## left out ("twigs"); its body's mass ("mass"); and whether the body and the
## physics engine have the kg ("right").
static func _weighed(piece: FelledTree) -> Dictionary:
	if piece == null:
		return {"trunk": -1, "other": -1, "kg": 0.0, "twigs": 0, "mass": 0.0, "right": false}
	var skeleton := piece.skeleton
	var species := piece.species
	var min_radius := species.collision_min_radius_m
	var counts := Vector3i.ZERO
	for branch in skeleton.branch_count():
		var wood := skeleton.wood_segments(branch, min_radius)
		if skeleton.is_twig(branch, min_radius):
			counts.z += wood
		elif skeleton.branch_depth[branch] == 0:
			counts.x += wood
		else:
			counts.y += wood
	var kg := maxf(species.trunk_segment_mass_kg * counts.x + species.branch_segment_mass_kg * counts.y, 1.0)
	var engine: float = PhysicsServer3D.body_get_param(piece.get_rid(), PhysicsServer3D.BODY_PARAM_MASS)
	return {"trunk": counts.x, "other": counts.y, "kg": kg, "twigs": counts.z, "mass": piece.mass,
			"right": is_equal_approx(piece.mass, kg) and is_equal_approx(engine, kg)}


## The logs and sticks a lone piece drops (2026-10-02: "the stick and log loot
## should have some angular damp so they dont roll away forever. The stick should
## be maybe 2.5kg and the logs can be 8kg"): their scenes weigh and damp them, and
## the level's own log and stick keep that.
func _test_loot_weights() -> void:
	var found := {}
	for path in [LOG, STICK]:
		var item := (load(path) as PackedScene).instantiate() as RigidBody3D
		found[path] = Vector4(item.mass, item.angular_damp, item.angular_damp_mode, 1.0) if item else Vector4.ZERO
		if item:
			item.free()
	# The level's own logs and sticks, and what they set over their scene.
	var state := (load(LEVEL) as PackedScene).get_state()
	var level_logs := PackedStringArray()
	var level_sticks := PackedStringArray()
	var overridden := PackedStringArray()
	for node in state.get_node_count():
		var instance := state.get_node_instance(node)
		var path := instance.resource_path if instance else ""
		if path == LOG:
			level_logs.append(state.get_node_name(node))
		elif path == STICK:
			level_sticks.append(state.get_node_name(node))
		else:
			continue
		for property in state.get_node_property_count(node):
			var name := state.get_node_property_name(node, property)
			if name in [&"mass", &"angular_damp", &"angular_damp_mode"]:
				overridden.append("%s sets %s" % [state.get_node_name(node), name])
	var log: Vector4 = found[LOG]
	var stick: Vector4 = found[STICK]
	var combine := float(RigidBody3D.DAMP_MODE_COMBINE)
	_check(log == Vector4(8.0, 1.0, combine, 1.0) and stick == Vector4(2.5, 6.0, combine, 1.0)
			and not level_logs.is_empty() and not level_sticks.is_empty() and overridden.is_empty(),
			"a log weighs %.1f kg and a stick %.1f kg (log.tscn, stick.tscn), each damped against rolling on: angular damp %.1f on the log and %.1f on the stick, added to the world's (COMBINE); the level's own (%s) override none of it%s"
			% [log.x, stick.x, log.y, stick.y, ", ".join(level_logs + level_sticks),
			"" if overridden.is_empty() else " (but %s)" % ", ".join(overridden)])


## Fall damage (2026-10-03: "When branches impact the ground, they should damage
## and depending on the impact, they should break their segments"; "apply the
## damage of the max health of that segment, so it always breaks"): a hit
## closing at impact_speed or faster on a felled piece's branch marks that
## branch's line nearest the hit to break (TreeChop.impact), the nearest that can
## be chopped however far off, and only once; the line being chopped stays the
## readout's. Never the trunk, a twig, a branch that is gone, a lone piece or a
## standing tree, nor under impact_speed. The oak of seed 0 felled at line 1, the
## top held still (frozen), its stump gone and its upper limb's tip cut off.
func _test_impacts() -> void:
	var chop := await _add_tree()
	var tree := chop.tree
	var whole := tree.skeleton
	var segment := whole.segment_length
	var min_radius := tree.species.collision_min_radius_m
	var limb_id := whole.branch_id[_thickest_limb(whole)]
	var upper_id := whole.branch_id[_highest_limb(whole)]
	var standing_lines := chop.lines.size()
	var standing := chop.impact(_out_from(chop, _thickest_limb(whole), 3 * segment), 5.0, _thickest_limb(whole))
	var standing_kept := chop.lines.size() == standing_lines
	var tops := _pieces_of(tree)
	chop.preset(0, 1, _through(chop.line_at(0, 1)))
	var top: FelledTree = tops[0] if tops.size() == 1 else null
	_free_all([tree])
	top.freeze = true
	var wood := top.piece
	var skeleton := top.skeleton
	var limb := skeleton.branch_with_id(limb_id)
	var upper := skeleton.branch_with_id(upper_id)
	# The upper limb's tip cut off at its last line, lone once the frame is over.
	var tips := _pieces_of(wood)
	var tip_k := _last_choppable(top.chop, upper)
	top.chop.preset(upper, tip_k, _through(top.chop.line_at(upper, tip_k)))
	await process_frame
	var tip: FelledTree = tips[0] if tips.size() == 1 else null
	var chopping := top.chop.preset(0, 3, PackedInt32Array([5]))
	var told := []
	top.chop.changed.connect(func(line: TreeChop.Line) -> void: told.append(line))
	var hits := []
	top.chop.impacted.connect(func(line: TreeChop.Line, speed: float) -> void: hits.append([line, speed]))
	var first := _first_choppable(top.chop, limb)
	var inside := (first - 1) * segment
	var marked := top.chop.impact(_out_from(top.chop, limb, inside), 3.0, limb)
	var line: TreeChop.Line = top.chop.lines.get(Vector2i(limb_id, first))
	_check(marked and line != null and line.broken_by == 3.0 and hits.size() == 1 and hits[0] == [line, 3.0]
			and not top.chop.choppable(limb, first - 1) and top.chop.current == chopping and told.is_empty(),
			"a hit at 3.0 m/s on limb %d of the felled top, on its bark %.2f m along it, where its line %d can't be chopped (inside its junction), marks line %d, the nearest that can, %.2f m off, past a slash's band: impact() true, broken_by %.1f, impacted told once, with that line and speed; trunk line 3, being chopped, stays the line the readout shows (changed told nothing)"
			% [limb_id, inside, first - 1, first, segment, line.broken_by if line else 0.0])
	var again := top.chop.impact(_out_from(top.chop, limb, inside), 6.0, limb)
	var on_line := top.chop.impact(_out_from(top.chop, limb, first * segment), 6.0, limb)
	_check(not again and not on_line and line != null and line.broken_by == 3.0 and hits.size() == 1,
			"once: a second hit there at 6.0 m/s, and one right on line %d, mark nothing (false); its broken_by stays %.1f, nothing told"
			% [first, line.broken_by if line else 0.0])
	var between := (first + 1.6) * segment
	var last := _last_choppable(top.chop, limb)
	var nearer := top.chop.impact(_out_from(top.chop, limb, between), 2.5, limb)
	var far := top.chop.impact(_out_from(top.chop, limb, last * segment, 0.5), 4.0, limb)
	var marks := {}
	for key: Vector2i in top.chop.lines:
		var each: TreeChop.Line = top.chop.lines[key]
		if key.x == limb_id and each.broken_by > 0.0:
			marks[key.y] = each.broken_by
	_check(nearer and far and marks == {first: 3.0, first + 2: 2.5, last: 4.0} and hits.size() == 3,
			"the line marked is the choppable one nearest the hit along the branch, however far off: a hit %.2f m along limb %d, 0.6 of the way from line %d to %d, marks line %d (2.5 m/s); one 0.5 m off its bark at line %d marks line %d (4.0 m/s); line %d, nearest neither, stays unmarked: %s"
			% [between, limb_id, first + 1, first + 2, first + 2, last, last, first + 1, marks])
	var lines := top.chop.lines.size()
	var counted := hits.size()
	var on_trunk := top.chop.impact(_out_from(top.chop, 0, 4 * segment), 5.0, 0)
	var twig := _woodiest_twig(skeleton, min_radius)
	var on_twig := true
	if twig >= 0:
		var twig_base := skeleton.distances[skeleton.branch_first_node[twig]]
		on_twig = top.chop.impact(_out_from(top.chop, twig, (twig_base + skeleton.branch_length(twig)) * 0.5), 5.0, twig)
	wood._gone[upper] = 1
	var on_gone := top.chop.impact(_out_from(top.chop, upper, segment), 5.0, upper)
	wood._gone[upper] = 0
	_check(not on_trunk and twig >= 0 and not on_twig and not on_gone and top.chop.lines.size() == lines
			and hits.size() == counted,
			"on the felled top nothing is marked (false, no line made, nothing told) at 5.0 m/s on its trunk (at line 4), on a twig (branch %d, depth %d: %d segments of wood but no line to chop), or on limb %d gone from it (its gone flag set, as break_branch sets a twig's)"
			% [twig, skeleton.branch_depth[twig] if twig >= 0 else -1,
			skeleton.wood_segments(twig, min_radius) if twig >= 0 else -1, upper_id])
	var on_tip := true
	if tip:
		var tip_base := tip.skeleton.distances[0]
		on_tip = tip.chop.impact(_out_from(tip.chop, 0, (tip_base + tip.skeleton.branch_length(0)) * 0.5), 5.0, 0)
	_check(tip != null and tip.chop.health != null and not on_tip and tip.chop.lines.is_empty() and not standing
			and standing_kept,
			"nor on limb %d's tip, cut off at its line %d and lone (health %d), nor on the standing tree (limb %d, at its line 3, 5.0 m/s)"
			% [upper_id, tip_k, tip.chop.health.maximum if tip and tip.chop.health else -1, limb_id])
	var slow_at := _out_from(top.chop, upper, 2 * segment)
	var slow_speed := top.chop.impact_speed - 0.01
	var slow := top.chop.impact(slow_at, slow_speed, upper)
	var slow_kept := top.chop.lines.size() == lines and hits.size() == counted
	var just := top.chop.impact(slow_at, top.chop.impact_speed, upper)
	var just_line: TreeChop.Line = top.chop.lines.get(Vector2i(upper_id, 2))
	_check(not slow and slow_kept and just and just_line != null and just_line.broken_by == top.chop.impact_speed
			and hits.size() == counted + 1 and top.chop.impact_speed == ProceduralTree.BREAK_SPEED,
			"under impact_speed (%.1f m/s by default, as fast as breaks a twig) nothing: a hit at %.2f m/s on limb %d's line 2 marks nothing; one at %.2f m/s marks it"
			% [top.chop.impact_speed, slow_speed, upper_id, top.chop.impact_speed])
	_free_all([tip, top])


## A line an impact marked breaks (TreeChop.break_next): opened all round to its
## total and cut through there, as slashes cut it; at most IMPACT_CUTS_PER_TICK
## (one) such cut a physics tick across every tree, the rest waiting their turn;
## and a marked line a cut hands to the piece cut off breaks there. Two oaks of
## seed 0 felled at line 1, each top held still (frozen), their stumps gone.
func _test_impact_breaks() -> void:
	var chop := await _add_tree()
	var twin_chop := await _add_tree()
	twin_chop.tree.position = Vector3(30.0, 0.0, 0.0)
	var whole := chop.tree.skeleton
	var segment := whole.segment_length
	var limb_id := whole.branch_id[_thickest_limb(whole)]
	var upper_id := whole.branch_id[_highest_limb(whole)]
	var tops := _pieces_of(chop.tree)
	var twin_tops := _pieces_of(twin_chop.tree)
	chop.preset(0, 1, _through(chop.line_at(0, 1)))
	twin_chop.preset(0, 1, _through(twin_chop.line_at(0, 1)))
	var top: FelledTree = tops[0] if tops.size() == 1 else null
	var twin: FelledTree = twin_tops[0] if twin_tops.size() == 1 else null
	_free_all([chop.tree, twin_chop.tree])
	top.freeze = true
	twin.freeze = true
	var limb := top.skeleton.branch_with_id(limb_id)
	var k := _first_choppable(top.chop, limb) + 1
	var key := Vector2i(limb_id, k)
	var idle := top.chop.break_next()
	var cuts := _cuts_of(top.piece)
	var twin_pieces := _pieces_of(twin.piece)
	var marked := top.chop.impact(_out_from(top.chop, limb, k * segment), 3.0, limb)
	var line: TreeChop.Line = top.chop.lines.get(key)
	var broke := top.chop.break_next()
	var tick := Engine.get_physics_frames()
	twin.chop.preset(limb, k, _through(twin.chop.line_at(limb, k)))
	var piece: FelledTree = cuts[0][0] if cuts.size() == 1 else null
	var twin_piece: FelledTree = twin_pieces[0] if twin_pieces.size() == 1 else null
	_check(not idle and marked and broke and line != null and line.open == line.total and piece != null
			and not top.chop.lines.has(key) and not piece.chop.lines.has(key) and piece.skeleton.branch_id[0] == limb_id
			and is_equal_approx(piece.skeleton.distances[0], k * segment) and _same_pieces(top, twin)
			and _same_pieces(piece, twin_piece),
			"with nothing marked, break_next() breaks nothing (false); an impact marking limb %d's line %d on a felled top, it breaks it at once (true): opened to its %d and cut through, the limb from %.2f m along it a piece of its own (%.0f kg), the line on neither piece; the same two pieces, skeletons and weights, as slashes cutting it through give on a second top (preset)"
			% [limb_id, k, line.total if line else -1, k * segment, piece.mass if piece else 0.0])
	if piece == null:
		_free_pieces()
		return
	var upper := top.skeleton.branch_with_id(upper_id)
	var limb_cuts := _cuts_of(piece.piece)
	var on_top := top.chop.impact(_out_from(top.chop, upper, 2 * segment), 3.0, upper)
	var on_limb := piece.chop.impact(_out_from(piece.chop, 0, (k + 1) * segment), 3.0, 0)
	var held := piece.chop.break_next()
	for frame in 4:
		await physics_frame
	var ticks := PackedInt32Array()
	for cut: Array in cuts.slice(1) + limb_cuts:
		ticks.append(cut[1])
	ticks.sort()
	_check(on_top and on_limb and not held and cuts.size() == 2 and limb_cuts.size() == 1
			and ticks == PackedInt32Array([tick + 1, tick + 2]),
			"two more lines marked in that tick, on two pieces (limb %d's line 2 on the top, line %d on the limb cut off): the limb's break_next() breaks nothing then (false), that tick's cut spent; they break one a tick, in the next two (ticks %s, after tick %d)"
			% [upper_id, k + 1, ticks, tick])
	var twin_upper := twin.skeleton.branch_with_id(upper_id)
	var far_key := Vector2i(upper_id, 3)
	var marked_far := twin.chop.impact(_out_from(twin.chop, twin_upper, 3 * segment), 3.0, twin_upper)
	twin.chop.preset(twin_upper, 2, _through(twin.chop.line_at(twin_upper, 2)))
	var carrier: FelledTree = twin_pieces[1] if twin_pieces.size() == 2 else null
	var carried: TreeChop.Line = carrier.chop.lines.get(far_key) if carrier else null
	var carried_by := carried.broken_by if carried else 0.0
	var off_carrier: Array[FelledTree] = []
	if carrier:
		off_carrier = _pieces_of(carrier.piece)
	for frame in 3:
		await physics_frame
	var broken: FelledTree = off_carrier[0] if off_carrier.size() == 1 else null
	_check(marked_far and carried != null and carried_by == 3.0 and not twin.chop.lines.has(far_key)
			and broken != null and broken.skeleton.branch_id[0] == upper_id
			and is_equal_approx(broken.skeleton.distances[0], 3 * segment) and not carrier.chop.lines.has(far_key),
			"a marked line handed on by a cut breaks where it is: limb %d's line 3 marked on the second top, which slashes then cut through at line 2, goes with the limb cut off, still marked (%.1f m/s), which breaks there by itself within a tick or two, the tip from %.2f m along it"
			% [upper_id, carried_by, 3 * segment])
	_free_pieces()


## A contact names the shape of a body it touched by its index there:
## ProceduralTree.branch_of_shape gives the branch whose wood that shape is, -1
## for an index off the body. TreeSkeleton.nearest_on, which nearest() now asks
## of each branch, gives what nearest() finds for the branch it finds. The oak
## of seed 0's top, felled at line 1.
func _test_shape_branches() -> void:
	var chop := await _add_tree()
	var tree := chop.tree
	var tops := _pieces_of(tree)
	chop.preset(0, 1, _through(chop.line_at(0, 1)))
	var top: FelledTree = tops[0] if tops.size() == 1 else null
	_free_all([tree])
	var wood := top.piece
	var skeleton := top.skeleton
	var to_skeleton := wood.skeleton_transform().affine_inverse()
	var rid := top.get_rid()
	var count := PhysicsServer3D.body_get_shape_count(rid)
	var named := 0
	var worst := 0.0
	var branches := {}
	for index in count:
		var shape := PhysicsServer3D.body_get_shape(rid, index)
		var data: Dictionary = PhysicsServer3D.shape_get_data(shape)
		var half: float = data.height * 0.5
		if PhysicsServer3D.shape_get_type(shape) == PhysicsServer3D.SHAPE_CAPSULE:
			half -= data.radius
		var place := top.global_transform * PhysicsServer3D.body_get_shape_transform(rid, index)
		# The branch whose path both ends of the shape's axis lie on.
		var best := -1
		var best_off := INF
		for branch in skeleton.branch_count():
			var off := 0.0
			for end: Vector3 in [place * (Vector3.UP * half), place * (Vector3.DOWN * half)]:
				var on := skeleton.nearest_on(branch, to_skeleton * end)
				off = maxf(off, absf(on.y + skeleton.sample_radius(branch, on.x)))
			if off < best_off:
				best = branch
				best_off = off
		if wood.branch_of_shape(index) == best:
			named += 1
		worst = maxf(worst, best_off)
		branches[best] = true
	_check(count > 0 and named == count and worst < 0.001 and wood.branch_of_shape(-1) == -1
			and wood.branch_of_shape(count) == -1,
			"each of the felled top's %d wood shapes, by its index on the body, names the branch it was built along (%d branches in all): the one whose path both ends of its axis lie on (%.4f mm off at most); index -1 and index %d name none (-1)"
			% [count, branches.size(), worst * 1000.0, count])
	var bounds := AABB(skeleton.positions[0], Vector3.ZERO)
	for position in skeleton.positions:
		bounds = bounds.expand(position)
	bounds = bounds.grow(0.5)
	var random := RandomNumberGenerator.new()
	random.seed = 7
	var points := 300
	var same := 0
	var none_nearer := true
	for point_index in points:
		var point := bounds.position + bounds.size * Vector3(random.randf(), random.randf(), random.randf())
		var found := skeleton.nearest(point)
		if skeleton.nearest_on(int(found.x), point) == Vector2(found.y, found.z):
			same += 1
		for branch in skeleton.branch_count():
			none_nearer = none_nearer and skeleton.nearest_on(branch, point).y >= found.z
	_check(same == points and none_nearer,
			"for each of %d points in and round the felled top, nearest_on() gives the branch nearest() finds the same distance along it and gap off its bark (%d of %d), and no branch's bark is nearer by it"
			% [points, same, points])
	_free_all([top])


## A part cut off a moving piece moves on as it was (ProceduralTree.sever,
## 2026-10-03): each part at the velocity the whole had at the point its centre
## of mass is at (FelledTree.centre_of_mass, already where the new shapes put it
## in the tick of the cut), spinning as the whole did, so the cut's faces
## move on together, as one body's did. A felled top set spinning in the air,
## gravity off, its stump gone, cut at limb 1's line 3 by an impact.
func _test_velocity_handoff() -> void:
	var chop := await _add_tree()
	var tree := chop.tree
	var limb_id := tree.skeleton.branch_id[_thickest_limb(tree.skeleton)]
	var tops := _pieces_of(tree)
	chop.preset(0, 1, _through(chop.line_at(0, 1)))
	var top: FelledTree = tops[0] if tops.size() == 1 else null
	_free_all([tree])
	top.gravity_scale = 0.0
	# Past the tick it starts tipping over in.
	var ticks := 0
	while top._toward != Vector3.ZERO and ticks < 10:
		await physics_frame
		ticks += 1
	await physics_frame
	top.linear_velocity = Vector3(0.6, 0.4, -0.3)
	top.angular_velocity = Vector3(0.8, -1.2, 0.5)
	await physics_frame
	var state := PhysicsServer3D.body_get_direct_state(top.get_rid())
	var centre := top.global_position + state.center_of_mass
	var velocity := top.linear_velocity
	var spin := top.angular_velocity
	var limb := top.skeleton.branch_with_id(limb_id)
	var k := _first_choppable(top.chop, limb) + 1
	var point := top.chop.centre(top.chop.line_at(limb, k))
	var whole_there := velocity + spin.cross(point - centre)
	var pieces := _pieces_of(top.piece)
	var cut := top.chop.impact(point, 3.0, limb) and top.chop.break_next()
	var piece: FelledTree = pieces[0] if pieces.size() == 1 else null
	if not cut or piece == null:
		_check(false, "a spinning felled top cut at limb %d's line %d by an impact: it broke there (%s, %d pieces)"
				% [limb_id, k, cut, pieces.size()])
		_free_pieces()
		return
	var centres := [top.centre_of_mass(), piece.centre_of_mass()]
	var off := 0.0
	var spun := true
	var copied := 0.0
	var engine_off := 0.0
	var local_centres := []
	for index in 2:
		var body: FelledTree = [top, piece][index]
		var there := body.linear_velocity + body.angular_velocity.cross(point - centres[index])
		off = maxf(off, there.distance_to(whole_there))
		spun = spun and body.angular_velocity.is_equal_approx(spin)
		# Each part kept the whole's velocity, as before.
		copied = maxf(copied, (velocity + spin.cross(point - centres[index])).distance_to(whole_there))
		local_centres.append(body.global_transform.affine_inverse() * centres[index])
	await physics_frame
	for index in 2:
		var body: FelledTree = [top, piece][index]
		var engine := PhysicsServer3D.body_get_direct_state(body.get_rid()).center_of_mass_local
		engine_off = maxf(engine_off, engine.distance_to(local_centres[index]))
	_check(off < 0.02 and spun and engine_off < 0.001 and copied > 10.0 * maxf(off, 0.02),
			"a felled top spinning at %.2f rad/s and moving at %.2f m/s, gravity off, cut at limb %d's line %d by an impact (break_next): the top and the limb cut off each move at the line's middle as the whole did there (%.2f m/s), within %.4f m/s, each spinning as it did about its own centre of mass, where the engine puts it a tick on (within %.4f mm); keeping the whole's velocity, as before, they were %.2f m/s off there"
			% [spin.length(), velocity.length(), limb_id, k, whole_there.length(), off, engine_off * 1000.0, copied])
	_free_pieces()


## A felled piece's fall (fall damage): limb 1, cut off at its first line, comes
## to rest unbroken on a floor on the Static layer, then is let go above it. From
## 0.08 m it lands too slowly to break; struck by a 2 kg crate (a prop, on the
## Dynamic layer) at 4 m/s, twice impact_speed, it breaks nothing, as only
## something solid breaks it; from 0.5 m it lands at about 3 m/s and breaks at a
## line.
func _test_drops() -> void:
	var errors := _ErrorCounter.new()
	OS.add_logger(errors)
	var ground := _floor_body()
	root.add_child(ground)
	var chop := await _add_tree()
	var tree := chop.tree
	var limb := _thickest_limb(tree.skeleton)
	var limb_id := tree.skeleton.branch_id[limb]
	var limb_k := _first_choppable(chop, limb)
	var pieces := _pieces_of(tree)
	chop.preset(limb, limb_k, _through(chop.line_at(limb, limb_k)))
	var piece: FelledTree = pieces[0] if pieces.size() == 1 else null
	_free_all([tree])
	# Down from the tree to the floor without fall damage.
	var impact_speed := piece.chop.impact_speed
	piece.chop.impact_speed = 100.0
	var settled := await _rest(piece, 6.0)
	piece.chop.impact_speed = impact_speed
	var lines := _choppable_lines(piece.chop)
	var hits := []
	piece.chop.impacted.connect(func(line: TreeChop.Line, speed: float) -> void: hits.append([line.id, line.k, speed]))
	var cuts := _pieces_of(piece.piece)
	var low := await _drop(piece, 0.08, 36)
	var again := await _rest(piece, 2.0)
	_check(piece.sleeping and hits.is_empty() and cuts.is_empty() and _choppable_lines(piece.chop) == lines,
			"limb %d cut off at its line %d comes to rest on the floor in %d ticks (no fall damage on its way down); lifted 0.08 m and let go, it lands at %.2f m/s (its centre's fastest) and breaks nothing, at rest again %d ticks on, its %d lines left to chop"
			% [limb_id, limb_k, settled, low, again + 36, lines.size()])
	var segment := piece.skeleton.segment_length
	var span := piece.skeleton.line_range(0)
	var at := floori((span.x + span.y) / 2.0) * segment
	var place := piece.piece.skeleton_transform()
	var target := place * piece.skeleton.sample_position(0, at)
	var crate := _crate(0.2, 2.0)
	crate.gravity_scale = 0.0
	crate.max_contacts_reported = 4
	crate.position = target + Vector3.UP * (piece.skeleton.sample_radius(0, at) * place.basis.get_scale().x + 0.25)
	root.add_child(crate)
	crate.linear_velocity = Vector3.DOWN * 4.0
	var struck := {}
	for tick in 18:
		await physics_frame
		var state := PhysicsServer3D.body_get_direct_state(crate.get_rid())
		for contact in state.get_contact_count():
			if state.get_contact_collider_object(contact) == piece:
				var branch := piece.piece.branch_of_shape(state.get_contact_collider_shape(contact))
				struck[piece.skeleton.branch_id[branch] if branch >= 0 else -1] = true
	var bounced := crate.linear_velocity.y
	crate.free()
	_check(not struck.is_empty() and bounced > -1.0 and hits.is_empty() and cuts.is_empty()
			and _choppable_lines(piece.chop) == lines,
			"a 2 kg crate, a prop on the Dynamic layer, sent down at 4.0 m/s (impact_speed is %.1f) onto the lying limb %.2f m along it meets its wood (branch %s) and is stopped there (%.2f m/s after), but breaks nothing: only something solid breaks a piece's branches"
			% [impact_speed, at, struck.keys(), bounced])
	await _rest(piece, 3.0)
	var high := await _drop(piece, 0.5, 48)
	var first_hit: Array = hits[0] if not hits.is_empty() else [-1, -1, 0.0]
	_check(hits.size() >= 1 and cuts.size() >= 1 and first_hit[2] >= impact_speed,
			"lifted 0.5 m and let go, it lands at %.2f m/s and breaks: its first hit marks branch %d's line %d at %.2f m/s; %d lines broken off it in 48 ticks (branch:line, %s)"
			% [high, first_hit[0], first_hit[1], first_hit[2], cuts.size(),
			", ".join(hits.map(func(hit: Array) -> String: return "%d:%d at %.2f m/s" % hit))])
	_free_pieces()
	ground.free()
	await process_frame
	OS.remove_logger(errors)
	_check(errors.count == 0,
			"no engine errors as the limb is cut off, comes to rest, is dropped, struck by the crate and broken by its fall, and its pieces freed (%d)"
			% errors.count)


static func _centre_of_mass(body: RigidBody3D) -> Vector3:
	return body.global_position + PhysicsServer3D.body_get_direct_state(body.get_rid()).center_of_mass


## The thickest of a skeleton's limbs.
static func _thickest_limb(skeleton: TreeSkeleton) -> int:
	var thickest := -1
	for branch in skeleton.branch_count():
		if skeleton.branch_depth[branch] == 1 and (thickest < 0
				or skeleton.branch_base_radius[branch] > skeleton.branch_base_radius[thickest]):
			thickest = branch
	return thickest


## The limb joining the trunk highest up.
static func _highest_limb(skeleton: TreeSkeleton) -> int:
	var highest := -1
	for branch in skeleton.branch_count():
		if skeleton.branch_depth[branch] == 1 and (highest < 0
				or skeleton.branch_attach_distance[branch] > skeleton.branch_attach_distance[highest]):
			highest = branch
	return highest


## The last line along `branch` that can be chopped, or -1.
static func _last_choppable(chop: TreeChop, branch: int) -> int:
	var span := chop.tree.skeleton.line_range(branch)
	for k in range(span.y, span.x - 1, -1):
		if chop.choppable(branch, k):
			return k
	return -1


## Every line on `chop`'s tree that can be chopped, as Vector2i(branch, k).
static func _choppable_lines(chop: TreeChop) -> Array[Vector2i]:
	var found: Array[Vector2i] = []
	var skeleton := chop.tree.skeleton
	for branch in skeleton.branch_count():
		var span := skeleton.line_range(branch)
		for k in range(span.x, span.y + 1):
			if chop.choppable(branch, k):
				found.append(Vector2i(branch, k))
	return found


## The trunk's first line that is wood but that a limb's junction crosses, and
## that limb, as Vector2i(k, limb); (-1, -1) if there is none.
static func _blocked_line(skeleton: TreeSkeleton, min_radius: float) -> Vector2i:
	var span := skeleton.line_range(0)
	for k in range(span.x, span.y + 1):
		if not skeleton.line_is_wood(0, k, min_radius):
			continue
		var at := k * skeleton.segment_length
		for child in range(1, skeleton.branch_count()):
			var across := skeleton.junction_span(child)
			if skeleton.branch_parent[child] == 0 and across.x < at and at < across.y:
				return Vector2i(k, child)
	return Vector2i(-1, -1)


## Slashes `chop`'s lone piece at `point` at full strength until its health is
## gone: how many slashes it took (at most 10).
func _break(chop: TreeChop, point: Vector3) -> int:
	var blows := 0
	while chop.health != null and chop.health.current > 0 and blows < 10:
		_strike(chop, Strike.Kind.SLASH, point, Strike.MAX_DAMAGE)
		blows += 1
	return blows


## What `drop` drops, as it drops it.
static func _drops_of(drop: LootDrop) -> Array[Node3D]:
	var items: Array[Node3D] = []
	if drop:
		drop.dropped.connect(func(dropped: Array[Node3D]) -> void: items.append_array(dropped))
	return items


## How `items` lie round `middle`: the ring LootDrop lays that many on, a spacing
## (two of an item's reach and `gap`) between neighbours ("ring"); the most any
## is off that ring, out or up ("off"); the least distance between two
## ("apart"); and an item's reach ("reach").
static func _ring_of(items: Array[Node3D], middle: Vector3, gap: float) -> Dictionary:
	if items.is_empty():
		return {"ring": 0.0, "off": INF, "apart": 0.0, "reach": 0.0}
	var reach := LootDrop._reach(items[0])
	var ring := (2.0 * reach + gap) / (2.0 * sin(PI / items.size())) if items.size() > 1 else 0.0
	var off := 0.0
	var apart := INF
	for a in items.size():
		var offset := items[a].global_position - middle
		off = maxf(off, maxf(absf(Vector2(offset.x, offset.z).length() - ring), absf(offset.y)))
		for b in range(a + 1, items.size()):
			apart = minf(apart, items[a].global_position.distance_to(items[b].global_position))
	return {"ring": ring, "off": off, "apart": apart, "reach": reach}


## How `items` lie round `middle`: the most any one's length (its Y) is off level
## (x), and off square to the line out from the middle (y).
static func _lying(items: Array[Node3D], middle: Vector3) -> Vector2:
	var lying := Vector2.INF if items.is_empty() else Vector2.ZERO
	for item in items:
		var length := item.global_basis.y.normalized()
		var out := item.global_position - middle
		out.y = 0.0
		lying = Vector2(maxf(lying.x, absf(length.y)), maxf(lying.y, absf(length.dot(out.normalized()))))
	return lying


## A point `off` metres out from `branch`'s bark `distance` along it, in the
## world, on the side round it farthest from any bark (TreeSkeleton.nearest):
## [the point, how far it is off the nearest bark, in the tree's own metres].
func _off_bark(chop: TreeChop, branch: int, distance: float, off: float) -> Array:
	var tree := chop.tree
	var skeleton := tree.skeleton
	var frame := skeleton.sample_frame(branch, distance)
	var centre := skeleton.sample_position(branch, distance)
	var reach := skeleton.sample_radius(branch, distance) + off
	var best := [Vector3.INF, -INF]
	for step in 16:
		var local := centre + frame[1].rotated(frame[0], (step + 0.5) * TAU / 16) * reach
		var gap := skeleton.nearest(local, tree.gone_branches()).z
		if gap > best[1]:
			best = [tree.skeleton_transform() * local, gap]
	return best


## A wide floor on the Static layer, its top at the trees' base.
static func _floor_body() -> StaticBody3D:
	var ground := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20.0, 1.0, 20.0)
	shape.shape = box
	ground.add_child(shape)
	ground.position = Vector3.DOWN * 0.5
	return ground


## A box `size` metres a side, of `mass` kg, on the Dynamic layer, meeting the
## level and other props.
static func _crate(size: float, mass: float) -> RigidBody3D:
	var crate := RigidBody3D.new()
	crate.mass = mass
	crate.collision_layer = ProceduralTree.DYNAMIC_LAYER
	crate.collision_mask = ProceduralTree.STATIC_LAYER | ProceduralTree.DYNAMIC_LAYER
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3.ONE * size
	shape.shape = box
	crate.add_child(shape)
	return crate


## Whether `item`'s shapes, where it is, meet `body`.
static func _meets(item: Node3D, body: CollisionObject3D) -> bool:
	var solid := item as CollisionObject3D
	if solid == null or not is_instance_valid(body):
		return false
	var query := PhysicsShapeQueryParameters3D.new()
	query.collision_mask = body.collision_layer
	query.exclude = [solid.get_rid()]
	for child in solid.get_children():
		var shape := child as CollisionShape3D
		if shape == null or shape.shape == null:
			continue
		query.shape = shape.shape
		query.transform = solid.global_transform * shape.transform
		for hit: Dictionary in solid.get_world_3d().direct_space_state.intersect_shape(query, 32):
			if hit.collider == body:
				return true
	return false


## Frees each of `nodes` still there, once.
static func _free_all(nodes: Array) -> void:
	var freed := {}
	for node: Variant in nodes:
		if is_instance_valid(node) and not freed.has(node):
			freed[node] = true
			(node as Node).free()


## Frees every felled piece left in the scene, those cut off pieces too.
func _free_pieces() -> void:
	_free_all(root.get_children().filter(func(node: Node) -> bool: return node is FelledTree))


## The pieces cut off `tree`, as they come, each with the physics tick it was
## cut in: [piece, tick].
static func _cuts_of(tree: ProceduralTree) -> Array:
	var cuts := []
	tree.severed.connect(func(piece: FelledTree) -> void: cuts.append([piece, Engine.get_physics_frames()]))
	return cuts


## Whether two felled pieces are the same: their skeletons' nodes and branches,
## their weight and the lines they carry.
static func _same_pieces(a: FelledTree, b: FelledTree) -> bool:
	if a == null or b == null:
		return false
	var one := a.skeleton
	var other := b.skeleton
	return one.positions == other.positions and one.distances == other.distances and one.radii == other.radii \
			and one.branch_id == other.branch_id and one.branch_cut == other.branch_cut and a.mass == b.mass \
			and a.chop.lines.keys() == b.chop.lines.keys()


## A point `off` metres out from `branch`'s bark `distance` along it (the tree's
## own metres), in the world, on side 0 of its node frame there.
static func _out_from(chop: TreeChop, branch: int, distance: float, off := 0.0) -> Vector3:
	var tree := chop.tree
	var skeleton := tree.skeleton
	var normal := skeleton.sample_frame(branch, distance)[1]
	return tree.skeleton_transform() * (skeleton.sample_position(branch, distance)
			+ normal * (skeleton.sample_radius(branch, distance) + off))


## The twig with the most segments thick enough to be wood, or -1.
static func _woodiest_twig(skeleton: TreeSkeleton, min_radius: float) -> int:
	var twig := -1
	for branch in skeleton.branch_count():
		if skeleton.is_twig(branch, min_radius) and (twig < 0
				or skeleton.wood_segments(branch, min_radius) > skeleton.wood_segments(twig, min_radius)):
			twig = branch
	return twig


## Waits until `body` sleeps, at most `seconds` of ticks: how many ticks it took.
func _rest(body: RigidBody3D, seconds: float) -> int:
	var ticks := 0
	while is_instance_valid(body) and not body.sleeping and ticks < seconds * Engine.physics_ticks_per_second:
		await physics_frame
		ticks += 1
	return ticks


## Lifts `piece` `height` metres, still, and lets it go: the fastest its centre
## of mass fell over the next `ticks` ticks, in m/s.
func _drop(piece: FelledTree, height: float, ticks: int) -> float:
	piece.global_position += Vector3.UP * height
	piece.linear_velocity = Vector3.ZERO
	piece.angular_velocity = Vector3.ZERO
	piece.sleeping = false
	var fastest := 0.0
	for tick in ticks:
		await physics_frame
		if is_instance_valid(piece):
			fastest = maxf(fastest, -piece.linear_velocity.y)
	return fastest


## A leaf cluster on a twig (`twig`), or on wood with a line to chop, on a
## branch at least `depth` below the trunk.
static func _leaf_on(skeleton: TreeSkeleton, min_radius: float, twig: bool, depth := 0) -> int:
	for leaf in skeleton.leaf_count():
		var branch := skeleton.leaf_branch[leaf]
		if skeleton.is_twig(branch, min_radius) == twig and skeleton.branch_depth[branch] >= depth:
			return leaf
	return -1


## How many leaf clusters grow on a branch and everything growing from it.
static func _leaves_from(skeleton: TreeSkeleton, branch: int) -> int:
	var end := skeleton.subtree_end(branch)
	var count := 0
	for leaf in skeleton.leaf_count():
		if skeleton.leaf_branch[leaf] >= branch and skeleton.leaf_branch[leaf] < end:
			count += 1
	return count


## How many touch volumes a tree has of a kind: 0 leaf clusters, 1 bare twigs.
static func _touch_count(tree: ProceduralTree, kind: int) -> int:
	var count := 0
	for part: Vector2i in tree._touch_parts.values():
		if part.x == kind:
			count += 1
	return count


## The shape owner of a tree's touch volume: (kind, its leaf cluster or branch).
static func _touch_owner(tree: ProceduralTree, kind: int, index: int) -> int:
	for owner_id: int in tree._touch_parts:
		if tree._touch_parts[owner_id] == Vector2i(kind, index):
			return owner_id
	return -1


## Has `body` touch a tree's touch volume, as the physics engine reports it.
func _touch(tree: ProceduralTree, body: Node3D, kind: int, index: int) -> void:
	var owner_id := _touch_owner(tree, kind, index)
	if owner_id >= 0:
		tree._on_touched(RID(), body, 0, tree._foliage.shape_owner_get_shape_index(owner_id, 0))


## The player's body, as far as a tree can tell: on the Player layer.
func _player() -> CharacterBody3D:
	var player := CharacterBody3D.new()
	player.collision_layer = ProceduralTree.PLAYER_LAYER
	player.add_child(_box())
	return player


## A prop on the Dynamic layer, weightless, so it moves only as it is set to.
func _prop() -> RigidBody3D:
	var prop := RigidBody3D.new()
	prop.collision_layer = ProceduralTree.DYNAMIC_LAYER
	prop.gravity_scale = 0.0
	prop.add_child(_box())
	return prop


static func _box() -> CollisionShape3D:
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	return shape


## The level's tree cuts itself through (TreeChop severs it): nothing has it
## fell itself any more, and its chop and readout are wired.
func _test_level_wiring() -> void:
	var state := (load(LEVEL) as PackedScene).get_state()
	var fell := false
	for index in state.get_connection_count():
		fell = fell or state.get_connection_signal(index) == &"felled" or state.get_connection_method(index) == &"fell"
	_check(not fell, "the level no longer has its tree fell itself on TreeChop.felled: TreeChop cuts it through itself (%d connections)"
			% state.get_connection_count())
	var found := {}
	for node in state.get_node_count():
		var path := String(state.get_node_path(node)).trim_prefix("./")
		for property in state.get_node_property_count(node):
			var value: Variant = state.get_node_property_value(node, property)
			var name := state.get_node_property_name(node, property)
			if name == &"script" and value is Script:
				found[path + ":script"] = (value as Script).resource_path
			elif value is NodePath:
				found[path + ":" + name] = value
	_check(found.get("ProceduralTree/Strikeable:script") == "res://scripts/strike/strikeable.gd"
			and found.get("ProceduralTree/TreeChop:script") == "res://scripts/trees/tree_chop.gd"
			and found.get("ProceduralTree/TreeChop:strikeable") == NodePath("../Strikeable")
			and found.get("ProceduralTree/ChopDisplay:script") == "res://scripts/trees/tree_chop_display.gd"
			and found.get("ProceduralTree/ChopDisplay:chop") == NodePath("../TreeChop"),
			"the level's ProceduralTree has its TreeChop struck through its Strikeable, and its ChopDisplay showing that TreeChop")
