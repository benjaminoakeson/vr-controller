class_name PlayerDebug
extends Node

## Development tools for the player, added by Player only when asked for: a
## per-tick locomotion recorder, a readout above the left hand, and the
## guided headset session. Gameplay code never refers to any of this, and
## nothing here writes to the player.
##
## The guided session (`-- --record-baseline`) shows one plain instruction at
## a time, ticks each off by recognising it in the measurements, records the
## whole session, and closes the game when the list is done. Without it,
## nothing is recorded unless a test harness asks.

const GUIDED_ARGUMENT := "--record-baseline"
## Records free play, from when the headset is tracked until the game closes.
const RECORD_ARGUMENT := "--record-session"
## Headset sessions are recorded in the `headset` folder under this one.
const RECORDINGS := "user://baselines"
## Where the readout sits relative to the left controller, in metres.
const READOUT_OFFSET := Vector3(0.0, 0.08, 0.05)
## The guided session starts once the headset reports a pose above this
## height, in metres, so a recording does not open with the rig on the floor.
const TRACKED_HEAD_HEIGHT := 0.5
## How long the finished message stays up before the game closes, in seconds.
const FINISHED_LINGER := 5.0
## The guided session's items: what the latest change needs checked in the
## headset (the arm's simulated strength, 2026-09-26: grabbing a box, lifting
## and swinging it; and squeezing a box between the palms, which holds
## nothing, so the arm stays exactly as before). For free play, record with
## --record-session instead.
const GUIDED_STEPS: Array[BaselineChecklist.Step] = [
	BaselineChecklist.Step.GRAB, BaselineChecklist.Step.PALM_LIFT,
]

@export var readout: Label3D
@export var physical_debug: PhysicalDebug
@export_range(0.05, 2.0, 0.05, "suffix:s") var readout_interval := 0.25

## Measures every tick; records when started. Created by attach().
var recorder: LocomotionRecorder
## The guided session's checklist, or null outside a guided session.
var checklist: BaselineChecklist

var _rig: PlayerRig
var _guided_directory := ""
var _guided_started := false
var _record_free_play := false
var _finished_for := 0.0
var _readout_time := 0.0
var _readout_distance := 0.0


## Gives the tools the player parts they read. Call before adding to the tree.
func attach(rig: PlayerRig, physical: PlayerPhysical) -> void:
	_rig = rig
	recorder = LocomotionRecorder.new(physical, rig)
	if physical_debug != null:
		physical_debug.attach(physical)


func _ready() -> void:
	if recorder == null or readout == null:
		push_error("PlayerDebug: attach() must be called first, and the readout assigned.")
		set_physics_process(false)
		set_process(false)
		return
	# After the body has moved and the skeleton has solved, so every sample is
	# a finished tick.
	process_physics_priority = StaticSkeleton.SOLVE_PRIORITY + 2
	_place_readout()
	if GUIDED_ARGUMENT in OS.get_cmdline_user_args():
		start_guided(RECORDINGS.path_join("headset"))
	elif RECORD_ARGUMENT in OS.get_cmdline_user_args():
		_record_free_play = true


func _exit_tree() -> void:
	if recorder != null:
		recorder.stop()


## Starts the guided headset session. Recording into `directory` begins once
## the headset is tracked, and ends, along with the game, after the last item.
func start_guided(directory: String) -> void:
	checklist = BaselineChecklist.new(GUIDED_STEPS)
	_guided_directory = directory
	_guided_started = false
	_finished_for = 0.0
	readout.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	readout.width = 640.0
	print("PlayerDebug: guided session waiting for the headset to be tracked.")


func _physics_process(delta: float) -> void:
	if checklist != null:
		_run_guided(delta)
	elif _record_free_play and _rig.head.position.y > TRACKED_HEAD_HEIGHT:
		_record_free_play = false
		if recorder.start(RECORDINGS.path_join("headset"), "free"):
			_pulse()
	recorder.stage = checklist.current if checklist != null else -1
	recorder.measure(delta)
	if checklist != null and recorder.recording:
		var shown := checklist.current
		checklist.update(recorder.sample, delta)
		# A buzz for each item ticked off, so progress can be felt.
		if checklist.current != shown or checklist.complete:
			_pulse()
	_update_readout(delta)


func _process(_delta: float) -> void:
	_place_readout()


## Recording starts once the headset is tracked. Stopping is final: a guided
## session records once, then lingers on its last message and quits.
func _run_guided(delta: float) -> void:
	if checklist.complete:
		if recorder.recording:
			recorder.stop()
			_pulse()
		_finished_for += delta
		if _finished_for >= FINISHED_LINGER:
			get_tree().quit()
	elif not _guided_started and _rig.head.position.y > TRACKED_HEAD_HEIGHT:
		_guided_started = recorder.start(_guided_directory, "headset")
		if _guided_started:
			_pulse()


func _update_readout(delta: float) -> void:
	_readout_time += delta
	_readout_distance += recorder.sample.distance
	if _readout_time < readout_interval:
		return
	if checklist != null:
		readout.text = checklist.prompt()
	else:
		var sample := recorder.sample
		readout.text = "%s\n%.2f / %.2f m/s\n%s %.0f°\nhands %.2f %.2f m\n%d Hz" % [
				"REC %.0f s" % recorder.elapsed if recorder.recording else "debug",
				_readout_distance / _readout_time, sample.commanded,
				"ground" if sample.grounded else "air", sample.slope_deg,
				sample.left_separation, sample.right_separation,
				Engine.physics_ticks_per_second]
	_readout_time = 0.0
	_readout_distance = 0.0


func _place_readout() -> void:
	readout.global_position = _rig.left_controller.global_transform * READOUT_OFFSET


func _pulse() -> void:
	_rig.left_controller.trigger_haptic_pulse(&"haptic", 0.0, 0.5, 0.1, 0.0)
