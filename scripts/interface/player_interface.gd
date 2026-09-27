class_name PlayerInterface
extends Node3D

## The GUI layer: displays and controls anchored to the body, and feedback to
## the player. So far: the view fade, the comfort half of the head-in-wall
## policy, and the hands' contact haptics.

@export var view_fade: ViewFade
@export var hand_haptics: HandHaptics


func attach(rig: PlayerRig, physical: PlayerPhysical) -> void:
	view_fade.attach(rig.head, physical)
	if hand_haptics != null:
		hand_haptics.attach(rig, physical)
