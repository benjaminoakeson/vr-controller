class_name LocomotionRecorder
extends Node

## Records what locomotion does, tick by tick, so a replacement body can be
## compared against the current one on the same fixtures.
##
## It reads the body, the rig and the skeleton after they have finished the
## tick and writes nothing back. Each run is a CSV plus a summary in the log.
##
## Normal play is untouched: nothing is recorded unless someone asks. There
## are three ways to ask:
## - Launching with `-- --record-baseline` records a guided headset session:
##   the readout shows one plain instruction at a time, ticks each off as it
##   is done, and closes the recording and the game when the list is finished.
## - A test harness calls `start()` and `stop()` directly.
## - The toggle button starts and ends a run by hand.
##
## Speeds come from how far the body actually moved, so they include the body
## following the headset.

const CSV_HEADER := "time_s,tick_hz,delta_s,x,y,z,speed,speed_h,speed_v,commanded," \
		+ "grounded,slope_deg,run_factor,origin_correction,head_height,head_x,head_z," \
		+ "left_foot_height,right_foot_height,physics_ms,stage"
## Recording starts once the headset reports a pose above this height, in
## metres, so the file does not open with the rig lying at the floor.
const TRACKED_HEAD_HEIGHT := 0.5
## How long the finished message stays up before the game closes itself.
const FINISHED_LINGER := 5.0

@export var body: PlayerBody
## Supplies the commanded travel and the feet. Optional: without it those
## columns read zero.
@export var skeleton: StaticSkeleton
## The controller whose button starts and ends a manual run.
@export var toggle_controller: XRController3D
@export var toggle_action := &"by_button"
## Live numbers or instructions for the headset. Optional.
@export var readout: Label3D
@export_range(0.05, 2.0, 0.05, "suffix:s") var readout_interval := 0.25
## Grounded ticks commanded faster than this count toward the walking average.
@export_range(0.0, 1.0, 0.01, "suffix:m/s") var moving_threshold := 0.1
@export var directory := "user://baselines"
## The command-line user argument that turns on the guided headset session.
@export var guided_argument := "--record-baseline"

var recording := false
## The file the current or last run wrote.
var path := ""

var _file: FileAccess
var _checklist: BaselineChecklist
# A guided session records once; stopping it is final.
var _guided_started := false
var _finished_for := 0.0
var _primed := false
var _previous_position := Vector3.ZERO
var _commanded := 0.0
var _since_flush := 0.0
# The readout averages over its own interval; one tick's speed is too noisy.
var _readout_time := 0.0
var _readout_distance := 0.0
# The current run's totals, for its summary.
var _elapsed := 0.0
var _distance := 0.0
var _max_speed := 0.0
var _moving_time := 0.0
var _moving_distance := 0.0
var _moving_commanded := 0.0
var _airborne_time := 0.0
var _max_rise := 0.0
var _pulled_back := 0.0
var _lowest_head := INF


func _ready() -> void:
	if body == null or body.origin == null or body.hmd == null:
		push_error("LocomotionRecorder: body, with its origin and hmd, must be assigned.")
		set_physics_process(false)
		return
	# After the body has moved and the skeleton has solved, so each sample is
	# a finished tick.
	process_physics_priority = StaticSkeleton.SOLVE_PRIORITY + 2
	if guided_argument in OS.get_cmdline_user_args():
		_checklist = BaselineChecklist.new()
		directory = directory.path_join("headset")
		if readout != null:
			readout.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			readout.width = 640.0
	elif toggle_controller != null:
		toggle_controller.button_pressed.connect(_on_button_pressed)


func _exit_tree() -> void:
	stop()


func _physics_process(delta: float) -> void:
	var position := body.global_position
	if not _primed:
		_previous_position = position
		_primed = true
		return
	var moved := position - _previous_position
	_previous_position = position
	_commanded = skeleton.commanded_travel.length() if skeleton != null else 0.0
	if _checklist != null:
		_run_guided(delta)
	if recording:
		_record(delta, moved)
	_update_readout(delta, moved.length())


## Opens a new recording named after `label`. Returns false if the file could
## not be written.
func start(label := "locomotion") -> bool:
	if recording:
		return true
	DirAccess.make_dir_recursive_absolute(directory)
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	path = directory.path_join("%s_%s.csv" % [label, stamp])
	# Two runs in the same second must not overwrite each other.
	var copy := 2
	while FileAccess.file_exists(path):
		path = directory.path_join("%s_%s_%d.csv" % [label, stamp, copy])
		copy += 1
	_file = FileAccess.open(path, FileAccess.WRITE)
	if _file == null:
		push_error("LocomotionRecorder: cannot write %s (%s)." % [
				path, error_string(FileAccess.get_open_error())])
		return false
	_file.store_line(CSV_HEADER)
	_elapsed = 0.0
	_distance = 0.0
	_max_speed = 0.0
	_moving_time = 0.0
	_moving_distance = 0.0
	_moving_commanded = 0.0
	_airborne_time = 0.0
	_max_rise = 0.0
	_pulled_back = 0.0
	_lowest_head = INF
	recording = true
	_pulse()
	print("LocomotionRecorder: recording to %s" % ProjectSettings.globalize_path(path))
	return true


