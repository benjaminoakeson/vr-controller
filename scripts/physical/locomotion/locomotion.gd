class_name Locomotion
extends Node

## Plans each tick's movement from its modules, which are its children, in
## scene order. Each module reads and adds to the shared frame. A module that
## claims the tick ends the chain. Modules never move the body or the rig:
## the body applies the frame, and only the rig carrier moves the rig.

var frame := LocomotionFrame.new()

var _modules: Array[LocomotionModule] = []


func attach(rig: PlayerRig, physical: DynamicPhysical) -> void:
	_modules.clear()
	for child in get_children():
		var module := child as LocomotionModule
		if module != null:
			module.attach(rig, physical)
			_modules.append(module)


func plan(delta: float) -> LocomotionFrame:
	frame.reset()
	for module in _modules:
		module.contribute(frame, delta)
		if frame.exclusive:
			break
	return frame
