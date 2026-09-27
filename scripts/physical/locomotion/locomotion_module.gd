class_name LocomotionModule
extends Node

## One part of locomotion. Each tick it reads the shared frame and adds its
## part; it never moves the body or the rig itself.

var rig: PlayerRig
var physical: DynamicPhysical


func attach(p_rig: PlayerRig, p_physical: DynamicPhysical) -> void:
	rig = p_rig
	physical = p_physical


## Adds this module's part of the tick's plan to `frame`.
func contribute(_frame: LocomotionFrame, _delta: float) -> void:
	pass
