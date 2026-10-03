class_name TreeChop
extends Node

## Lets its parent ProceduralTree be chopped at its segment lines (agreed
## 2026-10-02, documents/procedural_trees.md, Chopping). The tree grows in
## segments (TreeSkeleton.segment_length), with a line every segment along every
## branch from its natural base. Every line on wood thick enough to hit can be
## chopped, standing or felled, and every one behaves the same:
## - A line on the trunk (depth 0) has `sides` around it; any other line one
##   side, all round.
## - A slash (a strike a Sharp edge or point dealt, the strike model) landing on
##   a line opens the side it lands on by its damage and, on a trunk line, the
##   sides either side by spill_share of it, each up to the line's cap. A full
##   side takes no more, so the player chops around the trunk.
## - What a line takes to cut through scales with the wood's cross-section
##   there: first_line_total at the trunk's first line, as much less as the wood
##   is thinner in cross-section, and at least least_total. Each of a trunk
##   line's sides takes 1/sides_to_cut of it, so that many full sides cut it.
## - Through, TreeChop cuts the tree there itself (ProceduralTree.sever). On a
##   standing tree a trunk line tips the part above over away from the wood
##   still uncut, hinged to the stump (FelledTree), and emits felled; any other
##   line lets the part beyond go as it will. The line is gone from both parts; a
##   part cut off takes the lines it carries, as they were, and chops on.
##
## Where a slash counts (forgiving, 2026-10-02: "some of my hits I feel don't
## register"): on the branch whose bark is nearest its point
## (TreeSkeleton.nearest), on the line being chopped (`current`) while within
## sticky reach of it, else on the nearest line within band_m that can be
## chopped. A line can be chopped when its wood is at least the species'
## collision_min_radius_m thick, it is past where its branch's bark clears its
## parent's, and no live branch's junction crosses it: a cut there would go
## through that branch's base. Twigs, branches with no line on wood to chop
## (TreeSkeleton.is_twig), break off whole on any strike at
## ProceduralTree.BREAK_SPEED or faster instead, as their leaves do.
##
## Blunt strikes and slashes off every line are still strikes, but cut nothing.
## Every strike it judges carries what it made of it (Strike.judged; Outcome),
## for the recorder. Distances are the tree's own metres, before its size
## variation.
##
## Lone pieces (2026-10-02: "If the segments are chopped so there are no other
## segments attached, then the hp of that log shows"): once no line on the tree
## can be chopped (a standing tree: once its trunk is cut, as its stump), it is
## lone, usually one segment with whatever stubs and twigs grow from it. It gets
## a Health, shown above its middle (TreeChopDisplay), that only slashes take:
## trunk_segment_health if its main branch is the trunk, else
## branch_segment_health. At 0 it is gone, its body or, for the stump, the tree
## itself, which never moves, waking what rested on it; and it drops
## logs_per_segment logs, or sticks_per_segment sticks, for each segment of wood
## it held (LootDrop).
##
## Fall damage (2026-10-03: "When branches impact the ground, they should damage
## and depending on the impact, they should break their segments"; "apply the
## damage of the max health of that segment, so it always breaks"): a felled
## piece's branch that hits something solid at impact_speed or faster breaks at
## its line nearest the hit, as if chopped through (impact, break_next; the piece
## reads its contacts, FelledTree). The trunk, twigs and lone pieces never break
## this way.

## Emitted when a line opens, or the line being chopped changes, with that line
## (null: none); and once when the tree is ready.
signal changed(line: Line)
## Emitted when a standing tree's trunk line is through, before the tree is cut
## there: where (`distance` up the trunk) and the way the part above falls
## (`toward`: level, in the world).
signal felled(distance: float, toward: Vector3)
## Emitted when an impact marks one of its branch lines to break (fall damage),
## with that line and how fast the hit closed (m/s).
signal impacted(line: Line, speed: float)

## What a strike on the tree came to (Strike.judged["outcome"]).
enum Outcome {
	## Not judged by a tree.
	NONE,
	## It opened a line.
	COUNTED,
	## Not a slash, so it cut nothing.
	BLUNT,
	## A slash too weak to do damage.
	NO_DAMAGE,
	## It landed too far off any bark.
	OFF_BARK,
	## No line it could chop was within reach.
	OFF_LINE,
	## Its nearest line runs through a branch's junction, and no other line was
	## within reach.
	BLOCKED,
	## The side it landed on was already full.
	FULL_SIDE,
	## It broke a twig off.
	TWIG_BROKEN,
	## It met a twig too slowly to break it.
	TWIG_HELD,
	## A slash on a lone piece, whose health takes it.
	LONE,
}

