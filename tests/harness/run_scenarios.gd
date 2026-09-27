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
## was) unless it sets "weapons".
const WEAPONS: Array[NodePath] = [^"Dynamic/Sword", ^"Dynamic/Dagger"]
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
	var no_hands: bool = scenario.get("no_hands", false)
	var t := _time - (NO_HANDS_SETTLE if no_hands else SETTLE)
	var finished := false
	if t >= 0.0:
		if no_hands:
			_rig.left_tracked = false
			_rig.right_tracked = false
		if not scenario.get("guided", false) and not _debug.recorder.recording:
			_debug.recorder.start(_directory, scenario.name)
			_scenario_state.start_height = _state.body_position.y
		finished = (scenario.drive as Callable).call(t) or t >= scenario.limit
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
	if not scenario.get("weapons", false):
		for path in WEAPONS:
			var weapon := _level.get_node_or_null(path)
			if weapon != null:
				weapon.get_parent().remove_child(weapon)
				weapon.free()
	_player = _place_player(_level, scenario.start)
	if _player == null:
		push_error("run_scenarios: the level has no Player.")
		quit(1)
		return
	root.add_child(_level)
	if scenario.has("palms"):
		var palms: Array = scenario.palms
		_turn_palms(palms[0], palms[1])
	_debug = _player.enable_debug()
	_state = _player.physical.snapshot
	if scenario.get("guided", false):
		_debug.start_guided(SMOKE_DIRECTORY)
	_time = 0.0
	_scenario_state = {"phase": 0, "phase_start": 0.0}
	# Where the level lays the weapons, before a physics step moves them.
	if scenario.get("weapons", false):
		for path in WEAPONS:
			var weapon := _level.get_node(path) as Node3D
			_scenario_state["placed_" + String(weapon.name)] = weapon.global_transform


