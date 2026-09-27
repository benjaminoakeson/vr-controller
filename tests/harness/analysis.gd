extends RefCounted

## Reads LocomotionRecorder CSVs and measures them. The same measurements are
## used for simulated runs and headset sessions, so the two can be compared,
## and for comparing a run with stored reference results.

## Commanded speed above this is a stick press, in m/s.
const MOVING := 0.1
## A body slower than this has stopped, in m/s.
const STOPPED := 0.05
## Walking is judged after this long into a press, once acceleration is over.
const SETTLE_TIME := 0.5
## A grounded, stick-driven tick slower than this share of the command, after
## settling, is a stall - the body snagged on something.
const STALL_RATIO := 0.3
## The walking motor's response time, CapsuleBody.response_time in the scene:
## the view should follow the stick's commanded velocity at this lag, one tick
## after it is commanded.
const STICK_RESPONSE_TIME := 0.12
## Commanded speed, in m/s, above which real walking counts as combined with
## the stick.
const STICK_ROOM_COMMAND := 0.5
## Moves smaller than this in one tick, in metres, count as standing still
## when turns back and forth are counted: far above the physics engine's
## rounding, far below anything a player could see.
const REVERSAL_DEADBAND := 0.00002
## A point within this of where it comes to rest has settled, in metres.
const SETTLED := 0.001


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