## One segment line being chopped: its branch (by TreeSkeleton.branch_id, which
## every piece of the tree keeps), its number k along the branch and the distance
## there, what it takes to cut through, each side's cap and how far each side is
## open.
class Line:
	var id := 0
	var k := 0
	var at := 0.0
	var total := 0
	var cap := 0
	var depths := PackedInt32Array()
	var open := 0
	## The side the last slash opened.
	var last_side := 0
	## How fast the impact that marked it to break closed, in m/s (fall damage); 0
	## if none has.
	var broken_by := 0.0

	func key() -> Vector2i:
		return Vector2i(id, k)


# How far off the bark a strike may land and still count, in metres.
const _BARK_MARGIN := 0.1
# The line being chopped keeps slashes at most this share of a segment off it,
# so the next line can always be started.
const _STICKY_SHARE := 0.75
# How far round a lone piece's wood what rests on it is looked for when it goes,
# in metres: more than a sleeping body's contact gap.
const _WAKE_MARGIN := 0.05
## How many lines impacts break a physics tick, across every tree: each cut
## builds two pieces' meshes and collision (1 to 7 ms on the desktop), and a
## hard landing can break several, so they are spread over ticks. None is lost:
## a marked line goes with its piece until it breaks.
const IMPACT_CUTS_PER_TICK := 1

# The physics tick the impact cuts were counted in, and how many there were.
static var _impact_tick := -1
static var _impact_cuts := 0

## The tree's strikes.
@export var strikeable: Strikeable
## How far along a branch from a line a slash still counts on it, in the
## tree's metres; the line being chopped keeps slashes this far off it too, up
## to three quarters of a segment (2026-10-02: 0.15 asked too much aim, then
## 0.3 still missed hits).
@export_range(0.05, 1.0, 0.01, "suffix:m") var band_m := 0.35
## How many sides a trunk line has around the trunk.
@export_range(3, 16, 1) var sides := 8
## What cutting through the trunk's first line takes, in damage points: six
## sides' worth of 50, each five full-strength strikes (2026-10-02).
@export_range(1, 2000, 1) var first_line_total := 300
## The least any line takes.
@export_range(1, 200, 1) var least_total := 10
## How many of a trunk line's sides, fully open, cut through it: each side
## takes its total over this, or over `sides` if that is fewer, so a line can
## always be cut through.
@export_range(1.0, 16.0, 0.5) var sides_to_cut := 6.0
## How much a slash opens each side next to the one it lands on, as a share of
## its damage, rounded (2026-10-02: the cut spreads round the trunk). It counts
## toward cutting through: at 0.25 a full-strength slash opens 16 in all.
@export_range(0.0, 1.0, 0.05) var spill_share := 0.25
@export_group("Notches")
## How far a notch reaches into the wood where a side is fully open, as a share
## of the branch's radius. It deepens as the side opens, and on a trunk line
## eases into the sides either side (TreeMesher.notch_depth).
@export_range(0.1, 1.0, 0.01) var notch_depth_share := 0.9
## How far a notch's mouth reaches up and down the bark from its line, as a
## share of its depth: 0.25 makes a V half as tall as it is deep (2026-10-02;
## 0.5 grew too tall).
@export_range(0.1, 2.0, 0.01) var notch_height_share := 0.25
@export_group("Lone pieces")
## What a lone piece of trunk drops for each segment of wood it held
## (2026-10-02: "Make each segment drop 3 wood logs").
@export var log_scene: PackedScene = preload("res://scenes/props/wood/log.tscn")
@export_range(0, 16, 1) var logs_per_segment := 3
## What a lone piece of a branch drops for each segment of wood it held.
@export var stick_scene: PackedScene = preload("res://scenes/props/wood/stick.tscn")
@export_range(0, 16, 1) var sticks_per_segment := 1
## A lone piece's health, in damage points, if its main branch is the trunk
## (2026-10-02: fixed per kind, 50 and 10).
@export_range(1, 1000, 1) var trunk_segment_health := 50
## A lone piece's health if its main branch is any other.
@export_range(1, 1000, 1) var branch_segment_health := 10
## How much a lone piece damps its spin, per second, added to the world's, so
## it doesn't roll off when walked over or pushed (2026-10-03: "the individual
## stick and log segments also roll way too easily"). At 16 a 75 kg log walked
## into rolls on 0.10 to 0.26 m after the last touch (2.5 to 3.1 m at 1), and a
## thin branch tip's creep slows to about 0.02 m/s and it falls asleep (at 6 it
## creeps on for ever). Bigger pieces keep FelledTree.ROLLING_DAMP, so a felled
## top still tips over and falls freely.
@export_range(0.0, 50.0, 0.5, "suffix:/s") var lone_angular_damp := 16.0
@export_group("Fall damage")
## How fast a felled piece's branch must close on something solid to break at
## its nearest line, in m/s: as fast as breaks a twig or a leaf. Kept above about
## 1.6 at 72 Hz, the most a hit leaves closing at the next tick, so no hit counts
## twice.
@export_range(1.0, 20.0, 0.1, "suffix:m/s") var impact_speed := ProceduralTree.BREAK_SPEED

