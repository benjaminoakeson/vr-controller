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
		+ "left_command_gap,right_command_gap,left_sag,right_sag,left_holding,right_holding,stage," \
		+ "left_grab_role,right_grab_role,aiming," \
		+ "left_spin,right_spin,left_spin_back,right_spin_back,left_turn_error,right_turn_error," \
		+ "left_tracked_step,right_tracked_step,left_tracked_turn,right_tracked_turn," \
		+ "left_held_mass,right_held_mass,left_held_offset,right_held_offset," \
		+ "left_on_hold,right_on_hold,leg_tuck,turns," \
		+ "left_throw_speed,right_throw_speed,left_throw_off,right_throw_off," \
		+ "left_throw_own,right_throw_own," \
		+ "left_strikes,right_strikes,left_strike_source,right_strike_source," \
		+ "left_strike_energy,right_strike_energy,left_strike_damage,right_strike_damage," \
		+ "left_strike_speed,right_strike_speed,left_strike_mass,right_strike_mass," \
		+ "left_strike_material,right_strike_material,left_strike_kind,right_strike_kind," \
		+ "left_strike_x,right_strike_x,left_strike_y,right_strike_y,left_strike_z,right_strike_z," \
		+ "left_chop_outcome,right_chop_outcome,left_chop_depth,right_chop_depth," \
		+ "left_chop_line,right_chop_line,left_chop_offset,right_chop_offset,left_chop_side,right_chop_side," \
		+ "left_leg_extension,right_leg_extension,left_drawn_slip,right_drawn_slip," \
		+ "left_held_turn,right_held_turn,carried_mass"
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
	## Each hand's grab (HandGrab.State: 0 idle, 1 seating, 2 holding).
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
# Each physical hand's turn, its spin, and its target before the arm's
# strength last tick, for the wrist columns (2026-09-27: a 10 kg box held out
# made the wrist jitter in the headset, which no column showed).
var _last_hands: Array[Basis] = [Basis.IDENTITY, Basis.IDENTITY]
var _last_spins: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _last_tracked: Array[Transform3D] = [Transform3D.IDENTITY, Transform3D.IDENTITY]
var _wrists_seen := false
var _throws_seen := PackedInt32Array([0, 0])
var _strikes_seen := PackedInt32Array([0, 0])
# The furthest each hand's held object was drawn from where the hand holds
# it, over the frames drawn since the last tick (sample_drawn), in metres.
var _drawn_slip := PackedFloat32Array([0.0, 0.0])


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
	_drawn_slip.fill(0.0)


## Measures, as a frame is drawn, how far each held object is drawn from the
## hand holding it as the avatar shows it (HandGrab.drawn_gap): what the
## player sees slip, beside the physics' own gap. Call from _process.
func sample_drawn() -> void:
	var dynamic := _physical as DynamicPhysical
	if dynamic == null or dynamic.left_grab == null or dynamic.right_grab == null:
		return
	var state := _physical.snapshot
	for side in 2:
		var grab := dynamic.left_grab if side == 0 else dynamic.right_grab
		_drawn_slip[side] = maxf(_drawn_slip[side], grab.drawn_gap(state.hands[side]))


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
	_wrists_seen = false
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
	var throws_now := _throw_columns(state, delta)
	_file.store_line(("%.4f,%d,%.5f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%d,%.2f,%.3f,%.4f,"
			+ "%.4f,%.4f,%.4f,%.4f,%.4f,%.3f,%.4f,%.4f,%.4f,%.3f,%.1f,%d,%d,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.1f,%.1f,%d,%d,%d,%d,%.4f,%.4f,%.4f,%.4f,%.4f,%.2f,%.2f,%.2f,%.2f,%d,%d,%d,%d,%d,%.4f,%.4f,%.4f,%.2f,%d,%d,%.4f,%.4f,%.4f,%.4f,%.4f,%.2f,%.2f,%.2f,%.2f,%d,%d,%d,%d") % [
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
			_largest_holding(state, 0), _largest_holding(state, 1), stage,
			state.grab_role[0], state.grab_role[1], int(state.grab_aiming[0] and state.grab_aiming[1])]
			+ _wrist_columns(state, delta) \
			+ ",%d,%d,%.3f,%d" % [int(state.grab_on_hold[0]), int(state.grab_on_hold[1]), state.body_tuck, state.turns] \
			+ throws_now + _strike_columns(state) \
			# How much of its length each leg spans, hip to ankle (1 = straight;
			# beyond that the shin stretches).
			+ ",%.3f,%.3f" % [_rig.skeleton.left_leg_extension, _rig.skeleton.right_leg_extension] \
			+ ",%.4f,%.4f" % [_drawn_slip[0], _drawn_slip[1]] \
			+ ",%.2f,%.2f,%.2f" % [state.grab_turn[0], state.grab_turn[1], state.carried_mass])
	_since_flush += delta
	if _since_flush >= FLUSH_INTERVAL:
		_since_flush = 0.0
		_file.flush()