## Finds the level's player, swaps in the requested player scene if there is
## one, and puts it at `start`. The level is not in the tree yet.
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
	player.position = start
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
			for key: String in ["finger_depth", "finger_depth_held", "finger_twitch", "finger_bends",
					"finger_held", "box_moved", "prop_moved", "prop_rise", "prop_speed", "palm_depth", "kicked",
					"wrist_turn", "held_rise_min", "held_rise_max", "box_tilt", "held_turn", "hand_pulled",
					"rise_LightBox", "rise_MediumBox", "hand_came", "crate_came",
					"swing_gap", "swing_separation", "swing_past", "swing_behind", "still_held", "swing_hand_past",
					"arm_shaped_ticks", "arm_hand_gap", "arm_hand_gap_raw", "arm_hand_turn", "arm_hand_turn_raw",
					"arm_elbow_gap", "arm_elbow_raw", "arm_bone_turn", "arm_bone_raw", "arm_stretch",
					"arm_stretch_gap", "arm_clamp", "arm_target_motion", "arm_lift", "arm_phases",
					"arm_rest_ticks", "arm_rest_hand", "arm_rest_turn", "arm_rest_elbow", "arm_rest_bone",
					"arm_rest_touching", "grab_on_handle", "weapon_rest",
					"hold", "release", "step", "push", "flick"]:
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
	# steps are (step checks include props, section 6.8).
	if result.name not in ["steps", "walk_kick_box"]:
		_expect(failures, lifts.is_empty(), "no step lift (%d)" % lifts.size())
	_expect(failures, result.get("hand_recoveries", 0) == 0,
			"no hand moved to its target after sticking (%d)" % result.get("hand_recoveries", 0))
	var fade: float = result.get("fade_max", 0.0)
	if result.name not in ["wall", "wall_through", "respawn"]:
		_expect(failures, fade == 0.0, "view never faded (%.2f)" % fade)
	if result.name not in ["wall_through", "respawn"]:
		_expect(failures, a.relocations == 0, "no recentre or respawn (%d)" % a.relocations)
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
			# Gripped, the box comes up into the palm quickly and is held there
			# as the hand lifts, keeping its rotation relative to the hand; let
			# go, it drops back onto the table.
			var moved: Array = result.get("prop_moved", [0.0, 0.0, 0.0])
			_expect(failures, a.grabs == 1, "grabbed once (%d)" % a.grabs)
			_expect(failures, a.grab_pull_time >= 0.0 and a.grab_pull_time <= 0.25,
					"pulled into the hand in %.3f s <= 0.25" % a.grab_pull_time)
			_expect(failures, a.grab_gap_held_max <= 0.01, "held at the grab point (%.4f m off at most)" % a.grab_gap_held_max)
			_expect(failures, result.get("held_rise_min", 0.0) >= 0.18,
					"it came up with the hand (%.3f m)" % result.get("held_rise_min", 0.0))
			_expect(failures, result.get("held_turn", 90.0) <= 3.0,
					"it kept its rotation in the hand (%.1f°)" % result.get("held_turn", 90.0))
			_expect(failures, result.get("hand_pulled", 1.0) <= 0.05,
					"a 2 kg box did not drag the hand (%.3f m)" % result.get("hand_pulled", 1.0))
			_expect(failures, absf(moved[1]) <= 0.02, "let go, it dropped back onto the table (%.3f m)" % moved[1])
		"grab_sword_table", "grab_dagger_table":
			# As grab_lift_box, for a weapon lying on the table: gripped over
			# the middle of its handle, it is grabbed by the handle (not the
			# guard or blade), comes up into the palm and is held there as the
			# hand lifts; let go, it drops back onto the table where it was.
			var moved: Array = result.get("prop_moved", [0.0, 0.0, 0.0])
			var aside := Vector2(moved[0], moved[2]).length()
			_expect(failures, a.grabs == 1, "grabbed once (%d)" % a.grabs)
			_expect(failures, result.get("grab_on_handle", false), "grabbed by the handle")
			_expect(failures, a.grab_pull_time >= 0.0 and a.grab_pull_time <= 0.25,
					"pulled into the hand in %.3f s <= 0.25" % a.grab_pull_time)
			_expect(failures, a.grab_gap_held_max <= 0.01, "held at the grab point (%.4f m off at most)" % a.grab_gap_held_max)
			_expect(failures, result.get("held_rise_min", 0.0) >= 0.18,
					"it came up with the hand (%.3f m)" % result.get("held_rise_min", 0.0))
			_expect(failures, result.get("held_turn", 90.0) <= 3.0,
					"it kept its rotation in the hand (%.1f°)" % result.get("held_turn", 90.0))
			_expect(failures, result.get("hand_pulled", 1.0) <= 0.05,
					"it did not drag the hand (%.3f m)" % result.get("hand_pulled", 1.0))
			_expect(failures, absf(moved[1]) <= 0.02 and aside <= 0.05,
					"let go, it dropped back onto the table (%.3f m down, %.3f m aside)" % [moved[1], aside])
		"weapons_rest":
			# Left alone, the weapons stay where the level lays them, no corner
			# in the table: bodies of several shapes settled up to the 5 mm
			# penetration slop deep until they reported contacts (2026-09-27).
			# Laid flat, each rocks about a degree onto its blade's tip, which
			# is thinner than the grip or guard, within 0.1 s of loading.
			var rest: Dictionary = result.get("weapon_rest", {})
			for weapon: String in ["Sword", "Dagger"]:
				var entry: Dictionary = rest.get(weapon, {})
				_expect(failures, entry.get("moved", 1.0) <= 0.002,
						"%s stayed where it was laid (%.4f m <= 0.002)" % [weapon, entry.get("moved", 1.0)])
				_expect(failures, entry.get("turned", 90.0) <= 1.5,
						"%s only settled onto its blade's tip (%.2f° <= 1.5)" % [weapon, entry.get("turned", 90.0)])
				_expect(failures, entry.get("sink", 1.0) <= 0.001,
						"%s rests on the tabletop (%.4f m into it <= 0.001)" % [weapon, entry.get("sink", 1.0)])
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
			# The pull acts on both: a 40 kg box brings the hand down to it
			# more than it comes up to the hand, and nothing is thrown.
			_expect(failures, a.grabs == 1, "grabbed once (%d)" % a.grabs)
			_expect(failures, result.get("hand_came", 0.0) > result.get("crate_came", 1.0),
					"the hand went to the box (%.3f m) more than the box came up (%.3f m)" % [
					result.get("hand_came", 0.0), result.get("crate_came", 1.0)])
			_expect(failures, result.get("prop_speed", 9.0) <= 1.0,
					"nothing thrown (%.2f m/s)" % result.get("prop_speed", 9.0))
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
			# A foot walking into a small box kicks it along: the legs pass
			# into the level but meet props.
			var moved: Array = result.get("prop_moved", [0.0, 0.0, 0.0])
			var kicked: Dictionary = result.get("kicked", {})
			var by_legs := kicked.keys().filter(func(part: String) -> bool:
					return part.begins_with("PropsOnlyParts/"))
			_expect(failures, not by_legs.is_empty(), "the legs pushed it (%s)" % JSON.stringify(kicked))
			_expect(failures, Vector2(moved[0], moved[2]).length() >= 0.1,
					"it was kicked along (%.3f m)" % Vector2(moved[0], moved[2]).length())
			_expect(failures, result.get("prop_speed", 9.0) <= 3.0,
					"kicked, not launched (%.2f m/s)" % result.get("prop_speed", 9.0))
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
		{"name": "flat_full", "title": "Full stick 5 s on the flat, release",
				"start": Vector3(-4.3, 0.0, -3.5), "facing": along_x, "limit": 8.0,
				"drive": func(t: float) -> bool:
					_rig.stick = Vector2(0.0, 1.0) if t >= 0.5 and t < 5.5 else Vector2.ZERO
					return false},
		{"name": "flat_half", "title": "Half stick 6 s on the flat, release",
				"start": Vector3(-4.3, 0.0, -3.5), "facing": along_x, "limit": 8.5,
				"drive": func(t: float) -> bool:
					_rig.stick = Vector2(0.0, 0.5) if t >= 0.5 and t < 6.5 else Vector2.ZERO
					return false},
		{"name": "steps", "title": "Up the three 0.25 m steps, then back down",
				"start": Vector3(1.9, 0.0, 2.0), "facing": along_x, "limit": 14.0,
				"drive": _drive_steps},
		{"name": "ramp", "title": "Down the long 15° ramp, then back up",
				"start": Vector3(4.5, 0.0, -5.5), "facing": Vector3.LEFT, "limit": 22.0,
				"drive": _drive_ramp},
		{"name": "lower_ramp", "title": "Up the lower 15° ramp to the platform",
				"start": Vector3(-5.5, -4.0, 1.5), "facing": Vector3.FORWARD, "limit": 7.0,
				"drive": func(_t: float) -> bool:
					# Stop on the platform at the top: past it is the level's edge.
					_rig.stick = Vector2(0.0, 1.0) if _state.body_position.z > -5.4 else Vector2.ZERO
					return _state.body_position.z <= -5.4},
		{"name": "drop", "title": "Walk into the floor hole and land 4 m below",
				"start": Vector3(-4.0, 0.0, 1.2), "facing": Vector3.BACK, "limit": 6.0,
				"drive": _drive_drop},
		{"name": "wall", "title": "Walk the real head 1 m into the wall, then back",
				"start": Vector3(0.0, 0.0, 3.0), "facing": Vector3.BACK, "limit": 6.5,
				"no_hands": true, "drive": _drive_wall},
		{"name": "wall_through", "title": "Walk the real head 1.5 m into the wall and stay",
				"start": Vector3(0.0, 0.0, 3.0), "facing": Vector3.BACK, "limit": 6.0,
				"no_hands": true, "drive": func(t: float) -> bool:
					var forward := 1.5 * clampf((t - 0.5) / 3.0, 0.0, 1.0)
					_rig.head_position = Vector3(0.0, SimulatedRig.HEAD_HEIGHT, forward)
					return false},
		{"name": "crouch", "title": "Crouch to 0.8 m head height, hold, stand",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 6.0,
				"drive": _drive_crouch},
		{"name": "run_moderate", "title": "Grips + moderate arm pumping + full stick",
				"start": Vector3(-4.3, 0.0, -3.5), "facing": along_x, "limit": 4.5,
				"drive": func(t: float) -> bool: return _drive_run(t, 0.15, 1.5, 1.8)},
		{"name": "run_hard", "title": "Grips + hard arm pumping + full stick",
				"start": Vector3(-4.3, 0.0, -3.5), "facing": along_x, "limit": 3.5,
				"drive": func(t: float) -> bool: return _drive_run(t, 0.25, 2.5, 1.1)},
		{"name": "room_walk", "title": "Walk around the room without the stick",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 8.0,
				"drive": _drive_room_walk},
		{"name": "stick_room_walk", "title": "Full stick while really walking with, against and across it",
				"start": Vector3(-4.3, 0.0, -3.5), "facing": along_x, "limit": 7.0,
				"drive": _drive_stick_room_walk},
		{"name": "slope_walk", "title": "Walk down and up the 15° ramp without the stick",
				"start": Vector3(2.0, -0.51, -5.5), "facing": Vector3.LEFT, "limit": 7.0,
				"drive": _drive_slope_walk},
		{"name": "table_straight", "title": "Walk the real head straight into the pedestal",
				"start": Vector3(-0.3, 0.0, 0.0), "facing": Vector3.RIGHT, "limit": 6.0,
				"no_hands": true,
				"drive": func(t: float) -> bool: return _drive_head_to(t, Vector3(1.5, 0.0, 0.0))},
		{"name": "table_oblique", "title": "Walk the real head into the pedestal at an angle",
				"start": Vector3(-0.3, 0.0, -0.3), "facing": Vector3.RIGHT, "limit": 6.0,
				"no_hands": true,
				"drive": func(t: float) -> bool: return _drive_head_to(t, Vector3(1.4, 0.0, 0.6))},
		{"name": "hands_free", "title": "Both hands trace circles in the air",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 4.0,
				"drive": _drive_hands_free},
		{"name": "hand_wall_one", "title": "Push one hand into the wall",
				"start": Vector3(0.0, 0.0, 3.35), "facing": Vector3.BACK, "limit": 5.5,
				"palms": PALMS_TO_WALL,
				"drive": func(t: float) -> bool: return _drive_hand_reach(t, false)},
		{"name": "hand_wall_two", "title": "Push both hands hard into the wall",
				"start": Vector3(0.0, 0.0, 3.65), "facing": Vector3.BACK, "limit": 5.5,
				"palms": PALMS_TO_WALL,
				"drive": func(t: float) -> bool: return _drive_hand_reach(t, true)},
		{"name": "push_steps", "title": "Push the wall with both hands a little, then more",
				"start": Vector3(0.0, 0.0, 3.55), "facing": Vector3.BACK, "limit": 6.0,
				"palms": PALMS_TO_WALL, "drive": _drive_push_steps},
		{"name": "hand_table_press", "title": "Press the right hand down on the table",
				"start": Vector3(0.45, 0.0, 0.0), "facing": Vector3.RIGHT, "limit": 4.5,
				"palms": PALMS_DOWN,
				"drive": _drive_table_press},
		{"name": "vault", "title": "Press both hands down on the table, a little then more, and let go",
				"start": Vector3(0.53, 0.0, 0.0), "facing": Vector3.RIGHT, "limit": 7.0,
				"palms": PALMS_DOWN, "head_height": 1.45,
				"drive": _drive_vault},
		{"name": "palm_slide", "title": "Rest the right palm on the table and slide it across, then press and pull",
				"start": Vector3(0.35, 0.0, 0.0), "facing": Vector3.RIGHT, "limit": 7.0,
				"palms": PALMS_DOWN, "drive": _drive_palm_slide},
		{"name": "fingers_curl", "title": "Close both hands, open them, make fists, then point",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 7.0,
				"drive": _drive_fingers_curl},
		{"name": "fingers_table", "title": "Lay an open right hand flat on the table and press",
				"start": Vector3(0.35, 0.0, 0.0), "facing": Vector3.RIGHT, "limit": 5.0,
				"palms": PALMS_DOWN, "drive": _drive_fingers_table},
		{"name": "fingers_close_on_table", "title": "Close an open hand held just above the table, then lift it",
				"start": Vector3(0.35, 0.0, 0.0), "facing": Vector3.RIGHT, "limit": 5.0,
				"palms": PALMS_DOWN, "drive": _drive_fingers_close_on_table},
		{"name": "fingers_wrap_edge", "title": "Hold the table's front face, fingers up past its edge, tilted, and close",
				"start": Vector3(0.35, 0.0, 0.0), "facing": Vector3.RIGHT, "limit": 4.5,
				"palms": [Vector3.FORWARD, Vector3.UP.rotated(Vector3.FORWARD, deg_to_rad(20.0))],
				"drive": _drive_fingers_wrap_edge},
		{"name": "fingers_grip_box", "title": "Lay a hand on the light box, fingers over its far edge at a corner, and close",
				"start": Vector3(0.45, 0.0, -0.34), "facing": Vector3.RIGHT, "limit": 4.5,
				"palms": PALMS_DOWN, "drive": _drive_fingers_grip_box},
		{"name": "palm_push_box", "title": "Push the light box 0.2 m across the table with the right palm",
				"start": Vector3(0.65, 0.0, -0.4), "facing": Vector3.RIGHT, "limit": 4.0,
				"palms": PALMS_TO_WALL, "drive": _drive_palm_push_box},
		{"name": "walk_push_crate", "title": "Walk at full stick into an 8 kg crate on the floor and push it",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 5.0,
				"no_hands": true, "drive": _drive_walk_push_crate},
		{"name": "walk_kick_box", "title": "Walk at full stick past a small box on the floor, in line with the right foot",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 3.0,
				"no_hands": true, "drive": _drive_walk_kick_box},
		{"name": "palms_lift_box", "title": "Squeeze a 5 kg box between both palms and lift it 0.15 m, no grip",
				"start": Vector3(0.65, 0.0, 0.3), "facing": Vector3.RIGHT, "limit": 5.0,
				"drive": _drive_palms_lift_box},
		{"name": "grab_lift_box", "title": "Grip above the light box, lift it 0.2 m, hold, let go",
				"start": Vector3(0.65, 0.0, -0.4), "facing": Vector3.RIGHT, "limit": 5.5,
				"palms": PALMS_DOWN, "hand_height": 1.35, "drive": _drive_grab_lift_box},
		{"name": "grab_picks_closest", "title": "Grip between two boxes, nearer the medium box, and lift",
				"start": Vector3(0.65, 0.0, -0.31), "facing": Vector3.RIGHT, "limit": 4.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "drive": _drive_grab_picks_closest},
		{"name": "grab_swing_medium", "title": "Grab the 5 kg box, lift it and swing it fast side to side",
				"start": Vector3(0.65, 0.0, -0.25), "facing": Vector3.RIGHT, "limit": 5.5,
				"palms": PALMS_DOWN, "hand_height": 1.35, "box": "MediumBox", "drive": _drive_grab_swing},
		{"name": "grab_swing_heavy", "title": "Grab the 10 kg box, lift it and swing it fast side to side",
				"start": Vector3(0.65, 0.0, -0.1), "facing": Vector3.RIGHT, "limit": 5.5,
				"palms": PALMS_DOWN, "hand_height": 1.35, "box": "HeavyBox", "drive": _drive_grab_swing},
		{"name": "grab_whip_heavy", "title": "Grab the 10 kg box and whip it side to side as fast as a player can",
				"start": Vector3(0.65, 0.0, -0.1), "facing": Vector3.RIGHT, "limit": 5.5,
				"palms": PALMS_DOWN, "hand_height": 1.35, "box": "HeavyBox", "swing_time": 0.12,
				"swing_reach": 0.6, "drive": _drive_grab_swing},
		{"name": "grab_heavy_box", "title": "Grip 5 cm above a 40 kg box and try to lift it",
				"start": Vector3(0.65, 0.0, 0.3), "facing": Vector3.RIGHT, "limit": 4.5,
				"palms": PALMS_DOWN, "hand_height": 1.35, "drive": _drive_grab_heavy_box},
		{"name": "lean_over_table", "title": "Lean over the table, chest down toward it, hold, stand",
				"start": Vector3(0.62, 0.0, 0.0), "facing": Vector3.RIGHT, "limit": 4.5,
				"no_hands": true, "drive": _drive_lean_over_table},
		{"name": "finger_poke", "title": "Point the right index finger and push it into the wall",
				"start": Vector3(0.0, 0.0, 3.35), "facing": Vector3.BACK, "limit": 5.5,
				"no_hands": false, "drive": _drive_finger_poke},
		{"name": "hand_turn", "title": "Turn the right hand 90° about each axis",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 5.5,
				"drive": _drive_hand_turn},
		{"name": "hand_tracking_loss", "title": "Lose the right controller while walking",
				"start": Vector3(-4.3, 0.0, -3.5), "facing": Vector3.RIGHT, "limit": 5.0,
				"drive": _drive_tracking_loss},
		{"name": "jump", "title": "Press A standing still, and land",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 4.0,
				"drive": func(t: float) -> bool: return _drive_jump(t, false)},
		{"name": "jump_walk", "title": "Press A while walking at full stick, and land",
				"start": Vector3(-4.3, 0.0, -3.5), "facing": along_x, "limit": 5.0,
				"drive": func(t: float) -> bool: return _drive_jump(t, true)},
		{"name": "respawn", "title": "Walk off the level's edge and be respawned",
				"start": Vector3(4.5, 0.0, 0.0), "facing": Vector3.RIGHT, "limit": 8.0,
				"drive": _drive_respawn},
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
		{"name": "arm_table_rest", "title": "Rest the right palm on the table: the arms match the static skeleton's",
				"start": Vector3(0.55, 0.0, 0.0), "facing": Vector3.RIGHT, "limit": 4.5,
				"palms": PALMS_DOWN, "hand_height": 1.35, "drive": _drive_arm_table_rest},
		{"name": "arm_room_walk", "title": "Walk around the room without the stick: the arms match the static skeleton's",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 8.0,
				"drive": func(t: float) -> bool:
					_drive_room_walk(t)
					_track_arms("")
					return false},
		{"name": "grab_hold_out_light", "title": "Grab the 2 kg box, step back, hold it out at shoulder height, let go",
				"start": Vector3(0.65, 0.0, -0.4), "facing": Vector3.RIGHT, "limit": 8.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "box": "LightBox", "release_at": 6.5,
				"drive": _drive_grab_hold_out},
		{"name": "grab_hold_out_heavy", "title": "Grab the 10 kg box, step back, hold it out at shoulder height, let go",
				"start": Vector3(0.65, 0.0, -0.1), "facing": Vector3.RIGHT, "limit": 8.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "box": "HeavyBox", "release_at": 6.5,
				"drive": _drive_grab_hold_out},
		{"name": "grab_step_heavy", "title": "Holding the 10 kg box out, jump the controller 0.2 m sideways and hold",
				"start": Vector3(0.65, 0.0, -0.1), "facing": Vector3.RIGHT, "limit": 8.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "box": "HeavyBox", "reach_share": 0.9, "step_at": 6.0,
				"drive": _drive_grab_hold_out},
		{"name": "grab_flick_light", "title": "Grab the 2 kg box, lift it and flick the wrist down and back twice",
				"start": Vector3(0.65, 0.0, -0.4), "facing": Vector3.RIGHT, "limit": 5.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "drive": _drive_grab_flick},
		{"name": "hand_flick", "title": "The same wrist flick with an empty hand, for reference",
				"start": Vector3(0.65, 0.0, -0.4), "facing": Vector3.RIGHT, "limit": 5.0,
				"palms": PALMS_DOWN, "hand_height": 1.35, "grip": false, "drive": _drive_grab_flick},
		{"name": "push_free_hand", "title": "Push the free right hand aside with 50 N for 1 s, then let go",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 4.0,
				"drive": _drive_push_free_hand},
		# The weapons on the table (2026-09-27); only these keep them (WEAPONS).
		{"name": "weapons_rest", "title": "Leave the sword and dagger lying on the table: they stay where the level lays them, on its top",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 3.0, "weapons": true,
				"drive": _drive_weapons_rest},
		{"name": "grab_sword_table", "title": "Grip the sword by its handle where it lies on the table, lift it 0.2 m, hold, let go",
				"start": Vector3(0.65, 0.0, 0.54), "facing": Vector3.RIGHT, "limit": 5.5,
				"palms": PALMS_DOWN, "hand_height": 1.35, "weapons": true, "weapon": ^"Dynamic/Sword",
				"drive": _drive_grab_weapon},
		{"name": "grab_dagger_table", "title": "Grip the dagger by its handle where it lies on the table, lift it 0.2 m, hold, let go",
				"start": Vector3(0.65, 0.0, 0.34), "facing": Vector3.RIGHT, "limit": 5.5,
				"palms": PALMS_DOWN, "hand_height": 1.35, "weapons": true, "weapon": ^"Dynamic/Dagger",
				"drive": _drive_grab_weapon},
	]


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
	_track_finger_sink(Plane(Vector3.UP, 1.0), AABB(Vector3(0.75, 0.5, -0.5), Vector3(0.5, 1.0, 1.0)),
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
	_track_finger_sink(Plane(Vector3.UP, 1.0), AABB(Vector3(0.75, 0.5, -0.5), Vector3(0.5, 1.0, 1.0)),
			t >= 2.3 and t <= 3.5)
	return false


## The right palm comes flat against the table's front face (x 0.75), its
## knuckles 1.5 cm above the top edge and the hand tilted 20° about the palm,
## by 1.5 s; grip and trigger close by 2.3 s and stay closed, wrapping the
## fingers over the edge onto the tabletop, each where it meets it.
func _drive_fingers_wrap_edge(t: float) -> bool:
	var reach := clampf((t - 0.5) / 1.0, 0.0, 1.0)
	var close := clampf((t - 2.0) / 0.3, 0.0, 1.0)
	var length := (_player.physical as DynamicPhysical).right_drive.palm_size.z * _player.rig.skeleton.hand_scale
	var height := 1.0 - length * 0.5 + 0.015
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
	var length := (_player.physical as DynamicPhysical).right_drive.palm_size.z * _player.rig.skeleton.hand_scale
	var top := 1.10 + _palm_half_thickness() + 0.002
	# About the fingers, not grabbing: the boxes are not grabbable here.
	for box: String in ["LightBox", "MediumBox", "HeavyBox"]:
		Grabbable.of(_level.get_node("Dynamic/" + box)).enabled = false
	_place_palm(false, Vector3(0.0, lerpf(top + 0.08, top, reach), lerpf(-0.25, -(1.03 - 0.45 - length * 0.5), reach)))
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
## it: the legs are on their own kinematic body, so this is where they meet
## props.
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


## As _drive_grab_lift_box, over the middle of the scenario's weapon's handle
## (its Grip collider) where the weapon lies on the table: fingers across the
## handle, 4 cm above it by 1.2 s; the grip closes at 1.5 s; the hand lifts
## 0.2 m by 3 s and holds until 4 s, when the grip opens and the weapon drops.
## Records whether the grab point was on the handle.
func _drive_grab_weapon(t: float) -> bool:
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
	_place_palm(false, Vector3(handle.z - start.z, lerpf(above + 0.1, above, reach) + lift,
			-lerpf(ahead - 0.13, ahead, reach)))
	_rig.right_grip = 1.0 if t >= 1.5 and t < 4.0 else 0.0
	_track_grab(weapon, t)
	var hand_grab := (_player.physical as DynamicPhysical).right_grab
	if hand_grab.state != HandGrab.State.IDLE and not _scenario_state.has("grab_on_handle"):
		var point := weapon.global_transform.affine_inverse() * hand_grab.object_point
		# Within 0.1 mm: the guard stands 0.5 mm prouder than the grip beside it.
		_scenario_state.grab_on_handle = (grip.transform * AABB(-size * 0.5, size)).grow(0.0001).has_point(point)
	return false


## The table's weapons left alone: the most each moves and turns from where the
## level lays it, and how deep a corner of its colliders goes into the tabletop.
func _drive_weapons_rest(_t: float) -> bool:
	var rest: Dictionary = _scenario_state.get("weapon_rest", {})
	for path in WEAPONS:
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


## How far the lowest corner of `body`'s box colliders over the table is below
## its top (1.0 m), or 0 if none is.
func _table_sink(body: RigidBody3D) -> float:
	var table := AABB(Vector3(0.75, 0.5, -0.5), Vector3(0.5, 1.0, 1.0))
	var sink := 0.0
	for child in body.get_children():
		var holder := child as CollisionShape3D
		if holder == null or not holder.shape is BoxShape3D:
			continue
		var half := (holder.shape as BoxShape3D).size * 0.5
		for i in 8:
			var corner := holder.global_transform * Vector3(half.x if i & 1 else -half.x,
					half.y if i & 2 else -half.y, half.z if i & 4 else -half.z)
			if table.has_point(corner):
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
## 5 cm above it by 1.2 s and grips at 1.5 s: the pull brings the hand down to
## the box more than the box up to the hand. It then tries to lift 0.15 m.
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
	_track_prop(crate, t)
	return false


## The held box's rise, its turn relative to the hand while held, and the
## widest the hand was held off its target.
func _track_grab(box: RigidBody3D, t: float) -> void:
	_track_prop(box, t)
	var physical := _player.physical as DynamicPhysical
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
	query.transform = drive.hand.global_transform
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


func _drive_wall(t: float) -> bool:
	# Real walking: the head moves through the room at 0.5 m/s, 1 m toward
	# the wall and back. The body can only follow until the wall stops it.
	var forward := clampf((t - 0.5) / 2.0, 0.0, 1.0) - clampf((t - 3.5) / 2.0, 0.0, 1.0)
	_rig.head_position = Vector3(0.0, SimulatedRig.HEAD_HEIGHT, forward)
	return false


func _drive_crouch(t: float) -> bool:
	var depth := clampf(t - 0.5, 0.0, 1.0) - clampf(t - 3.5, 0.0, 1.0)
	var head := lerpf(SimulatedRig.HEAD_HEIGHT, 0.8, depth)
	_rig.head_position = Vector3(0.0, head, 0.0)
	var hand_height := SimulatedRig.HAND_REST.y * head / SimulatedRig.HEAD_HEIGHT
	_rig.left_hand.y = hand_height
	_rig.right_hand.y = hand_height
	return false


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
	_track_finger_sink(Plane(Vector3.UP, 1.0), AABB(Vector3(0.75, 0.5, -0.5), Vector3(0.5, 1.0, 1.0)),
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
	var near := Vector3(0.0, lerpf(above + 0.1, above, reach) + lift, lerpf(-0.2, -0.33, reach))
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
