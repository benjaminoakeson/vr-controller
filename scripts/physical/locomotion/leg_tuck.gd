class_name LegTuck
extends LocomotionModule

## Draws the legs up while the arms carry the body, and lets them down again
## (2026-09-28, decided with the player: climbing, step 2).
##
## The arms carry the body while a hand holds a Climbable hold, or an empty
## hand presses down on something (a table's top, a ledge). Once they have
## carried it off the ground, the capsule's bottom rises to about the bottom
## of the hips (CapsuleBody.tuck), so it can be hauled or vaulted over a ledge
## its legs would catch on. Its top stays with the head: nothing moves the
## view.
##
## The legs come down again:
## - still carried, when the feet reach the ground below: lowered onto a
##   floor, the body lands on its feet rather than its drawn-up bottom;
## - once nothing carries the body, at once into whatever room there is below
##   (hanging in the air, they just drop); what is left, when the drawn-up body
##   rests on something (hauled over a ledge onto it), by standing up: the legs
##   lift the body at up to stand_speed, easing to arrive at rest, so the view
##   rises smoothly by as much as they had drawn up.

## How far up the legs draw: the capsule's bottom rises to this share of the
## head's height above the feet, about the hips (0.90 m for a 1.70 m head; the
## hip joints at about 0.57 of it). Raised from 0.47 after the 2026-09-30
## headset session ("the legs should lift up slightly higher so it is easier
## to mantle"); above the hips' own shape, which rides up to stay above the
## drawn-up bottom (BodyParts).
@export_range(0.0, 0.8, 0.01) var tuck_share := 0.53
## How fast standing up lifts the body, and the view with it, in m/s.
@export_range(0.1, 3.0, 0.05, "suffix:m/s") var stand_speed := 1.0
## An empty hand presses down when it touches something with its target at
## least this far below it.
@export_range(0.0, 0.2, 0.005, "suffix:m") var press_depth := 0.03
## Still carried, the legs come down once the ground below is within this of
## where the feet would stand.
@export_range(0.0, 0.2, 0.005, "suffix:m") var landing_reach := 0.04

## Whether the legs are drawn up, or standing up out of it.
var tucked := false

var _tuck := 0.0


func contribute(frame: LocomotionFrame, _delta: float) -> void:
	var body := physical.body
	var carried := physical.climbing() or _pressing()
	if not tucked:
		# Off the ground further than a landing would put the feet back on it:
		# hauled up faster than 0.5 m/s the body is not supported a centimetre
		# up, and drawn up there the legs came straight back down (headset,
		# 2026-09-30: four one-tick flickers as climbs left the floor).
		var ground := physical.ground
		if carried and not ground.supported and not ground.stepping_down and ground.gap > landing_reach:
			tucked = true
			_tuck = tuck_share * rig.head.position.y
	elif not carried or _landing(body):
		tucked = false
	frame.target_tuck = _tuck if tucked else 0.0
	if tucked or body.tuck <= 0.0:
		return
	# Letting the legs down: what they cannot drop into they stand up out of.
	var resting: float = body.tuck - body.legroom(body.tuck)
	if resting > 0.0:
		frame.lift_speed = maxf(frame.lift_speed,
				minf(stand_speed, sqrt(2.0 * body.get_gravity().length() * resting)))
		frame.standing_up = true


## Whether an empty hand presses down on something (last tick's hands).
func _pressing() -> bool:
	var state := physical.snapshot
	for side in 2:
		if state.hand_touching[side] and state.grab_state[side] == HandGrab.State.IDLE \
				and state.hands[side].origin.y - state.hand_targets[side].origin.y > press_depth:
			return true
	return false


## Whether the ground below the drawn-up body is where its feet would stand.
func _landing(body: CapsuleBody) -> bool:
	var reach: float = body.tuck + landing_reach
	var below: float = body.legroom(reach)
	return below < reach and below >= body.tuck - landing_reach