## Per hand, left then right, on the tick a prop was thrown (zero otherwise):
## the speed it left with (m/s), how far its way was off the way the player's
## hand (the static skeleton's) was going, in degrees, and the speed its own
## last step gave it (m/s). Read before _wrist_columns moves on the hands it
## remembers.
func _throw_columns(state: PoseSnapshot, delta: float) -> String:
	var speeds := [0.0, 0.0]
	var offs := [0.0, 0.0]
	var owns := [0.0, 0.0]
	for side in 2:
		if state.throws[side] == _throws_seen[side]:
			continue
		_throws_seen[side] = state.throws[side]
		var thrown := state.throw_velocity[side]
		speeds[side] = thrown.length()
		owns[side] = state.throw_own_velocity[side].length()
		if _wrists_seen and delta > 0.0:
			var hand := (state.hand_tracked[side].origin - _last_tracked[side].origin) / delta
			offs[side] = rad_to_deg(hand.angle_to(thrown))
	return ",%.3f,%.3f,%.2f,%.2f,%.3f,%.3f" % [speeds[0], speeds[1], offs[0], offs[1], owns[0], owns[1]]


## Per hand, left then right: the strikes it has made so far, and on the tick it
## made one (zeros otherwise) where that came from (HandStrikes.Source), its
## energy (J), the damage it did, its closing speed (m/s), the mass it met (kg)
## the struck material's id (StrikeMaterial.id) and the damage type (Strike.Kind).
## Then where it landed (world x, y, z) and, on a tree, what the chop made of it
## (Strike.judged, 2026-10-02): the outcome (TreeChop.Outcome, 0 off any tree),
## the branch's depth, the line it counted on or the nearest, how far along the
## branch from that line it landed (m) and the side it opened (-1 for none).
func _strike_columns(state: PoseSnapshot) -> String:
	var sources := [0, 0]
	var energies := [0.0, 0.0]
	var damages := [0.0, 0.0]
	var speeds := [0.0, 0.0]
	var masses := [0.0, 0.0]
	var materials := [0, 0]
	var kinds := [0, 0]
	var points: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
	var outcomes := [0, 0]
	var depths := [-1, -1]
	var lines := [-1, -1]
	var offsets := [0.0, 0.0]
	var sides := [-1, -1]
	for side in 2:
		var strike := state.last_strikes[side]
		if state.strikes[side] == _strikes_seen[side] or strike == null:
			continue
		_strikes_seen[side] = state.strikes[side]
		sources[side] = state.strike_sources[side]
		energies[side] = strike.energy
		damages[side] = strike.damage
		speeds[side] = strike.speed
		masses[side] = strike.effective_mass
		materials[side] = strike.material.id if strike.material != null else 0
		kinds[side] = strike.kind
		points[side] = strike.point
		outcomes[side] = strike.judged.get("outcome", 0)
		depths[side] = strike.judged.get("depth", -1)
		lines[side] = strike.judged.get("line", -1)
		offsets[side] = strike.judged.get("offset", 0.0)
		sides[side] = strike.judged.get("side", -1)
	return ",%d,%d,%d,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%d,%d,%d" % [
			state.strikes[0], state.strikes[1], sources[0], sources[1], energies[0], energies[1],
			damages[0], damages[1], speeds[0], speeds[1], masses[0], masses[1], materials[0], materials[1],
			kinds[0], kinds[1]] \
			+ ",%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%d,%d,%d,%d,%d,%.3f,%.3f,%d,%d" % [
			points[0].x, points[1].x, points[0].y, points[1].y, points[0].z, points[1].z,
			outcomes[0], outcomes[1], depths[0], depths[1], lines[0], lines[1], offsets[0], offsets[1],
			sides[0], sides[1]]


## Per hand, left then right: how fast the physical hand turns (rad/s);
## whether its spin turned back this tick (1) while over 0.05 rad/s; how far
## it is turned off its target (degrees); how far its target before the arm's
## strength (the static skeleton's hand, or while two-handed the shared
## target) moved (mm) and turned (degrees) this tick, which on a still hand is
## the tracking's tremble; and the mass it pulls in or holds (kg), and how
## far that mass's centre is from the hand's centre (m).
func _wrist_columns(state: PoseSnapshot, delta: float) -> String:
	var spins := [0.0, 0.0]
	var backs := [0, 0]
	var errors := [0.0, 0.0]
	var steps := [0.0, 0.0]
	var turns := [0.0, 0.0]
	for side in 2:
		var hand := state.hands[side].basis.orthonormalized()
		var tracked := state.hand_tracked[side].orthonormalized()
		errors[side] = rad_to_deg(ArmStrength.rotation_between(hand, state.hand_targets[side].basis).length())
		if _wrists_seen:
			var spin := ArmStrength.rotation_between(_last_hands[side], hand) / delta
			spins[side] = spin.length()
			backs[side] = int(spin.length() > 0.05 and spin.dot(_last_spins[side]) < 0.0)
			steps[side] = tracked.origin.distance_to(_last_tracked[side].origin) * 1000.0
			turns[side] = rad_to_deg(ArmStrength.rotation_between(_last_tracked[side].basis, tracked.basis).length())
			_last_spins[side] = spin
		_last_hands[side] = hand
		_last_tracked[side] = tracked
	_wrists_seen = true
	return (",%.3f,%.3f,%d,%d,%.2f,%.2f,%.3f,%.3f,%.3f,%.3f,%.2f,%.2f,%.4f,%.4f") % [spins[0], spins[1], backs[0], backs[1],
			errors[0], errors[1], steps[0], steps[1], turns[0], turns[1], state.grab_mass[0], state.grab_mass[1],
			state.grab_offset[0], state.grab_offset[1]]


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
