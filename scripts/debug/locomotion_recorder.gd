class_name LocomotionRecorder
extends RefCounted

## Measures what locomotion did on each physics tick and, while recording,
## writes it to a CSV, one row per tick.
##
## It reads the physical layer's snapshot, the rig and the static skeleton
## after they have finished the tick, and writes nothing back. Speeds come from how far the
## body actually moved, so they include the body following the headset.
## tests/harness/analysis.gd measures these files, simulated or headset alike.

const CSV_HEADER := "time_s,tick_hz,delta_s,x,y,z,speed,speed_h,speed_v,commanded," \
		+ "grounded,slope_deg,run_factor,origin_correction,head_height,head_x,head_z," \
		+ "left_foot_height,right_foot_height,physics_ms,body_height,head_lead," \
		+ "head_obstruction,blackout,motor_force,relocations,step_phase," \
		+ "left_hand_x,left_hand_y,left_hand_z,right_hand_x,right_hand_y,right_hand_z," \
		+ "left_separation,right_separation,left_force,right_force,left_contacts,right_contacts," \
		+ "left_touching,right_touching,room_speed,view_vx,view_vz,commanded_x,commanded_z," \
		+ "left_finger_error,right_finger_error,left_finger_bend,right_finger_bend," \
		+ "left_finger_reversals,right_finger_reversals," \
		+ "parts_pressing,parts_pressed,prop_contact,prop_x,prop_y,prop_z,prop_mass," \
		+ "left_grab,right_grab,left_grab_gap,right_grab_gap,arm_stretch," \
		+ "left_command_gap,right_command_gap,left_sag,right_sag,left_holding,right_holding,stage"
## A recording reaches the disk at least this often, in seconds, so a session
## closed from outside loses little.
const FLUSH_INTERVAL := 1.0


## One finished tick. The same instance is overwritten every tick.
class Sample:
	## How far the body moved this tick, in metres.
	var distance := 0.0
	## Speeds from that movement, in m/s: total, horizontal and vertical.
	var speed := 0.0
	var speed_h := 0.0
	var speed_v := 0.0
	## The movement intent the physical layer gave the static skeleton, in m/s.
	var commanded := 0.0
	## On its feet: supported, or being lifted or lowered a step by the legs.
	var grounded := false
	## 0 walking or standing, 1 lifting up a step, 2 stepping down.
	var step_phase := 0
	var slope_deg := 0.0
	var run_factor := 0.0
	## How far the rig was pulled back because the body could not follow the
	## headset, in metres.
	var origin_correction := 0.0
	## The headset's height above the rig's floor, in metres.
	var head_height := 0.0
	## The collision capsule's height, in metres.
	var body_height := 0.0
	## How far the head's footprint leads the body's feet, in metres.
	var head_lead := 0.0
	## How far the head has gone into a surface the body could not follow, in metres.
	var head_obstruction := 0.0
	## How far the view is blacked out for a relocation, 0 to 1.
	var blackout := 0.0
	## The walking motor's force, in newtons.
	var motor_force := 0.0
	## Relocations (recentre, respawn) so far.
	var relocations := 0
	## Each physical hand's distance from its target, in metres, and its drive's
	## force limit, in newtons.
	var left_separation := 0.0
	var right_separation := 0.0
	var left_force := 0.0
	var right_force := 0.0
	## Whether each hand is touching something, and where each hand is.
	var left_touching := false
	var right_touching := false
	var left_hand := Vector3.ZERO
	var right_hand := Vector3.ZERO
	## The body's feet, in world space.
	var position := Vector3.ZERO
	## The player's own walking speed in their room, from the headset, in m/s.
	var room_speed := 0.0
	## How fast the rig, and so the view, moved over the ground this tick, in
	## m/s: the stick's walking should be all of it.
	var view_velocity := Vector3.ZERO
	## The stick's walking velocity over the ground, in m/s.
	var commanded_velocity := Vector3.ZERO
	## Each hand's largest finger-joint gap to the static pose, and its fingers'
	## average bend, in degrees.
	var left_finger_error := 0.0
	var right_finger_error := 0.0
	var left_finger_bend := 0.0
	var right_finger_bend := 0.0
	## Finger joints that turned back this tick while their pose held still.
	var left_finger_reversals := 0
	var right_finger_reversals := 0
	## How many body parts something is pushing on, which (bit n for
	## BodyParts.Part n), and the most either arm is stretched to stay joined,
	## in metres.
	var parts_pressing := 0
	var parts_pressed := 0
	## Which of the body (1) and hands (2 left, 4 right) pushed on a loose prop.
	var prop_contact := 0
	## Each hand's grab (HandGrab.State: 0 idle, 1 pulling in, 2 holding).
	var left_grab := 0
	var right_grab := 0
	var arm_stretch := 0.0