## The tree this chops: the parent.
var tree: ProceduralTree
## The lines being chopped or asked about, by Line.key().
var lines := {}
## The line last struck, or null: the one the readout shows.
var current: Line
## A lone piece's health (null until it is lone).
var health: Health

# A lone piece's middle, on its body (or the tree), and its radius there, in
# the world.
var _middle: Marker3D
var _middle_radius := 0.0


func _ready() -> void:
	tree = get_parent() as ProceduralTree
	if tree == null:
		push_error("TreeChop: its parent must be a ProceduralTree.")
		return
	if strikeable == null:
		push_error("TreeChop: no strikeable is assigned.")
	else:
		strikeable.struck.connect(_on_struck)
	tree.severed.connect(_on_severed)
	tree.reshaped.connect(_on_reshaped)
	# Lines are found on the tree's skeleton, which it grows as it becomes ready.
	if not tree.is_node_ready():
		await tree.ready
	# A tree that can be chopped draws and breaks as its own from the start.
	tree.make_own()
	# A standing tree's first trunk line is ready to chop, its band drawn up
	# front, so the first chop costs no more than the rest.
	if tree.collision_host == null and tree.skeleton:
		current = line_at(0, 1)
	_show_notches()
	changed.emit(current)
	# At the end of the frame: a piece just cut off takes the tree's settings
	# first (_on_severed).
	_check_lone.call_deferred()


## Whether no line on the tree can be chopped: a lone piece (see above). A
## standing tree is lone only once its trunk is cut, as its stump: the root
## "wont move but if the segment above the first root segment is chopped", and
## a tree with no line to chop stays whole.
func is_lone() -> bool:
	var skeleton := tree.skeleton if tree else null
	if skeleton == null:
		return false
	if tree.collision_host == null and not (skeleton.branch_cut[0] & TreeSkeleton.CUT_TIP):
		return false
	for branch in skeleton.branch_count():
		var span := skeleton.line_range(branch)
		for k in range(span.x, span.y + 1):
			if choppable(branch, k):
				return false
	return true


## A lone piece's middle in the world, where its health shows above and its loot
## drops round; the tree's position until it is lone.
func lone_centre() -> Vector3:
	return _middle.global_position if _middle else tree.global_position


## A lone piece's radius at its middle, in the world.
func lone_radius() -> float:
	return _middle_radius


## Whether `branch`'s line k can be chopped: inside the branch, on wood at least
## collision_min_radius_m thick past where its bark clears its parent's, and not
## through a live branch's junction.
func choppable(branch: int, k: int) -> bool:
	var skeleton := tree.skeleton if tree else null
	if skeleton == null or branch < 0 or branch >= skeleton.branch_count() or _is_gone(branch):
		return false
	var span := skeleton.line_range(branch)
	if k < span.x or k > span.y:
		return false
	return skeleton.line_is_wood(branch, k, tree.species.collision_min_radius_m) \
			and not skeleton.line_blocked(branch, k, tree.gone_branches())


## `branch`'s line k (branch: an index in the tree's skeleton), made the first
## time it is asked for; null if it can't be chopped.
func line_at(branch: int, k: int) -> Line:
	if not choppable(branch, k):
		return null
	var key := Vector2i(tree.skeleton.branch_id[branch], k)
	if not lines.has(key):
		lines[key] = _make_line(branch, k)
	return lines[key]


