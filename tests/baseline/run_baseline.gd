extends SceneTree

## Runs the locomotion baseline without a headset.
##
## Each scenario loads a fresh level, places the player, and plays scripted
## headset, controller and stick input through a SimulatedRig while the
## player scene's own LocomotionRecorder records. Gameplay code is not
## changed or bypassed; only its inputs are simulated. Results are simulated
## desktop physics, not headset or Quest measurements.
##
## godot --headless --xr-mode off --fixed-fps 72 --path . \
##     -s tests/baseline/run_baseline.gd [-- scenario_name ...]
##
## Writes a CSV per scenario and results.json to
## user://baselines/simulated/<timestamp>/ and prints a summary.

const SimulatedRig := preload("res://tests/baseline/simulated_rig.gd")
const Analysis := preload("res://tests/baseline/recording_analysis.gd")
const LEVEL_PATH := "res://scenes/level.tscn"
## Seconds to stand still before recording, so the body and feet settle.
const SETTLE := 0.5
## Frames to wait after freeing a level, so two never share the world.
const TEARDOWN_FRAMES := 2
## A scripted turn-around takes this long, in seconds, like a person turning.
const TURN_TIME := 1.0
## Standing pauses between the legs of a scripted walk, in seconds.
const PAUSE := 0.8

var _scenarios: Array[Dictionary] = []
var _index := -1
var _level: Node
var _rig: SimulatedRig
var _recorder: LocomotionRecorder
var _body: PlayerBody
var _time := 0.0
var _teardown := 0
var _state := {}
var _results: Array[Dictionary] = []
var _directory := ""


func _initialize() -> void:
	_directory = "user://baselines/simulated/%s" % \
			Time.get_datetime_string_from_system().replace(":", "-")
	_scenarios = _all_scenarios()
	var wanted := OS.get_cmdline_user_args()
	if not wanted.is_empty():
		_scenarios = _scenarios.filter(
				func(scenario: Dictionary) -> bool: return scenario.name in wanted)
	physics_frame.connect(_tick)
	_teardown = 1


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
	var t := _time - SETTLE
	var finished := false
	if t >= 0.0:
		if not _recorder.recording:
			_recorder.start(scenario.name)
		finished = (scenario.drive as Callable).call(t) or t >= scenario.limit
	_rig.apply()
	if finished:
		_finish(scenario)


func _next() -> void:
	_index += 1
	if _index >= _scenarios.size():
		_report()
		quit()
		return
	var scenario := _scenarios[_index]
	_rig = SimulatedRig.new()
	_rig.face(scenario.facing)
	_rig.apply()
	_level = (load(LEVEL_PATH) as PackedScene).instantiate()
	var controller := _level.get_node("VrController") as Node3D
	controller.position = scenario.start
	_recorder = controller.get_node("LocomotionRecorder") as LocomotionRecorder
	if _recorder == null:
		push_error("run_baseline: the player scene has no working LocomotionRecorder.")
		quit(1)
		return
	_recorder.directory = _directory
	_body = controller.get_node("PlayerBody")
	root.add_child(_level)
	_time = 0.0
	_state = {"phase": 0, "phase_start": 0.0}


func _finish(scenario: Dictionary) -> void:
	var summary := _recorder.stop()
	var rows := Analysis.load_rows(_recorder.path)
	_results.append({
		"name": scenario.name,
		"title": scenario.title,
		"csv": summary.get("path", ""),
		"final_position": [_body.global_position.x, _body.global_position.y, _body.global_position.z],
		"analysis": Analysis.summarize(rows),
	})
	_level.queue_free()
	_level = null
	_rig.release()
	_teardown = TEARDOWN_FRAMES


