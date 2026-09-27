extends LocomotionModule

## The capsule is as tall as the headset is high in the room, so crouching in
## the room crouches the body. The body keeps it above its minimum and grows
## it only into headroom.


func contribute(frame: LocomotionFrame, _delta: float) -> void:
	frame.target_height = rig.head.position.y