## The line a slash at a point in the world would count on, or null.
func locate(point: Vector3) -> Line:
	var skeleton := tree.skeleton
	var found := skeleton.nearest(tree.skeleton_transform().affine_inverse() * point, tree.gone_branches())
	var branch := int(found.x)
	if branch < 0 or found.z > _BARK_MARGIN or skeleton.is_twig(branch, tree.species.collision_min_radius_m):
		return null
	return _line_near(branch, found.y)


## Fall damage: a hit at `point` (in the world) on `branch` (an index in the
## tree's skeleton: the one whose wood the contact's shape is), closing at
## `speed` (m/s), marks that branch's line nearest the point to break
## (break_next), at any distance from it; once. Nothing on a standing tree, a
## lone piece, the trunk, a twig or a branch that is gone, or under
## impact_speed. The line being chopped stays the one the readout shows.
## Whether it marked one.
func impact(point: Vector3, speed: float, branch: int) -> bool:
	var skeleton := tree.skeleton if tree else null
	if skeleton == null or tree.collision_host == null or health != null or speed < impact_speed:
		return false
	if branch < 0 or branch >= skeleton.branch_count() or _is_gone(branch) or skeleton.branch_depth[branch] == 0 \
			or skeleton.is_twig(branch, tree.species.collision_min_radius_m):
		return false
	var along: float = skeleton.nearest_on(branch, tree.skeleton_transform().affine_inverse() * point).x
	var span := skeleton.line_range(branch)
	var best := -1
	var best_gap := INF
	for k in range(span.x, span.y + 1):
		var gap := absf(along - k * skeleton.segment_length)
		if gap < best_gap and choppable(branch, k):
			best = k
			best_gap = gap
	if best < 0:
		return false
	var line := line_at(branch, best)
	if line.broken_by > 0.0:
		return false
	line.broken_by = speed
	impacted.emit(line, speed)
	return true


## Breaks the first line an impact marked that is still on the tree: opened all
## round to its total and cut through as slashes would; at most
## IMPACT_CUTS_PER_TICK a physics tick across every tree. Whether it broke one.
func break_next() -> bool:
	var tick := Engine.get_physics_frames()
	if tick != _impact_tick:
		_impact_tick = tick
		_impact_cuts = 0
	if _impact_cuts >= IMPACT_CUTS_PER_TICK:
		return false
	for line: Line in lines.values():
		if line.broken_by > 0.0 and _branch(line) >= 0:
			_impact_cuts += 1
			for side in line.depths.size():
				line.depths[side] = line.cap
			_update(line)
			return true
	return false


## Which side of `line` a point in the world is on, round the branch (0 on a
## line of one side). Sides are numbered from the node frame the line's notch is
## drawn in (TreeSkeleton.normals), so they keep on every piece.
func side_at(line: Line, point: Vector3) -> int:
	var count := line.depths.size()
	if count <= 1:
		return 0
	var frame := _frame(line)
	var offset := tree.skeleton_transform().affine_inverse() * point \
			- tree.skeleton.sample_position(_branch(line), line.at)
	var radial := offset - frame[0] * offset.dot(frame[0])
	var angle := atan2(radial.dot(frame[0].cross(frame[1])), radial.dot(frame[1]))
	return int(fposmod(angle, TAU) / TAU * count) % count


## The way the middle of `line`'s side faces, out from the branch, in the world.
func side_direction(line: Line, side: int) -> Vector3:
	var frame := _frame(line)
	var local := frame[1].rotated(frame[0], (side + 0.5) * TAU / line.depths.size())
	return (tree.skeleton_transform().basis * local).normalized()


## The middle of the branch at `line`, in the world.
func centre(line: Line) -> Vector3:
	return tree.skeleton_transform() * tree.skeleton.sample_position(_branch(line), line.at)


## The branch's radius at `line`, in the world.
func radius(line: Line) -> float:
	return tree.skeleton.sample_radius(_branch(line), line.at) * tree.skeleton_transform().basis.get_scale().x


