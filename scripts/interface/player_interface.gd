class_name PlayerInterface
extends Node3D

## The GUI layer: displays and controls anchored to the body, and feedback to
## the player. So far: the view fade, the comfort half of the head-in-wall
## policy, the hands' contact haptics, and B showing the debug drawings.

@export var view_fade: ViewFade
@export var hand_haptics: HandHaptics
@export var skeleton_toggle: SkeletonToggle


func attach(rig: PlayerRig, physical: PlayerPhysical, physical_view: Node3D = null) -> void:
	view_fade.attach(rig.head, physical)
	if hand_haptics != null:
		hand_haptics.attach(rig, physical)
	if skeleton_toggle != null:
		skeleton_toggle.attach(rig, physical_view)
