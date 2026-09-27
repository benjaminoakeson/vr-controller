class_name BaselineChecklist
extends RefCounted

## The headset baseline as plain instructions that tick themselves off.
##
## Each item watches the recorder's samples for the thing it asks for, so the
## player only has to do it: nothing needs pressing, reading or writing down.
## Items are shown one at a time, from the list given when the checklist is
## made, so a session can leave out what the current body cannot do yet. The
## drop is last and optional because a 4 m fall is the least comfortable item.

enum Step { WALK, HALF, STEPS_UP, STEPS_DOWN, RAMP_DOWN, RAMP_UP, WALL, CROUCH, RUN, DROP, JUMP,
		HAND_TOUCH, HAND_PUSH, VAULT, STICK_ROOM, PALM_SLIDE, FINGERS, FINGER_WRAP, BODY_TOUCH, PROP_PUSH, PALM_LIFT, GRAB }

const PROMPTS := {
	Step.WALK: ["Push the left stick all the way forward and walk across the flat floor, then let go.",
			"Stand still in your room; only the stick moves you."],
	Step.HALF: ["Now walk with the stick pushed only about halfway.", ""],
	Step.STEPS_UP: ["Walk up the three steps to the top.",
			"They are near the big wall, on the side with the boxes on a post."],
	Step.STEPS_DOWN: ["Walk back down the steps.", ""],
	Step.RAMP_DOWN: ["Walk down the long ramp.",
			"It starts at the corner of the floor opposite the big wall, on the same side as the steps. Stop on the small platform at the bottom; the far edge is a drop into nothing."],
	Step.RAMP_UP: ["Turn around and walk back up the ramp.", ""],
	Step.WALL: ["Use the stick to get right up to the big wall, then take a real step forward and lean into it.",
			"Then step back again."],
	Step.CROUCH: ["Crouch down low, then stand back up.", ""],
	Step.RUN: ["Squeeze both grips, pump your arms up and down, and push the stick forward.",
			"Like running. Keep it up for a couple of seconds."],
	Step.JUMP: ["Press A on your right controller to jump. Try it standing, then while walking.",
			"On the flat floor, away from the hole."],
	Step.HAND_TOUCH: ["Put one hand flat on the table with the boxes on it, then press down into it.",
			"Hold the press for a moment."],
	Step.HAND_PUSH: ["Walk up to the big wall, put both hands on it, and push yourself away from it.",
			"Try a small push, then a bigger one."],
	Step.VAULT: ["Put both hands on the table and press down to lift yourself up, a little, then more. Then let go.",
			"The table is the post with the boxes on it."],
	Step.STICK_ROOM: ["Hold the left stick forward and, at the same time, really walk around your room: forward, back and to the side.",
			"Let go of the stick at once if anything feels off."],
	Step.PALM_SLIDE: ["Rest one palm flat on the table and slide it around. Then press down harder and pull it toward you.",
			"The table is the post with the boxes on it."],
	Step.FINGERS: ["Open and close both hands fully a few times: squeeze the grip and trigger together, then let go. Try a fist and pointing too.",
			"Watch the physical fingers (white capsules) follow your hands."],
	Step.FINGER_WRAP: ["Put a hand over the edge or corner of a box on the table and close it: each finger should stop where it touches, and any finger over nothing should close fully. Try the table's edge too.",
			"Hold it closed for a moment and watch for twitching."],
	Step.BODY_TOUCH: ["Walk up to the table with the boxes and lean out over it, bringing your chest down toward the tabletop: your chest should stop at its edge.",
			"Keep your head above the table. The body parts are the blue shapes."],
	Step.PROP_PUSH: ["Push the boxes on the table around with your hands, then knock one onto the floor and walk into it.",
			"Try the heavy box too."],
	Step.PALM_LIFT: ["Squeeze a box between your two palms, without gripping, and lift it up. Then set it down.",
			"Push the boxes apart first if they are too close together."],
	Step.GRAB: ["Grab a box (squeeze the grip near it), lift it and swing it around fast: it should stay where your hand holds it. Then let go to drop it.",
			"Try the medium and the heavy box too."],
	Step.DROP: ["Last one (optional): walk into the square hole in the floor.",
			"It drops you about 4 m. Skip it if you'd rather not; you can take the headset off."],
}