## Opens `branch`'s line k with its sides as `open_by_side` has them, each up to
## its cap, and makes it the line being chopped (for checks and test scenarios):
## it cuts through if that is enough. Null if the line can't be chopped.
func preset(branch: int, k: int, open_by_side: PackedInt32Array) -> Line:
	var line := line_at(branch, k)
	if line == null:
		return null
	for side in line.depths.size():
		line.depths[side] = clampi(open_by_side[side] if side < open_by_side.size() else 0, 0, line.cap)
	current = line
	_update(line)
	return line


## The way the part beyond a trunk `line` falls, level, in the world: away from
## the wood still uncut, each side's weighing as much as is left of it, as a tree
## tips away from the hinge it is left standing on. If what is left is even all
## round, away from the side the last slash opened, which is the player's.
func fall_direction(line: Line) -> Vector3:
	var hinge := Vector3.ZERO
	for side in line.depths.size():
		hinge += side_direction(line, side) * (line.cap - line.depths[side])
	hinge.y = 0.0
	if hinge.length() < 0.5 * line.cap:
		hinge = side_direction(line, line.last_side)
		hinge.y = 0.0
	return -hinge.normalized()


func _on_struck(strike: Strike) -> void:
	var skeleton := tree.skeleton if tree else null
	if skeleton == null:
		return
	var found := skeleton.nearest(tree.skeleton_transform().affine_inverse() * strike.point, tree.gone_branches())
	var branch := int(found.x)
	# A lone piece's health takes every slash on it that does damage, wherever it
	# lands; a twig it lands on fast enough breaks as well, as on any tree.
	if health != null and strike.kind == Strike.Kind.SLASH and strike.damage > 0:
		if branch >= 0 and found.z <= _BARK_MARGIN and strike.speed >= ProceduralTree.BREAK_SPEED \
				and skeleton.is_twig(branch, tree.species.collision_min_radius_m):
			tree.break_branch(branch)
		_judge(strike, Outcome.LONE, branch, found.y if branch >= 0 else 0.0)
		return
	if branch < 0 or found.z > _BARK_MARGIN:
		_judge(strike, Outcome.OFF_BARK)
		return
	var along := found.y
	if skeleton.is_twig(branch, tree.species.collision_min_radius_m):
		if strike.speed >= ProceduralTree.BREAK_SPEED:
			tree.break_branch(branch)
		var broke := tree.gone_branches()[branch] == 1
		_judge(strike, Outcome.TWIG_BROKEN if broke else Outcome.TWIG_HELD, branch, along)
		return
	if strike.kind != Strike.Kind.SLASH:
		_judge(strike, Outcome.BLUNT, branch, along)
		return
	if strike.damage <= 0:
		_judge(strike, Outcome.NO_DAMAGE, branch, along)
		return
	var line := _line_near(branch, along)
	if line == null:
		_judge(strike, Outcome.BLOCKED if _nearest_blocked(branch, along) else Outcome.OFF_LINE, branch, along)
		return
	var side := side_at(line, strike.point)
	if line.depths[side] >= line.cap:
		_judge(strike, Outcome.FULL_SIDE, branch, along, line, side)
		# The readout follows the line struck, so the player sees that side is full.
		if current != line:
			current = line
			changed.emit(line)
		return
	line.depths[side] = mini(line.depths[side] + strike.damage, line.cap)
	var count := line.depths.size()
	if count > 1:
		var spill := roundi(strike.damage * spill_share)
		for next in [posmod(side - 1, count), posmod(side + 1, count)]:
			line.depths[next] = mini(line.depths[next] + spill, line.cap)
	line.last_side = side
	current = line
	_judge(strike, Outcome.COUNTED, branch, along, line, side)
	_update(line)


## The line a slash `along` metres along `branch` counts on: the one being
## chopped while within sticky reach of it, else the nearest line within
## band_m that can be chopped; null if none.
func _line_near(branch: int, along: float) -> Line:
	var skeleton := tree.skeleton
	var segment := skeleton.segment_length
	if segment <= 0.0:
		return null
	if current != null and current.id == skeleton.branch_id[branch] \
			and absf(along - current.at) <= minf(band_m, _STICKY_SHARE * segment):
		return current
	var best := -1
	var best_gap := INF
	for k in range(floori((along - band_m) / segment), ceili((along + band_m) / segment) + 1):
		var gap := absf(along - k * segment)
		if gap <= band_m and gap < best_gap and choppable(branch, k):
			best = k
			best_gap = gap
	return line_at(branch, best) if best >= 0 else null