func _report() -> void:
	var json := JSON.stringify(_results, "  ")
	var file := FileAccess.open(_directory.path_join("results.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(json)
		file.close()
	print("BASELINE_RESULTS %s" % ProjectSettings.globalize_path(_directory.path_join("results.json")))
	for result in _results:
		var a: Dictionary = result.analysis
		print("%-14s %5.1f s  top %.2f m/s  airborne %.2f s  rise %.3f m  pulled %.3f m  head %.2f-%.2f  end %s" % [
				result.name, a.duration, a.top_speed, a.airborne_time, a.largest_rise,
				a.pulled_back, a.head_min, a.head_max, str(result.final_position)])


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
				"start": Vector3(-4.5, 0.0, -5.5), "facing": along_x, "limit": 22.0,
				"drive": _drive_ramp},
		{"name": "lower_ramp", "title": "Up the lower 15° ramp to the platform",
				"start": Vector3(5.5, -4.0, 1.5), "facing": Vector3.FORWARD, "limit": 7.0,
				"drive": func(_t: float) -> bool:
					# Stop on the platform at the top: past it is the level's edge.
					_rig.stick = Vector2(0.0, 1.0) if _body.global_position.z > -5.4 else Vector2.ZERO
					return _body.global_position.z <= -5.4},
		{"name": "drop", "title": "Walk into the floor hole and land 4 m below",
				"start": Vector3(-4.0, 0.0, 1.2), "facing": Vector3.BACK, "limit": 6.0,
				"drive": _drive_drop},
		{"name": "wall", "title": "Walk the real head 1 m into the wall, then back",
				"start": Vector3(0.0, 0.0, 3.0), "facing": Vector3.BACK, "limit": 6.5,
				"drive": _drive_wall},
		{"name": "crouch", "title": "Crouch to 0.8 m head height, hold, stand",
				"start": Vector3(-2.0, 0.0, 1.0), "facing": Vector3.FORWARD, "limit": 6.0,
				"drive": _drive_crouch},
		{"name": "run_moderate", "title": "Grips + moderate arm pumping + full stick",
				"start": Vector3(-4.3, 0.0, -3.5), "facing": along_x, "limit": 4.5,
				"drive": func(t: float) -> bool: return _drive_run(t, 0.15, 1.5, 1.8)},
		{"name": "run_hard", "title": "Grips + hard arm pumping + full stick",
				"start": Vector3(-4.3, 0.0, -3.5), "facing": along_x, "limit": 3.5,
				"drive": func(t: float) -> bool: return _drive_run(t, 0.25, 2.5, 1.1)},
	]


func _drive_steps(t: float) -> bool:
	return _out_and_back(t, 5.0,
			func() -> bool: return _body.global_position.x >= 4.9,
			func() -> bool: return _body.global_position.x <= 2.0)


func _drive_ramp(t: float) -> bool:
	return _out_and_back(t, 9.0,
			func() -> bool: return _body.global_position.x >= 4.2,
			func() -> bool: return _body.global_position.x <= -4.3)


## Walks forward at full stick until `arrived` holds, pauses, turns the head
## round as a person would, walks back until `returned` holds, then stands.
## Each leg gives up after `leg_limit` seconds.
func _out_and_back(t: float, leg_limit: float, arrived: Callable, returned: Callable) -> bool:
	var since: float = t - _state.phase_start
	match _state.phase:
		0:
			_rig.stick = Vector2(0.0, 1.0)
			if arrived.call() or since > leg_limit:
				_enter_phase(1, t)
		1:
			_rig.stick = Vector2.ZERO
			if since >= PAUSE:
				_state.turn_from = _rig.yaw
				_enter_phase(2, t)
		2:
			var turned := clampf(since / TURN_TIME, 0.0, 1.0)
			_rig.yaw = _state.turn_from + PI * turned
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
	_state.phase = phase
	_state.phase_start = t


func _drive_drop(t: float) -> bool:
	if not _body.grounded:
		_state.fell = true
	if _state.get("fell", false):
		_rig.stick = Vector2.ZERO
		if _body.grounded:
			_state.landed_for = _state.get("landed_for", 0.0) + 1.0 / Engine.physics_ticks_per_second
		return _state.get("landed_for", 0.0) >= 2.0
	_rig.stick = Vector2(0.0, 1.0)
	return false


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