## Seconds of the asked-for motion each timed item needs.
const WALK_TIME := 3.0
const HALF_TIME := 3.0
const RAMP_TIME := 3.0
const RUN_TIME := 1.0
## Leaning into the wall counts once the rig has been pulled back this far in
## total, in metres (kinematic body), or the head has gone this far into the
## wall (dynamic body without body parts), or the body's parts have pressed on
## it for WALL_PRESS_TIME seconds in all and then come away from it (dynamic
## body with parts, whose torso stops before the head gets in).
const WALL_PULL := 0.15
const WALL_DEPTH := 0.05
const WALL_PRESS_TIME := 0.5
## A crouch is the head below this share of standing height, then back above
## the second share.
const CROUCH_LOW := 0.65
const CROUCH_RECOVERED := 0.9
## The top step's tread, from the level, in metres above the main floor.
const TOP_STEP_HEIGHT := 0.755
const FLAT_SLOPE := 3.0
const RAMP_SLOPE_MIN := 10.0
const RAMP_SLOPE_MAX := 20.0
## A jump counts once the body has left the ground for at least this long,
## risen at least this far above where it left, and landed.
const JUMP_AIRTIME := 0.2
const JUMP_RISE := 0.2
## A hand counts as pressed while it touches something and is held this far
## off its target with at least this much force; the press must last
## HAND_TIME. A push counts once the body has moved PUSH_DISTANCE in all,
## horizontally and away from the hands, while both hands touch something.
## Movement back toward the hands subtracts, so small wobbles cancel out.
## Touching is required because a hand's drive force also rises when it merely
## lags its target, as when walking quickly; only horizontal movement away from
## the hands counts, because pressing down hard enough lifts the body.
const HAND_OFFSET := 0.05
const HAND_FORCE := 100.0
const HAND_TIME := 1.0
const PUSH_DISTANCE := 0.1
## A vault counts once both hands on something have lifted the body this far
## above where it left the ground, and it has landed again.
const VAULT_RISE := 0.05
## The body counts as supported up to a few centimetres above the floor, so a
## vault is measured from where it last stood still, below this vertical speed,
## with the hands off the table, and it has landed once it stands still again,
## hands off, within VAULT_LANDED of that height.
const VAULT_SETTLED_SPEED := 0.05
const VAULT_LANDED := 0.02
## Walking in the room with the stick held counts once the player has walked
## this far, in metres, at STICK_ROOM_WALK or faster while the stick asks for
## at least STICK_ROOM_COMMAND.
const STICK_ROOM_DISTANCE := 2.0
const STICK_ROOM_WALK := 0.2
const STICK_ROOM_COMMAND := 0.5
## Sliding a palm counts once hands touching something have moved this far
## along it in all, in metres.
const PALM_SLIDE_DISTANCE := 0.3
## A hand's fingers count as closed once their average bend passes
## FINGERS_CLOSED degrees, and as open again below FINGERS_OPEN; the item
## counts FINGERS_CYCLES such closings, from either hand.
const FINGERS_CLOSED := 50.0
const FINGERS_OPEN := 20.0
const FINGERS_CYCLES := 4
## Fingers count as stopped by something once a hand's fingers are held at
## least FINGER_WRAP_HELD degrees short of their pose for FINGER_WRAP_TIME.
const FINGER_WRAP_HELD := 20.0
const FINGER_WRAP_TIME := 0.5
## Body parts count as stopped by something once any of them has been pushed
## on for BODY_TOUCH_TIME seconds in all (leaning the chest onto the table).
const BODY_TOUCH_TIME := 0.3
## Pushing props counts once the body or a hand has pushed on a loose prop for
## PROP_PUSH_TIME seconds in all.
const PROP_PUSH_TIME := 1.0
## Lifting between the palms counts once both hands pushing on a prop have
## risen PALM_LIFT_RISE metres from where they both first touched it; the
## touch may break for up to PALM_LIFT_GAP seconds.
const PALM_LIFT_RISE := 0.08
const PALM_LIFT_GAP := 0.25
## Grabbing counts once a hand has held something for GRAB_TIME seconds in all
## and then let it go.
const GRAB_TIME := 1.0
## Walking commanded at full stick is 1.5 m/s in the scene; these bracket full
## and roughly half stick without depending on the exact tuning.
const FULL_STICK_SPEED := 1.2
const HALF_STICK_MIN := 0.3