var sample := Sample.new()
var recording := false
## The file being written, or the last one written.
var path := ""
## Seconds written to the current or last recording.
var elapsed := 0.0
## The guided-session item on screen this tick, or -1. Written with each row.
var stage := -1

var _physical: PlayerPhysical
var _rig: PlayerRig
var _file: FileAccess
var _previous := Vector3.ZERO
var _previous_rig := Vector3.ZERO
var _previous_room_head := Vector3.ZERO
var _primed := false
var _relocations := 0
var _since_flush := 0.0


func _init(physical: PlayerPhysical, rig: PlayerRig) -> void:
	_physical = physical
	_rig = rig


## Measures the tick that has just finished, and writes it when recording.
## Call once per physics tick, after the static skeleton has solved.
func measure(delta: float) -> void:
	var state := _physical.snapshot
	var position := state.body_position
	# A relocation is a teleport, not movement: start measuring afresh.
	var rig := _rig.global_position
	var room_head := _rig.head.position
	if not _primed or state.relocations != _relocations:
		_previous = position
		_previous_rig = rig
		_previous_room_head = room_head
		_relocations = state.relocations
		_primed = true
	var moved := position - _previous
	_previous = position
	var rig_moved := rig - _previous_rig
	_previous_rig = rig
	var walked := room_head - _previous_room_head
	_previous_room_head = room_head
	sample.room_speed = Vector2(walked.x, walked.z).length() / delta
	sample.view_velocity = Vector3(rig_moved.x, 0.0, rig_moved.z) / delta
	sample.commanded_velocity = state.commanded_travel
	sample.left_finger_error = state.finger_error[0]
	sample.right_finger_error = state.finger_error[1]
	sample.left_finger_bend = state.finger_bend[0]
	sample.right_finger_bend = state.finger_bend[1]
	sample.left_finger_reversals = state.finger_reversals[0]
	sample.right_finger_reversals = state.finger_reversals[1]
	sample.parts_pressing = state.parts_pressing
	sample.parts_pressed = state.parts_pressed
	sample.prop_contact = state.prop_contact
	sample.left_grab = state.grab_state[0]
	sample.right_grab = state.grab_state[1]
	sample.arm_stretch = maxf(state.arm_stretch[0], state.arm_stretch[1])
	sample.distance = moved.length()
	sample.speed = sample.distance / delta
	sample.speed_h = Vector2(moved.x, moved.z).length() / delta
	sample.speed_v = moved.y / delta
	sample.commanded = state.commanded_travel.length()
	sample.grounded = state.supported or state.lifting or state.stepping_down
	sample.step_phase = 1 if state.lifting else (2 if state.stepping_down else 0)
	sample.slope_deg = rad_to_deg(state.ground_normal.angle_to(Vector3.UP))
	sample.run_factor = state.run_factor
	sample.origin_correction = state.rig_correction
	sample.head_height = _rig.head.position.y
	sample.body_height = state.body_height
	sample.head_lead = state.head_lead.length()
	sample.head_obstruction = state.head_obstruction
	sample.blackout = state.blackout
	sample.motor_force = state.motor_force.length()
	sample.relocations = state.relocations
	sample.left_separation = state.hand_separation[0]
	sample.right_separation = state.hand_separation[1]
	sample.left_force = state.hand_force[0]
	sample.right_force = state.hand_force[1]
	sample.left_touching = state.hand_touching[0]
	sample.right_touching = state.hand_touching[1]
	sample.left_hand = state.hands[0].origin
	sample.right_hand = state.hands[1].origin
	sample.position = position
	if recording:
		_write(delta)


## Opens `<directory>/<label>_<time>.csv`. Returns false if it cannot be written.
func start(directory: String, label: String) -> bool:
	if recording:
		return true
	DirAccess.make_dir_recursive_absolute(directory)
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	path = directory.path_join("%s_%s.csv" % [label, stamp])
	# Two recordings in the same second must not overwrite each other.
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
	elapsed = 0.0
	_since_flush = 0.0
	recording = true
	print("LocomotionRecorder: recording to %s" % ProjectSettings.globalize_path(path))
	return true