## Closes the recording and returns its summary; empty if nothing was recording.
func stop() -> Dictionary:
	if not recording:
		return {}
	recording = false
	_file.close()
	_file = null
	_pulse()
	var summary := {
		"path": ProjectSettings.globalize_path(path),
		"duration": _elapsed,
		"distance": _distance,
		"walking_speed": _moving_distance / _moving_time if _moving_time > 0.0 else 0.0,
		"commanded_speed": _moving_commanded / _moving_time if _moving_time > 0.0 else 0.0,
		"top_speed": _max_speed,
		"airborne_time": _airborne_time,
		"largest_rise": _max_rise,
		"pulled_back": _pulled_back,
		"lowest_head": _lowest_head,
	}
	print(("LocomotionRecorder: %.1f s, %.2f m moved. Walking %.2f m/s against %.2f m/s "
			+ "commanded; top %.2f m/s. Airborne %.2f s. Largest grounded rise %.3f m "
			+ "in one tick. Rig pulled back %.3f m in total. Lowest head %.2f m.") % [
			summary.duration, summary.distance, summary.walking_speed,
			summary.commanded_speed, summary.top_speed, summary.airborne_time,
			summary.largest_rise, summary.pulled_back, summary.lowest_head])
	return summary


## The guided headset session: starts once the headset is tracked, and closes
## the recording and the game a few seconds after the last item.
func _run_guided(delta: float) -> void:
	if _checklist.complete:
		stop()
		_finished_for += delta
		if _finished_for >= FINISHED_LINGER:
			get_tree().quit()
	elif not _guided_started and body.hmd.position.y > TRACKED_HEAD_HEIGHT:
		_guided_started = start("headset")


func _record(delta: float, moved: Vector3) -> void:
	var speed := moved.length() / delta
	var head_height := body.hmd.position.y
	var head := body.hmd.global_position
	_elapsed += delta
	_distance += moved.length()
	_max_speed = maxf(_max_speed, speed)
	_pulled_back += body.origin_correction
	_lowest_head = minf(_lowest_head, head_height)
	if body.grounded:
		_max_rise = maxf(_max_rise, moved.y)
		if _commanded > moving_threshold:
			_moving_time += delta
			_moving_distance += moved.length()
			_moving_commanded += _commanded * delta
	else:
		_airborne_time += delta

	var stage := -1
	if _checklist != null:
		stage = _checklist.current
		_checklist.update({
			"grounded": body.grounded,
			"slope_deg": rad_to_deg(body.ground_normal.angle_to(Vector3.UP)),
			"commanded": _commanded,
			"speed": speed,
			"speed_v": moved.y / delta,
			"y": body.global_position.y,
			"run_factor": body.run_factor,
			"origin_correction": body.origin_correction,
			"head_height": head_height,
		}, delta)
		# A buzz for each item ticked off, so progress can be felt.
		if _checklist.current != stage or _checklist.complete:
			_pulse()

	_file.store_line(("%.4f,%d,%.5f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%d,%.2f,%.3f,%.4f,"
			+ "%.4f,%.4f,%.4f,%.4f,%.4f,%.3f,%d") % [
			_elapsed, Engine.physics_ticks_per_second, delta,
			body.global_position.x, body.global_position.y, body.global_position.z,
			speed, Vector2(moved.x, moved.z).length() / delta, moved.y / delta, _commanded,
			int(body.grounded), rad_to_deg(body.ground_normal.angle_to(Vector3.UP)),
			body.run_factor, body.origin_correction, head_height, head.x, head.z,
			_foot_height(skeleton.left_foot_tracker if skeleton != null else null),
			_foot_height(skeleton.right_foot_tracker if skeleton != null else null),
			# The monitor reports the previous frame's physics time, not this tick's.
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
			stage])
	# A guided session may end with the game being closed from outside; keep
	# at most a second of it unwritten.
	_since_flush += delta
	if _since_flush >= 1.0:
		_since_flush = 0.0
		_file.flush()


## A reference foot's height above the body's feet, which on stairs shows
## whether the foot found the tread.
func _foot_height(foot: Node3D) -> float:
	return foot.global_position.y - body.global_position.y if foot != null else 0.0


func _update_readout(delta: float, distance: float) -> void:
	if readout == null:
		return
	_readout_time += delta
	_readout_distance += distance
	if _readout_time < readout_interval:
		return
	if _checklist != null:
		readout.text = _checklist.prompt()
	else:
		var state := "REC %.0f s" % _elapsed if recording else "%s: record" % toggle_action
		readout.text = "%s\n%.2f / %.2f m/s\n%s %.0f°\n%d Hz" % [
				state, _readout_distance / _readout_time, _commanded,
				"ground" if body.grounded else "air",
				rad_to_deg(body.ground_normal.angle_to(Vector3.UP)),
				Engine.physics_ticks_per_second]
	_readout_time = 0.0
	_readout_distance = 0.0


func _on_button_pressed(action: String) -> void:
	if action != toggle_action:
		return
	if recording:
		stop()
	else:
		start()


func _pulse() -> void:
	if toggle_controller != null:
		toggle_controller.trigger_haptic_pulse(&"haptic", 0.0, 0.5, 0.1, 0.0)
