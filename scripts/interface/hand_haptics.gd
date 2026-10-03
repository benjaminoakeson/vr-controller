class_name HandHaptics
extends Node

## A short buzz in a controller when its physical hand starts touching
## something, stronger for a faster touch, so contact can be felt as well as
## seen; and when something the hand holds strikes (the strike model), stronger
## for a harder strike. It reads the physical layer's events and writes nothing
## back.

## The buzz of the gentlest touch, and the hand speed that gives a full buzz.
@export_range(0.0, 1.0, 0.05) var min_amplitude := 0.15
@export_range(0.1, 10.0, 0.1, "suffix:m/s") var full_speed := 2.0
@export_range(0.01, 0.5, 0.01, "suffix:s") var duration := 0.05

@export_group("Strikes")
## The strike energy that gives a full buzz in a hand holding the striker.
## Weaker strikes buzz with the square root of their share, so the buzz grows
## with the blow's speed, as a touch's does (never below min_amplitude).
@export_range(1.0, 500.0, 1.0, "suffix:J") var full_strike_energy := 100.0
@export_range(0.01, 0.5, 0.01, "suffix:s") var strike_duration := 0.06

## Strike buzzes so far, per hand (left, right), for checks.
var strike_pulses := PackedInt32Array([0, 0])

var _controllers: Array[XRController3D] = []


func attach(rig: PlayerRig, physical: PlayerPhysical) -> void:
	_controllers = [rig.left_controller, rig.right_controller]
	physical.hand_contact.connect(_on_hand_contact)
	physical.hand_strike.connect(_on_hand_strike)


func _on_hand_contact(side: int, speed: float) -> void:
	var amplitude := clampf(speed / full_speed, min_amplitude, 1.0)
	_controllers[side].trigger_haptic_pulse(&"haptic", 0.0, amplitude, duration, 0.0)


# Only what the hand holds: the hand's own strikes already buzz as touches, and
# something it let go of is not in its grip.
func _on_hand_strike(side: int, strike: Strike, source: int) -> void:
	if source != HandStrikes.Source.HELD:
		return
	var amplitude := clampf(sqrt(strike.energy / full_strike_energy), min_amplitude, 1.0)
	_controllers[side].trigger_haptic_pulse(&"haptic", 0.0, amplitude, strike_duration, 0.0)
	strike_pulses[side] += 1