## A recorded row as the sample the guided checklist reads live.
static func sample_from_row(row: Dictionary) -> LocomotionRecorder.Sample:
	var sample := LocomotionRecorder.Sample.new()
	sample.speed = row.speed
	sample.distance = row.speed * row.delta_s
	sample.speed_h = row.speed_h
	sample.speed_v = row.speed_v
	sample.commanded = row.commanded
	sample.grounded = row.grounded > 0.5
	sample.slope_deg = row.slope_deg
	sample.run_factor = row.run_factor
	sample.origin_correction = row.origin_correction
	sample.head_height = row.head_height
	sample.head_obstruction = row.get("head_obstruction", 0.0)
	sample.left_separation = row.get("left_separation", 0.0)
	sample.right_separation = row.get("right_separation", 0.0)
	sample.left_force = row.get("left_force", 0.0)
	sample.right_force = row.get("right_force", 0.0)
	sample.left_touching = row.get("left_touching", 0.0) > 0.5
	sample.right_touching = row.get("right_touching", 0.0) > 0.5
	sample.left_hand = Vector3(row.get("left_hand_x", 0.0), row.get("left_hand_y", 0.0),
			row.get("left_hand_z", 0.0))
	sample.right_hand = Vector3(row.get("right_hand_x", 0.0), row.get("right_hand_y", 0.0),
			row.get("right_hand_z", 0.0))
	sample.position = Vector3(row.x, row.y, row.z)
	sample.room_speed = row.get("room_speed", 0.0)
	sample.view_velocity = Vector3(row.get("view_vx", 0.0), 0.0, row.get("view_vz", 0.0))
	sample.commanded_velocity = Vector3(row.get("commanded_x", 0.0), 0.0, row.get("commanded_z", 0.0))
	sample.left_finger_error = row.get("left_finger_error", 0.0)
	sample.right_finger_error = row.get("right_finger_error", 0.0)
	sample.left_finger_bend = row.get("left_finger_bend", 0.0)
	sample.right_finger_bend = row.get("right_finger_bend", 0.0)
	sample.parts_pressing = int(row.get("parts_pressing", 0.0))
	sample.prop_contact = int(row.get("prop_contact", 0.0))
	sample.left_grab = int(row.get("left_grab", 0.0))
	sample.right_grab = int(row.get("right_grab", 0.0))
	sample.arm_stretch = row.get("arm_stretch", 0.0)
	return sample


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
		"x_max": -INF, "z_max": -INF, "wander_max": 0.0,
		"body_height_min": INF, "body_height_max": -INF, "head_lead_max": 0.0,
		"head_obstruction_max": 0.0, "blackout_max": 0.0, "motor_force_max": 0.0,
		"relocations": 0, "left_separation_max": 0.0, "right_separation_max": 0.0,
		"hand_force_max": 0.0, "hand_contacts": 0,
		"view_error_max": 0.0, "stick_room_distance": 0.0,
		"finger_error_max": 0.0, "finger_bend_min": INF, "finger_bend_max": -INF,
		# Finger joints that turned back while their pose held still (twitches).
		"finger_reversals": 0,
		"arm_stretch_max": 0.0, "parts_pressing_time": 0.0,
		# Seconds the body and each hand pushed on a loose prop.
		"prop_push_body": 0.0, "prop_push_hands": 0.0,
		# The most a prop pushed by both hands at once rose above where it was
		# when they both first touched it, in metres, and its mass.
		"prop_lift": 0.0, "prop_lift_mass": 0.0,
		# Grabs by either hand: how many, how long the first took to pull in,
		# seconds held, and the widest gap between the grab points while held.
		"grabs": 0, "grab_pull_time": -1.0, "grab_held_time": 0.0, "grab_gap_held_max": 0.0,
		# Seconds each body part was pushed on, by BodyParts.Part name.
		"parts_pressed": {},
	}
	if rows.is_empty():
		return result
	result.duration = rows[-1].time_s - rows[0].time_s + rows[0].delta_s
	result.tick_hz = int(rows[0].tick_hz)
	var press_start := -1
	var fall_start := -1
	var origin := Vector2(rows[0].x, rows[0].z)
	var stick_response := Vector3.ZERO
	var last_command := Vector3.ZERO
	var lift_from := NAN
	var last_grab := {"left": 0, "right": 0}
	var pull_started := -1.0
	result.relocations = int(rows[-1].get("relocations", 0.0) - rows[0].get("relocations", 0.0))
	result.hand_contacts = int(rows[-1].get("left_contacts", 0.0) + rows[-1].get("right_contacts", 0.0)
			- rows[0].get("left_contacts", 0.0) - rows[0].get("right_contacts", 0.0))
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
		result.x_max = maxf(result.x_max, row.x)
		result.z_max = maxf(result.z_max, row.z)
		result.wander_max = maxf(result.wander_max, origin.distance_to(Vector2(row.x, row.z)))
		# Columns added with the dynamic body; older recordings lack them.
		var body_height: float = row.get("body_height", 0.0)
		result.body_height_min = minf(result.body_height_min, body_height)
		result.body_height_max = maxf(result.body_height_max, body_height)
		result.head_lead_max = maxf(result.head_lead_max, row.get("head_lead", 0.0))
		result.head_obstruction_max = maxf(result.head_obstruction_max, row.get("head_obstruction", 0.0))
		result.blackout_max = maxf(result.blackout_max, row.get("blackout", 0.0))
		result.motor_force_max = maxf(result.motor_force_max, row.get("motor_force", 0.0))
		result.left_separation_max = maxf(result.left_separation_max, row.get("left_separation", 0.0))
		result.right_separation_max = maxf(result.right_separation_max, row.get("right_separation", 0.0))
		result.hand_force_max = maxf(result.hand_force_max,
				maxf(row.get("left_force", 0.0), row.get("right_force", 0.0)))
		stick_response += (last_command - stick_response) * minf(row.delta_s / STICK_RESPONSE_TIME, 1.0)
		last_command = Vector3(row.get("commanded_x", 0.0), 0.0, row.get("commanded_z", 0.0))
		_measure_view(row, result, stick_response)
		result.arm_stretch_max = maxf(result.arm_stretch_max, row.get("arm_stretch", 0.0))
		if row.get("parts_pressing", 0.0) > 0.5:
			result.parts_pressing_time += row.delta_s
		var prop := int(row.get("prop_contact", 0.0))
		if prop & 1:
			result.prop_push_body += row.delta_s
		if prop & 6:
			result.prop_push_hands += row.delta_s
		for side: String in ["left", "right"]:
			var grab := int(row.get(side + "_grab", 0.0))
			var was: int = last_grab[side]
			if grab == 1 and was == 0:
				result.grabs += 1
				if pull_started < 0.0:
					pull_started = row.time_s
			if grab == 2:
				if was == 1 and result.grab_pull_time < 0.0 and pull_started >= 0.0:
					result.grab_pull_time = row.time_s - pull_started
				result.grab_held_time += row.delta_s
				result.grab_gap_held_max = maxf(result.grab_gap_held_max, row.get(side + "_grab_gap", 0.0))
			last_grab[side] = grab
		if prop & 6 == 6 and row.has("prop_y"):
			if is_nan(lift_from):
				lift_from = row.prop_y
			if row.prop_y - lift_from > result.prop_lift:
				result.prop_lift = row.prop_y - lift_from
				result.prop_lift_mass = row.get("prop_mass", 0.0)
		elif prop & 6 == 0:
			lift_from = NAN
		var pressed := int(row.get("parts_pressed", 0.0))
		for part in BodyParts.Part.size():
			if pressed & (1 << part):
				var part_name: String = BodyParts.Part.keys()[part]
				result.parts_pressed[part_name] = result.parts_pressed.get(part_name, 0.0) + row.delta_s
		result.finger_reversals += int(row.get("left_finger_reversals", 0.0) + row.get("right_finger_reversals", 0.0))
		if row.has("right_finger_bend"):
			result.finger_error_max = maxf(result.finger_error_max,
					maxf(row.left_finger_error, row.right_finger_error))
			result.finger_bend_min = minf(result.finger_bend_min, minf(row.left_finger_bend, row.right_finger_bend))
			result.finger_bend_max = maxf(result.finger_bend_max, maxf(row.left_finger_bend, row.right_finger_bend))
		result.run_factor_max = maxf(result.run_factor_max, row.run_factor)
		if row.run_factor > 0.9:
			result.run_speed = maxf(result.run_speed, row.speed)
		if grounded:
			result.largest_rise = maxf(result.largest_rise, step)
			result.largest_drop = maxf(result.largest_drop, -step)
			result.slope_max = maxf(result.slope_max, row.slope_deg)
			for foot: float in [row.left_foot_height, row.right_foot_height]:
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
	# Step lifts and step-downs, from recordings that have the step phase.
	result.lifts = _phases(rows, 1)
	result.descents = _phases(rows, 2)
	return result


