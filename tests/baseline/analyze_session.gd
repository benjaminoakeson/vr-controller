extends SceneTree

## Measures a guided headset session, item by item, with the same analysis as
## the simulated baseline.
##
## godot --headless --xr-mode off --path . -s tests/baseline/analyze_session.gd [-- file.csv]
##
## Without a path it takes the newest recording in user://baselines/headset/.
## Prints a summary and writes <recording>.analysis.json beside the CSV.

const Analysis := preload("res://tests/baseline/recording_analysis.gd")
const SESSION_DIRECTORY := "user://baselines/headset"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var path: String = args[0] if not args.is_empty() else _newest(SESSION_DIRECTORY)
	if path.is_empty():
		push_error("analyze_session: no recording found in %s" % SESSION_DIRECTORY)
		quit(1)
		return
	var rows := Analysis.load_rows(path)
	var report := {
		"recording": ProjectSettings.globalize_path(path),
		"overall": Analysis.summarize(rows),
		"timing": _timing(rows),
		"items": {},
		"completed_items": 0,
	}
	var last_stage := -1
	for row in rows:
		last_stage = maxi(last_stage, int(row.stage))
	for stage in BaselineChecklist.Step.size():
		var slice := Analysis.stage_rows(rows, stage)
		if not slice.is_empty():
			report.items[BaselineChecklist.Step.keys()[stage]] = Analysis.summarize(slice)
	# An item is done once a later one has been shown; the drop is done if it
	# landed.
	report.completed_items = maxi(last_stage, 0)
	var drop: Dictionary = report.items.get("DROP", {})
	if not drop.is_empty() and drop.falls.any(func(fall: Dictionary) -> bool: return fall.landed):
		report.completed_items = BaselineChecklist.Step.size()

	var file := FileAccess.open(path + ".analysis.json", FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	print("SESSION %s" % report.recording)
	print("items completed: %d of %d" % [report.completed_items, BaselineChecklist.Step.size()])
	print("timing: %s" % JSON.stringify(report.timing))
	for item: String in report.items:
		var a: Dictionary = report.items[item]
		print("%-10s %5.1f s  top %.2f  airborne %.2f  rise %.3f  pulled %.3f  head %.2f-%.2f  run %.2f  presses %s" % [
				item, a.duration, a.top_speed, a.airborne_time, a.largest_rise, a.pulled_back,
				a.head_min, a.head_max, a.run_factor_max,
				JSON.stringify(a.presses.map(func(p: Dictionary) -> String:
					return "%.2f/%.2f m/s stop %.2f s" % [p.speed, p.commanded, p.stop_time]))])
	print("ANALYSIS %s" % ProjectSettings.globalize_path(path + ".analysis.json"))
	quit(0)


## Physics rates seen, and the previous frame's physics-process time. These
## come from a desktop-streamed session with the recorder running, so they
## are not Quest 3S standalone measurements.
func _timing(rows: Array[Dictionary]) -> Dictionary:
	var rates := {}
	var times: Array[float] = []
	for row in rows:
		var rate := str(int(row.tick_hz))
		rates[rate] = rates.get(rate, 0.0) + row.delta_s
		times.append(row.physics_ms)
	times.sort()
	var result := {"seconds_at_physics_rate": rates}
	if not times.is_empty():
		var total := 0.0
		for time in times:
			total += time
		result.physics_ms_mean = total / times.size()
		result.physics_ms_p95 = times[int(times.size() * 0.95)]
		result.physics_ms_max = times[-1]
	return result


func _newest(directory: String) -> String:
	var newest := ""
	var newest_time := 0
	for file in DirAccess.get_files_at(directory):
		if not file.ends_with(".csv"):
			continue
		var path := directory.path_join(file)
		var modified := FileAccess.get_modified_time(path)
		if modified >= newest_time:
			newest = path
			newest_time = modified
	return newest
