extends LocomotionModule

## The left stick walks the body the way the head is looking. It sets the
## direction and the walking speed; the arm-pump run may raise the speed.
## Climbing (a hand on a hold), the stick does nothing: the hands move the body.

@export var move_action := &"primary"
## The share of the stick's throw that is ignored.
@export_range(0.0, 0.9, 0.01) var stick_deadzone := 0.15
## Speed along the ground at full stick.
@export_range(0.1, 5.0, 0.05, "suffix:m/s") var walk_speed := 1.5

## How steeply the head may pitch, as the vertical share of its forward, before
## its up axis stands in for a forward too steep to flatten (about 49°).
const ELEVATION_LIMIT := 0.75


func contribute(frame: LocomotionFrame, _delta: float) -> void:
	frame.top_speed = walk_speed
	frame.wish = Vector3.ZERO if physical.climbing() else _wish_direction()


## The stick as a direction over the ground, in the headset's facing.
func _wish_direction() -> Vector3:
	var stick := rig.left_controller.get_vector2(move_action)
	var throw := stick.length()
	if throw < stick_deadzone:
		return Vector3.ZERO
	stick = stick / throw * inverse_lerp(stick_deadzone, 1.0, minf(throw, 1.0))
	var basis := rig.head.global_basis
	var forward := -basis.z
	if absf(forward.y) > ELEVATION_LIMIT:
		forward = basis.y * -signf(forward.y)
	forward = forward.slide(Vector3.UP).normalized()
	var right := forward.cross(Vector3.UP)
	return forward * stick.y + right * stick.x