## Closes the recording and returns its path, or an empty string if nothing
## was recording.
func stop() -> String:
	if not recording:
		return ""
	recording = false
	_file.close()
	_file = null
	print("LocomotionRecorder: %.1f s written to %s" % [elapsed, ProjectSettings.globalize_path(path)])
	return path


func _write(delta: float) -> void:
	elapsed += delta
	var state := _physical.snapshot
	var head := _rig.head.global_position
	_file.store_line(("%.4f,%d,%.5f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%d,%.2f,%.3f,%.4f,"
			+ "%.4f,%.4f,%.4f,%.4f,%.4f,%.3f,%.4f,%.4f,%.4f,%.3f,%.1f,%d,%d,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.1f,%.1f,%d,%d,%d,%d,%.4f,%.4f,%.4f,%.4f,%.4f,%.2f,%.2f,%.2f,%.2f,%d,%d,%d,%d,%d,%.4f,%.4f,%.4f,%.2f,%d,%d,%.4f,%.4f,%.4f,%.4f,%.4f,%.2f,%.2f,%.2f,%.2f,%d") % [
			elapsed, Engine.physics_ticks_per_second, delta,
			sample.position.x, sample.position.y, sample.position.z,
			sample.speed, sample.speed_h, sample.speed_v, sample.commanded,
			int(sample.grounded), sample.slope_deg, sample.run_factor,
			sample.origin_correction, sample.head_height, head.x, head.z,
			_foot_height(_rig.skeleton.left_foot_tracker),
			_foot_height(_rig.skeleton.right_foot_tracker),
			# The monitor reports the previous frame's physics time, not this tick's.
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
			sample.body_height, sample.head_lead, sample.head_obstruction, sample.blackout,
			sample.motor_force, sample.relocations, sample.step_phase,
			state.hands[0].origin.x, state.hands[0].origin.y, state.hands[0].origin.z,
			state.hands[1].origin.x, state.hands[1].origin.y, state.hands[1].origin.z,
			sample.left_separation, sample.right_separation, sample.left_force, sample.right_force,
			state.hand_contacts[0], state.hand_contacts[1],
			int(sample.left_touching), int(sample.right_touching),
			sample.room_speed, sample.view_velocity.x, sample.view_velocity.z,
			sample.commanded_velocity.x, sample.commanded_velocity.z,
			sample.left_finger_error, sample.right_finger_error,
			sample.left_finger_bend, sample.right_finger_bend,
			sample.left_finger_reversals, sample.right_finger_reversals,
			sample.parts_pressing, sample.parts_pressed, sample.prop_contact,
			state.prop_position.x, state.prop_position.y, state.prop_position.z, state.prop_mass,
			state.grab_state[0], state.grab_state[1], state.grab_gap[0], state.grab_gap[1],
			sample.arm_stretch,
			_command_gap(state, 0), _command_gap(state, 1),
			_largest_sag(state, 0), _largest_sag(state, 1),
			_largest_holding(state, 0), _largest_holding(state, 1), stage])
	_since_flush += delta
	if _since_flush >= FLUSH_INTERVAL:
		_since_flush = 0.0
		_file.flush()


## A reference foot's height above the body's feet. On stairs it shows
## whether the foot found the tread.
## How far the arm's strength moved a hand's target from the static
## skeleton's hand, in metres.
static func _command_gap(state: PoseSnapshot, side: int) -> float:
	return state.hand_tracked[side].origin.distance_to(state.hand_targets[side].origin)


## A hand's arm's larger dip, at the shoulder or wrist, in degrees.
static func _largest_sag(state: PoseSnapshot, side: int) -> float:
	var sag := state.arm_sag[side].abs()
	return rad_to_deg(maxf(sag.x, sag.y))


## The larger torque a hand's shoulder or wrist holds, in N·m.
static func _largest_holding(state: PoseSnapshot, side: int) -> float:
	var holding := state.arm_holding[side].abs()
	return maxf(holding.x, holding.y)


func _foot_height(foot: Node3D) -> float:
	return foot.global_position.y - sample.position.y if foot != null else 0.0
