extends LocomotionModule

## Running is pumping the arms. With both grips closed and the stick pushed,
## how hard the hands swing up and down sets how much faster than a walk the
## body goes: a throttle, not a switch, so a jog and a sprint feel like what
## the arms are doing. Hand heights are read in the rig's own space, so the
## rig being carried is not mistaken for a swing.

@export var grip_action := &"grip"
## How far each grip must be squeezed for the hand to count as a fist.
@export_range(0.0, 1.0, 0.01) var grip_threshold := 0.7
## Speed along the ground at full stick and a full pump.
@export_range(0.5, 10.0, 0.1, "suffix:m/s") var run_speed := 6.0
## Averaged vertical hand speed where running starts, and where it is full.
@export_range(0.0, 5.0, 0.05, "suffix:m/s") var pump_start := 0.6
@export_range(0.1, 10.0, 0.05, "suffix:m/s") var pump_full := 2.5
## How quickly the measured pump follows the arms.
@export_range(0.1, 20.0, 0.1, "suffix:1/s") var smoothing := 4.0

var _pump := 0.0
var _left_height := 0.0
var _right_height := 0.0


func contribute(frame: LocomotionFrame, delta: float) -> void:
	_measure(delta)
	# Only a moving body runs: pumping the arms while standing is exercise.
	frame.run_factor = 0.0 if frame.wish.is_zero_approx() \
			else clampf(inverse_lerp(pump_start, pump_full, _pump), 0.0, 1.0)
	frame.top_speed = lerpf(frame.top_speed, run_speed, frame.run_factor)


func _measure(delta: float) -> void:
	var left := rig.left_controller.position.y
	var right := rig.right_controller.position.y
	var speed := 0.0
	if _fists_closed():
		speed = (absf(left - _left_height) + absf(right - _right_height)) * 0.5 / delta
	_left_height = left
	_right_height = right
	_pump = lerpf(_pump, speed, 1.0 - exp(-smoothing * delta))


func _fists_closed() -> bool:
	return rig.left_controller.get_float(grip_action) >= grip_threshold \
			and rig.right_controller.get_float(grip_action) >= grip_threshold