## Whether the line nearest `along` metres along `branch` is wood to chop but
## runs through a branch's junction.
func _nearest_blocked(branch: int, along: float) -> bool:
	var skeleton := tree.skeleton
	var k := roundi(along / skeleton.segment_length)
	var span := skeleton.line_range(branch)
	return k >= span.x and k <= span.y and skeleton.line_is_wood(branch, k, tree.species.collision_min_radius_m) \
			and skeleton.line_blocked(branch, k, tree.gone_branches())


## Records on `strike` what it came to, for the recorder: the outcome, the
## branch's depth, the line it counted on (or the nearest), how far along the
## branch from that line it landed, and the side.
func _judge(strike: Strike, outcome: Outcome, branch := -1, along := 0.0, line: Line = null, side := -1) -> void:
	var skeleton := tree.skeleton
	var segment := skeleton.segment_length
	var k := -1
	if line != null:
		k = line.k
	elif branch >= 0 and segment > 0.0:
		k = roundi(along / segment)
	strike.judged = {
		"outcome": outcome,
		"depth": skeleton.branch_depth[branch] if branch >= 0 else -1,
		"line": k,
		"offset": along - k * segment if k >= 0 else 0.0,
		"side": side,
	}


func _update(line: Line) -> void:
	line.open = 0
	for depth in line.depths:
		line.open += depth
	var through := line.open >= line.total
	if not through:
		_show_notch(line)
	changed.emit(line)
	if through:
		_cut_through(line)


## Cuts the tree through at `line`, which is gone from both parts. A standing
## tree's trunk line tips the part above over, away from the wood still uncut.
func _cut_through(line: Line) -> void:
	var branch := _branch(line)
	lines.erase(line.key())
	if current == line:
		current = null
	if branch < 0:
		return
	var toward := Vector3.ZERO
	if line.depths.size() > 1 and tree.collision_host == null:
		toward = fall_direction(line)
		felled.emit(line.at, toward)
	tree.sever(branch, line.at, toward)


## A part cut off the tree takes the settings, and the lines it carries as they
## were: the line being chopped too, if it is one of them.
func _on_severed(piece: FelledTree) -> void:
	if piece.chop == null:
		return
	for setting: StringName in [&"band_m", &"sides", &"first_line_total", &"least_total", &"sides_to_cut",
			&"spill_share", &"notch_depth_share", &"notch_height_share", &"log_scene", &"logs_per_segment",
			&"stick_scene", &"sticks_per_segment", &"trunk_segment_health", &"branch_segment_health",
			&"impact_speed", &"lone_angular_damp"]:
		piece.chop.set(setting, get(setting))
	var skeleton := piece.skeleton
	for key: Vector2i in lines.keys():
		var branch := skeleton.branch_with_id(key.x)
		var span := skeleton.line_range(branch) if branch >= 0 else Vector2i(1, 0)
		if key.y < span.x or key.y > span.y:
			continue
		piece.chop.lines[key] = lines[key]
		if current != null and current.key() == key:
			piece.chop.current = current
			current = null
		lines.erase(key)
	piece.chop._show_notches()
	piece.chop.changed.emit(piece.chop.current)


## The tree was cut: lines no longer on it are let go, and the notches drawn
## again (the tree drew none since it took its new shape). What is left may be
## lone now.
func _on_reshaped() -> void:
	var skeleton := tree.skeleton
	for key: Vector2i in lines.keys():
		var branch := skeleton.branch_with_id(key.x)
		var span := skeleton.line_range(branch) if branch >= 0 else Vector2i(1, 0)
		if key.y < span.x or key.y > span.y:
			lines.erase(key)
	if current != null and not lines.has(current.key()):
		current = null
	_show_notches()
	changed.emit(current)
	_check_lone()


