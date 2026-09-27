class_name HandHaptics
extends Node

## A short buzz in a controller when its physical hand starts touching
## something, stronger for a faster touch, so contact can be felt as well as
## seen. It reads the physical layer's contact events and writes nothing back.

## The buzz of the gentlest touch, and the hand speed that gives a full buzz.
@export_range(0.0, 1.0, 0.05) var min_amplitude := 0.15
@export_range(0.1, 10.0, 0.1, "suffix:m/s") var full_speed := 2.0
@export_range(0.01, 0.5, 0.01, "suffix:s") var duration := 0.05

var _controllers: Array[XRController3D] = []


func attach(rig: PlayerRig, physical: PlayerPhysical) -> void:
	_controllers = [rig.left_controller, rig.right_controller]
	physical.hand_contact.connect(_on_hand_contact)


func _on_hand_contact(side: int, speed: float) -> void:
	var amplitude := clampf(speed / full_speed, min_amplitude, 1.0)
	_controllers[side].trigger_haptic_pulse(&"haptic", 0.0, amplitude, duration, 0.0)