## Compares the view's velocity with the stick's, as the walking motor would
## deliver it (STICK_RESPONSE_TIME): walking in the room must not change how
## the stick moves the view. Only meaningful on
## open, flat ground: a body stopped by a riser or a wall, walking a slope or
## falling also moves the view differently from the stick, as it should. Also
## totals the player's real walking while the stick walks. Rows from before
## these columns existed measure nothing.
static func _measure_view(row: Dictionary, result: Dictionary, stick_response: Vector3) -> void:
	if not row.has("view_vx"):
		return
	if row.commanded >= STICK_ROOM_COMMAND:
		result.stick_room_distance += row.room_speed * row.delta_s
	if row.commanded <= MOVING and stick_response.length() <= MOVING or row.origin_correction > 0.0:
		return
	var view := Vector3(row.view_vx, 0.0, row.view_vz)
	result.view_error_max = maxf(result.view_error_max, view.distance_to(stick_response))


## Each unbroken run of ticks in step phase `phase`: its duration and the
## height the body moved through, in seconds and metres.
static func _phases(rows: Array[Dictionary], phase: int) -> Array:
	var runs: Array = []
	var start := -1
	for i in rows.size() + 1:
		var inside: bool = i < rows.size() and int(rows[i].get("step_phase", 0.0)) == phase
		if inside and start < 0:
			start = i
		elif not inside and start >= 0:
			runs.append({
				"duration": rows[i - 1].time_s - rows[start].time_s + rows[start].delta_s,
				"height": rows[i - 1].y - rows[start].y,
			})
			start = -1
	return runs


