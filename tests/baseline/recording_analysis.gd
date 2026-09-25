extends RefCounted

## Reads a LocomotionRecorder CSV and measures it. The same measurements are
## used for simulated runs and headset sessions, so the two can be compared.

## Commanded speed above this is a stick press, in m/s.
const MOVING := 0.1
## A body slower than this has stopped, in m/s.
const STOPPED := 0.05
## Walking is judged after this long into a press, once acceleration is over.
const SETTLE_TIME := 0.5
## A grounded, stick-driven tick slower than this share of the command, after
## settling, is a stall - the body snagged on something.
const STALL_RATIO := 0.3


## Every row of a recording as a Dictionary of column name to float.
static func load_rows(path: String) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("Cannot read %s" % path)
		return rows
	var header := file.get_csv_line()
	while not file.eof_reached():
		var line := file.get_csv_line()
		if line.size() != header.size():
			continue
		var row := {}
		for i in header.size():
			row[header[i]] = line[i].to_float()
		rows.append(row)
	return rows


## Only the rows recorded while the guided session showed item `stage`.
static func stage_rows(rows: Array[Dictionary], stage: int) -> Array[Dictionary]:
	return rows.filter(func(row: Dictionary) -> bool: return int(row.stage) == stage)


## The measurements of one recording, or of any slice of one.
static func summarize(rows: Array[Dictionary]) -> Dictionary:
	var result := {
		"duration": 0.0, "tick_hz": 0, "presses": [], "falls": [],
		"top_speed": 0.0, "top_fall_speed": 0.0, "airborne_time": 0.0,
		"largest_rise": 0.0, "largest_drop": 0.0, "stall_time": 0.0,
		"pulled_back": 0.0, "pulled_back_largest": 0.0,
		"head_min": INF, "head_max": -INF, "head_x_max": -INF, "head_z_max": -INF,
		"foot_min": INF, "foot_max": -INF, "run_factor_max": 0.0, "run_speed": 0.0,
		"y_min": INF, "y_max": -INF, "slope_max": 0.0,
	}
	if rows.is_empty():
		return result
	result.duration = rows[-1].time_s - rows[0].time_s + rows[0].delta_s
	result.tick_hz = int(rows[0].tick_hz)
	var press_start := -1
	var fall_start := -1
	for i in rows.size():
		var row: Dictionary = rows[i]
		var step: float = row.speed_v * row.delta_s
		var grounded: bool = row.grounded > 0.5
		result.top_speed = maxf(result.top_speed, row.speed)
		result.top_fall_speed = maxf(result.top_fall_speed, -row.speed_v)
		result.pulled_back += row.origin_correction
		result.pulled_back_largest = maxf(result.pulled_back_largest, row.origin_correction)
		result.head_min = minf(result.head_min, row.head_height)
		result.head_max = maxf(result.head_max, row.head_height)
		result.head_x_max = maxf(result.head_x_max, row.head_x)
		result.head_z_max = maxf(result.head_z_max, row.head_z)
		result.y_min = minf(result.y_min, row.y)
		result.y_max = maxf(result.y_max, row.y)
		result.run_factor_max = maxf(result.run_factor_max, row.run_factor)
		if row.run_factor > 0.9:
			result.run_speed = maxf(result.run_speed, row.speed)
		if grounded:
			result.largest_rise = maxf(result.largest_rise, step)
			result.largest_drop = maxf(result.largest_drop, -step)
			result.slope_max = maxf(result.slope_max, row.slope_deg)
			for foot in [row.left_foot_height, row.right_foot_height]:
				result.foot_min = minf(result.foot_min, foot)
				result.foot_max = maxf(result.foot_max, foot)
		else:
			result.airborne_time += row.delta_s

		# Stick presses: a run of ticks commanded to move.
		var moving: bool = row.commanded > MOVING
		if moving and press_start < 0:
			press_start = i
		elif not moving and press_start >= 0:
			result.presses.append(_press(rows, press_start, i))
			press_start = -1
		# Falls: a run of airborne ticks.
		if not grounded and fall_start < 0:
			fall_start = i
		elif grounded and fall_start >= 0:
			result.falls.append(_fall(rows, fall_start, i))
			fall_start = -1
	if press_start >= 0:
		result.presses.append(_press(rows, press_start, rows.size()))
	if fall_start >= 0:
		result.falls.append(_fall(rows, fall_start, rows.size()))
	# A press cut off by the slice's edge before it settled says nothing.
	result.presses = result.presses.filter(
			func(press: Dictionary) -> bool: return press.commanded > 0.0)
	for press: Dictionary in result.presses:
		result.stall_time += press.stall_time
	return result


## One stick press from row `from` up to, not including, row `to`, and the
## coast to a stop after it.
static func _press(rows: Array[Dictionary], from: int, to: int) -> Dictionary:
	var start: float = rows[from].time_s
	var press := {
		"start": start, "length": rows[to - 1].time_s - start + rows[from].delta_s,
		"commanded": 0.0, "speed": 0.0, "ratio": 0.0, "rise_time": -1.0,
		"slope": 0.0, "climb": rows[to - 1].y - rows[from].y,
		"stall_time": 0.0, "stop_time": -1.0, "stop_distance": 0.0,
	}
	var commanded := 0.0
	var speed := 0.0
	var slope := 0.0
	var settled := 0
	for i in range(from, to):
		var row: Dictionary = rows[i]
		if press.rise_time < 0.0 and row.speed >= 0.9 * row.commanded:
			press.rise_time = row.time_s - start
		if row.time_s - start < SETTLE_TIME or row.grounded < 0.5:
			continue
		settled += 1
		commanded += row.commanded
		speed += row.speed
		slope += row.slope_deg
		if row.speed < STALL_RATIO * row.commanded:
			press.stall_time += row.delta_s
	if settled > 0:
		press.commanded = commanded / settled
		press.speed = speed / settled
		press.ratio = speed / commanded
		press.slope = slope / settled
	# Coasting after release, until stopped or pressed again.
	var release: float = rows[to - 1].time_s
	for i in range(to, rows.size()):
		var row: Dictionary = rows[i]
		if row.commanded > MOVING:
			break
		if row.speed < STOPPED:
			press.stop_time = row.time_s - release
			break
		press.stop_distance += row.speed * row.delta_s
	return press


## One airborne stretch and its landing.
static func _fall(rows: Array[Dictionary], from: int, to: int) -> Dictionary:
	var last: Dictionary = rows[to - 1]
	var fall := {
		"length": last.time_s - rows[from].time_s + last.delta_s,
		"height": rows[from].y - last.y,
		"landing_speed": -last.speed_v,
		"landed": to < rows.size(),
		"feet_after_landing": [],
	}
	if to < rows.size():
		fall.height = rows[from].y - rows[to].y
		var after: Dictionary = rows[mini(to + 36, rows.size() - 1)]
		fall.feet_after_landing = [after.left_foot_height, after.right_foot_height]
	return fall
