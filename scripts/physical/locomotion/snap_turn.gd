class_name SnapTurn
extends LocomotionModule

## Snap turning (2026-09-30, decided with the player: snap only for now, 45°).
## The right stick pushed left or right turns the view that way by
## snap_angle in one tick, about the vertical through the head's centre, which
## the body stands under (RigCarrier.turn). One turn per push: the stick has
## to come back near the middle before it turns again. Never a torque on the
## body: the rig carrier turns the rig, and DynamicPhysical turns what keeps a
## place in the world for the player (the hands and what they hold, the
## skeleton's feet).

@export var turn_action := &"primary"
## How far one push turns the view.
@export_range(1.0, 180.0, 1.0, "radians_as_degrees") var snap_angle := deg_to_rad(45.0)
## Pushed sideways past this share of its throw, the stick turns...
@export_range(0.1, 1.0, 0.01) var press_threshold := 0.7
## ...and back inside this, it may turn again.
@export_range(0.0, 0.9, 0.01) var release_threshold := 0.3

var _armed := true


func contribute(frame: LocomotionFrame, _delta: float) -> void:
	var sideways := rig.right_controller.get_vector2(turn_action).x
	if absf(sideways) < release_threshold:
		_armed = true
	elif _armed and absf(sideways) >= press_threshold:
		_armed = false
		# Right turns the view clockwise seen from above: negative about up.
		frame.turn = -signf(sideways) * snap_angle