## Every item in the order a player meets them.
const ALL_STEPS: Array[Step] = [Step.WALK, Step.HALF, Step.STEPS_UP, Step.STEPS_DOWN,
		Step.RAMP_DOWN, Step.RAMP_UP, Step.WALL, Step.CROUCH, Step.RUN, Step.JUMP,
		Step.HAND_TOUCH, Step.HAND_PUSH, Step.VAULT, Step.STICK_ROOM, Step.PALM_SLIDE, Step.FINGERS,
		Step.FINGER_WRAP, Step.BODY_TOUCH, Step.PROP_PUSH, Step.PALM_LIFT, Step.GRAB, Step.DROP]

var current := Step.WALK
var complete := false

var _steps: Array[Step] = []
var _index := 0

var _progress := 0.0
var _crouched := false
var _standing_height := 0.0
var _airborne := 0.0
var _last_position := Vector3.ZERO
var _takeoff_height := 0.0
var _last_hands: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _fingers_closed: Array[bool] = [false, false]
var _peak_height := 0.0
var _pressed_time := 0.0
var _lift_from := NAN
var _apart_for := 0.0


func _init(steps: Array[Step] = ALL_STEPS) -> void:
	_steps = steps
	current = _steps[0]


## The instruction to show now: item number, what to do, and a hint.
func prompt() -> String:
	if complete:
		return "All done - thank you!\nYou can take off the headset."
	var lines: Array = PROMPTS[current]
	var text := "Test %d of %d\n%s" % [_index + 1, _steps.size(), lines[0]]
	if not (lines[1] as String).is_empty():
		text += "\n(%s)" % lines[1]
	return text


