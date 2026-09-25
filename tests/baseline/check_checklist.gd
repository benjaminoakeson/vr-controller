extends SceneTree

## Checks that the guided headset checklist ticks each item off, by feeding it
## the simulated baseline recordings in the order a player would do them.
##
## godot --headless --xr-mode off --path . -s tests/baseline/check_checklist.gd \
##     -- <directory of a run_baseline.gd run>
##
## Exits 0 when every item completes, 1 otherwise.

const Analysis := preload("res://tests/baseline/recording_analysis.gd")
## Scenario recordings in checklist order. Steps and ramp cover two items each.
const ORDER := ["flat_full", "flat_half", "steps", "ramp", "wall", "crouch", "run_hard", "drop"]


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("check_checklist: pass the simulated run directory after --")
		quit(1)
		return
	var directory: String = args[0]
	var checklist := BaselineChecklist.new()
	for scenario: String in ORDER:
		var path := _recording(directory, scenario)
		if path.is_empty():
			push_error("check_checklist: no %s recording in %s" % [scenario, directory])
			quit(1)
			return
		var before := checklist.current
		for row in Analysis.load_rows(path):
			checklist.update({
				"grounded": row.grounded > 0.5, "slope_deg": row.slope_deg,
				"commanded": row.commanded, "speed": row.speed, "speed_v": row.speed_v,
				"y": row.y, "run_factor": row.run_factor,
				"origin_correction": row.origin_correction, "head_height": row.head_height,
			}, row.delta_s)
		print("%-10s %s -> %s" % [scenario, BaselineChecklist.Step.keys()[before],
				"COMPLETE" if checklist.complete else BaselineChecklist.Step.keys()[checklist.current]])
	print("CHECKLIST %s" % ("PASS" if checklist.complete else "FAIL"))
	quit(0 if checklist.complete else 1)


func _recording(directory: String, scenario: String) -> String:
	for file in DirAccess.get_files_at(directory):
		if file.begins_with(scenario + "_2") and file.ends_with(".csv"):
			return directory.path_join(file)
	return ""