## Once the tree is lone, gives it its health and loot (see above): on the
## piece's body, or on the tree itself for its stump. It is freed when its
## health runs out, its loot dropping round its middle.
func _check_lone() -> void:
	if health != null or tree == null or not tree.is_inside_tree() or not is_lone():
		return
	var skeleton := tree.skeleton
	var trunk := skeleton.branch_depth[0] == 0
	var object: Node3D = tree
	if tree.collision_host:
		object = tree.collision_host
	if object is RigidBody3D:
		(object as RigidBody3D).angular_damp = lone_angular_damp
	var middle := (skeleton.distances[skeleton.branch_first_node[0]] + skeleton.branch_length(0)) * 0.5
	_middle = Marker3D.new()
	_middle.name = "LoneMiddle"
	object.add_child(_middle)
	_middle.global_position = tree.skeleton_transform() * skeleton.sample_position(0, middle)
	_middle_radius = skeleton.sample_radius(0, middle) * tree.skeleton_transform().basis.get_scale().x
	health = Health.new()
	health.name = "Health"
	health.maximum = trunk_segment_health if trunk else branch_segment_health
	health.strikeable = strikeable
	# Only slashes chop, a lone piece as much as a line.
	health.kinds = 1 << Strike.Kind.SLASH
	object.add_child(health)
	var drop := LootDrop.new()
	drop.name = "LootDrop"
	drop.health = health
	drop.loot = log_scene if trunk else stick_scene
	# For each segment of wood its main branch holds, at least one.
	drop.count = (logs_per_segment if trunk else sticks_per_segment) \
			* maxi(skeleton.wood_segments(0, tree.species.collision_min_radius_m), 1)
	drop.centre = _middle
	drop.lay_down = true
	object.add_child(drop)
	health.depleted.connect(_break_up.bind(object))
	changed.emit(current)


## A lone piece whose health ran out goes, `object` with it (its body, or the
## tree), waking first what rests on it: Jolt leaves a sleeping body where it
## slept when what held it up is gone (2026-10-02: a felled top propped on its
## stump hung in the air once the stump went).
func _break_up(object: Node3D) -> void:
	var skeleton := tree.skeleton
	var bounds := AABB(skeleton.positions[0], Vector3.ZERO)
	for node in skeleton.node_count():
		bounds = bounds.merge(AABB(skeleton.positions[node] - Vector3.ONE * skeleton.radii[node],
				Vector3.ONE * 2.0 * skeleton.radii[node]))
	var place := tree.skeleton_transform()
	var box := BoxShape3D.new()
	box.size = bounds.size * place.basis.get_scale().x + Vector3.ONE * 2.0 * _WAKE_MARGIN
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = box
	query.transform = Transform3D(place.basis.orthonormalized(), place * bounds.get_center())
	for hit in object.get_world_3d().direct_space_state.intersect_shape(query, 64):
		var body := hit.collider as RigidBody3D
		if body:
			body.sleeping = false
	object.queue_free()


## Each line's notch on the tree, for the lines opened and the one being chopped.
func _show_notches() -> void:
	if tree == null or tree.skeleton == null:
		return
	for line: Line in lines.values():
		if line.open > 0 or line == current:
			_show_notch(line)


## `line`'s notch: each side as deep as it is open.
func _show_notch(line: Line) -> void:
	var branch := _branch(line)
	if branch < 0:
		return
	var openings := PackedFloat32Array()
	for depth in line.depths:
		openings.append(float(depth) / line.cap)
	tree.notch_ring(branch, line.at, openings, notch_depth_share, notch_height_share)


func _make_line(branch: int, k: int) -> Line:
	var skeleton := tree.skeleton
	var line := Line.new()
	line.id = skeleton.branch_id[branch]
	line.k = k
	line.at = k * skeleton.segment_length
	var share := skeleton.sample_radius(branch, line.at) / skeleton.first_line_radius \
			if skeleton.first_line_radius > 0.0 else 1.0
	line.total = maxi(least_total, roundi(first_line_total * share * share))
	var count := sides if skeleton.branch_depth[branch] == 0 else 1
	# Rounded up, so sides_to_cut full sides always reach the total.
	line.cap = maxi(1, ceili(line.total / minf(sides_to_cut, count))) if count > 1 else line.total
	line.depths.resize(count)
	return line


## `line`'s branch, as an index in the tree's skeleton now; -1 if it is gone.
func _branch(line: Line) -> int:
	return tree.skeleton.branch_with_id(line.id)


## The node frame at `line`: (axis, normal), in the skeleton's space.
func _frame(line: Line) -> PackedVector3Array:
	return tree.skeleton.sample_frame(_branch(line), line.at)


func _is_gone(branch: int) -> bool:
	var gone := tree.gone_branches()
	return branch < gone.size() and gone[branch] == 1
