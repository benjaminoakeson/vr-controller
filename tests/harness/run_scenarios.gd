extends SceneTree

## Runs the player through scripted scenarios on the test level, without a
## headset, and checks the results.
##
## Each scenario loads a fresh level, places the player, and plays scripted
## headset, controller and stick input through SimulatedRig while the
## player's own debug recorder records. Gameplay code is not changed or
## bypassed; only its inputs are simulated, and scenarios read the physical
## layer's snapshot like any other consumer. Results are simulated desktop
## physics, not headset or Quest 3S measurements.
##
##   godot --headless --xr-mode off --fixed-fps 72 --path . \
##       -s tests/harness/run_scenarios.gd [-- option ... scenario ...]
##
## Options:
##   --level=res://path.tscn      run on this level instead of scenes/level.tscn
##   --player=res://path.tscn     run this player scene in place of the level's own
##   --reference=res://path.json  instead of the acceptance checks, require every
##                                measurement to match these reference results
##   --write-reference            save this run as the reference instead of
##                                checking (after a deliberate change, once the
##                                old reference was understood)
##   --no-comparison              skip the printed comparison with the reference
## Scenario names limit the run to those scenarios.
##
## Writes a CSV per scenario and results.json to
## user://baselines/simulated/<time>/, prints the checks, and exits with 0
## only if all of them pass:
## - ACCEPTANCE: the current rung's criteria for the dynamic body, each with
##   its tolerance (see _acceptance()), plus a printed, unchecked comparison
##   with the kinematic body's reference results;
##   or REFERENCE: every measurement within 1 %, or 0.001 in its unit, of the
##   given reference results;
## - CHECKLIST: the guided headset checklist recognises every item of the
##   guided session when fed the recordings in the order a player meets them;
## - GUIDED: a guided session starts recording and shows its first item.

const SimulatedRig := preload("res://tests/harness/simulated_rig.gd")
const Analysis := preload("res://tests/harness/analysis.gd")
const LEVEL_PATH := "res://scenes/level.tscn"
const KINEMATIC_REFERENCE := "res://tests/harness/reference/kinematic_baseline.json"
## The guided check records here, apart from real headset sessions.
const SMOKE_DIRECTORY := "user://baselines/smoke"
## A measurement matches its reference within this share of the reference
## value, or within the absolute amount, whichever is larger.
const REFERENCE_RELATIVE := 0.01
const REFERENCE_ABSOLUTE := 0.001
## The recording that exercises each guided-session item.
const SCENARIO_FOR_STEP := {
	BaselineChecklist.Step.WALK: "flat_full", BaselineChecklist.Step.HALF: "flat_half",
	BaselineChecklist.Step.STEPS_UP: "steps", BaselineChecklist.Step.STEPS_DOWN: "steps",
	BaselineChecklist.Step.RAMP_DOWN: "ramp", BaselineChecklist.Step.RAMP_UP: "ramp",
	BaselineChecklist.Step.WALL: "wall", BaselineChecklist.Step.CROUCH: "crouch",
	BaselineChecklist.Step.RUN: "run_hard", BaselineChecklist.Step.DROP: "drop",
	BaselineChecklist.Step.JUMP: "jump",
	BaselineChecklist.Step.HAND_TOUCH: "hand_table_press", BaselineChecklist.Step.HAND_PUSH: "push_steps",
	BaselineChecklist.Step.VAULT: "vault", BaselineChecklist.Step.STICK_ROOM: "stick_room_walk",
	BaselineChecklist.Step.PALM_SLIDE: "palm_slide", BaselineChecklist.Step.FINGERS: "fingers_curl",
	BaselineChecklist.Step.FINGER_WRAP: "fingers_grip_box",
	BaselineChecklist.Step.BODY_TOUCH: "lean_over_table",
	BaselineChecklist.Step.PROP_PUSH: "palm_push_box",
	BaselineChecklist.Step.PALM_LIFT: "palms_lift_box",
	BaselineChecklist.Step.GRAB: "grab_lift_box",
}
## Palms flat against the wall ahead, fingers up; or flat on a table, fingers
## ahead. Each is the palm's direction then the fingers', in the head's facing.
const PALMS_TO_WALL := [Vector3.FORWARD, Vector3.UP]
const PALMS_DOWN := [Vector3.DOWN, Vector3.FORWARD]
## The weapons lying on the level's table (2026-09-27). They lie where the
## table scenarios put their hands and crates, which were tuned on a clear
## table, so each scenario takes them out of its level before it enters the
## tree (no bodies are made, and the physics engine's solve order stays as it
## was), keeping all of them for "weapons": true or those it lists.
const WEAPONS: Array[NodePath] = [^"Dynamic/Sword", ^"Dynamic/Dagger", ^"Dynamic/LongSword",
		^"Dynamic/Pickaxe", ^"Dynamic/Axe",
		^"CopperOre", ^"IronOre", ^"GoldOre", ^"SilverOre", ^"CobaltOre"]
## The struck posts east of the table (the strike model, 2026-09-30), taken out
## the same way, and kept for "targets": true or those listed. A scenario puts
## those it keeps where it needs them ("place").
const TARGETS: Array[NodePath] = [^"Targets/ClothDummy", ^"Targets/WoodPost", ^"Targets/StoneBlock"]
## The pieces cut off a watched tree, by role (_tree_pieces): the key each is
## kept under while its scenario runs. The pieces impacts break off (fall
## damage, 2026-10-03) are kept in the order they broke ("broken"), as
## broken_1, broken_2 and on.
const TREE_PIECES := {"top": "fall_piece", "rest": "buck_piece", "cut": "severed_piece"}
## How near a piece of a tree must lie to a lone piece as that goes to have
## touched it, in metres (_touches): a resting contact's depth, and a little.
const TOUCH_GAP := 0.01
## How long a piece cut off a tree must stay at rest for its rest to count, in
## seconds (fall damage, _track_pieces): longer than a rocking piece stays slow
## as it turns back.
const REST_HOLD := 1.0
## How slow a piece an impact broke off must go to count as settled though it
## never rests, in m/s (fall damage, 2026-10-03): lying on the floor, a branch
## tip 3 cm thick may creep on for good at a steady 0.073 m/s, turning 2.2 rad/s
## (Jolt's round shapes creep; FelledTree.ROLLING_DAMP does not stop it). Lone, a
## piece one segment long damps its spin by TreeChop.lone_angular_damp: at 16 the
## tip creeps at about 0.02 m/s and sleeps 7 to 10 s on (2026-10-03).
const CREEP_SPEED := 0.1
## What a piece cut off a tree weighs for each segment of wood it holds
## (2026-10-02, the player: "each segment (trunk root) should be 75kg and each
## branch segment should be 25kg"): a segment of a trunk, and of any other
## branch but a twig, which weighs nothing (_weight_rule).
const TRUNK_SEGMENT_KG := 75.0
const BRANCH_SEGMENT_KG := 25.0
## The table's top, 1.0 m high (the level's CSGBox3D14, lengthened to 1.5 m on
## 2026-09-27), in the arena the scenarios were written in (ARENA).
const TABLE_TOP := AABB(Vector3(0.75, 0.5, -0.5), Vector3(0.5, 1.0, 1.5))
## The scenarios were written in the level as it was until 2026-09-27, and keep
## its numbers. This is where each feature they use lay in it: a pose, its
## origin a point on the feature and its -Z the way the player faces it. A
## scenario names its feature ("at"; "open" if it names none), and runs with
## the level turned about the vertical and moved along the floor (never
## raised) so that the feature, found in the level by name (_feature_pose),
## lies there. The level moves; the numbers do not.
const ARENA := {
	# Where the scenarios that stand, turn and step about start (the level's
	# OpenFloor marker, facing its -Z); where a 9.2 m straight walk starts, its
	# end at the level's edge (the OpenLane marker, its -Z along the walk).
	"open": Transform3D(Basis.IDENTITY, Vector3(-2.0, 0.0, 1.0)),
	"lane": Transform3D(Basis(Vector3(0.0, 0.0, 1.0), Vector3.UP, Vector3(-1.0, 0.0, 0.0)),
			Vector3(-4.3, 0.0, -3.5)),
	# The light box, the boxes as the level lays them on the Table (the table's
	# scenarios work beside them: 7 mm off, a hand pressing the table met the
	# heavy box); the Table's top at its +Z end, where the weapons lie.
	"boxes": Transform3D(Basis.IDENTITY, Vector3(1.0, 1.05, -0.4)),
	"weapons": Transform3D(Basis.IDENTITY, Vector3(1.0, 1.0, 1.001)),
	# Step1's top; the Wall's face toward the floor, facing out of it.
	"steps": Transform3D(Basis.IDENTITY, Vector3(3.0, 0.25, 2.0)),
	"wall": Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 4.0)),
	# The pit: the PitHole in the floor; the PitRamp's top edge, facing down
	# it, and its foot on the PitFloor, facing up it. Ramp15's high end, facing
	# down it (the old ramp's top edge: slope_walk stands 2 m down it).
	"pit_hole": Transform3D(Basis.IDENTITY, Vector3(-4.0, 0.0, 2.75)),
	"pit_top": Transform3D(Basis(Vector3(0.0, 0.0, -1.0), Vector3.UP, Vector3(1.0, 0.0, 0.0)),
			Vector3(3.996, 0.0, -5.5)),
	"pit_foot": Transform3D(Basis.IDENTITY, Vector3(-5.5, -4.0, 1.797)),
	"ramp15_top": Transform3D(Basis(Vector3(0.0, 0.0, -1.0), Vector3.UP, Vector3(1.0, 0.0, 0.0)),
			Vector3(3.996, 0.0, -5.5)),
	# The climbing holds (2026-09-28): the Wall's face behind Holds/Hold1,
	# facing out of the wall, as the wall's scenarios have it.
	"hold1": Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 4.0)),
	# The same for Hold4, on the lip of the Notch cut into the Wall's top, the
	# Platform behind it level with the Notch's floor (climbing, step 2).
	"hold4": Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 4.0)),
}
## Where the climbing scenarios stand: 0.35 m from the wall, Hold1 ahead.
const CLIMB_START := Vector3(0.0, 0.0, 3.65)
## The comparison table's measurements.
const COMPARED := ["top_speed", "presses.0.speed", "presses.0.rise_time",
	"presses.0.stop_time", "presses.0.stop_distance", "airborne_time", "largest_rise",
	"pulled_back", "head_obstruction_max", "body_height_min", "run_factor_max"]
## Seconds to stand still before recording, so the body and feet settle.
const SETTLE := 0.5
## Without hands, the static skeleton's chest only turns once the head has
## twisted past the neck's limit, so a scenario facing anywhere but the chest's
## starting -Z would run with the body turned sideways. Scenarios without
## hands therefore settle for longer with both controllers tracked at the
## body's sides, where the chest turns to face the head; tracking drops as
## recording starts.
const NO_HANDS_SETTLE := 2.0
const SIDE_HAND := Vector3(0.25, 0.9, 0.0)
## Frames to wait after freeing a level, so two never share the world.
const TEARDOWN_FRAMES := 2
## A scripted turn-around takes this long, in seconds, like a person turning.
const TURN_TIME := 1.0
## Standing pauses between the legs of a scripted walk, in seconds.
const PAUSE := 0.8
## How long the guided check runs before looking, in seconds.
const GUIDED_TIME := 2.0

enum Mode { ACCEPTANCE, REFERENCE, WRITE }

var _scenarios: Array[Dictionary] = []
var _index := -1
var _level: Node
var _player: Player
var _state: PoseSnapshot
var _debug: PlayerDebug
var _rig: SimulatedRig
var _time := 0.0
# The running scenario's time (t, after its settling), as its drive last saw it.
var _t := 0.0
var _teardown := 0
var _scenario_state := {}
var _results: Array[Dictionary] = []
var _directory := ""
var _level_path := LEVEL_PATH
var _player_scene: PackedScene
var _mode := Mode.ACCEPTANCE
var _reference_path := KINEMATIC_REFERENCE
var _compare := true
var _guided_ran := false
var _guided_ok := false


func _initialize() -> void:
	_directory = "user://baselines/simulated/%s" % \
			Time.get_datetime_string_from_system().replace(":", "-")
	var wanted: Array[String] = []
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--level="):
			_level_path = argument.trim_prefix("--level=")
		elif argument.begins_with("--player="):
			_player_scene = load(argument.trim_prefix("--player=")) as PackedScene
			if _player_scene == null:
				push_error("run_scenarios: cannot load %s" % argument)
				quit(1)
				return
		elif argument.begins_with("--reference="):
			_mode = Mode.REFERENCE
			_reference_path = argument.trim_prefix("--reference=")
		elif argument == "--write-reference":
			_mode = Mode.WRITE
		elif argument == "--no-comparison":
			_compare = false
		else:
			wanted.append(argument)
	_scenarios = _all_scenarios()
	if not wanted.is_empty():
		_scenarios = _scenarios.filter(
				func(scenario: Dictionary) -> bool: return scenario.name in wanted)
	physics_frame.connect(_tick)
	process_frame.connect(_frame)
	_teardown = 1


## Runs before the player's nodes in every physics tick: SceneTree emits
## physics_frame ahead of their _physics_process.
func _tick() -> void:
	if _teardown > 0:
		_teardown -= 1
		if _teardown == 0:
			_next()
		return
	if _level == null:
		return
	var delta := 1.0 / Engine.physics_ticks_per_second
	_time += delta
	var scenario := _scenarios[_index]
	if scenario.has("tree"):
		_time_frame()
	var no_hands: bool = scenario.get("no_hands", false)
	var t := _time - (NO_HANDS_SETTLE if no_hands else SETTLE)
	_t = t
	var finished := false
	if t >= 0.0:
		if no_hands:
			_rig.left_tracked = false
			_rig.right_tracked = false
		if not scenario.get("guided", false) and not _debug.recorder.recording:
			_debug.recorder.start(_directory, scenario.name)
			_scenario_state.start_height = _state.body_position.y
		finished = (scenario.drive as Callable).call(t) or t >= scenario.limit
		if not scenario.get("guided", false):
			_check_model()
		if _scenario_state.has("fall_piece"):
			_log_fall(t)
		if scenario.has("tree"):
			_track_weights(scenario, t)
			_track_pieces(t)
		if scenario.has("snaps"):
			_drive_snaps(t, scenario.snaps)
			_track_turn(t)
		if _player.interface != null:
			_scenario_state.fade_max = maxf(_scenario_state.get("fade_max", 0.0),
					_player.interface.view_fade.alpha)
		var dynamic := _player.physical as DynamicPhysical
		if dynamic != null and dynamic.right_drive != null:
			var drive := dynamic.right_drive
			var error := (drive.target.basis.orthonormalized()
					* drive.hand.global_basis.orthonormalized().inverse()).get_rotation_quaternion().get_angle()
			_scenario_state.turn_error = error
			_scenario_state.turn_error_max = maxf(_scenario_state.get("turn_error_max", 0.0), error)
	_rig.apply()
	if finished:
		_finish(scenario)


func _next() -> void:
	_index += 1
	if _index >= _scenarios.size():
		_report()
		return
	var scenario := _scenarios[_index]
	_rig = SimulatedRig.new()
	_rig.face(scenario.facing)
	# A scenario that stands lower starts there: a head cannot drop in one tick.
	_rig.head_position.y = scenario.get("head_height", SimulatedRig.HEAD_HEIGHT)
	# One working at the table's boxes starts with the hands held above them,
	# so resting hands do not shove the boxes before it begins.
	if scenario.has("hand_height"):
		_rig.left_hand.y = scenario.hand_height
		_rig.right_hand.y = scenario.hand_height
	if scenario.get("no_hands", false):
		# Head and body scenarios: the controllers report no tracking once
		# recording starts, so the hands stay at the body's sides instead of
		# reaching walls first.
		_rig.left_hand = Vector3(-SIDE_HAND.x, SIDE_HAND.y, SIDE_HAND.z)
		_rig.right_hand = SIDE_HAND
	_rig.apply()
	_level = (load(_level_path) as PackedScene).instantiate()
	(_level as Node3D).transform = _arena_transform(_level, scenario.get("at", "open"))
	var kept := _kept(scenario, "weapons", WEAPONS)
	var kept_targets := _kept(scenario, "targets", TARGETS)
	for path in WEAPONS + TARGETS:
		var node := _level.get_node_or_null(path)
		if node != null and path not in kept and path not in kept_targets:
			node.get_parent().remove_child(node)
			node.free()
	var place: Dictionary = scenario.get("place", {})
	for path: NodePath in place:
		_place(path, place[path])
	if scenario.has("vein_health"):
		(_level.get_node(scenario.vein as NodePath).get_node(^"Health") as Health).maximum = scenario.vein_health
	var start: Vector3 = scenario.start
	if scenario.has("on_ramp"):
		start.y = _ramp_height(_level, scenario.on_ramp, start)
	_player = _place_player(_level, start)
	if _player == null:
		push_error("run_scenarios: the level has no Player.")
		quit(1)
		return
	root.add_child(_level)
	_scenario_state = {}
	for path in kept_targets:
		Strikeable.of(_level.get_node(path)).struck.connect(_log_strike)
	if scenario.has("vein"):
		_watch_vein(_level.get_node(scenario.vein as NodePath))
	if scenario.has("tree"):
		_watch_tree(_level.get_node(scenario.tree as NodePath) as ProceduralTree, scenario)
	if scenario.has("stool"):
		_scenario_state.stool = _add_stool(start)
	if scenario.has("palms"):
		var palms: Array = scenario.palms
		_turn_palms(palms[0], palms[1])
	_debug = _player.enable_debug()
	_state = _player.physical.snapshot
	if scenario.get("guided", false):
		_debug.start_guided(SMOKE_DIRECTORY)
	_time = 0.0
	_scenario_state.merge({"phase": 0, "phase_start": 0.0}, true)
	# Where the level lays the weapons, before a physics step moves them.
	for path in kept:
		var weapon := _level.get_node(path) as Node3D
		_scenario_state["placed_" + String(weapon.name)] = weapon.global_transform


## Which of `paths` a scenario keeps under `key` ("weapons", "targets"): all
## of them for true, those it lists for a list, none otherwise.
static func _kept(scenario: Dictionary, key: String, paths: Array[NodePath]) -> Array[NodePath]:
	var keep: Variant = scenario.get(key, false)
	var kept: Array[NodePath] = []
	for path in paths:
		if (keep is bool and keep) or (keep is Array and path in keep):
			kept.append(path)
	return kept


## Puts the level's node at `path` at `pose`, in the frame the scenario was
## written in (ARENA's), before the level enters the tree.
func _place(path: NodePath, pose: Transform3D) -> void:
	var node := _level.get_node(path) as Node3D
	var parent := Transform3D.IDENTITY
	var up := node.get_parent()
	while up != null:
		if up is Node3D:
			parent = (up as Node3D).transform * parent
		if up == _level:
			break
		up = up.get_parent()
	node.transform = parent.affine_inverse() * pose


## Logs a strike on a kept target into the scenario's results ("strikes"),
## with what the struck object made of it, if anything judged it ("judged":
## Strike.judged; for a tree also its outcome's name, "verdict"), and where it
## landed in the striker's own space, as the striker lies after the step
## ("on_striker"), and in its Sharp feature's, if one dealt it ("on_feature":
## along an edge is its Y; "feature_length": the edge's length). A scripted
## strike (_slash_lone) has no striker: "" and neither.
func _log_strike(strike: Strike) -> void:
	var log: Array = _scenario_state.get("strikes", [])
	var entry := {"t": _t, "striker": String(strike.striker.name) if strike.striker != null else "",
			"target": String(strike.target.name),
			"speed": strike.speed, "mass": strike.effective_mass, "energy": strike.energy,
			"damage": strike.damage, "held_by": strike.held_by, "gap": strike.gap,
			"kind": strike.kind, "feature": String(strike.feature.name) if strike.feature != null else "",
			"threshold": strike.material.threshold_of(strike.kind),
			"full": strike.material.full_energy_of(strike.kind),
			"point": [strike.point.x, strike.point.y, strike.point.z],
			"normal": [strike.normal.x, strike.normal.y, strike.normal.z]}
	if strike.striker != null:
		var on_striker := strike.striker.global_transform.affine_inverse() * strike.point
		entry.on_striker = [on_striker.x, on_striker.y, on_striker.z]
		if strike.feature != null:
			var on_feature := strike.feature.transform.affine_inverse() * on_striker
			entry.on_feature = [on_feature.x, on_feature.y, on_feature.z]
			entry.feature_length = strike.feature.length
	if not strike.judged.is_empty():
		entry.judged = strike.judged.duplicate()
		if strike.judged.has("outcome"):
			entry.verdict = str(TreeChop.Outcome.find_key(strike.judged.outcome))
	log.append(entry)
	_scenario_state.strikes = log


## Follows an ore vein a scenario strikes ("vein"; health, 2026-10-02): logs
## its strikes as the posts' are, its health and what its display shows at the
## start (time 0) and after each change ("vein_health": [time, health, text]),
## when its health ran out ("vein_depleted") and when it left the level
## ("vein_gone"). Its loot: the scene it drops, where its meshes lay and where
## it stood ("loot_scene", "vein_bounds" [low, high], "vein_position"), and
## what it dropped (_on_loot_dropped).
func _watch_vein(vein: Node3D) -> void:
	var health := vein.get_node(^"Health") as Health
	var display := vein.get_node(^"HealthDisplay") as Label3D
	Strikeable.of(vein).struck.connect(_log_strike)
	_scenario_state.vein_maximum = health.maximum
	_scenario_state.vein_health = [[0.0, health.current, display.text]]
	# After the display's own handler, so its text is already the new one.
	health.changed.connect(func(current: int) -> void:
			_scenario_state.vein_health.append([_t, current, display.text]))
	health.depleted.connect(func() -> void: _scenario_state.vein_depleted = _t)
	vein.tree_exited.connect(func() -> void: _scenario_state.vein_gone = _t)
	var drop := vein.get_node_or_null(^"LootDrop") as LootDrop
	if drop == null or drop.loot == null:
		return
	var bounds := AABB()
	var meshes := vein.find_children("*", "MeshInstance3D", true, false)
	for i in meshes.size():
		var mesh := meshes[i] as MeshInstance3D
		var box := mesh.global_transform * mesh.get_aabb()
		bounds = box if i == 0 else bounds.merge(box)
	_scenario_state.loot_scene = drop.loot.resource_path
	_scenario_state.vein_bounds = [[bounds.position.x, bounds.position.y, bounds.position.z],
			[bounds.end.x, bounds.end.y, bounds.end.z]]
	_scenario_state.vein_position = [vein.global_position.x, vein.global_position.y, vein.global_position.z]
	drop.dropped.connect(_on_loot_dropped)


## Follows the tree a scenario chops ("tree"; chopping, 2026-10-02) at its
## segment line "chop_line" (Vector2i(branch, k): the branch's index in the
## tree's skeleton and the line's number along it; the trunk's first line if
## absent). First it turns and moves the tree so the middle of that line's side
## 0 faces "tree_face" [point, toward] (toward: horizontal, from the trunk to
## the player), the bark there at the point, where the scenario's blow lands;
## then it opens the line's sides as "chop_preset" has them, which makes it the
## line being chopped. Both happen before the first tick. It logs the tree's
## strikes as the posts' are, with what the tree made of each (_log_strike),
## and the side of the line each landed on, -1 if it would not count on that
## line, seen as it landed, before the tree judged it ("chop_sides"); the
## line's length (the tree's "segment_length"), what each of its sides takes
## and what cuts through it ("chop_cap", "chop_fell_at"), and what a slash
## spills onto the sides either side, none on a line of one side
## ("chop_spill"). Its sides, what the tree's readout shows and whether it
## shows this line (the line being chopped), at the start (time 0) and after
## each change of it ("chop_open": [time, sides, text, shown]); when it was
## felled and the way it falls ("chop_felled", "fall_toward"); when its top
## split off to fall ("fall_started"), and the stump left ("stump_length",
## "stump_solid"); and the top as it falls, every tick (_log_fall). When
## anything is cut off it, and the piece ("severed": times; "severed_piece").
## Should the tree leave the level, when ("tree_gone"). The piece the scenario
## breaks once it is lone ("lone", a role of _tree_pieces: "tree", "top" or
## "cut", the first piece cut off), from the start or as it is cut off
## (_watch_lone). Every piece cut off it, and off those, any way, is followed
## from the tick it was made (fall damage, 2026-10-03; _follow_piece), with
## what it takes for an impact to break a line ("impact_speed"), and each cut's
## time (_on_cut_starting).
func _watch_tree(tree: ProceduralTree, scenario: Dictionary) -> void:
	var chop := tree.get_node(^"TreeChop") as TreeChop
	var display := tree.get_node(^"ChopDisplay") as TreeChopDisplay
	var at: Vector2i = scenario.get("chop_line", Vector2i(0, 1))
	var line := chop.line_at(at.x, at.y)
	_scenario_state.segment_length = tree.skeleton.segment_length
	_scenario_state.tree_id = tree.get_instance_id()
	_scenario_state.impact_speed = chop.impact_speed
	chop.changed.connect(_on_cut_starting.bind(chop))
	tree.reshaped.connect(_on_cut_done)
	if line == null:
		push_error("run_scenarios: the tree's line %s cannot be chopped." % str(at))
		return
	if scenario.has("tree_face"):
		var face: Array = scenario.tree_face
		var toward: Vector3 = face[1]
		var side := chop.side_direction(line, 0)
		var turn := Vector3(side.x, 0.0, side.z).signed_angle_to(Vector3(toward.x, 0.0, toward.z), Vector3.UP)
		tree.global_transform = Transform3D(Basis(Vector3.UP, turn), Vector3.ZERO) * tree.global_transform
		tree.global_position += (face[0] as Vector3) - (chop.centre(line) + chop.side_direction(line, 0) * chop.radius(line))
	if scenario.has("chop_preset"):
		chop.preset(at.x, at.y, PackedInt32Array(scenario.chop_preset))
	# Where each strike landed is seen before the tree judges it, as a blow that
	# cuts the line through takes the line off the tree; what the tree made of
	# it, after.
	var strikeable := Strikeable.of(tree)
	var judges := strikeable.struck.is_connected(chop._on_struck)
	if judges:
		strikeable.struck.disconnect(chop._on_struck)
	strikeable.struck.connect(func(strike: Strike) -> void:
			var sides: Array = _scenario_state.get("chop_sides", [])
			sides.append(chop.side_at(line, strike.point) if chop.locate(strike.point) == line else -1)
			_scenario_state.chop_sides = sides)
	if judges:
		strikeable.struck.connect(chop._on_struck)
	strikeable.struck.connect(_log_strike)
	_scenario_state.chop_cap = line.cap
	_scenario_state.chop_fell_at = line.total
	_scenario_state.chop_spill = chop.spill_share if line.depths.size() > 1 else 0.0
	_scenario_state.chop_open = [[0.0, Array(line.depths), display._total.text, chop.current == line]]
	# After the display's own handler, so its text is already the new one.
	chop.changed.connect(func(which: TreeChop.Line) -> void:
			if which == line:
				_scenario_state.chop_open.append([_t, Array(line.depths), display._total.text, chop.current == line]))
	var lone: String = scenario.get("lone", "")
	if lone == "tree":
		_watch_lone(chop)
	chop.felled.connect(func(_distance: float, toward: Vector3) -> void:
			_scenario_state.chop_felled = _t
			_scenario_state.fall_toward = [toward.x, toward.y, toward.z])
	tree.felled.connect(func(top: FelledTree) -> void:
			_scenario_state.fall_piece = top
			_name_piece(top, "top")
			_scenario_state.fall_started = _t
			# The trunk's way up at the cut, in the top's own frame, to follow its tilt.
			var trunk := top.piece.skeleton_transform().basis * top.skeleton.sample_direction(0, top.skeleton.distances[0])
			_scenario_state.fall_trunk = top.global_basis.inverse() * trunk.normalized()
			_scenario_state.stump_length = tree.skeleton.branch_length(0)
			_scenario_state.stump_solid = tree.has_collision()
			if lone == "top":
				_watch_lone(top.chop))
	tree.severed.connect(func(piece: FelledTree) -> void:
			var severed: Array = _scenario_state.get("severed", [])
			severed.append(_t)
			_scenario_state.severed = severed
			_scenario_state.severed_piece = piece
			_follow_piece(piece, tree, "cut")
			if lone == "cut" and severed.size() == 1:
				_watch_lone(piece.chop))
	tree.tree_exited.connect(func() -> void: _scenario_state.tree_gone = _t)


## Follows the lone piece a scenario breaks (chopping 1c, 2026-10-02) through
## its TreeChop, from before it is lone: when it got its health, which body
## carries it, how much and of which kinds of strike ("lone": {"at", "object",
## "maximum", "kinds", "loot_scene", "count", "gap"}); its health, and what its
## readout shows, then and after each change ("lone_health": [time, health,
## text]); when its health ran out and where its middle was then
## ("lone_depleted", "lone_middle"), and when its body left the level
## ("lone_gone"). Every strike it takes from then on ("lone_strikes": [time,
## striker, "" for a scripted one; kind, damage, the tree's verdict]); they are
## logged as the tree's are too (_log_strike), and its loot as a vein's
## (_on_loot_dropped), with what took each drop's place (_blocked_places).
func _watch_lone(chop: TreeChop) -> void:
	# After the readout's own handler, so it already shows the health.
	chop.changed.connect(func(_line: TreeChop.Line) -> void:
			if chop.health == null or _scenario_state.has("lone"):
				return
			var health := chop.health
			var object := health.get_parent() as Node3D
			var drop := object.get_node(^"LootDrop") as LootDrop
			_scenario_state.lone = {"at": _t, "object": String(object.name), "maximum": health.maximum,
					"kinds": health.kinds, "loot_scene": drop.loot.resource_path, "count": drop.count, "gap": drop.gap}
			_scenario_state.lone_health = [[_t, health.current, _lone_text(chop)]]
			health.changed.connect(func(current: int) -> void:
					_scenario_state.lone_health.append([_t, current, _lone_text(chop)]))
			health.depleted.connect(func() -> void:
					_scenario_state.lone_depleted = _t
					var middle := chop.lone_centre()
					_scenario_state.lone_middle = [middle.x, middle.y, middle.z])
			object.tree_exited.connect(func() -> void: _scenario_state.lone_gone = _t)
			drop.dropped.connect(_on_loot_dropped)
			drop.dropped.connect(func(items: Array[Node3D]) -> void:
					_scenario_state.lone_blocked = _blocked_places(object, items, chop.lone_centre()))
			if not chop.strikeable.struck.is_connected(_log_strike):
				chop.strikeable.struck.connect(_log_strike)
			# After the tree's own handler, so the verdict is in.
			chop.strikeable.struck.connect(func(strike: Strike) -> void:
					var strikes: Array = _scenario_state.get("lone_strikes", [])
					strikes.append([_t, String(strike.striker.name) if strike.striker != null else "", strike.kind,
							strike.damage, str(TreeChop.Outcome.find_key(strike.judged.get("outcome", TreeChop.Outcome.NONE)))])
					_scenario_state.lone_strikes = strikes))


## What took the places of a lone piece's drops as they dropped, each in its
## ring at the middle's height, as it was turned: the bodies there a drop meets,
## the piece's own aside (its body, if it is one, and every body below it,
## internal ones too) and the drops' ("lone_blocked": per drop, each body as its
## parent's name and its own, since a tree builds its wood body unnamed).
## LootDrop raises a drop whose place is taken.
static func _blocked_places(object: Node3D, items: Array[Node3D], middle: Vector3) -> Array:
	var aside: Array[RID] = []
	var nodes: Array[Node] = [object]
	while not nodes.is_empty():
		var node: Node = nodes.pop_back()
		if node is CollisionObject3D:
			aside.append((node as CollisionObject3D).get_rid())
		nodes.append_array(node.get_children(true))
	for item in items:
		aside.append((item as CollisionObject3D).get_rid())
	var space := object.get_world_3d().direct_space_state
	var blocked := []
	for item in items:
		var query := PhysicsShapeQueryParameters3D.new()
		query.collision_mask = (item as CollisionObject3D).collision_mask
		query.exclude = aside
		var place := Transform3D(item.global_basis, Vector3(item.global_position.x, middle.y, item.global_position.z))
		var names := []
		for shape: CollisionShape3D in item.find_children("*", "CollisionShape3D", false, false):
			query.shape = shape.shape
			query.transform = place * shape.transform
			for hit: Dictionary in space.intersect_shape(query, 8):
				var body := hit.collider as Node
				var found := "%s/%s" % [body.get_parent().name, body.name]
				if found not in names:
					names.append(found)
		blocked.append(names)
	return blocked


## What a lone piece's readout shows: its health ("" before it is lone).
static func _lone_text(chop: TreeChop) -> String:
	for child in chop.tree.get_children():
		var display := child as TreeChopDisplay
		if display != null and display._health != null:
			return display._health.text
	return ""


## Follows a piece cut off the watched tree, or off one of its pieces, from the
## tick it was made (fall damage, 2026-10-03): as `role`; as broken_1, broken_2
## and on if an impact broke the line it came off at (fall damage); or unnamed
## until its scenario names it (_name_piece). Its record ("made"; "pieces_made"
## in the results): its role; what it was cut off ("parent": that piece's role,
## "tree" for the tree itself); whether an impact broke it off ("fall"); when
## ("t", and the physics "tick"); the line it came off at ("line": the branch's
## id, k); how high its wood's middle was then ("height", m) and how fast the
## wood it was cut off moved there ("parent_speed", m/s: that body's velocity
## and spin about its centre of mass as the engine had it before the cut, at
## the piece's middle); what it weighed. Then, every tick (_track_pieces), the
## fastest it went after its first step and when, the most contacts the engine
## reported for it, its hardest touching contact with something solid, when it
## came to rest and how it lay then, and when it left the level ("gone"). Every
## piece it is cut into is followed the same way, every impact on it logged
## (_on_impacted), and every cut on it timed (_on_cut_starting).
func _follow_piece(piece: FelledTree, parent: Node3D, role: String) -> void:
	var cutting: Dictionary = _scenario_state.get("cutting", {})
	var fall: bool = cutting.get("speed", 0.0) > 0.0
	if fall:
		var broken: Array = _scenario_state.get("broken", [])
		broken.append(piece)
		_scenario_state.broken = broken
		role = "broken_%d" % broken.size()
	var centre := piece.centre_of_mass()
	var speed := 0.0
	if parent is RigidBody3D:
		var body := parent as RigidBody3D
		var whole := body.global_position + PhysicsServer3D.body_get_direct_state(body.get_rid()).center_of_mass
		speed = (body.linear_velocity + body.angular_velocity.cross(centre - whole)).length()
	var made: Array = _scenario_state.get("made", [])
	var record := {"piece": piece, "id": piece.get_instance_id(), "parent_id": parent.get_instance_id(),
			"role": role, "parent": _role_of(parent), "fall": fall, "t": _t, "tick": Engine.get_physics_frames(),
			"line": cutting.get("line", []), "height": centre.y, "parent_speed": speed, "mass": piece.mass,
			"fastest": 0.0, "fastest_at": -1.0, "contacts": 0, "contacts_at": -1.0, "hardest": [0.0, -1.0, "", -1],
			"resting": -1.0, "rest_from": -1.0, "woke": -1.0, "gone": -1.0}
	made.append(record)
	_scenario_state.made = made
	if not cutting.is_empty():
		cutting.made = made.size() - 1
	# A lone piece struck to nothing goes at rest: its rest counts until then.
	piece.tree_exiting.connect(func() -> void:
			if _level != null and record.gone < 0.0:
				record.gone = _t
				_take_rest(record))
	piece.piece.severed.connect(_on_piece_severed.bind(piece))
	piece.piece.reshaped.connect(_on_cut_done)
	if piece.chop:
		piece.chop.changed.connect(_on_cut_starting.bind(piece.chop))
		piece.chop.impacted.connect(_on_impacted.bind(piece))


## Names a followed piece of the watched tree by its role (_follow_piece).
func _name_piece(piece: FelledTree, role: String) -> void:
	for record: Dictionary in _scenario_state.get("made", []):
		if record.id == piece.get_instance_id():
			record.role = role


## The role a piece of the watched tree goes by (_follow_piece; _tree_pieces):
## "tree" for the tree itself, "" for anything else.
func _role_of(piece: Object) -> String:
	if not is_instance_valid(piece):
		return ""
	var id := piece.get_instance_id()
	for record: Dictionary in _scenario_state.get("made", []):
		if record.id == id:
			return record.role
	return "tree" if id == _scenario_state.get("tree_id", 0) else ""


## What the fall damage logs call a body a piece of the watched tree met: a piece
## of the tree by its role, the tree's own wood "tree" (the stump, once it is
## felled), anything else by its name (the level's floor, walls and table are
## its "Static" CSG).
func _name_of(body: Object) -> String:
	if not is_instance_valid(body):
		return ""
	var role := _role_of(body)
	var node := body as Node
	if role == "" and node != null and node.get_parent() != null:
		role = _role_of(node.get_parent())
	if role != "":
		return role
	return String(node.name) if node != null else str(body)


## A piece of the watched tree was cut in two: the part beyond is followed too.
func _on_piece_severed(piece: FelledTree, parent: FelledTree) -> void:
	_follow_piece(piece, parent, "")


## A line of the watched tree, or of one of its pieces, is through and about to
## be cut (TreeChop emits changed just before it cuts): the role of what is cut,
## the line (its branch's id and k) and the branch's depth, how fast the impact
## that broke it closed (0 if none did), and the wall time it began, for the
## cut's record (_on_cut_done).
func _on_cut_starting(line: TreeChop.Line, chop: TreeChop) -> void:
	if line == null or line.open < line.total:
		return
	var skeleton := chop.tree.skeleton
	var branch := skeleton.branch_with_id(line.id)
	var cut: Node3D = chop.tree.collision_host if chop.tree.collision_host else chop.tree
	_scenario_state.cutting = {"from": Time.get_ticks_usec(), "role": _role_of(cut), "line": [line.id, line.k],
			"depth": skeleton.branch_depth[branch] if branch >= 0 else -1, "speed": line.broken_by}


## The tree, or a piece of it, took its new shape after a cut (ProceduralTree
## emits reshaped last as it cuts): the cut's record ("cuts"): when and in which
## physics tick, the role of what was cut, the line and its branch's depth,
## whether an impact broke it ("fall") and how fast that closed ("speed"), the
## piece it made ("made", by its role), and how long the cut took in wall time
## ("sever_us", microseconds: from the line going through until the piece cut
## took its new shape, building the new piece and the cut one's new shapes);
## the frame it happened in is timed by _time_frame ("frame_us").
func _on_cut_done() -> void:
	var cutting: Dictionary = _scenario_state.get("cutting", {})
	if cutting.is_empty():
		return
	_scenario_state.erase("cutting")
	var cuts: Array = _scenario_state.get("cuts", [])
	cuts.append({"t": _t, "tick": Engine.get_physics_frames(), "role": cutting.role, "line": cutting.line,
			"depth": cutting.depth, "fall": cutting.speed > 0.0, "speed": cutting.speed, "made": cutting.get("made", -1),
			"sever_us": Time.get_ticks_usec() - int(cutting.from), "frame_us": -1})
	_scenario_state.cuts = cuts


## An impact marked a line of a piece of the watched tree to break (fall
## damage): when and in which physics tick, the role of the piece, the line (its
## branch's id and k) and the branch's depth, how fast it closed, and where and
## on what it hit: the piece's contact that closed that fast, as FelledTree read
## it this tick ("impacts").
func _on_impacted(line: TreeChop.Line, speed: float, piece: FelledTree) -> void:
	var state := PhysicsServer3D.body_get_direct_state(piece.get_rid())
	var point := Vector3.ZERO
	var hit := ""
	var nearest := INF
	for i in state.get_contact_count():
		var closing := -(state.get_contact_local_velocity_at_position(i)
				- state.get_contact_collider_velocity_at_position(i)).dot(state.get_contact_local_normal(i))
		if absf(closing - speed) < nearest:
			nearest = absf(closing - speed)
			point = state.get_contact_local_position(i)
			hit = _name_of(state.get_contact_collider_object(i))
	var branch := piece.skeleton.branch_with_id(line.id)
	var impacts: Array = _scenario_state.get("impacts", [])
	impacts.append({"t": _t, "tick": Engine.get_physics_frames(), "role": _role_of(piece), "line": [line.id, line.k],
			"depth": piece.skeleton.branch_depth[branch] if branch >= 0 else -1, "speed": speed,
			"point": [point.x, point.y, point.z], "hit": hit})
	_scenario_state.impacts = impacts


## Times the frames of a tree scenario (fall damage, 2026-10-03), in wall time
## from one tick to the next, the harness's own work included ("frames": [time,
## microseconds]); each cut's record takes the time of the frame it happened in
## ("frame_us").
func _time_frame() -> void:
	var now := Time.get_ticks_usec()
	if _scenario_state.has("frame_from"):
		var took: int = now - int(_scenario_state.frame_from)
		var frames: Array = _scenario_state.get("frames", [])
		frames.append([_t, took])
		_scenario_state.frames = frames
		var tick := Engine.get_physics_frames() - 1
		for cut: Dictionary in _scenario_state.get("cuts", []):
			if cut.tick == tick:
				cut.frame_us = took
	_scenario_state.frame_from = now


## Follows every piece cut off the watched tree every tick, after the
## scenario's drive (fall damage, 2026-10-03; _follow_piece): the most contacts
## the engine reported for it, and when ("contacts", "contacts_at"); its hardest
## touching contact with something solid (the Static layer), read as FelledTree
## reads its contacts ("hardest": [closing speed, time, what it met, the depth
## of its branch there]); after its first step, the fastest it went and when;
## and when it came to rest: the start of its first rest (moving and turning
## under 0.05 m/s and rad/s) that held for REST_HOLD, or until it went or the
## scenario ended ("rest_from"; -1 if none), when how it lay is taken
## (_take_rest), and when it next moved, if it did ("woke"). And every tick,
## each awake piece's centre of mass, speed and spin ("pieces_log": [time,
## [role, x, y, z, speed, spin] for each piece in the level not asleep]; one
## asleep lies still).
func _track_pieces(t: float) -> void:
	var tick := Engine.get_physics_frames()
	var row: Array = [t]
	for record: Dictionary in _scenario_state.get("made", []):
		if not is_instance_valid(record.piece):
			continue
		var piece: FelledTree = record.piece
		var state := PhysicsServer3D.body_get_direct_state(piece.get_rid())
		if not piece.sleeping:
			var centre := piece.global_position + state.center_of_mass
			row.append([record.role, centre.x, centre.y, centre.z, piece.linear_velocity.length(),
					piece.angular_velocity.length()])
		if state.get_contact_count() > record.contacts:
			record.contacts = state.get_contact_count()
			record.contacts_at = t
		for i in state.get_contact_count():
			var other := state.get_contact_collider_object(i)
			var layer: int = other.get("collision_layer") if other != null and "collision_layer" in other else 0
			if not layer & FelledTree.STATIC_LAYER:
				continue
			var normal := state.get_contact_local_normal(i)
			var closing := -(state.get_contact_local_velocity_at_position(i)
					- state.get_contact_collider_velocity_at_position(i)).dot(normal)
			var gap := (state.get_contact_local_position(i) - state.get_contact_collider_position(i)).dot(normal)
			if closing > record.hardest[0] and Striker.touches(gap, closing, state.step, FelledTree.TOUCH_MARGIN):
				var branch := piece.piece.branch_of_shape(state.get_contact_local_shape(i))
				record.hardest = [closing, t, _name_of(other), piece.skeleton.branch_depth[branch] if branch >= 0 else -1]
		if tick <= record.tick:
			continue
		var speed := piece.linear_velocity.length()
		if speed > record.fastest:
			record.fastest = speed
			record.fastest_at = t
		if speed < 0.05 and piece.angular_velocity.length() < 0.05:
			if record.resting < 0.0:
				record.resting = t
			if record.rest_from < 0.0 and t - record.resting >= REST_HOLD - 1e-6:
				_take_rest(record)
		else:
			record.resting = -1.0
			if record.rest_from >= 0.0 and record.woke < 0.0:
				record.woke = t
	if row.size() > 1:
		var log: Array = _scenario_state.get("pieces_log", [])
		log.append(row)
		_scenario_state.pieces_log = log


## A followed piece of the watched tree has come to rest (_track_pieces), or is
## at rest as it goes or as the scenario ends: when its rest began ("rest_from"),
## how high its lowest point is ("lowest", m; the floor's top is at 0), and the
## bodies on the Static layer its shapes come within TOUCH_GAP of ("on", _near):
## what holds it up. Once.
func _take_rest(record: Dictionary) -> void:
	if record.rest_from >= 0.0 or record.resting < 0.0 or not is_instance_valid(record.piece):
		return
	record.rest_from = record.resting
	record.lowest = _lowest_point(record.piece)
	record.on = _near(record.piece, TOUCH_GAP, FelledTree.STATIC_LAYER)


## How high the lowest point of a body's collision shapes is in the world, in
## metres: its capsules' and cylinders' exactly, any other shape's outline.
static func _lowest_point(body: CollisionObject3D) -> float:
	return _lowest_point_at(body, body.global_transform)


## The same, were the body placed at `pose` in the world.
static func _lowest_point_at(body: CollisionObject3D, pose: Transform3D) -> float:
	var lowest := INF
	for owner_id in body.get_shape_owners():
		if body.is_shape_owner_disabled(owner_id):
			continue
		var place := pose * body.shape_owner_get_transform(owner_id)
		var axis := place.basis.y.normalized()
		var across := sqrt(maxf(1.0 - axis.y * axis.y, 0.0))
		for i in body.shape_owner_get_shape_count(owner_id):
			var shape := body.shape_owner_get_shape(owner_id, i)
			if shape is CapsuleShape3D:
				var capsule := shape as CapsuleShape3D
				lowest = minf(lowest, place.origin.y - absf(axis.y) * (capsule.height * 0.5 - capsule.radius)
						- capsule.radius)
			elif shape is CylinderShape3D:
				var cylinder := shape as CylinderShape3D
				lowest = minf(lowest, place.origin.y - absf(axis.y) * cylinder.height * 0.5 - cylinder.radius * across)
			else:
				for point: Vector3 in shape.get_debug_mesh().surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
					lowest = minf(lowest, (place * point).y)
	return lowest


## The bodies on `mask`'s layers that a piece's shapes, each grown by `gap` (m),
## overlap as it lies, by what the fall damage logs call them (_name_of).
func _near(piece: FelledTree, gap: float, mask: int) -> Array:
	var space := piece.get_world_3d().direct_space_state
	var query := PhysicsShapeQueryParameters3D.new()
	query.collision_mask = mask
	var aside: Array[RID] = [piece.get_rid()]
	query.exclude = aside
	var names := []
	for owner_id in piece.get_shape_owners():
		if piece.is_shape_owner_disabled(owner_id):
			continue
		query.transform = piece.global_transform * piece.shape_owner_get_transform(owner_id)
		for i in piece.shape_owner_get_shape_count(owner_id):
			query.shape = _grown(piece.shape_owner_get_shape(owner_id, i), gap)
			for hit: Dictionary in space.intersect_shape(query, 32):
				var found := _name_of(hit.collider)
				if found not in names:
					names.append(found)
	return names


## How many leaf clusters a piece of the watched tree has left, with every piece
## cut or broken off it, and off those, still in the level (fall damage takes a
## limb off with its leaves).
func _family_leaves(top: FelledTree) -> int:
	var family := [top.get_instance_id()]
	var leaves := top.leaves_left()
	for record: Dictionary in _scenario_state.get("made", []):
		if record.parent_id in family:
			family.append(record.id)
			if is_instance_valid(record.piece):
				leaves += (record.piece as FelledTree).leaves_left()
	return leaves


## The followed pieces and cuts as the results keep them (fall damage), once the
## scenario is over: a piece still at rest at the end, its rest taken if it was
## not (_take_rest), and how one still moving lies ("lowest", "on"); each piece's
## record without the piece ("pieces_made"); each cut naming the piece it made by
## its role; and the frames' wall time from the start ("frame_us": {"median",
## "max", "max_at"}, microseconds).
func _export_pieces() -> void:
	var made: Array = _scenario_state.get("made", [])
	var pieces := []
	for record: Dictionary in made:
		_take_rest(record)
		if is_instance_valid(record.piece) and not record.has("on"):
			record.lowest = _lowest_point(record.piece)
			record.on = _near(record.piece, TOUCH_GAP, FelledTree.STATIC_LAYER)
		var entry := record.duplicate()
		for key: String in ["piece", "id", "parent_id"]:
			entry.erase(key)
		pieces.append(entry)
	_scenario_state.pieces_made = pieces
	for cut: Dictionary in _scenario_state.get("cuts", []):
		cut.made = made[cut.made].role if cut.made is int and cut.made >= 0 else ""
	var frames: Array = (_scenario_state.get("frames", []) as Array).filter(
			func(frame: Array) -> bool: return frame[0] >= 0.0)
	if not frames.is_empty():
		var took: Array = frames.map(func(frame: Array) -> int: return frame[1])
		took.sort()
		var longest: Array = frames[0]
		for frame: Array in frames:
			if frame[1] > longest[1]:
				longest = frame
		_scenario_state.frame_us = {"median": took[took.size() / 2], "max": longest[1], "max_at": longest[0]}


## Logs a felled tree's falling top every tick from the cut ("fall_log": [time,
## its centre of mass x, y, z, its speed, its trunk's tilt from upright in
## degrees, whether it sleeps, how many leaf clusters it has left with the
## pieces broken off it (_family_leaves)]), while it is in the level. While it
## is hinged to the stump (FelledTree), how far the point of it first seen at
## the hinge is from the hinge ("hinge_log": [time, metres]), through any cut
## on it meanwhile (fall damage, 2026-10-03).
func _log_fall(t: float) -> void:
	if not is_instance_valid(_scenario_state.fall_piece):
		return
	var top: FelledTree = _scenario_state.fall_piece
	var state := PhysicsServer3D.body_get_direct_state(top.get_rid())
	var centre := top.global_position + state.center_of_mass
	var trunk := top.global_basis * (_scenario_state.fall_trunk as Vector3)
	var log: Array = _scenario_state.get("fall_log", [])
	log.append([t, centre.x, centre.y, centre.z, top.linear_velocity.length(),
			rad_to_deg(trunk.angle_to(Vector3.UP)), top.sleeping, _family_leaves(top)])
	_scenario_state.fall_log = log
	for child in top.get_children():
		var hinge := child as HingeJoint3D
		if hinge == null or hinge.is_queued_for_deletion():
			continue
		if not _scenario_state.has("hinge_point"):
			_scenario_state.hinge_point = top.global_transform.affine_inverse() * hinge.global_position
		var hinged: Array = _scenario_state.get("hinge_log", [])
		hinged.append([t, (top.global_transform * (_scenario_state.hinge_point as Vector3)).distance_to(
				hinge.global_position)])
		_scenario_state.hinge_log = hinged


## Weighs the pieces cut off the watched tree (2026-10-02), every tick after the
## scenario's drive, each once, by its role (_tree_pieces: "top", "rest", "cut",
## then those impacts broke off, broken_1 and on; the felled top is the top,
## though it was also the first piece cut off): as it first appears and again
## whenever it is cut itself (its skeleton changes), what it weighs and what the
## weight rule makes of its skeleton then ("weighed": [time, role, its mass, the
## rule's mass, its trunk's segments of wood, its other branches'],
## _weight_rule); and every tick while it is in the level, what it weighs and
## how many of its branches broke off since it was last cut ("weight_now": by
## role, [time, mass, branches gone]).
func _track_weights(scenario: Dictionary, t: float) -> void:
	var pieces := _tree_pieces(scenario)
	var skeletons: Dictionary = _scenario_state.get("weighed_skeletons", {})
	var seen: Array[FelledTree] = []
	for role: String in pieces:
		var piece := pieces[role] as FelledTree
		if piece == null or piece in seen:
			continue
		seen.append(piece)
		if skeletons.get(piece.get_instance_id()) != piece.skeleton:
			skeletons[piece.get_instance_id()] = piece.skeleton
			var rule := _weight_rule(piece)
			var weighed: Array = _scenario_state.get("weighed", [])
			weighed.append([t, role, piece.mass, rule[0], rule[1], rule[2]])
			_scenario_state.weighed = weighed
		var now: Dictionary = _scenario_state.get("weight_now", {})
		now[role] = [t, piece.mass, piece.piece.gone_branches().count(1)]
		_scenario_state.weight_now = now
	_scenario_state.weighed_skeletons = skeletons


## What the weight rule makes a piece cut off a tree weigh, by its skeleton as
## it is (2026-10-02): TRUNK_SEGMENT_KG for each segment of wood on a trunk (a
## branch of depth 0), BRANCH_SEGMENT_KG for each on any other branch but a
## twig, which weighs nothing (TreeSkeleton.wood_segments and is_twig, at its
## species' collision_min_radius_m), and at least 1 kg: [that mass, the
## trunk's segments, the other branches'].
static func _weight_rule(piece: FelledTree) -> Array:
	var skeleton := piece.skeleton
	var thinnest := piece.species.collision_min_radius_m
	var trunk := 0
	var branches := 0
	for branch in skeleton.branch_count():
		if skeleton.is_twig(branch, thinnest):
			continue
		if skeleton.branch_depth[branch] == 0:
			trunk += skeleton.wood_segments(branch, thinnest)
		else:
			branches += skeleton.wood_segments(branch, thinnest)
	return [maxf(TRUNK_SEGMENT_KG * trunk + BRANCH_SEGMENT_KG * branches, 1.0), trunk, branches]


## Logs the loot a watched vein or lone piece dropped, and when
## ("loot_dropped"): each item's scene, where it appeared, how far its shapes
## reach from there and its mass, in kg, if it is a body ("loot"). The items
## themselves are kept for _log_loot ("loot_items").
func _on_loot_dropped(items: Array[Node3D]) -> void:
	_scenario_state.loot_dropped = _t
	_scenario_state.loot_items = items
	var loot: Array = []
	for item in items:
		var at := item.global_position
		loot.append({"scene": item.scene_file_path, "spawn": [at.x, at.y, at.z], "reach": _reach_of(item),
				"mass": (item as RigidBody3D).mass if item is RigidBody3D else 0.0})
	_scenario_state.loot = loot


## Logs the dropped loot every tick ("loot_log": [time, per item its position,
## velocity and turning velocity, how high its lowest point is, and how far its
## length, its Y, is turned from level, in degrees: 0 lying, 90 standing]).
func _log_loot(t: float) -> void:
	var items: Array = _scenario_state.get("loot_items", [])
	if items.is_empty():
		return
	var entry: Array = [t]
	for item: RigidBody3D in items:
		var at := item.global_position
		var moving := item.linear_velocity
		var turning := item.angular_velocity
		var length := item.global_basis.y.normalized()
		entry.append([at.x, at.y, at.z, moving.x, moving.y, moving.z, turning.x, turning.y, turning.z,
				_lowest_of(item), rad_to_deg(asin(clampf(absf(length.y), 0.0, 1.0)))])
	var log: Array = _scenario_state.get("loot_log", [])
	log.append(entry)
	_scenario_state.loot_log = log


## How far `item`'s collision shapes reach from its origin, in metres: the
## farthest of their points (_shape_points).
static func _reach_of(item: Node3D) -> float:
	var reach := 0.0
	for shape: CollisionShape3D in item.find_children("*", "CollisionShape3D", false, false):
		for point in _shape_points(shape):
			reach = maxf(reach, (shape.transform * point).length())
	return reach


## How high the lowest of `item`'s collision shapes' points (_shape_points) is
## in the world, in metres.
static func _lowest_of(item: Node3D) -> float:
	var lowest := INF
	for shape: CollisionShape3D in item.find_children("*", "CollisionShape3D", false, false):
		for point in _shape_points(shape):
			lowest = minf(lowest, (shape.global_transform * point).y)
	return lowest


## A collision shape's points, in its own space: a convex shape's, or the
## corners of another shape's outline.
static func _shape_points(shape: CollisionShape3D) -> PackedVector3Array:
	if shape.shape is ConvexPolygonShape3D:
		return (shape.shape as ConvexPolygonShape3D).points
	return shape.shape.get_debug_mesh().surface_get_arrays(0)[Mesh.ARRAY_VERTEX]


## Finds the level's player, swaps in the requested player scene if there is
## one, and puts it at `start`. The level is not in the tree yet.
## How to lay `level` for a scenario at the feature `at` (ARENA): turned about
## the vertical and moved along the floor, so the feature lies where the
## scenario was written for it.
func _arena_transform(level: Node, at: String) -> Transform3D:
	var here := _feature_pose(level, at)
	var there: Transform3D = ARENA[at]
	var turn := Basis(Vector3.UP, _heading(here.basis).signed_angle_to(_heading(there.basis), Vector3.UP))
	var shift := there.origin - turn * here.origin
	shift.y = 0.0
	return Transform3D(turn, shift)


## Where the feature `at` lies in `level`, in the level's own space, as ARENA
## has it: from the level's named nodes.
func _feature_pose(level: Node, at: String) -> Transform3D:
	match at:
		"open":
			return _node_pose(level, ^"OpenFloor")
		"lane":
			return _node_pose(level, ^"OpenLane")
		"boxes":
			return _node_pose(level, ^"Dynamic/LightBox")
		"weapons":
			var table := _node_pose(level, ^"Static/Table")
			var size := (level.get_node(^"Static/Table") as CSGBox3D).size
			return Transform3D(_level_basis(table.basis), table * Vector3(0.0, size.y * 0.5, size.z * 0.5))
		"steps":
			var step := _node_pose(level, ^"Static/Step1")
			var size := (level.get_node(^"Static/Step1") as CSGBox3D).size
			return Transform3D(_level_basis(step.basis), step * Vector3(0.0, size.y * 0.5, 0.0))
		"wall":
			# Its face on its thinner side toward the floor, facing out of it.
			var wall := _node_pose(level, ^"Static/Wall")
			var size := (level.get_node(^"Static/Wall") as CSGBox3D).size
			var across := wall.basis.x.normalized() if size.x <= size.z else wall.basis.z.normalized()
			var toward_floor := _node_pose(level, ^"Static/Floor").origin - wall.origin
			var out := across if across.dot(toward_floor) > 0.0 else -across
			return Transform3D(_facing(out), wall.origin + out * minf(size.x, size.z) * 0.5)
		"hold1", "hold4":
			var face := _feature_pose(level, "wall")
			var hold := _node_pose(level, NodePath("Holds/Hold" + at.right(1)))
			var out := -face.basis.z
			return Transform3D(face.basis, hold.origin + out * (face.origin - hold.origin).dot(out))
		"pit_hole":
			var hole := _node_pose(level, ^"Static/PitHole")
			return Transform3D(_level_basis(hole.basis), hole.origin)
		"ramp15_top":
			var ramp15 := _ramp_top(level, ^"Static/Ramp15")
			return Transform3D(_facing(ramp15[1] - ramp15[0]), ramp15[0])
		"pit_top", "pit_foot":
			var ramp := _ramp_top(level, ^"Static/PitRamp")
			var high: Vector3 = ramp[0]
			var low: Vector3 = ramp[1]
			var down := Vector3(low.x - high.x, 0.0, low.z - high.z)
			if at == "pit_top":
				return Transform3D(_facing(down), high)
			# Where its top meets the PitFloor's.
			var bottom := _node_pose(level, ^"Static/PitFloor")
			var floor_y := bottom.origin.y + (level.get_node(^"Static/PitFloor") as CSGBox3D).size.y * 0.5
			return Transform3D(_facing(-down), high.lerp(low, (high.y - floor_y) / (high.y - low.y)))
	push_error("run_scenarios: no feature \"%s\"." % at)
	return Transform3D.IDENTITY


## A ramp's top face along its length (the ramp at `path`, a CSGBox3D), in the
## level's space: its high end and its low end, each in the middle of its width.
func _ramp_top(level: Node, path: NodePath) -> Array[Vector3]:
	var ramp := _node_pose(level, path)
	var size := (level.get_node(path) as CSGBox3D).size
	var along := ramp.basis.x.normalized() * size.x * 0.5 if size.x >= size.z \
			else ramp.basis.z.normalized() * size.z * 0.5
	var top := ramp.origin + ramp.basis.y.normalized() * size.y * 0.5
	var ends: Array[Vector3] = [top + along, top - along]
	if ends[1].y > ends[0].y:
		ends.reverse()
	return ends


## How high the top of the ramp at `path` is under `start`, a point in the
## world with the level laid for its scenario.
func _ramp_height(level: Node, path: NodePath, start: Vector3) -> float:
	var local := (level as Node3D).transform.affine_inverse() * start
	var ramp := _node_pose(level, path)
	var normal := ramp.basis.y.normalized()
	var top: Vector3 = _ramp_top(level, path)[0]
	return top.y - (normal.x * (local.x - top.x) + normal.z * (local.z - top.z)) / normal.y


## `path`'s transform in `level`'s own space (the level is not in the tree yet).
func _node_pose(level: Node, path: NodePath) -> Transform3D:
	var node := level.get_node_or_null(path) as Node3D
	if node == null:
		push_error("run_scenarios: the level has no %s." % path)
		return Transform3D.IDENTITY
	var pose := node.transform
	var parent := node.get_parent()
	while parent != level:
		pose = (parent as Node3D).transform * pose
		parent = parent.get_parent()
	return pose


## The way a pose faces along the floor: its -Z, level.
static func _heading(basis: Basis) -> Vector3:
	var forward := -basis.z
	return Vector3(forward.x, 0.0, forward.z).normalized()


## A level basis facing `direction` along the floor.
static func _facing(direction: Vector3) -> Basis:
	return Basis.looking_at(Vector3(direction.x, 0.0, direction.z).normalized(), Vector3.UP)


## `basis` turned only about the vertical: its facing along the floor.
static func _level_basis(basis: Basis) -> Basis:
	return _facing(_heading(basis))


func _place_player(level: Node, start: Vector3) -> Player:
	var player: Player = null
	for child in level.get_children():
		if child is Player:
			player = child
			break
	if player == null:
		return null
	if _player_scene != null:
		var index := player.get_index()
		var player_name := player.name
		level.remove_child(player)
		player.free()
		player = _player_scene.instantiate() as Player
		player.name = player_name
		level.add_child(player)
		level.move_child(player, index)
	# At `start` in the world, not turned with the level.
	player.transform = (level as Node3D).transform.affine_inverse() * Transform3D(Basis.IDENTITY, start)
	return player


func _finish(scenario: Dictionary) -> void:
	if scenario.get("guided", false):
		_guided_ran = true
		var recorder := _debug.recorder
		var first_line := _debug.readout.text.get_slice("\n", 0)
		_guided_ok = recorder.recording and recorder.path.begins_with(SMOKE_DIRECTORY) \
				and first_line.begins_with("Test 1 of")
		print("guided: recording=%s readout=\"%s\"" % [recorder.recording, first_line])
		recorder.stop()
	else:
		var path := _debug.recorder.stop()
		var position := _state.body_position
		var result := {
			"name": scenario.name,
			"title": scenario.title,
			"csv": ProjectSettings.globalize_path(path),
			"final_position": [position.x, position.y, position.z],
			"final_head_lead": _state.head_lead.length(),
			"start_height": _scenario_state.get("start_height", 0.0),
			# How far the rig ended up from where it started, horizontally: the
			# view's drift against the real room, in metres.
			"rig_drift": Vector2(_player.rig.global_position.x - scenario.start.x,
					_player.rig.global_position.z - scenario.start.z).length(),
			# How dark the interface's view fade got, 0 to 1.
			"fade_max": _scenario_state.get("fade_max", 0.0),
			"rig_offset": [_player.rig.global_position.x - scenario.start.x,
					_player.rig.global_position.z - scenario.start.z],
			"analysis": Analysis.summarize(Analysis.load_rows(path)),
		}
		var physical := _player.physical as DynamicPhysical
		if physical != null:
			result.response_time = physical.body.response_time
			result.hand_recoveries = physical.left_drive.recoveries + physical.right_drive.recoveries
			result.turn_error_max = _scenario_state.get("turn_error_max", 0.0)
			result.turn_error_final = _scenario_state.get("turn_error", 0.0)
			result.palm_half_thickness = _palm_half_thickness()
			result.finger_sink = _scenario_state.get("finger_sink", -1.0)
			result.finger_sink_held = _scenario_state.get("finger_sink_held", -1.0)
			result.part_sink = _scenario_state.get("part_sink", 0.0)
			result.part_sink_held = _scenario_state.get("part_sink_held", 0.0)
			# The strike buzzes in each hand (HandHaptics), kept only when there were any.
			var haptics := _player.interface.hand_haptics if _player.interface != null else null
			if haptics != null and haptics.strike_pulses[0] + haptics.strike_pulses[1] > 0:
				result.strike_pulses = [haptics.strike_pulses[0], haptics.strike_pulses[1]]
			if scenario.has("tree"):
				_export_pieces()
			for key: String in ["finger_depth", "finger_depth_held", "finger_twitch", "finger_bends",
					"finger_held", "box_moved", "prop_moved", "prop_rise", "prop_speed", "palm_depth", "kicked",
					"wrist_turn", "held_rise_min", "held_rise_max", "box_tilt", "held_turn", "hand_pulled",
					"rise_LightBox", "rise_MediumBox", "hand_came", "crate_came",
					"swing_gap", "swing_separation", "swing_past", "swing_behind", "still_held", "swing_hand_past",
					"arm_shaped_ticks", "arm_hand_gap", "arm_hand_gap_raw", "arm_hand_turn", "arm_hand_turn_raw",
					"arm_elbow_gap", "arm_elbow_raw", "arm_bone_turn", "arm_bone_raw", "arm_stretch",
					"arm_stretch_gap", "arm_clamp", "arm_target_motion", "arm_lift", "arm_phases",
					"arm_rest_ticks", "arm_rest_hand", "arm_rest_turn", "arm_rest_elbow", "arm_rest_bone",
					"arm_rest_touching", "grab_on_handle", "weapon_rest", "skeleton_toggled", "view", "model", "two_hand",
					"hold", "release", "step", "push", "flick", "handle_grab", "climb", "turn", "throw",
					"strikes", "box_log", "vein_maximum", "vein_health", "vein_depleted", "vein_gone",
					"loot_scene", "vein_bounds", "vein_position", "loot", "loot_dropped", "loot_log",
					"segment_length", "chop_cap", "chop_fell_at", "chop_spill", "chop_sides", "chop_open",
					"chop_felled", "tree_gone", "fall_toward", "fall_started", "fall_log", "stump_length",
					"stump_solid", "dropped", "drop_log", "severed", "line_cut", "line_at", "line_gone", "limb_log",
					"stub_capped", "stub_lines", "bucked", "buck_cut", "buck_lines", "buck_gone", "buck_log",
					"swing_from", "line_choppable", "lone", "lone_health", "lone_depleted", "lone_middle",
					"lone_gone", "lone_blocked", "lone_pieces", "lone_strikes", "lone_struck", "still_log", "still_drop",
					"leaves_start", "leaves_end", "branches_gone", "box_nearest", "weighed", "weight_now",
					"impact_speed", "impacts", "cuts", "pieces_made", "pieces_log", "frame_us", "laid", "hinge_log",
					"roll_mass", "roll_at", "roll_log", "walked", "walked_log", "mirror_only",
					"grip_from_centre", "hand_from_centre", "left_grip_from_centre", "left_hand_from_centre",
					"seat", "regrab", "neighbour_moved", "seat_time", "held_speed", "run_hold", "respawn_hold",
					"look", "held_contact"]:
				if _scenario_state.has(key):
					result[key] = _scenario_state[key]
		_results.append(result)
	_level.queue_free()
	_level = null
	_rig.release()
	_teardown = TEARDOWN_FRAMES


func _report() -> void:
	DirAccess.make_dir_recursive_absolute(_directory)
	var results_path := _directory.path_join("results.json")
	var file := FileAccess.open(results_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(_results, "  "))
		file.close()
	print("RESULTS %s" % ProjectSettings.globalize_path(results_path))
	for result in _results:
		var a: Dictionary = result.analysis
		print("%-18s %5.1f s  top %.2f m/s  airborne %.2f s  rise %.3f m  pulled %.3f m  head %.2f-%.2f  end %s" % [
				result.name, a.duration, a.top_speed, a.airborne_time, a.largest_rise,
				a.pulled_back, a.head_min, a.head_max, _rounded(result.final_position)])
	var passed := true
	match _mode:
		Mode.ACCEPTANCE:
			if _compare:
				_print_comparison()
			passed = _check_acceptance()
		Mode.REFERENCE:
			passed = _check_reference()
		Mode.WRITE:
			passed = _save_reference()
	passed = _check_checklist() and passed
	if _guided_ran:
		print("GUIDED %s" % ("PASS" if _guided_ok else "FAIL"))
		passed = passed and _guided_ok
	print("HARNESS %s" % ("PASS" if passed else "FAIL"))
	quit(0 if passed else 1)


## The acceptance criteria for the dynamic body, as of rung 3. They check that the body
## does what its formulation says, with tolerances; how it feels is decided
## in the headset. Motor timings are derived from the body's response time:
## a first-order approach closes 90 % of a speed change in about τ·ln 10,
## stops from speed v in about τ·ln(v / 0.05 m/s), and coasts about v·τ.
func _acceptance(result: Dictionary) -> Array[String]:
	var a: Dictionary = result.analysis
	var failures: Array[String] = []
	var presses: Array = a.presses
	var falls: Array = a.falls
	var lifts: Array = a.get("lifts", [])
	var descents: Array = a.get("descents", [])
	var tau: float = result.get("response_time", 0.12)
	# A small box on the floor is a step the assist may lift onto, as the
	# steps are (step checks include props, section 6.8); so is a lone stick
	# (2026-10-03).
	if result.name not in ["steps", "walk_kick_box", "lone_stick_walked_into"]:
		_expect(failures, lifts.is_empty(), "no step lift (%d)" % lifts.size())
	_expect(failures, result.get("hand_recoveries", 0) == 0,
			"no hand moved to its target after sticking (%d)" % result.get("hand_recoveries", 0))
	var fade: float = result.get("fade_max", 0.0)
	if result.name not in ["wall", "wall_through", "respawn", "respawn_holding", "climb_walk_away"]:
		_expect(failures, fade == 0.0, "view never faded (%.2f)" % fade)
	if result.name not in ["wall_through", "respawn", "respawn_holding", "climb_walk_away"]:
		_expect(failures, a.relocations == 0, "no recentre or respawn (%d)" % a.relocations)
	if result.has("model"):
		_accept_model(failures, result.name, result.model)
	match result.name:
		"stand":
			_expect(failures, a.wander_max <= 0.005, "drift %.4f m <= 0.005" % a.wander_max)
			_expect(failures, a.airborne_time == 0.0, "never airborne (%.3f s)" % a.airborne_time)
		"flat_full":
			if _expect(failures, presses.size() == 1, "one stick press (%d)" % presses.size()):
				var press: Dictionary = presses[0]
				var speed: float = press.commanded
				_expect(failures, absf(press.ratio - 1.0) <= 0.02, "speed ratio %.3f within 2 %%" % press.ratio)
				_expect_near(failures, press.rise_time, tau * log(10.0), 0.3, "90 %% rise time")
				_expect_near(failures, press.stop_distance, speed * tau, 0.3, "stopping distance")
				_expect(failures, press.stop_time > 0.0 and press.stop_time <= 1.3 * tau * log(speed / 0.05),
						"stop time %.3f s <= %.3f" % [press.stop_time, 1.3 * tau * log(speed / 0.05)])
			_expect(failures, a.airborne_time == 0.0, "never airborne (%.3f s)" % a.airborne_time)
		"flat_half":
			if _expect(failures, presses.size() == 1, "one stick press (%d)" % presses.size()):
				_expect(failures, absf(presses[0].ratio - 1.0) <= 0.02, "speed ratio %.3f within 2 %%" % presses[0].ratio)
		"steps":
			if _expect(failures, presses.size() == 2, "up and back down (%d presses)" % presses.size()):
				_expect(failures, presses[0].climb >= 0.73, "climbed to the top (%.3f m)" % presses[0].climb)
				_expect(failures, presses[0].length <= 3.5, "top reached in %.2f s <= 3.5" % presses[0].length)
				_expect(failures, presses[1].climb <= -0.73, "came back down (%.3f m)" % presses[1].climb)
			if _expect(failures, lifts.size() == 3, "one lift per step (%d)" % lifts.size()):
				for lift: Dictionary in lifts:
					_expect(failures, lift.duration <= 0.35, "lift took %.2f s <= 0.35" % lift.duration)
					_expect(failures, lift.height >= 0.15, "lift rose %.3f m >= 0.15" % lift.height)
			_expect(failures, descents.size() >= 3, "stepped down each step (%d)" % descents.size())
			_expect(failures, a.largest_rise <= 0.04, "no snap up: %.3f m in one tick <= 0.04" % a.largest_rise)
			_expect(failures, a.largest_drop <= 0.04, "no snap down: %.3f m in one tick <= 0.04" % a.largest_drop)
			_expect(failures, a.airborne_time <= 0.05, "airborne %.3f s <= 0.05" % a.airborne_time)
		"run_hold_sword", "run_hold_heavy_box", "run_hold_longsword":
			# Rung 8.1 (2026-10-02): what a hand holds moves with it, at a run
			# as at rest, and is drawn there.
			var run: Dictionary = result.get("run_hold", {})
			_expect(failures, run.get("held_throughout", false), "held throughout the run")
			_expect(failures, run.get("speed_max", 0.0) >= 3.0, "ran (top speed %.2f m/s >= 3)" % run.get("speed_max", 0.0))
			_expect(failures, run.get("gap_max", INF) <= 0.005, "grab points %.4f m apart <= 0.005" % run.get("gap_max", INF))
			# Held in one hand, it is welded there. Two hands each hold a point of
			# it and turn on it as their wrists do, the lead only its roll.
			if result.name != "run_hold_longsword":
				var turn_limit := 3.0 if result.name == "run_hold_heavy_box" else 1.5
				_expect(failures, run.get("turn_max", INF) <= turn_limit,
						"turned %.2f° in the hand <= %.1f" % [run.get("turn_max", INF), turn_limit])
				_expect(failures, run.get("tip_slip_max", INF) <= 0.02,
						"furthest point moved %.4f m in the hand <= 0.02" % run.get("tip_slip_max", INF))
			# Rung 8.2: the legs carry it along and pay for it; the arm only takes
			# the hand's own motion, so the hand keeps up with its target.
			var masses := {"run_hold_sword": 1.2, "run_hold_heavy_box": 10.0, "run_hold_longsword": 1.9}
			var mass: float = masses[result.name]
			_expect(failures, absf(run.get("carried", 0.0) - mass) <= 0.02 * mass,
					"the legs carried its %.2f kg (%.2f)" % [mass, run.get("carried", 0.0)])
			_expect(failures, run.get("behind_max", INF) <= 0.1,
					"the hand kept up with its target (%.3f m behind at most <= 0.1)" % run.get("behind_max", INF))
			if result.name == "run_hold_heavy_box":
				_expect(failures, run.get("speed_max", INF) <= 5.5, "the load slowed the run (top %.2f m/s <= 5.5)" % run.get("speed_max", INF))
			_expect(failures, a.drawn_slip_held_max - a.grab_gap_held_max <= 0.001,
					"drawn %.4f m off the hand, beyond the grab points' %.4f m by <= 0.001" % [a.drawn_slip_held_max, a.grab_gap_held_max])
		"room_walk":
			# The body stays under the head during real walking, and following
			# never moves the view: the world stays fixed to the real room.
			_expect(failures, a.head_lead_max <= 0.1, "head led the body by %.3f m <= 0.1" % a.head_lead_max)
			_expect(failures, result.final_head_lead <= 0.02, "back under the head (%.3f m)" % result.final_head_lead)
			_expect(failures, result.rig_drift <= 0.01, "view drifted %.3f m <= 0.01" % result.rig_drift)
		"stick_room_walk":
			# Stick and room-scale walking combine seamlessly: the view moves
			# with the stick alone, and the body stays under the head.
			_expect(failures, a.view_error_max <= 0.1,
					"view moved with the stick (strayed %.3f m/s <= 0.1)" % a.view_error_max)
			_expect(failures, a.stick_room_distance >= 2.0,
					"walked %.2f m in the room with the stick held >= 2.0" % a.stick_room_distance)
			_expect(failures, a.head_lead_max <= 0.1, "head led the body by %.3f m <= 0.1" % a.head_lead_max)
			_expect(failures, result.final_head_lead <= 0.02, "back under the head (%.3f m)" % result.final_head_lead)
			_expect(failures, absf(result.rig_offset[1]) <= 0.02,
					"walking across the stick left the view's side position alone (%.3f m)" % result.rig_offset[1])
		"slope_walk":
			_expect(failures, a.head_lead_max <= 0.1, "head led the body by %.3f m <= 0.1" % a.head_lead_max)
			_expect(failures, result.rig_drift <= 0.01, "view drifted %.3f m <= 0.01" % result.rig_drift)
			_expect(failures, a.airborne_time <= 0.05, "airborne %.3f s <= 0.05" % a.airborne_time)
		"table_straight", "table_oblique":
			# The body stops at the pedestal; a clear head may lean past its edge
			# by the lean limit, then the view is pushed back. Nothing but the
			# push-back moves the view.
			_expect(failures, a.x_max <= 0.56, "body stopped at the pedestal (x %.3f <= 0.56)" % a.x_max)
			_expect(failures, a.head_lead_max <= 0.36, "head lead held to %.3f m <= 0.36" % a.head_lead_max)
			_expect(failures, a.pulled_back >= 0.1, "view pushed back %.3f m >= 0.1" % a.pulled_back)
			# The hips and legs stand with the body, so they stop with it and
			# the torso leans over the pedestal from there: no part pushes the
			# view, and the head never gets into it.
			_expect(failures, absf(result.rig_drift - a.pulled_back) <= 0.01,
					"view moved only by the push-back (%.3f m against %.3f m)" % [result.rig_drift, a.pulled_back])
			_expect(failures, a.head_obstruction_max <= 0.02,
					"head stayed out of the pedestal (%.3f m)" % a.head_obstruction_max)
		"hands_free":
			# Hands follow their targets closely in free space and do not
			# disturb the body.
			_expect(failures, a.left_separation_max <= 0.05 and a.right_separation_max <= 0.05,
					"hands within 0.05 m of their targets (%.3f, %.3f)" % [a.left_separation_max, a.right_separation_max])
			_expect(failures, a.wander_max <= 0.01, "body stayed put (%.3f m)" % a.wander_max)
			_expect(failures, result.rig_drift <= 0.01, "view drifted %.3f m <= 0.01" % result.rig_drift)
			_expect(failures, a.hand_contacts == 0, "touched nothing (%d)" % a.hand_contacts)
		"hand_wall_one":
			# One hand pushed into the wall: it stops at the surface, steady; the
			# push moves the body back and then it stops.
			var rows := Analysis.load_rows(result.csv)
			var reach := _column_max(rows, "right_hand_z", 0.0, INF)
			var shake := _column_span(rows, "right_hand_z", 3.0, 4.0)
			var pushed: float = rows[0].z - _column_min(rows, "z", 0.0, 4.0)
			var creep := _column_span(rows, "z", 3.5, 4.0)
			var surface: float = 4.0 - result.palm_half_thickness
			_expect(failures, reach <= surface + 0.005,
					"palm stopped flat at the wall (z %.3f <= %.3f)" % [reach, surface + 0.005])
			_expect(failures, shake <= 0.01, "hand steady against the wall (%.4f m)" % shake)
			_expect(failures, pushed >= 0.03, "the push moved the body back (%.3f m)" % pushed)
			_expect(failures, creep <= 0.005, "then it stopped (%.4f m in the last 0.5 s)" % creep)
			_expect(failures, a.hand_contacts >= 1, "the touch was reported (%d)" % a.hand_contacts)
		"hand_wall_two":
			# Both hands pushing hard: the body is pushed back as far as the push
			# goes, stops, and stays there when released. The view moves with it.
			var rows := Analysis.load_rows(result.csv)
			var start_z: float = rows[0].z
			var pushed := start_z - _column_min(rows, "z", 0.0, INF)
			var kept: float = start_z - rows[-1].z
			var settled_speed := _column_max(rows, "speed", 3.5, 4.0)
			var shake := maxf(_column_span(rows, "left_hand_z", 3.0, 4.0), _column_span(rows, "right_hand_z", 3.0, 4.0))
			_expect(failures, pushed >= 0.05 and pushed <= 0.5, "body pushed back %.3f m, 0.05 to 0.5" % pushed)
			_expect(failures, pushed - kept <= 0.02, "stayed back when released (%.3f of %.3f m)" % [kept, pushed])
			_expect(failures, settled_speed <= 0.02, "then stopped (%.3f m/s)" % settled_speed)
			_expect(failures, absf(result.rig_drift - kept) <= 0.01,
					"view ended with the body (%.3f m against %.3f m)" % [result.rig_drift, kept])
			_expect(failures, shake <= 0.01, "hands steady against the wall (%.4f m)" % shake)
			_expect(failures, a.hand_contacts >= 2, "both touches reported (%d)" % a.hand_contacts)
		"hand_table_press":
			# A hand pressed down on the table stops on it, steady, and does not
			# lift or move the body.
			var rows := Analysis.load_rows(result.csv)
			var lowest := _column_min(rows, "right_hand_y", 2.5, 3.5)
			var shake := _column_span(rows, "right_hand_y", 2.8, 3.4)
			var surface: float = 1.0 + result.palm_half_thickness
			_expect(failures, lowest >= surface - 0.005,
					"palm stopped flat on the tabletop (y %.3f >= %.3f)" % [lowest, surface - 0.005])
			_expect(failures, shake <= 0.01, "hand steady on the table (%.4f m)" % shake)
			_expect(failures, a.right_separation_max >= 0.05, "hand was held off its target (%.3f m)" % a.right_separation_max)
			_expect(failures, a.y_max <= 0.01, "body stayed on the ground (%.3f m)" % a.y_max)
			# Pressed past the arm's reach, the target is pulled back toward the
			# shoulder; the palm grips by friction and draws the body toward the
			# table until the legs' hold takes the pull. It must then stay.
			# With the wrist holding the palm flat (wrist inertia, 2026-09-25) the
			# palm grips the table over its whole face and the draw settles about
			# 0.4 s later, by about 3.4 s.
			var creep := _column_span(rows, "x", 3.0, 3.5)
			_expect(failures, a.wander_max <= 0.1, "body drawn in at most 0.1 m (%.3f m)" % a.wander_max)
			_expect(failures, creep <= 0.01, "then held still (%.4f m)" % creep)
		"fingers_curl":
			# Springs bring every finger joint to the static pose and hold it
			# still; closing bends them well past open; the palms stay put.
			var rows := Analysis.load_rows(result.csv)
			var settled := 0.0
			var shake := 0.0
			for window: Array in [[1.2, 1.5], [2.2, 2.5], [3.2, 3.5], [4.2, 4.5], [5.2, 5.5], [6.2, 6.5]]:
				for column: String in ["left_finger_error", "right_finger_error"]:
					settled = maxf(settled, _column_max(rows, column, window[0], window[1]))
				shake = maxf(shake, _column_span(rows, "right_finger_bend", window[0], window[1]))
			var open := _column_max(rows, "right_finger_bend", 0.2, 0.5)
			var closed := _column_min(rows, "right_finger_bend", 1.2, 1.5)
			_expect(failures, settled <= 2.0, "every joint settled on its pose (%.2f° <= 2)" % settled)
			_expect(failures, shake <= 0.5, "held still (%.2f° <= 0.5)" % shake)
			_expect(failures, closed >= open + 40.0, "a closed hand bent %.1f° past open (>= 40)" % (closed - open))
			_expect(failures, a.left_separation_max <= 0.02 and a.right_separation_max <= 0.02,
					"palms stayed on target (%.3f, %.3f)" % [a.left_separation_max, a.right_separation_max])
		"fingers_table":
			# The fingers give way against the tabletop, staying out of it and
			# still, and let the palm come down flat.
			var rows := Analysis.load_rows(result.csv)
			var lowest := _column_min(rows, "right_hand_y", 2.5, 3.5)
			var rest: float = 1.0 + result.palm_half_thickness
			var shake := _column_span(rows, "right_finger_bend", 2.5, 3.5)
			# Within Jolt's penetration slop (5 mm, project setting) plus 1 mm.
			_expect(failures, result.finger_sink_held <= 0.006,
					"fingers stayed out of the table while pressed (%.4f m in)" % result.finger_sink_held)
			_expect(failures, result.finger_sink_held >= -0.005, "fingers reached the table (%.4f m)" % result.finger_sink_held)
			_expect(failures, result.finger_sink <= 0.03, "no finger went far in at any moment (%.4f m)" % result.finger_sink)
			_expect(failures, lowest <= rest + 0.005, "palm came down flat (y %.3f <= %.3f)" % [lowest, rest + 0.005])
			_expect(failures, shake <= 0.5, "fingers held still on the table (%.2f°)" % shake)
		"palm_push_box":
			# The palm meets the box and pushes it along the tabletop with the
			# hand, staying out of it; the box slides (and rocks and skews:
			# friction 1 at a push through its middle is at the edge of tipping
			# it) but is not thrown.
			var moved: Array = result.get("prop_moved", [0.0, 0.0, 0.0])
			# 0.15 to 0.2 m, by solve order, with the wrist holding the palm
			# square to the box as it rocks and skews.
			_expect(failures, moved[0] >= 0.12, "the palm pushed the box along (%.3f m of 0.2)" % moved[0])
			_expect(failures, result.get("prop_speed", 9.0) <= 0.5,
					"the box was pushed, not thrown (%.2f m/s)" % result.get("prop_speed", 9.0))
			_expect(failures, result.get("prop_rise", 1.0) <= 0.05,
					"the box stayed on the table (rose %.3f m)" % result.get("prop_rise", 1.0))
			# Jolt's 5 mm penetration slop, plus the push: the hand's drive and
			# the contact are solved together, and a firm push on a light box
			# sinks the palm 7.8 to 12.4 mm, depending on the solve order (which
			# scenarios ran before it).
			_expect(failures, result.get("palm_depth", 1.0) <= 0.015,
					"the palm stayed out of the box (%.4f m in)" % result.get("palm_depth", 1.0))
			_expect(failures, a.prop_push_hands >= 1.0, "the hand pushed on it (%.2f s)" % a.prop_push_hands)
		"grab_lift_box":
			# Gripped, the box comes up into the palm within seat_time and is held there
			# as the hand lifts, keeping its rotation relative to the hand; let
			# go, it drops back onto the table.
			var moved: Array = result.get("prop_moved", [0.0, 0.0, 0.0])
			_expect(failures, a.grabs == 1, "grabbed once (%d)" % a.grabs)
			_expect(failures, a.grab_pull_time >= 0.0 and a.grab_pull_time <= result.get("seat_time", 0.0) + 1e-4,
					"seated in the hand in %.3f s <= %.2f" % [a.grab_pull_time, result.get("seat_time", 0.0)])
			_expect(failures, a.grab_gap_held_max <= 0.01, "held at the grab point (%.4f m off at most)" % a.grab_gap_held_max)
			_expect(failures, result.get("held_rise_min", 0.0) >= 0.18,
					"it came up with the hand (%.3f m)" % result.get("held_rise_min", 0.0))
			_expect(failures, result.get("held_turn", 90.0) <= 3.0,
					"it kept its rotation in the hand (%.1f°)" % result.get("held_turn", 90.0))
			_expect(failures, result.get("hand_pulled", 1.0) <= 0.05,
					"a 2 kg box did not drag the hand (%.3f m)" % result.get("hand_pulled", 1.0))
			_expect(failures, absf(moved[1]) <= 0.02, "let go, it dropped back onto the table (%.3f m)" % moved[1])
		"grab_sword_table", "grab_dagger_table", "grab_longsword_table":
			# As grab_lift_box, for a weapon lying on the table: gripped over
			# the middle of its handle, it is grabbed by the handle (not the
			# guard or blade), comes up into the palm and is held there as the
			# hand lifts; let go, it drops back onto the table where it was.
			var moved: Array = result.get("prop_moved", [0.0, 0.0, 0.0])
			var aside := Vector2(moved[0], moved[2]).length()
			_expect(failures, a.grabs == 1, "grabbed once (%d)" % a.grabs)
			_expect(failures, result.get("grab_on_handle", false), "grabbed by the handle")
			_expect(failures, a.grab_pull_time >= 0.0 and a.grab_pull_time <= result.get("seat_time", 0.0) + 1e-4,
					"seated in the hand in %.3f s <= %.2f" % [a.grab_pull_time, result.get("seat_time", 0.0)])
			_expect(failures, a.grab_gap_held_max <= 0.01, "held at the grab point (%.4f m off at most)" % a.grab_gap_held_max)
			_expect(failures, result.get("held_rise_min", 0.0) >= 0.18,
					"it came up with the hand (%.3f m)" % result.get("held_rise_min", 0.0))
			_expect(failures, result.get("held_turn", 90.0) <= 3.0,
					"it kept its rotation in the hand (%.1f°)" % result.get("held_turn", 90.0))
			_expect(failures, result.get("hand_pulled", 1.0) <= 0.05,
					"it did not drag the hand (%.3f m)" % result.get("hand_pulled", 1.0))
			_expect(failures, absf(moved[1]) <= 0.02 and aside <= 0.05,
					"let go, it dropped back onto the table (%.3f m down, %.3f m aside)" % [moved[1], aside])
			_accept_handle_seat(result, failures)
		"handle_sword_yaw45", "handle_sword_yaw135", "handle_sword_tilt", "handle_sword_near_pommel",\
				"handle_generic_cylinder", "handle_dagger_near_end", "handle_longsword_yaw80":
			_accept_handle(result, failures)
		"climb_grab_hold", "climb_hang_two", "climb_pull_two", "climb_pull_one", "climb_hang_one_reach",\
				"climb_throw", "climb_tracking_loss", "climb_hold_and_prop", "climb_walk_away",\
				"climb_grab_moving", "climb_lower_fast", "climb_mantle_notch", "climb_land_on_feet":
			_accept_climb(result, failures)
		"climb_mantle_table":
			_accept_mantle(result, failures, 2.5, 4.5)
		"throw_box_overhand", "throw_box_late":
			_accept_throw(result, failures)
		"strike_punch_cloth", "strike_punch_stone", "strike_press_post", "strike_rest_sword",\
				"strike_sword_post", "strike_axe_stone", "strike_longsword_two_hand", "strike_box_cloth",\
				"strike_box_drop", "strike_dagger_let_go", "strike_sword_flat_wood", "strike_sword_edge_stone",\
				"strike_axe_bit_wood", "strike_pick_wood", "strike_adze_wood", "strike_dagger_stab_cloth":
			_accept_strike(result, failures)
		"strike_box_vein":
			_accept_strike(result, failures)
			_accept_vein(result, failures)
		"strike_vein_break":
			_accept_strike(result, failures)
			_accept_vein(result, failures)
			_accept_loot(result, failures)
		"vein_loot_drop":
			_accept_loot(result, failures)
		"grab_ore_pressed":
			# On the half-size ore's surface, at least 3 cm from its centre
			# (its nearest face is about 5 cm out), not at the centre.
			var grip: float = result.get("grip_from_centre", 0.0)
			var nearest: float = result.get("hand_from_centre", 0.0)
			_expect(failures, grip >= 0.03, "took hold on the ore's surface (%.3f m from its centre)" % grip)
			_expect(failures, nearest >= 0.03, "the hand stayed outside the ore while it held it (%.3f m)" % nearest)
			_expect(failures, result.get("held_rise_min", 0.0) >= 0.15,
					"lifted it with the hand (%.3f m)" % result.get("held_rise_min", 0.0))
		"grab_ore_join":
			var grip: float = result.get("left_grip_from_centre", 0.0)
			var nearest: float = result.get("left_hand_from_centre", 0.0)
			_expect(failures, grip >= 0.03,
					"the left hand, its grab point at the ore's centre, took hold on its surface (%.3f m from the centre)" % grip)
			_expect(failures, nearest >= 0.03,
					"and holds it from outside it, with the right (%.3f m from the centre at the nearest)" % nearest)
		"held_palm_push", "held_palm_under", "held_strike_palm", "held_slap_fast", "held_clash", "held_clash_fast",\
				"held_clash_deep":
			_accept_held_contact(result, failures)
		"chop_axe_tree", "chop_axe_fell", "chop_box_tree", "chop_axe_high", "chop_axe_toe":
			_accept_strike(result, failures)
			_accept_chop(result, failures)
			_accept_weight(result, failures)
			_accept_breaks(result, failures)
		"chop_tree_falls", "chop_axe_drop_on_log", "chop_high_cut":
			_accept_fall(result, failures)
			_accept_weight(result, failures)
			_accept_breaks(result, failures)
		"chop_branch_line":
			_accept_limb(result, failures)
			_accept_weight(result, failures)
			_accept_breaks(result, failures)
		"chop_buck_log":
			_accept_buck(result, failures)
			_accept_weight(result, failures)
			_accept_breaks(result, failures)
		"chop_root_loot":
			_accept_lone(result, failures)
			_accept_weight(result, failures)
			_accept_breaks(result, failures)
		"chop_log_loot":
			_accept_buck(result, failures)
			_accept_lone(result, failures)
			_accept_weight(result, failures)
			_accept_breaks(result, failures)
		"chop_stick_loot":
			_accept_limb(result, failures)
			_accept_lone(result, failures)
			_accept_weight(result, failures)
			_accept_breaks(result, failures)
		"chop_limb_set_down":
			_accept_set_down(result, failures)
			_accept_weight(result, failures)
			_accept_breaks(result, failures)
		"loot_log_roll", "loot_stick_roll":
			_accept_roll(result, failures)
		"lone_log_walked_into", "lone_stick_walked_into":
			_accept_walked(result, failures)
		"leaves_box_slow", "leaves_box_fast":
			_accept_crown_pass(result, failures)
			_accept_breaks(result, failures)
		"turn_snap_stand", "turn_snap_walk", "turn_snap_reach", "turn_snap_sword", "turn_snap_longsword",\
				"turn_snap_climb", "turn_snap_climb_prop":
			_accept_turn(result, failures)
		"handle_dagger_end":
			# The palm's grab point 3 cm beyond the dagger's grip, past its butt
			# end, palm down; the grip is in the grab area and the blade is not,
			# and nothing else lies on the table. A hand beyond either end of a
			# handle cannot hold it there: nothing is grabbed, and the dagger is
			# never the hand's candidate.
			var h: Dictionary = result.get("handle_grab", {})
			var reach: Dictionary = h.get("reach_at_grip", {})
			var moved: Array = result.get("prop_moved", [1.0, 1.0, 1.0])
			_expect(failures, reach.get("Grip", 1.0) < 0.0 and reach.get("Blade", -1.0) > 0.0,
					"as the grip closed, the grip was in the grab area and the blade not (%.3f m, %.3f m outside it)" % [
					reach.get("Grip", 1.0), reach.get("Blade", -1.0)])
			_expect(failures, absf(h.get("along_at_grip", 0.0)) > h.get("half", 1.0),
					"the palm was beyond the grip's end (%.4f m from its middle; half length %.4f m)" % [
					h.get("along_at_grip", 0.0), h.get("half", 1.0)])
			_expect(failures, a.grabs == 0, "nothing grabbed (%d)" % a.grabs)
			_expect(failures, h.get("candidate_ticks", 1) == 0,
					"the dagger was never the hand's candidate (%d ticks)" % h.get("candidate_ticks", 1))
			_expect(failures, Vector3(moved[0], moved[1], moved[2]).length() <= 0.002,
					"the dagger stayed where it lay (%.4f m)" % Vector3(moved[0], moved[1], moved[2]).length())
		"weapons_rest", "longsword_rest":
			# Left alone, the weapons stay where the level lays them, no corner
			# in the table: bodies of several shapes settled up to the 5 mm
			# penetration slop deep until they reported contacts (2026-09-27).
			# Laid flat, each rocks about a degree onto its blade's tip, which
			# is thinner than the grip or guard, within 0.1 s of loading.
			var rest: Dictionary = result.get("weapon_rest", {})
			var weapons: Array[String] = ["Sword", "Dagger"]
			if result.name == "longsword_rest":
				weapons.append("LongSword")
			for weapon: String in weapons:
				var entry: Dictionary = rest.get(weapon, {})
				_expect(failures, entry.get("moved", 1.0) <= 0.002,
						"%s stayed where it was laid (%.4f m <= 0.002)" % [weapon, entry.get("moved", 1.0)])
				_expect(failures, entry.get("turned", 90.0) <= 1.5,
						"%s only settled onto its blade's tip (%.2f° <= 1.5)" % [weapon, entry.get("turned", 90.0)])
				_expect(failures, entry.get("sink", 1.0) <= 0.001,
						"%s rests on the tabletop (%.4f m into it <= 0.001)" % [weapon, entry.get("sink", 1.0)])
		"skeleton_toggle":
			# The debug drawings (the static skeleton's and the physical
			# layer's) start hidden over the character model; B shows both and
			# hides them again, and does nothing else (it is not A: no jump).
			# The physical layer's drawing shows every one of the player's
			# collision shapes, of its type and size, where it is (2026-09-27;
			# both start hidden since 2026-10-02).
			var toggled: Array = result.get("skeleton_toggled", [false, false, false])
			var view: Dictionary = result.get("view", {})
			_expect(failures, toggled[0], "the drawings were hidden before B, the model shown")
			_expect(failures, toggled[1], "the first B showed both, the model still shown")
			_expect(failures, toggled[2], "the second B hid them again, the model still shown")
			_expect(failures, falls.is_empty(), "B did not jump (%d falls)" % falls.size())
			_expect(failures, view.get("shapes", 0) >= 49,
					"the physical layer has its shapes (%d)" % view.get("shapes", 0))
			_expect(failures, view.get("drawn", 0) == view.get("shapes", -1),
					"each is drawn (%d of %d)" % [view.get("drawn", 0), view.get("shapes", 0)])
			_expect(failures, view.get("worst", 1.0) <= 0.001,
					"where it is and as big (%.4f m off at worst)" % view.get("worst", 1.0))
			# Only reflections show the model's head and neck (2026-10-03): the
			# player's eyes sit inside them.
			var mirror_only: Dictionary = result.get("mirror_only", {})
			var mirrored: Array = mirror_only.get("mirrored", [])
			var drawn: Array = mirror_only.get("drawn", [])
			_expect(failures, mirrored.size() == MIRROR_ONLY_PARTS.size()
					and MIRROR_ONLY_PARTS.all(func(part: String) -> bool: return part in mirrored),
					"the head and neck are drawn apart (%s)" % ", ".join(mirrored))
			_expect(failures, not drawn.any(func(part: String) -> bool: return part in MIRROR_ONLY_PARTS),
					"and not with the rest of the model")
			_expect(failures, drawn.size() + mirrored.size() == MODEL_PARTS,
					"no part lost or doubled (%d + %d of %d)" % [drawn.size(), mirrored.size(), MODEL_PARTS])
			_expect(failures, mirror_only.get("layers", 0) == RenderLayers.mask(RenderLayers.MIRROR_ONLY),
					"on the mirror-only layer alone (layers %d)" % mirror_only.get("layers", 0))
			_expect(failures, mirror_only.get("posed", false), "on the model's skin and skeleton, shown with it")
			_expect(failures, not mirror_only.get("eyes_see", true), "the player's camera does not draw them")
			_expect(failures, mirror_only.get("mirror_eyes_see", 0) == 2,
					"both of the mirror's eyes do (%d of 2)" % mirror_only.get("mirror_eyes_see", 0))
		"two_hand_sword", "two_hand_sword_swap", "two_hand_longsword", "two_hand_bar_aim",\
				"two_hand_share", "two_hand_pull_apart", "two_hand_close", "two_hand_release_apart",\
				"two_hand_close_apart", "two_hand_bar_yawed", "two_hand_reach_longsword", "two_hand_reach_sword",\
				"two_hand_reach_sword_drift", "two_hand_table_join", "two_hand_longsword_beside":
			_accept_two_hands(result, failures)
		"grab_swing_medium", "grab_swing_heavy", "grab_whip_heavy":
			# Held boxes swung fast stay where the hand holds them: locked in
			# the hand, carried by it, and steadied by the wrist, they do not
			# swing out past the hand or drop; and the hand's force limit holds
			# steady instead of swinging between its floor and ceiling.
			var rows := Analysis.load_rows(result.csv)
			var holding := rows.filter(func(row: Dictionary) -> bool: return row.right_grab > 1.5)
			# Swinging back and forth: a tick where the limit jumps by half or
			# more one way and then the other. Since the arm's strength
			# (2026-09-26) the limit includes the commanded motion's own force,
			# which ramps up as a swing starts and down as it stops; a ramp is
			# not a swing.
			var flips := 0
			for k in range(1, holding.size() - 1):
				var before: float = holding[k - 1].right_force
				var now: float = holding[k].right_force
				var after: float = holding[k + 1].right_force
				var rise := now - before
				var fall := now - after
				if signf(rise) == signf(fall) and absf(rise) > 0.5 * minf(before, now) \
						and absf(fall) > 0.5 * minf(after, now):
					flips += 1
			_expect(failures, flips <= holding.size() / 50,
					"the hand's force held steady (%d of %d ticks jumped and back)" % [flips, holding.size()])
			_expect(failures, result.get("still_held", false), "still held after the swings")
			_expect(failures, result.get("swing_gap", 1.0) <= 0.01,
					"the box stayed at the hand's grab point (%.4f m off)" % result.get("swing_gap", 1.0))
			var beyond: float = result.get("swing_past", 1.0) - result.get("swing_hand_past", 0.0)
			_expect(failures, beyond <= 0.015, "the box went no further than the hand past the swing (%.3f m more)" % beyond)
			_expect(failures, rad_to_deg(result.turn_error_max) <= 12.0,
					"the wrist held the box level (%.1f° at most)" % rad_to_deg(result.turn_error_max))
			var lag := 0.25 if result.name == "grab_whip_heavy" else 0.1
			_expect(failures, result.get("swing_separation", 1.0) <= lag,
					"the hand stayed near its target (%.3f m at most, %.2f allowed)" % [result.get("swing_separation", 1.0), lag])
		"grab_picks_closest":
			# Two boxes in the grab area: the one whose surface is nearest the
			# palm's grab point is grabbed, and only it.
			_expect(failures, a.grabs == 1, "grabbed once (%d)" % a.grabs)
			_expect(failures, result.get("rise_MediumBox", 0.0) >= 0.12,
					"the nearer box came up (%.3f m)" % result.get("rise_MediumBox", 0.0))
			_expect(failures, absf(result.get("rise_LightBox", 1.0)) <= 0.01,
					"the other stayed put (%.3f m)" % result.get("rise_LightBox", 1.0))
		"grab_heavy_box":
			# Seated like any object (decided with the player 2026-10-02): a
			# 40 kg box comes up into the hand within seat_time; held, its
			# weight takes the hand down until the box is back on the table
			# (0.4 s after the grip), and nothing is thrown.
			_expect(failures, a.grabs == 1, "grabbed once (%d)" % a.grabs)
			_expect(failures, a.grab_pull_time >= 0.0 and a.grab_pull_time <= result.get("seat_time", 0.0) + 1e-4,
					"seated in the hand in %.3f s <= %.2f" % [a.grab_pull_time, result.get("seat_time", 0.0)])
			_expect(failures, result.get("hand_came", 0.0) >= 0.03 and absf(result.get("crate_came", 1.0)) <= 0.01,
					"held, its weight took the hand down (%.3f m) and the box back to the table (%.3f m up)" % [
					result.get("hand_came", 0.0), result.get("crate_came", 1.0)])
			_expect(failures, result.get("held_speed", 9.0) <= 1.0,
					"held, nothing thrown (%.2f m/s)" % result.get("held_speed", 9.0))
		"grab_box_moving_slow", "grab_box_moving", "grab_sword_moving":
			_accept_seat(result, failures)
		"grab_regrab_box":
			# Gripped again before the hand was clear of it, then let go and the
			# hand lifted away: its own layers come back, not the Held layer.
			var regrab: Dictionary = result.get("regrab", {})
			_expect(failures, a.grabs == 2, "grabbed twice (%d)" % a.grabs)
			_expect(failures, regrab.get("end", []) == regrab.get("start", [-1]),
					"let go and clear of the hand, it has its own layers back (%s; %s before)" % [
					str(regrab.get("end", [])), str(regrab.get("start", []))])
		"handle_sword_yaw45_box":
			# The sword seats into a box set where its blade goes: it meets
			# nothing until lifted clear of the box, so the box stays put.
			var h: Dictionary = result.get("handle_grab", {})
			_expect(failures, a.grabs == 1, "grabbed once (%d)" % a.grabs)
			_expect(failures, result.get("neighbour_moved", 1.0) <= 0.005,
					"the box stayed where it lay (%.4f m <= 0.005)" % result.get("neighbour_moved", 1.0))
			_expect(failures, h.get("solid_at", 0.0) > 2.0 and h.get("solid_at", 9.0) <= 3.0,
					"the sword met nothing until lifted clear of the box (solid at %.3f s; lifted from 2.0 s, 0.2 m by 3.0 s)" % h.get("solid_at", 0.0))
			_accept_handle_seat(result, failures)
		"palms_lift_box":
			# Squeezed between the palms, a 5 kg box lifts with them and stays
			# level: the wrists hold the palms flat against its weight instead of
			# rolling with it. Let go, it drops back, and the free hands are
			# exactly on their targets again.
			_expect(failures, result.get("held_rise_min", 0.0) >= 0.12,
					"the box came up with the hands (%.3f m of 0.15)" % result.get("held_rise_min", 0.0))
			_expect(failures, result.get("box_tilt", 90.0) <= 8.0,
					"it stayed level (%.1f°)" % result.get("box_tilt", 90.0))
			_expect(failures, result.get("wrist_turn", 90.0) <= 8.0,
					"the wrists held the palms flat (%.1f° off at most)" % result.get("wrist_turn", 90.0))
			_expect(failures, rad_to_deg(result.turn_error_final) <= 2.0,
					"let go, the hands were back on their targets (%.1f°)" % rad_to_deg(result.turn_error_final))
		"walk_push_crate":
			# Walking into a loose crate, the body shoves it along rather than
			# passing through it or climbing it; a round capsule meeting a box
			# pushes it aside as it goes by.
			var moved: Array = result.get("prop_moved", [0.0, 0.0, 0.0])
			var shoved := Vector2(moved[0], moved[2]).length()
			_expect(failures, shoved >= 0.5, "the body shoved the crate (%.2f m)" % shoved)
			_expect(failures, a.prop_push_body > 0.0, "the body pushed on it (%.2f s)" % a.prop_push_body)
			_expect(failures, result.get("prop_speed", 9.0) <= 2.5,
					"the crate was shoved, not launched (%.2f m/s)" % result.get("prop_speed", 9.0))
			_expect(failures, a.y_max <= 0.02, "the body did not climb the crate (y %.3f)" % a.y_max)
			_expect(failures, a.airborne_time == 0.0, "never left the ground (%.3f s)" % a.airborne_time)
		"walk_kick_box":
			# A foot walking into a small box passes through it: the legs meet
			# no props (2026-10-03). The capsule's edge may still nudge it.
			var kicked: Dictionary = result.get("kicked", {})
			var legs := BodyParts.LEG_PARTS.map(func(part: int) -> String:
					return "PropsOnlyParts/" + BodyParts.Part.keys()[part].to_pascal_case())
			var by_legs := kicked.keys().filter(func(part: String) -> bool: return part in legs)
			_expect(failures, by_legs.is_empty(), "the legs passed through it (%s)" % JSON.stringify(kicked))
			_expect(failures, result.get("prop_speed", 9.0) <= 3.0,
					"not launched (%.2f m/s)" % result.get("prop_speed", 9.0))
			_expect(failures, a.airborne_time == 0.0, "never left the ground (%.3f s)" % a.airborne_time)
		"lean_over_table":
			# Leaning out over the table, the chest meets its edge: the part of
			# the torso that goes with the head cannot be stopped without moving
			# the view, so its push on the body carries the view back, as any
			# push does, and the chest stays out of the table. The head stays
			# clear of it, so nothing fades.
			var rows := Analysis.load_rows(result.csv)
			var pressing := _column_max(rows, "parts_pressing", 0.5, 3.0)
			_expect(failures, pressing >= 1.0, "the chest met the table (%d parts)" % pressing)
			_expect(failures, result.part_sink <= 0.035,
					"no part went far in at any moment (%.4f m)" % result.part_sink)
			_expect(failures, result.part_sink_held <= 0.01,
					"parts stayed out of the table while held (%.4f m in)" % result.part_sink_held)
			_expect(failures, result.rig_drift >= 0.05, "the table pushed the view back (%.3f m)" % result.rig_drift)
			_expect(failures, a.head_obstruction_max <= 0.02,
					"head stayed out of the table (%.3f m)" % a.head_obstruction_max)
			_expect(failures, fade == 0.0, "view never faded (%.2f)" % fade)
			_expect(failures, a.x_max <= 0.56, "body stayed out of the table (x %.3f <= 0.56)" % a.x_max)
			_expect(failures, a.airborne_time == 0.0, "never left the ground (%.3f s)" % a.airborne_time)
			# A foot swinging under the leaning head once rode up onto the
			# table's top (1.04 m, 2026-10-02).
			_expect(failures, a.foot_max <= 0.32, "feet stayed on the floor (%.2f m up <= 0.32)" % a.foot_max)
		"tree_feet":
			# The feet once stood on the trunk's rounded foot (0.6 to 1 m up)
			# and stayed there, the other foot's floor holding each one, while
			# the stick walked the body away and the legs stretched to 3.8
			# times their length (2026-10-02).
			var rows := Analysis.load_rows(result.csv)
			_expect(failures, a.foot_max <= 0.32, "feet stayed on the ground (%.2f m up <= 0.32)" % a.foot_max)
			_expect(failures, a.x_max >= 2.5, "the stick walked the body away from the tree (x %.2f >= 2.5)" % a.x_max)
			var stretch := maxf(_column_max(rows, "left_leg_extension", 0.0, INF),
					_column_max(rows, "right_leg_extension", 0.0, INF))
			_expect(failures, stretch <= 1.3, "legs never stretched past walking (%.2f <= 1.3)" % stretch)
			var standing := maxf(_column_max(rows, "left_leg_extension", 7.5, INF),
					_column_max(rows, "right_leg_extension", 7.5, INF))
			_expect(failures, standing <= 1.05, "the feet came back under the body (legs %.2f <= 1.05)" % standing)
			_expect(failures, a.airborne_time == 0.0, "never left the ground (%.3f s)" % a.airborne_time)
		"fingers_wrap_edge", "fingers_grip_box":
			# Every joint curls until a bone it moves meets something, so each
			# finger stops where it touches and wraps on around the edge; a
			# finger with nothing in its way closes fully. Held closed, nothing
			# moves or twitches, and no finger is in the table or the box.
			var rows := Analysis.load_rows(result.csv)
			var held: Array = result.get("finger_held", [0.0, 0.0, 0.0, 0.0, 0.0])
			var bends: Array = result.get("finger_bends", [])
			var wrapped: Array[int] = [1, 2]
			if result.name == "fingers_wrap_edge":
				wrapped = [1, 2, 3, 4]
			# Wrapping: the joints past the root curl on around the edge. With
			# the wrist holding the hand firm the fingertips hook the edge fully
			# and the middle joints curl less than when the hand rolled freely.
			for finger in wrapped:
				_expect(failures, held[finger] >= 10.0,
						"finger %d stopped where it met the edge (%.1f° short)" % [finger, held[finger]])
				var past_root: float = bends[finger][1] + bends[finger][2] if bends.size() == 5 else 0.0
				_expect(failures, past_root >= 60.0,
						"finger %d curled on past its root around the edge (%.1f°)" % [finger, past_root])
			if result.name == "fingers_grip_box":
				for finger: int in [3, 4]:
					_expect(failures, held[finger] <= 1.0,
							"finger %d, over nothing, closed fully (%.1f° short)" % [finger, held[finger]])
				# A firm hand closing over a 2 kg box nudges it about 1.2 cm.
				_expect(failures, result.get("box_moved", 1.0) <= 0.02,
						"closing did not shove the box (%.4f m)" % result.get("box_moved", 1.0))
			else:
				var roots: Array = wrapped.map(func(finger: int) -> float: return bends[finger][0])
				_expect(failures, roots.max() - roots.min() >= 5.0,
						"each finger stopped at its own place on the edge (roots %.1f° apart)" % (roots.max() - roots.min()))
			_expect(failures, result.get("finger_depth_held", 1.0) <= 0.004,
					"fingers stayed out while held (%.4f m in)" % result.get("finger_depth_held", 1.0))
			_expect(failures, result.get("finger_depth", 1.0) <= 0.006,
					"no finger went in at any moment (%.4f m)" % result.get("finger_depth", 1.0))
			_expect(failures, result.get("finger_twitch", 1.0) <= 0.5,
					"held still: no joint moved more than %.2f° in a tick" % result.get("finger_twitch", 1.0))
			_expect(failures, a.finger_reversals == 0, "no finger twitched (%d reversals)" % a.finger_reversals)
			_expect(failures, _column_span(rows, "right_hand_y", 2.8, 4.5) <= 0.005 \
					and _column_span(rows, "right_hand_x", 2.8, 4.5) <= 0.005,
					"closing did not shove the hand")
		"fingers_curl":
			_expect(failures, a.grabs == 0, "gripping at nothing grabbed nothing (%d)" % a.grabs)
		"fingers_close_on_table":
			# Closing over the table, the fingers stop where they meet it: held
			# open by it, out of it, without shoving the hand; lifted clear,
			# they finish closing.
			var rows := Analysis.load_rows(result.csv)
			var held := _column_min(rows, "right_finger_error", 2.6, 3.4)
			var curled := _column_min(rows, "right_finger_bend", 2.6, 3.4) - _column_max(rows, "right_finger_bend", 1.6, 1.9)
			var shoved := _column_span(rows, "right_hand_y", 2.0, 3.5)
			var closed_after := _column_max(rows, "right_finger_error", 4.5, 5.0)
			_expect(failures, held >= 20.0, "the table stopped the fingers closing (held %.1f° open)" % held)
			_expect(failures, curled >= 5.0, "they curled down onto it first (%.1f° more bent)" % curled)
			_expect(failures, result.finger_sink_held >= -0.004,
					"they reached the table (%.4f m short)" % -result.finger_sink_held)
			_expect(failures, result.finger_sink_held <= 0.003,
					"fingers stayed out of the table (%.4f m in)" % result.finger_sink_held)
			_expect(failures, shoved <= 0.005, "closing did not shove the hand (%.4f m)" % shoved)
			_expect(failures, closed_after <= 1.0, "lifted clear, they closed fully (%.1f° short)" % closed_after)
		"finger_poke":
			# A pointing hand pushed into the wall is stopped by its fingers,
			# which stay out of the wall while it pushes and hold still. Turning
			# fast as it pulls away, a fingertip may sweep briefly into the wall:
			# the physics engine's contact prediction covers straight movement,
			# not a turn's sweep. That is bounded, not required to be zero.
			var rows := Analysis.load_rows(result.csv)
			var shake := _column_span(rows, "right_finger_bend", 3.0, 4.0)
			var hand_shake := _column_span(rows, "right_hand_z", 3.0, 4.0)
			var pushing := rows.filter(func(row: Dictionary) -> bool:
					return row.time_s >= 2.5 and row.time_s <= 4.0)
			var touching := pushing.filter(func(row: Dictionary) -> bool: return row.right_touching > 0.5)
			_expect(failures, result.finger_sink_held <= 0.005,
					"fingers stayed out of the wall while pushing (%.4f m in)" % result.finger_sink_held)
			_expect(failures, touching.size() == pushing.size(),
					"the hand pressed on the wall throughout (%d of %d ticks)" % [touching.size(), pushing.size()])
			_expect(failures, result.finger_sink <= 0.03, "no finger went far in at any moment (%.4f m)" % result.finger_sink)
			_expect(failures, shake <= 1.0, "finger held still against the wall (%.2f°)" % shake)
			_expect(failures, hand_shake <= 0.01, "hand held still (%.4f m)" % hand_shake)
		"palm_slide":
			# Resting lightly, the palm slides flat along the tabletop with its
			# target, in contact throughout, and the body stays put. Pressed and
			# pulled, it grips: how far that draws the body is reported, not
			# judged, until it has been felt in the headset.
			var rows := Analysis.load_rows(result.csv)
			var sliding := rows.filter(func(row: Dictionary) -> bool:
					return row.time_s >= 1.7 and row.time_s <= 3.8)
			var touching := sliding.filter(func(row: Dictionary) -> bool: return row.right_touching > 0.5)
			var bounce := _column_span(rows, "right_hand_y", 1.7, 3.8)
			var lag := _column_max(rows, "right_separation", 1.7, 3.8)
			var moved := _column_span(rows, "x", 0.0, 4.0)
			var creep := _column_span(rows, "x", 6.5, 7.0)
			result.drawn_by_pull = _column_max(rows, "x", 4.0, 7.0) - rows[0].x
			_expect(failures, touching.size() == sliding.size(),
					"palm stayed on the table (%d of %d ticks)" % [touching.size(), sliding.size()])
			_expect(failures, bounce <= 0.005, "palm slid flat (%.4f m up and down)" % bounce)
			_expect(failures, lag <= 0.02, "palm kept up with its target (%.3f m)" % lag)
			_expect(failures, moved <= 0.01, "a light slide left the body put (%.3f m)" % moved)
			_expect(failures, creep <= 0.002, "body still after the pull (%.4f m)" % creep)
		"push_steps":
			# Pushing a little, then more: the body goes back a little, then
			# more, stopping each time the push stops. No threshold, no coasting.
			var rows := Analysis.load_rows(result.csv)
			var start_z: float = rows[0].z
			var first: float = start_z - _column_min(rows, "z", 1.5, 2.5)
			var second: float = start_z - _column_min(rows, "z", 3.5, 4.5)
			var creep := maxf(_column_span(rows, "z", 2.0, 2.5), _column_span(rows, "z", 4.0, 4.5))
			var after: float = start_z - rows[-1].z
			_expect(failures, first >= 0.02, "a small push moved the body back (%.3f m)" % first)
			_expect(failures, second >= first + 0.04, "a bigger push moved it further (%.3f m after %.3f m)" % [second, first])
			_expect(failures, creep <= 0.005, "it stopped when each push stopped (%.4f m)" % creep)
			_expect(failures, second - after <= 0.02, "and stayed when released (%.3f of %.3f m)" % [after, second])
		"vault":
			# Pressing both hands down on the table lifts the body to a height set
			# by the press, a little then more, settling without bouncing; let go,
			# it lands without bouncing either.
			var rows := Analysis.load_rows(result.csv)
			var first := _column_min(rows, "y", 2.0, 2.5)
			var second := _column_min(rows, "y", 4.0, 4.5)
			var overshoot := maxf(_column_max(rows, "y", 1.0, 2.5) - first,
					_column_max(rows, "y", 3.0, 4.5) - second)
			var shake := maxf(_column_span(rows, "y", 2.0, 2.5), _column_span(rows, "y", 4.0, 4.5))
			_expect(failures, first >= 0.03, "a press lifted the body (%.3f m)" % first)
			_expect(failures, second >= first + 0.05, "a deeper press lifted it further (%.3f after %.3f m)" % [second, first])
			_expect(failures, overshoot <= 0.03, "no more than 0.03 m of overshoot (%.3f m)" % overshoot)
			# 4.2 to 4.4 mm or 8.2 mm, depending on which scenarios ran before
			# it in the same run: the physics engine's solve order, not the body.
			_expect(failures, shake <= 0.01, "held steady (%.4f m)" % shake)
			_expect(failures, falls.size() <= 1 and a.y_max <= second + 0.03, "landed without bouncing (%d airborne stretches)" % falls.size())
			_expect(failures, descents.is_empty(), "a vault is not a step down (%d)" % descents.size())
		"hand_turn":
			# The hand turns 90° about each axis in turn; a wrong motor sign on
			# any axis would send it the other way.
			_expect(failures, result.turn_error_max <= deg_to_rad(25.0),
					"turn lag at most %.1f° <= 25" % rad_to_deg(result.turn_error_max))
			_expect(failures, result.turn_error_final <= deg_to_rad(3.0),
					"settled within %.1f° <= 3" % rad_to_deg(result.turn_error_final))
		"hand_tracking_loss":
			# The right controller loses tracking while the body walks: its hand
			# is held where it was relative to the body, then recovers.
			_expect(failures, a.right_separation_max <= 0.08,
					"hand kept with the body (%.3f m <= 0.08)" % a.right_separation_max)
		"jump", "jump_walk":
			if _expect(failures, falls.size() == 1, "one jump, one landing (%d)" % falls.size()):
				_expect(failures, falls[0].landed, "landed")
			var start_height: float = result.start_height
			_expect(failures, a.y_max - start_height >= 0.36 and a.y_max - start_height <= 0.44,
					"rose %.3f m, 0.36 to 0.44" % (a.y_max - start_height))
			_expect(failures, descents.is_empty(), "a jump is not a step down (%d)" % descents.size())
			if result.name == "jump":
				_expect(failures, a.wander_max <= 0.02, "straight up (drift %.3f m)" % a.wander_max)
			elif _expect(failures, presses.size() == 1, "one stick press (%d)" % presses.size()):
				_expect(failures, presses[0].ratio >= 0.97, "kept walking speed (ratio %.3f)" % presses[0].ratio)
		"ramp":
			if _expect(failures, presses.size() == 2, "two stick presses (%d)" % presses.size()):
				for press: Dictionary in presses:
					_expect(failures, press.ratio >= 0.97, "speed along the slope ratio %.3f >= 0.97" % press.ratio)
				_expect(failures, presses[0].climb <= -2.1, "reached the bottom (climb %.2f m)" % presses[0].climb)
				_expect(failures, presses[1].climb >= 2.1, "came back up (climb %.2f m)" % presses[1].climb)
			_expect(failures, a.airborne_time <= 0.05, "airborne %.3f s <= 0.05" % a.airborne_time)
		"lower_ramp":
			if _expect(failures, presses.size() == 1, "one stick press (%d)" % presses.size()):
				_expect(failures, presses[0].ratio >= 0.97, "speed along the slope ratio %.3f >= 0.97" % presses[0].ratio)
			_expect(failures, a.y_max >= -2.25, "reached the platform (top %.2f m)" % a.y_max)
			_expect(failures, a.airborne_time <= 0.05, "airborne %.3f s <= 0.05" % a.airborne_time)
		"drop":
			if _expect(failures, falls.size() == 1, "one fall, no bounce (%d)" % falls.size()):
				_expect(failures, falls[0].landed, "landed")
				_expect(failures, falls[0].height >= 3.85 and falls[0].height <= 4.02,
						"fell %.2f m, 3.85 to 4.02" % falls[0].height)
		"wall", "wall_through":
			# Walking the real head into the wall: the head reaches it before
			# the torso, so the rung-2 policy holds: the view fades with the
			# head's depth, and a head walked on through is recentred over the
			# body. The torso's top, which follows the head, meets the wall only
			# as the view starts to darken; pushing on the body, it moves the
			# view back a little, as any push does.
			_expect(failures, a.head_obstruction_max >= 0.05, "head went into the wall (%.3f m)" % a.head_obstruction_max)
			_expect(failures, a.z_max <= 3.82, "body stayed out of the wall (z %.3f <= 3.82)" % a.z_max)
			if result.name == "wall":
				_expect(failures, fade >= 0.5, "view darkened in the wall (%.2f)" % fade)
				_expect(failures, result.rig_drift <= 0.03, "view drifted %.3f m <= 0.03" % result.rig_drift)
			else:
				_expect(failures, a.relocations == 1, "recentred once (%d)" % a.relocations)
				_expect(failures, a.blackout_max >= 1.0, "blacked out (%.2f)" % a.blackout_max)
				_expect(failures, fade >= 0.99, "view went fully black (%.2f)" % fade)
				_expect(failures, result.final_head_lead <= 0.1,
						"head back over the body (%.3f m)" % result.final_head_lead)
		"crouch":
			_expect(failures, a.body_height_min >= 0.78 and a.body_height_min <= 0.82,
					"capsule shrank to %.3f m, 0.78 to 0.82" % a.body_height_min)
			_expect(failures, a.body_height_max >= 1.68, "capsule grew back to %.3f m" % a.body_height_max)
			_expect(failures, a.airborne_time == 0.0, "never airborne (%.3f s)" % a.airborne_time)
			_expect(failures, a.wander_max <= 0.01, "drift %.4f m <= 0.01" % a.wander_max)
		"look_down", "look_down_nod":
			_accept_look_down(result.get("look", {}), result.name == "look_down", failures)
		"run_moderate":
			_expect(failures, absf(a.run_factor_max - 0.22) <= 0.02, "run factor %.2f near 0.22" % a.run_factor_max)
			if _expect(failures, presses.size() == 1, "one stick press (%d)" % presses.size()):
				_expect(failures, presses[0].ratio >= 0.97, "speed ratio %.3f >= 0.97" % presses[0].ratio)
		"run_hard":
			_expect(failures, a.run_factor_max >= 0.99, "run factor %.2f reaches 1" % a.run_factor_max)
			_expect(failures, a.run_speed >= 5.8, "run speed %.2f m/s >= 5.8" % a.run_speed)
		"respawn":
			var position: Array = result.final_position
			var home := Vector2(position[0], position[2]).distance_to(Vector2(4.5, 0.0))
			_expect(failures, a.relocations == 1, "respawned once (%d)" % a.relocations)
			_expect(failures, a.blackout_max >= 1.0, "blacked out (%.2f)" % a.blackout_max)
			_expect(failures, fade >= 0.99, "view went fully black (%.2f)" % fade)
			_expect(failures, home <= 0.3 and absf(position[1]) <= 0.05,
					"back at the start (%.2f m away, y %.2f)" % [home, position[1]])
		"respawn_holding":
			var held: Dictionary = result.get("respawn_hold", {})
			_expect(failures, a.relocations == 1, "respawned once (%d)" % a.relocations)
			_expect(failures, held.get("held", false), "still holding the box at the end")
			_expect(failures, held.get("gap_after", INF) <= 0.005,
					"the box came with the hand (grab points %.4f m apart after <= 0.005)" % held.get("gap_after", INF))
			_expect(failures, held.get("speed_after", INF) <= 3.0,
					"nothing flung it (%.2f m/s at most after <= 3)" % held.get("speed_after", INF))
		"arm_idle_forward", "arm_idle_right", "arm_idle_back", "arm_idle_left", "arm_reach_poses", \
				"arm_hand_turn", "arm_table_rest", "arm_room_walk":
			# Empty-handed, the physical arm is the static skeleton's (Option A,
			# 2026-09-26): nothing held, the hand's target is the static hand
			# untouched, the hand sits on it, and the posed elbow and bones lie
			# on the static skeleton's. The tolerances are the acceptance bar
			# proposed by the design synthesis (2026-09-26): hand 1 mm and 1°
			# (the bar's "bones" tolerance, applied to the hand's turn too),
			# elbow 5 mm, bones 1°. Past full reach the elbow is allowed the
			# known proportional-stretch difference (cosmetic, reported as
			# arm_stretch_gap; about 8 mm at the harness's rest pose).
			# At rest (the static arm still for ARM_REST_TICKS) the bar holds
			# as it stands. In motion (every tick) it holds beyond one tick of
			# the static pose's own motion: the drive moves the hand at its
			# target's velocity from where the target is, so it runs a tick
			# ahead of it in steady motion and carries on a tick when it stops
			# (see _track_arms); a hand past the drive's reach margin is also
			# allowed its clamp (reported as arm_clamp).
			var shaped: int = result.get("arm_shaped_ticks", -1)
			_expect(failures, shaped == 0, "the hand's target was the static hand untouched (%d ticks shaped)" % shaped)
			if _expect(failures, result.get("arm_rest_ticks", 0) > 0, "the arm came to rest"):
				_expect(failures, result.get("arm_rest_hand", 1.0) <= 0.001,
						"at rest, hand on the static hand (%.4f m <= 0.001)" % result.get("arm_rest_hand", 1.0))
				_expect(failures, result.get("arm_rest_turn", 90.0) <= 1.0,
						"at rest, hand turned as the static hand (%.2f° <= 1)" % result.get("arm_rest_turn", 90.0))
				_expect(failures, result.get("arm_rest_elbow", 1.0) <= 0.005,
						"at rest, elbow on the static elbow (%.4f m beyond the stretch difference <= 0.005)" % \
						result.get("arm_rest_elbow", 1.0))
				_expect(failures, result.get("arm_rest_bone", 90.0) <= 1.0,
						"at rest, bones along the static bones (%.2f° <= 1)" % result.get("arm_rest_bone", 90.0))
			_expect(failures, result.get("arm_hand_gap", 1.0) <= 0.001,
					"moving, hand on the static hand (%.4f m beyond a tick's motion <= 0.001; %.4f m raw)" % [
					result.get("arm_hand_gap", 1.0), result.get("arm_hand_gap_raw", 1.0)])
			_expect(failures, result.get("arm_hand_turn", 90.0) <= 1.0,
					"moving, hand turned as the static hand (%.2f° beyond a tick's turn <= 1; %.2f° raw)" % [
					result.get("arm_hand_turn", 90.0), result.get("arm_hand_turn_raw", 90.0)])
			_expect(failures, result.get("arm_elbow_gap", 1.0) <= 0.005,
					"moving, elbow on the static elbow (%.4f m beyond a tick's motion and the stretch difference <= 0.005; %.4f m raw)" % [
					result.get("arm_elbow_gap", 1.0), result.get("arm_elbow_raw", 1.0)])
			_expect(failures, result.get("arm_bone_turn", 90.0) <= 1.0,
					"moving, bones along the static bones (%.2f° beyond a tick's turn <= 1; %.2f° raw)" % [
					result.get("arm_bone_turn", 90.0), result.get("arm_bone_raw", 90.0)])
		"grab_hold_out_light", "grab_hold_out_heavy":
			# Held out ahead of the shoulder at its height, the hand dips as
			# far as the arm's strength (ArmStrength) says and settles there
			# without bobbing; let go, it returns to its target without
			# overshooting. Only a test of the arm if the arm alone bore the box.
			var hold: Dictionary = result.get("hold", {})
			var release: Dictionary = result.get("release", {})
			_expect(failures, result.get("still_held", false), "still held when let go")
			_expect(failures, hold.get("touched", 1) == 0,
					"the arm alone bore the box (it touched something %d ticks)" % hold.get("touched", 1))
			var drop: float = hold.get("drop", 1.0)
			if result.name == "grab_hold_out_light":
				# Proposal, from scratch prototype P2 with the dip: 2 kg held
				# out sags barely, about 1 cm; and, with the dip, every load
				# shows a little.
				_expect(failures, drop <= 0.02, "the hand held the 2 kg box up (sagged %.4f m <= 0.02)" % drop)
				_expect(failures, drop >= 0.003, "its weight showed (sagged %.4f m >= 0.003)" % drop)
			else:
				# Decided with the player (2026-09-26): a load strains the arm
				# but never drops it (giving way dropped this 0.46 m and felt
				# like the arm gave up). At 600 N·m/rad, 10 kg held at 0.9 of
				# the arm's reach (58 N·m) dips the shoulder 5.5°, about 6 cm.
				_expect(failures, drop >= 0.03 and drop <= 0.1,
						"the 10 kg box strained the arm without dropping (sagged %.3f m, 0.03 to 0.1)" % drop)
			# Proposal: P2 settled in 0.81 s, sinking without turning back.
			_expect(failures, hold.get("settle", 9.0) <= 1.2, "settled in %.2f s <= 1.2" % hold.get("settle", 9.0))
			_expect(failures, hold.get("reversals", 99) == 0,
					"sank without bobbing on the way (%d reversals)" % hold.get("reversals", 99))
			# The bar: a loaded hold after settling does not bob, and jitters
			# at most 0.1 mm a tick (Analysis.wobble(): a steady creep is not
			# jitter; shaking back and forth every tick is).
			_expect(failures, hold.get("settled_reversals", 99) == 0,
					"no bobbing once settled (%d reversals)" % hold.get("settled_reversals", 99))
			_expect(failures, hold.get("jitter", 1.0) <= 0.0001,
					"held steady (jitter %.5f m a tick <= 0.0001)" % hold.get("jitter", 1.0))
			# Let go: its target stood still, so the hand turns back no more
			# than it (not at all) and overshoots it by at most 1 mm (the
			# bar's return overshoot), and is back on it (within 1 mm) before
			# the scenario ends.
			_expect(failures, release.get("overshoot", 1.0) <= 0.001,
					"let go, the hand overshot its target by %.4f m <= 0.001" % release.get("overshoot", 1.0))
			_expect(failures, release.get("reversals", 99) == 0 and release.get("settled_reversals", 99) == 0,
					"and did not turn back (%d, then %d reversals)" % [release.get("reversals", 99),
					release.get("settled_reversals", 99)])
			_expect(failures, release.get("settle_ticks", 1) < release.get("ticks", 0),
					"and was back on its target (%.2f s, %.4f m off at the end)" % [release.get("settle", 9.0),
					release.get("final_gap", 1.0)])
		"grab_hold_out_heavy_corner":
			# Held by a corner, the pair turns about its shared centre of mass
			# and the hand's centre swings round it; the wrist must not buzz
			# (the spin turning back every tick above 8 rad/s). Before the fix,
			# 204 ticks in a row; after, at most a tick or two as the weld takes.
			var rows := Analysis.load_rows(result.csv)
			var run := 0
			var longest := 0
			var peak := 0.0
			for row in rows:
				if row.right_grab < 1.5:
					run = 0
					continue
				peak = maxf(peak, row.right_spin)
				run = run + 1 if row.right_spin_back > 0.5 and row.right_spin > 8.0 else 0
				longest = maxi(longest, run)
			_expect(failures, result.get("still_held", false), "still held when let go")
			_expect(failures, longest <= 3,
					"the wrist did not buzz (%d ticks in a row turning back above 8 rad/s <= 3; peak %.1f rad/s)" % [longest, peak])
		"grab_flick_light":
			# A quick wrist flick with the 2 kg box: the hand keeps up with the
			# static hand and does not spring past it. Before the revision of
			# 2026-09-26 it fell 21.6° and 23 mm behind and swung 11.8° past
			# (the player: "springy" on quick flicks). Proposal: the turn
			# behind and the swing past about halved, the place within 2 cm.
			var flick: Dictionary = result.get("flick", {})
			_expect(failures, flick.get("still_held", false), "still held after the flicks")
			_expect(failures, flick.get("turn", 90.0) <= 11.0,
					"the hand kept up with the static hand's turn (%.1f° behind at most <= 11)" % flick.get("turn", 90.0))
			_expect(failures, flick.get("gap", 1.0) <= 0.02,
					"and its place (%.4f m at most <= 0.02)" % flick.get("gap", 1.0))
			_expect(failures, flick.get("past", 90.0) <= 6.5,
					"it swung past the static hand by %.1f° <= 6.5 after the flicks" % flick.get("past", 90.0))
			_expect(failures, result.get("held_turn", 90.0) <= 3.0,
					"the box kept its rotation in the hand (%.1f°)" % result.get("held_turn", 90.0))
		"grab_step_heavy":
			# Holding the 10 kg box out, the controller jumps 0.2 m sideways:
			# the hand goes over as the arm's strength lets it and settles
			# where it now sags to (its last place). The bar, along the jump: a
			# 0.2 m target jump overshoots at most 1 mm, and the hand's motion
			# turns back no more than the target's (a single jump: not at
			# all); once settled, as any loaded hold, no bobbing and at most
			# 0.1 mm a tick. Proposal: settled within 1.2 s, as the hold. The
			# command's own overshoot and turns are reported beside the hand's
			# (step.command_*), to tell the arm's strength from the drive.
			var step: Dictionary = result.get("step", {})
			var hold: Dictionary = result.get("hold", {})
			_expect(failures, result.get("still_held", false), "still held at the end")
			_expect(failures, hold.get("touched", 1) == 0 and step.get("touched", 1) == 0,
					"the arm alone bore the box (it touched something %d, then %d ticks)" % [
					hold.get("touched", 1), step.get("touched", 1)])
			_expect(failures, step.get("moved", 0.0) >= 0.1, "the hand went over (%.3f m)" % step.get("moved", 0.0))
			_expect(failures, step.get("overshoot", 1.0) <= 0.001,
					"overshot where it settled by %.4f m <= 0.001" % step.get("overshoot", 1.0))
			_expect(failures, step.get("reversals", 99) == 0,
					"went over without turning back (%d reversals)" % step.get("reversals", 99))
			_expect(failures, step.get("settle", 9.0) <= 1.2, "settled in %.2f s <= 1.2" % step.get("settle", 9.0))
			_expect(failures, step.get("settled_reversals", 99) == 0,
					"no bobbing once settled (%d reversals)" % step.get("settled_reversals", 99))
			_expect(failures, step.get("jitter", 1.0) <= 0.0001,
					"held steady (jitter %.5f m a tick <= 0.0001)" % step.get("jitter", 1.0))
		"push_free_hand":
			# A 50 N push on a free hand for 1 s, then let go. The bar: the
			# hand is back within 1 mm of its target within 2 ticks,
			# overshooting it by at most 1 mm. Scratch prototype P2 found the
			# pre-arm drive's effort damping (550 N·s/m) made a free 1 kg hand
			# ring at 36 Hz (69 reversals); the target stands still, so the
			# hand turns back no more than it (not at all), pushed or returning.
			var push: Dictionary = result.get("push", {})
			var release: Dictionary = result.get("release", {})
			_expect(failures, push.get("offset", 0.0) >= 0.001, "the push moved the hand (%.4f m)" % push.get("offset", 0.0))
			_expect(failures, push.get("reversals", 99) == 0,
					"no ringing while pushed (%d reversals in %d ticks, jitter %.4f m a tick)" % [
					push.get("reversals", 99), push.get("ticks", 0), push.get("jitter", 1.0)])
			_expect(failures, release.get("overshoot", 1.0) <= 0.001,
					"let go, it overshot its target by %.4f m <= 0.001" % release.get("overshoot", 1.0))
			_expect(failures, release.get("settle_ticks", 99) <= 2,
					"back within 1 mm of its target in %d ticks <= 2 (from %.4f m)" % [
					release.get("settle_ticks", 99), release.get("start_gap", 0.0)])
			_expect(failures, release.get("reversals", 99) == 0 and release.get("settled_reversals", 99) == 0,
					"no ringing on the way back (%d, then %d reversals)" % [release.get("reversals", 99),
					release.get("settled_reversals", 99)])
	return failures


## The largest, smallest, and range of a recorded column between two times.
func _column_max(rows: Array[Dictionary], column: String, from: float, to: float) -> float:
	var values := _column(rows, column, from, to)
	return values.max() if not values.is_empty() else 0.0


func _column_min(rows: Array[Dictionary], column: String, from: float, to: float) -> float:
	var values := _column(rows, column, from, to)
	return values.min() if not values.is_empty() else 0.0


func _column_span(rows: Array[Dictionary], column: String, from: float, to: float) -> float:
	var values := _column(rows, column, from, to)
	return values.max() - values.min() if not values.is_empty() else 0.0


func _column(rows: Array[Dictionary], column: String, from: float, to: float) -> Array:
	return rows.filter(func(row: Dictionary) -> bool: return row.time_s >= from and row.time_s <= to) \
			.map(func(row: Dictionary) -> float: return row.get(column, 0.0))


func _check_acceptance() -> bool:
	var total := 0
	for result in _results:
		var failures := _acceptance(result)
		total += failures.size()
		print("  %-14s %s" % [result.name, "ok" if failures.is_empty() else "; ".join(failures)])
	print("ACCEPTANCE %s: %d scenarios, %d criteria failed" % [
			"PASS" if total == 0 else "FAIL", _results.size(), total])
	return total == 0


## Records a failed criterion. Returns whether it held, so dependent checks
## can be skipped.
func _expect(failures: Array[String], held: bool, criterion: String) -> bool:
	if not held:
		failures.append(criterion)
	return held


func _expect_near(failures: Array[String], value: float, expected: float, share: float,
		what: String) -> bool:
	return _expect(failures, absf(value - expected) <= share * expected,
			"%s %.3f within %d %% of %.3f" % [what, value, roundi(share * 100.0), expected])


## Prints a few headline measurements beside the kinematic body's reference,
## for reading, not for passing or failing.
func _print_comparison() -> void:
	var reference := _load_reference(KINEMATIC_REFERENCE)
	if reference.is_empty():
		return
	var expected := Analysis.key_metrics(reference)
	var actual := Analysis.key_metrics(_results)
	print("COMPARISON with the kinematic body (this run / reference):")
	for result in _results:
		var cells: Array[String] = []
		for metric: String in COMPARED:
			var key := "%s.%s" % [result.name, metric]
			if actual.has(key) and expected.has(key):
				cells.append("%s %.3f/%.3f" % [metric.trim_prefix("presses.0."), actual[key], expected[key]])
		if not cells.is_empty():
			print("  %-14s %s" % [result.name, "  ".join(cells)])


func _check_reference() -> bool:
	var reference := _load_reference(_reference_path)
	if reference.is_empty() or _results.is_empty():
		print("REFERENCE FAIL: nothing to compare with %s" % _reference_path)
		return false
	var names := reference.map(func(result: Dictionary) -> String: return result.name)
	var compared := _results.filter(func(result: Dictionary) -> bool: return result.name in names)
	var result_names := compared.map(func(result: Dictionary) -> String: return result.name)
	var expected := Analysis.key_metrics(reference.filter(
			func(result: Dictionary) -> bool: return result.name in result_names))
	var actual := Analysis.key_metrics(compared)
	var failures := Analysis.compare(actual, expected, REFERENCE_RELATIVE, REFERENCE_ABSOLUTE)
	for failure in failures:
		print("  %s" % failure)
	var added := Analysis.unrecorded(actual, expected)
	if not added.is_empty():
		print("  not in the reference, so not compared: %s" % ", ".join(added))
	print("REFERENCE %s: %d measurements against %s, %d outside tolerance" % [
			"PASS" if failures.is_empty() else "FAIL", expected.size(), _reference_path,
			failures.size()])
	return failures.is_empty()


## Saves this run's results, without machine-specific file paths, as the
## reference later runs are compared with.
func _save_reference() -> bool:
	var reference: Array[Dictionary] = []
	for result in _results:
		var entry := result.duplicate()
		entry.erase("csv")
		reference.append(entry)
	var file := FileAccess.open(_reference_path, FileAccess.WRITE)
	if file == null:
		print("REFERENCE FAIL: cannot write %s" % _reference_path)
		return false
	file.store_string(JSON.stringify(reference, "  "))
	file.close()
	print("REFERENCE WRITTEN: %d scenarios to %s" % [reference.size(), _reference_path])
	return true


func _load_reference(path: String) -> Array:
	var reference: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return reference if reference is Array else []


func _check_checklist() -> bool:
	var recordings := {}
	for result in _results:
		recordings[result.name] = result.csv
	var order: Array[String] = []
	for step in PlayerDebug.GUIDED_STEPS:
		var scenario_name: String = SCENARIO_FOR_STEP[step]
		if order.is_empty() or order[-1] != scenario_name:
			order.append(scenario_name)
	for scenario_name in order:
		if not recordings.has(scenario_name):
			print("CHECKLIST skipped: it needs %s" % ", ".join(order))
			return true
	var checklist := BaselineChecklist.new(PlayerDebug.GUIDED_STEPS)
	for scenario_name in order:
		var before := checklist.current
		for row in Analysis.load_rows(recordings[scenario_name]):
			checklist.update(Analysis.sample_from_row(row), row.delta_s)
		print("  %-10s %s -> %s" % [scenario_name, BaselineChecklist.Step.keys()[before],
				"COMPLETE" if checklist.complete else BaselineChecklist.Step.keys()[checklist.current]])
	print("CHECKLIST %s" % ("PASS" if checklist.complete else "FAIL"))
	return checklist.complete


func _rounded(values: Array) -> String:
	return "(%.3f, %.3f, %.3f)" % [values[0], values[1], values[2]]


func _all_scenarios() -> Array[Dictionary]:
	var along_x := Vector3.RIGHT
	return [
		{"name": "stand", "title": "Stand still on the flat", "start": Vector3(-2.0, 0.0, 1.0),
				"facing": Vector3.FORWARD, "limit": 3.0, "drive": func(_t: float) -> bool: return false},
		{"name": "flat_full", "at": "lane", "title": "Full stick 5 s on the flat, release",
				"start": Vector3(-4.3, 0.0, -3.5), "facing": along_x, "limit": 8.0,
				"drive": func(t: float) -> bool:
					_rig.stick = Vector2(0.0, 1.0) if t >= 0.5 and t < 5.5 else Vector2.ZERO
					return false},
		{"name": "flat_half", "at": "lane", "title": "Half stick 6 s on the flat, release",
				"start": Vector3(-4.3, 0.0, -3.5), "facing": along_x, "limit": 8.5,
				"drive": func(t: float) -> bool:
					_rig.stick = Vector2(0.0, 0.5) if t >= 0.5 and t < 6.5 else Vector2.ZERO
					return false},
		{"name": "steps", "at": "steps", "title": "Up the three 0.25 m steps, then back down",
				"start": Vector3(1.9, 0.0, 2.0), "facing": along_x, "limit": 14.0,
				"drive": _drive_steps},
		{"name": "ramp", "at": "pit_top", "title": "Down the pit ramp to its foot, then back up",
				"start": Vector3(4.5, 0.0, -5.5), "facing": Vector3.LEFT, "limit": 22.0,
				"drive": _drive_ramp},
		{"name": "lower_ramp", "at": "pit_foot", "title": "Up the pit ramp from the pit's floor to the top",
				# 0.3 m before the ramp's foot (the old 15° ramp's start was just up
				# it; the pit's 30° ramp would put the body into the ramp there).
				"start": Vector3(-5.5, -4.0, 2.1), "facing": Vector3.FORWARD, "limit": 7.0,
				"drive": func(_t: float) -> bool:
					# Stop on the platform at the top: past it is the level's edge.
					_rig.stick = Vector2(0.0, 1.0) if _state.body_position.z > -5.4 else Vector2.ZERO
					return _state.body_position.z <= -5.4},
		{"name": "drop", "at": "pit_hole", "title": "Walk into the floor hole and land 4 m below",
				"start": Vector3(-4.0, 0.0, 1.2), "facing": Vector3.BACK, "limit": 6.0,
				"drive": _drive_drop},
		{"name": "wall", "at": "wall", "title": "Walk the real head 1 m into the wall, then back",
				"start": Vector3(0.0, 0.0, 3.0), "facing": Vector3.BACK, "limit": 6.5,
				"no_hands": true, "drive": _drive_wall},
		{"name": "wall_through", "at": "wall", "title": "Walk the real head 1.5 m into the wall and stay",
				"start": Vector3(0.0, 0.0, 3.0), "facing": Vector3.BACK, "limit": 6.0,
				"no_hands": true, "drive": func(t: float) -> bool:
					var forward := 1.5 * clampf((t - 0.5) / 3.0, 0.0, 1.0)
					_rig.head_position = Vector3(0.0, SimulatedRig.HEAD_HEIGHT, forward)
					return false},
		{"name": "crouch", "title": "Crouch to 0.8 m head height, hold, stand",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 6.0,
				"drive": _drive_crouch},
		{"name": "run_moderate", "at": "lane", "title": "Grips + moderate arm pumping + full stick",
				"start": Vector3(-4.3, 0.0, -3.5), "facing": along_x, "limit": 4.5,
				"drive": func(t: float) -> bool: return _drive_run(t, 0.15, 1.5, 1.8)},
		{"name": "run_hard", "at": "lane", "title": "Grips + hard arm pumping + full stick",
				"start": Vector3(-4.3, 0.0, -3.5), "facing": along_x, "limit": 3.5,
				"drive": func(t: float) -> bool: return _drive_run(t, 0.25, 2.5, 1.1)},
		# Running while holding (rung 8.1, 2026-10-02): a grab scenario's drive
		# until the object is lifted and held ("held_at"), then grips kept, both
		# hands pumped hard and the stick full back, away from the table
		# (_drive_run_holding): whether a held object stays in the hand at a run.
		{"name": "run_hold_sword", "at": "weapons", "title": "Lift the sword off the table, then run backward from it pumping hard",
				"start": Vector3(0.65, 0.0, 0.54), "facing": Vector3.RIGHT, "limit": 6.0,
				"palms": PALMS_DOWN, "hand_height": 1.35,
				"weapons": [^"Dynamic/Sword", ^"Dynamic/Dagger"], "weapon": ^"Dynamic/Sword",
				"hold_drive": _drive_grab_weapon, "held_at": 3.2, "run_push": 0.8, "drive": _drive_run_holding},
		{"name": "run_hold_heavy_box", "at": "boxes", "title": "Lift the 10 kg box off the table, then run backward from it pumping hard",
				"start": Vector3(0.65, 0.0, -0.1), "facing": Vector3.RIGHT, "limit": 5.5,
				"palms": PALMS_DOWN, "hand_height": 1.35, "box": "HeavyBox",
				"hold_drive": _drive_grab_swing, "held_at": 2.6, "run_push": 0.8, "drive": _drive_run_holding},
		{"name": "run_hold_longsword", "at": "weapons", "title": "Lift the longsword in both hands, then run backward from the table pumping both hands together",
				"start": Vector3(0.65, 0.0, 0.805), "facing": Vector3.RIGHT, "limit": 6.5,
				"palms": PALMS_DOWN, "hand_height": 1.35, "weapons": [^"Dynamic/LongSword"],
				"object": ^"Dynamic/LongSword", "left_z": 0.74, "right_z": 0.87,
				"right_grip": [1.5, 9.0], "left_grip": [3.0, 9.0], "lift": [1.8, 2.5, 0.2],
				"windows": {}, "hold_drive": _drive_two_hands, "held_at": 3.9, "run_push": 0.8,
				"drive": _drive_run_holding},
		{"name": "room_walk", "title": "Walk around the room without the stick",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 8.0,
				"drive": _drive_room_walk},
		{"name": "stick_room_walk", "at": "lane", "title": "Full stick while really walking with, against and across it",
				"start": Vector3(-4.3, 0.0, -3.5), "facing": along_x, "limit": 7.0,
				"drive": _drive_stick_room_walk},
		{"name": "slope_walk", "at": "ramp15_top", "on_ramp": ^"Static/Ramp15", "title": "Walk down and up the 15° ramp without the stick, standing 2 m down it",
				"start": Vector3(2.0, -0.51, -5.5), "facing": Vector3.LEFT, "limit": 7.0,
				"drive": _drive_slope_walk},
		{"name": "table_straight", "at": "boxes", "title": "Walk the real head straight into the pedestal",
				"start": Vector3(-0.3, 0.0, 0.0), "facing": Vector3.RIGHT, "limit": 6.0,
				"no_hands": true,
				"drive": func(t: float) -> bool: return _drive_head_to(t, Vector3(1.5, 0.0, 0.0))},
		{"name": "table_oblique", "at": "boxes", "title": "Walk the real head into the pedestal at an angle",
				"start": Vector3(-0.3, 0.0, -0.3), "facing": Vector3.RIGHT, "limit": 6.0,
				"no_hands": true,
				"drive": func(t: float) -> bool: return _drive_head_to(t, Vector3(1.4, 0.0, 0.6))},
		{"name": "hands_free", "title": "Both hands trace circles in the air",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 4.0,
				"drive": _drive_hands_free},
		{"name": "hand_wall_one", "at": "wall", "title": "Push one hand into the wall",
				"start": Vector3(0.0, 0.0, 3.35), "facing": Vector3.BACK, "limit": 5.5,
				"palms": PALMS_TO_WALL,
				"drive": func(t: float) -> bool: return _drive_hand_reach(t, false)},
		{"name": "hand_wall_two", "at": "wall", "title": "Push both hands hard into the wall",
				"start": Vector3(0.0, 0.0, 3.65), "facing": Vector3.BACK, "limit": 5.5,
				"palms": PALMS_TO_WALL,
				"drive": func(t: float) -> bool: return _drive_hand_reach(t, true)},
		{"name": "push_steps", "at": "wall", "title": "Push the wall with both hands a little, then more",
				"start": Vector3(0.0, 0.0, 3.55), "facing": Vector3.BACK, "limit": 6.0,
				"palms": PALMS_TO_WALL, "drive": _drive_push_steps},
		{"name": "hand_table_press", "at": "boxes", "title": "Press the right hand down on the table",
				"start": Vector3(0.45, 0.0, 0.0), "facing": Vector3.RIGHT, "limit": 4.5,
				"palms": PALMS_DOWN,
				"drive": _drive_table_press},
		{"name": "vault", "at": "boxes", "title": "Press both hands down on the table, a little then more, and let go",
				"start": Vector3(0.53, 0.0, 0.0), "facing": Vector3.RIGHT, "limit": 7.0,
				"palms": PALMS_DOWN, "head_height": 1.45,
				"drive": _drive_vault},
		{"name": "palm_slide", "at": "boxes", "title": "Rest the right palm on the table and slide it across, then press and pull",
				"start": Vector3(0.35, 0.0, 0.0), "facing": Vector3.RIGHT, "limit": 7.0,
				"palms": PALMS_DOWN, "drive": _drive_palm_slide},
		{"name": "fingers_curl", "title": "Close both hands, open them, make fists, then point",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 7.0,
				"drive": _drive_fingers_curl},
		{"name": "fingers_table", "at": "boxes", "title": "Lay an open right hand flat on the table and press",
				"start": Vector3(0.35, 0.0, 0.0), "facing": Vector3.RIGHT, "limit": 5.0,
				"palms": PALMS_DOWN, "drive": _drive_fingers_table},
		{"name": "fingers_close_on_table", "at": "boxes", "title": "Close an open hand held just above the table, then lift it",
				"start": Vector3(0.35, 0.0, 0.0), "facing": Vector3.RIGHT, "limit": 5.0,
				"palms": PALMS_DOWN, "drive": _drive_fingers_close_on_table},
		{"name": "fingers_wrap_edge", "at": "boxes", "title": "Hold the table's front face, fingers up past its edge, tilted, and close",
				"start": Vector3(0.35, 0.0, 0.0), "facing": Vector3.RIGHT, "limit": 4.5,
				"palms": [Vector3.FORWARD, Vector3.UP.rotated(Vector3.FORWARD, deg_to_rad(20.0))],
				"drive": _drive_fingers_wrap_edge},
		# The other boxes are moved along the table, clear of the little finger:
		# the player model's hand (2026-10-02) spreads it over the medium box.
		{"name": "fingers_grip_box", "at": "boxes", "title": "Lay a hand on the light box, fingers over its far edge at a corner, and close",
				"start": Vector3(0.45, 0.0, -0.34), "facing": Vector3.RIGHT, "limit": 4.5,
				"palms": PALMS_DOWN, "drive": _drive_fingers_grip_box,
				"place": {^"Dynamic/MediumBox": Transform3D(Basis.IDENTITY, Vector3(1.0, 1.0631, 0.1)),
						^"Dynamic/HeavyBox": Transform3D(Basis.IDENTITY, Vector3(1.0, 1.0631, 0.3))}},
		{"name": "palm_push_box", "at": "boxes", "title": "Push the light box 0.2 m across the table with the right palm",
				"start": Vector3(0.65, 0.0, -0.4), "facing": Vector3.RIGHT, "limit": 4.0,
				"palms": PALMS_TO_WALL, "drive": _drive_palm_push_box},
		{"name": "walk_push_crate", "title": "Walk at full stick into an 8 kg crate on the floor and push it",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 5.0,
				"no_hands": true, "drive": _drive_walk_push_crate},
		{"name": "walk_kick_box", "title": "Walk at full stick past a small box on the floor, in line with the right foot",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 3.0,
				"no_hands": true, "drive": _drive_walk_kick_box},
		{"name": "palms_lift_box", "at": "boxes", "title": "Squeeze a 5 kg box between both palms and lift it 0.15 m, no grip",
				"start": Vector3(0.65, 0.0, 0.3), "facing": Vector3.RIGHT, "limit": 5.0,
				"drive": _drive_palms_lift_box},
		{"name": "grab_lift_box", "at": "boxes", "title": "Grip above the light box, lift it 0.2 m, hold, let go",
				"start": Vector3(0.65, 0.0, -0.4), "facing": Vector3.RIGHT, "limit": 5.5,
				"palms": PALMS_DOWN, "hand_height": 1.35, "drive": _drive_grab_lift_box},
		{"name": "grab_picks_closest", "at": "boxes", "title": "Grip between two boxes, nearer the medium box, and lift",
				"start": Vector3(0.65, 0.0, -0.31), "facing": Vector3.RIGHT, "limit": 4.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "drive": _drive_grab_picks_closest},
		{"name": "grab_swing_medium", "at": "boxes", "title": "Grab the 5 kg box, lift it and swing it fast side to side",
				"start": Vector3(0.65, 0.0, -0.25), "facing": Vector3.RIGHT, "limit": 5.5,
				"palms": PALMS_DOWN, "hand_height": 1.35, "box": "MediumBox", "drive": _drive_grab_swing},
		{"name": "grab_swing_heavy", "at": "boxes", "title": "Grab the 10 kg box, lift it and swing it fast side to side",
				"start": Vector3(0.65, 0.0, -0.1), "facing": Vector3.RIGHT, "limit": 5.5,
				"palms": PALMS_DOWN, "hand_height": 1.35, "box": "HeavyBox", "drive": _drive_grab_swing},
		{"name": "grab_whip_heavy", "at": "boxes", "title": "Grab the 10 kg box and whip it side to side as fast as a player can",
				"start": Vector3(0.65, 0.0, -0.1), "facing": Vector3.RIGHT, "limit": 5.5,
				"palms": PALMS_DOWN, "hand_height": 1.35, "box": "HeavyBox", "swing_time": 0.12,
				"swing_reach": 0.6, "drive": _drive_grab_swing},
		{"name": "grab_heavy_box", "at": "boxes", "title": "Grip 5 cm above a 40 kg box and try to lift it",
				"start": Vector3(0.65, 0.0, 0.3), "facing": Vector3.RIGHT, "limit": 4.5,
				"palms": PALMS_DOWN, "hand_height": 1.35, "drive": _drive_grab_heavy_box},
		{"name": "lean_over_table", "at": "boxes", "title": "Lean over the table, chest down toward it, hold, stand",
				"start": Vector3(0.62, 0.0, 0.0), "facing": Vector3.RIGHT, "limit": 4.5,
				"no_hands": true, "drive": _drive_lean_over_table},
		{"name": "tree_feet", "title": "Walk into the tree's trunk with the stick, lean in over its foot, then walk away with the stick: the feet stay on the ground and follow",
				"start": Vector3(1.0, 0.0, -11.0), "facing": Vector3.LEFT, "limit": 8.5,
				"no_hands": true, "drive": _drive_tree_feet},
		{"name": "finger_poke", "at": "wall", "title": "Point the right index finger and push it into the wall",
				"start": Vector3(0.0, 0.0, 3.35), "facing": Vector3.BACK, "limit": 5.5,
				"no_hands": false, "drive": _drive_finger_poke},
		{"name": "hand_turn", "title": "Turn the right hand 90° about each axis",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 5.5,
				"drive": _drive_hand_turn},
		{"name": "hand_tracking_loss", "at": "lane", "title": "Lose the right controller while walking",
				"start": Vector3(-4.3, 0.0, -3.5), "facing": Vector3.RIGHT, "limit": 5.0,
				"drive": _drive_tracking_loss},
		{"name": "jump", "title": "Press A standing still, and land",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 4.0,
				"drive": func(t: float) -> bool: return _drive_jump(t, false)},
		{"name": "jump_walk", "at": "lane", "title": "Press A while walking at full stick, and land",
				"start": Vector3(-4.3, 0.0, -3.5), "facing": along_x, "limit": 5.0,
				"drive": func(t: float) -> bool: return _drive_jump(t, true)},
		{"name": "respawn", "at": "lane", "title": "Walk off the level's edge and be respawned",
				"start": Vector3(4.5, 0.0, 0.0), "facing": Vector3.RIGHT, "limit": 8.0,
				"drive": _drive_respawn},
		{"name": "respawn_holding", "at": "lane", "title": "Holding a 2 kg box, walk off the level's edge and be respawned: the box comes too",
				"start": Vector3(4.5, 0.0, 0.0), "facing": Vector3.RIGHT, "limit": 8.0,
				"drive": _drive_respawn_holding},
		{"name": "guided", "title": "Guided session starts and shows its first item",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": GUIDED_TIME,
				"guided": true, "drive": func(_t: float) -> bool: return false},
		# The arm's strength (Option A, 2026-09-26). Last, so the scenarios
		# above keep the physics engine's solve order they were tuned with.
		{"name": "arm_idle_forward", "title": "Empty-handed at rest facing -Z: the arms match the static skeleton's",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 3.0, "drive": _drive_arm_idle},
		{"name": "arm_idle_right", "title": "Empty-handed at rest facing +X: the arms match the static skeleton's",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.RIGHT, "limit": 3.0, "drive": _drive_arm_idle},
		{"name": "arm_idle_back", "title": "Empty-handed at rest facing +Z: the arms match the static skeleton's",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.BACK, "limit": 3.0, "drive": _drive_arm_idle},
		{"name": "arm_idle_left", "title": "Empty-handed at rest facing -X: the arms match the static skeleton's",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.LEFT, "limit": 3.0, "drive": _drive_arm_idle},
		{"name": "arm_reach_poses", "title": "Both arms straight down, ahead, overhead and past full reach: they match the static skeleton's",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 11.0, "drive": _drive_arm_poses},
		{"name": "arm_hand_turn", "title": "Turn the right controller 90° about each axis: the arms match the static skeleton's",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 5.5,
				"drive": func(t: float) -> bool:
					_drive_hand_turn(t)
					_track_arms("")
					return false},
		{"name": "arm_table_rest", "at": "boxes", "title": "Rest the right palm on the table: the arms match the static skeleton's",
				"start": Vector3(0.55, 0.0, 0.0), "facing": Vector3.RIGHT, "limit": 4.5,
				"palms": PALMS_DOWN, "hand_height": 1.35, "drive": _drive_arm_table_rest},
		{"name": "arm_room_walk", "title": "Walk around the room without the stick: the arms match the static skeleton's",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 8.0,
				"drive": func(t: float) -> bool:
					_drive_room_walk(t)
					_track_arms("")
					return false},
		{"name": "grab_hold_out_light", "at": "boxes", "title": "Grab the 2 kg box, step back, hold it out at shoulder height, let go",
				"start": Vector3(0.65, 0.0, -0.4), "facing": Vector3.RIGHT, "limit": 8.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "box": "LightBox", "release_at": 6.5,
				"drive": _drive_grab_hold_out},
		{"name": "grab_hold_out_heavy", "at": "boxes", "title": "Grab the 10 kg box, step back, hold it out at shoulder height, let go",
				"start": Vector3(0.65, 0.0, -0.1), "facing": Vector3.RIGHT, "limit": 8.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "box": "HeavyBox", "release_at": 6.5,
				"drive": _drive_grab_hold_out},
		# Headset, 2026-09-27: holding the 10 kg box the wrist buzzed at 36 Hz,
		# 16-20 rad/s, for up to 2.5 s. Gripped by a corner, its centre 10 cm
		# from the hand's, the harness does the same (2.8 s before the fix).
		{"name": "grab_hold_out_heavy_corner", "at": "boxes", "title": "Grab the 10 kg box by a top corner, step back, hold it out: the wrist does not buzz",
				"start": Vector3(0.65, 0.0, -0.1), "facing": Vector3.RIGHT, "limit": 7.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "box": "HeavyBox", "release_at": 6.5,
				"palm_offset": Vector3(-0.06, 0.0, 0.08), "drive": _drive_grab_hold_out},
		{"name": "grab_step_heavy", "at": "boxes", "title": "Holding the 10 kg box out, jump the controller 0.2 m sideways and hold",
				"start": Vector3(0.65, 0.0, -0.1), "facing": Vector3.RIGHT, "limit": 8.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "box": "HeavyBox", "reach_share": 0.9, "step_at": 6.0,
				"drive": _drive_grab_hold_out},
		{"name": "grab_flick_light", "at": "boxes", "title": "Grab the 2 kg box, lift it and flick the wrist down and back twice",
				"start": Vector3(0.65, 0.0, -0.4), "facing": Vector3.RIGHT, "limit": 5.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "drive": _drive_grab_flick},
		{"name": "hand_flick", "at": "boxes", "title": "The same wrist flick with an empty hand, for reference",
				"start": Vector3(0.65, 0.0, -0.4), "facing": Vector3.RIGHT, "limit": 5.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "grip": false, "drive": _drive_grab_flick},
		# The grab's seat (2026-10-02): gripped while the hand sweeps past it
		# fast, an object comes into the hand by the same fixed transition, in
		# the hand's own space, as gripped with the hand still (_track_seat).
		{"name": "grab_box_moving_slow", "at": "boxes", "title": "Sweep the right palm sideways over the light box at 1 m/s, gripping as it passes; lift, hold, let go",
				"start": Vector3(0.65, 0.0, -0.4), "facing": Vector3.RIGHT, "limit": 4.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "speed": 1.0, "drive": _drive_grab_moving},
		{"name": "grab_box_moving", "at": "boxes", "title": "As grab_box_moving_slow, at 2.5 m/s",
				"start": Vector3(0.65, 0.0, -0.4), "facing": Vector3.RIGHT, "limit": 4.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "speed": 2.5, "drive": _drive_grab_moving},
		{"name": "grab_sword_moving", "at": "weapons", "title": "Sweep the right palm along the sword's handle at 2.5 m/s, the wrist rolling at up to 4 rad/s, gripping over its middle; lift, hold, let go",
				"start": Vector3(0.65, 0.0, 0.54), "facing": Vector3.RIGHT, "limit": 4.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "weapons": [^"Dynamic/Sword"], "weapon": ^"Dynamic/Sword",
				"speed": 2.5, "roll": 4.0, "left_aside": true, "drive": _drive_grab_moving},
		{"name": "grab_regrab_box", "at": "boxes", "title": "Grip the light box, let go and grip it again two ticks later, before the hand is clear of it; let go and lift the hand away: it gets its own layers back",
				"start": Vector3(0.65, 0.0, -0.4), "facing": Vector3.RIGHT, "limit": 5.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "drive": _drive_grab_regrab},
		{"name": "push_free_hand", "title": "Push the free right hand aside with 50 N for 1 s, then let go",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 4.0,
				"drive": _drive_push_free_hand},
		# The weapons on the table (2026-09-27); only these keep them (WEAPONS).
		{"name": "weapons_rest", "at": "weapons", "title": "Leave the sword and dagger lying on the table: they stay where the level lays them, on its top",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 3.0,
				"weapons": [^"Dynamic/Sword", ^"Dynamic/Dagger"], "drive": _drive_weapons_rest},
		{"name": "grab_sword_table", "at": "weapons", "title": "Grip the sword by its handle where it lies on the table, lift it 0.2 m, hold, let go",
				"start": Vector3(0.65, 0.0, 0.54), "facing": Vector3.RIGHT, "limit": 5.5,
				"palms": PALMS_DOWN, "hand_height": 1.35,
				"weapons": [^"Dynamic/Sword", ^"Dynamic/Dagger"], "weapon": ^"Dynamic/Sword",
				"drive": _drive_grab_weapon},
		{"name": "grab_dagger_table", "at": "weapons", "title": "Grip the dagger by its handle where it lies on the table, lift it 0.2 m, hold, let go",
				"start": Vector3(0.65, 0.0, 0.34), "facing": Vector3.RIGHT, "limit": 5.5,
				"palms": PALMS_DOWN, "hand_height": 1.35,
				"weapons": [^"Dynamic/Sword", ^"Dynamic/Dagger"], "weapon": ^"Dynamic/Dagger",
				"drive": _drive_grab_weapon},
		{"name": "skeleton_toggle", "title": "Press B twice: the debug drawings show over the model, then hide; the physical layer is drawn",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 3.0,
				"drive": _drive_skeleton_toggle},
		# The longsword (2026-09-27), the two-handed test weapon.
		{"name": "longsword_rest", "at": "weapons", "title": "Leave the longsword, sword and dagger on the table: they stay where the level lays them, on its top",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 3.0,
				"weapons": [^"Dynamic/LongSword", ^"Dynamic/Sword", ^"Dynamic/Dagger"], "drive": _drive_weapons_rest},
		{"name": "grab_longsword_table", "at": "weapons", "title": "Grip the longsword by its handle where it lies on the table, lift it 0.2 m, hold, let go",
				"start": Vector3(0.65, 0.0, 0.816), "facing": Vector3.RIGHT, "limit": 5.5,
				"palms": PALMS_DOWN, "hand_height": 1.35,
				"weapons": [^"Dynamic/LongSword"], "weapon": ^"Dynamic/LongSword", "drive": _drive_grab_weapon},
		# Two hands on one object (2026-09-27): both hands hold a point on it,
		# it aims along the line between them, and the lead (the first to
		# grab) sets its roll. Scripted by _drive_two_hands: grip times per
		# hand, a lift, raising the left hand, rolling the right, pulling the
		# hands apart; measured in the named windows.
		{"name": "two_hand_sword", "at": "weapons", "title": "Lift the sword by the pommel end, add the left hand by the guard, hold, let go left then right",
				"start": Vector3(0.65, 0.0, 0.54), "facing": Vector3.RIGHT, "limit": 7.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "weapons": [^"Dynamic/Sword"],
				"object": ^"Dynamic/Sword", "left_z": 0.498, "right_z": 0.582,
				"right_grip": [1.5, 5.5], "left_grip": [3.0, 4.5], "lift": [1.8, 2.5, 0.2],
				"windows": {"both": [3.5, 4.4], "after": [4.6, 5.4], "dropped": [6.5, 7.0]},
				"drive": _drive_two_hands},
		{"name": "two_hand_sword_swap", "at": "weapons", "title": "As two_hand_sword, but the lead lets go first: the left hand takes over",
				"start": Vector3(0.65, 0.0, 0.54), "facing": Vector3.RIGHT, "limit": 7.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "weapons": [^"Dynamic/Sword"],
				"object": ^"Dynamic/Sword", "left_z": 0.498, "right_z": 0.582,
				"right_grip": [1.5, 4.5], "left_grip": [3.0, 5.5], "lift": [1.8, 2.5, 0.2],
				"windows": {"both": [3.5, 4.4], "after": [4.6, 5.4], "dropped": [6.5, 7.0]},
				"drive": _drive_two_hands},
		{"name": "two_hand_longsword", "at": "weapons", "title": "Two-handed longsword: lift, raise the left hand 5 cm, roll the right hand 30°",
				"start": Vector3(0.65, 0.0, 0.805), "facing": Vector3.RIGHT, "limit": 9.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "weapons": [^"Dynamic/LongSword"],
				"object": ^"Dynamic/LongSword", "left_z": 0.74, "right_z": 0.87,
				"right_grip": [1.5, 7.2], "left_grip": [3.0, 7.2], "lift": [1.8, 2.5, 0.2],
				"raise_left": [4.0, 5.0, 5.5, 6.0, 0.05], "roll_right": [6.0, 6.5, 30.0],
				"windows": {"both": [3.5, 3.95], "raised": [5.1, 5.45], "rolled": [6.6, 7.1],
						"dropped": [8.5, 9.0]},
				"drive": _drive_two_hands},
		{"name": "two_hand_bar_aim", "at": "weapons", "title": "A 0.8 m bar held 0.6 m apart: raise the left hand 0.2 m, then roll the right 30°",
				"start": Vector3(0.65, 0.0, 0.55), "facing": Vector3.RIGHT, "limit": 8.5,
				"palms": PALMS_DOWN, "hand_height": 1.35,
				"bar": [Vector3(0.04, 0.04, 0.8), 2.0], "left_z": 0.25, "right_z": 0.85,
				"right_grip": [1.5, 7.0], "left_grip": [1.7, 7.0], "lift": [2.0, 3.0, 0.25],
				"raise_left": [3.5, 4.5, 5.5, 6.0, 0.2], "roll_right": [6.0, 6.5, 30.0],
				"windows": {"both": [3.1, 3.45], "raised": [4.9, 5.4], "rolled": [6.6, 6.95],
						"dropped": [8.0, 8.5]},
				"drive": _drive_two_hands},
		{"name": "two_hand_share", "at": "weapons", "title": "A 10 kg bar held with two hands 0.4 m apart, then with the right alone",
				"start": Vector3(0.65, 0.0, 0.55), "facing": Vector3.RIGHT, "limit": 7.5,
				"palms": PALMS_DOWN, "hand_height": 1.35,
				"bar": [Vector3(0.05, 0.05, 0.8), 10.0], "left_z": 0.35, "right_z": 0.75,
				"right_grip": [1.5, 6.5], "left_grip": [1.7, 5.0], "lift": [2.0, 3.0, 0.3],
				"windows": {"both": [4.0, 5.0], "takeover": [5.0, 5.5], "one": [6.0, 6.5]},
				"drive": _drive_two_hands},
		{"name": "two_hand_pull_apart", "at": "weapons", "title": "Both hands grip a bar on the same tick, pull 0.2 m apart each, then 0.5 m: it stays held at their middle; let go",
				"start": Vector3(0.65, 0.0, 0.55), "facing": Vector3.RIGHT, "limit": 7.5,
				"palms": PALMS_DOWN, "hand_height": 1.35,
				"bar": [Vector3(0.04, 0.04, 0.8), 2.0], "left_z": 0.3, "right_z": 0.8,
				"right_grip": [1.5, 6.0], "left_grip": [1.5, 6.0], "lift": [2.0, 3.0, 0.25],
				"apart": [3.5, 4.0, 0.2, 5.0, 5.3, 0.5],
				"windows": {"both": [3.1, 3.45], "tension": [4.3, 5.0], "far": [5.6, 5.95], "dropped": [7.2, 7.5]},
				"drive": _drive_two_hands},
		{"name": "two_hand_close", "at": "weapons", "title": "Both palms 3 cm apart on a bar: no aiming, the lead keeps it welded",
				"start": Vector3(0.65, 0.0, 0.55), "facing": Vector3.RIGHT, "limit": 6.5,
				"palms": PALMS_DOWN, "hand_height": 1.35,
				"bar": [Vector3(0.04, 0.04, 0.8), 2.0], "left_z": 0.535, "right_z": 0.565,
				"right_grip": [1.5, 5.0], "left_grip": [1.7, 4.0], "lift": [2.0, 3.0, 0.2],
				"windows": {"both": [3.2, 3.9], "after": [4.1, 4.9], "dropped": [6.0, 6.5]},
				"drive": _drive_two_hands},
		# From the review of two-handed holds (2026-09-27): letting go while the
		# player's hands are out of step with the grip, each order of the two
		# hands' ticks; palms too close to aim, pulled apart; and wrists not
		# square to the grip line, trembling like tracked ones.
		{"name": "two_hand_release_apart", "at": "weapons", "title": "A bar held 0.5 m apart, the left leading: pull the hands 0.1 m further apart each, let go with the right: the left takes it without a fling",
				"start": Vector3(0.65, 0.0, 0.55), "facing": Vector3.RIGHT, "limit": 7.0,
				"palms": PALMS_DOWN, "hand_height": 1.35,
				"bar": [Vector3(0.04, 0.04, 0.8), 2.0], "left_z": 0.3, "right_z": 0.8,
				"left_grip": [1.5, 5.5], "right_grip": [1.7, 4.5], "lift": [2.0, 3.0, 0.25],
				"apart": [3.5, 4.0, 0.1, 9.0, 9.5, 0.1],
				"windows": {"both": [3.1, 3.45], "apart": [4.1, 4.45], "takeover": [4.5, 5.0],
						"alone": [5.05, 5.45], "dropped": [6.5, 7.0]},
				"drive": _drive_two_hands},
		{"name": "two_hand_close_apart", "at": "weapons", "title": "Palms 3 cm apart on a bar, the left leading: pull the hands 0.1 m apart each, let go with the left: no strain, no fling",
				"start": Vector3(0.65, 0.0, 0.55), "facing": Vector3.RIGHT, "limit": 7.0,
				"palms": PALMS_DOWN, "hand_height": 1.35,
				"bar": [Vector3(0.04, 0.04, 0.8), 2.0], "left_z": 0.535, "right_z": 0.565,
				"left_grip": [1.5, 4.5], "right_grip": [1.7, 5.5], "lift": [2.0, 3.0, 0.2],
				"apart": [3.5, 4.0, 0.1, 9.0, 9.5, 0.1],
				"windows": {"both": [3.1, 3.45], "apart": [4.1, 4.45], "takeover": [4.5, 5.0],
						"alone": [5.05, 5.45], "dropped": [6.5, 7.0]},
				"drive": _drive_two_hands},
		{"name": "two_hand_bar_yawed", "at": "weapons", "title": "A bar held 0.6 m apart, the wrists turned 6° and -4° about the palms and trembling 0.2°: raise the left hand 0.2 m: it does not roll",
				"start": Vector3(0.65, 0.0, 0.55), "facing": Vector3.RIGHT, "limit": 7.0,
				"palms": PALMS_DOWN, "hand_height": 1.35,
				"bar": [Vector3(0.04, 0.04, 0.8), 2.0], "left_z": 0.25, "right_z": 0.85,
				"right_grip": [1.5, 6.0], "left_grip": [1.7, 6.0], "lift": [2.0, 3.0, 0.25],
				"yaw": [6.0, -4.0], "tremble": 0.2, "roll_from": 3.45,
				"raise_left": [3.5, 4.5, 9.0, 9.5, 0.2],
				"windows": {"both": [3.1, 3.45], "raised": [4.9, 5.4], "dropped": [6.5, 7.0]},
				"drive": _drive_two_hands},
		# Headset, 2026-09-27: a second hand gripping a held weapon with the
		# player's hand a few centimetres off the handle (controllers keep real
		# hands apart) twitched, its grab line orange for up to 4.5 s. Here the
		# left controller stays 8 cm beyond the handle and 2 cm lower than the
		# other scenarios' palms, and grips; or grips 5 cm beyond it and drifts
		# 10 cm further. With the second hand pulling the object in (before it
		# joined the hold as it grips), 8 cm took 12 ticks on the longsword and
		# never locked on the sword, and the drift stuck at 600 N.
		{"name": "two_hand_reach_longsword", "at": "weapons", "title": "Lift the longsword by the pommel end, grip with the left hand 8 cm beyond the handle and keep it there: it comes into both hands smoothly",
				"start": Vector3(0.65, 0.0, 0.805), "facing": Vector3.RIGHT, "limit": 7.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "weapons": [^"Dynamic/LongSword"],
				"object": ^"Dynamic/LongSword", "left_z": 0.74, "right_z": 0.87,
				"left_offset": Vector3(0.0, -0.02, -0.08),
				"right_grip": [1.5, 5.5], "left_grip": [3.0, 5.0], "lift": [1.8, 2.5, 0.2],
				"windows": {"pull": [3.0, 3.6], "both": [4.0, 4.9], "dropped": [6.5, 7.0]},
				"drive": _drive_two_hands},
		{"name": "two_hand_reach_sword", "at": "weapons", "title": "As two_hand_reach_longsword, with the sword: its handle is 8 cm long",
				"start": Vector3(0.65, 0.0, 0.54), "facing": Vector3.RIGHT, "limit": 7.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "weapons": [^"Dynamic/Sword"],
				"object": ^"Dynamic/Sword", "left_z": 0.498, "right_z": 0.582,
				"left_offset": Vector3(0.0, -0.02, -0.08),
				"right_grip": [1.5, 5.5], "left_grip": [3.0, 5.0], "lift": [1.8, 2.5, 0.2],
				"windows": {"pull": [3.0, 3.6], "both": [4.0, 4.9], "dropped": [6.5, 7.0]},
				"drive": _drive_two_hands},
		{"name": "two_hand_reach_sword_drift", "at": "weapons", "title": "As two_hand_reach_sword, gripping 5 cm beyond the handle, the left controller then drifting 10 cm further away",
				"start": Vector3(0.65, 0.0, 0.54), "facing": Vector3.RIGHT, "limit": 7.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "weapons": [^"Dynamic/Sword"],
				"object": ^"Dynamic/Sword", "left_z": 0.498, "right_z": 0.582,
				"left_offset": Vector3(0.0, -0.02, -0.05), "left_move": [3.05, 3.6, Vector3(0.0, 0.0, -0.10)],
				"right_grip": [1.5, 5.5], "left_grip": [3.0, 5.0], "lift": [1.8, 2.5, 0.2],
				"windows": {"pull": [3.0, 3.6], "both": [4.0, 4.9], "dropped": [6.5, 7.0]},
				"drive": _drive_two_hands},
		# Review, 2026-09-27: the longsword held by its pommel end with its tip
		# on the table, the second hand joining 5 cm off the handle while it
		# rests; then lifted. While it rests, the two hands traded its load
		# every tick (in the old code too, in some runs). Open: the fix is the
		# player's choice (see the architecture doc).
		{"name": "two_hand_table_join", "at": "weapons", "title": "The longsword's tip resting on the table, the left hand joins 5 cm off the handle; it rests, then both lift it",
				"start": Vector3(0.65, 0.0, 0.805), "facing": Vector3.RIGHT, "limit": 7.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "weapons": [^"Dynamic/LongSword"],
				"object": ^"Dynamic/LongSword", "left_z": 0.74, "right_z": 0.87,
				"left_offset": Vector3(0.0, -0.02, -0.05),
				"right_grip": [1.5, 6.0], "left_grip": [2.0, 5.5], "lift": [3.5, 4.2, 0.2],
				"windows": {"pull": [2.0, 2.6], "rest": [2.8, 3.4], "both": [4.6, 5.3], "dropped": [6.5, 7.0]},
				"drive": _drive_two_hands},
		# Handles (2026-09-27, at the player's request): a hand holds a handle only
		# straight along the fist's grip, toward the thumb or the little finger,
		# its palm on one of the handle's sides, whichever is nearest how the
		# hand meets it; anywhere along it with the palm wholly on it; never from
		# beyond an end. As grab_sword_table (_drive_grab_weapon), with the right
		# controller turned ("turn": [degrees about the palm's normal, degrees
		# about the fingers], eased in over the first 0.5 s), the palm placed
		# along the handle ("from_end": metres from the grip's pommel end, less
		# than 0 beyond it), or a code-built prop ("cylinder"). Only the object
		# under test lies on the table: a sword turning into the hand sweeps its
		# blade across the table, where the dagger lies. The free left hand waits
		# at the body's side ("left_aside"): at its rest it hangs where a sword
		# held tilted has its blade, and caught it when let go.
		{"name": "handle_sword_yaw45", "at": "weapons", "title": "As grab_sword_table, the right controller turned 45° about the palm's normal: the sword turns into the fist, blade toward the thumb",
				"start": Vector3(0.65, 0.0, 0.54), "facing": Vector3.RIGHT, "limit": 5.5,
				"palms": PALMS_DOWN, "hand_height": 1.35, "weapons": [^"Dynamic/Sword"],
				"weapon": ^"Dynamic/Sword", "turn": [45.0, 0.0], "toward": 1, "left_aside": true,
				"drive": _drive_grab_weapon},
		{"name": "handle_sword_yaw45_box", "at": "weapons", "title": "As handle_sword_yaw45, a 0.3 kg box set on the table where the seat puts the blade as the grip closes: the sword seats through it, meets nothing until lifted clear, and the box stays where it lies",
				"start": Vector3(0.65, 0.0, 0.54), "facing": Vector3.RIGHT, "limit": 5.5,
				"palms": PALMS_DOWN, "hand_height": 1.35, "weapons": [^"Dynamic/Sword"],
				"weapon": ^"Dynamic/Sword", "turn": [45.0, 0.0], "toward": 1, "left_aside": true,
				"in_the_way": true, "drive": _drive_grab_weapon},
		{"name": "handle_sword_yaw135", "at": "weapons", "title": "As handle_sword_yaw45, turned 135°: the nearest seat has the blade toward the little finger",
				"start": Vector3(0.65, 0.0, 0.54), "facing": Vector3.RIGHT, "limit": 5.5,
				"palms": PALMS_DOWN, "hand_height": 1.35, "weapons": [^"Dynamic/Sword"],
				"weapon": ^"Dynamic/Sword", "turn": [135.0, 0.0], "toward": -1, "left_aside": true,
				"drive": _drive_grab_weapon},
		{"name": "handle_sword_tilt", "at": "weapons", "title": "As grab_sword_table, the right controller rolled 30° about the fingers, thumb up: seated, the sword's pommel is in the table, and it meets nothing until lifted clear",
				"start": Vector3(0.65, 0.0, 0.54), "facing": Vector3.RIGHT, "limit": 5.5,
				"palms": PALMS_DOWN, "hand_height": 1.35, "weapons": [^"Dynamic/Sword"],
				"weapon": ^"Dynamic/Sword", "turn": [0.0, 30.0], "toward": 1, "left_aside": true,
				"drive": _drive_grab_weapon},
		{"name": "handle_sword_near_pommel", "at": "weapons", "title": "As grab_sword_table, the palm over the grip 1 cm from its pommel end: the fist is seated as far along as leaves the palm wholly on the grip",
				"start": Vector3(0.65, 0.0, 0.54), "facing": Vector3.RIGHT, "limit": 5.5,
				"palms": PALMS_DOWN, "hand_height": 1.35, "weapons": [^"Dynamic/Sword"],
				"weapon": ^"Dynamic/Sword", "from_end": 0.01, "toward": 1, "left_aside": true,
				"drive": _drive_grab_weapon},
		{"name": "handle_dagger_end", "at": "weapons", "title": "The palm 3 cm beyond the dagger's grip, past its butt end, and the grip closes: nothing is grabbed",
				"start": Vector3(0.65, 0.0, 0.34), "facing": Vector3.RIGHT, "limit": 5.5,
				"palms": PALMS_DOWN, "hand_height": 1.35, "weapons": [^"Dynamic/Dagger"],
				"weapon": ^"Dynamic/Dagger", "from_end": -0.03, "left_aside": true, "drive": _drive_grab_weapon},
		{"name": "handle_generic_cylinder", "at": "weapons", "title": "A 1 kg cylinder built in code, its Grabbable's handle its whole length, gripped with the hand turned 30° across it: it turns into the fist",
				"start": Vector3(0.65, 0.0, 0.55), "facing": Vector3.RIGHT, "limit": 5.5,
				"palms": PALMS_DOWN, "hand_height": 1.35,
				"cylinder": [0.018, 0.3, 1.0], "turn": [30.0, 0.0], "toward": 1, "left_aside": true,
				"drive": _drive_grab_weapon},
		# The same at the dagger's butt, where nothing stands over the grip's end
		# (the sword's grip box once ran 1.75 cm into its pommel, which then met
		# a palm 1 cm from that end first; the grip boxes now end where the
		# pommels begin).
		{"name": "handle_dagger_near_end", "at": "weapons", "title": "The palm over the dagger's grip 1 cm from its butt end: the fist is seated as far along as leaves the palm wholly on the grip",
				"start": Vector3(0.65, 0.0, 0.34), "facing": Vector3.RIGHT, "limit": 5.5,
				"palms": PALMS_DOWN, "hand_height": 1.35, "weapons": [^"Dynamic/Dagger"],
				"weapon": ^"Dynamic/Dagger", "from_end": 0.01, "toward": 1, "left_aside": true,
				"drive": _drive_grab_weapon},
		# Review, 2026-09-27: the longsword, turned in with more speed than the
		# grip's torque could stop, swung up to 31° past its seat and welded
		# while still turning. It takes 0.47-0.56 s to turn in 80°. Turned so, its
		# blade reaches 0.7 m past the table's edge, and let go it lands anywhere
		# from 3 mm to 12 cm aside (handle_sword_tilt watches a let-go fling).
		{"name": "handle_longsword_yaw80", "at": "weapons", "title": "As grab_longsword_table, the right controller turned 80° about the palm's normal: the longsword turns into the fist without swinging past it",
				"start": Vector3(0.65, 0.0, 0.816), "facing": Vector3.RIGHT, "limit": 5.5,
				"palms": PALMS_DOWN, "hand_height": 1.35, "weapons": [^"Dynamic/LongSword"],
				"weapon": ^"Dynamic/LongSword", "turn": [80.0, 0.0], "toward": 1, "left_aside": true,
				"drop_aside": 0.2, "drive": _drive_grab_weapon},
		# Review, 2026-09-27: each hand was seated along a handle as if alone, and
		# hands do not meet each other, so a second fist could be seated in the
		# first. The right controller grips the longsword 5 cm from its grip's
		# middle toward the pommel, the left 7 cm from it toward the guard (real
		# controllers keep hands about that far apart): the left fist is seated a
		# palm's width (8 cm) from the right one. Measured once settled.
		{"name": "two_hand_longsword_beside", "at": "weapons", "title": "Grip the longsword, then with the left hand 7 cm along: the left fist is seated a palm's width from the right one, not in it",
				"start": Vector3(0.65, 0.0, 0.815), "facing": Vector3.RIGHT, "limit": 9.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "weapons": [^"Dynamic/LongSword"],
				"object": ^"Dynamic/LongSword", "left_z": 0.78, "right_z": 0.85,
				"right_grip": [1.5, 7.2], "left_grip": [3.0, 7.2], "lift": [1.8, 2.5, 0.2],
				"windows": {"both": [5.0, 6.5], "dropped": [8.5, 9.0]},
				"drive": _drive_two_hands},
		# Climbing (2026-09-28): a hand gripping a Climbable hold is pulled onto
		# it and welded there, and its drive then moves the body the opposite
		# way to how the player's hand moves (one arm holds and hauls slowly,
		# two haul faster). The player stands 0.35 m from the wall facing it,
		# Hold1 ahead at 2.0 m, its top out of the simulated arm's reach, so the
		# hands take its front, palms to the wall (_drive_climb).
		{"name": "climb_grab_hold", "at": "hold1", "title": "Grip Hold1 with the right hand: the hand is pulled onto it and held there, the body stays put; let go",
				"start": CLIMB_START, "facing": Vector3.BACK, "limit": 4.0, "palms": PALMS_TO_WALL,
				"hands": "right", "grip": [1.5, 3.0], "drive": _drive_climb},
		{"name": "climb_hang_two", "at": "hold1", "title": "Both hands on Hold1, lower them 0.3 m: the body rises 0.3 m and hangs there still; let go and land",
				"start": CLIMB_START, "facing": Vector3.BACK, "limit": 6.5, "palms": PALMS_TO_WALL,
				"grip": [1.5, 4.5], "pull": [2.0, 3.0, 0.3], "drive": _drive_climb},
		{"name": "climb_pull_two", "at": "hold1", "title": "Both hands on Hold1, pull down 0.6 m fast: the body rises as fast as two arms haul, then catches up",
				"start": CLIMB_START, "facing": Vector3.BACK, "limit": 5.5, "palms": PALMS_TO_WALL,
				"grip": [1.5, 4.0], "pull": [2.0, 2.3, 0.6], "drive": _drive_climb},
		{"name": "climb_pull_one", "at": "hold1", "title": "The right hand alone on Hold1, pull down 0.4 m fast: one arm hauls slowly, then catches up",
				"start": CLIMB_START, "facing": Vector3.BACK, "limit": 6.0, "palms": PALMS_TO_WALL,
				"hands": "right", "grip": [1.5, 4.5], "pull": [2.0, 2.2, 0.4], "drive": _drive_climb},
		{"name": "climb_hang_one_reach", "at": "hold1", "title": "Hang from Hold1 by both hands, let go with the left and reach about: the right holds the body still",
				"start": CLIMB_START, "facing": Vector3.BACK, "limit": 6.5, "palms": PALMS_TO_WALL,
				"grip": [1.5, 6.5], "pull": [2.0, 3.0, 0.3], "reach_left": [3.3, 5.3], "drive": _drive_climb},
		{"name": "climb_throw", "at": "hold1", "title": "Both hands on Hold1, pull down fast and let go mid-pull: the body flies on with the speed the pull gave it",
				"start": CLIMB_START, "facing": Vector3.BACK, "limit": 4.5, "palms": PALMS_TO_WALL,
				"grip": [1.5, 2.3], "pull": [2.0, 2.3, 0.6], "linear": true, "drive": _drive_climb},
		{"name": "climb_tracking_loss", "at": "hold1", "title": "Hang from Hold1, lose both controllers: the body stays held, and the hands let go after 1 s",
				"start": CLIMB_START, "facing": Vector3.BACK, "limit": 6.5, "palms": PALMS_TO_WALL,
				"grip": [1.5, 6.5], "pull": [2.0, 3.0, 0.3], "untrack": [3.5, 6.5], "drive": _drive_climb},
		{"name": "climb_hold_and_prop", "at": "hold1", "title": "A 2 kg box in the left hand, the right on Hold1, pull 0.3 m: the body rises with the box held",
				"start": CLIMB_START, "facing": Vector3.BACK, "limit": 5.5, "palms": PALMS_TO_WALL,
				"hands": "right", "prop_left": true, "grip": [1.5, 4.5], "pull": [2.0, 3.0, 0.3], "drive": _drive_climb},
		{"name": "climb_walk_away", "at": "hold1", "title": "Hold Hold1 with the right hand and walk 1 m back in the room: the hold keeps the body, the view is held within the lean limit, no recentre; let go and the body follows the head",
				"start": CLIMB_START, "facing": Vector3.BACK, "limit": 7.0, "palms": PALMS_TO_WALL,
				"hands": "right", "grip": [1.5, 5.0], "walk_back": [2.0, 4.0, 1.0], "drive": _drive_climb},
		# The headset's missed grabs (2026-09-28): gripped 1-3 cm off a hold
		# with the hand still moving; pulled in, the drive drew the hand off it
		# faster than the grip brought it in and it never locked.
		{"name": "climb_grab_moving", "at": "hold1", "title": "The right hand sweeps up past Hold1 at 0.7 m/s and grips on the way, keeps going 0.16 m, then pulls down 0.4 m: it holds on from the grip",
				"start": CLIMB_START, "facing": Vector3.BACK, "limit": 5.5, "palms": PALMS_TO_WALL,
				"hands": "right", "grip": [1.4, 5.0], "sweep": [1.2, 1.63, -0.15, 0.15], "pull": [2.2, 3.0, 0.4],
				"drive": _drive_climb},
		# The headset's fling (2026-09-28): a holding hand raised fast.
		{"name": "climb_lower_fast", "at": "hold1", "title": "Hauled 0.8 m up Hold1 by the right hand, raise it 0.4 m in 0.15 s: the body sinks no faster than it falls or than lowering_speed, and one arm stops it",
				"start": CLIMB_START, "facing": Vector3.BACK, "limit": 7.0, "palms": PALMS_TO_WALL,
				"hands": "right", "grip": [1.5, 7.0], "pull": [2.0, 3.0, 0.8], "raise": [4.5, 4.65, 0.4],
				"drive": _drive_climb},
		# Climbing, step 2 (2026-09-28): carried off the ground by the arms, the
		# legs draw up to about the hips (LegTuck); let go resting on something,
		# the body stands up out of it.
		{"name": "climb_mantle_notch", "at": "hold4", "title": "Hanging from Hold4 on the Notch's lip, haul up 0.85 m and 0.7 m back over it, let go: the legs drawn up clear the lip, and the body stands up on the Notch's floor",
				"start": Vector3(0.0, 3.3, 3.65), "facing": Vector3.BACK, "limit": 7.0, "palms": PALMS_TO_WALL,
				"hold": "Holds/Hold4", "stool": 1.8, "top": "Static/Platform",
				"grip": [1.5, 4.7], "pull": [2.0, 3.0, 0.85], "haul_back": [3.3, 4.3, 0.7], "drive": _drive_climb},
		{"name": "climb_land_on_feet", "at": "hold1", "title": "Hanging 0.3 m up Hold1 with the legs drawn up, raise the hands 0.45 m: the feet meet the floor and the legs come down, the body standing, still holding",
				"start": CLIMB_START, "facing": Vector3.BACK, "limit": 6.5, "palms": PALMS_TO_WALL,
				"grip": [1.5, 6.5], "pull": [2.0, 3.0, 0.3], "raise": [4.0, 5.0, 0.45], "drive": _drive_climb},
		{"name": "climb_mantle_table", "at": "boxes", "title": "At the table, press both palms down 0.5 m, lean 0.45 m on over it, lift the hands: the legs drawn up clear its edge, and the body stands up on it",
				"start": Vector3(0.53, 0.0, 0.44), "facing": Vector3.RIGHT, "limit": 7.0, "palms": PALMS_DOWN,
				"head_height": 1.45, "top": "Static/Table", "drive": _drive_mantle_table},
		# Snap turning (2026-09-30, decided with the player: snap only, 45°, and no
		# jank for the body, held objects or climbing): the right stick pushed
		# sideways at the times in "snaps" [[time, direction, held for]]
		# (_drive_snaps); every tick is recorded (_track_turn).
		{"name": "turn_snap_stand", "title": "Standing, snap turn right, right (holding the stick 1 s), left, left: four 45° turns about the eyes, back where it started",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 5.5,
				"snaps": [[1.0, 1.0, 0.2], [2.0, 1.0, 1.0], [3.5, -1.0, 0.2], [4.5, -1.0, 0.2]],
				"drive": func(_t: float) -> bool: return false},
		{"name": "turn_snap_walk", "title": "Walking at full stick, snap turn right: the walk carries on the way the view now faces",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 3.5, "walking": true,
				"snaps": [[1.5, 1.0, 0.2]], "drive": _drive_turn_walk},
		{"name": "turn_snap_reach", "title": "Hands held out in front, snap turn right then left: the hands turn with the player, on their targets",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 3.5, "palms": PALMS_DOWN,
				"snaps": [[1.5, 1.0, 0.2], [2.5, -1.0, 0.2]], "drive": _drive_turn_reach},
		{"name": "turn_snap_sword", "at": "weapons", "title": "The sword gripped and lifted 0.2 m, snap turn right: it turns with the hand, held as it was",
				"start": Vector3(0.65, 0.0, 0.54), "facing": Vector3.RIGHT, "limit": 5.5,
				"palms": PALMS_DOWN, "hand_height": 1.35,
				"weapons": [^"Dynamic/Sword", ^"Dynamic/Dagger"], "weapon": ^"Dynamic/Sword",
				"snaps": [[3.2, 1.0, 0.2]], "drive": _drive_grab_weapon},
		{"name": "turn_snap_longsword", "at": "weapons", "title": "The longsword held steady in both hands, snap turn right: it turns with them, held as it was",
				"start": Vector3(0.65, 0.0, 0.805), "facing": Vector3.RIGHT, "limit": 9.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "weapons": [^"Dynamic/LongSword"],
				"object": ^"Dynamic/LongSword", "left_z": 0.74, "right_z": 0.87,
				"right_grip": [1.5, 7.2], "left_grip": [3.0, 7.2], "lift": [1.8, 2.5, 0.2],
				"raise_left": [4.0, 5.0, 5.5, 6.0, 0.05], "roll_right": [6.0, 6.5, 30.0],
				"windows": {"both": [3.5, 3.95], "raised": [5.1, 5.45], "rolled": [6.6, 7.1],
						"dropped": [8.5, 9.0]},
				"snaps": [[6.72, 1.0, 0.2]], "drive": _drive_two_hands},
		{"name": "turn_snap_climb", "at": "hold1", "title": "Hanging from Hold1 by both hands, snap turn right then left: the body hangs still, the hands stay on the hold",
				"start": CLIMB_START, "facing": Vector3.BACK, "limit": 6.5, "palms": PALMS_TO_WALL,
				"grip": [1.5, 4.5], "pull": [2.0, 3.0, 0.3], "snaps": [[3.4, 1.0, 0.2], [3.9, -1.0, 0.2]], "drive": _drive_climb},
		{"name": "turn_snap_climb_prop", "at": "hold1", "title": "The right hand on Hold1, a 2 kg box in the left, hauled 0.3 m, snap turn right: the body hangs still, the box turns with its hand",
				"start": CLIMB_START, "facing": Vector3.BACK, "limit": 5.5, "palms": PALMS_TO_WALL,
				"hands": "right", "prop_left": true, "grip": [1.5, 4.5], "pull": [2.0, 3.0, 0.3], "snaps": [[3.6, 1.0, 0.2]], "drive": _drive_climb},
		# Throwing props (2026-09-30): the light box picked up, wound up over the
		# right shoulder and thrown overhand, the grip opening part way through
		# the swing (_drive_throw).
		{"name": "throw_box_overhand", "at": "boxes", "title": "Pick up the 2 kg box, wind up over the shoulder and throw it overhand, letting go near the top of the swing",
				"start": Vector3(0.65, 0.0, -0.4), "facing": Vector3.RIGHT, "limit": 5.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "box": "LightBox", "throw": [3.4, 0.4, 0.4],
				"drive": _drive_throw},
		{"name": "throw_box_late", "at": "boxes", "title": "The same throw, letting go late, the hand already slowing and turning down",
				"start": Vector3(0.65, 0.0, -0.4), "facing": Vector3.RIGHT, "limit": 5.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "box": "LightBox", "throw": [3.4, 0.4, 0.55],
				"drive": _drive_throw},
		{"name": "throw_sword_flick", "at": "weapons", "title": "The sword gripped, swung overhand with a hard wrist flick at the end (about 45 rad/s), let go mid-flick (measured, not checked)",
				"start": Vector3(0.65, 0.0, 0.54), "facing": Vector3.RIGHT, "limit": 5.5,
				"palms": PALMS_DOWN, "hand_height": 1.35,
				"weapons": [^"Dynamic/Sword", ^"Dynamic/Dagger"], "weapon": ^"Dynamic/Sword",
				"throw": [3.7, 0.4, 0.7], "flick": [50.0, -100.0, 0.55, 0.8], "drive": _drive_flick},
		# Strikes (the strike model, rung 1, 2026-09-30): every physical object
		# strikes blunt. The posts are kept and placed where each scenario needs
		# them; "expect" lists its checks (_accept_strike).
		{"name": "strike_punch_cloth", "title": "A right fist, knuckles first, punched at 5 m/s into the cloth dummy: one blunt strike by the hand",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 2.5, "palms": PALMS_DOWN,
				"targets": [^"Targets/ClothDummy"],
				"place": {^"Targets/ClothDummy": Transform3D(Basis.IDENTITY, Vector3(-1.8, 0.8, 0.35))},
				"punch": [1.0, 5.0, -0.15, -0.6, 1.35, true],
				"expect": {"count": 1, "striker": "RightHand", "held_by": 0, "source": 1, "kind": Strike.Kind.BLUNT,
						"mass": [0.6, 1.3], "speed": [1.5, 7.0]},
				"drive": _drive_punch},
		{"name": "strike_punch_stone", "title": "The same punch into the stone block: one blunt strike, stone's damage",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 2.5, "palms": PALMS_DOWN,
				"targets": [^"Targets/StoneBlock"],
				"place": {^"Targets/StoneBlock": Transform3D(Basis.IDENTITY, Vector3(-1.8, 1.2, 0.25))},
				"punch": [1.0, 5.0, -0.15, -0.6, 1.35, true],
				"expect": {"count": 1, "striker": "RightHand", "held_by": 0, "source": 1, "kind": Strike.Kind.BLUNT,
						"mass": [0.6, 1.3], "speed": [1.5, 7.0]},
				"drive": _drive_punch},
		{"name": "strike_press_post", "title": "An open palm pushed into the wooden post at 0.2 m/s and held pressing: no strike",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 4.5, "palms": PALMS_TO_WALL,
				"targets": [^"Targets/WoodPost"],
				"place": {^"Targets/WoodPost": Transform3D(Basis.IDENTITY, Vector3(-1.8, 0.8, 0.4))},
				"punch": [1.0, 0.2, -0.3, -0.62, 1.35, false],
				"expect": {"count": 0, "source": 0},
				"drive": _drive_punch},
		{"name": "strike_rest_sword", "title": "The sword let down flat 2 cm above the stone block, left lying there: at most one (light) strike as it lands",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 3.0,
				"weapons": [^"Dynamic/Sword"], "targets": [^"Targets/StoneBlock"],
				"place": {^"Targets/StoneBlock": Transform3D(Basis.IDENTITY, Vector3(-2.0, 0.5, -1.0)),
						^"Dynamic/Sword": Transform3D(Basis(Vector3.RIGHT, Vector3.FORWARD, Vector3.UP),
								Vector3(-2.0, 1.0331, -1.0))},
				"expect": {"count": [0, 1], "after": -0.3, "source": 0, "kind": Strike.Kind.BLUNT},
				"drive": func(_t: float) -> bool: return false},
		{"name": "strike_sword_post", "at": "weapons", "title": "The sword gripped and lifted from the table, then pushed edge first at 4 m/s into the wooden post: one strike, by the held sword",
				"start": Vector3(0.65, 0.0, 0.54), "facing": Vector3.RIGHT, "limit": 4.5,
				"palms": PALMS_DOWN, "hand_height": 1.35,
				"weapons": [^"Dynamic/Sword"], "weapon": ^"Dynamic/Sword", "targets": [^"Targets/WoodPost"],
				"place": {^"Targets/WoodPost": Transform3D(Basis.IDENTITY, Vector3(1.42, 0.8, 0.25))},
				"push": [3.3, 4.0, 0.45],
				"expect": {"count": 1, "striker": "Sword", "held_by": 2, "source": 2, "held_at_end": true,
						"kind": Strike.Kind.SLASH, "mass": [0.2, 2.3], "speed": [1.0, 8.0]},
				"drive": _drive_weapon_push},
		{"name": "strike_axe_stone", "at": "weapons", "title": "The axe gripped and lifted from the table, then pushed head first at 4 m/s into the stone block: one strike, by the held axe",
				"start": Vector3(0.65, 0.0, -1.04), "facing": Vector3.RIGHT, "limit": 4.5,
				"palms": PALMS_DOWN, "hand_height": 1.35,
				"weapons": [^"Dynamic/Axe"], "weapon": ^"Dynamic/Axe", "targets": [^"Targets/StoneBlock"],
				"place": {^"Targets/StoneBlock": Transform3D(Basis.IDENTITY, Vector3(1.62, 1.0, -1.4))},
				"push": [3.3, 4.0, 0.45],
				"expect": {"count": 1, "striker": "Axe", "held_by": 2, "source": 2, "held_at_end": true,
						"kind": Strike.Kind.BLUNT, "mass": [0.2, 2.1], "speed": [1.0, 8.0]},
				"drive": _drive_weapon_push},
		{"name": "strike_longsword_two_hand", "at": "weapons", "title": "The longsword in both hands, lifted, then thrust tip first at 3 m/s to the left into the wooden post: one slash (its point), held by both",
				"start": Vector3(0.65, 0.0, 0.805), "facing": Vector3.RIGHT, "limit": 6.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "weapons": [^"Dynamic/LongSword"],
				"object": ^"Dynamic/LongSword", "left_z": 0.74, "right_z": 0.87,
				"right_grip": [1.5, 9.0], "left_grip": [3.0, 9.0], "lift": [1.8, 2.5, 0.2],
				"push": [4.2, 3.0, 0.3], "push_toward": Vector3.LEFT, "windows": {"both": [3.5, 4.0]},
				"targets": [^"Targets/WoodPost"],
				"place": {^"Targets/WoodPost": Transform3D(Basis.IDENTITY, Vector3(1.1, 1.81, -0.25))},
				"expect": {"count": 1, "striker": "LongSword", "held_by": 3, "source_both": 2,
						"kind": Strike.Kind.SLASH, "mass": [0.3, 4.0], "speed": [1.0, 8.0]},
				"drive": _drive_two_hands},
		{"name": "strike_box_cloth", "title": "A 2 kg box launched face first at 4 m/s into the cloth dummy: one strike at the box's own speed and mass, no hand's",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 1.5,
				"targets": [^"Targets/ClothDummy"],
				"place": {^"Targets/ClothDummy": Transform3D(Basis.IDENTITY, Vector3(-2.0, 0.8, -1.0))},
				"box_launch": [Vector3(-2.0, 1.0, 0.0), Vector3(0.0, 0.0, -4.0), 2.0],
				"expect": {"count": 1, "striker": "Box", "held_by": 0, "source": 0, "box_speed": 0.03,
						"kind": Strike.Kind.BLUNT, "mass": [1.9, 2.05]},
				"drive": _drive_box_launch},
		{"name": "strike_box_drop", "title": "The 2 kg box dropped flat from 0.5 m onto the stone block: one strike worth m·g·h at its full mass, then none at rest",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 2.0,
				"targets": [^"Targets/StoneBlock"],
				"place": {^"Targets/StoneBlock": Transform3D(Basis.IDENTITY, Vector3(-2.0, 0.5, -1.0))},
				"box_launch": [Vector3(-2.0, 1.55, -1.0), Vector3.ZERO, 2.0],
				"expect": {"count": 1, "striker": "Box", "held_by": 0, "source": 0, "box_speed": 0.03,
						"kind": Strike.Kind.BLUNT, "drop": [0.5, 0.1], "mass": [1.96, 2.04]},
				"drive": _drive_box_launch},
		{"name": "strike_dagger_let_go", "at": "weapons", "title": "The dagger gripped and thrown overhand at the cloth dummy beyond the table: one strike, counted for the hand that let go",
				"start": Vector3(0.65, 0.0, 0.34), "facing": Vector3.RIGHT, "limit": 5.5,
				"palms": PALMS_DOWN, "hand_height": 1.35,
				"weapons": [^"Dynamic/Dagger"], "weapon": ^"Dynamic/Dagger", "targets": [^"Targets/ClothDummy"],
				"place": {^"Targets/ClothDummy": Transform3D(Basis.IDENTITY, Vector3(2.2, 0.8, 0.54))},
				"throw": [3.7, 0.4, 0.4], "flick": [0.0, 0.0, 0.5, 0.8],
				"expect": {"count": 1, "striker": "Dagger", "held_by": 0, "source": 3},
				"drive": _drive_flick},
		# The sharp damage type (the strike model, rung 2, 2026-10-01; one sharp
		# type, slash, since 2026-10-02): a sharp part leading the blow slashes;
		# stone takes only blunt. The axe and the
		# pickaxe are laid turned round where a scenario needs their other side to
		# face the post ("place"), with their grips where the level has them.
		{"name": "strike_sword_flat_wood", "at": "weapons", "title": "The sword lifted, the wrist turned a quarter so the blade's flat faces ahead, pushed into the wooden post: blunt",
				"start": Vector3(0.65, 0.0, 0.54), "facing": Vector3.RIGHT, "limit": 4.5,
				"palms": PALMS_DOWN, "hand_height": 1.35,
				"weapons": [^"Dynamic/Sword"], "weapon": ^"Dynamic/Sword", "targets": [^"Targets/WoodPost"],
				"place": {^"Targets/WoodPost": Transform3D(Basis.IDENTITY, Vector3(1.42, 0.8, 0.25))},
				"roll": [3.0, 3.25, 90.0], "push": [3.3, 4.0, 0.45],
				"expect": {"count": 1, "striker": "Sword", "held_by": 2, "source": 2, "kind": Strike.Kind.BLUNT},
				"drive": _drive_weapon_push},
		{"name": "strike_sword_edge_stone", "at": "weapons", "title": "The sword pushed edge first into the stone block: stone takes no slash, so blunt",
				"start": Vector3(0.65, 0.0, 0.54), "facing": Vector3.RIGHT, "limit": 4.5,
				"palms": PALMS_DOWN, "hand_height": 1.35,
				"weapons": [^"Dynamic/Sword"], "weapon": ^"Dynamic/Sword", "targets": [^"Targets/StoneBlock"],
				"place": {^"Targets/StoneBlock": Transform3D(Basis.IDENTITY, Vector3(1.57, 1.0, -0.05))},
				"push": [3.3, 4.0, 0.45],
				"expect": {"count": 1, "striker": "Sword", "held_by": 2, "source": 2, "kind": Strike.Kind.BLUNT},
				"drive": _drive_weapon_push},
		{"name": "strike_axe_bit_wood", "at": "weapons", "title": "The axe, laid with its bit away from the player, pushed bit first into the wooden post: slash",
				"start": Vector3(0.65, 0.0, -1.04), "facing": Vector3.RIGHT, "limit": 4.5,
				"palms": PALMS_DOWN, "hand_height": 1.35,
				"weapons": [^"Dynamic/Axe"], "weapon": ^"Dynamic/Axe", "targets": [^"Targets/WoodPost"],
				"place": {^"Dynamic/Axe": Transform3D(Basis(Vector3.LEFT, Vector3.BACK, Vector3.UP), Vector3(1.0, 1.0185, -0.779)),
						^"Targets/WoodPost": Transform3D(Basis.IDENTITY, Vector3(1.42, 0.8, -0.78))},
				"push": [3.3, 4.0, 0.45],
				"expect": {"count": 1, "striker": "Axe", "held_by": 2, "source": 2, "kind": Strike.Kind.SLASH},
				"drive": _drive_weapon_push},
		{"name": "strike_pick_wood", "at": "weapons", "title": "The pickaxe, laid with its pick away from the player, pushed pick first into the wooden post: slash (a point is sharp)",
				"start": Vector3(0.65, 0.0, -0.312), "facing": Vector3.RIGHT, "limit": 4.5,
				"palms": PALMS_DOWN, "hand_height": 1.35,
				"weapons": [^"Dynamic/Pickaxe"], "weapon": ^"Dynamic/Pickaxe", "targets": [^"Targets/WoodPost"],
				"place": {^"Dynamic/Pickaxe": Transform3D(Basis(Vector3.LEFT, Vector3.BACK, Vector3.UP), Vector3(1.0, 1.038, -0.075)),
						^"Targets/WoodPost": Transform3D(Basis.IDENTITY, Vector3(1.42, 0.8, -0.1))},
				"push": [3.3, 4.0, 0.45],
				"expect": {"count": 1, "striker": "Pickaxe", "held_by": 2, "source": 2, "kind": Strike.Kind.SLASH},
				"drive": _drive_weapon_push},
		{"name": "strike_adze_wood", "at": "weapons", "title": "The pickaxe as the level lays it, its adze away from the player, pushed adze first into the wooden post: slash",
				"start": Vector3(0.65, 0.0, -0.312), "facing": Vector3.RIGHT, "limit": 4.5,
				"palms": PALMS_DOWN, "hand_height": 1.35,
				"weapons": [^"Dynamic/Pickaxe"], "weapon": ^"Dynamic/Pickaxe", "targets": [^"Targets/WoodPost"],
				"place": {^"Targets/WoodPost": Transform3D(Basis.IDENTITY, Vector3(1.42, 0.8, -0.53))},
				"push": [3.3, 4.0, 0.45],
				"expect": {"count": 1, "striker": "Pickaxe", "held_by": 2, "source": 2, "kind": Strike.Kind.SLASH},
				"drive": _drive_weapon_push},
		{"name": "strike_dagger_stab_cloth", "at": "weapons", "title": "The dagger lifted and thrust tip first to the left into the cloth dummy: slash (a point is sharp)",
				"start": Vector3(0.65, 0.0, 0.34), "facing": Vector3.RIGHT, "limit": 4.5,
				"palms": PALMS_DOWN, "hand_height": 1.35,
				"weapons": [^"Dynamic/Dagger"], "weapon": ^"Dynamic/Dagger", "targets": [^"Targets/ClothDummy"],
				"place": {^"Targets/ClothDummy": Transform3D(Basis.IDENTITY, Vector3(0.785, 1.8, -0.2))},
				"push": [3.3, 3.0, 0.25], "push_toward": Vector3.LEFT,
				"expect": {"count": 1, "striker": "Dagger", "held_by": 2, "source": 2, "kind": Strike.Kind.SLASH},
				"drive": _drive_weapon_push},
		# Measured, not checked: a sword spinning free sweeps its blade through
		# the cloth dummy, to see how fast a blade's turn can outrun the contacts
		# (Jolt's continuous collision sweeps only straight-line motion).
		{"name": "strike_spin_20", "title": "The sword spinning at 20 rad/s sweeps its blade into the cloth dummy (measured, not checked)",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 1.0,
				"weapons": [^"Dynamic/Sword"], "weapon": ^"Dynamic/Sword", "targets": [^"Targets/ClothDummy"],
				"place": {^"Targets/ClothDummy": Transform3D(Basis.IDENTITY, Vector3(-2.0, 0.8, -1.0))},
				"spin": [Vector3(-2.0, 1.1, -0.6), Vector3(-20.0, 0.0, 0.0)], "drive": _drive_spin},
		{"name": "strike_spin_40", "title": "The same at 40 rad/s (measured, not checked)",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 1.0,
				"weapons": [^"Dynamic/Sword"], "weapon": ^"Dynamic/Sword", "targets": [^"Targets/ClothDummy"],
				"place": {^"Targets/ClothDummy": Transform3D(Basis.IDENTITY, Vector3(-2.0, 0.8, -1.0))},
				"spin": [Vector3(-2.0, 1.1, -0.6), Vector3(-40.0, 0.0, 0.0)], "drive": _drive_spin},
		{"name": "strike_spin_60", "title": "The same at 60 rad/s (measured, not checked)",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 1.0,
				"weapons": [^"Dynamic/Sword"], "weapon": ^"Dynamic/Sword", "targets": [^"Targets/ClothDummy"],
				"place": {^"Targets/ClothDummy": Transform3D(Basis.IDENTITY, Vector3(-2.0, 0.8, -1.0))},
				"spin": [Vector3(-2.0, 1.1, -0.6), Vector3(-60.0, 0.0, 0.0)], "drive": _drive_spin},
		# Health (2026-10-02): an ore vein is struck as one object through any of
		# its bodies (one per mesh), loses each strike's damage (1 to 10) from its
		# health, shows what is left over it, and frees itself at 0. The copper
		# vein is put where the box scenarios put the posts, and the box aimed at
		# its middle (75 % size since 2026-10-02: 0.97 m tall). Last in the list,
		# so the scenarios before them run as they did.
		{"name": "strike_box_vein", "title": "A 2 kg box launched at 6 m/s into the copper ore vein: struck as the vein, whose health falls by the damage, shown over it",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 1.5,
				"vein": ^"Copper",
				"place": {^"Copper": Transform3D(Basis.IDENTITY, Vector3(-2.0, 0.0, -1.2))},
				"box_launch": [Vector3(-2.0, 0.58, 0.0), Vector3(0.0, 0.0, -6.0), 2.0],
				"expect": {"count": [1, 3], "striker": "Box", "held_by": 0, "source": 0,
						"kind": Strike.Kind.BLUNT, "target": "Copper", "broken": false},
				"drive": _drive_box_launch},
		{"name": "strike_vein_break", "title": "The same box into the copper vein left with 1 health: the strike takes the last of it, and the vein is gone",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 1.5,
				"vein": ^"Copper", "vein_health": 1,
				"place": {^"Copper": Transform3D(Basis.IDENTITY, Vector3(-2.0, 0.0, -1.2))},
				"box_launch": [Vector3(-2.0, 0.58, 0.0), Vector3(0.0, 0.0, -6.0), 2.0],
				"expect": {"count": 1, "striker": "Box", "held_by": 0, "source": 0,
						"kind": Strike.Kind.BLUNT, "target": "Copper", "broken": true, "loot": 4},
				"drive": _drive_box_launch},
		# Loot (2026-10-02): the vein's health emptied at once, with nothing else
		# about, so its four ores fall on their own.
		{"name": "vein_loot_drop", "title": "The copper vein's health emptied at once: four copper ores appear inside it, clear of each other, unpushed, and come to rest where it stood",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 3.0,
				"vein": ^"Copper", "break_at": 0.2,
				"place": {^"Copper": Transform3D(Basis.IDENTITY, Vector3(-2.0, 0.0, -1.2))},
				"expect": {"loot": 4, "settle": true},
				"drive": _drive_vein_break},
		# Chopping (rung 1, 2026-10-02; at segment lines since 1b): the level's tree
		# is turned and moved so its first trunk line's side 0 is where the post
		# scenarios' blows land ("tree_face"), then struck the same way. A slash
		# opens the side it lands on; a blunt blow opens nothing; the line open
		# enough fells the tree, whose top splits off to fall (rung 2;
		# chop_tree_falls follows a fall where the tree stands on the floor). The
		# axe's push stops 0.28 m out, 4 cm past the bark: the trunk is far wider
		# than the post, so the post scenarios' longer push brings the hand
		# gripping the axe onto the curving bark beside the bit (a blunt touch,
		# which opens nothing). Last in the list, so the scenarios before them run
		# as they did.
		{"name": "chop_axe_tree", "at": "weapons", "title": "The axe pushed bit first into the tree at its first trunk line: a slash that opens the side it lands on by its damage",
				"start": Vector3(0.65, 0.0, -1.04), "facing": Vector3.RIGHT, "limit": 4.5,
				"palms": PALMS_DOWN, "hand_height": 1.35,
				"weapons": [^"Dynamic/Axe"], "weapon": ^"Dynamic/Axe",
				"place": {^"Dynamic/Axe": Transform3D(Basis(Vector3.LEFT, Vector3.BACK, Vector3.UP), Vector3(1.0, 1.0185, -0.779))},
				"tree": ^"ProceduralTree", "tree_face": [Vector3(1.32, 1.25, -0.869), Vector3(-0.866, 0.0, -0.5)],
				"push": [3.3, 4.0, 0.28],
				"expect": {"count": 1, "striker": "Axe", "held_by": 2, "source": 2, "kind": Strike.Kind.SLASH,
						"target": "ProceduralTree", "on_line": true, "opened": true, "felled": false},
				"drive": _drive_weapon_push},
		{"name": "chop_axe_fell", "at": "weapons", "title": "The same blow on the line 299 open around the side it lands on: it opens the 300th, and the tree is felled, its top splitting off to fall while the stump stays",
				"start": Vector3(0.65, 0.0, -1.04), "facing": Vector3.RIGHT, "limit": 4.5,
				"palms": PALMS_DOWN, "hand_height": 1.35,
				"weapons": [^"Dynamic/Axe"], "weapon": ^"Dynamic/Axe",
				"place": {^"Dynamic/Axe": Transform3D(Basis(Vector3.LEFT, Vector3.BACK, Vector3.UP), Vector3(1.0, 1.0185, -0.779))},
				"tree": ^"ProceduralTree", "tree_face": [Vector3(1.32, 1.25, -0.869), Vector3(-0.866, 0.0, -0.5)],
				"chop_preset": [0, 0, 50, 50, 50, 50, 50, 49],
				"push": [3.3, 4.0, 0.28],
				"expect": {"count": 1, "striker": "Axe", "held_by": 2, "source": 2, "kind": Strike.Kind.SLASH,
						"target": "ProceduralTree", "on_line": true, "opened": true, "felled": true},
				"drive": _drive_weapon_push},
		{"name": "chop_box_tree", "title": "A 2 kg box launched at 4 m/s into the tree at its first trunk line: a blunt strike, which opens nothing",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 1.5,
				"tree": ^"ProceduralTree", "tree_face": [Vector3(-2.0, 0.775, -0.85), Vector3.BACK],
				"box_launch": [Vector3(-2.0, 1.0, 0.0), Vector3(0.0, 0.0, -4.0), 2.0],
				"expect": {"count": [1, 3], "striker": "Box", "held_by": 0, "source": 0, "kind": Strike.Kind.BLUNT,
						"target": "ProceduralTree", "on_line": true, "opened": false, "felled": false},
				"drive": _drive_box_launch},
		# A convex shape's grab point (2026-10-02). A palm pressed onto the
		# half-size ore on the table (hands meet loose props, so its grab point
		# stays outside the ore) takes hold on its surface and lifts it. Then the
		# case that held ores by their centre: a second hand reaching into an ore
		# the first holds (the Held layer, which hands pass through), its grab
		# point at the ore's centre, where the cast it used saw nothing. Last in
		# the list, so the scenarios before them run as they did.
		{"name": "grab_ore_pressed", "at": "weapons", "title": "The right palm pressed 1 cm down onto a copper ore on the table, gripped and lifted 0.2 m: held by its surface, the hand outside it",
				"start": Vector3(0.65, 0.0, 0.34), "facing": Vector3.RIGHT, "limit": 4.0,
				"palms": PALMS_DOWN, "hand_height": 1.35,
				"weapons": [^"CopperOre"], "weapon": ^"CopperOre", "press": 0.01,
				"place": {^"CopperOre": Transform3D(Basis.IDENTITY, Vector3(1.0, 1.064, 0.34))},
				"drive": _drive_grab_ore},
		{"name": "grab_ore_join", "at": "weapons", "title": "The ore lifted in the right hand; the left hand's grab point brought into it, to its centre, and the left grips: it holds the ore by its surface, not inside it",
				"start": Vector3(0.65, 0.0, 0.34), "facing": Vector3.RIGHT, "limit": 5.0,
				"palms": PALMS_DOWN, "hand_height": 1.35,
				"weapons": [^"CopperOre"], "weapon": ^"CopperOre", "press": 0.0,
				"place": {^"CopperOre": Transform3D(Basis.IDENTITY, Vector3(1.0, 1.064, 0.34))},
				"drive": _drive_grab_ore_join},
		# The hands meet what the other hand holds (2026-10-03): the sword lifted
		# in the right hand, met by the open left hand, or by the dagger in it
		# (_drive_held_contact). "steady" is the window the held object should be
		# still in; "recorded" scenarios are measured, not judged.
		{"name": "held_palm_push", "at": "weapons", "title": "The sword lifted in the right hand; the open left palm pressed 3 cm down into its blade, held, lifted off: the palm stays on the blade, the grip holds",
				"start": Vector3(0.65, 0.0, 0.54), "facing": Vector3.RIGHT, "limit": 6.5,
				"palms": PALMS_DOWN, "hand_height": 1.35, "weapons": [^"Dynamic/Sword"], "weapon": ^"Dynamic/Sword",
				"contact": ["press", 0.03], "steady": [4.6, 5.4], "drive": _drive_held_contact},
		{"name": "held_palm_under", "at": "weapons", "title": "The sword lifted in the right hand; the open left hand brought in under its blade and raised 2 cm into it: the blade rests on it, the grip holds",
				"start": Vector3(0.65, 0.0, 0.54), "facing": Vector3.RIGHT, "limit": 6.5,
				"palms": PALMS_DOWN, "hand_height": 1.35, "weapons": [^"Dynamic/Sword"], "weapon": ^"Dynamic/Sword",
				"contact": ["under", 0.02], "steady": [5.2, 6.2], "drive": _drive_held_contact},
		{"name": "held_strike_palm", "at": "weapons", "title": "The sword lifted in the right hand and pushed edge first at 2 m/s into the still, open left hand: the hand stops the blade, the grip holds",
				"start": Vector3(0.65, 0.0, 0.54), "facing": Vector3.RIGHT, "limit": 6.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "weapons": [^"Dynamic/Sword"], "weapon": ^"Dynamic/Sword",
				"contact": ["strike", 2.0, 0.19], "steady": [5.0, 6.0], "drive": _drive_held_contact},
		{"name": "held_slap_fast", "at": "weapons", "title": "The sword lifted in the right hand; the open left hand slapped across its blade at 5 m/s, its target 15 cm beyond: measured (tunnelling, give)",
				"start": Vector3(0.65, 0.0, 0.54), "facing": Vector3.RIGHT, "limit": 5.5,
				"palms": PALMS_DOWN, "hand_height": 1.35, "weapons": [^"Dynamic/Sword"], "weapon": ^"Dynamic/Sword",
				"contact": ["slap", 5.0, 0.4], "steady": [5.0, 5.5], "recorded": true, "drive": _drive_held_contact},
		{"name": "held_clash", "at": "weapons", "title": "The sword in the right hand pushed edge first at 2 m/s into the dagger held still in the left, 2 cm past it: the blades meet, both grips hold",
				"start": Vector3(0.65, 0.0, 0.54), "facing": Vector3.RIGHT, "limit": 6.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "weapons": [^"Dynamic/Sword", ^"Dynamic/Dagger"],
				"weapon": ^"Dynamic/Sword", "contact": ["clash", 2.0, 0.02], "steady": [4.8, 6.0],
				"drive": _drive_held_contact},
		{"name": "held_clash_fast", "at": "weapons", "title": "As held_clash at 5 m/s: measured (tunnelling, give)",
				"start": Vector3(0.65, 0.0, 0.54), "facing": Vector3.RIGHT, "limit": 6.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "weapons": [^"Dynamic/Sword", ^"Dynamic/Dagger"],
				"weapon": ^"Dynamic/Sword", "contact": ["clash", 5.0, 0.02], "steady": [4.8, 6.0], "recorded": true,
				"drive": _drive_held_contact},
		{"name": "held_clash_deep", "at": "weapons", "title": "As held_clash, pushed 10 cm past the dagger: measured (how far a hard press bends the grips)",
				"start": Vector3(0.65, 0.0, 0.54), "facing": Vector3.RIGHT, "limit": 6.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "weapons": [^"Dynamic/Sword", ^"Dynamic/Dagger"],
				"weapon": ^"Dynamic/Sword", "contact": ["clash", 2.0, 0.1], "steady": [4.8, 6.0], "recorded": true,
				"drive": _drive_held_contact},
		# Felling (chopping rung 2, 2026-10-02): the tree where the level has it, on
		# the floor, its first trunk line opened all but sides 0 and 1 at 0.2 s, as
		# a felling slash would. Its top tips away from that uncut wood, falls and
		# comes to rest. Last in the list, so the scenarios before it run as they
		# did. Fall damage (2026-10-03): landing, the top breaks its limbs at the
		# lines nearest where they hit the floor. Felled at line 1, the level's oak
		# always broke limb 1 at its lines 5, 4 and 3 (6.50, 2.45, 2.23 to 2.50 m/s)
		# and then limb 8 at its line 3 (7.0 to 7.9 m/s) at 3.5 s; what broke after
		# (up to three more, as late as 4.4 s) changed with the scenarios run before
		# it (the same run twice broke the same). The pieces roll and rock on the
		# floor for up to 7 s after they break (one rolled out, back and out again,
		# at rest 6.8 s after it broke), and a branch tip may creep on for good at
		# 0.073 m/s (CREEP_SPEED), so these scenarios run 13 s.
		{"name": "chop_tree_falls", "title": "The tree, standing on the floor, felled with sides 0 and 1 left uncut: its top tips over away from them, falls without flying about, breaks limbs where they hit the floor and lies at rest, its leaves that met the floor gone; the stump stays",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 13.0,
				"tree": ^"ProceduralTree", "fell_at": 0.2, "open_sides": [0, 0, 50, 50, 50, 50, 50, 50],
				"expect": {"fall": {"down_by": 4.0, "rest_by": 8.0, "max_speed": 12.0, "leaves": true},
						"breaks": {"count": [4, 10], "first": [["top", 1, 5], ["top", 1, 4], ["top", 1, 3], ["top", 8, 3]],
						"rest_by": 11.5}},
				"drive": _drive_tree_fell},
		# The felled top meets everything (2026-10-02). With no layer of its own, a
		# dropped axe once drove it into the floor at the axe's own speed. Dropped
		# once all its limbs have broken (fall damage; the last at 4.4 s), it breaks
		# nothing.
		{"name": "chop_axe_drop_on_log", "title": "The axe dropped from 1.2 m onto the felled tree's top lying at rest: it bounces off, and the top stays where it lay, on the floor, nothing broken off it",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 13.0,
				"weapons": [^"Dynamic/Axe"], "weapon": ^"Dynamic/Axe",
				"tree": ^"ProceduralTree", "fell_at": 0.2, "open_sides": [0, 0, 50, 50, 50, 50, 50, 50],
				"drop_at": 5.5, "drop_height": 1.2,
				"expect": {"fall": {"down_by": 4.0, "rest_by": 9.0, "max_speed": 12.0}, "drop": {"shift": 0.02},
						"breaks": {"count": [4, 10], "first": [["top", 1, 5], ["top", 1, 4], ["top", 1, 3], ["top", 8, 3]],
						"quiet_from": "dropped", "rest_by": 11.5}},
				"drive": _drive_tree_fell},
		# Limbs and leaves (chopping, 2026-10-02), the tree where the level has it.
		# Its thickest limb cut through at its first line that can be chopped (the
		# one before it is inside the limb's junction), as slashes would: the limb
		# comes off as its own piece and falls, the tree still standing; bare once
		# its leaves broke on the floor, it may rock on its crook a few seconds
		# (Jolt has no rolling resistance; FelledTree.ROLLING_DAMP stands in). A box
		# sent through a leaf cluster with its gravity off, so it keeps its speed:
		# slower than a swing it breaks nothing; at a swing's speed it breaks what
		# it passes through. Last in the list, so the scenarios before them run as
		# they did. Fall damage (2026-10-03): the limb lands at 6 to 8.6 m/s and
		# breaks up, always first its branch 2 at its line 1, then its own lines 5
		# and 3 (the piece broken at 3 then broke at its line 4 too, in every run so
		# far): five pieces, 25 to 50 kg, all at rest by 6.2 s, but for the branch
		# tip, which in one run crept on for 10 s (CREEP_SPEED).
		{"name": "chop_branch_line", "title": "The tree's thickest limb cut through at its first line that can be chopped at 0.2 s: it comes off as its own piece, leaving a capped stub with no line to chop, falls, breaks up where it hits the floor, and its pieces come to rest; the tree still stands",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 10.0,
				"tree": ^"ProceduralTree", "cut_at": 0.2,
				"expect": {"limb": {"drop": 1.5, "rest_by": 8.0, "max_speed": 12.0},
						"breaks": {"count": [3, 6], "first": [["cut", 2, 1], ["cut", 1, 5], ["cut", 1, 3]], "rest_by": 8.5}},
				"drive": _drive_line_cut},
		{"name": "leaves_box_slow", "title": "A 2 kg box, its gravity off, sent at 1 m/s through a leaf cluster on the tree, slower than a swing: no leaves break",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 3.5,
				"tree": ^"ProceduralTree", "crown_pass": [1.0, 2.0],
				"expect": {"leaves": false},
				"drive": _drive_crown_pass},
		{"name": "leaves_box_fast", "title": "The same box sent at 4 m/s, a swing's speed: the leaves it passes through break",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 2.0,
				"tree": ^"ProceduralTree", "crown_pass": [4.0, 2.0],
				"expect": {"leaves": true},
				"drive": _drive_crown_pass},
		# Every line chops (chopping 1b, 2026-10-02): any segment line on wood thick
		# enough to hit, standing or felled. The axe's blow at the fourth trunk
		# line as chop_axe_tree's at the first (the tree moved down for it); the
		# tree felled at its fifth; its felled top bucked once it lies at rest,
		# without the cut pushing the pieces apart (as shapes overlapping there
		# would); and the axe swung level so its toe's corner meets the bark first,
		# which the bit's edge reaches since it runs the whole front of the head
		# (it stopped 2 cm short of each end, and a corner there struck blunt).
		# Last in the list, so the scenarios before them run as they did.
		{"name": "chop_axe_high", "at": "weapons", "title": "The axe pushed bit first into the tree at its fourth trunk line (1.8 m up where the level has it) as chop_axe_tree at its first: a slash that opens that line, which the readout now shows",
				"start": Vector3(0.65, 0.0, -1.04), "facing": Vector3.RIGHT, "limit": 4.5,
				"palms": PALMS_DOWN, "hand_height": 1.35,
				"weapons": [^"Dynamic/Axe"], "weapon": ^"Dynamic/Axe",
				"place": {^"Dynamic/Axe": Transform3D(Basis(Vector3.LEFT, Vector3.BACK, Vector3.UP), Vector3(1.0, 1.0185, -0.779))},
				"tree": ^"ProceduralTree", "chop_line": Vector2i(0, 4),
				"tree_face": [Vector3(1.32, 1.25, -0.869), Vector3(-0.866, 0.0, -0.5)],
				"push": [3.3, 4.0, 0.28],
				"expect": {"count": 1, "striker": "Axe", "held_by": 2, "source": 2, "kind": Strike.Kind.SLASH,
						"target": "ProceduralTree", "on_line": true, "opened": true, "felled": false},
				"drive": _drive_weapon_push},
		# Fall damage (2026-10-03): felled at line 5, the top always broke limb 1 at
		# its lines 5 and 4 (4.86, 2.25 to 2.38 m/s), then its branch 2 at line 1,
		# and in some runs limb 1 at line 3 too, all by 2.4 s; it runs 13 s as
		# chop_tree_falls does.
		{"name": "chop_high_cut", "title": "The tree felled at its fifth trunk line, 2.25 m up, sides 0 and 1 left uncut: its top tips over off the stump away from them, falls without flying about, breaks limbs where they hit the floor and lies at rest; the stump, five segments tall, stays",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 13.0,
				"tree": ^"ProceduralTree", "chop_line": Vector2i(0, 5), "fell_at": 0.2,
				"open_sides": [0, 0, 41, 41, 41, 41, 41, 41],
				"expect": {"fall": {"down_by": 3.0, "rest_by": 8.0, "max_speed": 12.0, "stump": 5},
						"breaks": {"count": [3, 8], "first": [["top", 1, 5], ["top", 1, 4]], "rest_by": 11.5}},
				"drive": _drive_tree_fell},
		# Fall damage (2026-10-03): with its limbs broken off on landing, the top
		# lies on its trunk, its butt off the floor (5 cm up at the fourth line), so
		# the part cut off there drops once cut, and in some runs rolled off a stub
		# 1.40 m and lay at rest 8.63 to 8.65 s after the cut: it runs 17 s. With lone
		# pieces damped harder (2026-10-03), the pieces broken off on landing settle
		# elsewhere, and in the whole harness the top then crept off its hump's crest
		# for 4 s, under 0.08 m/s, before it rolled off the stub 1.40 m, at rest 10.06
		# s after the cut (0.26 s after it, settling 0.19 m, with only the tree
		# scenarios run before it, and in the whole harness before the change).
		{"name": "chop_buck_log", "title": "The tree felled as in chop_tree_falls; once its top lies at rest, one of the top's trunk lines cut through: two pieces, neither thrown off the other, which settle onto what holds them up",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 17.0,
				"tree": ^"ProceduralTree", "fell_at": 0.2, "open_sides": [0, 0, 50, 50, 50, 50, 50, 50],
				"buck_at": 6.0, "buck_line": 4,
				"expect": {"buck": {"ticks": 4, "speed": 0.3, "gap": 0.01, "rest_by": 11.0},
						"breaks": {"count": [4, 10], "first": [["top", 1, 5], ["top", 1, 4], ["top", 1, 3], ["top", 8, 3]],
						"rest_by": 11.5}},
				"drive": _drive_tree_fell},
		{"name": "chop_axe_toe", "title": "The axe swung level into the tree's first trunk line, its head rolled 20° so the corner of its toe meets the bark first: a slash, dealt by the bit's toe",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 1.5,
				"weapons": [^"Dynamic/Axe"], "weapon": ^"Dynamic/Axe",
				"tree": ^"ProceduralTree", "tree_face": [Vector3(-2.0, 1.0, -1.0), Vector3.BACK],
				"swing": [1.1, 0.75, 6.0, 20.0, 0.0],
				"expect": {"count": 1, "striker": "Axe", "held_by": 0, "source": 0, "kind": Strike.Kind.SLASH,
						"target": "ProceduralTree", "on_line": true, "opened": true, "felled": false, "toe": 0.02},
				"drive": _drive_swing},
		# Lone pieces (chopping 1c, 2026-10-02): a piece of the tree with no line
		# left to chop has a health that only slashes take, 50 if its main branch is
		# the trunk and 10 if not, and at 0 it is gone, dropping three logs for each
		# segment of trunk wood it held or a stick for each of branch, laid still
		# round its middle; once it is gone they fall. Each is broken once
		# everything cut off the tree lies at rest, by full-strength slashes on its
		# bark (10 damage), scripted as the line presets are: the stump left by a
		# fell, which never moves; a one-segment log bucked off the felled top; the
		# tip of the thickest limb, cut at its last line that can be chopped. What
		# rested on a piece as it went is woken and settles onto what holds it up
		# now; what did not touch it stays put. Last in the list, so the scenarios
		# before them run as they did.
		# Fall damage (2026-10-03): the felled top breaks its limbs as in
		# chop_tree_falls, and the pieces may roll and rock for up to 7 s after,
		# which the stump's slashes wait for (one broken off may creep on slower than
		# CREEP_SPEED): it runs 12 s.
		{"name": "chop_root_loot", "title": "The tree felled as in chop_tree_falls; once its top lies at rest, the stump, lone from the fell with 50 health, slashed to 0 at full strength: the tree is gone, three logs drop round the stump's middle, fall and lie at rest on the floor where they were laid, none thrown, and the top, woken if it rested on the stump, settles onto what holds it up now",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 12.0,
				"tree": ^"ProceduralTree", "fell_at": 0.2, "open_sides": [0, 0, 50, 50, 50, 50, 50, 50],
				"lone": "tree", "slash_at": 5.0, "still": "top",
				"expect": {"lone": {"from": "chop_felled", "health": 50, "loot": 3,
						"scene": "res://scenes/props/wood/log.tscn", "mass": 8.0, "rest_by": 3.0, "aside": 1.0, "chops_on": ["top"],
						"still": {"shift": 0.02, "settle": 0.3, "settle_by": 3.0}},
						"breaks": {"count": [4, 10], "first": [["top", 1, 5], ["top", 1, 4], ["top", 1, 3], ["top", 8, 3]],
						"rest_by": 10.5}},
				"drive": _drive_tree_fell},
		# Fall damage (2026-10-03): with its limbs broken off on landing, the top
		# lies with its butt off the floor (26 cm up at its second line), so the log
		# cut off there drops once cut; in some runs it rolled 0.61 m and lay at
		# rest 5.08 to 5.13 s after the cut. The slashes then wait for every piece
		# to rest: it runs 18 s.
		{"name": "chop_log_loot", "title": "The tree felled and its top bucked as in chop_buck_log, at its second trunk line: the log left between the cuts, one segment, lone with 50 health and the rest of the top not, slashed to 0 at full strength: it is gone, three logs drop round its middle and lie at rest on the floor, none thrown, and the rest of the top, woken if it touched the log, settles onto what holds it up now",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 18.0,
				"tree": ^"ProceduralTree", "fell_at": 0.2, "open_sides": [0, 0, 50, 50, 50, 50, 50, 50],
				"buck_at": 6.0, "buck_line": 2, "lone": "top", "slash_at": 8.0, "still": "rest",
				"expect": {"buck": {"ticks": 4, "speed": 0.3, "gap": 0.01, "rest_by": 7.0},
						"lone": {"from": "bucked", "health": 50, "loot": 3, "scene": "res://scenes/props/wood/log.tscn",
						"mass": 8.0, "rest_by": 3.0, "aside": 1.0, "chops_on": ["rest"],
						"still": {"shift": 0.02, "settle": 0.3, "settle_by": 3.0}},
						"breaks": {"count": [4, 10], "first": [["top", 1, 5], ["top", 1, 4], ["top", 1, 3], ["top", 8, 3]],
						"rest_by": 11.5}},
				"drive": _drive_tree_fell},
		{"name": "chop_stick_loot", "title": "The tree's thickest limb cut through at its last line that can be chopped at 0.2 s: its tip falls to the floor, lone with 10 health; slashed once at full strength, it is gone, and one stick drops at its middle and lies at rest on the floor, not thrown; the tree still stands",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 8.0,
				"tree": ^"ProceduralTree", "cut_at": 0.2, "cut_last": true, "lone": "cut", "slash_at": 3.0,
				"expect": {"limb": {"drop": 3.0, "rest_by": 8.0, "max_speed": 12.0},
						"lone": {"from": "line_cut", "health": 10, "loot": 1, "scene": "res://scenes/props/wood/stick.tscn",
						"mass": 2.5, "rest_by": 3.0, "aside": 1.0, "chops_on": ["tree"]},
						"breaks": {"count": 0, "rest_by": 5.0}},
				"drive": _drive_line_cut},
		# Loot that rolls (2026-10-02, the player: "the stick and log loot should
		# have some angular damp so they dont roll away forever"): a log, then a
		# stick, as its scene makes it, laid on its side on the open floor ahead
		# of the player as LootDrop lays one, and set rolling across its length,
		# away from the player, at 1.5 m/s. Each scene damps its spin by 6 a
		# second (with the world's 0.1). Measured in scratch runs at 6, a stick
		# rolled at 1 m/s stopped after 0.46 m and 1.75 s, and one at 2 m/s after
		# 0.87 m: at 1.5 m/s about 0.67 m and 2 s, so half as much again, 1 m and
		# 3 s, bounds it (at 4, a 1 m/s roll took 6.3 s; from 0.5 to 3 the stick
		# crept on at about 1 mm a tick and never rested). Here the stick rests
		# 0.68 to 0.69 m on, 1.99 s after; the log, which its knot and faceted
		# hull stop too, 0.38 m on, 1.36 s after. Neither goes faster than it was
		# set rolling, though the log gains up to 0.03 m/s a tick as it tips over
		# its knot or a facet. Last in the list, so the scenarios before them run
		# as they did.
		{"name": "loot_log_roll", "title": "A log, as its scene makes it, laid on its side on the open floor and set rolling across its length at 1.5 m/s: it never goes faster than that, and comes to rest within 1 m and 3 s; it weighs 8 kg",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 5.0,
				"roll": {"scene": "res://scenes/props/wood/log.tscn", "from": Vector3(-2.0, 0.0, -0.5),
						"toward": Vector3.FORWARD, "speed": 1.5},
				"expect": {"roll": {"mass": 8.0, "distance": 1.0, "rest_by": 3.0}},
				"drive": _drive_loot_roll},
		{"name": "loot_stick_roll", "title": "A stick, as its scene makes it, laid on its side on the open floor and set rolling across its length at 1.5 m/s: it never goes faster than that, and comes to rest within 1 m and 3 s; it weighs 2.5 kg",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 5.0,
				"roll": {"scene": "res://scenes/props/wood/stick.tscn", "from": Vector3(-2.0, 0.0, -0.5),
						"toward": Vector3.FORWARD, "speed": 1.5},
				"expect": {"roll": {"mass": 2.5, "distance": 1.0, "rest_by": 3.0}},
				"drive": _drive_loot_roll},
		# Looking down at the feet (2026-10-03), last for the same reason.
		{"name": "look_down", "title": "Look down at the feet (60°, then 80°) and back up, bending the neck",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 7.0,
				"drive": _drive_look_down.bind(true)},
		{"name": "look_down_nod", "title": "Look down at the feet (60°, then 80°) and back up, nodding the head alone",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 7.0,
				"drive": _drive_look_down.bind(false)},
		# Fall damage (2026-10-03): a limb set down gently stays whole. The tree's
		# thickest limb cut through as in chop_branch_line and, in that same tick,
		# laid level on the open floor ahead of the player, 2 cm up, still
		# (_set_down): it lands at about 0.6 m/s, far under the impact speed. Last
		# in the list, so the scenarios before it run as they did.
		{"name": "chop_limb_set_down", "title": "The tree's thickest limb cut through as in chop_branch_line and at once laid down level, 2 cm above the open floor: it settles there whole, nothing broken off it",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 4.0,
				"tree": ^"ProceduralTree", "cut_at": 0.2, "set_down": Vector3(-2.5, 0.02, -4.5),
				"expect": {"laid": {"height": 0.02, "under": 1.0},
						"breaks": {"count": 0, "quiet_from": "line_cut", "rest_by": 3.0}},
				"drive": _drive_line_cut},
		# Lone pieces walked into (2026-10-03, after a headset session: "the
		# individual stick and log segments also roll way too easily when walking
		# over them or pushing them"): a lone piece damps its spin by
		# TreeChop.lone_angular_damp, a bigger one by FelledTree.ROLLING_DAMP. At the
		# first tick one is made of the level's oak and laid on the open floor ahead
		# of the player as it comes to rest there (_lay_lone), and from 2 s the
		# stick walks the body into it at full speed, and on. Neither piece is round
		# (the log is two cylinders 0.353 and 0.343 m in radius, their axes 3.7 cm
		# apart; the stick is bent), so each rolls over a hump into a dip, or back
		# into its own. Measured in scratch runs at a damp of 1 (before), 6, 10 and
		# 16: walked into for 2.25 s, the log is pushed on at 1.25, 1.03, 0.91 and
		# 0.78 m/s (the body's own pace), rolls on 2.80, 0.68, 0.24 and 0.11 m after
		# the last touch and lies at rest 5.93, 2.89, 0.97 and 0.82 s after it, 4.67,
		# 2.30, 1.66 and 1.31 m from where it lay. Lying across the way, the stick is
		# stepped over and never moves; lying 10° off it, it is kicked 0.90, 0.32,
		# 0.22 and 0.20 m and lies at rest 5.60, 2.39, 2.01 and 1.31 s after the last
		# touch. At some walk lengths the log stops on its hump's crest and creeps
		# down off it, under 0.07 m/s, for 2 to 8 s, however damped; not at this one
		# (from 2.15 to 2.5 s long, at 16 it lay at rest 0.79 to 0.97 s after). Here,
		# at 16, the log goes 1.31 m, rolls on 0.12 m and lies at rest 0.82 s after
		# the last touch; the stick goes 0.18 to 0.19 m, rolls on 0.13 to 0.15 m and
		# lies at rest 1.17 s after it, 1.72 s in the whole harness (lying 50° to 90°
		# off the way, up to 2.31 s). Last in the list, so the scenarios before them
		# run as they did.
		{"name": "lone_log_walked_into", "title": "A lone log, one segment of the oak's trunk (75 kg), laid on the open floor across the way and walked into at full stick and on for 2.25 s: pushed along, it rolls on at most 0.25 m after the last touch, lies at rest within 1.2 s of it, and ends at most 1.5 m from where it lay",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 7.0, "no_hands": true,
				"tree": ^"ProceduralTree", "lone_set": {"kind": "log", "at": Vector3(-2.0, 0.005, -0.3)},
				"walk": [2.0, 4.25],
				"expect": {"walked": {"moved": 1.5, "rolled_on": 0.25, "rest_by": 1.2}},
				"drive": _drive_lone_walk},
		{"name": "lone_stick_walked_into", "title": "A lone stick, the tip of the oak's thickest limb (25 kg), laid on the open floor 10° off the way and walked over at full stick for 2 s: kicked, it moves at most 0.3 m, rolls on at most 0.25 m after the last touch and lies at rest within 2.5 s of it",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 7.0, "no_hands": true,
				"tree": ^"ProceduralTree", "lone_set": {"kind": "stick", "at": Vector3(-2.0, 0.005, -0.3), "yaw": 80.0},
				"walk": [2.0, 4.0],
				"expect": {"walked": {"moved": 0.3, "rolled_on": 0.25, "rest_by": 2.5}},
				"drive": _drive_lone_walk},
	]


## Climbing (2026-09-28): facing the wall, Hold1 ahead at 2.0 m. The hands in
## "hands" ("both", or "right" with the left down at the side) come 2 cm off the
## side of it their palms face ("palms"), their grab points on its middle, 6 cm
## either side of its centre, by 1.2 s, and grip over
## "grip" [close, open]; "sweep" [from, to, low, high] moves them up past it
## at a steady speed meanwhile, from low to high (m); "pull" [from, to, depth]
## lowers them in the room by depth (smoothly, or at a steady speed with
## "linear"), "raise" [from, to, height] raises them, and "haul_back" [from,
## to, distance] brings them back toward the body. "hold" names the hold
## (Holds/Hold1 by default). A start above the floor stands on a stool
## (_add_stool) until "stool" (s). "untrack" [from, to]
## loses both controllers; "reach_left" [from, to] lets go with the left and
## swings it up and round; "walk_back" [from, to, distance] walks the player
## back in the room, hands and all; "prop_left" puts a 2 kg box in the left
## hand, gripped at 1.5 s. Every tick is recorded (_track_climb).
func _drive_climb(t: float) -> bool:
	var scenario := _scenarios[_index]
	var physical := _player.physical as DynamicPhysical
	var facing: Vector3 = scenario.facing
	var start: Vector3 = scenario.start
	var right := facing.cross(Vector3.UP)
	var palms: Array = scenario.palms
	var palm_out: Vector3 = right * palms[0].x + Vector3.UP * palms[0].y - facing * palms[0].z
	var fingers: Vector3 = right * palms[1].x + Vector3.UP * palms[1].y - facing * palms[1].z
	if not _scenario_state.has("hold_side"):
		var hold := _level.get_node(NodePath(scenario.get("hold", "Holds/Hold1"))) as StaticBody3D
		var size := ((hold.get_node(^"Shape") as CollisionShape3D).shape as BoxShape3D).size
		var half := (hold.global_basis.inverse() * palm_out).abs().dot(size * 0.5)
		_scenario_state.hold_side = hold.global_position - palm_out * half
	# The palm's centre, off the hold by its half-thickness and 2 cm, back
	# from its grab point (grab_forward toward its fingers).
	var over: Vector3 = _scenario_state.hold_side - palm_out * (_palm_half_thickness() + 0.02) \
			- fingers * physical.right_grab.grab_forward
	var reach := smoothstep(0.5, 1.2, t)
	if t >= scenario.get("stool", INF) and _scenario_state.has("stool"):
		(_scenario_state.stool as Node).queue_free()
		_scenario_state.erase("stool")
	var grip: Array = scenario.get("grip", [1.5, 4.5])
	var pull: Array = scenario.get("pull", [0.0, 0.0, 0.0])
	var pulled := clampf((t - pull[0]) / maxf(pull[1] - pull[0], 1e-3), 0.0, 1.0) if scenario.get("linear", false) \
			else smoothstep(pull[0], pull[1], t)
	var lowered: float = pull[2] * pulled
	var haul: Array = scenario.get("haul_back", [0.0, 0.0, 0.0])
	var hauled: float = haul[2] * smoothstep(haul[0], haul[1], t)
	var raise: Array = scenario.get("raise", [0.0, 0.0, 0.0])
	lowered -= raise[2] * smoothstep(raise[0], raise[1], t)
	var sweep: Array = scenario.get("sweep", [0.0, 0.0, 0.0, 0.0])
	lowered -= lerpf(sweep[2], sweep[3], clampf((t - sweep[0]) / maxf(sweep[1] - sweep[0], 1e-3), 0.0, 1.0))
	var walk: Array = scenario.get("walk_back", [0.0, 0.0, 0.0])
	var back: float = walk[2] * smoothstep(walk[0], walk[1], t)
	# The head's position is in the rig's frame, the palms in the head's facing
	# (they go back with it).
	var away := (_player.rig.global_basis.inverse() * -facing).normalized()
	_rig.head_position = Vector3(0.0, SimulatedRig.HEAD_HEIGHT, 0.0) + away * back
	var both: bool = scenario.get("hands", "both") == "both"
	var reach_left: Array = scenario.get("reach_left", [INF, INF])
	for left: bool in [true, false]:
		var palm := Vector3(-0.2 if left else 0.2, 1.0, -0.2)
		var gripping: bool = t >= grip[0] and t < grip[1]
		if both or not left:
			var aim := over + right * (-0.06 if left else 0.06)
			var on_hold := Vector3((aim - start).dot(right), aim.y - start.y, -(aim - start).dot(facing))
			palm = palm.lerp(on_hold, reach) - Vector3.UP * lowered + Vector3.BACK * hauled
			if left and t >= reach_left[0]:
				gripping = false
				var swing := clampf((t - reach_left[0]) / (reach_left[1] - reach_left[0]), 0.0, 1.0) * TAU
				palm += Vector3(0.25 * sin(swing), 0.3 * (1.0 - cos(swing)) * 0.5, 0.1 * sin(swing))
		elif scenario.get("prop_left", false):
			# Palm down beside the body, the box under it clear of the wall.
			palm = Vector3(-0.3, 1.1, -0.1)
			_turn_palm(true, PALMS_DOWN[0], PALMS_DOWN[1])
			gripping = t >= 1.5
			if t >= 1.45 and not _scenario_state.has("prop"):
				var at := _head_frame() * palm - Vector3.UP * (_palm_half_thickness() + 0.05)
				var prop := _spawn_prop(Vector3(0.1, 0.1, 0.1), 2.0, at)
				prop.add_child(Grabbable.new())
				_scenario_state.prop = prop
		else:
			# The free hand down at the side, clear of Hold5, which the player
			# put on the wall under Hold1 (2026-09-30).
			palm = Vector3(-0.3, 0.9, 0.05)
		_place_palm(left, palm)
		_rig.set("left_grip" if left else "right_grip", 1.0 if gripping else 0.0)
	var untrack: Array = scenario.get("untrack", [INF, INF])
	var lost: bool = t >= untrack[0] and t < untrack[1]
	_rig.left_tracked = not lost
	_rig.right_tracked = not lost
	_track_climb(t)
	return false


## Every tick of a climbing scenario: the body's height, how far it is toward
## the wall from the start, the head's lead on it, its vertical speed,
## whether it stands on anything, each hand's grab and whether it holds Hold1,
## the arms' overreach, the relocations, and the left hand's held mass.
func _track_climb(t: float) -> void:
	var physical := _player.physical as DynamicPhysical
	var scenario := _scenarios[_index]
	var hold := _level.get_node(NodePath(scenario.get("hold", "Holds/Hold1")))
	var log: Dictionary = _scenario_state.get("climb", {"t": [], "y": [], "along": [], "lead": [], "vy": [], "left": [], "right": [],
			"on_hold": [], "supported": [], "relocations": [], "overreach": [], "left_mass": [], "tuck": []})
	log.tuck.append(_state.body_tuck)
	if scenario.has("top"):
		var box := _level.get_node(NodePath(scenario.top)) as CSGBox3D
		log.top = box.global_position.y + box.size.y * 0.5
	log.stand_speed = (physical.locomotion.get_node(^"LegTuck") as LegTuck).stand_speed
	log.t.append(t)
	log.y.append(_state.body_position.y)
	log.along.append((_state.body_position - (_scenarios[_index].start as Vector3)).dot(_scenarios[_index].facing))
	log.lead.append(Vector2(_state.head_lead.x, _state.head_lead.z).length())
	log.vy.append(_state.body_velocity.y)
	log.left.append(physical.left_grab.state)
	log.right.append(physical.right_grab.state)
	log.on_hold.append(int(physical.left_grab.target == hold) + 2 * int(physical.right_grab.target == hold))
	log.supported.append(int(_state.supported))
	log.relocations.append(_state.relocations)
	log.overreach.append(maxf(physical.left_drive.overreach, physical.right_drive.overreach))
	log.left_mass.append(_state.grab_mass[0])
	log.tracking_loss = physical.right_grab.tracking_loss_time
	log.climb_strength = physical.right_drive.climb_strength
	log.haul_speed = physical.right_drive.haul_speed
	log.weight = physical.body.mass * physical.body.get_gravity().length()
	log.lowering_speed = physical.right_drive.lowering_speed
	_scenario_state.climb = log


## How often a climbing log's legs were drawn up for under 3 ticks: drawn up
## leaving the floor and straight back down (headset, 2026-09-30).
static func _tuck_flickers(log: Dictionary) -> int:
	var tucks: Array = log.get("tuck", [])
	var flickers := 0
	var run := 0
	for tuck: float in tucks + [0.0]:
		if tuck > 0.0:
			run += 1
			continue
		if run > 0 and run < 3:
			flickers += 1
		run = 0
	return flickers


## The index of the first tick at or after `time` in a climbing log.
static func _climb_tick(log: Dictionary, time: float) -> int:
	var times: Array = log.get("t", [])
	for i in times.size():
		if times[i] >= time:
			return i
	return maxi(times.size() - 1, 0)


## The first tick from `from` on where `key` (a hand's grab) equals `value`, or -1.
static func _climb_first(log: Dictionary, key: String, value: int, from := 0) -> int:
	var values: Array = log.get(key, [])
	for i in range(from, values.size()):
		if values[i] == value:
			return i
	return -1


## The lowest and highest body height between `from` and `to`, in seconds.
static func _climb_span(log: Dictionary, from: float, to: float) -> Vector2:
	var low := INF
	var high := -INF
	for i in range(_climb_tick(log, from), _climb_tick(log, to) + 1):
		low = minf(low, log.y[i])
		high = maxf(high, log.y[i])
	return Vector2(low, high)


## Climbing's checks (_drive_climb). Heights are the body's (its feet).
func _accept_climb(result: Dictionary, failures: Array[String]) -> void:
	var log: Dictionary = result.get("climb", {})
	var scenario := _scenario_named(result.name)
	if not _expect(failures, not log.is_empty(), "climbing was recorded"):
		return
	var grip: Array = scenario.get("grip", [1.5, 4.5])
	var pull: Array = scenario.get("pull", [0.0, 0.0, 0.0])
	var both: bool = scenario.get("hands", "both") == "both"
	var ground: float = log.y[_climb_tick(log, grip[0])]
	# Each climbing hand snaps onto Hold1 and is welded there as the grip
	# closes (within 2 ticks: the rig's grip reaches the grab a tick late).
	var grip_tick := _climb_tick(log, grip[0])
	for key: String in (["left", "right"] if both else ["right"]):
		var locked := _climb_first(log, key, HandGrab.State.HOLDING, grip_tick)
		var bit := 1 if key == "left" else 2
		_expect(failures, locked >= 0 and log.t[locked] - grip[0] <= 0.03 and (int(log.on_hold[locked]) & bit) != 0,
				"the %s hand snapped onto Hold1 and held as the grip closed (%.3f s)" % [key,
				log.t[locked] - grip[0] if locked >= 0 else -1.0])
	var let_go := _climb_first(log, "right", HandGrab.State.IDLE, grip_tick + 1)
	_expect(failures, _tuck_flickers(log) == 0,
			"the legs never drew up for only a tick or two (%d times)" % _tuck_flickers(log))
	match result.name:
		"climb_grab_hold":
			var span := _climb_span(log, grip[0], grip[1] - 0.05)
			_expect(failures, span.y - span.x <= 0.02,
					"the body stayed put while the hand came onto the hold (%.3f m)" % (span.y - span.x))
		"climb_mantle_notch":
			_accept_mantle(result, failures, pull[1], grip[1])
		"climb_land_on_feet":
			var raise: Array = scenario.raise
			var drawn: float = log.tuck[_climb_tick(log, raise[0])]
			_expect(failures, drawn >= 0.7, "hanging, the legs were drawn up (%.3f m)" % drawn)
			var lowest := _climb_span(log, raise[0], grip[1] - 0.1).x
			_expect(failures, lowest >= ground - 0.01,
					"lowered, the body landed on its feet, not its drawn-up bottom (%.3f m)" % (lowest - ground))
			var end: int = _climb_tick(log, grip[1] - 0.1)
			_expect(failures, log.tuck[end] == 0.0 and log.supported[end] == 1 and log.right[end] == HandGrab.State.HOLDING,
					"standing with the legs down, still holding (tuck %.3f m)" % log.tuck[end])
			_expect(failures, absf(log.y[end] - ground) <= 0.01, "on the floor (%.3f m)" % (log.y[end] - ground))
		"climb_hang_two", "climb_hold_and_prop":
			var hang := _climb_span(log, pull[1] + 0.2, grip[1] - 0.1)
			var tolerance := 0.01 if result.name == "climb_hang_two" else 0.02
			_expect(failures, absf((hang.x + hang.y) * 0.5 - ground - pull[2]) <= tolerance,
					"the body rose as far as the hands were lowered (%.3f m of %.2f)" % [(hang.x + hang.y) * 0.5 - ground, pull[2]])
			_expect(failures, hang.y - hang.x <= 0.005, "then hung still (%.4f m)" % (hang.y - hang.x))
			if result.name == "climb_hold_and_prop":
				var carried: float = log.left_mass[_climb_tick(log, grip[1] - 0.1)]
				_expect(failures, absf(carried - 2.0) <= 0.01, "the left hand still held the 2 kg box (%.2f kg)" % carried)
			var landed := _climb_first(log, "supported", 1, _climb_tick(log, grip[1]))
			_expect(failures, landed >= 0, "let go, the body fell and landed")
			# Let go in the air, the drawn-up legs just drop: no standing up.
			var rising := -INF
			for i in range(let_go, landed if landed >= 0 else log.vy.size()):
				rising = maxf(rising, log.vy[i])
			_expect(failures, rising <= 0.02 and log.tuck[let_go + 2] == 0.0,
					"let go in the air, the legs dropped at once (rising %.2f m/s, tuck %.3f m)" % [rising, log.tuck[let_go + 2]])
		"climb_pull_two", "climb_pull_one":
			var fastest := 0.0
			for i in range(_climb_tick(log, pull[0]), _climb_tick(log, grip[1] - 0.1)):
				fastest = maxf(fastest, log.vy[i])
			# Where the arms' pull, falling to nothing at haul_speed, meets the
			# body's weight (HandDrive._hang).
			var arms := 2.0 if result.name == "climb_pull_two" else 1.0
			var expected: float = log.haul_speed * (1.0 - log.weight / (arms * log.climb_strength))
			var slack := 0.15 if result.name == "climb_pull_two" else 0.08
			_expect(failures, absf(fastest - expected) <= slack,
					"it rose at most as fast as its arms haul (%.2f m/s, %.2f ± %.2f)" % [fastest, expected, slack])
			var settled := _climb_span(log, grip[1] - 0.3, grip[1] - 0.1)
			_expect(failures, absf((settled.x + settled.y) * 0.5 - ground - pull[2]) <= 0.02,
					"then caught up with the hands (%.3f m of %.2f)" % [(settled.x + settled.y) * 0.5 - ground, pull[2]])
		"climb_hang_one_reach":
			var reach: Array = scenario.reach_left
			var span := _climb_span(log, reach[0] + 0.1, reach[1])
			_expect(failures, span.y - span.x <= 0.02, "one arm held the body still (%.4f m)" % (span.y - span.x))
			_expect(failures, let_go < 0 or log.t[let_go] >= grip[1], "the right hand held on throughout")
		"climb_throw":
			# From the first tick flying free: the one after both hands let go
			# (the snapshot is taken before the tick's step).
			var release := maxi(_climb_first(log, "left", HandGrab.State.IDLE, grip_tick + 1), let_go)
			if not _expect(failures, release >= 0, "both hands let go"):
				return
			release = mini(release + 1, log.vy.size() - 1)
			var speed: float = log.vy[release]
			var peak := -INF
			for i in range(release, log.y.size()):
				peak = maxf(peak, log.y[i])
			_expect(failures, speed >= 1.0, "it left the hold rising (%.2f m/s >= 1)" % speed)
			var rise: float = peak - log.y[release]
			_expect(failures, rise >= 0.9 * speed * speed / (2.0 * 9.8),
					"and flew on with that speed (rose %.3f m more, %.3f expected)" % [rise, speed * speed / (2.0 * 9.8)])
		"climb_tracking_loss":
			var lost: Array = scenario.untrack
			var tracking_loss: float = log.tracking_loss
			var span := _climb_span(log, lost[0], lost[0] + tracking_loss - 0.05)
			_expect(failures, span.y - span.x <= 0.01, "untracked, the body stayed held (%.4f m)" % (span.y - span.x))
			# Within 4 ticks: the rig's loss reaches the grab a few ticks late.
			_expect(failures, let_go >= 0 and absf(log.t[let_go] - lost[0] - tracking_loss) <= 0.06,
					"then the hands let go after %.1f s (%.3f s)" % [tracking_loss, log.t[let_go] - lost[0] if let_go >= 0 else -1.0])
		"climb_grab_moving":
			# Held on while the hand moved on up (the body on the floor: the arm
			# does not push it down), then lifted by the pull by what is left.
			var sweep: Array = scenario.sweep
			var at_grip: float = lerpf(sweep[2], sweep[3], (grip[0] - sweep[0]) / (sweep[1] - sweep[0]))
			var expected: float = pull[2] - (sweep[3] - at_grip)
			_expect(failures, let_go >= 0 and absf(log.t[let_go] - grip[1]) <= 0.1,
					"the hand held on until the grip opened")
			var hang := _climb_span(log, pull[1] + 0.3, grip[1] - 0.1)
			_expect(failures, absf((hang.x + hang.y) * 0.5 - ground - expected) <= 0.02,
					"the body rose as far as the hands came down past the grip (%.3f m of %.3f)" % [(hang.x + hang.y) * 0.5 - ground, expected])
		"climb_lower_fast":
			var raise: Array = scenario.raise
			var from := _climb_tick(log, raise[0])
			var until := _climb_tick(log, grip[1] - 0.1)
			var fastest := 0.0
			var pushed := 0.0
			var lowest := INF
			for i in range(from, until):
				fastest = minf(fastest, log.vy[i])
				lowest = minf(lowest, log.y[i])
				if i > 0 and log.right[i - 1] == HandGrab.State.HOLDING:
					pushed = minf(pushed, (log.vy[i] - log.vy[i - 1]) / (log.t[i] - log.t[i - 1]))
			var speed: float = log.lowering_speed
			var target: float = ground + pull[2] - raise[2]
			_expect(failures, -fastest <= speed + 0.05,
					"it sank at most at lowering_speed (%.2f m/s, %.1f)" % [-fastest, speed])
			_expect(failures, pushed >= -9.8 - 0.3, "no faster than it falls (%.1f m/s²)" % pushed)
			_expect(failures, target - lowest <= 0.35,
					"one arm stopped it within 0.35 m past the hand (%.3f m)" % (target - lowest))
			var settled: float = log.y[until]
			_expect(failures, absf(settled - target) <= 0.01,
					"and hauled it back to the hand (%.3f m off)" % (settled - target))
		"climb_walk_away":
			var moved_holding := false
			var gripped: float = log.along[grip_tick]
			var away := 0.0
			var lead := 0.0
			for i in log.t.size():
				if log.right[i] != HandGrab.State.HOLDING:
					continue
				moved_holding = moved_holding or (i > 0 and log.relocations[i] != log.relocations[i - 1])
				away = minf(away, log.along[i] - gripped)
				lead = maxf(lead, log.lead[i])
			_expect(failures, not moved_holding, "no recentre while the hand held the hold")
			_expect(failures, away >= -0.03, "the hold kept the body from following the head (%.3f m back)" % -away)
			_expect(failures, lead <= 0.36, "the view was held within the lean limit (%.3f m)" % lead)
			_expect(failures, let_go >= 0 and absf(log.t[let_go] - grip[1]) <= 0.1, "the hand held on until the grip opened")
			var released: float = log.along[_climb_tick(log, grip[1])]
			var final: float = log.along[log.along.size() - 1]
			_expect(failures, released - final >= 0.2 and log.lead[log.lead.size() - 1] <= 0.1,
					"let go, the body went back under the head (%.3f m, lead %.3f m)" % [released - final, log.lead[log.lead.size() - 1]])


## A mantle's checks (climbing, step 2): the legs drawn up by `carried` (s),
## let go (or the hands lifted) at `released`, and the body then standing on
## the top named "top" with its legs down, having stood up no faster than
## LegTuck's stand_speed.
func _accept_mantle(result: Dictionary, failures: Array[String], carried: float, released: float) -> void:
	var log: Dictionary = result.get("climb", {})
	if not _expect(failures, not log.is_empty() and log.has("top"), "the mantle was recorded"):
		return
	var drawn: float = log.tuck[_climb_tick(log, carried)]
	_expect(failures, drawn >= 0.6, "carried by the arms, the legs were drawn up (%.3f m)" % drawn)
	_expect(failures, _tuck_flickers(log) == 0,
			"the legs never drew up for only a tick or two (%d times)" % _tuck_flickers(log))
	var rising := -INF
	for i in range(_climb_tick(log, released), log.vy.size()):
		rising = maxf(rising, log.vy[i])
	var speed: float = log.stand_speed
	_expect(failures, rising <= speed * 1.1, "stood up no faster than %.1f m/s, within 10 %% (%.2f)" % [speed, rising])
	var end: int = log.y.size() - 1
	_expect(failures, absf(log.y[end] - log.top) <= 0.02 and log.supported[end] == 1,
			"and stands on the top (%.3f m off it)" % (log.y[end] - log.top))
	_expect(failures, log.tuck[end] == 0.0, "with its legs down (%.3f m)" % log.tuck[end])


## Mantling the table by pressing (climbing, step 2): at the vault's height
## (head 1.45 m), both palms come down on the tabletop by 1.5 s and press on
## 0.5 m into it in the room by 2.5 s, lifting the body; the head leans 0.45 m
## on over the table by 3.5 s while the palms stay where they press; they lift
## off from 4.5 s, and the body stands up on the table. Every tick is recorded
## (_track_climb).
func _drive_mantle_table(t: float) -> bool:
	var scenario := _scenarios[_index]
	var facing: Vector3 = scenario.facing
	var lean := 0.45 * smoothstep(2.5, 3.5, t)
	var ahead := (_player.rig.global_basis.inverse() * facing).normalized()
	_rig.head_position = Vector3(0.0, 1.45, 0.0) + ahead * lean
	var down := _palm_rest() + lerpf(0.055, -0.275, clampf((t - 0.5) / 1.0, 0.0, 1.0)) \
			- lerpf(0.0, 0.225, clampf((t - 1.5) / 1.0, 0.0, 1.0)) \
			+ lerpf(0.0, 0.8, clampf((t - 4.5) / 0.5, 0.0, 1.0))
	_place_palm(true, Vector3(-0.225, down, -0.32 + lean))
	_place_palm(false, Vector3(0.225, down, -0.32 + lean))
	_track_climb(t)
	return false


## Pushes the right stick sideways for each [time, direction, held for] in
## `snaps`, and leaves it centred otherwise.
func _drive_snaps(t: float, snaps: Array) -> void:
	_rig.right_stick = Vector2.ZERO
	for snap: Array in snaps:
		if t >= snap[0] and t < snap[0] + snap[2]:
			_rig.right_stick = Vector2(snap[1], 0.0)


## Walks at full stick from 0.5 s to 2.5 s.
func _drive_turn_walk(t: float) -> bool:
	_rig.stick = Vector2(0.0, 1.0) if t >= 0.5 and t < 2.5 else Vector2.ZERO
	return false


## Holds both hands out in front at chest height by 1 s.
func _drive_turn_reach(t: float) -> bool:
	var reach := smoothstep(0.3, 1.0, t)
	_place_palm(true, Vector3(-0.2, 1.0, -0.2).lerp(Vector3(-0.15, 1.3, -0.45), reach))
	_place_palm(false, Vector3(0.2, 1.0, -0.2).lerp(Vector3(0.15, 1.3, -0.45), reach))
	return false


## Every tick of a snap-turn scenario: the turns so far; the eyes, the head's
## centre and the view's yaw; the body; each hand and its separation from its target; what
## each hand holds, relative to the hand, and how fast it moves; and the
## static skeleton's feet's yaw.
func _track_turn(t: float) -> void:
	var physical := _player.physical as DynamicPhysical
	var skeleton := _player.rig.skeleton
	var log: Dictionary = _scenario_state.get("turn", {"t": [], "turns": [], "eyes": [], "centre": [], "yaw": [], "body": [],
			"separation": [], "held": [], "held_speed": [], "feet_yaw": [], "on_hold": [], "recoveries": [],
			"climb_offset": []})
	log.t.append(t)
	log.turns.append(_state.turns)
	log.eyes.append(_player.rig.head.global_position)
	log.centre.append(_player.rig.head_centre())
	log.yaw.append(_yaw_of(_player.rig.head.global_basis))
	log.body.append(_state.body_position)
	var separation := []
	var held := []
	var speed := []
	var on_hold := 0
	var recoveries := 0
	for side in 2:
		var drive: HandDrive = physical.left_drive if side == 0 else physical.right_drive
		var grab: HandGrab = physical.left_grab if side == 0 else physical.right_grab
		separation.append(drive.separation)
		recoveries += drive.recoveries
		var object := grab.target as RigidBody3D if grab.state == HandGrab.State.HOLDING else null
		held.append(drive.hand.global_transform.affine_inverse() * object.global_transform if object != null else null)
		speed.append(object.linear_velocity.length() if object != null else 0.0)
		on_hold += int(grab.climbing()) << side
	log.separation.append(separation)
	log.held.append(held)
	log.held_speed.append(speed)
	log.on_hold.append(on_hold)
	log.recoveries.append(recoveries)
	var climb := 0.0
	for drive: HandDrive in [physical.left_drive, physical.right_drive]:
		if drive.climbing:
			climb = maxf(climb, drive.climb_offset.length())
	log.climb_offset.append(climb)
	log.feet_yaw.append([_yaw_of(skeleton.left_foot_tracker.global_basis), _yaw_of(skeleton.right_foot_tracker.global_basis)])
	_scenario_state.turn = log


## Which way `basis` faces over the ground, in radians about up from -Z.
static func _yaw_of(basis: Basis) -> float:
	var forward := -basis.z
	return atan2(-forward.x, -forward.z)


## Snap turning's checks (_track_turn), around each turn: the view turned by
## the snap angle in one tick about the head's centre, the feet with it; the
## body did not jump; standing, nothing pushed the view after, a hand on its
## target stayed on it, and what a hand held stayed where it was in the hand,
## moving no faster than before; hanging from holds, the body slid round them
## until the player's hands were back on them, the hands still holding.
func _accept_turn(result: Dictionary, failures: Array[String]) -> void:
	var log: Dictionary = result.get("turn", {})
	var scenario := _scenario_named(result.name)
	if not _expect(failures, not log.is_empty(), "turning was recorded"):
		return
	var snaps: Array = scenario.snaps
	var ticks := []
	for i in range(1, log.turns.size()):
		if log.turns[i] != log.turns[i - 1]:
			ticks.append(i)
	_expect(failures, ticks.size() == snaps.size(), "one turn per push (%d of %d)" % [ticks.size(), snaps.size()])
	var angle := deg_to_rad(45.0)
	var worst_turn := 0.0
	var worst_eyes := 0.0
	var worst_feet := 0.0
	var worst_body := 0.0
	var worst_separation := 0.0
	var worst_shift := 0.0
	var worst_tilt := 0.0
	var worst_speed := 0.0
	var worst_push := 0.0
	var worst_slide := 0.0
	var worst_slide_speed := 0.0
	var worst_back_on := 0.0
	for n in ticks.size():
		var k: int = ticks[n]
		var direction: float = snaps[mini(n, snaps.size() - 1)][1]
		var turned := angle_difference(log.yaw[k - 1], log.yaw[k])
		var rotation := Basis(Vector3.UP, turned)
		worst_turn = maxf(worst_turn, absf(turned + direction * angle))
		# The head's centre goes on as it was going, turned after: still, it
		# stays still. (The turn's own tick still holds the step before it.)
		# (Hanging from holds the body starts round them at once: the tick
		# after is the slide's.)
		var climbing: bool = log.on_hold[k - 1] != 0
		var was_moving: Vector3 = log.centre[k - 1] - log.centre[k - 2]
		worst_eyes = maxf(worst_eyes, ((log.centre[k] - log.centre[k - 1]) - was_moving).length())
		if not climbing:
			worst_eyes = maxf(worst_eyes, ((log.centre[k + 1] - log.centre[k]) - rotation * was_moving).length())
		for side in 2:
			worst_feet = maxf(worst_feet, absf(angle_difference(log.feet_yaw[k - 1][side], log.feet_yaw[k][side]) - turned))
		var after := mini(k + 36, log.t.size() - 1)
		if n + 1 < ticks.size():
			after = mini(after, ticks[n + 1] - 1)
		# The body does not jump: it goes on as it was, turned after.
		var body_was: Vector3 = log.body[k - 1] - log.body[k - 2]
		worst_body = maxf(worst_body, ((log.body[k] - log.body[k - 1]) - body_was).length())
		if not climbing:
			worst_body = maxf(worst_body, ((log.body[k + 1] - log.body[k]) - rotation * body_was).length())
		# Hanging from holds, the climb moves the body round them until the
		# player's hands are back on them (as a real turn does), carrying the
		# view and what the other hand holds with it.
		if climbing:
			var slide: Vector3 = log.body[after] - log.body[k - 1]
			worst_slide = maxf(worst_slide, slide.length())
			for i in range(k + 1, after):
				var speed: float = (log.body[i] - log.body[i - 1]).length() / (log.t[i] - log.t[i - 1])
				worst_slide_speed = maxf(worst_slide_speed, speed)
			# The climb's offset, the mean of the climbing hands': with two
			# hands their pair is turned and each stays a few cm off its own.
			worst_back_on = maxf(worst_back_on, log.climb_offset[after])
			_expect(failures, log.on_hold[after] == log.on_hold[k - 1], "the hands stayed on their holds through turn %d" % (n + 1))
			continue
		# Standing, nothing pushes the view after the turn.
		if not scenario.get("walking", false):
			for i in range(k + 1, after):
				worst_push = maxf(worst_push, (log.centre[i] - log.centre[i - 1]).length())
		for side in 2:
			for i in range(k, after):
				worst_separation = maxf(worst_separation, log.separation[i][side] - log.separation[k - 1][side])
			var before = log.held[k - 1][side]
			if before == null:
				continue
			var speed_before := 0.0
			for i in range(maxi(k - 36, 0), k):
				speed_before = maxf(speed_before, log.held_speed[i][side])
			for i in range(k, after):
				var now = log.held[i][side]
				if now == null:
					continue
				var shift := ((now as Transform3D).origin - (before as Transform3D).origin).length()
				var tilt := ((before as Transform3D).basis.inverse() * (now as Transform3D).basis).get_rotation_quaternion().get_angle()
				worst_shift = maxf(worst_shift, shift)
				worst_tilt = maxf(worst_tilt, tilt)
				worst_speed = maxf(worst_speed, log.held_speed[i][side] - speed_before)
	_expect(failures, worst_turn <= deg_to_rad(0.5), "each turn was 45° in one tick (%.2f° off)" % rad_to_deg(worst_turn))
	_expect(failures, worst_eyes <= 0.002, "about the head's centre, which went on as it was (%.4f m)" % worst_eyes)
	_expect(failures, worst_feet <= deg_to_rad(2.0), "the feet turned with the view (%.2f° off)" % rad_to_deg(worst_feet))
	_expect(failures, worst_body <= 0.002, "the body did not jump (%.4f m)" % worst_body)
	_expect(failures, worst_push <= 0.002, "nothing pushed the view after (%.4f m a tick)" % worst_push)
	_expect(failures, worst_separation <= 0.01, "a hand stayed on its target (%.3f m further off)" % worst_separation)
	_expect(failures, worst_shift <= 0.01 and worst_tilt <= deg_to_rad(2.0),
			"what it held stayed in the hand (%.3f m, %.2f°)" % [worst_shift, rad_to_deg(worst_tilt)])
	_expect(failures, worst_speed <= 0.3, "and moved no faster than before (%.2f m/s more)" % worst_speed)
	_expect(failures, worst_back_on <= 0.03,
			"hanging, the body went round the holds until the hands were back on them within 0.5 s (climb %.3f m off)" % worst_back_on)
	_expect(failures, worst_slide <= 0.35 and worst_slide_speed <= 2.5,
			"sliding at most 0.35 m, at most 2.5 m/s (%.3f m, %.2f m/s)" % [worst_slide, worst_slide_speed])
	_expect(failures, log.recoveries[log.recoveries.size() - 1] == log.recoveries[0], "no hand recovery")
	if result.name == "turn_snap_stand":
		var net := angle_difference(log.yaw[0], log.yaw[log.yaw.size() - 1])
		_expect(failures, absf(net) <= deg_to_rad(0.5), "back to its first facing (%.2f°)" % rad_to_deg(net))
	if result.name == "turn_snap_walk" and not ticks.is_empty():
		# Walking on the way the view now faces, from the turn's tick on.
		var worst_heading := 0.0
		for i in range(ticks[0] + 1, mini(ticks[0] + 18, log.t.size())):
			var step: Vector3 = log.eyes[i] - log.eyes[i - 1]
			var heading := atan2(-step.x, -step.z)
			worst_heading = maxf(worst_heading, absf(angle_difference(log.yaw[i], heading)))
		_expect(failures, worst_heading <= deg_to_rad(2.0),
				"the walk went on the way the view faces (%.2f° off)" % rad_to_deg(worst_heading))


## Throwing (2026-09-30): grips the scenario's box as _drive_grab_lift_box
## does (gripped at 1.5 s, lifted 0.2 m by 2.5 s), winds the hand up behind the
## right shoulder by 3.2 s, then swings it overhand on a 0.55 m arc about the
## shoulder, 150° from up and back to forward and down, starting at "throw"
## [start, duration, release]: the speed rises and falls as a sine (at most
## 5.7 m/s for 0.4 s), and the grip opens at the share "release" of the swing.
## Every tick is recorded (_track_throw).
func _drive_throw(t: float) -> bool:
	var scenario := _scenarios[_index]
	var box := _level.get_node("Dynamic/" + String(scenario.box)) as RigidBody3D
	var throw: Array = scenario.throw
	var reach := clampf((t - 0.5) / 0.7, 0.0, 1.0)
	var lift := 0.2 * smoothstep(2.0, 2.5, t)
	var above := 1.10 + _palm_half_thickness() + 0.04
	var palm := Vector3(0.0, lerpf(above + 0.1, above, reach) + lift, lerpf(-0.2, -0.33, reach))
	var shoulder := Vector3(0.2, 1.45, 0.0)
	var share := clampf((t - throw[0]) / throw[1], 0.0, 1.0)
	# The swing's progress, its speed a sine over the throw.
	var along := (share - sin(TAU * share) / TAU)
	var angle := deg_to_rad(lerpf(120.0, -30.0, along))
	var arc := shoulder + 0.55 * Vector3(0.0, sin(angle), -cos(angle))
	palm = palm.lerp(arc, smoothstep(2.6, 3.2, t))
	_place_palm(false, palm)
	_rig.right_grip = 1.0 if t >= 1.5 and share < throw[2] else 0.0
	_track_throw(box, t)
	return false


## A weapon thrown with a wrist flick: gripped as _drive_grab_weapon grips it
## (at 1.5 s, lifted 0.2 m by 3.0 s), wound up behind the shoulder by 3.6 s and
## swung on _drive_throw's arc from "throw" [start, duration, release], the
## wrist turning about the hand's right from "flick" [from, to] degrees between
## the shares [start, end] of the swing, the turn's speed a sine.
func _drive_flick(t: float) -> bool:
	var scenario := _scenarios[_index]
	var weapon := _level.get_node(scenario.weapon as NodePath) as RigidBody3D
	var grip := weapon.get_node("Grip") as CollisionShape3D
	var size := (grip.shape as BoxShape3D).size
	if not _scenario_state.has("handle"):
		var top := (grip.global_transform * AABB(-size * 0.5, size)).end.y
		_scenario_state.handle = Vector3(grip.global_position.x, top, grip.global_position.z)
	var handle: Vector3 = _scenario_state.handle
	var start: Vector3 = scenario.start
	var reach := clampf((t - 0.5) / 0.7, 0.0, 1.0)
	var lift := 0.2 * smoothstep(2.0, 3.0, t)
	var above := handle.y + _palm_half_thickness() + 0.04
	var ahead := handle.x - start.x
	var palm := Vector3(handle.z - start.z, lerpf(above + 0.1, above, reach) + lift, -lerpf(ahead - 0.13, ahead, reach))
	var throw: Array = scenario.throw
	var flick: Array = scenario.flick
	var share := clampf((t - throw[0]) / throw[1], 0.0, 1.0)
	var along := (share - sin(TAU * share) / TAU)
	var angle := deg_to_rad(lerpf(120.0, -30.0, along))
	var arc := Vector3(0.2, 1.45, 0.0) + 0.55 * Vector3(0.0, sin(angle), -cos(angle))
	palm = palm.lerp(arc, smoothstep(3.1, 3.6, t))
	var wrist := clampf((share - flick[2]) / (flick[3] - flick[2]), 0.0, 1.0)
	var bend := lerpf(flick[0], flick[1], wrist - sin(TAU * wrist) / TAU) * smoothstep(3.1, 3.6, t)
	_rig.right_hand_turn = Basis(Vector3.RIGHT, deg_to_rad(bend)) * _palm_turn(false, PALMS_DOWN[0], PALMS_DOWN[1])
	_place_palm(false, palm)
	_rig.right_grip = 1.0 if t >= 1.5 and share < throw[2] else 0.0
	_track_throw(weapon, t)
	return false


## A throw's checks (_track_throw): the prop leaves the way the player's hand
## was going at the release, within 3°, and about as fast, within 20 % (a
## light box lags the hand speeding up, and runs on past it slowing down).
func _accept_throw(result: Dictionary, failures: Array[String]) -> void:
	var log: Dictionary = result.get("throw", {})
	if not _expect(failures, not log.is_empty(), "the throw was recorded"):
		return
	var release := -1
	for i in range(1, log.t.size()):
		if log.state[i - 1] == HandGrab.State.HOLDING and log.state[i] == HandGrab.State.IDLE:
			release = i
			break
	if not _expect(failures, release > 0, "the box was let go"):
		return
	var hand: Vector3 = (log.player_hand[release] - log.player_hand[release - 1]) / (log.t[release] - log.t[release - 1])
	var thrown: Vector3 = log.velocity[release]
	var off := rad_to_deg(hand.angle_to(thrown))
	_expect(failures, off <= 3.0, "the box left the way the hand was going (%.1f° off)" % off)
	var ratio := thrown.length() / hand.length()
	_expect(failures, ratio >= 0.8 and ratio <= 1.2,
			"and about as fast (%.2f m/s against the hand's %.2f)" % [thrown.length(), hand.length()])


## Every tick of a throw: the time, the right grab's state, the box's place,
## velocity and spin, the player's hand (the static skeleton's) and the
## physical hand.
func _track_throw(box: RigidBody3D, t: float) -> void:
	var physical := _player.physical as DynamicPhysical
	var log: Dictionary = _scenario_state.get("throw", {"t": [], "state": [], "box": [], "velocity": [],
			"spin": [], "player_hand": [], "hand": []})
	log.t.append(t)
	log.state.append(physical.right_grab.state)
	log.box.append(box.global_position)
	log.velocity.append(box.linear_velocity)
	log.spin.append(box.angular_velocity)
	log.player_hand.append(physical.right_drive.static_hand().origin)
	log.hand.append(physical.right_drive.hand.global_position)
	_scenario_state.throw = log


## How far a "push" [start, speed, distance] has moved the hands at `t`: at a
## steady speed (m/s) from its start (s), until it has gone the distance (m).
static func _pushed(t: float, push: Array) -> float:
	return clampf((t - push[0]) * push[1], 0.0, push[2])


## A right-hand punch or press (the strike scenarios): "punch" [start, speed,
## from, to, height, fist]. The palm waits `from` ahead of the head (head-frame
## z, negative ahead) at `height`, its centre 0.2 m right, then moves straight
## ahead at `speed` (m/s) from `start` (s) to `to`, and stays there pressing.
## A fist squeezes the grip and trigger from the start, so the fingers curl and
## the knuckles lead; the palm faces as the scenario's "palms" turn it.
func _drive_punch(t: float) -> bool:
	var punch: Array = _scenarios[_index].punch
	var fist: bool = punch[5]
	_rig.right_grip = 1.0 if fist else 0.0
	_rig.right_trigger = 1.0 if fist else 0.0
	var travelled := clampf((t - punch[0]) * punch[1], 0.0, absf(punch[3] - punch[2]))
	_place_palm(false, Vector3(0.2, punch[4], punch[2] - travelled))
	return false


## The scenario's weapon gripped and lifted as _drive_grab_weapon does (the
## grip closes at 1.5 s, the hand lifts 0.2 m by 3 s), then the hand pushed by
## "push" [start, speed, distance] (_pushed) along "push_toward" (head frame;
## ahead if absent) and held there; the grip stays closed to the end. "roll"
## [from, to, degrees] turns the controller about the head's X axis meanwhile,
## from palms down (along a blade lying across the player, a quarter turn
## faces its flat ahead).
func _drive_weapon_push(t: float) -> bool:
	var scenario := _scenarios[_index]
	var weapon := _level.get_node(scenario.weapon as NodePath) as RigidBody3D
	var grip := weapon.get_node("Grip") as CollisionShape3D
	var size := (grip.shape as BoxShape3D).size
	if not _scenario_state.has("handle"):
		var top := (grip.global_transform * AABB(-size * 0.5, size)).end.y
		_scenario_state.handle = Vector3(grip.global_position.x, top, grip.global_position.z)
	var handle: Vector3 = _scenario_state.handle
	var start: Vector3 = scenario.start
	var reach := clampf((t - 0.5) / 0.7, 0.0, 1.0)
	var lift := 0.2 * smoothstep(2.0, 3.0, t)
	var above := handle.y + _palm_half_thickness() + 0.04
	# Facing +X, the head's forward (-Z) is the level's +X and its right the level's +Z.
	var ahead := handle.x - start.x
	var pushed := (scenario.get("push_toward", Vector3.FORWARD) as Vector3) * _pushed(t, scenario.push)
	if scenario.has("roll"):
		var roll: Array = scenario.roll
		_rig.right_hand_turn = Basis(Vector3.RIGHT, deg_to_rad(roll[2]) * smoothstep(roll[0], roll[1], t)) \
				* _palm_turn(false, PALMS_DOWN[0], PALMS_DOWN[1])
	_place_palm(false, Vector3(handle.z - start.z, lerpf(above + 0.1, above, reach) + lift,
			-lerpf(ahead - 0.13, ahead, reach)) + pushed)
	_rig.right_grip = 1.0 if t >= 1.5 else 0.0
	return false


## A box with a Striker ("Box", 0.1 m, "box_launch" [position, velocity, mass])
## put into the level at the first tick and let go with that velocity; its
## velocity is logged every tick for the strike checks (box_log).
func _drive_box_launch(t: float) -> bool:
	var launch: Array = _scenarios[_index].box_launch
	if not _scenario_state.has("box"):
		var box := _spawn_prop(Vector3(0.1, 0.1, 0.1), launch[2], launch[0])
		box.name = "Box"
		box.max_contacts_reported = 4
		box.add_child(Striker.new())
		box.linear_velocity = launch[1]
		_scenario_state.box = box
	var box: RigidBody3D = _scenario_state.box
	var log: Array = _scenario_state.get("box_log", [])
	log.append([t, box.linear_velocity.x, box.linear_velocity.y, box.linear_velocity.z])
	_scenario_state.box_log = log
	return false


## The right palm comes flat over the middle of the scenario's ore (where it
## lies by 1.2 s), 4 cm above it by 1.2 s, presses "press" (m) into its top by
## 1.4 s, grips at 1.5 s and lifts 0.2 m by 3 s. Records how far from the ore's
## centre the grab took hold ("grip_from_centre") and how near the hand's grab
## point came to that centre while it held ("hand_from_centre").
func _drive_grab_ore(t: float) -> bool:
	var scenario := _scenarios[_index]
	var ore := _level.get_node(scenario.weapon as NodePath) as RigidBody3D
	if t < 1.2 or not _scenario_state.has("ore_top"):
		var shape := ore.get_node(^"Shape") as CollisionShape3D
		var box := shape.global_transform * shape.shape.get_debug_mesh().get_aabb()
		_scenario_state.ore_top = Vector3(ore.global_position.x, box.end.y, ore.global_position.z)
	var top: Vector3 = _scenario_state.ore_top
	var start: Vector3 = scenario.start
	var reach := clampf((t - 0.5) / 0.7, 0.0, 1.0)
	var above := top.y + _palm_half_thickness() + 0.04
	var height := lerpf(above + 0.1, above, reach) - (0.04 + (scenario.press as float)) * smoothstep(1.2, 1.4, t) \
			+ 0.2 * smoothstep(2.0, 3.0, t)
	# Facing +X, the head's forward (-Z) is the level's +X and its right the level's +Z.
	_place_palm(false, Vector3(top.z - start.z, height, -(top.x - start.x)))
	_rig.right_grip = 1.0 if t >= 1.5 else 0.0
	_track_grab(ore, t)
	var hand_grab := (_player.physical as DynamicPhysical).right_grab
	if hand_grab.state != HandGrab.State.IDLE and not _scenario_state.has("grip_from_centre"):
		_scenario_state.grip_from_centre = hand_grab.object_point.distance_to(ore.global_position)
	if hand_grab.state == HandGrab.State.HOLDING:
		_scenario_state.hand_from_centre = minf(_scenario_state.get("hand_from_centre", INF),
				hand_grab.hand_point.distance_to(ore.global_position))
	return false


## As _drive_grab_ore, the right hand lifting the ore; then from 3 s the left
## hand's grab point is brought by 3.6 s to where the ore's centre was at 3 s,
## as a player's hand reaching into it (the physical hand meets the held ore,
## 2026-10-03, so a target following the ore would chase it away), and the
## left grips at 3.8 s. Records how far from the ore's centre the left took hold
## ("left_grip_from_centre") and how near the left's grab point came to that
## centre once both held it, from 4.3 s ("left_hand_from_centre").
func _drive_grab_ore_join(t: float) -> bool:
	_drive_grab_ore(t)
	var scenario := _scenarios[_index]
	var ore := _level.get_node(scenario.weapon as NodePath) as RigidBody3D
	var physical := _player.physical as DynamicPhysical
	var left := physical.left_grab
	if t >= 3.0:
		if not _scenario_state.has("left_from"):
			_scenario_state.left_from = _palm_of(true)
			# The left palm's centre where its grab point would be at the ore's
			# centre: the grab point's offset from the palm's centre, as it is now.
			var offset := left.hand_point - physical.left_drive.hand.global_position
			_scenario_state.left_into = _head_frame().affine_inverse() * (ore.global_position - offset)
		_place_palm(true, (_scenario_state.left_from as Vector3).lerp(_scenario_state.left_into,
				smoothstep(3.0, 3.6, t)))
	_rig.left_grip = 1.0 if t >= 3.8 else 0.0
	if left.state != HandGrab.State.IDLE and not _scenario_state.has("left_grip_from_centre"):
		_scenario_state.left_grip_from_centre = left.object_point.distance_to(ore.global_position)
	if t >= 4.3 and left.state == HandGrab.State.HOLDING:
		_scenario_state.left_hand_from_centre = minf(_scenario_state.get("left_hand_from_centre", INF),
				left.hand_point.distance_to(ore.global_position))
	return false


## A free hand against what the other holds (2026-10-03: the hands meet held
## objects, all but the hands holding them). The right hand grips the sword
## where it lies and lifts it 0.2 m, as _drive_weapon_push does (the grip
## closes at 1.5 s, lifted by 3 s), and holds it there to the end. The open
## left hand waits at the body's side until 3.2 s, when the blade's pose places
## what follows. By the scenario's "contact":
## - ["press", depth]: the left palm comes over the blade's middle, 4 cm above
##   it by 3.85 s, presses `depth` (m) down into it from 3.9 to 4.2 s, holds,
##   and lifts back off from 5.4 to 5.7 s;
## - ["under", rise]: the left hand comes 20 cm nearer the player than the
##   blade's middle and 4 cm below it by 3.8 s, in under it by 4.3 s, and
##   rises `rise` (m) into it from 4.4 to 4.7 s, and stays;
## - ["slap", speed, distance]: the left palm, facing the blade's edge with its
##   fingers up, 25 cm nearer the player than the blade's middle at its height
##   by 3.8 s, moves away from the player at `speed` (m/s) from 4 s for
##   `distance` (m), through the blade, and stays;
## - ["strike", speed, distance]: the left palm, facing the blade's edge with
##   its fingers up, waits 20 cm nearer the player than the blade's middle at
##   its height from 3.8 s; from 4 s the sword is pushed toward the player at
##   `speed` (m/s) for `distance` (m);
## - ["clash", speed, past]: the dagger, laid at the first tick beside the
##   sword's blade (_lay_beside), is gripped and lifted by the left hand as the
##   right lifts the sword; from 4 s the sword is pushed toward the player at
##   `speed` (m/s) until its blade's edge is `past` (m) beyond the dagger's.
## Measured by _track_held_contact.
func _drive_held_contact(t: float) -> bool:
	var scenario := _scenarios[_index]
	var contact: Array = scenario.contact
	var kind: String = contact[0]
	var sword := _level.get_node(scenario.weapon as NodePath) as RigidBody3D
	var dagger := _level.get_node(^"Dynamic/Dagger") as RigidBody3D if kind == "clash" else null
	if not _scenario_state.has("handle"):
		if dagger != null:
			_lay_beside(dagger, sword)
			_scenario_state.dagger_handle = _handle_top(dagger)
		_scenario_state.handle = _handle_top(sword)
	var frame := _head_frame()
	# Toward the player, in the world.
	var toward := frame.basis.z.normalized()
	if t >= 3.2 and not _scenario_state.has("blade"):
		var blade := sword.get_node(^"Blade") as CollisionShape3D
		var size := (blade.shape as BoxShape3D).size
		var box := blade.global_transform * AABB(-size * 0.5, size)
		_scenario_state.blade = blade.global_position
		_scenario_state.blade_top = box.end.y
		_scenario_state.blade_bottom = box.position.y
		if dagger != null:
			var other := dagger.get_node(^"Blade") as Node3D
			# How far the sword's blade edge is from the dagger's, toward the player.
			_scenario_state.clash_gap = (blade.global_position - other.global_position).dot(-toward) \
					- (blade.shape as BoxShape3D).size.x
	var start: Vector3 = scenario.start
	var reach := clampf((t - 0.5) / 0.7, 0.0, 1.0)
	var lift := 0.2 * smoothstep(2.0, 3.0, t)
	var pushed := 0.0
	if kind == "strike":
		pushed = _pushed(t, [4.0, contact[1], contact[2]])
	elif kind == "clash" and _scenario_state.has("clash_gap"):
		pushed = _pushed(t, [4.0, contact[1], (_scenario_state.clash_gap as float) + (contact[2] as float)])
	_place_palm(false, _over_handle(_scenario_state.handle, start, reach, lift) + Vector3.BACK * pushed)
	_rig.right_grip = 1.0 if t >= 1.5 else 0.0
	if kind == "clash":
		_place_palm(true, _over_handle(_scenario_state.dagger_handle, start, reach, lift))
		_rig.left_grip = 1.0 if t >= 1.5 else 0.0
	else:
		_rig.left_grip = 0.0
		# Struck or slapping, the palm faces the blade's edge, fingers up.
		var faces: Array = PALMS_TO_WALL if kind in ["slap", "strike"] else PALMS_DOWN
		_rig.left_hand_turn = _palm_turn(true, faces[0], faces[1])
		var side := Vector3(-SIDE_HAND.x, SIDE_HAND.y, SIDE_HAND.z)
		var palm := side
		if _scenario_state.has("blade"):
			var middle: Vector3 = _scenario_state.blade
			var half := _palm_half_thickness()
			var top: float = _scenario_state.blade_top
			var bottom: float = _scenario_state.blade_bottom
			var at := frame.affine_inverse()
			match kind:
				"press":
					var high := at * Vector3(middle.x, top + 0.3, middle.z)
					var over := at * Vector3(middle.x, top + half + 0.04, middle.z)
					var pressed := over + Vector3.DOWN * ((0.04 + (contact[1] as float))
							* (smoothstep(3.9, 4.2, t) - smoothstep(5.4, 5.7, t)))
					palm = side.lerp(high, smoothstep(3.2, 3.6, t)) if t < 3.6 \
							else high.lerp(pressed, smoothstep(3.6, 3.85, t))
				"under":
					var low := Vector3(middle.x, bottom - half - 0.04, middle.z)
					var near := at * (low + toward * 0.2)
					var below := at * low + Vector3.UP * ((0.04 + (contact[1] as float)) * smoothstep(4.4, 4.7, t))
					palm = side.lerp(near, smoothstep(3.2, 3.8, t)) if t < 3.9 \
							else near.lerp(below, smoothstep(3.9, 4.3, t))
				"slap", "strike":
					var near := at * (middle + toward * (0.25 if kind == "slap" else 0.2))
					var moved := _pushed(t, [4.0, contact[1], contact[2]]) if kind == "slap" else 0.0
					palm = side.lerp(near, smoothstep(3.2, 3.8, t)) + Vector3.FORWARD * moved
		_place_palm(true, palm)
	_track_held_contact(t, kind, sword, dagger, toward)
	return false


## Where a palm comes over a handle lying at `handle` (its top's middle), as
## _drive_weapon_push brings the right one: 13 cm short of it and 10 cm higher
## at `reach` 0, 4 cm above it at 1; raised by `lift`.
func _over_handle(handle: Vector3, start: Vector3, reach: float, lift: float) -> Vector3:
	var above := handle.y + _palm_half_thickness() + 0.04
	var ahead := handle.x - start.x
	# Facing +X, the head's forward (-Z) is the level's +X and its right the level's +Z.
	return Vector3(handle.z - start.z, lerpf(above + 0.1, above, reach) + lift, -lerpf(ahead - 0.13, ahead, reach))


## The middle of the top of a weapon's handle (its Grip collider) as it lies.
func _handle_top(weapon: RigidBody3D) -> Vector3:
	var grip := weapon.get_node(^"Grip") as CollisionShape3D
	var size := (grip.shape as BoxShape3D).size
	var top := (grip.global_transform * AABB(-size * 0.5, size)).end.y
	return Vector3(grip.global_position.x, top, grip.global_position.z)


## Lays the dagger on the table beside the sword's blade, pointing the other
## way: its grip 7 cm beyond the sword's tip and 14.5 cm nearer the player, its
## blade alongside the sword's from there, both hands clear of the other blade.
func _lay_beside(dagger: RigidBody3D, sword: RigidBody3D) -> void:
	var toward := _head_frame().basis.z.normalized()
	var along := sword.global_basis.y.normalized()
	var blade := sword.get_node(^"Blade") as CollisionShape3D
	var tip := blade.global_position + along * (blade.shape as BoxShape3D).size.y * 0.5
	var grip := tip + along * 0.07 + toward * 0.145
	var basis := Basis(Vector3.UP, PI) * dagger.global_basis
	var origin := grip - basis * (dagger.get_node(^"Grip") as Node3D).position
	origin.y = dagger.global_position.y
	dagger.global_transform = Transform3D(basis, origin)


## Measures the contact from 3.9 s into _scenario_state.held_contact: how deep
## the free left hand (or, clashing, the sword) sank into what the other hand
## holds ("sunk"); each holding hand's worst turn and gap in the hand, and
## whether it still holds at the end; each hand's furthest from its target;
## the fastest the still-held object moved; in the "steady" window, its most
## in a tick, how far its holding hand was held off its target ("droop") and
## that hand's least borne share of the weight; and whether the left hand (or
## the sword) ended on the far side of the blade it met ("passed").
func _track_held_contact(t: float, kind: String, sword: RigidBody3D, dagger: RigidBody3D, toward: Vector3) -> void:
	var scenario := _scenarios[_index]
	var physical := _player.physical as DynamicPhysical
	var grabs: Array[HandGrab] = [physical.left_grab, physical.right_grab]
	var drives: Array[HandDrive] = [physical.left_drive, physical.right_drive]
	var held: Array[RigidBody3D] = [dagger, sword]
	var hc: Dictionary = _scenario_state.get("held_contact", {"kind": kind,
			"recorded": scenario.get("recorded", false), "sunk": 0.0, "turn": [0.0, 0.0], "gap": [0.0, 0.0],
			"held": [false, false], "separation": [0.0, 0.0], "speed": 0.0, "steady": 0.0, "droop": 0.0,
			"borne": 1.0, "passed": false})
	_scenario_state.held_contact = hc
	if t < 3.9:
		return
	var still_side := 0 if kind == "clash" else 1
	var still: RigidBody3D = held[still_side]
	var into: RigidBody3D = sword if kind == "clash" else drives[0].hand
	hc.sunk = maxf(hc.sunk, _sunk(into, Grabbable.HELD_LAYER, [into.get_rid()]))
	for side in 2:
		if held[side] != null:
			var holding := grabs[side].state == HandGrab.State.HOLDING and grabs[side].target == held[side]
			hc.held[side] = holding
			if holding:
				hc.turn[side] = maxf(hc.turn[side], grabs[side].held_turn)
				hc.gap[side] = maxf(hc.gap[side], grabs[side].gap)
		hc.separation[side] = maxf(hc.separation[side], drives[side].separation)
	hc.speed = maxf(hc.speed, still.linear_velocity.length())
	var steady: Array = scenario.steady
	if t >= steady[0] and t <= steady[1]:
		if _scenario_state.has("still_was"):
			hc.steady = maxf(hc.steady, still.global_position.distance_to(_scenario_state.still_was))
		hc.droop = maxf(hc.droop, drives[still_side].separation)
		hc.borne = minf(hc.borne, drives[still_side].borne_share())
	_scenario_state.still_was = still.global_position
	# Which side of the met blade the mover is on, toward the player.
	var blade := (sword.get_node(^"Blade") as Node3D).global_position
	var side_now := (blade - (dagger.get_node(^"Blade") as Node3D).global_position).dot(toward) if kind == "clash" \
			else (drives[0].hand.global_position - blade).dot(toward)
	if not _scenario_state.has("side_from"):
		_scenario_state.side_from = side_now
	hc.passed = signf(side_now) != signf(_scenario_state.side_from)


## How deep `body`'s shapes sink into the bodies on `mask` (but those in
## `exclude`), in metres: the deepest contact the space finds.
func _sunk(body: CollisionObject3D, mask: int, exclude: Array[RID]) -> float:
	var space := body.get_world_3d().direct_space_state
	var query := PhysicsShapeQueryParameters3D.new()
	query.collision_mask = mask
	query.exclude = exclude
	var deepest := 0.0
	for owner_id in body.get_shape_owners():
		var holder := body.shape_owner_get_owner(owner_id) as CollisionShape3D
		if holder == null or holder.shape == null or holder.disabled:
			continue
		query.shape = holder.shape
		query.transform = holder.global_transform
		var points := space.collide_shape(query, 8)
		for i in range(0, points.size() - 1, 2):
			deepest = maxf(deepest, (points[i] as Vector3).distance_to(points[i + 1]))
	return deepest


## The free hand meets what the other holds (_drive_held_contact): it does not
## sink in, the blade it met is not passed through, the holding hands keep
## their grip, unturned and unslipped, and what is held still stays still,
## its hand near its target. "recorded" scenarios are measured only.
func _accept_held_contact(result: Dictionary, failures: Array[String]) -> void:
	var hc: Dictionary = result.get("held_contact", {})
	if not _expect(failures, not hc.is_empty(), "measured the contact") or hc.recorded:
		return
	var clash: bool = hc.kind == "clash"
	_expect(failures, hc.sunk <= 0.006, "%s did not sink in (%.4f m deep at most <= 0.006)"
			% ["the sword" if clash else "the left hand", hc.sunk])
	_expect(failures, not hc.passed, "%s stayed on its side of the blade it met" % ["the sword" if clash else "the left hand"])
	for side in ([0, 1] if clash else [1]):
		var hand: String = ["left", "right"][side]
		_expect(failures, hc.held[side], "the %s hand still holds at the end" % hand)
		_expect(failures, hc.turn[side] <= 3.0, "the %s hand's object turned in it %.2f° <= 3" % [hand, hc.turn[side]])
		_expect(failures, hc.gap[side] <= 0.005, "the %s hand's grab points %.4f m apart <= 0.005" % [hand, hc.gap[side]])
	_expect(failures, hc.steady <= 0.0003, "held still: steady (%.5f m a tick <= 0.0003)" % hc.steady)
	if hc.kind != "strike":
		# Struck, the sword is what moves, and its hand is sent past the palm.
		_expect(failures, hc.speed <= (1.0 if clash else 0.5),
				"what is held still moved %.2f m/s at most <= %.1f" % [hc.speed, 1.0 if clash else 0.5])
		_expect(failures, hc.droop <= 0.02, "its hand stayed near its target (%.4f m off <= 0.02)" % hc.droop)


## Empties the watched vein's health at "break_at" (s), as a killing strike
## would, then logs its loot every tick (_log_loot).
func _drive_vein_break(t: float) -> bool:
	var scenario := _scenarios[_index]
	if t >= scenario.break_at and not _scenario_state.has("broke"):
		_scenario_state.broke = true
		var health := _level.get_node(scenario.vein as NodePath).get_node(^"Health") as Health
		health.take_damage(health.current)
	_log_loot(t)
	return false


## Opens the watched tree's line ("chop_line") as "open_sides" has it at
## "fell_at" (s), as a felling slash would, so the tree is felled with nothing
## near it. With "drop_at" (s), the scenario's weapon is then let fall from
## "drop_height" (m) over the fallen top's centre of mass, still, and its height
## logged every tick from then ("dropped", "drop_log": [time, height]). With
## "buck_line" (k), the fallen top is bucked there (_buck_top). With
## "slash_at" (s), a lone piece is then broken (_slash_lone).
func _drive_tree_fell(t: float) -> bool:
	var scenario := _scenarios[_index]
	if t >= scenario.fell_at and not _scenario_state.has("line_opened"):
		_scenario_state.line_opened = true
		var at: Vector2i = scenario.get("chop_line", Vector2i(0, 1))
		var chop := _level.get_node(scenario.tree as NodePath).get_node(^"TreeChop") as TreeChop
		chop.preset(at.x, at.y, PackedInt32Array(scenario.open_sides))
	if scenario.has("buck_line") and _scenario_state.has("fall_piece"):
		_buck_top(t, scenario)
	if scenario.has("drop_at") and t >= scenario.drop_at and _scenario_state.has("fall_piece"):
		var weapon := _level.get_node(scenario.weapon as NodePath) as RigidBody3D
		if not _scenario_state.has("dropped"):
			var top: FelledTree = _scenario_state.fall_piece
			var state := PhysicsServer3D.body_get_direct_state(top.get_rid())
			var above := top.global_position + state.center_of_mass + Vector3.UP * (scenario.drop_height as float)
			weapon.global_transform = Transform3D(Basis.IDENTITY, above)
			weapon.linear_velocity = Vector3.ZERO
			weapon.angular_velocity = Vector3.ZERO
			_scenario_state.dropped = t
		var log: Array = _scenario_state.get("drop_log", [])
		log.append([t, weapon.global_position.y])
		_scenario_state.drop_log = log
	if scenario.has("slash_at"):
		_slash_lone(t, scenario)
	return false


## Once the fallen top lies at rest from "buck_at" (s), cuts its trunk's line
## "buck_line" (k) through, every side open to its cap, as slashes would: the
## time, and the line's k, total and cap ("bucked", "buck_cut"). The part beyond
## comes off as a FelledTree of its own ("buck_piece"); the lines each piece's
## trunk carries ("buck_lines": [first k, last k] for the top, then the piece)
## and whether the line cut is gone from both ("buck_gone"). Then both pieces
## are logged every tick (_log_buck), while both are in the level.
func _buck_top(t: float, scenario: Dictionary) -> void:
	if not is_instance_valid(_scenario_state.fall_piece):
		return
	var top: FelledTree = _scenario_state.fall_piece
	if not _scenario_state.has("bucked"):
		if t < scenario.buck_at or top.linear_velocity.length() >= 0.05 or top.angular_velocity.length() >= 0.05:
			return
		_scenario_state.bucked = t
		var k: int = scenario.buck_line
		var line := top.chop.line_at(0, k)
		if line == null:
			push_error("run_scenarios: the fallen top's line %d cannot be chopped." % k)
			return
		_scenario_state.buck_cut = [k, line.total, line.cap]
		var sides := PackedInt32Array()
		sides.resize(line.depths.size())
		sides.fill(line.cap)
		top.piece.severed.connect(func(piece: FelledTree) -> void:
				_scenario_state.buck_piece = piece
				_name_piece(piece, "rest"), CONNECT_ONE_SHOT)
		top.chop.preset(0, k, sides)
		var piece: FelledTree = _scenario_state.get("buck_piece")
		if piece != null:
			var key := Vector2i(0, k)
			var top_lines := top.skeleton.line_range(0)
			var piece_lines := piece.skeleton.line_range(0)
			_scenario_state.buck_lines = [[top_lines.x, top_lines.y], [piece_lines.x, piece_lines.y]]
			_scenario_state.buck_gone = not top.chop.lines.has(key) and not piece.chop.lines.has(key)
	_log_buck(t)


## Logs both pieces of a bucked top every tick from the cut ("buck_log": [time,
## the top's speed, the piece's speed, how far apart their cut faces are along
## the trunk (+ apart) and across it, the top's centre of mass x, y, z, the
## piece's x, y, z, the top's upward speed, the piece's]). Each cut face's
## middle is where its piece's trunk ends at the cut, as it lies now.
func _log_buck(t: float) -> void:
	if not is_instance_valid(_scenario_state.fall_piece) or not is_instance_valid(_scenario_state.get("buck_piece")):
		return
	var top: FelledTree = _scenario_state.fall_piece
	var piece: FelledTree = _scenario_state.buck_piece
	var at: float = (_scenario_state.buck_cut[0] as int) * top.skeleton.segment_length
	var lower := top.piece.skeleton_transform() * top.skeleton.sample_position(0, at)
	var upper := piece.piece.skeleton_transform() * piece.skeleton.sample_position(0, at)
	var axis := (top.piece.skeleton_transform().basis * top.skeleton.sample_direction(0, at)).normalized()
	var apart := upper - lower
	var top_centre := top.global_position + PhysicsServer3D.body_get_direct_state(top.get_rid()).center_of_mass
	var piece_centre := piece.global_position + PhysicsServer3D.body_get_direct_state(piece.get_rid()).center_of_mass
	var log: Array = _scenario_state.get("buck_log", [])
	log.append([t, top.linear_velocity.length(), piece.linear_velocity.length(), apart.dot(axis),
			(apart - axis * apart.dot(axis)).length(), top_centre.x, top_centre.y, top_centre.z,
			piece_centre.x, piece_centre.y, piece_centre.z, top.linear_velocity.y, piece.linear_velocity.y])
	_scenario_state.buck_log = log


## At "cut_at" (s), cuts the watched tree's thickest limb through at its first
## line that can be chopped, or with "cut_last" its last, as slashes would
## ("line_cut": the time; "line_at": [the limb's index, k, the line's distance
## along it, its total]; "line_choppable": the limb's lines that could be
## chopped before). Then whether the tree keeps the limb up to the cut, capped
## ("stub_capped"), the lines left on that stub that are still wood
## ("stub_lines"), and whether the line is gone from the tree and from the
## piece cut off ("line_gone"). Then logs the piece every tick, while it is in
## the level ("limb_log": [time, its centre of mass x, y, z, its speed, its
## spin, whether it sleeps]). With "slash_at" (s), a lone piece is then broken
## (_slash_lone). With "set_down", the piece is laid down at once (_set_down).
func _drive_line_cut(t: float) -> bool:
	var scenario := _scenarios[_index]
	var tree := _level.get_node(scenario.tree as NodePath) as ProceduralTree
	var chop := tree.get_node(^"TreeChop") as TreeChop
	if t >= scenario.cut_at and not _scenario_state.has("line_cut"):
		_scenario_state.line_cut = t
		var skeleton := tree.skeleton
		var limb := -1
		for branch in skeleton.branch_count():
			if skeleton.branch_depth[branch] == 1 and (limb < 0
					or skeleton.branch_base_radius[branch] > skeleton.branch_base_radius[limb]):
				limb = branch
		var span := skeleton.line_range(limb)
		var choppable: Array[int] = []
		for j in range(span.x, span.y + 1):
			if chop.choppable(limb, j):
				choppable.append(j)
		_scenario_state.line_choppable = choppable
		var k := -1
		if not choppable.is_empty():
			k = choppable[-1] if scenario.get("cut_last", false) else choppable[0]
		var line := chop.line_at(limb, k)
		if line == null:
			push_error("run_scenarios: the tree's thickest limb has no line to chop.")
			return false
		var id := skeleton.branch_id[limb]
		_scenario_state.line_at = [limb, k, line.at, line.total]
		chop.preset(limb, k, PackedInt32Array([line.total]))
		var stub := tree.skeleton.branch_with_id(id)
		_scenario_state.stub_capped = stub >= 0 and tree.skeleton.branch_cut[stub] & TreeSkeleton.CUT_TIP != 0
		var stub_lines := []
		if stub >= 0:
			var left := tree.skeleton.line_range(stub)
			for j in range(left.x, left.y + 1):
				if tree.skeleton.line_is_wood(stub, j, tree.species.collision_min_radius_m):
					stub_lines.append(j)
		_scenario_state.stub_lines = stub_lines
		var cut_off: FelledTree = _scenario_state.get("severed_piece")
		_scenario_state.line_gone = not chop.lines.has(Vector2i(id, k)) and is_instance_valid(cut_off) \
				and not cut_off.chop.lines.has(Vector2i(id, k))
		if scenario.has("set_down") and is_instance_valid(cut_off):
			_set_down(cut_off, scenario.set_down)
	if is_instance_valid(_scenario_state.get("severed_piece")):
		var piece: FelledTree = _scenario_state.severed_piece
		var state := PhysicsServer3D.body_get_direct_state(piece.get_rid())
		var log: Array = _scenario_state.get("limb_log", [])
		var centre := piece.global_position + state.center_of_mass
		log.append([t, centre.x, centre.y, centre.z, piece.linear_velocity.length(), piece.angular_velocity.length(),
				piece.sleeping])
		_scenario_state.limb_log = log
	if scenario.has("slash_at"):
		_slash_lone(t, scenario)
	return false


## Lays a piece cut off the watched tree down at `at` (fall damage, 2026-10-03;
## "set_down": a point on the floor, its height the gap to leave), still: turned
## so its main branch runs level along X and the way across it that its wood's
## shapes spread least (their middles about its wood's middle, by volume) is
## up, its wood's middle over the point, its lowest point that high over the
## floor. Then how it was laid ("laid": {"lowest": its lowest point, m; "tilt":
## its main branch's angle from level, degrees; "near": what its shapes come
## within 1.9 cm of, on every layer it meets}).
func _set_down(piece: FelledTree, at: Vector3) -> void:
	var skeleton := piece.skeleton
	var first := skeleton.branch_first_node[0]
	var last := first + skeleton.branch_node_count[0] - 1
	var along := (piece.piece.skeleton_transform().basis * (skeleton.positions[last] - skeleton.positions[first])) \
			.normalized()
	var centre := piece.centre_of_mass()
	var u := along.cross(Vector3.UP).normalized()
	var v := u.cross(along)
	var uu := 0.0
	var uv := 0.0
	var vv := 0.0
	for owner_id in piece.get_shape_owners():
		if piece.is_shape_owner_disabled(owner_id):
			continue
		var offset := piece.global_transform * piece.shape_owner_get_transform(owner_id).origin - centre
		var volume := _volume(piece.shape_owner_get_shape(owner_id, 0))
		uu += volume * offset.dot(u) * offset.dot(u)
		uv += volume * offset.dot(u) * offset.dot(v)
		vv += volume * offset.dot(v) * offset.dot(v)
	# The most spread is at this angle from u, round the main branch; the least,
	# a quarter turn on.
	var angle := 0.5 * atan2(2.0 * uv, uu - vv)
	var flat := -u * sin(angle) + v * cos(angle)
	if flat.y < 0.0:
		flat = -flat
	var turn := Basis(along, flat, along.cross(flat)).inverse()
	piece.global_transform = Transform3D(turn * piece.global_basis,
			turn * (piece.global_position - centre) + Vector3(at.x, centre.y, at.z))
	piece.global_position.y += at.y - _lowest_point(piece)
	piece.linear_velocity = Vector3.ZERO
	piece.angular_velocity = Vector3.ZERO
	# It falls from where it was laid, not from where it was cut (_accept_breaks).
	for record: Dictionary in _scenario_state.get("made", []):
		if record.id == piece.get_instance_id():
			record.height = piece.centre_of_mass().y
	var laid := (piece.piece.skeleton_transform().basis * (skeleton.positions[last] - skeleton.positions[first])) \
			.normalized()
	_scenario_state.laid = {"lowest": _lowest_point(piece), "tilt": rad_to_deg(asin(clampf(absf(laid.y), 0.0, 1.0))),
			"near": _near(piece, 0.019, FelledTree.MASK)}


## A wood shape's volume, in cubic metres: a capsule's or a cylinder's; 0 for
## any other.
static func _volume(shape: Shape3D) -> float:
	if shape is CapsuleShape3D:
		var capsule := shape as CapsuleShape3D
		return PI * capsule.radius * capsule.radius * (capsule.height - 2.0 * capsule.radius) \
				+ 4.0 / 3.0 * PI * pow(capsule.radius, 3)
	if shape is CylinderShape3D:
		var cylinder := shape as CylinderShape3D
		return PI * cylinder.radius * cylinder.radius * cylinder.height
	return 0.0


## The watched tree's pieces in the level, by role: "tree", the tree itself,
## standing or a stump; "top", its felled top; "rest", what was bucked off the
## top; "cut", the first piece cut off it (the top, if it was felled); and
## broken_1, broken_2 and on, each piece an impact broke off any of them (fall
## damage, 2026-10-03), in the order they broke.
func _tree_pieces(scenario: Dictionary) -> Dictionary:
	var pieces := {}
	var tree := _level.get_node_or_null(scenario.tree as NodePath)
	if tree != null:
		pieces.tree = tree
	for role: String in TREE_PIECES:
		var piece: Variant = _scenario_state.get(TREE_PIECES[role])
		if is_instance_valid(piece):
			pieces[role] = piece
	var broken: Array = _scenario_state.get("broken", [])
	for i in broken.size():
		if is_instance_valid(broken[i]):
			pieces["broken_%d" % (i + 1)] = broken[i]
	return pieces


## A piece's TreeChop: a felled piece's, or the tree's own.
static func _chop_of(piece: Node3D) -> TreeChop:
	return (piece as FelledTree).chop if piece is FelledTree else piece.get_node(^"TreeChop") as TreeChop


## From "slash_at" (s), once every piece cut off the tree lies at rest (one an
## impact broke off, once it goes slower than CREEP_SPEED), slashes the lone
## piece the scenario breaks ("lone", a role of _tree_pieces) one tick after
## another until its health runs out: full-strength strikes (10 damage),
## scripted as the line presets are and handed to its Strikeable as a Striker
## would (no striker), on its bark at its middle on the side facing up and
## toward the player (_lone_bark). As the first lands, whether each piece is
## lone ("lone_pieces": by role); as each lands, where its body is
## ("lone_struck": [time, x, y, z]). From then on, every tick, its loot
## (_log_loot) and the piece "still" names, if it is a felled piece
## ("still_log": [time, its centre of mass x, y, z, its speed, whether it
## sleeps]); and, in the tick the lone piece goes, whether that one slept just
## before, is awake once it went and touched it as it went ("still_drop":
## {"asleep", "awake", "touched"}; _touches).
func _slash_lone(t: float, scenario: Dictionary) -> void:
	var pieces := _tree_pieces(scenario)
	if not _scenario_state.has("lone_pieces"):
		if t < scenario.slash_at:
			return
		for role: String in pieces:
			var body := pieces[role] as RigidBody3D
			if body == null:
				continue
			if role.begins_with("broken_"):
				if body.linear_velocity.length() >= CREEP_SPEED:
					return
			elif body.linear_velocity.length() >= 0.05 or body.angular_velocity.length() >= 0.05:
				return
		var lone := {}
		for role: String in pieces:
			lone[role] = _chop_of(pieces[role]).is_lone()
		_scenario_state.lone_pieces = lone
	var chop: TreeChop = _chop_of(pieces[scenario.lone]) if pieces.has(scenario.lone) else null
	var still := pieces.get(scenario.get("still", "")) as FelledTree
	# At most twice the strikes its health takes, should they not count.
	if chop != null and chop.health != null and chop.health.current > 0 \
			and _scenario_state.get("lone_struck", []).size() < 2 * ceili(chop.health.maximum / float(Strike.MAX_DAMAGE)):
		var object := chop.health.get_parent() as Node3D
		var struck: Array = _scenario_state.get("lone_struck", [])
		struck.append([t, object.global_position.x, object.global_position.y, object.global_position.z])
		_scenario_state.lone_struck = struck
		var strike := Strike.new()
		strike.kind = Strike.Kind.SLASH
		strike.target = chop.strikeable.object
		strike.point = _lone_bark(chop, scenario.start)
		strike.normal = (strike.point - chop.lone_centre()).normalized()
		strike.speed = 4.0
		strike.energy = chop.strikeable.material.full_energy_of(Strike.Kind.SLASH)
		strike.effective_mass = 2.0 * strike.energy / (strike.speed * strike.speed)
		var asleep := still != null and still.sleeping
		chop.strikeable.receive(strike)
		# Gone: it leaves the level at the end of this tick, so it still lies where
		# it was.
		if chop.health.current == 0 and still != null:
			_scenario_state.still_drop = {"asleep": asleep, "awake": not still.sleeping,
					"touched": _touches(object, still, TOUCH_GAP)}
	_log_loot(t)
	if still != null:
		var centre := still.global_position + PhysicsServer3D.body_get_direct_state(still.get_rid()).center_of_mass
		var log: Array = _scenario_state.get("still_log", [])
		log.append([t, centre.x, centre.y, centre.z, still.linear_velocity.length(), still.sleeping])
		_scenario_state.still_log = log


## Whether `body` touches `piece`, as they lie now: comes within `gap` of the
## bodies the piece collides through (its body, if it is one, and every physics
## body below it, internal ones too), each of their shapes grown by `gap`.
static func _touches(piece: Node3D, body: CollisionObject3D, gap: float) -> bool:
	var space := piece.get_world_3d().direct_space_state
	var query := PhysicsShapeQueryParameters3D.new()
	query.collision_mask = body.collision_layer
	var nodes: Array[Node] = [piece]
	while not nodes.is_empty():
		var node: Node = nodes.pop_back()
		nodes.append_array(node.get_children(true))
		var own := node as PhysicsBody3D
		if own == null or own == body:
			continue
		for owner_id in own.get_shape_owners():
			if own.is_shape_owner_disabled(owner_id):
				continue
			query.transform = own.global_transform * own.shape_owner_get_transform(owner_id)
			for i in own.shape_owner_get_shape_count(owner_id):
				query.shape = _grown(own.shape_owner_get_shape(owner_id, i), gap)
				for hit: Dictionary in space.intersect_shape(query, 32):
					if hit.rid == body.get_rid():
						return true
	return false


## A copy of `shape` grown by `gap` all round, for the shapes a tree's wood is
## built of; any other as it is.
static func _grown(shape: Shape3D, gap: float) -> Shape3D:
	var grown := shape.duplicate() as Shape3D
	if grown is CapsuleShape3D:
		(grown as CapsuleShape3D).radius += gap
		(grown as CapsuleShape3D).height += 2.0 * gap
	elif grown is CylinderShape3D:
		(grown as CylinderShape3D).radius += gap
		(grown as CylinderShape3D).height += 2.0 * gap
	elif grown is SphereShape3D:
		(grown as SphereShape3D).radius += gap
	elif grown is BoxShape3D:
		(grown as BoxShape3D).size += Vector3.ONE * 2.0 * gap
	return grown


## A point on the bark of a lone piece's main branch at its middle, in the
## world: on the side facing up and toward `toward`.
static func _lone_bark(chop: TreeChop, toward: Vector3) -> Vector3:
	var skeleton := chop.tree.skeleton
	var middle := (skeleton.distances[skeleton.branch_first_node[0]] + skeleton.branch_length(0)) * 0.5
	var axis := (chop.tree.skeleton_transform().basis * skeleton.sample_direction(0, middle)).normalized()
	var centre := chop.lone_centre()
	var facing := Vector3(toward.x - centre.x, 0.0, toward.z - centre.z).normalized() + Vector3.UP
	return centre + (facing - axis * facing.dot(axis)).normalized() * chop.lone_radius()


## At the first tick, sends a 2 kg box, its gravity off, at "crown_pass"
## [speed, distance]: from that far out from a leaf cluster growing on a limb or
## the trunk of the watched tree, level, straight through the cluster's
## middle. Logs how many leaf clusters the tree has, at the start and every tick
## ("leaves_start", "leaves_end"), how many branches broke ("branches_gone"),
## and how near the box came to the cluster's middle ("box_nearest").
func _drive_crown_pass(_t: float) -> bool:
	var scenario := _scenarios[_index]
	var tree := _level.get_node(scenario.tree as NodePath) as ProceduralTree
	var launch: Array = scenario.crown_pass
	if not _scenario_state.has("box"):
		var skeleton := tree.skeleton
		var leaf := 0
		while skeleton.branch_depth[skeleton.leaf_branch[leaf]] >= 2:
			leaf += 1
		var size := skeleton.leaf_size[leaf] * tree.skeleton_transform().basis.get_scale().x
		var out := tree.skeleton_transform().basis * skeleton.leaf_forward[leaf]
		out = Vector3(out.x, 0.0, out.z).normalized()
		var middle := tree.skeleton_transform() * skeleton.leaf_anchor(leaf) + out * size * 0.5
		var box := _spawn_prop(Vector3(0.1, 0.1, 0.1), 2.0, middle + out * (launch[1] as float))
		box.name = "Box"
		box.gravity_scale = 0.0
		box.linear_velocity = -out * (launch[0] as float)
		_scenario_state.box = box
		_scenario_state.cluster_middle = middle
		_scenario_state.leaves_start = tree.leaves_left()
	var box: RigidBody3D = _scenario_state.box
	var nearest: float = _scenario_state.get("box_nearest", INF)
	_scenario_state.box_nearest = minf(nearest, box.global_position.distance_to(_scenario_state.cluster_middle))
	_scenario_state.leaves_end = tree.leaves_left()
	_scenario_state.branches_gone = tree.gone_branches().count(1)
	return false


## Loot set rolling ("roll" {"scene", "from", "toward", "speed"}; 2026-10-02):
## at the first tick, an item of the scene, as the scene makes it, laid on its
## side as LootDrop lays one (LootDrop.lay_down: its length, its Y, level, and
## its Z down), its length across "toward" (level), at "from" on the floor, its
## lowest point on it; and set rolling toward "toward" at "speed" (m/s), turning
## about its length as fast as rolling without slipping takes with its middle
## (its origin) that high off the floor. Its mass and when it was set rolling
## ("roll_mass", "roll_at"); every tick from then, its centre of mass, speed and
## spin, how high its lowest point is and whether it sleeps ("roll_log": [time,
## x, y, z, speed, spin, lowest, sleeping]).
func _drive_loot_roll(t: float) -> bool:
	var roll: Dictionary = _scenarios[_index].roll
	if not _scenario_state.has("roll_item"):
		var item := (load(roll.scene) as PackedScene).instantiate() as RigidBody3D
		var toward := Vector3((roll.toward as Vector3).x, 0.0, (roll.toward as Vector3).z).normalized()
		var length := toward.cross(Vector3.UP)
		var from: Vector3 = roll.from
		_level.add_child(item)
		item.global_transform = Transform3D(Basis(length.cross(Vector3.DOWN), length, Vector3.DOWN), from)
		var height := from.y - _lowest_of(item)
		item.global_position.y += height
		item.linear_velocity = toward * (roll.speed as float)
		item.angular_velocity = Vector3.UP.cross(toward) * (roll.speed as float) / height
		_scenario_state.roll_item = item
		_scenario_state.roll_mass = item.mass
		_scenario_state.roll_at = t
	var item: RigidBody3D = _scenario_state.roll_item
	var centre := item.global_position + PhysicsServer3D.body_get_direct_state(item.get_rid()).center_of_mass
	var log: Array = _scenario_state.get("roll_log", [])
	log.append([t, centre.x, centre.y, centre.z, item.linear_velocity.length(), item.angular_velocity.length(),
			_lowest_of(item), item.sleeping])
	_scenario_state.roll_log = log
	return false


## The scenario's weapon, at the first tick, put at "spin" [position, angular
## velocity] (unturned: a blade points up) and let go spinning.
func _drive_spin(_t: float) -> bool:
	var scenario := _scenarios[_index]
	if not _scenario_state.has("spun"):
		_scenario_state.spun = true
		var spin: Array = scenario.spin
		var weapon := _level.get_node(scenario.weapon as NodePath) as RigidBody3D
		weapon.global_transform = Transform3D(Basis.IDENTITY, spin[0])
		weapon.linear_velocity = Vector3.ZERO
		weapon.angular_velocity = spin[1]
	return false


## The scenario's weapon swung free into the watched tree's line, as an arm
## swings an axe level at a trunk ("swing" [stance, radius, speed, roll,
## draw]): round the vertical through a pivot "stance" m out from the line's
## middle, toward "tree_face"'s toward, at the line's height; the weapon's
## origin "radius" m from the pivot, its Y (an axe's handle, to its head) out
## from it, its Z up, its -X (an axe's bit) leading round at "speed" m/s there.
## "roll" twists it about its Y and "draw" turns it about the vertical
## (degrees). It starts a little before any of it would enter the trunk (as
## wide all the way up as at the line) and is carried round at that speed until
## its first strike on the tree, then stopped there (frozen), as an arm stops
## the blow: let go, it rebounds and its handle's end swings into the trunk
## ("swing_from": the angle round the pivot it started at, from the line to the
## trunk, in radians).
func _drive_swing(_t: float) -> bool:
	var scenario := _scenarios[_index]
	var weapon := _level.get_node(scenario.weapon as NodePath) as RigidBody3D
	if _scenario_state.has("strikes"):
		weapon.freeze = true
		return false
	var swing: Array = scenario.swing
	var tree := _level.get_node(scenario.tree as NodePath) as ProceduralTree
	var chop := tree.get_node(^"TreeChop") as TreeChop
	var at: Vector2i = scenario.get("chop_line", Vector2i(0, 1))
	var line := chop.line_at(at.x, at.y)
	var toward: Vector3 = (scenario.tree_face[1] as Vector3).normalized()
	var pivot := chop.centre(line) + toward * (swing[0] as float)
	var spin: float = swing[2] / swing[1]
	if not _scenario_state.has("swing_from"):
		# Points over the weapon's boxes, in its own space.
		var points := PackedVector3Array()
		for shape: CollisionShape3D in weapon.find_children("*", "CollisionShape3D", false, false):
			if shape.shape is BoxShape3D:
				var size := (shape.shape as BoxShape3D).size
				for i in 5:
					for j in 9:
						for k in 3:
							points.append(shape.transform * (size * Vector3(i / 4.0 - 0.5, j / 8.0 - 0.5, k / 2.0 - 0.5)))
		var reach := chop.radius(line)
		var angle := 1.6
		var touches := false
		while angle > -1.6 and not touches:
			angle -= 0.004
			var pose := _swing_pose(pivot, toward, swing, angle)
			for point in points:
				var offset := pose * point - chop.centre(line)
				touches = touches or Vector2(offset.x, offset.z).length() < reach
		# At least three ticks before the touch, so the striker's pose before the
		# step that meets the trunk is the swing's.
		_scenario_state.swing_from = angle + maxf(0.3, 3.5 * spin / Engine.physics_ticks_per_second)
		weapon.global_transform = _swing_pose(pivot, toward, swing, _scenario_state.swing_from)
	var turning := Vector3.UP * spin
	weapon.angular_velocity = turning
	var centre := weapon.global_transform * PhysicsServer3D.body_get_direct_state(weapon.get_rid()).center_of_mass_local
	weapon.linear_velocity = turning.cross(centre - pivot)
	return false


## The pose of a weapon swung by "swing" [stance, radius, speed, roll, draw]
## (_drive_swing), `angle` radians round the pivot from the line to the trunk.
static func _swing_pose(pivot: Vector3, toward: Vector3, swing: Array, angle: float) -> Transform3D:
	var inward := -toward
	var across := inward.cross(Vector3.UP)
	var out := inward * cos(angle) + across * sin(angle)
	# The way round the swing goes is the weapon's -X: its angle falls.
	var behind := across * cos(angle) - inward * sin(angle)
	var basis := Basis(Vector3.UP, deg_to_rad(swing[4])) * Basis(behind, out, Vector3.UP) \
			* Basis(Vector3.UP, deg_to_rad(swing[3]))
	return Transform3D(basis, pivot + out * (swing[1] as float))


## The strike scenarios' checks (the strike model, rung 1), from their
## "expect": "count" (exact, or [least, most]) strikes on the kept posts; per
## strike its "striker", "held_by" (the hands holding it, as bits), "mass" and
## "speed" ([least, most], kg and m/s), and none after "after" (s); the hands'
## strikes in the recording: "source" (the right hand's HandStrikes.Source, 0
## for none on either hand) or "source_both" (both hands on the same tick);
## "kind" (each strike's damage type, Strike.Kind);
## "held_at_end" (the right hand still holds); "box_speed" (the closing speed
## within that share of the spawned box's velocity the tick before, gravity
## for the step added); "drop" [height, share] (the energy within that share
## of m·g·h). Every strike's damage must be its material's for its energy, and
## its energy ½ · mass · speed².
func _accept_strike(result: Dictionary, failures: Array[String]) -> void:
	var expect: Dictionary = {}
	for scenario in _scenarios:
		if scenario.name == result.name:
			expect = scenario.expect
	var strikes: Array = result.get("strikes", [])
	var count: Variant = expect.count
	var least: int = count[0] if count is Array else count
	var most: int = count[1] if count is Array else count
	_expect(failures, strikes.size() >= least and strikes.size() <= most,
			"%d strikes on the posts, expected %s" % [strikes.size(), str(count)])
	for strike: Dictionary in strikes:
		var what := "%s on %s at %.2f s (%.2f J, %.2f m/s, %.2f kg)" % [strike.striker, strike.target,
				strike.t, strike.energy, strike.speed, strike.mass]
		if expect.has("striker"):
			_expect(failures, strike.striker == expect.striker, "%s: struck by %s" % [what, expect.striker])
		if expect.has("held_by"):
			_expect(failures, int(strike.held_by) == expect.held_by,
					"%s: held by hands %d, expected %d" % [what, int(strike.held_by), expect.held_by])
		for key: String in ["mass", "speed"]:
			if expect.has(key):
				var span: Array = expect[key]
				_expect(failures, strike[key] >= span[0] and strike[key] <= span[1],
						"%s: %s within %s" % [what, key, str(span)])
		if expect.has("after"):
			_expect(failures, strike.t <= expect.after, "%s: no strike after %.2f s" % [what, expect.after])
		if expect.has("kind"):
			_expect(failures, int(strike.kind) == expect.kind, "%s: %s, expected %s (feature: %s)" % [what,
					StrikeReadout.KIND_NAMES[int(strike.kind)], StrikeReadout.KIND_NAMES[expect.kind],
					strike.feature if strike.feature != "" else "none"])
		# None below the threshold; else 1 at it to 10 at the full energy, in a
		# straight line, rounded (2026-10-02).
		var damage := 0
		if strike.energy >= strike.threshold:
			var strength: float = clampf((strike.energy - strike.threshold)
					/ (strike.full - strike.threshold), 0.0, 1.0)
			damage = roundi(lerpf(Strike.MIN_DAMAGE, Strike.MAX_DAMAGE, strength))
		_expect(failures, strike.damage == damage,
				"%s: damage %d is its material's %d" % [what, strike.damage, damage])
		if expect.has("target"):
			_expect(failures, strike.target == expect.target, "%s: struck %s" % [what, expect.target])
		var energy: float = 0.5 * strike.mass * strike.speed * strike.speed
		_expect(failures, absf(strike.energy - energy) < 1e-4 * maxf(1.0, energy),
				"%s: energy is half mass times speed squared (%.4f)" % [what, energy])
		if expect.has("box_speed"):
			var before := Vector3.ZERO
			for entry: Array in result.get("box_log", []):
				if entry[0] < strike.t - 1e-6:
					before = Vector3(entry[1], entry[2], entry[3])
			var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
			var normal := Vector3(strike.normal[0], strike.normal[1], strike.normal[2])
			var step := 1.0 / Engine.physics_ticks_per_second
			var closing := -(before + Vector3.DOWN * gravity * step).dot(normal)
			_expect(failures, absf(strike.speed - closing) <= expect.box_speed * closing,
					"%s: closing speed the box's own %.3f m/s" % [what, closing])
		if expect.has("drop"):
			var drop: Array = expect.drop
			var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
			var fallen := 2.0 * gravity * (drop[0] as float)
			_expect(failures, absf(strike.energy - fallen) <= drop[1] * fallen,
					"%s: energy within %d%% of m·g·h (%.2f J)" % [what, int(drop[1] * 100.0), fallen])
	var rows := Analysis.load_rows(result.csv)
	var logged := Analysis.strikes(rows)
	if expect.has("source"):
		var source: int = expect.source
		var right := logged.filter(func(s: Dictionary) -> bool: return s.side == 1)
		var left := logged.filter(func(s: Dictionary) -> bool: return s.side == 0)
		if source == 0:
			_expect(failures, logged.is_empty(), "no hand's strike recorded (%d)" % logged.size())
		else:
			_expect(failures, right.size() == strikes.size() and left.is_empty() \
					and right.all(func(s: Dictionary) -> bool: return s.source == source),
					"each strike recorded once, for the right hand, as source %d (%s)" % [source,
							str(logged.map(func(s: Dictionary) -> String: return "%d:%d" % [s.side, s.source]))])
	if expect.has("source_both"):
		var source: int = expect.source_both
		var times := {}
		for s in logged:
			if s.source == source:
				times[s.time] = int(times.get(s.time, 0)) | (1 << s.side)
		_expect(failures, times.values().has(3),
				"a strike recorded for both hands on the same tick, as source %d" % source)
	# Each strike by a held object buzzes each hand holding it, once; no other
	# strike buzzes (a hand's own touch buzzes on its own, HandHaptics).
	var pulses: Array = result.get("strike_pulses", [0, 0])
	var buzzes := [0, 0]
	for s in logged:
		if s.source == HandStrikes.Source.HELD:
			buzzes[s.side] += 1
	_expect(failures, pulses[0] == buzzes[0] and pulses[1] == buzzes[1],
			"a buzz in each holding hand per strike (%s, expected %s)" % [str(pulses), str(buzzes)])
	if expect.get("held_at_end", false):
		var end: float = rows[-1].time_s if not rows.is_empty() else 0.0
		_expect(failures, _column_min(rows, "right_grab", end - 0.1, end) == 2.0,
				"the right hand still holds it at the end")


## The ore vein scenarios' checks (health, 2026-10-02), from their "expect":
## the vein's health starts at its most and falls by each strike's damage, down
## to 0 and no further, its display showing every value; "broken": whether it
## ran out, and then left the level in that same tick.
func _accept_vein(result: Dictionary, failures: Array[String]) -> void:
	var expect: Dictionary = {}
	for scenario in _scenarios:
		if scenario.name == result.name:
			expect = scenario.expect
	var maximum: int = result.get("vein_maximum", 0)
	var expected: Array[int] = [maximum]
	for strike: Dictionary in result.get("strikes", []):
		if strike.damage > 0 and expected[-1] > 0:
			expected.append(maxi(expected[-1] - int(strike.damage), 0))
	var went: Array[int] = []
	for entry: Array in result.get("vein_health", []):
		went.append(entry[1])
		_expect(failures, entry[2] == "%d / %d" % [entry[1], maximum],
				"at %d health the vein showed \"%s\"" % [entry[1], entry[2]])
	_expect(failures, went == expected,
			"the vein's health went %s, expected %s from its strikes" % [str(went), str(expected)])
	var broken: bool = expect.broken
	_expect(failures, result.has("vein_depleted") == broken,
			"the vein's health %s" % ("ran out" if broken else "did not run out"))
	if broken:
		_expect(failures, result.get("vein_gone", -1.0) == result.get("vein_depleted", -2.0),
				"the vein left the level in the tick its health ran out")
	else:
		_expect(failures, not result.has("vein_gone"), "the vein is still in the level")


## The chopping scenarios' checks (rung 1, 2026-10-02; at segment lines since
## 1b), from their "expect": the watched line starts as preset, and each
## damaging slash opens the side it landed on by its damage, and on a line of
## sides (a trunk's) the sides either side by its spill, each up to the cap,
## until the line is open enough to cut through, while blunt strikes and
## strikes off the line open nothing; the readout showed every value while it
## showed this line ("open / total"), and shows it once a side opened;
## "on_line": every strike landed on the line; "opened": whether any side
## opened; "felled": whether the tree was felled, and then its top split off to
## fall in that same tick while the stump stayed (_accept_split); "toe" (m):
## each slash landed on its edge within that of the edge's end (Sharp.length).
func _accept_chop(result: Dictionary, failures: Array[String]) -> void:
	var expect: Dictionary = {}
	for scenario in _scenarios:
		if scenario.name == result.name:
			expect = scenario.expect
	var opens: Array = result.get("chop_open", [])
	if opens.is_empty():
		_expect(failures, false, "the tree's line was watched")
		return
	var cap: int = result.chop_cap
	var fell_at: int = result.chop_fell_at
	var sides: Array = result.get("chop_sides", [])
	var strikes: Array = result.get("strikes", [])
	var depths: Array = (opens[0][1] as Array).duplicate()
	var expected: Array = [depths.duplicate()]
	for i in strikes.size():
		var strike: Dictionary = strikes[i]
		var side: int = sides[i] if i < sides.size() else -1
		if expect.get("on_line", false):
			_expect(failures, side >= 0, "%s at %.2f s landed on the line (side %d; %s)"
					% [strike.striker, strike.t, side, strike.get("verdict", "not judged")])
		var open: int = depths.reduce(func(sum: int, depth: int) -> int: return sum + depth, 0)
		if strike.kind == Strike.Kind.SLASH and strike.damage > 0 and side >= 0 and depths[side] < cap \
				and open < fell_at:
			depths[side] = mini(depths[side] + int(strike.damage), cap)
			# On a line of sides, the sides either side open by a share of the damage too.
			if depths.size() > 1:
				var spill := roundi(strike.damage * (result.get("chop_spill", 0.0) as float))
				for next in [posmod(side - 1, depths.size()), posmod(side + 1, depths.size())]:
					depths[next] = mini(depths[next] + spill, cap)
			expected.append(depths.duplicate())
		if expect.has("toe") and strike.kind == Strike.Kind.SLASH:
			var along: float = absf(strike.get("on_feature", [0.0, 0.0, 0.0])[1])
			var half: float = strike.get("feature_length", 0.0) * 0.5
			_expect(failures, along >= half - (expect.toe as float),
					"%s at %.2f s: the slash landed %.3f m along its %s from its middle, within %.2f m of its end (%.3f)"
					% [strike.striker, strike.t, along, strike.feature, expect.toe, half])
	var went: Array = []
	for entry: Array in opens:
		went.append(entry[1])
		var open: int = (entry[1] as Array).reduce(func(sum: int, depth: int) -> int: return sum + depth, 0)
		if entry[3]:
			_expect(failures, entry[2] == "%d / %d" % [open, fell_at],
					"at %d open the readout showed \"%s\"" % [open, entry[2]])
	_expect(failures, went == expected,
			"the line's sides went %s, expected %s from its strikes" % [str(went), str(expected)])
	if expect.has("opened"):
		var opened: bool = went[-1] != went[0]
		_expect(failures, opened == expect.opened, "a side %s" % ("opened" if expect.opened else "stayed shut"))
		if opened:
			_expect(failures, opens[-1][3], "the readout shows the line opened (\"%s\")" % opens[-1][2])
	var felled: bool = expect.felled
	_expect(failures, result.has("chop_felled") == felled, "the tree %s" % ("was felled" if felled else "stands"))
	if felled:
		_accept_split(result, failures)
	else:
		_expect(failures, not result.has("tree_gone") and not result.has("fall_started"),
				"the tree still stands whole")


## A felled tree's top split off to fall in the tick its line was cut through,
## and the tree stayed as the stump, solid.
func _accept_split(result: Dictionary, failures: Array[String]) -> void:
	_expect(failures, result.has("fall_started") and result.get("fall_started") == result.get("chop_felled", -1.0),
			"the top split off to fall in the tick the line was cut through")
	_expect(failures, result.get("stump_solid", false) and not result.has("tree_gone"),
			"the tree stayed as the stump, still solid (%.2f m of trunk)" % result.get("stump_length", 0.0))


## The felling checks (chopping rung 2, 2026-10-02), from "expect": "fall"
## {"down_by", "rest_by", "max_speed"}: the split (_accept_split); the top
## tipped past 60° from upright within "down_by" s of the cut, its centre of
## mass going the way it was felled (within 30°) as it fell to 50°, never
## faster than "max_speed" (m/s), and lay at rest, down, within "rest_by" s.
## "stump" (k): the stump is the trunk up to its line k, k segments long.
func _accept_fall(result: Dictionary, failures: Array[String]) -> void:
	var expect: Dictionary = {}
	for scenario in _scenarios:
		if scenario.name == result.name:
			expect = scenario.expect
	var fall: Dictionary = expect.fall
	_accept_split(result, failures)
	if fall.has("stump"):
		var segment: float = result.get("segment_length", 0.0)
		var stump: float = result.get("stump_length", 0.0)
		_expect(failures, segment > 0.0 and absf(stump - (fall.stump as int) * segment) < 0.001,
				"the stump is %d segments of %.3f m long (%.3f m)" % [fall.stump, segment, stump])
	var log: Array = result.get("fall_log", [])
	if log.size() < 2:
		_expect(failures, false, "the falling top was followed")
		return
	var cut: float = result.fall_started
	var first: Array = log[0]
	var last: Array = log[-1]
	var down_at := INF
	var still_from: float = first[0]
	var fastest := 0.0
	for entry: Array in log:
		if entry[5] >= 60.0 and down_at == INF:
			down_at = entry[0]
		if entry[4] >= 0.05:
			still_from = INF
		elif still_from == INF:
			still_from = entry[0]
		fastest = maxf(fastest, entry[4])
	_expect(failures, down_at - cut <= fall.down_by,
			"it tipped past 60° from upright %.2f s after the cut (by %.1f s)" % [down_at - cut, fall.down_by])
	# The way it fell: up to 50° over, where it has left the hinge. Once its crown
	# is down, a lopsided top may roll on over a limb (2026-10-02).
	var fallen: Array = last
	for entry: Array in log:
		if entry[5] >= 50.0:
			fallen = entry
			break
	var moved := Vector3(fallen[1] - first[1], 0.0, fallen[3] - first[3])
	var toward := Vector3(result.fall_toward[0], 0.0, result.fall_toward[2])
	_expect(failures, moved.length() > 0.5 and rad_to_deg(moved.angle_to(toward)) <= 30.0,
			"its centre of mass went %.2f m as it fell to 50°, %.0f° from the way it was felled"
			% [moved.length(), rad_to_deg(moved.angle_to(toward))])
	_expect(failures, fastest <= fall.max_speed,
			"its centre of mass never went faster than %.1f m/s (%.2f)" % [fall.max_speed, fastest])
	_expect(failures, last[5] >= 60.0 and still_from - cut <= fall.rest_by,
			"it lay down (%.0f° from upright) at rest %.2f s after the cut (by %.1f s)"
			% [last[5], still_from - cut, fall.rest_by])
	# "leaves": the leaf clusters that touched anything are gone (2026-10-02):
	# all there as it was cut, some gone once it lies on the floor, not all; on it
	# and on every piece broken off it, which takes its leaves along (fall damage,
	# 2026-10-03).
	if fall.get("leaves", false):
		_expect(failures, first[7] > 0 and last[7] < first[7] and last[7] > 0,
				"its leaves that met the floor are gone: %d of %d left on it and the pieces broken off it"
				% [last[7], first[7]])
	# "drop" {"shift"}: the weapon dropped on the top at rest moved it no more
	# than "shift" (m), and stayed above the floor.
	if expect.has("drop"):
		var dropped: float = result.get("dropped", -1.0)
		var before: Array = first
		for entry: Array in log:
			if entry[0] < dropped:
				before = entry
		var shift := Vector3(last[1] - before[1], last[2] - before[2], last[3] - before[3]).length()
		_expect(failures, dropped >= 0.0 and shift <= expect.drop.shift,
				"the weapon dropped on it moved the top %.3f m (at most %.2f)" % [shift, expect.drop.shift])
		var lowest := INF
		for entry: Array in result.get("drop_log", []):
			lowest = minf(lowest, entry[1])
		_expect(failures, lowest > -0.05, "the weapon stayed above the floor (lowest %.2f m)" % lowest)


## The limb checks (chopping, 2026-10-02; a line cut through since 1b), from
## "expect": "limb" {"drop", "rest_by", "max_speed"}: the limb came off in the
## tick its line was cut through, once; the line is gone from the tree and from
## the piece; a capped stub is left whose lines that are wood to chop are those
## that could be chopped before the cut (none, cut at the first), and the tree
## stands; the piece's centre of mass fell at least "drop" (m), never faster
## than "max_speed" (m/s), and lay at rest within "rest_by" s of the cut.
func _accept_limb(result: Dictionary, failures: Array[String]) -> void:
	var expect: Dictionary = {}
	for scenario in _scenarios:
		if scenario.name == result.name:
			expect = scenario.expect
	var limb: Dictionary = expect.limb
	var cut: float = result.get("line_cut", -1.0)
	var severed: Array = result.get("severed", [])
	var line: Array = result.get("line_at", [-1, -1, 0.0, 0])
	_expect(failures, severed.size() == 1 and severed[0] == cut,
			"the limb (branch %d) came off in the tick its line %d (%.2f m along it, total %d) was cut through, once (%s)"
			% [line[0], line[1], line[2], line[3], str(severed)])
	_expect(failures, result.get("line_gone", false), "the line is gone from the tree and from the piece")
	var stub_lines: Array = result.get("stub_lines", [-1])
	var before: Array = (result.get("line_choppable", []) as Array).filter(func(k: int) -> bool: return k < line[1])
	_expect(failures, result.get("stub_capped", false) and stub_lines == before,
			"the tree keeps a capped stub, with the lines before the cut still to chop (%s, expected %s)"
			% [str(stub_lines), str(before)])
	_expect(failures, not result.has("chop_felled") and not result.has("tree_gone"), "the tree still stands")
	var log: Array = result.get("limb_log", [])
	if log.size() < 2:
		_expect(failures, false, "the falling limb was followed")
		return
	var first: Array = log[0]
	var last: Array = log[-1]
	var still_from := INF
	var fastest := 0.0
	for entry: Array in log:
		if entry[4] >= 0.05:
			still_from = INF
		elif still_from == INF:
			still_from = entry[0]
		fastest = maxf(fastest, entry[4])
	_expect(failures, first[2] - last[2] >= limb.drop,
			"its centre of mass fell %.2f m, from %.2f m (at least %.1f)" % [first[2] - last[2], first[2], limb.drop])
	_expect(failures, fastest <= limb.max_speed,
			"its centre of mass never went faster than %.1f m/s (%.2f)" % [limb.max_speed, fastest])
	_expect(failures, still_from - cut <= limb.rest_by,
			"it lay at rest %.2f s after the cut (by %.1f s)" % [still_from - cut, limb.rest_by])


## The bucking checks (chopping 1b, 2026-10-02), from "expect": "buck"
## {"ticks", "speed", "gap", "rest_by"}: the tree was felled (_accept_split),
## and its top, lying at rest, cut through at its trunk line: one new piece, in
## that tick, the line gone from both and each carrying the lines on its side
## of the cut. No pop: for the first "ticks" ticks after the cut neither
## piece's centre of mass went "speed" (m/s) or faster beyond what it fell by,
## up to falling freely since the cut (a piece that hung free of the floor
## drops once cut), and the cut faces' middles stayed within "gap" (m) of each
## other along the trunk (shapes overlapping at the cut would throw the pieces
## apart at once); and both lay at rest within "rest_by" s of the cut. Each
## piece then settles onto what
## holds it up now, gathering speed as gravity lets it (at the level oak's
## fourth line about 0.06 m/s a tick, both dropping 5 cm and their cut faces
## parting 3 cm as they tip, 2026-10-02); where it leans on a limb it may settle
## 10 to 27 cm: not checked.
func _accept_buck(result: Dictionary, failures: Array[String]) -> void:
	var expect: Dictionary = {}
	for scenario in _scenarios:
		if scenario.name == result.name:
			expect = scenario.expect
	var buck: Dictionary = expect.buck
	_accept_split(result, failures)
	var bucked: float = result.get("bucked", -1.0)
	var line: Array = result.get("buck_cut", [-1, 0, 0])
	var log: Array = result.get("buck_log", [])
	if not _expect(failures, bucked >= 0.0 and not log.is_empty() and log[0][0] == bucked,
			"the top was bucked at its line %d, as it lay at rest (at %.2f s), into two pieces in that tick"
			% [line[0], bucked]):
		return
	var lines: Array = result.get("buck_lines", [[0, 0], [0, 0]])
	var k: int = line[0]
	_expect(failures, result.get("buck_gone", false) and lines[0][1] == k - 1 and lines[1][0] == k + 1,
			"the line is gone from both pieces, the top keeping lines %d-%d and the piece %d-%d"
			% [lines[0][0], lines[0][1], lines[1][0], lines[1][1]])
	var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
	var fastest := 0.0
	var beyond := 0.0
	var widest := 0.0
	# The first row is the cut's own tick. What a piece falls by, up to falling
	# freely since the cut, is no pop: one that hung free of the floor drops once
	# cut (2026-10-03: once impacts took the felled top's limbs, it lay with its
	# butt off the floor, 5 cm up at the oak's fourth line, 26 cm at its second).
	for i in range(1, mini(buck.ticks + 1, log.size())):
		var falls: float = gravity * (log[i][0] - bucked)
		for piece in 2:
			var speed: float = log[i][1 + piece]
			fastest = maxf(fastest, speed)
			beyond = maxf(beyond, speed - minf(falls, maxf(-(log[i][11 + piece] as float), 0.0)))
		widest = maxf(widest, absf(log[i][3]))
	_expect(failures, beyond < buck.speed,
			"over the first %d ticks neither piece went %.1f m/s or faster beyond falling freely since the cut (%.3f; %.3f m/s at most)"
			% [buck.ticks, buck.speed, beyond, fastest])
	_expect(failures, widest <= buck.gap,
			"over the first %d ticks the cut faces stayed within %.2f m along the trunk (%.4f)"
			% [buck.ticks, buck.gap, widest])
	var still_from := INF
	for entry: Array in log:
		if maxf(entry[1], entry[2]) >= 0.05:
			still_from = INF
		elif still_from == INF:
			still_from = entry[0]
	var first: Array = log[0]
	var last: Array = log[-1]
	var top_moved := Vector3(last[5] - first[5], last[6] - first[6], last[7] - first[7]).length()
	var piece_moved := Vector3(last[8] - first[8], last[9] - first[9], last[10] - first[10]).length()
	_expect(failures, still_from - bucked <= buck.rest_by,
			"both lay at rest %.2f s after the cut (by %.1f s); the top's centre of mass settled %.3f m, the piece's %.3f m"
			% [still_from - bucked, buck.rest_by, top_moved, piece_moved])


## The weight checks (2026-10-02, the player: "each segment (trunk root) should
## be 75kg and each branch segment should be 25kg. When the tree gets cut and a
## segment breaks, the weight of the new chunk should be the combined weight of
## all the connecting segments"), on what _track_weights weighed: every piece
## cut off the tree, or off its pieces, any way (each line cut through by
## slashes, the buck or an impact: "pieces_made", _follow_piece) was weighed;
## each time, it weighed what the weight rule made of its skeleton
## (_weight_rule); a piece cut lost exactly what the pieces cut off it in that
## tick weigh, so the two parts of each cut weigh what the whole did; and each
## piece weighed to the end, or until it went, what it weighed when last cut,
## whatever broke off it since (twigs weigh nothing). On the level's oak: its
## top felled at line 1, 900 kg (8 segments of trunk, 12 of branch; 1,156 kg by
## volume before); its thickest limb cut at its line 2, 150 kg (27 kg by
## volume).
func _accept_weight(result: Dictionary, failures: Array[String]) -> void:
	var weighed: Array = result.get("weighed", [])
	var made: Array = result.get("pieces_made", [])
	var parents := {}
	for record: Dictionary in made:
		parents[record.role] = record.parent
	var broken := made.filter(func(record: Dictionary) -> bool: return record.fall).size()
	var roles := {}
	var first := {}
	for entry: Array in weighed:
		roles[entry[1]] = _piece_name(entry[1])
		if not first.has(entry[1]):
			first[entry[1]] = entry[0]
	_expect(failures, roles.size() == made.size(),
			"each of the %d pieces cut off the tree (%d of them by impacts) was weighed (%s)"
			% [made.size(), broken, ", ".join(roles.values())])
	var last := {}
	for entry: Array in weighed:
		var piece := _piece_name(entry[1])
		_expect(failures, absf(entry[2] - entry[3]) <= 0.001,
				"the %s weighed %.1f kg at %.2f s: %d segments of trunk at %.0f kg and %d of branch at %.0f make %.1f"
				% [piece, entry[2], entry[0], entry[4], TRUNK_SEGMENT_KG, entry[5], BRANCH_SEGMENT_KG, entry[3]])
		if last.has(entry[1]):
			# Weighed again: it was cut, and what was cut off it was first weighed in
			# that same tick.
			var off := 0.0
			var cut_off: Array[String] = []
			for other: Array in weighed:
				if other[0] == entry[0] and first[other[1]] == other[0] and parents.get(other[1], "") == entry[1]:
					off += other[2]
					cut_off.append("the %s, %.1f kg" % [_piece_name(other[1]), other[2]])
			_expect(failures, not cut_off.is_empty() and absf(last[entry[1]][2] - entry[2] - off) <= 0.001,
					"cut at %.2f s, the %s went from %.1f kg to %.1f, losing exactly what was cut off it (%s)"
					% [entry[0], piece, last[entry[1]][2], entry[2], ", ".join(cut_off)])
		last[entry[1]] = entry
	var now: Dictionary = result.get("weight_now", {})
	for role: String in last:
		var end: Array = now.get(role, [-1.0, -1.0, 0])
		_expect(failures, absf(end[1] - last[role][2]) <= 0.001,
				"the %s weighed %.1f kg at %.2f s, the last it was seen, as when it was last cut (%.1f), with %d branches broken off it since"
				% [_piece_name(role), end[1], end[0], last[role][2], end[2]])


## What the weight checks call a piece of a tree by its role (_tree_pieces).
static func _piece_name(role: String) -> String:
	if role.begins_with("broken_"):
		return "piece %s an impact broke off" % role.trim_prefix("broken_")
	return {"top": "felled top", "rest": "piece bucked off the top", "cut": "piece cut off"}.get(role, role)


## The fall damage checks (2026-10-03, the player: "When branches impact the
## ground, they should damage and depending on the impact, they should break
## their segments"; agreed: branch lines only, the trunk stays whole; anything
## solid counts; an impact deals the segment's whole health, so it always
## breaks), on what the tree scenarios followed (_follow_piece, _on_impacted,
## _on_cut_done, _track_pieces), from "expect": "breaks" {"count", "first",
## "quiet_from", "rest_by"} (none: nothing breaks):
## - "count": how many lines impacts broke, exactly or [least, most]; "first":
##   the first of them, each [the role of the piece it broke, the branch's id,
##   k], where they always fall the same; "quiet_from": a time in the results
##   (its key, as "dropped") from which no impact marked anything;
## - only branch lines: no impact marked, and none broke, a line of the trunk
##   (a branch of depth 0);
## - each break was marked by one impact on its line, closing at the tree's
##   impact speed or faster, and every line marked broke;
## - at most TreeChop.IMPACT_CUTS_PER_TICK breaks a physics tick;
## - no piece thrown: after its first step, no piece cut off any way went
##   faster than the wood it was cut off moved at its middle at the cut plus
##   falling freely from that height to the floor, and a tenth;
## - "rest_by" (s): every piece came to rest by then (its first rest that held
##   for REST_HOLD, or until it went or the scenario ended: _track_pieces), or,
##   one an impact broke off, never went CREEP_SPEED or faster from then on (it
##   creeps); held up as it lay (touching the level, the stump or another
##   piece), its lowest point no lower than 2 cm under the floor's top (the 25
##   kg tip of the oak's limb 1 rests with its last capsule, 3.4 cm in radius,
##   1.1 to 1.3 cm into the floor, 2026-10-03);
## - the engine reported fewer contacts for each piece than FelledTree's
##   MAX_CONTACTS, so none was left out.
func _accept_breaks(result: Dictionary, failures: Array[String]) -> void:
	var want: Dictionary = _scenario_named(result.name).expect.get("breaks", {})
	var impacts: Array = result.get("impacts", [])
	var breaks := (result.get("cuts", []) as Array).filter(func(cut: Dictionary) -> bool: return cut.fall)
	var said := func(cut: Dictionary) -> String:
		return "the %s's branch %d at line %d at %.2f s (%.2f m/s), making %s" % [cut.role, cut.line[0], cut.line[1],
				cut.t, cut.speed, cut.made]
	var count: Variant = want.get("count", 0)
	var least: int = count[0] if count is Array else count
	var most: int = count[1] if count is Array else count
	_expect(failures, breaks.size() >= least and breaks.size() <= most,
			"%d lines broke by impacts, expected %s (%s)" % [breaks.size(), str(count),
			"; ".join(breaks.map(said)) if not breaks.is_empty() else "none"])
	var first: Array = want.get("first", [])
	for i in first.size():
		var expected: Array = first[i]
		var cut: Dictionary = breaks[i] if i < breaks.size() else {}
		_expect(failures, not cut.is_empty() and cut.role == expected[0] and cut.line == [expected[1], expected[2]],
				"break %d was the %s's branch %d at line %d (%s)" % [i + 1, expected[0], expected[1], expected[2],
				said.call(cut) if not cut.is_empty() else "none"])
	if want.has("quiet_from"):
		var from: float = result.get(want.quiet_from, -1.0)
		var late := impacts.filter(func(impact: Dictionary) -> bool: return impact.t >= from)
		_expect(failures, from >= 0.0 and late.is_empty(),
				"no impact marked a line from %s, at %.2f s (%d did)" % [want.quiet_from, from, late.size()])
	var trunk := impacts.filter(func(impact: Dictionary) -> bool: return impact.depth == 0)
	trunk.append_array(breaks.filter(func(cut: Dictionary) -> bool: return cut.depth == 0))
	_expect(failures, trunk.is_empty(), "no impact marked or broke a trunk line (%d did)" % trunk.size())
	var speed: float = result.get("impact_speed", 0.0)
	var mark_said := func(impact: Dictionary) -> String:
		return "%.2f m/s on the %s at %.2f s" % [impact.speed, impact.role, impact.t]
	for cut: Dictionary in breaks:
		var marks := impacts.filter(func(impact: Dictionary) -> bool: return impact.line == cut.line)
		_expect(failures, speed > 0.0 and marks.size() == 1 and marks[0].tick <= cut.tick and cut.speed >= speed
				and absf(marks[0].speed - cut.speed) < 1e-4,
				"%s: marked by one impact on its line before, closing at %.1f m/s or faster (%s)" % [said.call(cut),
				speed, ", ".join(marks.map(mark_said))])
	for impact: Dictionary in impacts:
		_expect(failures, breaks.any(func(cut: Dictionary) -> bool: return cut.line == impact.line),
				"the line the %.2f m/s impact at %.2f s marked on the %s (branch %d, line %d) broke"
				% [impact.speed, impact.t, impact.role, impact.line[0], impact.line[1]])
	var per_tick := {}
	for cut: Dictionary in breaks:
		per_tick[cut.tick] = int(per_tick.get(cut.tick, 0)) + 1
	var crowded: int = per_tick.values().max() if not per_tick.is_empty() else 0
	_expect(failures, crowded <= TreeChop.IMPACT_CUTS_PER_TICK,
			"at most %d break a physics tick (%d)" % [TreeChop.IMPACT_CUTS_PER_TICK, crowded])
	var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
	for record: Dictionary in result.get("pieces_made", []):
		var piece := _piece_name(record.role)
		var falling := sqrt(2.0 * gravity * maxf(record.height, 0.0))
		var bound: float = 1.1 * (record.parent_speed + falling)
		_expect(failures, record.fastest <= bound,
				"the %s was not thrown: %.2f m/s at most (at %.2f s), the wood it was cut off moving %.2f m/s at its middle, %.2f m up, gives %.2f (and a tenth)"
				% [piece, record.fastest, record.fastest_at, record.parent_speed, record.height, bound / 1.1])
		_expect(failures, record.contacts < FelledTree.MAX_CONTACTS,
				"the engine reported %d contacts at most for the %s (at %.2f s), under %d" % [record.contacts, piece,
				record.contacts_at, FelledTree.MAX_CONTACTS])
		if want.has("rest_by"):
			var on: Array = record.get("on", [])
			var lowest: float = record.get("lowest", -1.0)
			var rested: bool = record.rest_from >= 0.0 and record.rest_from <= want.rest_by
			# Or, broken off by an impact, it crept on.
			var after := 0.0
			for row: Array in result.get("pieces_log", []):
				if row[0] >= want.rest_by:
					for state: Array in row.slice(1):
						if state[0] == record.role:
							after = maxf(after, state[4])
			_expect(failures, (rested or (record.fall and after < CREEP_SPEED)) and not on.is_empty() and lowest >= -0.02,
					"the %s, made at %.2f s, came to rest by %.1f s (at %.2f; %.3f m/s at most from then, under %.1f if it creeps), held up by %s, its lowest point %.3f m up"
					% [piece, record.t, want.rest_by, record.rest_from, after, CREEP_SPEED, str(on), lowest])


## The set-down checks (fall damage, 2026-10-03), from "expect": "laid"
## {"height", "under"}: the piece was laid level (its main branch within 1° of
## level), its lowest point "height" (m) over the floor, clear of everything it
## meets (nothing within 1.9 cm of its shapes); and the hardest it then met
## anything solid closed under "under" (m/s), its closing speed as FelledTree
## reads it: well under the impact speed.
func _accept_set_down(result: Dictionary, failures: Array[String]) -> void:
	var want: Dictionary = _scenario_named(result.name).expect.laid
	var laid: Dictionary = result.get("laid", {})
	if not _expect(failures, not laid.is_empty(), "the piece was laid down"):
		return
	_expect(failures, laid.tilt <= 1.0 and absf(laid.lowest - (want.height as float)) <= 0.001 and laid.near.is_empty(),
			"it was laid level (%.2f° off), its lowest point %.4f m up (%.2f), clear of everything (near %s)"
			% [laid.tilt, laid.lowest, want.height, str(laid.near)])
	var hardest: Array = [0.0, -1.0, "", -1]
	for record: Dictionary in result.get("pieces_made", []):
		if record.hardest[0] > hardest[0]:
			hardest = record.hardest
	_expect(failures, hardest[0] < want.under,
			"the hardest it met anything solid closed at %.2f m/s (at %.2f s, on %s, a branch of depth %d), under %.1f"
			% [hardest[0], hardest[1], hardest[2], hardest[3], want.under])


## The leaf checks (chopping, 2026-10-02), from "expect": the box went through
## the cluster it was sent at (within 0.3 m of its middle); "leaves": whether
## any leaves broke. Below a swing's speed, no branch broke either.
func _accept_crown_pass(result: Dictionary, failures: Array[String]) -> void:
	var expect: Dictionary = {}
	for scenario in _scenarios:
		if scenario.name == result.name:
			expect = scenario.expect
	var nearest: float = result.get("box_nearest", INF)
	_expect(failures, nearest <= 0.3, "the box went through the cluster (%.2f m from its middle)" % nearest)
	var start: int = result.get("leaves_start", 0)
	var end: int = result.get("leaves_end", 0)
	var gone: int = result.get("branches_gone", 0)
	if expect.leaves:
		_expect(failures, start > 0 and end < start,
				"leaves broke: %d of %d clusters left, %d branches broken" % [end, start, gone])
	else:
		_expect(failures, start > 0 and end == start and gone == 0,
				"no leaves broke: %d of %d clusters left, %d branches broken" % [end, start, gone])


## The loot checks (2026-10-02), from "expect": "loot" items of the vein's loot
## scene dropped in the tick the vein went, inside its meshes' bounds and clear
## of each other (their origins at least their two reaches apart). With
## "settle": nothing pushed them as they appeared (after the first step each
## moves only as gravity moves it, unturned), none rose, and all end at rest on
## the floor beside where the vein stood.
func _accept_loot(result: Dictionary, failures: Array[String]) -> void:
	var expect: Dictionary = {}
	for scenario in _scenarios:
		if scenario.name == result.name:
			expect = scenario.expect
	var loot: Array = result.get("loot", [])
	_expect(failures, loot.size() == expect.loot, "%d dropped, expected %d" % [loot.size(), expect.loot])
	_expect(failures, result.has("loot_dropped") and result.loot_dropped == result.get("vein_gone", -1.0),
			"the loot dropped in the tick the vein went")
	var corners: Array = result.get("vein_bounds", [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0]])
	var low := Vector3(corners[0][0], corners[0][1], corners[0][2])
	var bounds := AABB(low, Vector3(corners[1][0], corners[1][1], corners[1][2]) - low)
	var spawns: Array[Vector3] = []
	for item: Dictionary in loot:
		spawns.append(Vector3(item.spawn[0], item.spawn[1], item.spawn[2]))
	for i in loot.size():
		_expect(failures, loot[i].scene == result.get("loot_scene", ""),
				"drop %d is %s (%s)" % [i, result.get("loot_scene", "?"), loot[i].scene])
		_expect(failures, bounds.has_point(spawns[i]),
				"drop %d appeared inside the vein's bounds (%s)" % [i, str(spawns[i])])
	_accept_apart(result, failures)
	if not expect.get("settle", false):
		return
	var log: Array = result.get("loot_log", [])
	_accept_unpushed(result, failures)
	var stood: Array = result.get("vein_position", [0.0, 0.0, 0.0])
	var last: Array = log[-1] if not log.is_empty() else []
	for i in loot.size():
		var highest := -INF
		for entry: Array in log:
			highest = maxf(highest, entry[i + 1][1])
		_expect(failures, highest <= spawns[i].y + 0.001,
				"drop %d never rose (highest %.3f m, appeared at %.3f)" % [i, highest, spawns[i].y])
		if last.is_empty():
			continue
		var state: Array = last[i + 1]
		var speed := Vector3(state[3], state[4], state[5]).length()
		var turning := Vector3(state[6], state[7], state[8]).length()
		var aside := Vector2(state[0] - stood[0], state[2] - stood[2]).length()
		# Resting on the floor (its top at 0): its origin no higher than its reach.
		_expect(failures, speed <= 0.05 and turning <= 0.05 and state[1] > 0.0
				and state[1] <= float(loot[i].reach) + 0.01 and aside <= 0.6,
				"drop %d came to rest on the floor beside the vein (%.3f m/s, %.3f rad/s, %.3f m up, %.3f m aside)" % [
						i, speed, turning, state[1], aside])


## The loot appeared clear of each other: their origins at least their two
## reaches apart.
func _accept_apart(result: Dictionary, failures: Array[String]) -> void:
	var loot: Array = result.get("loot", [])
	for i in loot.size():
		for j in range(i + 1, loot.size()):
			var apart := Vector3(loot[i].spawn[0], loot[i].spawn[1], loot[i].spawn[2]).distance_to(
					Vector3(loot[j].spawn[0], loot[j].spawn[1], loot[j].spawn[2]))
			var clear: float = loot[i].reach + loot[j].reach
			_expect(failures, apart >= clear,
					"drops %d and %d appeared clear of each other (%.3f m apart, %.3f needed)" % [i, j, apart, clear])


## Nothing pushed the loot as it appeared: after its first step each moved only
## as gravity moved it, unturned.
func _accept_unpushed(result: Dictionary, failures: Array[String]) -> void:
	var step := 1.0 / Engine.physics_ticks_per_second
	var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
	var first: Array = []
	for entry: Array in result.get("loot_log", []):
		if entry[0] > result.get("loot_dropped", INF) + 1e-6:
			first = entry
			break
	_expect(failures, first.size() == result.get("loot", []).size() + 1, "the loot was seen after its first step")
	for i in range(1, first.size()):
		var state: Array = first[i]
		var pushed := Vector3(state[3], state[4] + gravity * step, state[5]).length()
		var turned := Vector3(state[6], state[7], state[8]).length()
		_expect(failures, pushed <= 0.01 and turned <= 0.01,
				"drop %d was not pushed as it appeared (%.4f m/s, %.4f rad/s beyond gravity's)" % [i - 1, pushed, turned])


## The lone piece checks (chopping 1c, 2026-10-02), from "expect": "lone"
## {"from", "health", "loot", "scene", "mass", "rest_by", "aside", "chops_on",
## "still"}. The piece the scenario broke turned lone in the tick of the cut
## "from" names (the result's time of it), with "health" that only slashes take,
## its readout showing it, while each piece "chops_on" names (_tree_pieces)
## still had a line to chop. Nothing but the script struck it once it was lone,
## one slash for every 10 health, and each was judged LONE and took its full 10
## off, the readout showing every value (what its loot strikes as it falls, on
## other pieces, is not its own); the piece never moved as it was struck, and
## left the level in the tick its health ran out. In that tick "loot" items of
## "scene" dropped, each weighing "mass" (kg; the player's, 2026-10-02: "The
## stick should be maybe 2.5kg and the logs can be 8kg"), laid as LootDrop lays
## them for a tree (LootDrop.lay_down): on their sides, round the piece's middle
## on a ring whose neighbours are two reaches and LootDrop's gap apart, at the
## middle's height, or whole spacings above it where something other than the
## piece took its place there (_blocked_places); clear of each other
## (_accept_apart); unpushed as they appeared (_accept_unpushed). None was
## thrown: none went faster than a tenth over falling freely from where it was
## laid to the floor. Each lay at rest on the floor (its top at 0; the item's
## lowest point within 1 cm of it), lying or leaning, not on its end (its length
## under 60° from level), within "rest_by" s of the drop, and within "aside" (m)
## of where it was laid. "still"
## {"shift", "settle", "settle_by"}, for the piece the scenario's "still" names,
## from the tick the lone piece went to the end: if it did not touch that piece
## as it went (_touches), its centre of mass moved at most "shift" (m); if it
## did, it was awake in that tick, not left asleep where the piece held it up,
## and settled onto what holds it up now: its centre of mass moved at most
## "settle" (m), no faster than a tenth and 0.05 m/s over falling freely as far
## as it dropped, and it lay at rest again within "settle_by" s.
func _accept_lone(result: Dictionary, failures: Array[String]) -> void:
	var scenario := _scenario_named(result.name)
	var want: Dictionary = scenario.expect.lone
	var lone: Dictionary = result.get("lone", {})
	if not _expect(failures, not lone.is_empty(), "the piece turned lone"):
		return
	var cut: float = result.get(want.from, -1.0)
	_expect(failures, lone.at == cut, "it turned lone in the tick it was cut (at %.3f s; %s at %.3f s)" % [
			lone.at, want.from, cut])
	_expect(failures, lone.maximum == want.health and lone.kinds == 1 << Strike.Kind.SLASH,
			"with %d health (%d), only slashes taking it (kinds %d)" % [want.health, lone.maximum, lone.kinds])
	var pieces: Dictionary = result.get("lone_pieces", {})
	for role: String in want.chops_on:
		_expect(failures, pieces.has(role) and not pieces[role],
				"the %s still had a line to chop as the piece was struck (lone: %s)" % [role, str(pieces)])
	# Its own strikes once lone ([time, striker, kind, damage, verdict]), and the
	# script's slashes ([time, where its body was]).
	var strikes: Array = result.get("lone_strikes", [])
	var slashes: Array = result.get("lone_struck", [])
	var others := strikes.filter(func(strike: Array) -> bool: return strike[1] != "")
	_expect(failures, others.is_empty() and strikes.size() == slashes.size()
			and slashes.size() == ceili(lone.maximum / float(Strike.MAX_DAMAGE)),
			"nothing but the script struck it, one slash for every 10 health (%d strikes, %d slashed; others %s)"
			% [strikes.size(), slashes.size(), str(others)])
	var expected: Array[int] = [lone.maximum]
	for strike: Array in strikes:
		_expect(failures, strike[4] == "LONE" and strike[2] == Strike.Kind.SLASH and strike[3] == Strike.MAX_DAMAGE,
				"the slash at %.3f s was judged on the lone piece at full strength (%s, kind %d, damage %d)"
				% [strike[0], strike[4], strike[2], strike[3]])
		if strike[2] == Strike.Kind.SLASH and strike[3] > 0 and expected[-1] > 0:
			expected.append(maxi(expected[-1] - int(strike[3]), 0))
	var went: Array[int] = []
	for entry: Array in result.get("lone_health", []):
		went.append(entry[1])
		_expect(failures, entry[2] == "%d / %d" % [entry[1], lone.maximum],
				"at %d health its readout showed \"%s\"" % [entry[1], entry[2]])
	_expect(failures, went == expected, "its health went %s, expected %s from its strikes" % [str(went), str(expected)])
	var moved := 0.0
	for entry: Array in slashes:
		moved = maxf(moved, Vector3(entry[1] - slashes[0][1], entry[2] - slashes[0][2], entry[3] - slashes[0][3]).length())
	_expect(failures, not slashes.is_empty() and moved <= 0.001,
			"it did not move as it was struck (%.4f m over %d slashes)" % [moved, slashes.size()])
	var depleted: float = result.get("lone_depleted", -1.0)
	_expect(failures, depleted >= 0.0 and result.get("lone_gone", -2.0) == depleted,
			"its %s left the level in the tick its health ran out (%.3f s)" % [lone.object, depleted])
	# Its loot.
	var loot: Array = result.get("loot", [])
	if not _expect(failures, loot.size() == want.loot and result.get("loot_dropped", -1.0) == depleted,
			"%d dropped in that tick, expected %d" % [loot.size(), want.loot]):
		return
	var at: Array = result.get("lone_middle", [0.0, 0.0, 0.0])
	var middle := Vector3(at[0], at[1], at[2])
	var blocked: Array = result.get("lone_blocked", [])
	var log: Array = result.get("loot_log", [])
	# The first row is the drop's own tick, as they were laid.
	var laid: Array = log[0] if not log.is_empty() and log[0][0] == depleted else []
	for i in loot.size():
		var spawn := Vector3(loot[i].spawn[0], loot[i].spawn[1], loot[i].spawn[2])
		var spacing: float = 2.0 * loot[i].reach + lone.gap
		var ring := spacing / (2.0 * sin(PI / loot.size())) if loot.size() > 1 else 0.0
		var out := Vector2(spawn.x - middle.x, spawn.z - middle.z).length()
		var rises := (spawn.y - middle.y) / spacing
		var taken: Array = blocked[i] if i < blocked.size() else ["?"]
		var tilt: float = laid[i + 1][10] if not laid.is_empty() else 90.0
		_expect(failures, loot[i].scene == want.scene, "drop %d is %s (%s)" % [i, want.scene, loot[i].scene])
		_expect(failures, absf(float(loot[i].get("mass", 0.0)) - (want.mass as float)) <= 1e-4,
				"drop %d weighs %.1f kg (%.2f)" % [i, want.mass, loot[i].get("mass", 0.0)])
		_expect(failures, absf(out - ring) <= 0.001 and absf(rises - roundf(rises)) <= 0.001
				and (roundi(rises) == 0 if taken.is_empty() else roundi(rises) >= 1) and tilt <= 0.1,
				"drop %d was laid on its side round the middle, raised only if its place was taken: %.4f m out (the ring %.4f m), %.4f m above it (%.2f spacings of %.3f m; its place taken by %s), its length %.1f° from level"
				% [i, out, ring, spawn.y - middle.y, rises, spacing, str(taken), tilt])
	_accept_apart(result, failures)
	_accept_unpushed(result, failures)
	if log.is_empty():
		return
	var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
	for i in loot.size():
		var spawn := Vector3(loot[i].spawn[0], loot[i].spawn[1], loot[i].spawn[2])
		var fastest := 0.0
		var still_from := INF
		for entry: Array in log:
			var state: Array = entry[i + 1]
			var speed := Vector3(state[3], state[4], state[5]).length()
			fastest = maxf(fastest, speed)
			if speed > 0.05 or Vector3(state[6], state[7], state[8]).length() > 0.05:
				still_from = INF
			elif still_from == INF:
				still_from = entry[0]
		var bound := 1.1 * sqrt(2.0 * gravity * maxf(spawn.y, 0.0))
		_expect(failures, fastest <= bound,
				"drop %d was not thrown: %.2f m/s at most, falling freely from %.3f m up gives %.2f (and a tenth)"
				% [i, fastest, spawn.y, bound / 1.1])
		var last: Array = log[-1][i + 1]
		var aside := Vector2(last[0] - spawn.x, last[2] - spawn.z).length()
		# Under 60° from level: lying, or leaning on what is beside it (a log
		# on its stump ends 34-40° up), not standing on its end (about 90).
		_expect(failures, still_from - depleted <= want.rest_by and absf(last[9]) <= 0.01 and last[10] < 60.0
				and aside <= want.aside,
				"drop %d lay at rest on the floor on its side %.2f s after it dropped (by %.1f), its lowest point %.4f m up, its length %.1f° from level (under 60: lying or leaning, not on its end), %.3f m from where it was laid (at most %.1f)"
				% [i, still_from - depleted, want.rest_by, last[9], last[10], aside, want.aside])
	if not want.has("still"):
		return
	# The piece the scenario's "still" names, from where it lay as the piece went
	# (the row of that tick, before its step) to the end.
	var rule: Dictionary = want.still
	var rows: Array = result.get("still_log", [])
	var gone: Dictionary = result.get("still_drop", {})
	var rested: Array = []
	for row: Array in rows:
		if row[0] <= depleted + 1e-6:
			rested = row
	if not _expect(failures, not rested.is_empty() and not gone.is_empty(),
			"the %s was followed as the piece went" % scenario.still):
		return
	var end: Array = rows[-1]
	var shift := Vector3(end[1] - rested[1], end[2] - rested[2], end[3] - rested[3]).length()
	if not gone.touched:
		_expect(failures, shift <= rule.shift,
				"the %s, which did not touch the piece as it went, stayed put: its centre of mass moved %.4f m (at most %.2f)"
				% [scenario.still, shift, rule.shift])
		return
	# It touched it: woken in that tick, not left asleep where the piece held it
	# up (Jolt wakes nothing whose support is freed), it settles onto what holds
	# it up now.
	var lowest: float = rested[2]
	var fastest := 0.0
	var still_from := INF
	for row: Array in rows:
		if row[0] <= depleted + 1e-6:
			continue
		lowest = minf(lowest, row[2])
		fastest = maxf(fastest, row[4])
		if row[4] >= 0.05:
			still_from = INF
		elif still_from == INF:
			still_from = row[0]
	var fall := sqrt(2.0 * gravity * maxf(rested[2] - lowest, 0.0))
	_expect(failures, gone.awake,
			"the %s, which touched the piece as it went, was awake in that tick (asleep just before: %s)"
			% [scenario.still, gone.asleep])
	_expect(failures, shift <= rule.settle and fastest <= 1.1 * fall + 0.05 and still_from - depleted <= rule.settle_by,
			"the %s settled onto what holds it up now: its centre of mass moved %.4f m (at most %.1f) and dropped %.4f m, at most %.3f m/s (falling freely that far gives %.3f; a tenth and 0.05 m/s more allowed), at rest again %.2f s after (by %.1f)"
			% [scenario.still, shift, rule.settle, rested[2] - lowest, fastest, fall, still_from - depleted, rule.settle_by])


## The rolling loot checks (2026-10-02), from "expect": "roll" {"mass",
## "distance", "rest_by"}: the item weighs "mass" (kg; the player's). Set rolling
## (_drive_loot_roll), it never went faster than it was set rolling at; it came
## to rest, moving and turning under 0.05 m/s and rad/s from then to the end,
## within "rest_by" s, its centre of mass within "distance" (m) along the floor
## of where it was set rolling; and it lies on the floor (its lowest point
## within 1 cm of it).
func _accept_roll(result: Dictionary, failures: Array[String]) -> void:
	var scenario := _scenario_named(result.name)
	var want: Dictionary = scenario.expect.roll
	var speed: float = scenario.roll.speed
	_expect(failures, absf(result.get("roll_mass", 0.0) - (want.mass as float)) <= 1e-4,
			"it weighs %.1f kg (%.2f)" % [want.mass, result.get("roll_mass", 0.0)])
	var log: Array = result.get("roll_log", [])
	if not _expect(failures, log.size() >= 2, "it was set rolling and followed (%d ticks)" % log.size()):
		return
	var first: Array = log[0]
	var last: Array = log[-1]
	var fastest := 0.0
	var still_from := INF
	for entry: Array in log.slice(1):
		fastest = maxf(fastest, entry[4])
		if entry[4] >= 0.05 or entry[5] >= 0.05:
			still_from = INF
		elif still_from == INF:
			still_from = entry[0]
	var went := Vector2(last[1] - first[1], last[3] - first[3]).length()
	_expect(failures, fastest <= speed,
			"it never went faster than it was set rolling at (%.3f m/s at most, set at %.1f)" % [fastest, speed])
	_expect(failures, still_from - first[0] <= want.rest_by and went <= want.distance,
			"it came to rest %.2f s after it was set rolling (by %.1f), %.3f m from where it was (at most %.1f)"
			% [still_from - first[0], want.rest_by, went, want.distance])
	_expect(failures, absf(last[6]) <= 0.01, "it lies on the floor (its lowest point %.4f m up)" % last[6])


## A lone piece walked into ("lone_set", "walk"; 2026-10-03): at the first tick
## the piece is made and laid down (_lay_lone); the stick walks the body ahead
## at full speed from "walk"[0] to "walk"[1] (s), into the piece and on. The
## piece is followed every tick (_track_walked).
func _drive_lone_walk(t: float) -> bool:
	var scenario := _scenarios[_index]
	if not _scenario_state.has("walked"):
		_lay_lone(scenario)
	var walk: Array = scenario.walk
	_rig.stick = Vector2(0.0, 1.0) if t >= walk[0] and t < walk[1] else Vector2.ZERO
	_track_walked(t, walk[0])
	return false


## Makes a lone piece of the watched tree at once and lays it down, still, at
## "lone_set" {"kind", "at", "yaw"}: its centre of mass over at, its main branch
## level along X, square to a walk along -Z (_set_down), turned as it comes to
## rest lying there (_roll_to_rest), its lowest point at's height over the
## floor, then turned "yaw" degrees about the vertical (none if absent). "log": a
## segment of trunk, the tree felled at its line 1 and the top bucked at its line
## 2 in the same tick, the top kept from tipping over the stump, and the rest of
## it, cut off at line 2, freed; "stick": a segment of branch, the tip of the
## tree's thickest limb, cut off at its last line that can be chopped (as
## chop_stick_loot cuts it). The piece is kept ("walked_piece"), and what it is
## goes into the results ("walked": its "kind", its "mass" (kg) and the spin
## damp the tree gives a lone piece ("setting", TreeChop.lone_angular_damp, /s);
## _track_walked adds the rest).
func _lay_lone(scenario: Dictionary) -> FelledTree:
	var tree := _level.get_node(scenario.tree as NodePath) as ProceduralTree
	var chop := tree.get_node(^"TreeChop") as TreeChop
	var lay: Dictionary = scenario.lone_set
	var piece: FelledTree
	if lay.kind == "log":
		chop.preset(0, 1, _opened_through(chop.line_at(0, 1)))
		piece = _scenario_state.fall_piece
		# Laid down at once, it does not tip over the stump's edge first.
		piece.tip_over(Vector3.ZERO, Vector3.ZERO, 0.0)
		piece.piece.severed.connect(func(rest: FelledTree) -> void: _scenario_state.buck_piece = rest,
				CONNECT_ONE_SHOT)
		piece.chop.preset(0, 2, _opened_through(piece.chop.line_at(0, 2)))
		(_scenario_state.buck_piece as FelledTree).free()
	else:
		var skeleton := tree.skeleton
		var limb := -1
		for branch in skeleton.branch_count():
			if skeleton.branch_depth[branch] == 1 and (limb < 0
					or skeleton.branch_base_radius[branch] > skeleton.branch_base_radius[limb]):
				limb = branch
		var span := skeleton.line_range(limb)
		var k := span.y
		while k > span.x and not chop.choppable(limb, k):
			k -= 1
		chop.preset(limb, k, _opened_through(chop.line_at(limb, k)))
		piece = _scenario_state.severed_piece
	_set_down(piece, lay.at)
	_roll_to_rest(piece, lay.at.y)
	if lay.has("yaw"):
		var centre := piece.global_transform * PhysicsServer3D.body_get_direct_state(piece.get_rid()).center_of_mass_local
		var turn := Basis(Vector3.UP, deg_to_rad(lay.yaw))
		piece.global_transform = Transform3D(turn * piece.global_basis, centre + turn * (piece.global_position - centre))
	_scenario_state.walked_piece = piece
	_scenario_state.walked = {"kind": lay.kind, "mass": piece.mass, "setting": chop.lone_angular_damp}
	return piece


## Turns a piece laid down level along X (_set_down) to where it comes to rest
## lying there: where its centre of mass sits lowest over its lowest point, of
## every degree round that line through its centre of mass and every quarter
## degree it may tip along it, up to 6° either way. Its wood is never round: a
## lone log of the level's oak is two cylinders, 0.353 and 0.343 m in radius,
## their axes 3.7 cm apart, so it rocks to a rest. Its lowest point is then
## `height` over the floor.
func _roll_to_rest(piece: FelledTree, height: float) -> void:
	var laid := piece.global_transform
	# The engine's centre of mass in the world lags a move until its next step.
	var centre := laid * PhysicsServer3D.body_get_direct_state(piece.get_rid()).center_of_mass_local
	var lowest := INF
	var rest := laid
	for degree in 360:
		for quarter in range(-24, 25):
			var turn := Basis(Vector3.BACK, deg_to_rad(quarter * 0.25)) * Basis(Vector3.RIGHT, deg_to_rad(degree))
			var pose := Transform3D(turn * laid.basis, centre + turn * (laid.origin - centre))
			var above := centre.y - _lowest_point_at(piece, pose)
			if above < lowest - 1e-7:
				lowest = above
				rest = pose
	piece.global_transform = rest
	piece.global_position.y += height - _lowest_point(piece)


## Each of `line`'s sides open to its cap: enough to cut it through.
static func _opened_through(line: TreeChop.Line) -> PackedInt32Array:
	var sides := PackedInt32Array()
	sides.resize(line.depths.size())
	sides.fill(line.cap)
	return sides


## Follows the laid lone piece every tick ("walked_log": [time, its centre of
## mass x, y, z, its speed, its spin, whether the player touched it, whether it
## sleeps]): the player touches it through a contact on its Player or Hands
## layers that pushed. Into "walked": once it is lone, its spin damp ("damp",
## /s) and its radius at its middle ("radius", m); and from `from` (s), where its
## centre of mass lay then ("start"), the farthest it has gone from there along
## the floor ("moved", m), how far it has turned ("turned", radians), how many
## ticks the player touched it and the last of them ("touches", "last_touch", s;
## -1 if none), the farthest it went along the floor from where it was then
## ("rolled_on", m), and when its last rest began ("rest_from", s: moving and
## turning under 0.05 m/s and rad/s since; -1 while it moves).
func _track_walked(t: float, from: float) -> void:
	var piece: FelledTree = _scenario_state.get("walked_piece")
	if not is_instance_valid(piece):
		return
	var walked: Dictionary = _scenario_state.walked
	var state := PhysicsServer3D.body_get_direct_state(piece.get_rid())
	var touching := false
	for i in state.get_contact_count():
		var other := state.get_contact_collider_object(i)
		var layer: int = other.get("collision_layer") if other != null and "collision_layer" in other else 0
		if layer & (ProceduralTree.PLAYER_LAYER | ProceduralTree.HANDS_LAYER) \
				and state.get_contact_impulse(i).length() > 0.0:
			touching = true
	var centre := piece.centre_of_mass()
	var speed := piece.linear_velocity.length()
	var spin := piece.angular_velocity.length()
	var log: Array = _scenario_state.get("walked_log", [])
	log.append([t, centre.x, centre.y, centre.z, speed, spin, touching, piece.sleeping])
	_scenario_state.walked_log = log
	if piece.chop.health != null:
		walked.damp = piece.angular_damp
		walked.radius = piece.chop.lone_radius()
	if t < from:
		return
	if not walked.has("start"):
		walked.merge({"start": [centre.x, centre.y, centre.z], "moved": 0.0, "turned": 0.0, "touches": 0,
				"last_touch": -1.0, "rolled_on": 0.0, "rest_from": -1.0})
	var start: Array = walked.start
	walked.moved = maxf(walked.moved, Vector2(centre.x - start[0], centre.z - start[2]).length())
	walked.turned += spin / Engine.physics_ticks_per_second
	if touching:
		walked.touches += 1
		walked.last_touch = t
		walked.touched_at = [centre.x, centre.y, centre.z]
		walked.rolled_on = 0.0
	elif walked.has("touched_at"):
		var left: Array = walked.touched_at
		walked.rolled_on = maxf(walked.rolled_on, Vector2(centre.x - left[0], centre.z - left[2]).length())
	if speed >= 0.05 or spin >= 0.05:
		walked.rest_from = -1.0
	elif walked.rest_from < 0.0:
		walked.rest_from = t


## The checks for a lone piece walked into (2026-10-03), from "expect": "walked"
## {"moved", "rolled_on", "rest_by"}: the piece is lone and damps its spin by
## its tree's lone_angular_damp; it lay still as the walk began; the player
## touched it; its centre of mass went no farther than "moved" (m) along the
## floor from where it lay then, at any time, nor than "rolled_on" (m) from where
## it was at the last touch, after it; and from the last touch it was at rest
## (moving and turning under 0.05 m/s and rad/s) within "rest_by" s, and stayed
## so to the end.
func _accept_walked(result: Dictionary, failures: Array[String]) -> void:
	var want: Dictionary = _scenario_named(result.name).expect.walked
	var walked: Dictionary = result.get("walked", {})
	if not _expect(failures, walked.has("start"), "the lone piece was laid down and followed through the walk"):
		return
	var log: Array = result.get("walked_log", [])
	var walk_from: float = _scenario_named(result.name).walk[0]
	var still: Array = []
	for row: Array in log:
		if row[0] >= walk_from:
			still = row
			break
	var damp: float = walked.get("damp", -1.0)
	_expect(failures, absf(damp - (walked.setting as float)) < 1e-4,
			"the %s, lone, %.0f kg, %.3f m in radius at its middle, damps its spin by %.1f /s, the tree's lone_angular_damp (%.1f)"
			% [walked.kind, walked.mass, walked.get("radius", 0.0), damp, walked.setting])
	if not _expect(failures, not still.is_empty(), "it was followed from the walk's start"):
		return
	_expect(failures, still[4] < 0.05 and still[5] < 0.05,
			"it lay still as the walk began (%.3f m/s, %.3f rad/s)" % [still[4], still[5]])
	var touched: int = walked.touches
	if not _expect(failures, touched > 0, "the player walked into it"):
		return
	_expect(failures, walked.moved <= want.moved,
			"its centre of mass went %.3f m along the floor at most (at most %.2f), turning %.0f°"
			% [walked.moved, want.moved, rad_to_deg(walked.turned)])
	_expect(failures, walked.rolled_on <= want.rolled_on,
			"touched for %d ticks, the last at %.2f s, it rolled on %.3f m after it (at most %.2f)"
			% [touched, walked.last_touch, walked.rolled_on, want.rolled_on])
	var rest_from: float = walked.rest_from
	if rest_from < 0.0:
		_expect(failures, false, "it still moved at the end, %.2f s after the last touch (to lie at rest by %.1f)"
				% [log[-1][0] - walked.last_touch, want.rest_by])
		return
	_expect(failures, rest_from - walked.last_touch <= want.rest_by,
			"it lay at rest from %.2f s on, %.2f s after the last touch (by %.1f)"
			% [rest_from, rest_from - walked.last_touch, want.rest_by])


func _drive_steps(t: float) -> bool:
	return _out_and_back(t, 5.0,
			func() -> bool: return _state.body_position.x >= 4.9,
			func() -> bool: return _state.body_position.x <= 2.0)


func _drive_ramp(t: float) -> bool:
	return _out_and_back(t, 9.0,
			func() -> bool: return _state.body_position.x <= -4.2,
			func() -> bool: return _state.body_position.x >= 4.3)


## Walks forward at full stick until `arrived` holds, pauses, turns the head
## round as a person would, walks back until `returned` holds, then stands.
## Each leg gives up after `leg_limit` seconds.
func _out_and_back(t: float, leg_limit: float, arrived: Callable, returned: Callable) -> bool:
	var since: float = t - _scenario_state.phase_start
	match _scenario_state.phase:
		0:
			_rig.stick = Vector2(0.0, 1.0)
			if arrived.call() or since > leg_limit:
				_enter_phase(1, t)
		1:
			_rig.stick = Vector2.ZERO
			if since >= PAUSE:
				_scenario_state.turn_from = _rig.yaw
				_enter_phase(2, t)
		2:
			var turned := clampf(since / TURN_TIME, 0.0, 1.0)
			_rig.yaw = _scenario_state.turn_from + PI * turned
			if turned >= 1.0:
				_enter_phase(3, t)
		3:
			_rig.stick = Vector2(0.0, 1.0)
			if returned.call() or since > leg_limit:
				_enter_phase(4, t)
		_:
			_rig.stick = Vector2.ZERO
			return since >= PAUSE
	return false


func _enter_phase(phase: int, t: float) -> void:
	_scenario_state.phase = phase
	_scenario_state.phase_start = t


func _drive_drop(_t: float) -> bool:
	if not _state.supported:
		_scenario_state.fell = true
	if _scenario_state.get("fell", false):
		_rig.stick = Vector2.ZERO
		if _state.supported:
			_scenario_state.landed_for = _scenario_state.get("landed_for", 0.0) \
					+ 1.0 / Engine.physics_ticks_per_second
		return _scenario_state.get("landed_for", 0.0) >= 2.0
	_rig.stick = Vector2(0.0, 1.0)
	return false


## Real walking in the room at about 0.8 m/s: 1.2 m forward, back, then 0.8 m
## sideways, with pauses. The stick is never touched.
func _drive_room_walk(t: float) -> bool:
	var legs := [[0.5, 2.0, Vector3(0.0, 0.0, -1.2)], [3.0, 4.5, Vector3(0.0, 0.0, 1.2)],
			[5.5, 6.5, Vector3(0.8, 0.0, 0.0)]]
	var offset := Vector3.ZERO
	for leg: Array in legs:
		offset += (leg[2] as Vector3) * clampf((t - leg[0]) / (leg[1] - leg[0]), 0.0, 1.0)
	_rig.head_position = Vector3(offset.x, SimulatedRig.HEAD_HEIGHT, offset.z)
	return false


## Full stick ahead (+X) from 0.5 s to 5 s while really walking in the room at
## 0.8 m/s: 0.8 m along the stick, 0.8 m back against it, then 1.2 m to the
## right across it, carrying on past the stick's release. Only the stick may
## move the view; the room walk never does.
func _drive_stick_room_walk(t: float) -> bool:
	_rig.stick = Vector2(0.0, 1.0) if t >= 0.5 and t < 5.0 else Vector2.ZERO
	var legs := [[1.0, 2.0, Vector3(0.8, 0.0, 0.0)], [2.5, 3.5, Vector3(-0.8, 0.0, 0.0)],
			[4.0, 5.5, Vector3(0.0, 0.0, 1.2)]]
	var offset := Vector3.ZERO
	for leg: Array in legs:
		offset += (leg[2] as Vector3) * clampf((t - leg[0]) / (leg[1] - leg[0]), 0.0, 1.0)
	_rig.head_position = Vector3(offset.x, SimulatedRig.HEAD_HEIGHT, offset.z)
	return false


## Real walking along the ramp, facing downhill: 1 m down it, then back up.
## Head offsets are in the rig's space, which is not turned, so downhill is -X.
func _drive_slope_walk(t: float) -> bool:
	var along := clampf((t - 0.5) / 1.5, 0.0, 1.0) - clampf((t - 3.0) / 1.5, 0.0, 1.0)
	_rig.head_position = Vector3(-1.0 * along, SimulatedRig.HEAD_HEIGHT, 0.0)
	return false


## Walks the real head by `offset` over 2.5 s from 0.5 s, and holds it there.
func _drive_head_to(t: float, offset: Vector3) -> bool:
	var along := clampf((t - 0.5) / 2.5, 0.0, 1.0)
	_rig.head_position = Vector3(offset.x * along, SimulatedRig.HEAD_HEIGHT, offset.z * along)
	return false


## Both hands trace 0.15 m circles at 1 Hz in front of the body, easing in.
func _drive_hands_free(t: float) -> bool:
	var amount := clampf((t - 0.5) / 0.5, 0.0, 1.0)
	var phase := TAU * t
	var offset := Vector3(sin(phase), cos(phase) - 1.0, 0.0) * 0.15 * amount
	_rig.left_hand = Vector3(-SimulatedRig.HAND_REST.x, SimulatedRig.HAND_REST.y, SimulatedRig.HAND_REST.z) \
			+ Vector3(-offset.x, offset.y, 0.0)
	_rig.right_hand = SimulatedRig.HAND_REST + offset
	return false


## Reaches the right hand (or both) 1.1 m forward at shoulder height over
## 1.5 s, holds until 4 s, and brings it back. The hand drive limits the reach
## to the arm's length from the shoulder.
func _drive_hand_reach(t: float, both: bool) -> bool:
	var reach := clampf((t - 0.5) / 1.5, 0.0, 1.0) - clampf((t - 4.0) / 1.0, 0.0, 1.0)
	var forward := lerpf(SimulatedRig.HAND_REST.z, -1.1, reach)
	var height := lerpf(SimulatedRig.HAND_REST.y, 1.4, reach)
	_set_hand(false, Vector3(SimulatedRig.HAND_REST.x, height, forward))
	if both:
		_set_hand(true, Vector3(-SimulatedRig.HAND_REST.x, height, forward))
	return false


## Both hands at shoulder height: reach to the wall and a little past it by
## 1.5 s, hold; reach further by 3.5 s, hold; bring them back by 5.5 s.
func _drive_push_steps(t: float) -> bool:
	var reach := lerpf(0.0, 0.28, clampf((t - 0.5) / 1.0, 0.0, 1.0)) \
			+ lerpf(0.0, 0.3, clampf((t - 2.5) / 1.0, 0.0, 1.0)) \
			- lerpf(0.0, 0.58, clampf((t - 4.5) / 1.0, 0.0, 1.0))
	var forward := SimulatedRig.HAND_REST.z - reach
	for left: bool in [true, false]:
		var x := -SimulatedRig.HAND_REST.x if left else SimulatedRig.HAND_REST.x
		_set_hand(left, Vector3(x, 1.4, forward))
	return false


## Reaches the right palm over the table (top at 1.0 m) by 1.5 s, presses it
## 0.3 m below where it rests on the tabletop by 2.5 s, holds, and lifts it by
## 4 s.
func _drive_table_press(t: float) -> bool:
	var over := clampf((t - 0.5) / 1.0, 0.0, 1.0)
	var press := clampf((t - 1.5) / 1.0, 0.0, 1.0) - clampf((t - 3.5) / 0.5, 0.0, 1.0)
	_place_palm(false, Vector3(0.145, _palm_rest() + 0.055 - 0.35 * press, lerpf(-0.2, -0.5, over)))
	return false


## Head lowered a little over the table; both palms over its near edge press
## 0.275 m below where they rest on the tabletop by 1.5 s, hold, 0.395 m by
## 3.5 s, hold, and lift off by 5.5 s. Deep enough, two hands lift the body.
func _drive_vault(t: float) -> bool:
	_rig.head_position = Vector3(0.0, 1.45, 0.0)
	var down := _palm_rest() + lerpf(0.055, -0.275, clampf((t - 0.5) / 1.0, 0.0, 1.0)) \
			- lerpf(0.0, 0.12, clampf((t - 2.5) / 1.0, 0.0, 1.0)) \
			+ lerpf(0.0, 0.45, clampf((t - 4.5) / 1.0, 0.0, 1.0))
	_place_palm(true, Vector3(-0.225, down, -0.32))
	_place_palm(false, Vector3(0.225, down, -0.32))
	return false


## The right palm rests on the tabletop (1.0 m) by 1.5 s, held 1 cm into it,
## slides 0.2 m to the right and back by 4 s, then presses 4 cm further in and
## pulls 0.1 m back toward the body by 6 s, and lifts. All within reach.
func _drive_palm_slide(t: float) -> bool:
	var reach := clampf((t - 0.5) / 1.0, 0.0, 1.0)
	var slide := 0.2 * (clampf((t - 1.5) / 1.0, 0.0, 1.0) - clampf((t - 3.0) / 1.0, 0.0, 1.0))
	var press := 0.04 * clampf((t - 4.0) / 0.5, 0.0, 1.0)
	var pull := 0.1 * clampf((t - 4.5) / 1.5, 0.0, 1.0)
	var lift := 0.2 * clampf((t - 6.2) / 0.5, 0.0, 1.0)
	var top := _palm_rest() - 0.01
	var palm := Vector3(-0.05 + slide, lerpf(1.15, top, reach) - press + lift,
			lerpf(-0.25, -0.47, reach) + pull)
	_place_palm(false, palm)
	return false


## Both hands close fully (grip and trigger) by 0.8 s and open by 1.8 s; make
## fists with the index out (grip only) from 2.5 s to 3.8 s; then close only
## the index (trigger only) from 4.5 s to 5.8 s. Each pose is held long
## enough to settle.
func _drive_fingers_curl(t: float) -> bool:
	var both := clampf((t - 0.5) / 0.3, 0.0, 1.0) - clampf((t - 1.5) / 0.3, 0.0, 1.0)
	var fist := clampf((t - 2.5) / 0.3, 0.0, 1.0) - clampf((t - 3.5) / 0.3, 0.0, 1.0)
	var point := clampf((t - 4.5) / 0.3, 0.0, 1.0) - clampf((t - 5.5) / 0.3, 0.0, 1.0)
	var grip := maxf(both, fist)
	var trigger := maxf(both, point)
	_rig.left_grip = grip
	_rig.right_grip = grip
	_rig.left_trigger = trigger
	_rig.right_trigger = trigger
	return false


## An open right palm reaches forward and comes down flat on the table (top
## at 1.0 m, its near edge 0.4 m ahead) by 1.5 s,
## presses 5 cm below where it would rest until 3.5 s, and lifts by 4.5 s.
## Tracks how far any finger bone sinks into the tabletop.
func _drive_fingers_table(t: float) -> bool:
	var down := clampf((t - 0.5) / 1.0, 0.0, 1.0)
	var press := clampf((t - 1.5) / 0.5, 0.0, 1.0) - clampf((t - 3.5) / 0.5, 0.0, 1.0)
	var lift := 0.15 * clampf((t - 4.0) / 0.5, 0.0, 1.0)
	_place_palm(false, Vector3(0.0, _palm_rest() + 0.1 * (1.0 - down) - 0.05 * press + lift,
			lerpf(-0.25, -0.5, down)))
	_track_finger_sink(Plane(Vector3.UP, 1.0), TABLE_TOP,
			t >= 2.0 and t <= 3.5)
	return false


## The right palm hovers flat 4 cm above the table by 1.5 s; grip and trigger
## close by 2.3 s, curling the fingers down onto the tabletop, and stay closed;
## the hand lifts 0.15 m clear between 3.5 s and 4 s. Tracks how far any
## finger bone sinks into the tabletop.
func _drive_fingers_close_on_table(t: float) -> bool:
	var reach := clampf((t - 0.5) / 1.0, 0.0, 1.0)
	var close := clampf((t - 2.0) / 0.3, 0.0, 1.0)
	var lift := 0.15 * clampf((t - 3.5) / 0.5, 0.0, 1.0)
	_place_palm(false, Vector3(0.0, lerpf(1.15, _palm_rest() + 0.04, reach) + lift, lerpf(-0.25, -0.5, reach)))
	_rig.right_grip = close
	_rig.right_trigger = close
	_track_finger_sink(Plane(Vector3.UP, 1.0), TABLE_TOP,
			t >= 2.3 and t <= 3.5)
	return false


## The right palm comes flat against the table's front face (x 0.75), its
## knuckles 1.5 cm above the top edge and the hand tilted 20° about the palm,
## by 1.5 s; grip and trigger close by 2.3 s and stay closed, wrapping the
## fingers over the edge onto the tabletop, each where it meets it.
func _drive_fingers_wrap_edge(t: float) -> bool:
	var reach := clampf((t - 0.5) / 1.0, 0.0, 1.0)
	var close := clampf((t - 2.0) / 0.3, 0.0, 1.0)
	var height := 1.0 - _palm_front() + 0.015
	_place_palm(false, Vector3(0.0, height, lerpf(-0.25, -(0.4 - _palm_half_thickness()), reach)))
	_rig.right_grip = close
	_rig.right_trigger = close
	_track_fingers(t >= 2.8 and t <= 4.5)
	return false


## The right palm comes down flat on the light box (10 cm, 2 kg, top at
## 1.10 m, far face at x 1.05) by 1.5 s, its knuckles 2 cm short of the far
## edge and its middle finger over the box's side, so the ring and little
## fingers close on air while the others close over the edge; grip and
## trigger close by 2.3 s and stay closed.
func _drive_fingers_grip_box(t: float) -> bool:
	var reach := clampf((t - 0.5) / 1.0, 0.0, 1.0)
	var close := clampf((t - 2.0) / 0.3, 0.0, 1.0)
	var top := 1.10 + _palm_half_thickness() + 0.002
	# About the fingers, not grabbing: the boxes are not grabbable here.
	for box: String in ["LightBox", "MediumBox", "HeavyBox"]:
		Grabbable.of(_level.get_node("Dynamic/" + box)).enabled = false
	_place_palm(false, Vector3(0.0, lerpf(top + 0.08, top, reach), lerpf(-0.25, -(1.03 - 0.45 - _palm_front()), reach)))
	_rig.right_grip = close
	_rig.right_trigger = close
	_track_fingers(t >= 2.8 and t <= 4.5)
	if not _scenario_state.has("box_start"):
		_scenario_state.box_start = (_level.get_node("Dynamic/LightBox") as Node3D).global_position
	_scenario_state.box_moved = (_level.get_node("Dynamic/LightBox") as Node3D).global_position \
			.distance_to(_scenario_state.box_start)
	return false


## Standing at the table's edge, the right palm, facing ahead with the fingers
## up, comes to the light box's near face (x 0.95, the box 10 cm, 2 kg,
## centred at 1.05 m) at its centre height by 1 s, then pushes on through
## 0.2 m more by 3 s and holds, the head leaning 0.15 m out over the table
## to reach, as a player would.
func _drive_palm_push_box(t: float) -> bool:
	var reach := clampf((t - 0.5) / 0.5, 0.0, 1.0)
	var push := clampf((t - 1.0) / 2.0, 0.0, 1.0)
	_rig.head_position = Vector3(0.0, SimulatedRig.HEAD_HEIGHT, -0.15 * push)
	var face := 0.95 - 0.65 - _palm_half_thickness()
	_place_palm(false, Vector3(0.0, 1.05, -(lerpf(0.15, face, reach) + 0.2 * push)))
	var box := _level.get_node("Dynamic/LightBox") as RigidBody3D
	_track_prop(box, t)
	_track_palm_depth(t >= 1.0)
	return false


## A crate (0.4 m, 8 kg, on the Dynamic layer and mask the level's props use)
## sits on the floor 0.6 m ahead; the stick walks the body into it at full
## speed from 0.5 s to 3.5 s.
func _drive_walk_push_crate(t: float) -> bool:
	if not _scenario_state.has("crate"):
		_scenario_state.crate = _spawn_prop(Vector3(0.4, 0.4, 0.4), 8.0, Vector3(-2.0, 0.2, 0.2))
	_rig.stick = Vector2(0.0, 1.0) if t >= 0.5 and t < 3.5 else Vector2.ZERO
	_track_prop(_scenario_state.crate, t)
	return false


## A 12 cm, 1 kg box sits on the floor 0.8 m ahead, 0.18 m to the right, in
## line with the right foot and clear of the capsule's middle; the stick walks
## the body past it from 0.3 s to 2 s. Counts which of the player's shapes push
## it: the legs are on their own kinematic body, switched off, so none of
## them should.
func _drive_walk_kick_box(t: float) -> bool:
	if not _scenario_state.has("kicked"):
		var box := _spawn_prop(Vector3(0.12, 0.12, 0.12), 1.0, Vector3(-1.82, 0.06, 0.3))
		box.contact_monitor = true
		box.max_contacts_reported = 8
		_scenario_state.crate = box
		_scenario_state.kicked = {}
	_rig.stick = Vector2(0.0, 1.0) if t > 0.3 and t < 2.0 else Vector2.ZERO
	var box: RigidBody3D = _scenario_state.crate
	_track_prop(box, t)
	var contacts := PhysicsServer3D.body_get_direct_state(box.get_rid())
	for i in contacts.get_contact_count():
		var other := contacts.get_contact_collider_object(i) as CollisionObject3D
		if other == null or contacts.get_contact_impulse(i).length() <= 0.0005:
			continue
		var holder := other.shape_owner_get_owner(other.shape_find_owner(contacts.get_contact_collider_shape(i)))
		var part := "%s/%s" % [other.name, holder.name]
		_scenario_state.kicked[part] = _scenario_state.kicked.get(part, 0) + 1
	return false


## Standing at the table's edge, the palms turn to face each other, fingers
## ahead, and close on the sides of a box on the tabletop (20 cm, 5 kg, centred
## at 1.0, 1.1, 0.3, clear of the other boxes) by 1.2 s, squeeze 1.5 cm into it
## by 1.6 s, lift it 0.15 m by 2.8 s, hold it until 4 s and let it go. No grip:
## only the palms' push and friction hold it, and the wrists must hold the
## palms flat against its weight. Tracks the box's rise and tilt and each
## hand's turn from its target.
func _drive_palms_lift_box(t: float) -> bool:
	if not _scenario_state.has("crate"):
		_turn_palm(true, Vector3.RIGHT, Vector3.FORWARD)
		_turn_palm(false, Vector3.LEFT, Vector3.FORWARD)
		_scenario_state.crate = _spawn_prop(Vector3(0.2, 0.2, 0.2), 5.0, Vector3(1.0, 1.1, 0.3))
	var close := clampf((t - 0.5) / 0.7, 0.0, 1.0)
	var squeeze := 0.015 * clampf((t - 1.2) / 0.4, 0.0, 1.0) - 0.08 * clampf((t - 4.0) / 0.3, 0.0, 1.0)
	var lift := 0.15 * smoothstep(1.8, 2.8, t)
	_rig.head_position = Vector3(0.0, SimulatedRig.HEAD_HEIGHT, -0.1 * close)
	var side := 0.1 + _palm_half_thickness() + 0.08 * (1.0 - close) - squeeze
	for left: bool in [true, false]:
		_place_palm(left, Vector3(-side if left else side, 1.1 + lift, -0.35))
	var box: RigidBody3D = _scenario_state.crate
	_track_prop(box, t)
	if t >= 2.8 and t <= 4.0:
		var physical := _player.physical as DynamicPhysical
		var turned := 0.0
		for drive: HandDrive in [physical.left_drive, physical.right_drive]:
			turned = maxf(turned, (drive.target.basis.orthonormalized()
					* drive.hand.global_basis.orthonormalized().inverse()).get_rotation_quaternion().get_angle())
		_scenario_state.wrist_turn = maxf(_scenario_state.get("wrist_turn", 0.0), rad_to_deg(turned))
		var rise: float = box.global_position.y - (_scenario_state.prop_start as Vector3).y
		_scenario_state.held_rise_min = minf(_scenario_state.get("held_rise_min", INF), rise)
		_scenario_state.held_rise_max = maxf(_scenario_state.get("held_rise_max", -INF), rise)
		_scenario_state.box_tilt = maxf(_scenario_state.get("box_tilt", 0.0),
				rad_to_deg(box.global_basis.y.angle_to(Vector3.UP)))
	return false


## The right palm comes flat 4 cm above the light box (top at 1.10 m), 2 cm
## short of its centre so the open fingers' slight curl clears its far edge,
## by 1.2 s; the grip closes at 1.5 s, pulling the box up into the palm; the
## hand lifts 0.2 m by 3 s and holds until 4 s, when the grip opens and the box
## drops.
func _drive_grab_lift_box(t: float) -> bool:
	var reach := clampf((t - 0.5) / 0.7, 0.0, 1.0)
	var lift := 0.2 * smoothstep(2.0, 3.0, t)
	var above := 1.10 + _palm_half_thickness() + 0.04
	_place_palm(false, Vector3(0.0, lerpf(above + 0.1, above, reach) + lift, lerpf(-0.2, -0.33, reach)))
	_rig.right_grip = 1.0 if t >= 1.5 and t < 4.0 else 0.0
	_track_grab(_level.get_node("Dynamic/LightBox") as RigidBody3D, t)
	return false


## Runs `tick` every physics tick after the hands' drives (HandDrive runs at
## SOLVE_PRIORITY + 5), so what it reads is what the frame draws: a seating
## object where HandGrab has just placed it, beside the hand where the last
## step left it. The scenario's own tick runs before either.
class AfterHands extends Node:
	var tick: Callable

	func _ready() -> void:
		process_physics_priority = StaticSkeleton.SOLVE_PRIORITY + 6

	func _physics_process(_delta: float) -> void:
		tick.call()


## The right palm sweeps toward the player's right 4 cm over the scenario's
## object (its "weapon"'s handle, else the light box) at "speed" m/s, the grip
## closing at 1.5 s as the palm passes over its middle (_sweep: at speed from
## 0.06 s before to 0.1 s after, easing in and out over 0.06 s); "roll" rad/s,
## the controller also rolls about the fingers, thumb up, on the same profile.
## It then lifts 0.2 m by 2.5 s, holds, and lets go at 3.5 s. With the box,
## the other boxes are taken off the table first: the sweep carries the box
## over where they lie. How the grab brings the object in, as drawn:
## _track_seat.
func _drive_grab_moving(t: float) -> bool:
	var scenario := _scenarios[_index]
	var speed: float = scenario.speed
	if not _scenario_state.has("object"):
		var object := _level.get_node(scenario.get("weapon", ^"Dynamic/LightBox") as NodePath) as RigidBody3D
		_scenario_state.object = object
		var over := object.global_position
		var top := 1.10
		if scenario.has("weapon"):
			var grip := object.get_node("Grip") as CollisionShape3D
			var size := (grip.shape as BoxShape3D).size if grip.shape is BoxShape3D \
					else Grabbable.handle_extent(grip.shape) * 2.0
			over = grip.global_position
			top = (grip.global_transform * AABB(-size * 0.5, size)).end.y
		else:
			for other: String in ["MediumBox", "HeavyBox"]:
				var box := _level.get_node_or_null("Dynamic/" + other)
				if box != null:
					box.get_parent().remove_child(box)
					box.queue_free()
		# Facing +X, the head's forward (-Z) is the level's +X and its right the level's +Z.
		var start: Vector3 = scenario.start
		_scenario_state.over = Vector3(over.z - start.z, top + _palm_half_thickness() + 0.04, -(over.x - start.x))
		var probe := AfterHands.new()
		probe.tick = func() -> void: _track_seat(object, 1.5)
		_level.add_child(probe)
	if scenario.get("left_aside", false):
		_rig.left_hand = Vector3(-SIDE_HAND.x, SIDE_HAND.y, SIDE_HAND.z)
	var swept := _sweep(t, 1.5)
	var roll: float = scenario.get("roll", 0.0)
	_rig.right_hand_turn = Basis(Vector3.FORWARD, roll * swept) * _palm_turn(false, PALMS_DOWN[0], PALMS_DOWN[1])
	var over: Vector3 = _scenario_state.over
	var reach := clampf((t - 0.5) / 0.7, 0.0, 1.0)
	var lift := 0.2 * smoothstep(2.0, 2.5, t)
	_place_palm(false, Vector3(over.x + speed * swept, lerpf(over.y + 0.1, over.y, reach) + lift, over.z))
	_rig.right_grip = 1.0 if t >= 1.5 and t < 3.5 else 0.0
	_track_grab(_scenario_state.object as RigidBody3D, t)
	return false


## How far a sweep at 1 m/s has gone at `t`, 0 at `at`: easing in over 0.06 s
## (smoothstep speed), at full speed from 0.06 s before `at` to 0.1 s after,
## easing out over 0.06 s.
static func _sweep(t: float, at: float) -> float:
	const RAMP := 0.06
	var start := at - 0.06 - RAMP
	var stop := at + 0.1
	var into := clampf((t - start) / RAMP, 0.0, 1.0)
	var out := clampf((t - stop) / RAMP, 0.0, 1.0)
	var eased_in := RAMP * (pow(into, 3.0) - 0.5 * pow(into, 4.0))
	var cruise := clampf(t - (start + RAMP), 0.0, stop - (start + RAMP))
	var eased_out := RAMP * (out - (pow(out, 3.0) - 0.5 * pow(out, 4.0)))
	return eased_in + cruise + eased_out - (0.5 * RAMP + 0.06)


## Grips the light box as _drive_grab_lift_box, without lifting; lets go at
## 2.0 s and grips again two ticks later, while the hand still overlaps it;
## lets go at 3.0 s and lifts the hand 0.2 m away by 3.8 s. Records the box's
## layer and mask at the start and at the end ("regrab").
func _drive_grab_regrab(t: float) -> bool:
	var box := _level.get_node("Dynamic/LightBox") as RigidBody3D
	var regrab: Dictionary = _scenario_state.get("regrab", {"start": [box.collision_layer, box.collision_mask]})
	var reach := clampf((t - 0.5) / 0.7, 0.0, 1.0)
	var away := 0.2 * smoothstep(3.2, 3.8, t)
	var above := 1.10 + _palm_half_thickness() + 0.04
	_place_palm(false, Vector3(0.0, lerpf(above + 0.1, above, reach) + away, lerpf(-0.2, -0.33, reach)))
	var gripped := (t >= 1.5 and t < 2.0) or (t >= 2.0 + 2.5 / Engine.physics_ticks_per_second and t < 3.0)
	_rig.right_grip = 1.0 if gripped else 0.0
	regrab.end = [box.collision_layer, box.collision_mask]
	_scenario_state.regrab = regrab
	_track_prop(box, t)
	return false


## How the right hand's grab brings `object` in, as drawn (AfterHands), into
## _scenario_state.seat, from the tick the grab begins (the grip closing at
## `grip`):
## - gaps: the distance between the object's grab point and the hand's, in
##   the hand's own space, each tick for 0.5 s (mm);
## - lock_ticks / lock_time: from the grab to the first tick held;
## - gap_at: that distance 0.083, 0.15 and 0.25 s after the grab (mm);
## - path_error: the most the distances before the lock differ from a grab
##   point moving in on 1 - (1 - s)³ over seat_time (0.08 s if HandGrab has
##   none), from where the first tick drew it (mm);
## - lock_jump: how far the object moved in the hand from the tick before the
##   lock to the lock (mm, °);
## - held_drift: the most it moved in the hand from the lock while held, up to
##   0.5 s after the grab (mm, °);
## - let_go_at: when the hand let it go, if it did; held_at_end: whether it
##   was still held 1.9 s after the grip closed.
func _track_seat(object: RigidBody3D, grip: float) -> void:
	var physical := _player.physical as DynamicPhysical
	var grab := physical.right_grab
	var hand := physical.right_drive.hand
	var s: Dictionary = _scenario_state.get("seat", {"gaps": [], "turns": []})
	var dt := 1.0 / Engine.physics_ticks_per_second
	var mine := grab.state != HandGrab.State.IDLE and grab.target == object
	if _t >= grip + 1.9 and not s.has("held_at_end"):
		s.held_at_end = mine and grab.state == HandGrab.State.HOLDING
	if not mine:
		if s.has("grabbed_at") and not s.has("let_go_at"):
			s.let_go_at = _t
		_scenario_state.seat = s
		return
	if not s.has("grabbed_at"):
		s.grabbed_at = _t
		s.seat_time = grab.get("seat_time") if grab.get("seat_time") != null else 0.08
		_scenario_state.seat_poses = []
	var poses: Array = _scenario_state.seat_poses
	var rel := hand.global_transform.orthonormalized().affine_inverse() * object.global_transform.orthonormalized()
	if poses.size() < roundi(0.5 / dt):
		poses.append(rel)
		s.gaps.append((rel * grab._grip_point).distance_to(grab._hold_point) * 1000.0)
		if grab.state == HandGrab.State.HOLDING and not s.has("lock_ticks"):
			s.lock_ticks = poses.size() - 1
			s.lock_time = s.lock_ticks * dt
		if poses.size() == roundi(0.5 / dt):
			_summarise_seat(s, poses, dt)
	_scenario_state.seat = s


## The summary figures of _track_seat from the poses it drew.
static func _summarise_seat(s: Dictionary, poses: Array, dt: float) -> void:
	var gaps: Array = s.gaps
	s.gap_at = [gaps[mini(roundi(0.083 / dt), gaps.size() - 1)], gaps[mini(roundi(0.15 / dt), gaps.size() - 1)],
			gaps[mini(roundi(0.25 / dt), gaps.size() - 1)]]
	var seat_time: float = s.seat_time
	var first: float = gaps[0]
	var eased_first := 1.0 - pow(1.0 - minf(dt / seat_time, 1.0), 3.0)
	var error := 0.0
	for k in s.get("lock_ticks", gaps.size()):
		var eased := 1.0 - pow(1.0 - minf((k + 1) * dt / seat_time, 1.0), 3.0)
		var wanted := first * (1.0 - eased) / maxf(1.0 - eased_first, 1e-6)
		error = maxf(error, absf((gaps[k] as float) - wanted))
	s.path_error = error
	if not s.has("lock_ticks"):
		return
	var lock: int = s.lock_ticks
	var at_lock: Transform3D = poses[lock]
	var turns: Array = []
	for pose: Transform3D in poses:
		turns.append(rad_to_deg(_turn_between(pose.basis, at_lock.basis)))
	s.turns = turns
	if lock > 0:
		var before: Transform3D = poses[lock - 1]
		s.lock_jump = [before.origin.distance_to(at_lock.origin) * 1000.0,
				rad_to_deg(_turn_between(before.basis, at_lock.basis))]
	var drift := [0.0, 0.0]
	for k in range(lock, poses.size()):
		var pose: Transform3D = poses[k]
		drift[0] = maxf(drift[0], pose.origin.distance_to(at_lock.origin) * 1000.0)
		drift[1] = maxf(drift[1], rad_to_deg(_turn_between(pose.basis, at_lock.basis)))
	s.held_drift = drift


## As _drive_grab_lift_box, over the middle of the scenario's weapon's handle
## (its Grip collider) where the weapon lies on the table: fingers across the
## handle, 4 cm above it by 1.2 s; the grip closes at 1.5 s; the hand lifts
## 0.2 m by 3 s and holds until 4 s, when the grip opens and the weapon drops.
## Records whether the grab point was on the handle, and how the hand holds
## the handle (_track_handle). Optional keys: "turn" [degrees about the
## palm's normal, degrees about the fingers] turns the right controller from
## palms down, eased in over the first 0.5 s (positive rolls the thumb up);
## "from_end" puts the palm that far along the handle from its pommel (-Y)
## end instead of over its middle (less than 0 beyond it); "cylinder"
## [radius, height, mass] grabs a code-built prop instead of a level weapon
## (_spawn_handle_cylinder); "left_aside" keeps the free left controller at
## the body's side.
func _drive_grab_weapon(t: float) -> bool:
	var scenario := _scenarios[_index]
	if scenario.has("cylinder") and not _scenario_state.has("cylinder"):
		_scenario_state.cylinder = _spawn_handle_cylinder(scenario.cylinder)
	var weapon: RigidBody3D = _scenario_state.cylinder if scenario.has("cylinder") \
			else _level.get_node(scenario.weapon as NodePath) as RigidBody3D
	var grip := weapon.get_node("Grip") as CollisionShape3D
	var size := (grip.shape as BoxShape3D).size if grip.shape is BoxShape3D \
			else Grabbable.handle_extent(grip.shape) * 2.0
	if not _scenario_state.has("handle"):
		var top := (grip.global_transform * AABB(-size * 0.5, size)).end.y
		var middle := grip.global_position
		if scenario.has("from_end"):
			middle = grip.global_transform * Vector3(0.0, (scenario.from_end as float) - size.y * 0.5, 0.0)
		_scenario_state.handle = Vector3(middle.x, top, middle.z)
	if scenario.get("left_aside", false):
		_rig.left_hand = Vector3(-SIDE_HAND.x, SIDE_HAND.y, SIDE_HAND.z)
	if scenario.has("turn"):
		var turn: Array = scenario.turn
		var eased := smoothstep(0.0, 0.5, t)
		_rig.right_hand_turn = Basis(Vector3.UP, deg_to_rad(turn[0]) * eased) \
				* Basis(Vector3.FORWARD, deg_to_rad(turn[1]) * eased) * _palm_turn(false, PALMS_DOWN[0], PALMS_DOWN[1])
	var handle: Vector3 = _scenario_state.handle
	var start: Vector3 = scenario.start
	var reach := clampf((t - 0.5) / 0.7, 0.0, 1.0)
	var lift := 0.2 * smoothstep(2.0, 3.0, t)
	var above := handle.y + _palm_half_thickness() + 0.04
	# Facing +X, the head's forward (-Z) is the level's +X and its right the level's +Z.
	var ahead := handle.x - start.x
	_place_palm(false, Vector3(handle.z - start.z, lerpf(above + 0.1, above, reach) + lift,
			-lerpf(ahead - 0.13, ahead, reach)))
	_rig.right_grip = 1.0 if t >= 1.5 and t < 4.0 else 0.0
	_track_grab(weapon, t)
	var hand_grab := (_player.physical as DynamicPhysical).right_grab
	if hand_grab.state != HandGrab.State.IDLE and not _scenario_state.has("grab_on_handle"):
		# The grab point in the weapon's own space: it may already be moving.
		var point := hand_grab._grip_point
		# Within 0.1 mm: the guard stands 0.5 mm prouder than the grip beside it.
		_scenario_state.grab_on_handle = (grip.transform * AABB(-size * 0.5, size)).grow(0.0001).has_point(point)
	_track_handle(false, weapon)
	if scenario.get("in_the_way", false) and t <= 3.0:
		# As the seat begins, a box on the table where it will put the blade's
		# middle; how far the box moves until the weapon is lifted clear.
		if int(hand_grab.state) == 1 and not _scenario_state.has("in_the_way"):
			var seated := hand_grab.drive.hand.global_transform.orthonormalized() * hand_grab._seat
			var blade := seated * (weapon.get_node("Blade") as Node3D).transform.origin
			_scenario_state.in_the_way = _spawn_prop(Vector3(0.06, 0.06, 0.06), 0.3, Vector3(blade.x, 1.0305, blade.z))
			_scenario_state.in_the_way_from = (_scenario_state.in_the_way as Node3D).global_position
		if _scenario_state.has("in_the_way"):
			var box: Node3D = _scenario_state.in_the_way
			_scenario_state.neighbour_moved = maxf(_scenario_state.get("neighbour_moved", 0.0),
					box.global_position.distance_to(_scenario_state.in_the_way_from))
	return false


## A code-built grabbable that is not a weapon, for the handle scenarios: a
## cylinder of [radius, height, mass], the whole of it its Grabbable's handle
## (set before the Grabbable enters the tree), lying on the table where the
## sword lies, along the level's Z with its Y toward -Z, as the sword's.
func _spawn_handle_cylinder(spec: Array) -> RigidBody3D:
	var prop := RigidBody3D.new()
	prop.mass = spec[2]
	prop.collision_layer = PROP_LAYER
	prop.collision_mask = PROP_MASK
	var holder := CollisionShape3D.new()
	holder.name = "Grip"
	var cylinder := CylinderShape3D.new()
	cylinder.radius = spec[0]
	cylinder.height = spec[1]
	holder.shape = cylinder
	prop.add_child(holder)
	var grabbable := Grabbable.new()
	var handles: Array[CollisionShape3D] = [holder]
	grabbable.handles = handles
	prop.add_child(grabbable)
	_level.add_child(prop)
	prop.global_transform = Transform3D(Basis(Vector3.RIGHT, Vector3.FORWARD, Vector3.UP),
			Vector3(0.93, 1.0 + cylinder.radius, 0.55))
	return prop


## How a hand (`left` or the right) holds `object` by a handle, from geometry,
## into _scenario_state.handle_grab. A handle's Y runs along it and its Z
## across it toward the palm; the hand's Y is the fist's grip (toward the
## thumb), and its palm faces along the skeleton's palm_direction.
## - At the grab: on_handle, whether the grab point (object_point) lay on a
##   handle's centre line (line_off, within 0.5 mm) and within its length
##   (along_grab from its middle).
## - At the lock (the first tick HOLDING): lock_axis, the angle between the
##   hand's Y and the handle's, either way along it; toward, +1 with the
##   handle's +Y toward the thumb, -1 toward the little finger; lock_palm, the
##   angle between the palm's normal and the handle's Z, either way; along,
##   the fist's centre line (hand_point) along the handle from its middle, and
##   lock_line, how far off the handle's centre line; along_grip, where the
##   grab point is along it; reach, how far along it the fist may hold it (its
##   half length less half the palm's width) and half, its half length.
## - While seating: pull_time to the lock (and the grab's seat_time),
##   pull_turn_error the wrist's largest turn off its target (°), and
##   pull_rebound how far it turned back off its seat (°).
## - solid_at: when it first met what a held object meets, held.
## - While held: held_axis and held_palm, the largest; flipped, ticks whose
##   toward differed from the lock's.
## - While idle, when the controller's grip closes: along_at_grip, where the
##   palm's grab point lies along the nearest handle, and reach_at_grip, how
##   far each of the object's box shapes is outside the grab area (the ball
##   HandGrab searches; below 0 inside it); candidate_ticks, ticks the hand
##   had the object as its candidate.
## HandGrab works out its points before each physics step and this reads
## after it, so they are compared with where the handle was a tick before.
func _track_handle(left: bool, object: RigidBody3D) -> void:
	var physical := _player.physical as DynamicPhysical
	var grab := physical.left_grab if left else physical.right_grab
	var drive := physical.left_drive if left else physical.right_drive
	var hand := drive.hand
	var handles := Grabbable.of(object).handles
	var now: Array[Transform3D] = []
	for holder in handles:
		now.append(holder.global_transform.orthonormalized())
	var before: Array = _scenario_state.get("handle_before", now)
	_scenario_state.handle_before = now
	var h: Dictionary = _scenario_state.get("handle_grab", {"grab_forward": grab.grab_forward, "grabbed": false, "on_handle": false,
			"candidate_ticks": 0, "pull_ticks": 0, "pull_time": 0.0, "pull_turn_error": 0.0,
			"held_ticks": 0, "held_axis": 0.0, "held_palm": 0.0, "flipped": 0})
	if grab.state == HandGrab.State.IDLE:
		if grab.target == object:
			h.candidate_ticks += 1
		var gripped: float = _rig.left_grip if left else _rig.right_grip
		if gripped >= grab.grab_grip and not h.has("reach_at_grip") and not handles.is_empty():
			var palm := _palm_side(left)
			var face := drive.palm_size.x * _player.rig.skeleton.hand_scale * 0.5
			var point := hand.global_transform * (palm * (face - grab.grab_depth)
					+ Vector3.FORWARD * grab.grab_forward * _player.rig.skeleton.hand_scale)
			var ball := point + hand.global_basis.orthonormalized() * palm * grab.grab_reach
			var nearest := _nearest_handle(now, point)
			h.along_at_grip = (now[nearest].affine_inverse() * point).y
			h.half = Grabbable.handle_extent(handles[nearest].shape).y
			var reach := {}
			for child in object.get_children():
				var shape := child as CollisionShape3D
				if shape != null and shape.shape is BoxShape3D:
					var frame := shape.global_transform.orthonormalized()
					var half := (shape.shape as BoxShape3D).size * 0.5
					var local := frame.affine_inverse() * ball
					reach[String(shape.name)] = (frame * local.clamp(-half, half)).distance_to(ball) - grab.grab_radius
			h.reach_at_grip = reach
	elif grab.target == object and not handles.is_empty():
		if not h.grabbed:
			h.grabbed = true
			var index := _nearest_handle(before, grab.object_point)
			var local: Vector3 = (before[index] as Transform3D).affine_inverse() * grab.object_point
			h.index = index
			h.line_off = Vector2(local.x, local.z).length()
			h.along_grab = local.y
			h.half = Grabbable.handle_extent(handles[index].shape).y
			h.on_handle = h.line_off <= 0.0005 and absf(local.y) <= h.half + 0.0001
		var index: int = h.index
		var seat := _handle_seat(left, hand, handles[index])
		if grab.state == HandGrab.State.SEATING:
			h.pull_ticks += 1
			h.pull_time = h.pull_ticks / float(Engine.physics_ticks_per_second)
			h.seat_time = grab.seat_time
			var error := (drive.target.basis.orthonormalized()
					* hand.global_basis.orthonormalized().inverse()).get_rotation_quaternion().get_angle()
			h.pull_turn_error = maxf(h.pull_turn_error, rad_to_deg(error))
			# Swinging past the seat: how far the fist's grip line and the palm's
			# side turn back off the handle's after they came nearest, once the
			# turn has come halfway in (before that, a sag as the pull starts is
			# not a swing past it).
			for key: String in ["x", "y"]:
				var off: float = seat[key]
				var peak := maxf(h.get("pull_peak_" + key, 0.0), off)
				h["pull_peak_" + key] = peak
				if off <= peak * 0.5:
					var least := minf(h.get("pull_least_" + key, 180.0), off)
					h["pull_least_" + key] = least
					h.pull_rebound = maxf(h.get("pull_rebound", 0.0), off - least)
		else:
			if Grabbable.of(object).solid and not h.has("solid_at"):
				h.solid_at = _t
			if not h.has("lock_axis"):
				var fist: Vector3 = (before[index] as Transform3D).affine_inverse() * grab.hand_point
				h.lock_axis = seat.x
				h.lock_palm = seat.y
				h.toward = int(seat.z)
				h.along = fist.y
				h.lock_line = Vector2(fist.x, fist.z).length()
				h.along_grip = ((before[index] as Transform3D).affine_inverse() * grab.object_point).y
				h.reach = maxf(h.half - drive.palm_size.y * _player.rig.skeleton.hand_scale * 0.5, 0.0)
			h.held_ticks += 1
			h.held_axis = maxf(h.held_axis, seat.x)
			h.held_palm = maxf(h.held_palm, seat.y)
			if int(seat.z) != h.toward:
				h.flipped += 1
	_scenario_state.handle_grab = h


## How a hand (`left` or the right) sits on `holder`, a handle, in degrees: x
## the angle between the fist's grip (the hand's Y, toward the thumb, leaned
## toward the fingers by the object's handle_lean) and the handle's Y, either
## way along it; y the angle between the palm's normal and
## the handle's Z, either way; z +1 with the handle's +Y toward the thumb, -1
## toward the little finger.
func _handle_seat(left: bool, hand: RigidBody3D, holder: CollisionShape3D) -> Vector3:
	var basis := hand.global_basis.orthonormalized()
	var handle := holder.global_basis.orthonormalized()
	# The fist's grip leaned toward the fingers by the object's handle_lean.
	var grip := basis * Vector3.UP.rotated(Vector3.LEFT, Grabbable.of(holder.get_parent()).handle_lean)
	return Vector3(_line_angle(grip, handle.y), _line_angle(basis * _palm_side(left), handle.z),
			signf(grip.dot(handle.y)))


## Which way a palm faces in its hand's own space, as HandGrab has it.
func _palm_side(left: bool) -> Vector3:
	var palm := _player.rig.skeleton.palm_direction.normalized()
	if left:
		palm.x = -palm.x
	return palm


## The handle, of those at `frames`, whose centre line passes nearest `point`.
static func _nearest_handle(frames: Array, point: Vector3) -> int:
	var nearest := 0
	var best := INF
	for i in frames.size():
		var local: Vector3 = (frames[i] as Transform3D).affine_inverse() * point
		var off := Vector2(local.x, local.z).length()
		if off < best:
			best = off
			nearest = i
	return nearest


## The angle between two directions, either way along a line, in degrees;
## precise for small ones.
static func _line_angle(a: Vector3, b: Vector3) -> float:
	var x := a.normalized()
	var y := b.normalized()
	return rad_to_deg(atan2(x.cross(y).length(), absf(x.dot(y))))


## The table's weapons left alone: the most each moves and turns from where the
## level lays it, and how deep a corner of its colliders goes into the tabletop.
func _drive_weapons_rest(_t: float) -> bool:
	var rest: Dictionary = _scenario_state.get("weapon_rest", {})
	for path in _kept(_scenarios[_index], "weapons", WEAPONS):
		var weapon := _level.get_node(path) as RigidBody3D
		var weapon_name := String(weapon.name)
		var from: Transform3D = _scenario_state["placed_" + weapon_name]
		var entry: Dictionary = rest.get(weapon_name, {"moved": 0.0, "turned": 0.0, "sink": 0.0})
		var turned := (from.basis.inverse() * weapon.global_basis).get_rotation_quaternion().get_angle()
		entry.moved = maxf(entry.moved, weapon.global_position.distance_to(from.origin))
		entry.turned = maxf(entry.turned, rad_to_deg(turned))
		entry.sink = maxf(entry.sink, _table_sink(weapon))
		rest[weapon_name] = entry
	_scenario_state.weapon_rest = rest
	return false


## Presses B at 0.5 s and again at 1.5 s, and checks the static skeleton's
## drawing is shown before, hidden between (from 0.7 s) and shown after (from
## 1.7 s). Standing still from 2.5 s, compares the physical layer's drawing
## with the physical layer's collision shapes. On the first tick, records
## which of the model's parts only reflections draw.
func _drive_skeleton_toggle(t: float) -> bool:
	if not _scenario_state.has("mirror_only"):
		_scenario_state.mirror_only = _mirror_only_parts()
	_rig.right_b = (t >= 0.5 and t < 0.6) or (t >= 1.5 and t < 1.6)
	var phase := 0 if t < 0.5 else (1 if t >= 0.7 and t < 1.4 else (2 if t >= 1.7 else -1))
	if phase >= 0:
		var held: Array = _scenario_state.get("skeleton_toggled", [true, true, true])
		var shown := phase == 1
		held[phase] = held[phase] and _player.rig.skeleton_view.visible == shown \
				and _player.physical_view.visible == shown and _player.pose_mapper.model.visible
		_scenario_state.skeleton_toggled = held
	if t >= 1.0 and t < 1.4:
		var view := _compare_view()
		var previous: Dictionary = _scenario_state.get("view", {"drawn": view.drawn, "worst": 0.0})
		view.drawn = mini(view.drawn, previous.drawn)
		view.worst = maxf(view.worst, previous.worst)
		_scenario_state.view = view
	return false


## The model's parts only reflections draw (2026-10-03): its head, with its
## ears, nose, eyes and eyelids, and its neck, by their surfaces' names.
const MIRROR_ONLY_PARTS := ["body1_head", "body1_ear", "body1_nose", "body1_nose_bridge", "body1_eye",
		"body1_eyelid_upper", "body1_eyelid_lower", "body1_neck"]
## How many parts (surfaces) the model is imported with.
const MODEL_PARTS := 28


## The model's parts as drawn (2026-10-03):
## - drawn, mirrored: the names of the surfaces the model's own mesh and its
##   mirror-only copy draw;
## - layers: the copy's render layers;
## - posed: whether the copy is on the model's skin and skeleton, shown with it;
## - eyes_see: whether the player's camera draws the copy's layer;
## - mirror_eyes_see: how many of the level's mirror's two reflection cameras do.
func _mirror_only_parts() -> Dictionary:
	var parts := _player.get_node(^"Visual/MirrorOnlyParts") as MirrorOnlyParts
	var copy := parts.mirror_only_mesh
	if copy == null:
		return {}
	var names := func(mesh: Mesh) -> Array:
		var surfaces := []
		for surface in mesh.get_surface_count():
			surfaces.append(String((mesh as ArrayMesh).surface_get_name(surface)))
		return surfaces
	var layer := RenderLayers.mask(RenderLayers.MIRROR_ONLY)
	var mirror_eyes_see := 0
	var mirror := _level.get_node_or_null(^"PlanarMirror")
	if mirror != null:
		for camera_path: NodePath in [^"LeftEyeViewport/Camera", ^"RightEyeViewport/Camera"]:
			if ((mirror.get_node(camera_path) as Camera3D).cull_mask & layer) != 0:
				mirror_eyes_see += 1
	var model := parts.model_mesh
	return {
		"drawn": names.call(model.mesh), "mirrored": names.call(copy.mesh), "layers": copy.layers,
		"posed": copy.skin == model.skin and copy.get_node(copy.skeleton) == model.get_node(model.skeleton)
				and copy.is_visible_in_tree() == model.is_visible_in_tree(),
		"eyes_see": (_player.rig.head.cull_mask & layer) != 0, "mirror_eyes_see": mirror_eyes_see,
	}


## The model's segments (2026-10-02, rung 7.1): each bone, the physical joint
## its head is on, and the bone (or joint) its far end reaches, as BodyParts.Joint
## names or model bone names.
const MODEL_SEGMENTS := {
	"Chest": ["", "NECK"], "Neck": ["NECK", "Head"],
	"LeftUpperArm": ["LEFT_SHOULDER", "LEFT_ELBOW"], "RightUpperArm": ["RIGHT_SHOULDER", "RIGHT_ELBOW"],
	"LeftLowerArm": ["LEFT_ELBOW", "LEFT_WRIST"], "RightLowerArm": ["RIGHT_ELBOW", "RIGHT_WRIST"],
	"LeftHand": ["LEFT_WRIST", ""], "RightHand": ["RIGHT_WRIST", ""],
	"LeftUpperLeg": ["LEFT_HIP", "LEFT_KNEE"], "RightUpperLeg": ["RIGHT_HIP", "RIGHT_KNEE"],
	"LeftLowerLeg": ["LEFT_KNEE", "LeftFoot"], "RightLowerLeg": ["RIGHT_KNEE", "RightFoot"],
}
## A segment swinging further than this in one tick, in degrees, has had its
## physical joints jump under it; its twist is not judged then, and the swing
## is reported.
const MODEL_SWING := 30.0
## The two bones of each elbow and knee.
const MODEL_HINGES := {
	"LeftUpperArm": "LeftLowerArm", "LeftLowerArm": "LeftUpperArm",
	"RightUpperArm": "RightLowerArm", "RightLowerArm": "RightUpperArm",
	"LeftUpperLeg": "LeftLowerLeg", "LeftLowerLeg": "LeftUpperLeg",
	"RightUpperLeg": "RightLowerLeg", "RightLowerLeg": "RightUpperLeg",
}
## The rest pose's next bone along each stretching bone, for its far end.
const MODEL_NEXT := {
	"Hips": "Spine", "Spine": "Chest", "Chest": "Neck", "Neck": "Head",
	"LeftUpperArm": "LeftLowerArm", "RightUpperArm": "RightLowerArm",
	"LeftLowerArm": "LeftHand", "RightLowerArm": "RightHand",
	"LeftUpperLeg": "LeftLowerLeg", "RightUpperLeg": "RightLowerLeg",
	"LeftLowerLeg": "LeftFoot", "RightLowerLeg": "RightFoot",
}


## The character model on the physical body (rung 7.1, 2026-10-02). Runs each
## tick before the player's nodes, so the model and the snapshot are both as
## the last tick left them: the model posed on that snapshot.
## - joint: how far a segment's ends are from the physical joints they run
##   between, the wrists, the eyes on the headset and the ankles above their
##   soles, and each finger's root where the physical hand has it (m);
## - hand_turn, head_turn: how far the hands and head turned against their
##   physical hand or headset since the first tick (rigid on them), degrees;
## - finger_turn: how far a finger bone turned against its physical bone since
##   the first tick (each turns with its own from the model's rest), degrees;
## - toe_turn: how far a foot faces from its sole, degrees;
## - stretch_min/max: the segments' stretch (1 = the model's rest length);
## - jump: the most any arm, leg, torso or neck bone turned about its own
##   length in one tick, away from snap turns and relocations, degrees (a flip
##   of which way it faces);
## - swings, swing: ticks in which such a bone swung more than MODEL_SWING,
##   its physical joints jumping, and the largest (reported, not judged here;
##   nor is the twist of the other bone of its elbow or knee that tick);
## - nan: ticks with a pose that is not a number.
func _check_model() -> void:
	var mapper := _player.pose_mapper
	if mapper == null or mapper.skeleton == null or mapper.model == null or not mapper.model.visible \
			or _state.body_joints.size() != BodyParts.Joint.size():
		return
	var skeleton := mapper.skeleton
	var check: Dictionary = _scenario_state.get("model", {"ticks": 0, "joint": 0.0, "joint_at": "",
			"hand_turn": 0.0, "head_turn": 0.0, "finger_turn": 0.0, "toe_turn": 0.0, "stretch_min": INF,
			"stretch_max": 0.0, "stretch_at": "", "jump": 0.0, "jump_at": "", "nan": 0})
	var memory: Dictionary = _scenario_state.get("model_memory", {})
	check.ticks += 1
	var world := func(bone_name: String) -> Transform3D:
		return skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone(bone_name))
	var near := func(what: String, at: Vector3, expected: Vector3) -> void:
		var gap := at.distance_to(expected)
		if not is_finite(gap):
			check.nan += 1
		elif gap > check.joint:
			check.joint = gap
			check.joint_at = what
	var joints := _state.body_joints
	for bone_name: String in MODEL_SEGMENTS:
		var ends: Array = MODEL_SEGMENTS[bone_name]
		var pose: Transform3D = world.call(bone_name)
		if ends[0] != "":
			near.call(bone_name + " start", pose.origin, joints[BodyParts.Joint[ends[0]]])
		if ends[1] != "":
			var next: String = MODEL_NEXT[bone_name]
			var length := skeleton.get_bone_rest(skeleton.find_bone(next)).origin.distance_to(
					skeleton.get_bone_rest(skeleton.find_bone(bone_name)).origin)
			var far := pose.origin + pose.basis.y.normalized() * length * pose.basis.get_scale().y
			var expected: Vector3 = (world.call(ends[1]) as Transform3D).origin if ends[1] in MODEL_NEXT.values() \
					else joints[BodyParts.Joint[ends[1]]]
			near.call(bone_name + " end", far, expected)
	for bone_name: String in MODEL_NEXT:
		var stretch := (world.call(bone_name) as Transform3D).basis.get_scale().y
		check.stretch_min = minf(check.stretch_min, stretch)
		if stretch > check.stretch_max:
			check.stretch_max = stretch
			check.stretch_at = "%s at %.2f s" % [bone_name, _t]
	# The head: the eyes on the headset's, turning with it.
	var eyes := _player.rig.skeleton.eye_tracker.global_transform.orthonormalized()
	var model_eyes: Vector3 = ((world.call("LeftEye") as Transform3D).origin
			+ (world.call("RightEye") as Transform3D).origin) * 0.5
	near.call("eyes", model_eyes, eyes.origin)
	_model_rigid(check, memory, "head", eyes, world.call("Head"))
	for side in 2:
		var prefix: String = PoseMapper.SIDES[side]
		# The hand on the physical hand: its wrist (above), each finger's root
		# where the static hand's layout (the model's, since 2026-10-02) puts
		# it on the physical hand, and its turn.
		var hand := _state.hands[side].orthonormalized()
		for finger in 5:
			var root: String = prefix + PoseMapper.FINGERS[finger] \
					+ (PoseMapper.THUMB_PHALANGES if finger == 0 else PoseMapper.PHALANGES)[0]
			near.call(root, (world.call(root) as Transform3D).origin,
					hand * _player.rig.skeleton.finger_rest(side == 0, finger, StaticSkeleton.Phalanx.ROOT).origin)
		_model_rigid(check, memory, prefix + "Hand", hand, world.call(prefix + "Hand"))
		# The foot on its sole: the ankle above it, facing its way.
		var sole := _state.body_soles[side]
		var foot: Transform3D = world.call(prefix + "Foot")
		var rest_ankle := skeleton.get_bone_rest(skeleton.find_bone(prefix + "Foot")).origin.y
		near.call(prefix + "Foot", foot.origin, sole.origin + sole.basis.y.normalized() * rest_ankle)
		var toes: Vector3 = ((world.call(prefix + "Toes") as Transform3D).origin - foot.origin).slide(sole.basis.y.normalized())
		check.toe_turn = maxf(check.toe_turn, rad_to_deg(toes.angle_to(-sole.basis.z)))
		# The fingers along the physical fingers.
		if _state.finger_bones.size() == 30:
			for finger in 5:
				var names: Array = PoseMapper.THUMB_PHALANGES if finger == 0 else PoseMapper.PHALANGES
				for phalanx in 3:
					var bone_name: String = prefix + PoseMapper.FINGERS[finger] + names[phalanx]
					var bone: Transform3D = world.call(bone_name)
					var physical := _state.finger_bones[side * 15 + finger * 3 + phalanx]
					var relation := (physical.basis.orthonormalized().inverse() * bone.basis.orthonormalized()).get_rotation_quaternion()
					if memory.has(bone_name):
						check.finger_turn = maxf(check.finger_turn, rad_to_deg((memory[bone_name] as Quaternion).angle_to(relation)))
					else:
						memory[bone_name] = relation
	# No arm, leg, torso or neck bone flips about its length from one tick to the next.
	var steady: bool = memory.get("turns", -1) == _state.turns and memory.get("relocations", -1) == _state.relocations
	memory.turns = _state.turns
	memory.relocations = _state.relocations
	var bases: Dictionary = memory.get("bases", {})
	var swings := {}
	var turns := {}
	for bone_name: String in MODEL_NEXT:
		var basis := (world.call(bone_name) as Transform3D).basis.orthonormalized()
		if steady and bases.has(bone_name):
			# Only the turn about the bone's own length: the physical joints
			# it runs between may swing it as fast as they move.
			var before: Basis = bases[bone_name]
			var carried := Quaternion(before.y.normalized(), basis.y.normalized()) * before.x
			swings[bone_name] = rad_to_deg(before.y.angle_to(basis.y))
			turns[bone_name] = rad_to_deg(carried.angle_to(basis.x))
		bases[bone_name] = basis
	memory.bases = bases
	for bone_name: String in turns:
		var swing: float = swings[bone_name]
		# An elbow or knee faces the way its two bones bend, so a jump of
		# either turns both.
		var partner: String = MODEL_HINGES.get(bone_name, "")
		var jumped := maxf(swing, swings.get(partner, 0.0))
		if jumped > MODEL_SWING:
			# The physical joints jumped under it: no twist to judge.
			if swing > MODEL_SWING:
				check.swings = check.get("swings", 0) + 1
				if swing > check.get("swing", 0.0):
					check.swing = swing
					check.swing_at = "%s at %.2f s" % [bone_name, _t]
		elif turns[bone_name] > check.jump:
			check.jump = turns[bone_name]
			check.jump_at = "%s at %.2f s" % [bone_name, _t]
	_scenario_state.model = check
	_scenario_state.model_memory = memory


## How far a rigid bone has turned against the frame it is posed on since the
## scenario's first check, in degrees.
func _model_rigid(check: Dictionary, memory: Dictionary, key: String, frame: Transform3D, bone: Transform3D) -> void:
	var relation := (frame.basis.inverse() * bone.basis.orthonormalized()).get_rotation_quaternion()
	if not memory.has(key):
		memory[key] = relation
		return
	var turn := rad_to_deg((memory[key] as Quaternion).angle_to(relation))
	var field := "head_turn" if key == "head" else "hand_turn"
	check[field] = maxf(check[field], turn)


## The model check's criteria (rung 7.1, 2026-10-02): the model on the physical
## body in every scenario, and standing, the model fitted in Blender close to
## the static skeleton's proportions.
func _accept_model(failures: Array[String], scenario: String, model: Dictionary) -> void:
	_expect(failures, model.ticks > 0, "the model was posed")
	_expect(failures, model.nan == 0, "the model's poses are numbers (%d ticks not)" % model.nan)
	_expect(failures, model.joint <= 0.001,
			"the model's joints on the physical ones (%.4f m off at worst, %s; <= 0.001)" % [model.joint, model.joint_at])
	_expect(failures, model.hand_turn <= 0.5, "the model's hands turn with the physical hands (%.2f° <= 0.5)" % model.hand_turn)
	_expect(failures, model.head_turn <= 0.5, "the model's head turns with the headset (%.2f° <= 0.5)" % model.head_turn)
	_expect(failures, model.finger_turn <= 0.5,
			"the model's fingers turn with the physical fingers (%.2f° <= 0.5)" % model.finger_turn)
	_expect(failures, model.toe_turn <= 0.5, "the model's feet face as the soles do (%.2f° <= 0.5)" % model.toe_turn)
	# A flip of the way a bone faces is half a turn; a fast flick of the hand
	# twists the upper arm 29° in a tick, following the physical elbow.
	_expect(failures, model.jump <= 60.0,
			"no model bone flips about its length (%.1f° in one tick <= 60, %s)" % [model.jump, model.jump_at])
	# Walking, the static gait itself stretches a trailing shin (to 1.42 at full
	# stick, 2026-10-02), so the fit is judged standing.
	if scenario == "stand":
		_expect(failures, model.stretch_min >= 0.95 and model.stretch_max <= 1.05,
				"the model fits the body: stretch %.3f to %.3f (%s) within 5 %%" % [model.stretch_min,
				model.stretch_max, model.stretch_at])


## Matches each of the player's collision shapes with a mesh of the physical
## layer's drawing of the same type, size and axis, centred where the shape is:
## how many shapes there are, how many are drawn, and the worst mismatch in
## metres (position or size) among those drawn.
func _compare_view() -> Dictionary:
	var meshes: Array[MeshInstance3D] = []
	for child in _player.physical_view.get_children():
		var drawn := child as MeshInstance3D
		if drawn != null and drawn.is_visible_in_tree() and drawn.mesh is PrimitiveMesh:
			meshes.append(drawn)
	var shapes := _player.physical.find_children("*", "CollisionShape3D", true, false)
	var drawn_count := 0
	var worst := 0.0
	for node in shapes:
		var holder := node as CollisionShape3D
		var best := INF
		for drawn in meshes:
			var mismatch := _mismatch(holder, drawn)
			best = minf(best, mismatch)
		if best <= 0.001:
			drawn_count += 1
		worst = maxf(worst, best if best < INF else 1.0)
	return {"shapes": shapes.size(), "drawn": drawn_count, "worst": worst}


## How far `drawn` is from showing `holder`'s shape: the distance between their
## centres plus the largest difference in size, or INF if the mesh is of
## another type, is scaled differently, or lies along another axis or (a box)
## turned another way.
static func _mismatch(holder: CollisionShape3D, drawn: MeshInstance3D) -> float:
	if not drawn.global_basis.get_scale().is_equal_approx(holder.global_basis.get_scale()):
		return INF
	var shape := holder.shape
	var mesh := drawn.mesh
	var apart := holder.global_position.distance_to(drawn.global_position)
	if shape is CapsuleShape3D and mesh is CapsuleMesh:
		var along := absf(holder.global_basis.y.normalized().dot(drawn.global_basis.y.normalized()))
		if along < 0.999:
			return INF
		var capsule := shape as CapsuleShape3D
		var capsule_mesh := mesh as CapsuleMesh
		return apart + maxf(absf(capsule.radius - capsule_mesh.radius), absf(capsule.height - capsule_mesh.height))
	if shape is SphereShape3D and mesh is SphereMesh:
		return apart + absf((shape as SphereShape3D).radius - (mesh as SphereMesh).radius)
	if shape is BoxShape3D and mesh is BoxMesh:
		var turn := holder.global_basis.get_rotation_quaternion().angle_to(drawn.global_basis.get_rotation_quaternion())
		if turn > 0.01:
			return INF
		var size := (shape as BoxShape3D).size - (mesh as BoxMesh).size
		return apart + maxf(absf(size.x), maxf(absf(size.y), absf(size.z)))
	return INF


## Two hands on one object, scripted by the scenario's keys:
## - "object" (a level weapon) or "bar" ([size, mass], spawned along Z at
##   (1.0, on the table, 0.55) with a Grabbable);
## - "left_z", "right_z": where along the object (world z) each palm grips;
## - "right_grip", "left_grip": [close, open] times, in seconds;
## - "lift": [from, to, metres]; "raise_left": [up from, up to, down from,
##   down to, metres]; "roll_right": [from, to, degrees] about the grip line;
##   "apart": [from, to, metres, from, to, metres], each hand moved that far
##   away from the other along the object; "yaw": [left, right] degrees each
##   wrist is turned about its palm's normal; "tremble": degrees each wrist
##   turns about a random axis, afresh every tick (seeded), like tracking noise;
##   "left_offset": where the left palm stays from its place over the grip
##   (head frame, metres), as a player's hand off the handle; "left_move":
##   [from, to, offset], the left palm moved that much further meanwhile;
##   "push" [start, speed, distance] (_pushed) moves both palms along
##   "push_toward" (head frame; ahead if absent), for the strike scenarios.
## Both palms come down over their grip points by 1.2 s, fingers across the
## object, 4 cm above it, as in _drive_grab_weapon.
func _drive_two_hands(t: float) -> bool:
	var scenario := _scenarios[_index]
	if not _scenario_state.has("object"):
		var object: RigidBody3D
		if scenario.has("bar"):
			var bar: Array = scenario.bar
			var size: Vector3 = bar[0]
			object = _spawn_prop(size, bar[1], Vector3(1.0, 1.0 + size.y * 0.5, 0.55))
			object.add_child(Grabbable.new())
		else:
			object = _level.get_node(scenario.object as NodePath) as RigidBody3D
		_scenario_state.object = object
		# The grip line's top and middle, where the object lies at the start.
		var top := 0.0
		var middle := 0.0
		for child in object.get_children():
			var holder := child as CollisionShape3D
			if holder == null or (scenario.has("object") and holder.name != "Grip"):
				continue
			var size := (holder.shape as BoxShape3D).size
			var box := holder.global_transform * AABB(-size * 0.5, size)
			top = box.end.y
			middle = holder.global_position.x
		_scenario_state.grip_top = top
		_scenario_state.grip_x = middle
	var object: RigidBody3D = _scenario_state.object
	var start: Vector3 = scenario.start
	var reach := clampf((t - 0.5) / 0.7, 0.0, 1.0)
	var lift_time: Array = scenario.lift
	var lift: float = lift_time[2] * smoothstep(lift_time[0], lift_time[1], t)
	var above: float = _scenario_state.grip_top + _palm_half_thickness() + 0.04 + lift
	var ahead: float = _scenario_state.grip_x - start.x
	var forward := -lerpf(ahead - 0.13, ahead, reach)
	var height := lerpf(above + 0.1, above, reach)
	var raise := 0.0
	if scenario.has("raise_left"):
		var r: Array = scenario.raise_left
		raise = r[4] * (smoothstep(r[0], r[1], t) - smoothstep(r[2], r[3], t))
	var apart := 0.0
	if scenario.has("apart"):
		var a: Array = scenario.apart
		apart = a[2] * smoothstep(a[0], a[1], t) + (a[5] - a[2]) * smoothstep(a[3], a[4], t)
	# Facing +X, the head's right (+X) is the level's +Z and its forward the level's +X.
	var left := Vector3(scenario.left_z - start.z - apart, height + raise, forward) \
			+ (scenario.get("left_offset", Vector3.ZERO) as Vector3)
	if scenario.has("left_move"):
		var move: Array = scenario.left_move
		left += (move[2] as Vector3) * smoothstep(move[0], move[1], t)
	var right := Vector3(scenario.right_z - start.z + apart, height, forward)
	if scenario.has("push"):
		var pushed := (scenario.get("push_toward", Vector3.FORWARD) as Vector3) * _pushed(t, scenario.push)
		left += pushed
		right += pushed
	var turns: Array[Basis] = [_palm_turn(true, PALMS_DOWN[0], PALMS_DOWN[1]),
			_palm_turn(false, PALMS_DOWN[0], PALMS_DOWN[1])]
	if scenario.has("yaw"):
		for side in 2:
			turns[side] = Basis(Vector3.UP, deg_to_rad(scenario.yaw[side])) * turns[side]
	if scenario.has("tremble"):
		if not _scenario_state.has("tremble"):
			var seeded := RandomNumberGenerator.new()
			seeded.seed = 27
			_scenario_state.tremble = seeded
		var random: RandomNumberGenerator = _scenario_state.tremble
		for side in 2:
			var axis := Vector3(random.randf_range(-1.0, 1.0), random.randf_range(-1.0, 1.0),
					random.randf_range(-1.0, 1.0))
			var angle := deg_to_rad(scenario.tremble) * random.randf()
			if axis.length_squared() > 1e-6:
				turns[side] = Basis(axis.normalized(), angle) * turns[side]
	if scenario.has("roll_right"):
		var roll: Array = scenario.roll_right
		var angle := deg_to_rad(roll[2]) * smoothstep(roll[0], roll[1], t)
		turns[1] = Basis(Vector3.RIGHT, angle) * turns[1]
	if scenario.has("yaw") or scenario.has("tremble") or scenario.has("roll_right"):
		_rig.left_hand_turn = turns[0]
		_rig.right_hand_turn = turns[1]
	_place_palm(true, left)
	_place_palm(false, right)
	var right_grip: Array = scenario.right_grip
	var left_grip: Array = scenario.left_grip
	_rig.right_grip = 1.0 if t >= right_grip[0] and t < right_grip[1] else 0.0
	_rig.left_grip = 1.0 if t >= left_grip[0] and t < left_grip[1] else 0.0
	var frame := _head_frame()
	_track_two_hands(object, t, frame * left, frame * right)
	return false


## Measures the two hands on `object` in the scenario's named windows, the worst
## of each over the window, into _scenario_state.two_hand; `left` and `right`
## are the palms' commanded centres in the world.
func _track_two_hands(object: RigidBody3D, t: float, left: Vector3, right: Vector3) -> void:
	var physical := _player.physical as DynamicPhysical
	var grabs: Array[HandGrab] = [physical.left_grab, physical.right_grab]
	var drives: Array[HandDrive] = [physical.left_drive, physical.right_drive]
	var two: Dictionary = _scenario_state.get("two_hand", {"windows": {}})
	var holding := [grabs[0].state == HandGrab.State.HOLDING and grabs[0].target == object,
			grabs[1].state == HandGrab.State.HOLDING and grabs[1].target == object]
	# By a handle, how each hand sits on the one it holds (_handle_seat): at its
	# lock (handle_lock, the angle between the fist's grip and the handle, -1
	# until it locks), and the worst in each window (handle_axis, handle_palm).
	var handles := Grabbable.of(object).handles
	var frames: Array[Transform3D] = []
	for holder in handles:
		frames.append(holder.global_transform.orthonormalized())
	# HandGrab's points are from before this physics step: set them against
	# the handles as they were then.
	var frames_before: Array = _scenario_state.get("two_hand_frames", frames)
	_scenario_state.two_hand_frames = frames
	var seats: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
	if not handles.is_empty():
		if not two.has("handle_lock"):
			two.handle_lock = [-1.0, -1.0]
		for side in 2:
			seats[side] = _handle_seat(side == 0, drives[side].hand,
					handles[_nearest_handle(frames, grabs[side].hand_point)])
			if holding[side] and (two.handle_lock[side] as float) < 0.0:
				two.handle_lock[side] = seats[side].x
				# By the handle: its grab point on the handle's centre line (a hand
				# 5-8 cm off the grip may hold the guard or the pommel as met).
				var frame: Transform3D = frames_before[_nearest_handle(frames_before, grabs[side].object_point)]
				var local := frame.affine_inverse() * grabs[side].object_point
				var by_handle: Array = two.get("by_handle", [false, false])
				by_handle[side] = Vector2(local.x, local.z).length() <= 0.0005
				two.by_handle = by_handle
	# Letting go of everything: when each hand last held the object, and when
	# a hand was first held more than 0.4 m off its target.
	for side in 2:
		if holding[side]:
			two["held_until_%d" % side] = t
		if drives[side].separation > 0.4 and not two.has("far_from"):
			two.far_from = t
	# How fast it moves in the 0.1 s after the last hand lets go: a pop, not
	# the fall that follows.
	if not holding[0] and not holding[1] and (two.has("held_until_0") or two.has("held_until_1")):
		var released: float = maxf(two.get("held_until_0", 0.0), two.get("held_until_1", 0.0))
		if t - released <= 0.1:
			two.speed_after = maxf(two.get("speed_after", 0.0), object.linear_velocity.length())
	var scenario := _scenarios[_index]
	var roll_start: float = (scenario.roll_right as Array)[0] if scenario.has("roll_right") \
			else scenario.get("roll_from", INF)
	if t >= roll_start and not two.has("roll_from"):
		two.roll_from = object.global_basis
	var windows: Dictionary = scenario.windows
	for window: String in windows:
		var span: Array = windows[window]
		if t < span[0] or t > span[1]:
			continue
		var w: Dictionary = two.windows.get(window, {})
		if w.is_empty():
			w = {"ticks": 0, "both": 0, "aiming": 0, "aim_hands": 0.0, "aim_command": 0.0, "jitter": 0.0,
					"speed": 0.0, "roles": [grabs[0].role(), grabs[1].role()],
					"kinds": [grabs[0].hold_kind, grabs[1].hold_kind],
					"from": object.global_transform, "hands_from": [drives[0].hand.global_basis, drives[1].hand.global_basis],
					"separation": [0.0, 0.0], "force": [0.0, 0.0], "turn_error": [0.0, 0.0], "reversals": [0, 0],
					"shoulder": [0.0, 0.0], "wrist": [0.0, 0.0], "drop": [0.0, 0.0], "share": [0.0, 0.0],
					"turned_in_hand": [0.0, 0.0], "roll": 0.0, "roll_max": 0.0, "last": object.global_position, "spin_max": [0.0, 0.0],
					"spin": [drives[0].hand.angular_velocity, drives[1].hand.angular_velocity],
					"pulling": [0, 0], "turn_backs": [0, 0], "stretch": [0.0, 0.0], "object_spin": 0.0,
					"motion": [drives[0].hand.linear_velocity, drives[1].hand.linear_velocity]}
		w.ticks += 1
		if not handles.is_empty() and not w.has("handle_axis"):
			w.handle_axis = [0.0, 0.0]
			w.handle_palm = [0.0, 0.0]
		var both: bool = holding[0] and holding[1]
		if both:
			w.both += 1
			if grabs[0].aiming() and grabs[1].aiming():
				w.aiming += 1
			if not handles.is_empty():
				var frame: Transform3D = frames_before[_nearest_handle(frames_before, grabs[0].object_point)]
				var apart := (frame.affine_inverse() * grabs[0].object_point).y - (frame.affine_inverse() * grabs[1].object_point).y
				w.fists_apart = minf(w.get("fists_apart", INF), absf(apart))
				w.fists_left_ahead = apart > 0.0
			var along := (object.global_transform * grabs[1].anchor) - (object.global_transform * grabs[0].anchor)
			var hands := drives[1].hand.global_position - drives[0].hand.global_position
			w.aim_hands = maxf(w.aim_hands, rad_to_deg(along.angle_to(hands)))
			w.aim_command = maxf(w.aim_command, rad_to_deg(along.angle_to(right - left)))
			# Roll about the grip line since the scripted roll began (or the window).
			var before: Basis = two.get("roll_from", (w.from as Transform3D).basis)
			var turn := (object.global_basis.orthonormalized() * before.orthonormalized().inverse()).get_rotation_quaternion()
			var axis := along.normalized()
			w.roll = rad_to_deg(2.0 * atan2(Vector3(turn.x, turn.y, turn.z).dot(axis), turn.w))
			w.roll_max = maxf(w.roll_max, absf(w.roll))
		w.jitter = maxf(w.jitter, object.global_position.distance_to(w.last))
		w.last = object.global_position
		w.speed = maxf(w.speed, object.linear_velocity.length())
		w.object_spin = maxf(w.object_spin, object.angular_velocity.length())
		for side in 2:
			var drive := drives[side]
			w.separation[side] = maxf(w.separation[side], drive.separation)
			w.force[side] = maxf(w.force[side], _state.hand_force[side])
			var error := (drive.target.basis.orthonormalized()
					* drive.hand.global_basis.orthonormalized().inverse()).get_rotation_quaternion().get_angle()
			w.turn_error[side] = maxf(w.turn_error[side], rad_to_deg(error))
			var spin := drive.hand.angular_velocity
			if spin.length() > 0.05 and (w.spin[side] as Vector3).dot(spin) < 0.0:
				w.reversals[side] += 1
			w.spin_max[side] = maxf(w.spin_max[side], spin.length())
			w.spin[side] = spin
			if grabs[side].state == HandGrab.State.SEATING:
				w.pulling[side] += 1
			var motion := drive.hand.linear_velocity
			if motion.length() > 0.05 and (w.motion[side] as Vector3).dot(motion) < 0.0:
				w.turn_backs[side] += 1
			w.motion[side] = motion
			w.shoulder[side] = maxf(w.shoulder[side], absf(_state.arm_holding[side].x))
			w.wrist[side] = maxf(w.wrist[side], absf(_state.arm_holding[side].y))
			var commanded: Vector3 = left if side == 0 else right
			w.drop[side] = maxf(w.drop[side], commanded.y - drive.hand.global_position.y)
			w.share[side] = grabs[side].share
			if holding[side] and holding[1 - side]:
				# How far the hand's side of the grip joint is from the object's:
				# the grip joint stretched.
				w.stretch[side] = maxf(w.stretch[side], (object.global_transform * grabs[side].anchor)
						.distance_to(grabs[side].joint_point(grabs[side].hold_kind)))
			if holding[side]:
				var relative := ((w.hands_from[side] as Basis).orthonormalized().inverse() * (w.from as Transform3D).basis.orthonormalized()).inverse() \
						* (drive.hand.global_basis.orthonormalized().inverse() * object.global_basis.orthonormalized())
				w.turned_in_hand[side] = maxf(w.turned_in_hand[side], rad_to_deg(relative.get_rotation_quaternion().get_angle()))
				if not handles.is_empty():
					w.handle_axis[side] = maxf(w.handle_axis[side], seats[side].x)
					w.handle_palm[side] = maxf(w.handle_palm[side], seats[side].y)
		w.layers = [object.collision_layer, object.collision_mask]
		two.windows[window] = w
	two.layers = [object.collision_layer, object.collision_mask]
	two.grabs = [grabs[0].grabs, grabs[1].grabs]
	_scenario_state.two_hand = two
	_track_prop(object, t)


## The two-hand scenarios' checks, from the windows _track_two_hands measured.
func _accept_two_hands(result: Dictionary, failures: Array[String]) -> void:
	var two: Dictionary = result.get("two_hand", {})
	var windows: Dictionary = two.get("windows", {})
	var both: Dictionary = windows.get("both", {})
	var name: String = result.name
	var aiming := name not in ["two_hand_close", "two_hand_close_apart"]
	# The lead is whichever hand gripped first; on the same tick, the left.
	var lead := 0 if name in ["two_hand_pull_apart", "two_hand_release_apart", "two_hand_close_apart"] else 1
	_expect(failures, both.get("both", 0) == both.get("ticks", -1),
			"both hands held it through the hold (%d of %d ticks)" % [both.get("both", 0), both.get("ticks", 0)])
	# Short grips (the swords', 8 and 13 cm between the hands) carry the blade
	# as a lever: the hand by the guard takes 2.5 times its weight, the other
	# pushes down with 1.5 times. The solver does not converge that loop at its
	# 10 velocity steps, and how far it falls short depends on the order Jolt
	# solves the joints in, which follows their creation and removal history,
	# not on the targets (they fit the grip joints exactly): remaking one hold
	# joint in place moves the sword between 1.4 and 2.7 mm of stretch and
	# 1.6-3.0° off its grip points (review, 2026-09-27). Accepted for the
	# headset to judge; at 30 velocity steps the blade came within 0.5-0.9 mm,
	# about 0.7° of the grip points and 1.3-1.7° of the player's hands. Since
	# the second hand joins the hold as it grips, its target is set where it
	# locks, up to hold_distance short of where the seat put it, which stays
	# in the aim: at most 5 mm across the span (1.9-2.9° on the swords' grips,
	# 0.4-0.6° on the bars). With the player's hand off the 8 cm handle that
	# takes the sword to 8.4° off the player's hands (6.9° before), hence 9°.
	var short := name in ["two_hand_sword", "two_hand_sword_swap", "two_hand_longsword",
			"two_hand_reach_longsword", "two_hand_reach_sword", "two_hand_reach_sword_drift",
			"two_hand_table_join", "two_hand_longsword_beside"]
	var aim_limit := 4.0 if short else 1.0
	var command_limit := 9.0 if short else 2.0
	if aiming:
		_expect(failures, both.get("aiming", 0) == both.get("ticks", -1),
				"it aimed between the hands (%d of %d ticks)" % [both.get("aiming", 0), both.get("ticks", 0)])
		_expect(failures, both.get("aim_hands", 90.0) <= aim_limit,
				"it pointed along the hands' grab points (%.2f° off <= %.0f)" % [both.get("aim_hands", 90.0), aim_limit])
		_expect(failures, both.get("aim_command", 90.0) <= command_limit,
				"it pointed along the player's hands (%.2f° off <= %.0f)" % [both.get("aim_command", 90.0), command_limit])
	else:
		_expect(failures, both.get("aiming", 1) == 0, "palms 3 cm apart never aimed (%d ticks)" % both.get("aiming", 1))
		_expect(failures, (both.get("turned_in_hand", [90.0, 90.0])[lead] as float) <= 3.0,
				"the lead kept it welded (%.2f° <= 3)" % (both.get("turned_in_hand", [90.0, 90.0])[lead] as float))
	_expect(failures, (both.get("roles", [0, 0])[lead] as int) == 1 and (both.get("roles", [0, 0])[1 - lead] as int) == 2,
			"roles: lead then support (%s)" % str(both.get("roles", [])))
	var still_windows := ["both", "raised", "rolled", "tension", "apart", "rest"] if name != "two_hand_share" else ["both"]
	# Trembling wrists turn the hands back and forth every tick by design.
	var trembling := name == "two_hand_bar_yawed"
	for window: String in still_windows:
		if not windows.has(window):
			continue
		var w: Dictionary = windows[window]
		_expect(failures, w.jitter <= 0.0003, "%s: steady (%.5f m a tick <= 0.0003)" % [window, w.jitter])
		_expect(failures, w.speed <= (0.3 if window == "tension" else 0.5),
				"%s: no sudden motion (%.3f m/s)" % [window, w.speed])
		# A hand turning back and forth under 0.1 rad/s (0.08° a tick) is not
		# seen; a buzz is.
		for side in 2:
			if trembling:
				break
			_expect(failures, (w.reversals[side] as int) <= w.ticks / 10 or (w.spin_max[side] as float) <= 0.1,
					"%s: hand %d does not ring (%d reversals in %d ticks, up to %.3f rad/s)" % [
					window, side, w.reversals[side], w.ticks, w.spin_max[side]])
	match name:
		"two_hand_sword", "two_hand_sword_swap":
			_expect(failures, is_equal_approx(both.share[0] + both.share[1], 1.0),
					"the weight's shares add up (%.3f + %.3f)" % [both.share[0], both.share[1]])
			var after: Dictionary = windows.get("after", {})
			var keeper := 1 if name == "two_hand_sword" else 0
			_expect(failures, (after.get("roles", [0, 0])[keeper] as int) == 1 and after.get("kinds", [9, 9])[keeper] == HandGrab.Hold.WELD,
					"the remaining hand leads, welded (%s, %s)" % [str(after.get("roles", [])), str(after.get("kinds", []))])
			_expect(failures, (after.get("turned_in_hand", [90.0, 90.0])[keeper] as float) <= 3.0,
					"taking over, it kept its rotation in the hand (%.2f° <= 3)" % (after.get("turned_in_hand", [90.0, 90.0])[keeper] as float))
		"two_hand_longsword_beside":
			# Both grab points lie on the handle's centre line, so this is how
			# far apart along it the two fists hold it.
			_expect(failures, absf(both.get("fists_apart", 0.0) - 0.08) <= 0.0005 and both.get("fists_left_ahead", false),
					"both: the left fist held it a palm's width from the right, toward the guard (%.4f m, 0.08)" % both.get("fists_apart", 0.0))
		"two_hand_longsword":
			var raised: Dictionary = windows.get("raised", {})
			var rolled: Dictionary = windows.get("rolled", {})
			_expect(failures, raised.get("aim_command", 90.0) <= command_limit,
					"raising the left hand aimed it with the hands (%.2f° off <= %.0f)" % [raised.get("aim_command", 90.0), command_limit])
			# Rolled by the mean of the two hands' roll: one hand's 30° gives 15°.
			_expect(failures, absf(absf(rolled.get("roll", 0.0)) - 15.0) <= 5.0,
					"rolling one hand rolled it half as far (%.1f° of 15 ± 5)" % rolled.get("roll", 0.0))
			_expect(failures, (raised.get("turn_error", [90.0, 90.0])[1] as float) <= 5.0 and (raised.get("turn_error", [90.0, 90.0])[0] as float) <= 3.0,
					"the wrists do not fight (lead %.1f° <= 5, support %.1f° <= 3)" % [raised.get("turn_error", [90.0, 90.0])[1], raised.get("turn_error", [90.0, 90.0])[0]])
		"two_hand_bar_aim":
			var raised: Dictionary = windows.get("raised", {})
			var rolled: Dictionary = windows.get("rolled", {})
			_expect(failures, raised.get("aim_command", 90.0) <= 2.0,
					"raising the left hand aimed it with the hands (%.2f° off <= 2)" % raised.get("aim_command", 90.0))
			_expect(failures, absf(absf(rolled.get("roll", 0.0)) - 15.0) <= 3.0,
					"rolling one hand rolled it half as far (%.1f° of 15 ± 3)" % rolled.get("roll", 0.0))
			_expect(failures, (raised.get("turn_error", [90.0, 90.0])[0] as float) <= 5.0 and (raised.get("turn_error", [90.0, 90.0])[1] as float) <= 5.0,
					"the wrists do not fight (%.1f°, %.1f° <= 5)" % [raised.get("turn_error", [90.0, 90.0])[0], raised.get("turn_error", [90.0, 90.0])[1]])
			_expect(failures, absf(both.share[0] - 0.5) <= 0.01 and absf(both.share[1] - 0.5) <= 0.01,
					"held in the middle, the hands share its weight equally (%.3f, %.3f)" % [both.share[0], both.share[1]])
		"two_hand_share":
			var one: Dictionary = windows.get("one", {})
			_expect(failures, (both.shoulder[1] as float) <= 0.65 * (one.get("shoulder", [0.0, 0.0])[1] as float),
					"two-handed, the lead's shoulder holds less (%.1f vs %.1f N·m one-handed)" % [both.shoulder[1], one.get("shoulder", [0.0, 0.0])[1]])
			_expect(failures, (both.wrist[1] as float) <= 0.3 * (one.get("wrist", [0.0, 0.0])[1] as float),
					"two-handed, the lead's wrist holds far less (%.1f vs %.1f N·m one-handed)" % [both.wrist[1], one.get("wrist", [0.0, 0.0])[1]])
			for side in 2:
				_expect(failures, (both.drop[side] as float) < (one.get("drop", [0.0, 0.0])[1] as float),
						"two-handed, hand %d dips less (%.3f m vs %.3f m one-handed)" % [side, both.drop[side], one.get("drop", [0.0, 0.0])[1]])
		"two_hand_pull_apart":
			# The player's hands pulled apart: the physical hands stay on the bar,
			# driven to their middle, and do not strain against each other.
			for window: String in ["tension", "far"]:
				var w: Dictionary = windows.get(window, {})
				_expect(failures, w.get("both", 0) == w.get("ticks", -1),
						"%s: both still hold it (%d of %d)" % [window, w.get("both", 0), w.get("ticks", 0)])
				_expect(failures, (w.get("force", [9999.0, 9999.0])[0] as float) <= 200.0 and (w.get("force", [9999.0, 9999.0])[1] as float) <= 200.0,
						"%s: the hands do not strain (%s N <= 200)" % [window, str(w.get("force", []))])
				_expect(failures, (w.get("separation", [1.0, 1.0])[0] as float) <= 0.02 and (w.get("separation", [1.0, 1.0])[1] as float) <= 0.02,
						"%s: each hand on its shared target (%s m <= 0.02)" % [window, str(w.get("separation", []))])
		"two_hand_release_apart", "two_hand_close_apart":
			# The player's hands 0.2 m further apart than the grips: the physical
			# hands stay on the object, at their middle, without straining. Then
			# one lets go and the other takes the object to its own controller,
			# 0.1 m away: no faster than a hand's drive closes a 0.1 m gap
			# (follow_gain 15/s), not flung by the jump in its target.
			var apart: Dictionary = windows.get("apart", {})
			_expect(failures, apart.get("both", 0) == apart.get("ticks", -1),
					"apart: both still hold it (%d of %d)" % [apart.get("both", 0), apart.get("ticks", 0)])
			_expect(failures, (apart.get("force", [9999.0, 9999.0])[0] as float) <= 200.0 and (apart.get("force", [9999.0, 9999.0])[1] as float) <= 200.0,
					"apart: the hands do not strain (%s N <= 200)" % str(apart.get("force", [])))
			_expect(failures, (apart.get("separation", [1.0, 1.0])[0] as float) <= 0.02 and (apart.get("separation", [1.0, 1.0])[1] as float) <= 0.02,
					"apart: each hand on its shared target (%s m <= 0.02)" % str(apart.get("separation", [])))
			var takeover: Dictionary = windows.get("takeover", {})
			_expect(failures, takeover.get("speed", 99.0) <= 1.5,
					"one hand let go 0.1 m out of step: the other takes it without a fling (%.2f m/s <= 1.5)" % takeover.get("speed", 99.0))
			var alone: Dictionary = windows.get("alone", {})
			var keeper := 0 if name == "two_hand_release_apart" else 1
			_expect(failures, (alone.get("roles", [0, 0])[keeper] as int) == 1 and alone.get("kinds", [9, 9])[keeper] == HandGrab.Hold.WELD,
					"the remaining hand leads, welded (%s, %s)" % [str(alone.get("roles", [])), str(alone.get("kinds", []))])
			_expect(failures, (alone.get("turned_in_hand", [90.0, 90.0])[keeper] as float) <= 3.0,
					"held alone, it keeps its rotation in the hand (%.2f° <= 3)" % (alone.get("turned_in_hand", [90.0, 90.0])[keeper] as float))
		"two_hand_reach_longsword", "two_hand_reach_sword", "two_hand_reach_sword_drift", "two_hand_table_join":
			# From the grip, the object and both hands move together into the
			# two-handed hold, as if the second hand held it already: the hand
			# comes onto the handle within 0.35 s, and nothing twitches. The
			# object's spin and speed coming together are recorded (object_spin,
			# speed) for the headset to judge: the seat starts at the drive's
			# step response.
			var pull: Dictionary = windows.get("pull", {})
			_expect(failures, (pull.get("pulling", [99, 99])[0] as int) <= 25,
					"the left hand came onto the handle in %d ticks <= 25" % (pull.get("pulling", [99, 99])[0] as int))
			for side in 2:
				_expect(failures, (pull.get("turn_backs", [99, 99])[side] as int) <= pull.get("ticks", 0) / 10,
						"coming together, hand %d does not twitch (%d turn-backs in %d ticks)" % [
						side, pull.get("turn_backs", [99, 99])[side], pull.get("ticks", 0)])
				_expect(failures, (pull.get("force", [9999.0, 9999.0])[side] as float) <= 400.0,
						"coming together, hand %d does not strain (%.0f N <= 400)" % [side, pull.get("force", [9999.0, 9999.0])[side]])
		"two_hand_bar_yawed":
			# Wrists not square to the grip line, as players hold things, and
			# trembling: raising one hand turns the line but rolls neither wrist.
			var raised: Dictionary = windows.get("raised", {})
			_expect(failures, raised.get("roll_max", 90.0) <= 2.0,
					"raising the left hand did not roll it (%.2f° at most <= 2)" % raised.get("roll_max", 90.0))
			_expect(failures, raised.get("aim_command", 90.0) <= 2.0,
					"raising the left hand aimed it with the hands (%.2f° off <= 2)" % raised.get("aim_command", 90.0))
	if short:
		# Held by the weapons' handles (2026-09-27): each hand locks seated on
		# the handle, the lead alone (as grab_sword_table) and the second hand
		# once its ride brings it within hold_angle (2°) of its seat, so within
		# 2.5° at the lock (_accept_handle). Then the two-hand hold leaves them
		# free to turn on it by design (the second holds a point, the lead a
		# point and the roll about the line between them) and aims the handle
		# along the line between the hands' centres, while the blade's lever
		# keeps it 1.6-3.0° off its grip points (above). Measured (2026-09-27),
		# the handle ends 8.2-8.7° off the fists' grip in the both window (which
		# opens as the join's swing ends) of the sword and 8.1-8.4° of the
		# longsword, settling to 7.1-7.9°; the sword's more since its grip was
		# cut back to where its pommel begins (its fists now 6.6 cm apart, 7.8
		# before; 6.4-7.0° then). 20.8-21.3°, settled, with the controllers 7 cm
		# apart (two_hand_longsword_beside, which fails on it). Not the locks' 5
		# mm leeway: locking within 1-2 mm left the sword 9.8-11.1° off. Open:
		# inference, the object aims along the line between the player's hands
		# while each hand keeps its own turn in the shared frame. The limit is the
		# swords' with about 2° of margin: a hand turned on the handle past it no
		# longer holds it straight along the fist. Those figures are with the
		# palm's grab point at its centre; moved toward the knuckles (the
		# player's choice, 2026-09-27) the handle sits that much forward of the
		# line between the hands' centres, and the sword's hands end 10.1° off
		# its handle at 1 cm, 14.4° at 2 cm and 16.8° at 2.5 cm (grab_forward),
		# aiming 3.8-9.1° off their grab points: two_hand_sword fails; the
		# longsword's longer span keeps it within the limits.
		# Only the hands that hold it by the handle: one 5-8 cm off the grip may
		# hold the guard or the pommel, as met.
		var lock: Array = two.get("handle_lock", [90.0, 90.0])
		var by_handle: Array = two.get("by_handle", [false, false])
		var axis: Array = both.get("handle_axis", [90.0, 90.0])
		var handle_limit := 11.0
		for side in 2:
			if not by_handle[side]:
				continue
			_expect(failures, (lock[side] as float) >= 0.0 and (lock[side] as float) <= 2.5,
					"hand %d locked seated along the handle (%.2f° <= 2.5)" % [side, lock[side]])
			_expect(failures, (axis[side] as float) <= handle_limit,
					"both: hand %d stayed along the handle (%.2f° <= %.0f)" % [side, axis[side], handle_limit])
	_expect(failures, two.get("speed_after", 99.0) <= 2.0,
			"let go, it does not pop away (%.2f m/s in the first 0.1 s <= 2)" % two.get("speed_after", 99.0))
	var layers: Array = two.get("layers", [0, 0])
	_expect(failures, (layers[0] as int) == PROP_LAYER | Grabbable.GRABBABLE_LAYER and (layers[1] as int) == PROP_MASK,
			"let go, it has its own layers back (%s)" % str(layers))
	var held_layers: Array = both.get("layers", [0, 0])
	_expect(failures, (held_layers[0] as int) == Grabbable.HELD_LAYER and (held_layers[1] as int) == Grabbable.HELD_MASK,
			"held, it is on the Held layer (%s)" % str(held_layers))


## The moving grabs' checks, from _track_seat (the grab's seat, 2026-10-02):
## grabbed once, the object comes into the hand the same way however fast the
## hand moves: held within seat_time of the grab (to the tick), on the seat's
## path all the way there (1 mm), with no jump at the lock (1 mm, 0.5°), not
## moving in the hand after it (3 mm, 1.5°: the weld gives 2.3 mm and 1.2°
## to the 2.5 m/s sweep's stop in 0.06 s, measured; pulled in, 2.8 mm and
## 1.4°), and still held once the hand has stopped and lifted it.
func _accept_seat(result: Dictionary, failures: Array[String]) -> void:
	var a: Dictionary = result.analysis
	var s: Dictionary = result.get("seat", {})
	var seat_time: float = s.get("seat_time", 0.08)
	_expect(failures, a.grabs == 1, "grabbed once (%d)" % a.grabs)
	_expect(failures, s.has("lock_time") and s.lock_time <= seat_time + 1e-4,
			"held %.3f s after the grab <= %.2f (%d ticks)" % [s.get("lock_time", 9.0), seat_time, s.get("lock_ticks", -1)])
	_expect(failures, s.get("path_error", 99.0) <= 1.0,
			"on the seat's path in the hand (%.2f mm off at most <= 1)" % s.get("path_error", 99.0))
	var jump: Array = s.get("lock_jump", [99.0, 99.0])
	_expect(failures, jump[0] <= 1.0 and jump[1] <= 0.5,
			"no jump at the lock (%.2f mm, %.2f°)" % [jump[0], jump[1]])
	var drift: Array = s.get("held_drift", [99.0, 99.0])
	_expect(failures, drift[0] <= 3.0 and drift[1] <= 1.5,
			"not moving in the hand once held (%.2f mm, %.2f°)" % [drift[0], drift[1]])
	# The grip opens at 3.5 s.
	_expect(failures, s.get("held_at_end", false) and s.get("let_go_at", 99.0) >= 3.49,
			"still held once the hand stopped and lifted it (let go at %.3f s)" % s.get("let_go_at", -1.0))


## The handle scenarios' checks, from _track_handle (2026-09-27). As
## grab_sword_table: grabbed once, it comes up with the hand, stays at the
## grab point and in the same rotation in the hand, does not drag the hand,
## and drops back onto the table when let go. Then how it is held
## (_accept_handle_seat), and:
## - where the palm met it along the handle, but with the palm wholly on it:
##   met nearer an end than half the palm's width ("from_end"), the grab
##   point is where the palm met it clamped to the handle's half length less
##   half the palm's width (within 0.5 mm), and the fist locks within
##   hold_distance (5 mm) of it: HandGrab locks as soon as the gap is that
##   small, whichever way it lies;
## - seated, turned into the fist, within seat_time however it lay (the
##   grab's seat, 2026-10-02; pulled in, 0.17 s turned 45° or 135°, and
##   0.69 s tilted 30° against the table, its pommel on it until lifted), and
##   not swinging back past its seat on the way (3°);
## - the wrist not twisted off its target while it turns, since nothing pushes
##   on the hand: at most 3° (1.5° in the first run, pulled in);
## - meeting what a held object meets by 3.0 s, when the hand has lifted it
##   0.2 m: from the lock, or once lifted clear of the table it was seated
##   into.
func _accept_handle(result: Dictionary, failures: Array[String]) -> void:
	var a: Dictionary = result.analysis
	var h: Dictionary = result.get("handle_grab", {})
	var name: String = result.name
	var moved: Array = result.get("prop_moved", [0.0, 0.0, 0.0])
	var aside := Vector2(moved[0], moved[2]).length()
	_expect(failures, a.grabs == 1, "grabbed once (%d)" % a.grabs)
	_expect(failures, a.grab_gap_held_max <= 0.01, "held at the grab point (%.4f m off at most)" % a.grab_gap_held_max)
	_expect(failures, result.get("held_rise_min", 0.0) >= 0.18,
			"it came up with the hand (%.3f m)" % result.get("held_rise_min", 0.0))
	_expect(failures, result.get("held_turn", 90.0) <= 3.0,
			"it kept its rotation in the hand (%.1f°)" % result.get("held_turn", 90.0))
	_expect(failures, result.get("hand_pulled", 1.0) <= 0.05,
			"it did not drag the hand (%.3f m)" % result.get("hand_pulled", 1.0))
	# Held at the palm's grab point, grab_forward toward the fingers from where
	# the harness puts the palm's centre, it is let go that much aside.
	var drop_aside: float = _scenario_named(name).get("drop_aside", 0.05) + h.get("grab_forward", 0.0)
	_expect(failures, absf(moved[1]) <= 0.02 and aside <= drop_aside,
			"let go, it dropped back onto the table (%.3f m down, %.3f m aside <= %.2f)" % [moved[1], aside, drop_aside])
	if not _accept_handle_seat(result, failures):
		return
	if _scenario_named(name).has("from_end"):
		var reach: float = h.get("reach", 0.0)
		var met: float = h.get("along_at_grip", 0.0)
		var wanted := clampf(met, -reach, reach)
		_expect(failures, absf(met) > reach,
				"the palm met the handle where it would overhang its end (%.4f m from the middle, > %.4f)" % [met, reach])
		_expect(failures, absf(h.get("along_grip", 1.0) - wanted) <= 0.0005,
				"held as near that end as leaves the palm wholly on it (grab point %.4f m from the middle, %.4f wanted)" % [
				h.get("along_grip", 1.0), wanted])
		_expect(failures, absf(h.get("along", 1.0) - wanted) <= 0.005,
				"the fist locked within 5 mm of it (%.4f m from the middle)" % h.get("along", 1.0))
	var seat_time: float = h.get("seat_time", 0.0)
	_expect(failures, h.get("pull_ticks", 0) > 0 and h.get("pull_time", 9.0) <= seat_time + 1e-4,
			"seated and turned into the fist in %.3f s <= %.2f" % [h.get("pull_time", 9.0), seat_time])
	_expect(failures, h.get("solid_at", 9.0) <= 3.0,
			"held, it met the level and props again by %.3f s <= 3.0" % h.get("solid_at", 9.0))
	_expect(failures, h.get("pull_turn_error", 90.0) <= 3.0,
			"the turn did not twist the wrist (%.2f° off its target at most <= 3)" % h.get("pull_turn_error", 90.0))
	_expect(failures, h.get("pull_rebound", 90.0) <= 3.0,
			"turned into its seat without swinging past it (%.2f° back at most <= 3)" % h.get("pull_rebound", 90.0))


## How the hand held the handle (_track_handle), for the one-hand handle
## grabs: by it, its grab point on the handle's centre line (0.5 mm) and
## within its length; straight along the fist's grip, toward the thumb (+1)
## or the little finger (-1) as the scenario expects ("toward", +1 unless it
## says), the palm on one of its sides: within 2.5° at the lock (hold_angle
## 2°, and the lock tick's motion) and within 3° while held (held_turn's
## limit: the weld holds it as it locked). Returns whether it was held by the
## handle, so the checks that follow from that can be skipped.
func _accept_handle_seat(result: Dictionary, failures: Array[String]) -> bool:
	var h: Dictionary = result.get("handle_grab", {})
	var toward: int = _scenario_named(result.name).get("toward", 1)
	if not _expect(failures, h.get("on_handle", false),
			"grabbed by the handle (%.4f m off its centre line <= 0.0005, %.4f m along it of %.4f)" % [
			h.get("line_off", 1.0), h.get("along_grab", 1.0), h.get("half", 0.0)]):
		return false
	_expect(failures, h.get("toward", 0) == toward,
			"the nearest seat: its +Y toward the %s (%d)" % ["thumb" if toward > 0 else "little finger", h.get("toward", 0)])
	_expect(failures, h.get("lock_axis", 90.0) <= 2.5 and h.get("lock_palm", 90.0) <= 2.5,
			"seated at the lock: %.2f° off the fist's grip, the palm %.2f° off its side (<= 2.5)" % [
			h.get("lock_axis", 90.0), h.get("lock_palm", 90.0)])
	_expect(failures, h.get("held_axis", 90.0) <= 3.0 and h.get("held_palm", 90.0) <= 3.0 and h.get("flipped", 1) == 0,
			"stayed seated while held (%.2f°, %.2f° at most <= 3; %d ticks turned over)" % [
			h.get("held_axis", 90.0), h.get("held_palm", 90.0), h.get("flipped", 1)])
	return true


## The scenario called `scenario_name` in this run, or an empty one.
func _scenario_named(scenario_name: String) -> Dictionary:
	for scenario in _scenarios:
		if scenario.name == scenario_name:
			return scenario
	return {}


## How far the lowest corner of `body`'s box colliders over the table is below
## its top, or 0 if none is.
func _table_sink(body: RigidBody3D) -> float:
	var sink := 0.0
	for child in body.get_children():
		var holder := child as CollisionShape3D
		if holder == null or not holder.shape is BoxShape3D:
			continue
		var half := (holder.shape as BoxShape3D).size * 0.5
		for i in 8:
			var corner := holder.global_transform * Vector3(half.x if i & 1 else -half.x,
					half.y if i & 2 else -half.y, half.z if i & 4 else -half.z)
			if TABLE_TOP.has_point(corner):
				sink = maxf(sink, 1.0 - corner.y)
	return sink


## The right palm comes flat over the 5 cm gap between the light box (-0.45 to
## -0.35) and the medium box (-0.30 to -0.20), 1 cm from the medium box's edge
## and 4 cm from the light box's, 2 cm above their tops; grips at 1.5 s and
## lifts 0.15 m by 2.8 s.
func _drive_grab_picks_closest(t: float) -> bool:
	var reach := clampf((t - 0.5) / 0.7, 0.0, 1.0)
	var lift := 0.15 * smoothstep(1.8, 2.8, t)
	var above := 1.10 + _palm_half_thickness() + 0.02
	_place_palm(false, Vector3(0.0, lerpf(above + 0.1, above, reach) + lift, lerpf(-0.2, -0.35, reach)))
	_rig.right_grip = 1.0 if t >= 1.5 else 0.0
	for box: String in ["LightBox", "MediumBox"]:
		var body := _level.get_node("Dynamic/" + box) as Node3D
		var key := "start_" + box
		if not _scenario_state.has(key):
			_scenario_state[key] = body.global_position
		_scenario_state["rise_" + box] = body.global_position.y - (_scenario_state[key] as Vector3).y
	return false


## Grabs the scenario's box from 4 cm above (as grab_lift_box), lifts it
## 0.25 m by 2.5 s, then swings the controller fast across and back twice,
## 0.5 m each way in 0.2 s (peaking near 4 m/s; or the scenario's swing_reach
## in swing_time), and holds still from 3.8 s.
## Tracks how far the box's grab point gets from the hand's, how far the hand
## gets from its target, how far past the swing's ends the box goes, and
## whether it is still held at the end.
func _drive_grab_swing(t: float) -> bool:
	var box := _level.get_node("Dynamic/" + String(_scenarios[_index].box)) as RigidBody3D
	var reach := clampf((t - 0.5) / 0.7, 0.0, 1.0)
	var lift := 0.25 * smoothstep(1.8, 2.5, t)
	var scenario: Dictionary = _scenarios[_index]
	var time: float = scenario.get("swing_time", 0.2)
	var swing_reach: float = scenario.get("swing_reach", 0.5)
	var swing := 0.0
	for start: float in [2.8, 3.2]:
		swing += smoothstep(start, start + time, t) - smoothstep(start + time, start + 2.0 * time, t)
	var above := 1.10 + _palm_half_thickness() + 0.04
	_place_palm(false, Vector3(swing_reach * swing, lerpf(above + 0.1, above, reach) + lift, lerpf(-0.2, -0.33, reach)))
	_rig.right_grip = 1.0 if t >= 1.5 else 0.0
	_track_prop(box, t)
	var physical := _player.physical as DynamicPhysical
	if t >= 2.7:
		var grab := physical.right_grab
		if grab.state != HandGrab.State.IDLE:
			_scenario_state.swing_gap = maxf(_scenario_state.get("swing_gap", 0.0), grab.gap)
		_scenario_state.swing_separation = maxf(_scenario_state.get("swing_separation", 0.0),
				physical.right_drive.separation)
		# How far the box goes past the ends of the swing, sideways: the
		# controller's own furthest sideways point is the reach it asked for.
		var side := (box.global_position.z - (_scenario_state.prop_start as Vector3).z)
		_scenario_state.swing_past = maxf(_scenario_state.get("swing_past", 0.0), side - swing_reach)
		_scenario_state.swing_behind = maxf(_scenario_state.get("swing_behind", 0.0), -side)
		var hand_side := physical.right_drive.hand.global_position.z - (_scenario_state.hand_start as float)
		_scenario_state.swing_hand_past = maxf(_scenario_state.get("swing_hand_past", 0.0), hand_side - swing_reach)
	else:
		_scenario_state.hand_start = physical.right_drive.hand.global_position.z
	if t >= 4.8:
		_scenario_state.still_held = physical.right_grab.state == HandGrab.State.HOLDING
	return false


## A wrist flick with the 2 kg box (or, without "grip", with the empty hand
## over it): gripped from 4 cm above (as
## grab_lift_box), lifted 0.25 m by 2.5 s, then the controller turns
## FLICK_ANGLE down about its side axis in FLICK_TIME and straight back up, at
## 2.8 s and at 3.4 s (peaking near 23 rad/s), and holds still from 3.6 s. It
## turns about itself, as the hand does about the grip.
## Measured from 2.7 s: the widest gap between the physical hand and the static
## skeleton's hand (position, and turn), and the same from the static hand to
## the command (the arm's strength) and from the command to the hand (the
## drive); after the last flick (from 3.56 s), how often the hand's turn from
## the static hand about the flick's axis turns back (springing), and when it
## is last more than 1° off.
func _drive_grab_flick(t: float) -> bool:
	if not _scenario_state.has("flick_from"):
		_scenario_state.flick_from = _rig.right_hand_turn
	var rest: Basis = _scenario_state.flick_from
	var reach := clampf((t - 0.5) / 0.7, 0.0, 1.0)
	var lift := 0.25 * smoothstep(1.8, 2.5, t)
	var above := 1.10 + _palm_half_thickness() + 0.04
	_rig.right_hand_turn = rest
	_place_palm(false, Vector3(0.0, lerpf(above + 0.1, above, reach) + lift, lerpf(-0.2, -0.33, reach)))
	var down := 0.0
	for start: float in [2.8, 3.4]:
		down += smoothstep(start, start + FLICK_TIME, t) \
				- smoothstep(start + FLICK_TIME, start + 2.0 * FLICK_TIME, t)
	_rig.right_hand_turn = Basis(Vector3.RIGHT, -FLICK_ANGLE * down) * rest
	_rig.right_grip = 1.0 if t >= 1.5 and _scenarios[_index].get("grip", true) else 0.0
	_track_grab(_level.get_node("Dynamic/LightBox") as RigidBody3D, t)
	if t < 2.7:
		return false
	var physical := _player.physical as DynamicPhysical
	var drive := physical.right_drive
	var hand := drive.hand.global_transform
	var tracked := drive.tracked_target
	var command := drive.target
	var flick: Dictionary = _scenario_state.get_or_add("flick", {"reversals": 0, "settle": 0.0})
	for measured: Array in [["gap", hand.origin.distance_to(tracked.origin)],
			["turn", rad_to_deg(_turn_between(hand.basis, tracked.basis))],
			["command_gap", command.origin.distance_to(tracked.origin)],
			["command_turn", rad_to_deg(_turn_between(command.basis, tracked.basis))],
			["drive_gap", hand.origin.distance_to(command.origin)],
			["drive_turn", rad_to_deg(_turn_between(hand.basis, command.basis))]]:
		flick[measured[0]] = maxf(flick.get(measured[0], 0.0), measured[1])
	flick.still_held = physical.right_grab.state == HandGrab.State.HOLDING
	if t >= 3.56:
		# The hand's turn from the static hand about the flick's axis, in
		# degrees; a change under 0.05° is standing still.
		var axis: Vector3 = (_head_frame().basis * Vector3.RIGHT).normalized()
		var turn := rad_to_deg(HandDrive._rotation_between(tracked.basis, hand.basis).dot(axis))
		if flick.has("last"):
			var change: float = turn - flick.last
			if absf(change) > 0.05:
				if flick.get("heading", 0.0) != 0.0 and signf(change) != flick.heading:
					flick.reversals += 1
				flick.heading = signf(change)
		flick.last = turn
		flick.past = maxf(flick.get("past", 0.0), absf(turn))
		if absf(turn) > 1.0:
			flick.settle = t - 3.56
	return false


## The angle between two rotations, radians.
static func _turn_between(a: Basis, b: Basis) -> float:
	return (a.orthonormalized().inverse() * b.orthonormalized()).get_rotation_quaternion().get_angle()


## A 40 kg box (20 cm) on the tabletop's empty half; the right palm comes flat
## 5 cm above it by 1.2 s and grips at 1.5 s: it is seated in the hand like
## any object, and held, its weight takes the hand down. It then tries to lift
## 0.15 m. Records the box's fastest once held ("held_speed").
func _drive_grab_heavy_box(t: float) -> bool:
	if not _scenario_state.has("crate"):
		var crate := _spawn_prop(Vector3(0.2, 0.2, 0.2), 40.0, Vector3(1.0, 1.1, 0.3))
		var grabbable := Grabbable.new()
		crate.add_child(grabbable)
		_scenario_state.crate = crate
	var reach := clampf((t - 0.5) / 0.7, 0.0, 1.0)
	var lift := 0.15 * smoothstep(2.5, 3.5, t)
	var above := 1.20 + _palm_half_thickness() + 0.05
	_place_palm(false, Vector3(0.0, lerpf(above + 0.1, above, reach) + lift, lerpf(-0.2, -0.35, reach)))
	_rig.right_grip = 1.0 if t >= 1.5 else 0.0
	var crate: RigidBody3D = _scenario_state.crate
	var hand := (_player.physical as DynamicPhysical).right_drive.hand
	if t < 1.5:
		_scenario_state.hand_before = hand.global_position.y
		_scenario_state.crate_before = crate.global_position.y
	elif t <= 1.9:
		_scenario_state.hand_came = (_scenario_state.hand_before as float) - hand.global_position.y
		_scenario_state.crate_came = crate.global_position.y - (_scenario_state.crate_before as float)
	if (_player.physical as DynamicPhysical).right_grab.state == HandGrab.State.HOLDING:
		_scenario_state.held_speed = maxf(_scenario_state.get("held_speed", 0.0), crate.linear_velocity.length())
	_track_grab(crate, t)
	return false


## The held box's rise, its turn relative to the hand while held, the
## widest the hand was held off its target, and the grab's seat_time.
func _track_grab(box: RigidBody3D, t: float) -> void:
	_track_prop(box, t)
	var physical := _player.physical as DynamicPhysical
	_scenario_state.seat_time = physical.right_grab.seat_time
	var hand := physical.right_drive.hand
	var relative := hand.global_basis.orthonormalized().inverse() * box.global_basis.orthonormalized()
	if physical.right_grab.state == HandGrab.State.HOLDING:
		if not _scenario_state.has("held_turn_from"):
			_scenario_state.held_turn_from = relative
		var turned := ((_scenario_state.held_turn_from as Basis).inverse() * relative).get_rotation_quaternion().get_angle()
		_scenario_state.held_turn = maxf(_scenario_state.get("held_turn", 0.0), rad_to_deg(turned))
		var rise: float = box.global_position.y - (_scenario_state.prop_start as Vector3).y
		if t >= 3.0:
			_scenario_state.held_rise_min = minf(_scenario_state.get("held_rise_min", INF), rise)
	if physical.right_grab.state != HandGrab.State.IDLE:
		_scenario_state.hand_pulled = maxf(_scenario_state.get("hand_pulled", 0.0), physical.right_drive.separation)


## Collision layer and mask of a loose prop, from the layer table in the
## architecture document (section 6.8): on Dynamic, meeting Static, Dynamic,
## Held, Player, Hands and Enemy. Each side of a contact must mask the other.
const PROP_LAYER := 2
const PROP_MASK := 1 | 2 | 8 | 16 | 32 | 256


## A static box in the level whose top is `feet` (world), for a scenario that
## starts above the floor (a hang): the player stands on it until it is taken
## away.
func _add_stool(feet: Vector3) -> StaticBody3D:
	var stool := StaticBody3D.new()
	stool.name = "Stool"
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.6, 0.2, 0.6)
	shape.shape = box
	stool.add_child(shape)
	_level.add_child(stool)
	stool.global_position = feet + Vector3.DOWN * 0.1
	return stool


## A box-shaped loose prop added to the level for one scenario.
func _spawn_prop(size: Vector3, mass: float, position: Vector3) -> RigidBody3D:
	var prop := RigidBody3D.new()
	prop.mass = mass
	prop.collision_layer = PROP_LAYER
	prop.collision_mask = PROP_MASK
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	prop.add_child(shape)
	_level.add_child(prop)
	prop.global_position = position
	return prop


## Where a prop started, how far it has moved, how high it went and how fast.
func _track_prop(prop: RigidBody3D, t: float) -> void:
	if not _scenario_state.has("prop_start"):
		_scenario_state.prop_start = prop.global_position
	var moved: Vector3 = prop.global_position - _scenario_state.prop_start
	_scenario_state.prop_moved = [moved.x, moved.y, moved.z]
	_scenario_state.prop_rise = maxf(_scenario_state.get("prop_rise", 0.0), moved.y)
	_scenario_state.prop_speed = maxf(_scenario_state.get("prop_speed", 0.0), prop.linear_velocity.length())


## How deep the right palm's box is in the level or a prop, while `holding`.
func _track_palm_depth(holding: bool) -> void:
	if not holding:
		return
	var drive := (_player.physical as DynamicPhysical).right_drive
	var space: PhysicsDirectSpaceState3D = _level.get_world_3d().direct_space_state
	var query := PhysicsShapeQueryParameters3D.new()
	query.collision_mask = PROP_LAYER | 1
	query.exclude = [drive.hand.get_rid()]
	var palm := BoxShape3D.new()
	palm.size = drive.palm_size * _player.rig.skeleton.hand_scale
	query.shape = palm
	query.transform = drive.hand.global_transform.translated_local(
			Vector3(0.0, 0.0, -drive.palm_shift * _player.rig.skeleton.hand_scale))
	var points: Array[Vector3] = space.collide_shape(query, 8)
	var depth := 0.0
	for k in range(0, points.size() - 1, 2):
		depth = maxf(depth, points[k].distance_to(points[k + 1]))
	_scenario_state.palm_depth = maxf(_scenario_state.get("palm_depth", 0.0), depth)


## The right hand's fingers while `holding`: how deep any bone is in the level
## or a prop, as the physics engine measures it; the most any joint moved in
## one tick; and each finger's bends at the end, in degrees.
func _track_fingers(holding: bool) -> void:
	var fingers := (_player.physical as DynamicPhysical).right_fingers
	var space: PhysicsDirectSpaceState3D = _level.get_world_3d().direct_space_state
	var query := PhysicsShapeQueryParameters3D.new()
	query.collision_mask = 3
	var capsule := CapsuleShape3D.new()
	query.shape = capsule
	var depth := 0.0
	var first := HandFingers.FINGERS * HandFingers.PHALANGES
	for i in range(first, first * 2):
		var size := _state.finger_sizes[i]
		capsule.radius = size.x
		capsule.height = maxf(size.y, size.x * 2.0)
		query.transform = _state.finger_bones[i] \
				* Transform3D(HandFingers.CAPSULE_ALONG_BONE, Vector3(0.0, 0.0, -size.y * 0.5))
		var points: Array[Vector3] = space.collide_shape(query, 8)
		for k in range(0, points.size() - 1, 2):
			depth = maxf(depth, points[k].distance_to(points[k + 1]))
	var bends: Array = []
	for finger in HandFingers.FINGERS:
		bends.append(fingers.bends_of(finger) * (180.0 / PI))
	if holding:
		_scenario_state.finger_depth_held = maxf(_scenario_state.get("finger_depth_held", 0.0), depth)
		var last: Array = _scenario_state.get("last_bends", bends)
		var moved := 0.0
		for finger in HandFingers.FINGERS:
			var change: Vector3 = ((bends[finger] as Vector3) - (last[finger] as Vector3)).abs()
			moved = maxf(moved, maxf(change.x, maxf(change.y, change.z)))
		_scenario_state.finger_twitch = maxf(_scenario_state.get("finger_twitch", 0.0), moved)
		_scenario_state.finger_bends = bends.map(func(b: Vector3) -> Array: return [b.x, b.y, b.z])
		_scenario_state.finger_held = Array(fingers.held_open).map(func(h: float) -> float: return rad_to_deg(h))
	_scenario_state.last_bends = bends
	_scenario_state.finger_depth = maxf(_scenario_state.get("finger_depth", 0.0), depth)


## Standing with the capsule 3 cm from the table's front (x 0.75, top at
## 1.0 m; the eyes 0.1 m ahead of it), the head leans 0.2 m further out over
## the table and down to 1.15 m by 1.5 s, holds until 3 s and comes back by
## 4 s: the chest comes down toward the tabletop while the head stays clear of
## it. Tracks how deep any part on the body goes into the table.
func _drive_lean_over_table(t: float) -> bool:
	var lean := smoothstep(0.5, 1.5, t) - smoothstep(3.0, 4.0, t)
	_rig.head_position = Vector3(0.2 * lean, lerpf(SimulatedRig.HEAD_HEIGHT, 1.15, lean), 0.0)
	_track_part_depth([BodyParts.Part.TORSO, BodyParts.Part.HIPS, BodyParts.Part.LEFT_SHOULDER,
			BodyParts.Part.RIGHT_SHOULDER, BodyParts.Part.LEFT_UPPER_ARM, BodyParts.Part.RIGHT_UPPER_ARM],
			t >= 1.5 and t <= 3.0)
	return false


## How deep any of `parts` is in the level, as the physics engine measures
## the overlap of each part's shape where it is posed; over the whole
## scenario and while `holding`. Any shape and any surface, including a
## capsule's side across an edge.
func _track_part_depth(parts: Array, holding: bool) -> void:
	var space: PhysicsDirectSpaceState3D = _level.get_world_3d().direct_space_state
	var query := PhysicsShapeQueryParameters3D.new()
	query.collision_mask = 1
	for part: int in parts:
		if part >= _state.body_part_shapes.size() or _state.body_part_shapes[part] == null:
			continue
		query.shape = _state.body_part_shapes[part]
		query.transform = _state.body_parts[part]
		var points: Array[Vector3] = space.collide_shape(query, 8)
		var depth := 0.0
		for k in range(0, points.size() - 1, 2):
			depth = maxf(depth, points[k].distance_to(points[k + 1]))
		_scenario_state.part_sink = maxf(_scenario_state.get("part_sink", 0.0), depth)
		if holding:
			_scenario_state.part_sink_held = maxf(_scenario_state.get("part_sink_held", 0.0), depth)


## The right hand points (grip closed, index out) and reaches 1.1 m forward at
## shoulder height by 2 s, into the wall 0.65 m ahead, holds until 4 s and
## comes back. Tracks how far any finger bone sinks into the wall.
func _drive_finger_poke(t: float) -> bool:
	_rig.right_grip = 1.0
	_drive_hand_reach(t, false)
	_track_finger_sink(Plane(Vector3.FORWARD, -4.0), AABB(Vector3(-5.0, -1.0, 3.5), Vector3(10.0, 5.0, 1.0)),
			t >= 2.5 and t <= 4.0)
	return false


## The deepest any finger bone has gone into `surface` (depth below it, in
## metres), counting only bone ends inside `area`, over the whole scenario
## and while `holding`. A bone is a capsule: its lowest point is its radius
## beyond the centre of an end cap.
func _track_finger_sink(surface: Plane, area: AABB, holding: bool) -> void:
	for i in _state.finger_sizes.size():
		var size := _state.finger_sizes[i]
		if size.x <= 0.0:
			continue
		var bone := _state.finger_bones[i]
		var inner := minf(size.x, size.y * 0.5)
		for point: Vector3 in [bone * Vector3(0.0, 0.0, -inner), bone * Vector3(0.0, 0.0, inner - size.y)]:
			if area.has_point(point):
				var depth := size.x - surface.distance_to(point)
				_scenario_state.finger_sink = maxf(_scenario_state.get("finger_sink", -1.0), depth)
				if holding:
					_scenario_state.finger_sink_held = maxf(_scenario_state.get("finger_sink_held", -1.0), depth)


## Faces both palms along `palm` with the fingers along `fingers`, both in the
## head's facing, by turning the controllers: the static skeleton's own hand
## turn is undone, so the palm lies exactly as asked.
func _turn_palms(palm: Vector3, fingers: Vector3) -> void:
	for left: bool in [true, false]:
		_turn_palm(left, palm, fingers)


## Like _turn_palms, for one hand.
func _turn_palm(left: bool, palm: Vector3, fingers: Vector3) -> void:
	_rig.set("left_hand_turn" if left else "right_hand_turn", _palm_turn(left, palm, fingers))


## The controller turn that faces a palm along `palm` with its fingers along
## `fingers`, in the head's facing.
func _palm_turn(left: bool, palm: Vector3, fingers: Vector3) -> Basis:
	var skeleton := _player.rig.skeleton
	var tilt := Basis.from_euler(skeleton.hand_rotation_degrees * (PI / 180.0))
	var wanted := Basis(palm, fingers, palm.cross(fingers)).orthonormalized()
	var palm_axis := skeleton.palm_direction.normalized()
	if left:
		palm_axis.x = -palm_axis.x
	var hand := Basis(palm_axis, Vector3.FORWARD, palm_axis.cross(Vector3.FORWARD))
	return wanted * hand.inverse() * tilt.inverse()


## Where a controller puts its palm's centre now, in the head's facing: the
## reverse of _place_palm.
func _palm_of(left: bool) -> Vector3:
	var offset := _player.rig.skeleton.hand_offset
	if left:
		offset.x = -offset.x
	var turn: Basis = _rig.left_hand_turn if left else _rig.right_hand_turn
	var controller: Vector3 = _rig.left_hand if left else _rig.right_hand
	return controller + turn * offset


## The simulated head's frame in the world: its footprint on the floor,
## turned to its facing. SimulatedRig places the controllers in it.
func _head_frame() -> Transform3D:
	var footprint := Vector3(_rig.head_position.x, 0.0, _rig.head_position.z)
	return _player.rig.global_transform * Transform3D(Basis(Vector3.UP, _rig.yaw), footprint)


## Puts a controller where its palm centre lands on `palm`, in the head's
## facing, allowing for the controller's turn and the skeleton's palm offset.
func _place_palm(left: bool, palm: Vector3) -> void:
	var offset := _player.rig.skeleton.hand_offset
	if left:
		offset.x = -offset.x
	var turn: Basis = _rig.left_hand_turn if left else _rig.right_hand_turn
	_rig.set("left_hand" if left else "right_hand", palm - turn * offset)


## Sets a controller's position as if it were not turned: a turned controller
## is moved so that its palm centre lands where the unturned one's would, and
## scenarios keep their reach whichever way the palms face.
func _set_hand(left: bool, position: Vector3) -> void:
	var offset := _player.rig.skeleton.hand_offset
	if left:
		offset.x = -offset.x
	_place_palm(left, position + offset)


## Where a palm's centre sits resting flat on the table's top (1.0 m).
func _palm_rest() -> float:
	return 1.0 + _palm_half_thickness()


## How far the right palm's box reaches ahead of the hand's centre, toward its
## knuckles, in metres: its box is longer than it is centred (since 2026-10-02).
func _palm_front() -> float:
	var drive := (_player.physical as DynamicPhysical).right_drive
	return (drive.palm_size.z * 0.5 + drive.palm_shift) * _player.rig.skeleton.hand_scale


func _palm_half_thickness() -> float:
	return (_player.physical as DynamicPhysical).right_drive.palm_size.x \
			* _player.rig.skeleton.hand_scale * 0.5


## Turns the right hand 90° about X, then Y, then Z, one second each.
func _drive_hand_turn(t: float) -> bool:
	var x := PI * 0.5 * clampf(t - 0.5, 0.0, 1.0)
	var y := PI * 0.5 * clampf(t - 2.0, 0.0, 1.0)
	var z := PI * 0.5 * clampf(t - 3.5, 0.0, 1.0)
	_rig.right_hand_turn = Basis(Vector3.BACK, z) * Basis(Vector3.UP, y) * Basis(Vector3.RIGHT, x)
	return false


## Loses the right controller at 0.5 s, walks at full stick from 0.8 s to
## 2.8 s, and finds the controller again at 3.5 s.
func _drive_tracking_loss(t: float) -> bool:
	_rig.right_tracked = t < 0.5 or t >= 3.5
	_rig.stick = Vector2(0.0, 1.0) if t >= 0.8 and t < 2.8 else Vector2.ZERO
	return false


## Presses A once at 1.5 s, walking at full stick throughout if `walking`,
## and finishes once the body has been back on the ground for a second.
func _drive_jump(t: float, walking: bool) -> bool:
	_rig.stick = Vector2(0.0, 1.0) if walking and t < 4.0 else Vector2.ZERO
	_rig.right_a = t >= 1.5 and t < 1.6
	if not _state.supported:
		_scenario_state.jumped = true
	if _scenario_state.get("jumped", false) and _state.supported:
		_scenario_state.landed_for = _scenario_state.get("landed_for", 0.0) \
				+ 1.0 / Engine.physics_ticks_per_second
	return _scenario_state.get("landed_for", 0.0) >= 1.0


## Walks off the edge, lets go of the stick once falling, and finishes a
## second after the body is back on its feet at the start. The level's terrain
## (added 2026-09-25) now catches a fall off the edge at about -8.3 m, above
## the -20 m kill height, so this scenario raises the kill height to -6 m.
func _drive_respawn(_t: float) -> bool:
	(_player.physical as DynamicPhysical).locomotion.get_node("Recovery").set("kill_height", -6.0)
	if not _state.supported:
		_scenario_state.fell = true
	if not _scenario_state.get("fell", false):
		_rig.stick = Vector2(0.0, 1.0)
		return false
	_rig.stick = Vector2.ZERO
	if _state.relocations > 0 and _state.supported:
		_scenario_state.home_for = _scenario_state.get("home_for", 0.0) \
				+ 1.0 / Engine.physics_ticks_per_second
	return _scenario_state.get("home_for", 0.0) >= 1.0


## respawn, holding a 2 kg box (rung 8.2, 2026-10-02): the box is put
## weightless on the right palm's grab point and gripped at 0.2 s; once held
## it gets its weight, and from 0.6 s the player walks off the edge. Measures
## into _scenario_state.respawn_hold whether it was still held at the end,
## and after the respawn the widest gap between the grab points and the box's
## fastest (moved alone, the hand dragged a held object across the jump).
func _drive_respawn_holding(t: float) -> bool:
	var grab := (_player.physical as DynamicPhysical).right_grab
	if not _scenario_state.has("respawn_box"):
		var hand := grab.drive.hand
		var centre := grab.hand_point + hand.global_basis * grab._palm_side * 0.08
		var box := _spawn_prop(Vector3(0.15, 0.15, 0.15), 2.0, centre)
		box.gravity_scale = 0.0
		box.add_child(Grabbable.new())
		_scenario_state.respawn_box = box
		_scenario_state.respawn_hold = {"held": false, "gap_after": 0.0, "speed_after": 0.0}
	var box: RigidBody3D = _scenario_state.respawn_box
	var measure: Dictionary = _scenario_state.respawn_hold
	_rig.right_grip = 1.0 if t >= 0.2 else 0.0
	var holding := grab.state == HandGrab.State.HOLDING and grab.target == box
	if holding:
		box.gravity_scale = 1.0
	measure.held = holding
	# From the second tick after the respawn: before then the box has the
	# speed of its fall (the respawn stops it, after this runs).
	if _state.relocations > 0:
		measure.ticks_after = measure.get("ticks_after", 0) + 1
		if measure.ticks_after >= 2:
			measure.gap_after = maxf(measure.gap_after, grab.gap)
			measure.speed_after = maxf(measure.speed_after, box.linear_velocity.length())
	if t < 0.6:
		return false
	return _drive_respawn(t)


func _drive_wall(t: float) -> bool:
	# Real walking: the head moves through the room at 0.5 m/s, 1 m toward
	# the wall and back. The body can only follow until the wall stops it.
	var forward := clampf((t - 0.5) / 2.0, 0.0, 1.0) - clampf((t - 3.5) / 2.0, 0.0, 1.0)
	_rig.head_position = Vector3(0.0, SimulatedRig.HEAD_HEIGHT, forward)
	return false


## The level's tree, its trunk 1 m ahead (-X), approached from the side its
## top leans away from: full stick into the trunk from 0.5 s to 2 s; the real
## head then leans 0.5 m on toward it from 2 s to 4 s, over the trunk's foot,
## and stays there; full stick back from 5 s to 7 s, about 3 m away; then
## standing.
func _drive_tree_feet(t: float) -> bool:
	var lean := 0.5 * clampf((t - 2.0) / 2.0, 0.0, 1.0)
	_rig.head_position = Vector3(-lean, SimulatedRig.HEAD_HEIGHT, 0.0)
	if t >= 0.5 and t < 2.0:
		_rig.stick = Vector2(0.0, 1.0)
	elif t >= 5.0 and t < 7.0:
		_rig.stick = Vector2(0.0, -1.0)
	else:
		_rig.stick = Vector2.ZERO
	return false


func _drive_crouch(t: float) -> bool:
	var depth := clampf(t - 0.5, 0.0, 1.0) - clampf(t - 3.5, 0.0, 1.0)
	var head := lerpf(SimulatedRig.HEAD_HEIGHT, 0.8, depth)
	_rig.head_position = Vector3(0.0, head, 0.0)
	var hand_height := SimulatedRig.HAND_REST.y * head / SimulatedRig.HEAD_HEIGHT
	_rig.left_hand.y = hand_height
	_rig.right_hand.y = hand_height
	return false


## Looking down at the feet (2026-10-03). Bending the neck, as a person
## looking at their feet does, the neck turns about its base for two thirds of
## the nod and the head about the skull's joint on top of it for the rest
## (about the lower and upper neck's shares of a look-down), so the eyes swing
## forward and drop. Both points are where the model has them: the neck base
## 0.14 m below and 0.10 m behind the eyes, the skull's joint 0.071 m below and
## 0.073 m behind them. Nodding the head alone, it turns about one point 0.075 m
## below and 0.0805 m behind the eyes (the long-standing default VR neck
## model): the eyes come forward and drop less, the hardest case for the body
## standing still under them. Down to 60° (about where the feet are) and held,
## on to 80° and held, then level again.
const NECK_BASE := Vector3(0.0, -0.14, 0.10)
const SKULL_JOINT := Vector3(0.0, -0.071, 0.073)
const NECK_NOD_SHARE := 2.0 / 3.0
const NOD_PIVOT := Vector3(0.0, -0.075, 0.0805)
## The ends of each hold, where the look-down check samples: level, 60°, 80°,
## level again.
const LOOK_HOLDS := {"level": 0.45, "down_60": 2.95, "down_80": 4.95, "after": 6.95}


func _drive_look_down(t: float, bending_neck: bool) -> bool:
	var down := (60.0 * smoothstep(0.5, 1.5, t) + 20.0 * smoothstep(3.0, 3.75, t)) \
			* (1.0 - smoothstep(5.0, 6.0, t))
	_rig.pitch = -deg_to_rad(down)
	var head := Basis(Vector3.RIGHT, _rig.pitch)
	var eyes := NOD_PIVOT - head * NOD_PIVOT
	if bending_neck:
		eyes = NECK_BASE + Basis(Vector3.RIGHT, _rig.pitch * NECK_NOD_SHARE) * (SKULL_JOINT - NECK_BASE) \
				- head * SKULL_JOINT
	_rig.head_position = Vector3(0.0, SimulatedRig.HEAD_HEIGHT, 0.0) + Basis(Vector3.UP, _rig.yaw) * eyes
	_track_look_down(t)
	return false


## Where the static body sits under a nodding head. At the end of each hold:
## how far the neck base is behind the eyes along the facing and below them
## (m); the model's neck bend on the chest and the head's on the neck, from
## level (degrees, forward positive); and how far the sightline from the eyes
## to each toe tip passes clear of the chest, taken as the body parts' torso
## radius around the line from the hips to the chest's centre (m, negative:
## the chest hides the toes). Through the nod, from level: how far the neck
## base moved in the world, across and up (m), how far the pelvis and the feet
## moved (m), how much further the legs reached (their extension, 1 = their
## length), and the model neck's least and greatest stretch.
func _track_look_down(t: float) -> void:
	var s := _player.rig.skeleton
	var mapper := _player.pose_mapper
	if mapper == null or mapper.skeleton == null or _state.body_joints.size() != BodyParts.Joint.size():
		return
	var look: Dictionary = _scenario_state.get("look", {"holds": {}, "neck_moved": 0.0, "neck_rose": 0.0,
			"hips_moved": 0.0, "feet_moved": 0.0, "reach": 0.0, "stretch_min": INF, "stretch_max": 0.0})
	_scenario_state.look = look
	var facing := -(_player.rig.global_basis * Basis(Vector3.UP, _rig.yaw)).z
	var eyes := s.eye_tracker.global_position
	var neck := s.neck_tracker.global_position
	var model := mapper.skeleton
	var bone := func(bone_name: String) -> Transform3D:
		return model.global_transform * model.get_bone_global_pose(model.find_bone(bone_name))
	var lean := func(pose: Transform3D) -> float:
		var axis := pose.basis.y.normalized()
		return rad_to_deg(atan2(axis.dot(facing), axis.dot(Vector3.UP)))
	var neck_pose: Transform3D = bone.call("Neck")
	var neck_lean: float = lean.call(neck_pose)
	var neck_bend: float = neck_lean - lean.call(bone.call("Chest"))
	var head_bend: float = lean.call(bone.call("Head")) - neck_lean
	var stretch := neck_pose.basis.get_scale().y
	var joints := _state.body_joints
	var hips := (joints[BodyParts.Joint.LEFT_HIP] + joints[BodyParts.Joint.RIGHT_HIP]) * 0.5
	var parts := (_player.physical as DynamicPhysical).body_parts
	var toe := parts.foot_size.z - parts.heel_length
	var clear := INF
	for side in 2:
		var tip := _state.body_soles[side] * Vector3(0.0, 0.0, -toe)
		var near := Geometry3D.get_closest_points_between_segments(eyes, tip, hips, s.torso_tracker.global_position)
		clear = minf(clear, near[0].distance_to(near[1]) - parts.torso_radius)
	var feet: Array[Vector3] = [s.left_foot_tracker.global_position, s.right_foot_tracker.global_position]
	var pelvis := s.hip_tracker.global_position
	var extension := maxf(s.left_leg_extension, s.right_leg_extension)
	var flat := func(v: Vector3) -> Vector2: return Vector2(v.x, v.z)
	if t < LOOK_HOLDS.level:
		look.start = {"neck": neck, "pelvis": pelvis, "feet": feet, "extension": extension,
				"neck_bend": neck_bend, "head_bend": head_bend}
	elif look.has("start"):
		var start: Dictionary = look.start
		look.neck_moved = maxf(look.neck_moved, flat.call(neck - start.neck).length())
		look.neck_rose = maxf(look.neck_rose, neck.y - start.neck.y)
		look.hips_moved = maxf(look.hips_moved, flat.call(pelvis - start.pelvis).length())
		for side in 2:
			look.feet_moved = maxf(look.feet_moved, (feet[side] - (start.feet as Array)[side]).length())
		look.reach = maxf(look.reach, extension - start.extension)
		look.stretch_min = minf(look.stretch_min, stretch)
		look.stretch_max = maxf(look.stretch_max, stretch)
	for hold: String in LOOK_HOLDS:
		var at: float = LOOK_HOLDS[hold]
		if t > at - 0.1 and t <= at and look.has("start"):
			look.holds[hold] = {"behind": (eyes - neck).dot(facing), "below": eyes.y - neck.y,
					"neck_bend": neck_bend - look.start.neck_bend, "head_bend": head_bend - look.start.head_bend,
					"toes_clear": clear}


## The look-down checks' criteria (2026-10-03): looking down, the body sits
## back far enough to see the feet past the chest, with the neck bent as a
## neck bends (not the head folded over an upright one) and neither stretched
## nor squashed past what a neck can; level, it stands as it did; the feet stay
## planted. Bending the neck, the body stands still under the eyes (the hips
## sit back a little over the feet as the chest leans). Nodding
## the head alone, the eyes drop less than the neck's bend assumes and the
## body rises with them, its legs reaching past their length by up to 0.07
## more (the shin takes it).
func _accept_look_down(look: Dictionary, bending_neck: bool, failures: Array[String]) -> void:
	var holds: Dictionary = look.get("holds", {})
	if not _expect(failures, holds.size() == LOOK_HOLDS.size(), "every hold sampled (%d of %d)" % [
			holds.size(), LOOK_HOLDS.size()]):
		return
	for hold: String in ["level", "after"]:
		var level: Dictionary = holds[hold]
		_expect(failures, absf(level.behind - 0.10) <= 0.005,
				"%s, the neck base %.3f m behind the eyes (0.10 ± 0.005)" % [hold, level.behind])
	for hold: String in ["down_60", "down_80"]:
		var down: Dictionary = holds[hold]
		_expect(failures, down.behind >= 0.13,
				"%s, the neck base %.3f m behind the eyes (>= 0.13)" % [hold, down.behind])
		_expect(failures, down.toes_clear >= 0.05,
				"%s, the toes in sight past the chest (%.3f m clear >= 0.05)" % [hold, down.toes_clear])
		_expect(failures, down.head_bend <= 35.0 and down.neck_bend >= 15.0,
				"%s, the neck takes the nod: head on neck %.1f° <= 35, neck on chest %.1f° >= 15" % [
				hold, down.head_bend, down.neck_bend])
	_expect(failures, look.stretch_min >= 0.8 and look.stretch_max <= 1.05,
			"the model's neck %.3f to %.3f of its length (0.8 to 1.05)" % [look.stretch_min, look.stretch_max])
	_expect(failures, look.feet_moved <= 0.01, "the feet stayed planted (%.3f m <= 0.01)" % look.feet_moved)
	if bending_neck:
		_expect(failures, look.neck_moved <= 0.02 and look.neck_rose <= 0.01,
				"the body stood still: the neck base moved %.3f m <= 0.02, rose %.3f m <= 0.01" % [
				look.neck_moved, look.neck_rose])
		# The hips sit back over the planted feet as the chest leans.
		_expect(failures, look.reach <= 0.015, "the legs reached %.3f further (<= 0.015)" % look.reach)
	else:
		_expect(failures, look.reach <= 0.07, "the legs reached %.3f further (<= 0.07)" % look.reach)


## Arm pumping: both grips closed, hands swinging in opposition by
## `amplitude` metres at `frequency` Hz, the stick pushed from 1 s for `push`
## seconds.
func _drive_run(t: float, amplitude: float, frequency: float, push: float) -> bool:
	_rig.left_grip = 0.9
	_rig.right_grip = 0.9
	var swing := amplitude * sin(TAU * frequency * t)
	_rig.left_hand.y = SimulatedRig.HAND_REST.y + swing
	_rig.right_hand.y = SimulatedRig.HAND_REST.y - swing
	_rig.stick = Vector2(0.0, 1.0) if t >= 1.0 and t < 1.0 + push else Vector2.ZERO
	return false


## Running while holding: the hands pump this far (m) at this rate (Hz), as
## run_hard's, from this long after the stick goes back (s), once the held
## object is clear of the table.
const RUN_HOLD_SWING := 0.25
const RUN_HOLD_FREQUENCY := 2.5
const RUN_HOLD_CLEAR := 0.8


## A grab scenario's drive ("hold_drive") until "held_at" seconds, by which the
## right hand (the lead) holds its object lifted; from then that pose kept,
## both grips closed, the stick full back, away from the table, and once clear
## of it both hands pumped hard (together while both hold the object, in turn
## otherwise) for "run_push" seconds. Measures the hold at a run into _scenario_state.run_hold:
## the widest gap between the grab points, how far the object turned in the
## lead hand and how far its furthest point moved there since the run began,
## the body's top speed, whether every holding hand held on throughout, and
## (with _frame) what each tick's scripts and each drawn frame see of the
## object's transform.
func _drive_run_holding(t: float) -> bool:
	var scenario := _scenarios[_index]
	var held_at: float = scenario.held_at
	(scenario.hold_drive as Callable).call(minf(t, held_at))
	if t < held_at:
		return false
	var physical := _player.physical as DynamicPhysical
	var grabs: Array[HandGrab] = [physical.left_grab, physical.right_grab]
	var lead := grabs[1]
	var two_handed := scenario.has("left_grip")
	var run: Dictionary = _scenario_state.get_or_add("run_hold", {"gap_max": 0.0, "turn_max": 0.0,
			"tip_slip_max": 0.0, "speed_max": 0.0, "held_throughout": true,
			"probe": {"ticks": 0, "tick_synced": 0, "frames": 0, "frame_as_tick": 0, "server_ahead": 0}})
	if not _scenario_state.has("run_object"):
		if lead.state != HandGrab.State.HOLDING:
			run.held_throughout = false
			return false
		var held := lead.target as RigidBody3D
		_scenario_state.run_object = held
		_scenario_state.run_in_hand = lead.drive.hand.global_transform.affine_inverse() * held.global_transform
		_scenario_state.run_far = _far_point(held, lead._grip_point)
		_scenario_state.run_left_y = _rig.left_hand.y
	var object: RigidBody3D = _scenario_state.run_object
	var swing := RUN_HOLD_SWING * sin(TAU * RUN_HOLD_FREQUENCY * maxf(t - held_at - RUN_HOLD_CLEAR, 0.0))
	_rig.right_hand.y += swing
	if two_handed:
		_rig.left_hand.y += swing
	else:
		_rig.left_hand.y = (_scenario_state.run_left_y as float) - swing
		_rig.left_grip = 0.9
	_rig.stick = Vector2(0.0, -1.0) if t - held_at < RUN_HOLD_CLEAR + (scenario.run_push as float) else Vector2.ZERO
	for side in 2:
		if grabs[side].state == HandGrab.State.HOLDING and grabs[side].target == object:
			run.gap_max = maxf(run.gap_max, grabs[side].gap)
		elif side == 1 or two_handed:
			run.held_throughout = false
	if not is_instance_valid(object):
		return false
	var in_hand := lead.drive.hand.global_transform.affine_inverse() * object.global_transform
	var from: Transform3D = _scenario_state.run_in_hand
	var far: Vector3 = _scenario_state.run_far
	run.turn_max = maxf(run.turn_max, rad_to_deg(_turn_between(from.basis, in_hand.basis)))
	run.tip_slip_max = maxf(run.tip_slip_max, (from * far).distance_to(in_hand * far))
	var velocity := physical.body.linear_velocity
	run.speed_max = maxf(run.speed_max, Vector2(velocity.x, velocity.z).length())
	# How far the arm's strength holds the hand's target behind the player's
	# hand (dip and lag), and how far the hand is held off that target.
	var drive := lead.drive
	run.lag_max = maxf(run.get("lag_max", 0.0), drive.tracked_target.origin.distance_to(drive.target.origin))
	run.behind_max = maxf(run.get("behind_max", 0.0), drive.separation)
	run.carried = maxf(run.get("carried", 0.0), _state.carried_mass)
	# This runs as the tick begins (physics_frame), before any script: the
	# object's node should already hold the server's latest step.
	var probe: Dictionary = run.probe
	probe.ticks += 1
	var server: Transform3D = PhysicsServer3D.body_get_state(object.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM)
	if server.is_equal_approx(object.global_transform):
		probe.tick_synced += 1
	_scenario_state.run_tick_transform = object.global_transform
	return false


## Runs as each frame is drawn. For a run while holding: whether the held
## object's node still has the transform it had as the tick began while the
## server has stepped on, that is, whether a frame draws bodies (and the avatar
## posed from them) as the tick's scripts saw them.
func _frame() -> void:
	if _level == null or not _scenario_state.has("run_tick_transform"):
		return
	var object: RigidBody3D = _scenario_state.run_object
	if not is_instance_valid(object):
		return
	var probe: Dictionary = _scenario_state.run_hold.probe
	probe.frames += 1
	if object.global_transform.is_equal_approx(_scenario_state.run_tick_transform):
		probe.frame_as_tick += 1
	var server: Transform3D = PhysicsServer3D.body_get_state(object.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM)
	if not server.is_equal_approx(object.global_transform):
		probe.server_ahead += 1
	probe.fraction = Engine.get_physics_interpolation_fraction()


## The corner of `object`'s collision shapes' bounding boxes furthest from
## `from`, both in the object's own space: a held weapon's tip.
static func _far_point(object: CollisionObject3D, from: Vector3) -> Vector3:
	var far := from
	var to_object := object.global_transform.affine_inverse()
	for owner_id in object.get_shape_owners():
		var holder := object.shape_owner_get_owner(owner_id) as CollisionShape3D
		if holder == null or holder.shape == null:
			continue
		var box := holder.shape.get_debug_mesh().get_aabb()
		for i in 8:
			var corner := to_object * holder.global_transform * box.get_endpoint(i)
			if corner.distance_to(from) > far.distance_to(from):
				far = corner
	return far


# --- The arm's strength (Option A, 2026-09-26) ---------------------------------

## Poses both arms are held in by arm_reach_poses, the right arm's (the left
## mirrors it): its name, which way the arm points from the shoulder, which way
## the palm faces (the fingers run along the arm), and the wrist's distance
## from the shoulder as a share of the arm's length (upper arm plus forearm).
## 0.98 is nearly straight, where the elbow is most sensitive to where the
## wrist is (about 2.5 mm of elbow for 1 mm of wrist); a straighter arm is
## ill-conditioned. 1.05 is 3 cm past full reach, within the hand drive's
## reach margin, so the drive does not pull the hand in: there the posed arm
## stretches both bones and the static skeleton only its forearm.
const ARM_POSES := [
	["down", Vector3.DOWN, Vector3.LEFT, 0.98],
	["ahead", Vector3.FORWARD, Vector3.DOWN, 0.98],
	["overhead", Vector3.UP, Vector3.FORWARD, 0.98],
	["past_reach", Vector3.FORWARD, Vector3.DOWN, 1.05],
]
## Ticks a static arm must have stood still to count as at rest: a quarter of
## a second, time for the hand drive's following (1 / follow_gain, 67 ms) to
## settle a 15 mm lag to 0.2 mm.
const ARM_REST_TICKS := 18
## How far the hold-out scenarios step back from the table before holding the
## box out, in metres, so that a sagging box meets nothing.
const HOLD_STEP_BACK := 0.8
## How far the step scenario jumps the controller sideways, in metres.
const HOLD_STEP := 0.2
## grab_flick_light's wrist flick: how far down the controller turns, and how
## long it takes each way.
const FLICK_ANGLE := deg_to_rad(70.0)
const FLICK_TIME := 0.08
## The push on a free hand, in newtons.
const PUSH_FORCE := 50.0


## Stands still with both hands at rest, comparing the arms with the static
## skeleton's.
func _drive_arm_idle(_t: float) -> bool:
	_track_arms("")
	return false


## Both arms swing round their shoulders from the harness's rest pose to each
## of ARM_POSES in turn, over 1 s each (a brisk move: about 1.5 m/s at the
## hand at most), holding each for 1 s, and back to rest by 10.5 s. Poses are
## placed from where the shoulders stood at the start.
func _drive_arm_poses(t: float) -> bool:
	if not _scenario_state.has("shoulders"):
		var frame := _head_frame().affine_inverse()
		var skeleton := _player.rig.skeleton
		_scenario_state.shoulders = [frame * skeleton.left_shoulder_tracker.global_position,
				frame * skeleton.right_shoulder_tracker.global_position]
	var sequence: Array = [null]
	sequence.append_array(ARM_POSES)
	sequence.append(null)
	var move := clampi(floori((t - 0.5) / 2.0), 0, sequence.size() - 2)
	var along := smoothstep(0.5 + 2.0 * move, 1.5 + 2.0 * move, t)
	for left: bool in [true, false]:
		var shoulder: Vector3 = _scenario_state.shoulders[0 if left else 1]
		var from := _arm_pose(left, sequence[move])
		var to := _arm_pose(left, sequence[move + 1])
		_rig.set("left_hand_turn" if left else "right_hand_turn", (from[1] as Basis).slerp(to[1], along))
		_place_palm(left, shoulder + (from[0] as Vector3).slerp(to[0], along))
	var label := "moving"
	if along <= 0.0 or along >= 1.0:
		var pose: Variant = sequence[move + 1] if along >= 1.0 else sequence[move]
		label = "rest" if pose == null else String(pose[0])
	_track_arms(label)
	return false


## Where a hand's palm is from its shoulder in `pose` (one of ARM_POSES, or
## null for the harness's rest pose), in the head's facing, and its
## controller's turn.
func _arm_pose(left: bool, pose: Variant) -> Array:
	var skeleton := _player.rig.skeleton
	var shoulder: Vector3 = _scenario_state.shoulders[0 if left else 1]
	var mirror := Vector3(-1.0 if left else 1.0, 1.0, 1.0)
	if pose == null:
		return [SimulatedRig.HAND_REST * mirror + skeleton.hand_offset * mirror - shoulder, Basis.IDENTITY]
	var direction: Vector3 = pose[1] * mirror
	var wrist: float = pose[3] * (skeleton.upper_arm_length + skeleton.forearm_length)
	# The wrist sits wrist_offset behind the palm's centre, back along the
	# fingers, which run along the arm.
	return [direction * (wrist + skeleton.wrist_offset.length()),
			_palm_turn(left, (pose[2] as Vector3) * mirror, direction)]


## Standing 0.1 m from the table's front (x 0.75), both hands start above the
## table's height, clear of it (a hand at the harness's rest height would rest
## on its front edge). The right palm moves to 0.1 m over the tabletop (1.0 m),
## 0.3 m ahead and in line with the right shoulder, 0.15 m clear of the heavy
## box, by 1 s; comes down flat onto it, just touching, by 1.5 s (the wrist
## then at about 0.98 of the arm's length from the shoulder); rests there
## until 3.5 s and lifts 0.1 m by 4 s. The left hand stays where it started.
func _drive_arm_table_rest(t: float) -> bool:
	if not _scenario_state.has("palm_start"):
		_scenario_state.palm_start = _palm_of(false)
	var over := Vector3(0.15, _palm_rest() + 0.1, -0.3)
	var down := 0.1 * (smoothstep(1.0, 1.5, t) - smoothstep(3.5, 4.0, t))
	_place_palm(false, (_scenario_state.palm_start as Vector3).lerp(over, smoothstep(0.0, 1.0, t)) + Vector3.DOWN * down)
	_track_arms("on_table" if t >= 1.6 and t <= 3.5 else "")
	# Whether the fingers reach the tabletop while the palm rests (reported).
	_track_finger_sink(Plane(Vector3.UP, 1.0), TABLE_TOP,
			t >= 1.6 and t <= 3.5)
	return false


## The physical arms against the static skeleton's, every tick, both sides,
## each compared with the static pose of the tick the physics just solved:
## the physical hand (after that tick's step) with the static hand, and the
## posed elbow and bones (BodyParts posed them from the physical hand before
## the step: last tick's reading) with the static elbow and bones. The posed
## arm is read back from its shapes: the upper arm capsule runs from the
## shoulder to the elbow and the forearm on to the wrist, both raised by the
## same offset toward the back of the hand (flush with the palm), which the
## two capsules' centres give.
##
## Kept raw, and beyond an allowance: one tick of the static pose's own
## motion, the larger of its last two ticks. The drive moves the hand at its
## target's velocity from where the target is, so in steady motion the hand
## after a step is where the target will be a tick later, and when the target
## stops the hand carries on for about a tick; the posed arm is posed from
## that hand. Then the hand drive's reach clamp (by design, and reported);
## and, for the elbow past full reach, the proportional-stretch difference:
## the posed arm lengthens both bones and the static skeleton only its
## forearm, so their elbows are upper_arm_length x stretch / arm length apart
## (reported). arm_lift is the raise read back from the shapes, a check on
## the read-back: the forearm's radius less the palm's half thickness.
##
## The same differences are also kept at rest, without the allowance for
## motion: on ticks where the static hand and elbow have stood still (under
## REVERSAL_DEADBAND a tick) for ARM_REST_TICKS, time for the drive's
## following (1 / follow_gain, 67 ms) to have settled. Per `label` (unless
## empty), the raw differences and the reach are also kept for that part of
## the scenario.
func _track_arms(label: String) -> void:
	var physical := _player.physical as DynamicPhysical
	var skeleton := _player.rig.skeleton
	var upper_length := skeleton.upper_arm_length
	var length := upper_length + skeleton.forearm_length
	for side in 2:
		var left := side == 0
		var drive := physical.left_drive if left else physical.right_drive
		var shoulder := (skeleton.left_shoulder_tracker if left else skeleton.right_shoulder_tracker).global_position
		var static_hand := (skeleton.left_hand_tracker if left else skeleton.right_hand_tracker).global_transform
		var static_wrist := (skeleton.left_wrist_tracker if left else skeleton.right_wrist_tracker).global_position
		var static_elbow := (skeleton.left_elbow_tracker if left else skeleton.right_elbow_tracker).global_position
		var static_upper := (static_elbow - shoulder).normalized()
		var static_fore := (static_wrist - static_elbow).normalized()
		var hand := drive.hand.global_transform
		# Nothing held: the target is the static hand (within reach), untouched.
		_scenario_state.arm_shaped_ticks = _scenario_state.get("arm_shaped_ticks", 0) \
				+ (1 if drive.target != drive.tracked_target else 0)
		var key := "arm_last_%d" % side
		var last: Dictionary = _scenario_state.get(key, {})
		_scenario_state[key] = {"hand": hand, "static_hand": static_hand, "elbow": static_elbow,
				"upper": static_upper, "fore": static_fore, "motion": Vector4.ZERO}
		if last.is_empty():
			continue
		var upper := _state.body_parts[BodyParts.Part.LEFT_UPPER_ARM + side].origin
		var fore := _state.body_parts[BodyParts.Part.LEFT_FOREARM + side].origin
		var posed_wrist: Vector3 = (last.hand as Transform3D) * (static_hand.affine_inverse() * static_wrist)
		var lift := 2.0 * (fore - upper) + shoulder - posed_wrist
		var posed_elbow := 2.0 * upper - shoulder - lift
		# The static pose's motion over this tick and the tick before: hand,
		# hand's turn, elbow and bones.
		var last_hand: Transform3D = last.static_hand
		var moved := Vector4(static_hand.origin.distance_to(last_hand.origin),
				_angle_between(last_hand.basis, static_hand.basis), static_elbow.distance_to(last.elbow),
				maxf(static_upper.angle_to(last.upper), static_fore.angle_to(last.fore)))
		_scenario_state[key].motion = moved
		var still := moved.x <= Analysis.REVERSAL_DEADBAND and moved.z <= Analysis.REVERSAL_DEADBAND
		_scenario_state[key].still = last.get("still", 0) + 1 if still else 0
		var allowed := moved.max(last.motion)
		var motion := allowed.x
		var turn_motion := allowed.y
		var reach_clamp := static_hand.origin.distance_to(drive.tracked_target.origin)
		var hand_gap := hand.origin.distance_to(static_hand.origin)
		var hand_turn := _angle_between(hand.basis, static_hand.basis)
		var reach := static_wrist.distance_to(shoulder)
		var stretch := maxf(reach - length, 0.0)
		var stretch_gap := upper_length * stretch / length
		var elbow_gap := posed_elbow.distance_to(static_elbow)
		var elbow_motion := allowed.z
		var bone_turn := maxf((posed_elbow - shoulder).angle_to(static_upper),
				(posed_wrist - posed_elbow).angle_to(static_fore))
		var bone_motion := allowed.w
		_keep_max("arm_hand_gap", hand_gap - motion - reach_clamp)
		_keep_max("arm_hand_gap_raw", hand_gap)
		_keep_max("arm_hand_turn", rad_to_deg(hand_turn - turn_motion))
		_keep_max("arm_hand_turn_raw", rad_to_deg(hand_turn))
		_keep_max("arm_elbow_gap", elbow_gap - elbow_motion - stretch_gap)
		_keep_max("arm_elbow_raw", elbow_gap)
		_keep_max("arm_bone_turn", rad_to_deg(bone_turn - bone_motion))
		_keep_max("arm_bone_raw", rad_to_deg(bone_turn))
		_keep_max("arm_stretch", stretch)
		_keep_max("arm_stretch_gap", stretch_gap)
		_keep_max("arm_clamp", reach_clamp)
		_keep_max("arm_target_motion", moved.x)
		_keep_max("arm_lift", lift.length())
		if _scenario_state[key].still >= ARM_REST_TICKS:
			_scenario_state.arm_rest_ticks = _scenario_state.get("arm_rest_ticks", 0) + 1
			_keep_max("arm_rest_hand", hand_gap)
			_keep_max("arm_rest_turn", rad_to_deg(hand_turn))
			_keep_max("arm_rest_elbow", elbow_gap - stretch_gap)
			_keep_max("arm_rest_bone", rad_to_deg(bone_turn))
			if drive.hand == physical.right_drive.hand and _state.hand_touching[1]:
				_scenario_state.arm_rest_touching = _scenario_state.get("arm_rest_touching", 0) + 1
		if label.is_empty():
			continue
		var phases: Dictionary = _scenario_state.get_or_add("arm_phases", {})
		var phase: Dictionary = phases.get_or_add(label, {"hand": 0.0, "turn": 0.0, "elbow": 0.0,
				"bone": 0.0, "reach": 0.0, "stretch_gap": 0.0})
		phase.hand = maxf(phase.hand, hand_gap)
		phase.turn = maxf(phase.turn, rad_to_deg(hand_turn))
		phase.elbow = maxf(phase.elbow, elbow_gap)
		phase.bone = maxf(phase.bone, rad_to_deg(bone_turn))
		phase.reach = maxf(phase.reach, reach / length)
		phase.stretch_gap = maxf(phase.stretch_gap, stretch_gap)


## Keeps the largest `value` seen under `key` in the scenario's state (at
## least zero).
func _keep_max(key: String, value: float) -> void:
	_scenario_state[key] = maxf(_scenario_state.get(key, 0.0), value)


## The angle between two rotations, in radians; precise for small ones.
static func _angle_between(from: Basis, to: Basis) -> float:
	var turn := Quaternion(from.orthonormalized()).inverse() * Quaternion(to.orthonormalized())
	return 2.0 * atan2(Vector3(turn.x, turn.y, turn.z).length(), absf(turn.w))


## Grabs the scenario's box from 4 cm above (as grab_swing), lifts it 0.25 m
## by 2.5 s, steps back HOLD_STEP_BACK from the table by 3.5 s (so a sagging
## box meets nothing), and reaches out ahead of the right shoulder, at its
## height, by 4.5 s, the palm down: the wrist placed at the scenario's
## reach_share of the arm's length (0.98 unless it says otherwise) from where
## the shoulder stood at 3.5 s. The static chest then comes toward the
## reaching hand, so the arm ends less straight (hold.reach: about 0.9 of its
## length at 0.98, like scratch prototype P2's "hold 10 kg out" at 0.92).
## Then it lets go at release_at, or jumps the controller HOLD_STEP sideways
## toward the body's middle at step_at and holds.
##
## Measured (the physical hand read after each step; the tracked target and
## the command are the snapshot's hand_tracked and hand_targets for that
## step): while held out still, from 4.5 s, how the hand settles, its sag
## and whether anything but the arm bore the box; after the step, how the
## hand settles on its new place; after letting go, how it returns to its
## target.
func _drive_grab_hold_out(t: float) -> bool:
	var scenario: Dictionary = _scenarios[_index]
	var box := _level.get_node("Dynamic/" + String(scenario.box)) as RigidBody3D
	var physical := _player.physical as DynamicPhysical
	var skeleton := _player.rig.skeleton
	var release_at: float = scenario.get("release_at", INF)
	var step_at: float = scenario.get("step_at", INF)
	var reach := clampf((t - 0.5) / 0.7, 0.0, 1.0)
	var lift := 0.25 * smoothstep(1.8, 2.5, t)
	var above := 1.10 + _palm_half_thickness() + 0.04
	var near := Vector3(0.0, lerpf(above + 0.1, above, reach) + lift, lerpf(-0.2, -0.33, reach)) \
			+ (scenario.get("palm_offset", Vector3.ZERO) as Vector3)
	# Facing +X, the rig is not turned: back from the table is -X.
	_rig.head_position = Vector3(-HOLD_STEP_BACK * smoothstep(2.5, 3.5, t), SimulatedRig.HEAD_HEIGHT, 0.0)
	var palm := near
	if t >= 3.5:
		if not _scenario_state.has("hold_shoulder"):
			_scenario_state.hold_shoulder = _head_frame().affine_inverse() * skeleton.right_shoulder_tracker.global_position
		var wrist: float = scenario.get("reach_share", 0.98) * (skeleton.upper_arm_length + skeleton.forearm_length)
		var out: Vector3 = (_scenario_state.hold_shoulder as Vector3) \
				+ Vector3.FORWARD * (wrist + skeleton.wrist_offset.length())
		palm = near.lerp(out, smoothstep(3.5, 4.5, t))
	if t >= step_at:
		palm.x -= HOLD_STEP
	_place_palm(false, palm)
	_rig.right_grip = 1.0 if t >= 1.5 and t < release_at else 0.0

	var hand := physical.right_drive.hand.global_position
	var tracked := _state.hand_tracked[1].origin
	var command := _state.hand_targets[1].origin
	var held := physical.right_grab.state == HandGrab.State.HOLDING
	var touching := held and PhysicsServer3D.body_get_direct_state(box.get_rid()).get_contact_count() > 0
	if t < release_at:
		_scenario_state.still_held = held
	var hold_end := minf(release_at, step_at)
	if t >= 4.5 and t < hold_end:
		(_scenario_state.get_or_add("hold_positions", []) as Array).append(hand)
		(_scenario_state.get_or_add("hold_commands", []) as Array).append(command)
		_scenario_state.hold_touched = _scenario_state.get("hold_touched", 0) + (1 if touching else 0)
		_keep_max("hold_drop_max", tracked.y - hand.y)
		_scenario_state.hold_end = {"hand": hand, "tracked": tracked, "command": command,
				"reach": skeleton.right_wrist_tracker.global_position.distance_to(
						skeleton.right_shoulder_tracker.global_position)
						/ (skeleton.upper_arm_length + skeleton.forearm_length),
				"sag": _state.arm_sag[1], "holding": _state.arm_holding[1]}
	elif t >= hold_end and not _scenario_state.has("hold"):
		_scenario_state.hold = _hold_summary()
	if t >= step_at:
		if not _scenario_state.has("step_axis"):
			_scenario_state.step_axis = _head_frame().basis * Vector3.LEFT
		(_scenario_state.get_or_add("step_positions", []) as Array).append(hand)
		(_scenario_state.get_or_add("step_commands", []) as Array).append(command)
		_scenario_state.step_touched = _scenario_state.get("step_touched", 0) + (1 if touching else 0)
	if t >= release_at and physical.right_grab.state == HandGrab.State.IDLE:
		(_scenario_state.get_or_add("release_positions", []) as Array).append(hand)
		_scenario_state.release_target = tracked
	if t >= scenario.limit:
		if _scenario_state.has("step_positions"):
			_scenario_state.step = _step_summary()
		if _scenario_state.has("release_positions"):
			_scenario_state.release = _return_summary(_scenario_state.release_positions,
					_scenario_state.release_target)
	return false


## How the held-out hand settled while its target stood still: the command's
## sag below the tracked target (vertical, and the whole gap), the physical
## hand's drop below it (at the end and at most) and its distance from its
## command, how it came to rest along the way it sagged (down), whether
## anything but the arm bore the box (ticks touching), how far out the arm
## reached (share of its length), the command's own settling (time, and turns
## up and down), and the arm's dip (degrees) and holding torques (N·m) at the
## shoulder and wrist.
func _hold_summary() -> Dictionary:
	var positions: Array = _scenario_state.get("hold_positions", [])
	if positions.is_empty():
		return {}
	var end: Dictionary = _scenario_state.hold_end
	var tracked: Vector3 = end.tracked
	var command: Vector3 = end.command
	var hand: Vector3 = end.hand
	var hold := Analysis.settling(positions, positions[-1], Vector3.DOWN)
	hold.settle = hold.settle_ticks / float(Engine.physics_ticks_per_second)
	hold.sag = tracked.y - command.y
	hold.command_gap = tracked.distance_to(command)
	hold.drop = tracked.y - hand.y
	hold.drop_max = _scenario_state.get("hold_drop_max", 0.0)
	hold.separation = command.distance_to(hand)
	hold.touched = _scenario_state.get("hold_touched", 0)
	hold.reach = end.reach
	var commands: Array = _scenario_state.hold_commands
	var commanded := Analysis.settling(commands, commands[-1], Vector3.DOWN)
	hold.command_settle = commanded.settle_ticks / float(Engine.physics_ticks_per_second)
	hold.command_reversals = commanded.reversals + commanded.settled_reversals
	var sag: Vector2 = end.sag
	var holding: Vector2 = end.holding
	hold.arm_sag = [rad_to_deg(sag.x), rad_to_deg(sag.y)]
	hold.arm_holding = [holding.x, holding.y]
	return hold


## How the hand went over after the controller's jump sideways and settled
## where it now sags to (its last position): Analysis.settling() along the
## jump, how far it moved, and its turns up and down; the same for the
## command (the arm's strength shaping the jumped target), to tell the drive's
## part from the arm's; and whether anything but the arm bore the box.
func _step_summary() -> Dictionary:
	var positions: Array = _scenario_state.step_positions
	var commands: Array = _scenario_state.step_commands
	var axis: Vector3 = _scenario_state.step_axis
	var step := Analysis.settling(positions, positions[-1], axis)
	step.moved = (positions[-1] as Vector3).distance_to(positions[0])
	step.settle = step.settle_ticks / float(Engine.physics_ticks_per_second)
	step.vertical_reversals = Analysis.reversals(positions, Vector3.UP)
	var command := Analysis.settling(commands, commands[-1], axis)
	step.command_overshoot = command.overshoot
	step.command_reversals = command.reversals + command.settled_reversals
	step.command_vertical_reversals = Analysis.reversals(commands, Vector3.UP)
	step.command_settle = command.settle_ticks / float(Engine.physics_ticks_per_second)
	step.touched = _scenario_state.get("step_touched", 0)
	return step


## How a let-go hand returned to its still target `target` from `positions`
## (the first where it was let go): Analysis.settling() along the way back,
## the distance it started from, the return time and where it ended.
func _return_summary(positions: Array, target: Vector3) -> Dictionary:
	var start: Vector3 = positions[0]
	var returned := Analysis.settling(positions, target, (target - start).normalized())
	returned.start_gap = start.distance_to(target)
	returned.settle = returned.settle_ticks / float(Engine.physics_ticks_per_second)
	returned.final_gap = (positions[-1] as Vector3).distance_to(target)
	return returned


## Both hands at rest, the controllers still. From 1 s to 2 s a steady
## PUSH_FORCE push to the right acts on the right hand's centre, as if
## something shoved it aside; then it stops and the hand returns to its
## target. Each tick's reading is the hand after the step before it, so the
## first reading after the push is where the push left it, and the return
## starts there. Measured: how far the push held the hand off its target (at
## most, and at the end), its turns back and forth while pushed, and its
## wobble (Analysis.wobble()) once the push had held it for ARM_REST_TICKS;
## then how it returned.
func _drive_push_free_hand(t: float) -> bool:
	var drive := (_player.physical as DynamicPhysical).right_drive
	var hand := drive.hand.global_position
	var target := drive.target.origin
	if _scenario_state.get("pushed", false):
		(_scenario_state.get_or_add("push_positions", []) as Array).append(hand)
		_keep_max("push_offset_max", hand.distance_to(target))
		_scenario_state.push_offset = hand.distance_to(target)
	elif _scenario_state.has("push_positions"):
		var returning: Array = _scenario_state.get_or_add("return_positions",
				[(_scenario_state.push_positions as Array)[-1]])
		returning.append(hand)
	_scenario_state.pushed = t >= 1.0 and t < 2.0
	if _scenario_state.pushed:
		drive.hand.apply_central_force(Vector3.RIGHT * PUSH_FORCE)
	if t >= _scenarios[_index].limit and _scenario_state.has("return_positions"):
		var pushed: Array = _scenario_state.push_positions
		_scenario_state.push = {"offset_max": _scenario_state.get("push_offset_max", 0.0),
				"offset": _scenario_state.get("push_offset", 0.0),
				"reversals": Analysis.reversals(pushed, Vector3.RIGHT),
				"jitter": Analysis.wobble(pushed.slice(ARM_REST_TICKS)), "ticks": pushed.size()}
		_scenario_state.release = _return_summary(_scenario_state.return_positions, target)
	return false
