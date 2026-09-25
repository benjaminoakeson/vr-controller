class_name BaselineChecklist
extends RefCounted

## The headset baseline as plain instructions that tick themselves off.
##
## Each item watches the recorder's samples for the thing it asks for, so the
## player only has to do it: nothing needs pressing, reading or writing down.
## Items are shown one at a time in a sensible order. The drop is last and
## optional because a 4 m fall is the least comfortable item.

enum Step { WALK, HALF, STEPS_UP, STEPS_DOWN, RAMP_DOWN, RAMP_UP, WALL, CROUCH, RUN, DROP }

const PROMPTS := {
	Step.WALK: ["Push the left stick all the way forward and walk across the flat floor, then let go.",
			"Stand still in your room; only the stick moves you."],
	Step.HALF: ["Now walk with the stick pushed only about halfway.", ""],
	Step.STEPS_UP: ["Walk up the three steps to the top.",
			"They are near the big wall, on the side with the boxes on a post."],
	Step.STEPS_DOWN: ["Walk back down the steps.", ""],
	Step.RAMP_DOWN: ["Walk down the long ramp.",
			"It starts at the far corner behind the mirror. Stop on the small platform at the bottom; the far edge is a drop into nothing."],
	Step.RAMP_UP: ["Turn around and walk back up the ramp.", ""],
	Step.WALL: ["Use the stick to get right up to the big wall, then take a real step forward and lean your head into it.",
			"The wall should stop you."],
	Step.CROUCH: ["Crouch down low, then stand back up.", ""],
	Step.RUN: ["Squeeze both grips, pump your arms up and down, and push the stick forward.",
			"Like running. Keep it up for a couple of seconds."],
	Step.DROP: ["Last one (optional): walk into the square hole in the floor.",
			"It drops you about 4 m. Skip it if you'd rather not; you can take the headset off."],
}

## Seconds of the asked-for motion each timed item needs.
const WALK_TIME := 3.0
const HALF_TIME := 3.0
const RAMP_TIME := 3.0
const RUN_TIME := 1.0
## Rig pulled back in total before leaning into the wall counts, in metres.
const WALL_PULL := 0.15
## A crouch is the head below this share of standing height, then back above
## the second share.
const CROUCH_LOW := 0.65
const CROUCH_RECOVERED := 0.9
## The top step's tread, from the level, in metres above the main floor.
const TOP_STEP_HEIGHT := 0.755
const FLAT_SLOPE := 3.0
const RAMP_SLOPE_MIN := 10.0
const RAMP_SLOPE_MAX := 20.0
## Walking commanded at full stick is 1.5 m/s in the scene; these bracket full
## and roughly half stick without depending on the exact tuning.
const FULL_STICK_SPEED := 1.2
const HALF_STICK_MIN := 0.3

var current := Step.WALK
var complete := false

var _progress := 0.0
var _crouched := false
var _standing_height := 0.0
var _airborne := 0.0


## The instruction to show now: step number, what to do, and a hint.
func prompt() -> String:
	if complete:
		return "All done - thank you!\nYou can take off the headset."
	var lines: Array = PROMPTS[current]
	var text := "Test %d of %d\n%s" % [current + 1, Step.size(), lines[0]]
	if not (lines[1] as String).is_empty():
		text += "\n(%s)" % lines[1]
	return text


## Feeds one recorded tick. `sample` holds the recorder's per-tick values.
func update(sample: Dictionary, delta: float) -> void:
	if complete:
		return
	var grounded: bool = sample.grounded
	var slope: float = sample.slope_deg
	var commanded: float = sample.commanded
	var head: float = sample.head_height
	_standing_height = maxf(_standing_height, head)
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
			if grounded and absf(sample.y - TOP_STEP_HEIGHT) < 0.05:
				_advance()
		Step.STEPS_DOWN:
			if grounded and absf(sample.y) < 0.05:
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
			if _progress >= WALL_PULL:
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


func _advance() -> void:
	_progress = 0.0
	_airborne = 0.0
	_crouched = false
	if current == Step.DROP:
		complete = true
	else:
		current = (current + 1) as Step
