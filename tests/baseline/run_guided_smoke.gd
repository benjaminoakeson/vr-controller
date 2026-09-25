extends SceneTree

## Smoke test for the guided headset session, without a headset: the player
## stands still with simulated tracking, and the session must start recording
## into the headset folder and show its first instruction.
##
## godot --headless --xr-mode off --fixed-fps 72 --path . \
##     -s tests/baseline/run_guided_smoke.gd -- --record-baseline

const SimulatedRig := preload("res://tests/baseline/simulated_rig.gd")
const DURATION := 2.0

var _rig: SimulatedRig
var _recorder: LocomotionRecorder
var _time := 0.0
var _checked := false


func _initialize() -> void:
	_rig = SimulatedRig.new()
	var level: Node = (load("res://scenes/level.tscn") as PackedScene).instantiate()
	_recorder = level.get_node("VrController/LocomotionRecorder")
	# Kept apart from real headset sessions, so analysis never picks it up.
	_recorder.directory = "user://baselines/smoke"
	root.add_child(level)
	physics_frame.connect(_tick)


func _tick() -> void:
	_rig.apply()
	_time += 1.0 / Engine.physics_ticks_per_second
	if _time < DURATION or _checked:
		return
	_checked = true
	var text := _recorder.readout.text if _recorder.readout != null else ""
	var ok := _recorder.recording and "/headset/" in _recorder.path and text.begins_with("Test 1 of")
	print("recording=%s path=%s" % [_recorder.recording, _recorder.path])
	print("readout=%s" % text.replace("\n", " | "))
	_recorder.stop()
	# Stopping is final: the next tick must not open another recording.
	await physics_frame
	ok = ok and not _recorder.recording
	print("GUIDED %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)