## Feeds one recorded tick.
func update(sample: LocomotionRecorder.Sample, delta: float) -> void:
	if complete:
		return
	var grounded := sample.grounded
	var slope := sample.slope_deg
	var commanded := sample.commanded
	var head := sample.head_height
	_standing_height = maxf(_standing_height, head)
	var moved := sample.position - _last_position
	_last_position = sample.position
	var last_hands := _last_hands
	_last_hands = [sample.left_hand, sample.right_hand]
	match current:
		Step.WALK:
			if grounded and slope < FLAT_SLOPE and commanded >= FULL_STICK_SPEED:
				_progress += delta
			# Done once enough walking is in and the body has come to rest,
			# so the recording includes a stop.
			if _progress >= WALK_TIME and commanded == 0.0 and sample.speed < 0.05:
				_advance()
		Step.HALF:
			if grounded and slope < FLAT_SLOPE \
					and commanded >= HALF_STICK_MIN and commanded < FULL_STICK_SPEED:
				_progress += delta
			if _progress >= HALF_TIME:
				_advance()
		Step.STEPS_UP:
			if grounded and absf(sample.position.y - TOP_STEP_HEIGHT) < 0.05:
				_advance()
		Step.STEPS_DOWN:
			if grounded and absf(sample.position.y) < 0.05:
				_advance()
		Step.RAMP_DOWN, Step.RAMP_UP:
			var direction := -1.0 if current == Step.RAMP_DOWN else 1.0
			if grounded and slope > RAMP_SLOPE_MIN and slope < RAMP_SLOPE_MAX \
					and sample.speed_v * direction > 0.1:
				_progress += delta
			if _progress >= RAMP_TIME:
				_advance()
		Step.WALL:
			_progress += sample.origin_correction
			if sample.parts_pressing > 0:
				_pressed_time += delta
			var leaned_on := _pressed_time >= WALL_PRESS_TIME and sample.parts_pressing == 0
			if _progress >= WALL_PULL or sample.head_obstruction >= WALL_DEPTH or leaned_on:
				_advance()
		Step.CROUCH:
			if head < _standing_height * CROUCH_LOW:
				_crouched = true
			elif _crouched and head > _standing_height * CROUCH_RECOVERED:
				_advance()
		Step.RUN:
			if sample.run_factor >= 0.6:
				_progress += delta
			if _progress >= RUN_TIME:
				_advance()
		Step.DROP:
			if not grounded:
				_airborne += delta
			elif _airborne > 0.4:
				_advance()
		Step.HAND_TOUCH:
			var left := sample.left_touching and sample.left_separation >= HAND_OFFSET \
					and sample.left_force >= HAND_FORCE
			var right := sample.right_touching and sample.right_separation >= HAND_OFFSET \
					and sample.right_force >= HAND_FORCE
			if left or right:
				_progress += delta
			if _progress >= HAND_TIME:
				_advance()
		Step.HAND_PUSH:
			if sample.left_touching and sample.right_touching:
				var away := sample.position - (sample.left_hand + sample.right_hand) * 0.5
				away.y = 0.0
				moved.y = 0.0
				if not away.is_zero_approx():
					_progress = maxf(_progress + moved.dot(away.normalized()), 0.0)
			if _progress >= PUSH_DISTANCE:
				_advance()
		Step.FINGERS:
			var bends: Array[float] = [sample.left_finger_bend, sample.right_finger_bend]
			for i in 2:
				if bends[i] >= FINGERS_CLOSED:
					_fingers_closed[i] = true
				elif bends[i] <= FINGERS_OPEN and _fingers_closed[i]:
					_fingers_closed[i] = false
					_progress += 1.0
			if _progress >= FINGERS_CYCLES:
				_advance()
		Step.FINGER_WRAP:
			if maxf(sample.left_finger_error, sample.right_finger_error) >= FINGER_WRAP_HELD:
				_progress += delta
			else:
				_progress = 0.0
			if _progress >= FINGER_WRAP_TIME:
				_advance()
		Step.GRAB:
			var holding := sample.left_grab == 2 or sample.right_grab == 2
			if holding:
				_progress += delta
			elif _progress >= GRAB_TIME and sample.left_grab == 0 and sample.right_grab == 0:
				_advance()
		Step.PALM_LIFT:
			var hands := (sample.left_hand.y + sample.right_hand.y) * 0.5
			if sample.prop_contact & 6 == 6:
				_apart_for = 0.0
				if is_nan(_lift_from):
					_lift_from = hands
				elif hands - _lift_from >= PALM_LIFT_RISE:
					_advance()
			else:
				_apart_for += delta
				if _apart_for > PALM_LIFT_GAP:
					_lift_from = NAN
		Step.PROP_PUSH:
			if sample.prop_contact != 0:
				_progress += delta
			if _progress >= PROP_PUSH_TIME:
				_advance()
		Step.BODY_TOUCH:
			if sample.parts_pressing > 0:
				_progress += delta
			if _progress >= BODY_TOUCH_TIME:
				_advance()
		Step.PALM_SLIDE:
			var touching: Array[bool] = [sample.left_touching, sample.right_touching]
			for i in 2:
				var slid := Vector2(_last_hands[i].x - last_hands[i].x, _last_hands[i].z - last_hands[i].z)
				# A jump this large in one tick is a relocation, not a slide.
				if touching[i] and slid.length() < 0.1:
					_progress += slid.length()
			if _progress >= PALM_SLIDE_DISTANCE:
				_advance()
		Step.STICK_ROOM:
			if commanded >= STICK_ROOM_COMMAND and sample.room_speed >= STICK_ROOM_WALK:
				_progress += sample.room_speed * delta
			if _progress >= STICK_ROOM_DISTANCE:
				_advance()
		Step.VAULT:
			var pressing := sample.left_touching and sample.right_touching
			if pressing:
				_peak_height = maxf(_peak_height, sample.position.y)
			elif grounded and absf(sample.speed_v) < VAULT_SETTLED_SPEED:
				if _peak_height - _takeoff_height >= VAULT_RISE \
						and sample.position.y <= _takeoff_height + VAULT_LANDED:
					_advance()
					return
				_takeoff_height = sample.position.y
				_peak_height = sample.position.y
		Step.JUMP:
			if not grounded:
				_airborne += delta
				_peak_height = maxf(_peak_height, sample.position.y)
			else:
				if _airborne >= JUMP_AIRTIME and _peak_height - _takeoff_height >= JUMP_RISE:
					_advance()
					return
				_airborne = 0.0
				_takeoff_height = sample.position.y
				_peak_height = sample.position.y


func _advance() -> void:
	_progress = 0.0
	_airborne = 0.0
	_crouched = false
	_pressed_time = 0.0
	_lift_from = NAN
	_apart_for = 0.0
	_index += 1
	if _index >= _steps.size():
		complete = true
	else:
		current = _steps[_index]