## How a point comes to rest at `rest`, from its positions a tick apart,
## measured along `axis` (a unit vector: the way it travels to get there):
## - ticks: how many positions there are;
## - overshoot: how far it went past `rest` along `axis`, in metres;
## - settle_ticks: ticks until it stayed within SETTLED of `rest` (all of
##   them if it never did);
## - reversals: turns between moving along `axis` and against it until then;
## - settled_reversals: turns along `axis` once settled (bobbing);
## - jitter: the largest wobble once settled (see wobble()), in metres.
static func settling(positions: Array, rest: Vector3, axis: Vector3) -> Dictionary:
	var result := {"ticks": positions.size(), "overshoot": 0.0, "settle_ticks": positions.size(),
			"reversals": 0, "settled_reversals": 0, "jitter": 0.0}
	if positions.is_empty():
		return result
	var settle := positions.size()
	for i in range(positions.size() - 1, -1, -1):
		if (positions[i] as Vector3).distance_to(rest) > SETTLED:
			break
		settle = i
	result.settle_ticks = settle
	for position: Vector3 in positions:
		result.overshoot = maxf(result.overshoot, (position - rest).dot(axis))
	result.reversals = reversals(positions.slice(0, settle + 1), axis)
	var settled := positions.slice(settle)
	result.settled_reversals = reversals(settled, axis)
	result.jitter = wobble(settled)
	return result


## The largest wobble of positions a tick apart: how far any one is from the
## midpoint of its neighbours, in metres. A steady drift has none; a point
## shaking back and forth every tick wobbles by its move in a tick.
static func wobble(positions: Array) -> float:
	var largest := 0.0
	for i in range(1, positions.size() - 1):
		var middle := ((positions[i - 1] as Vector3) + (positions[i + 1] as Vector3)) * 0.5
		largest = maxf(largest, (positions[i] as Vector3).distance_to(middle))
	return largest


## Turns between moving along `axis` and against it, over positions a tick
## apart. A move under REVERSAL_DEADBAND in a tick is standing still, and
## neither starts nor ends a turn.
static func reversals(positions: Array, axis: Vector3) -> int:
	var count := 0
	var heading := 0.0
	for i in range(1, positions.size()):
		var move := ((positions[i] as Vector3) - (positions[i - 1] as Vector3)).dot(axis)
		if absf(move) <= REVERSAL_DEADBAND:
			continue
		if heading != 0.0 and signf(move) != heading:
			count += 1
		heading = signf(move)
	return count


## Every number in a run's results, keyed "scenario.measurement", so two runs
## can be compared measurement by measurement.
static func key_metrics(results: Array) -> Dictionary:
	var flat := {}
	for result: Dictionary in results:
		_flatten(result.final_position, "%s.final_position" % result.name, flat)
		_flatten(result.analysis, result.name, flat)
	return flat


## The measurements in `actual` that differ from `reference` by more than
## `relative` of the reference value or `absolute`, whichever is larger, and
## any the reference has that `actual` lacks. Empty when they match.
## Measurements added after the reference was recorded are not compared (see
## unrecorded()): the reference guards what it recorded.
static func compare(actual: Dictionary, reference: Dictionary, relative: float,
		absolute: float) -> Array[String]:
	var failures: Array[String] = []
	for key: String in reference:
		if not actual.has(key):
			failures.append("%s: missing (reference %.4f)" % [key, reference[key]])
			continue
		var value: float = actual[key]
		var expected: float = reference[key]
		if absf(value - expected) > maxf(absolute, relative * absf(expected)):
			failures.append("%s: %.4f against reference %.4f" % [key, value, expected])
	return failures


## The names of measurements in `actual` that `reference` does not have, each
## once, without the scenario: those added since the reference was recorded.
static func unrecorded(actual: Dictionary, reference: Dictionary) -> Array[String]:
	var names: Array[String] = []
	for key: String in actual:
		var name := key.get_slice(".", key.get_slice_count(".") - 1)
		if not reference.has(key) and name not in names:
			names.append(name)
	return names


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


static func _flatten(value: Variant, key: String, into: Dictionary) -> void:
	match typeof(value):
		TYPE_DICTIONARY:
			for name: String in value:
				_flatten(value[name], "%s.%s" % [key, name], into)
		TYPE_ARRAY:
			for i in (value as Array).size():
				_flatten(value[i], "%s.%d" % [key, i], into)
		TYPE_FLOAT, TYPE_INT:
			into[key] = float(value)
		TYPE_BOOL:
			into[key] = 1.0 if value else 0.0
