class_name Locomotion
extends Node

## Plans each tick's movement from its modules, which are its children, in
## scene order. Each module reads and adds to the shared frame. A module that
## claims the tick ends the chain. Modules never move the body or the rig:
## the body applies the frame, and only the rig carrier moves the rig.

var frame := LocomotionFrame.new()

var _modules: Array[LocomotionModule] = []
var _physical: DynamicPhysical


func attach(rig: PlayerRig, physical: DynamicPhysical) -> void:
	_physical = physical
	_modules.clear()
	for child in get_children():
		var module := child as LocomotionModule
		if module != null:
			module.attach(rig, physical)
			_modules.append(module)


func plan(delta: float) -> LocomotionFrame:
	frame.reset()
	frame.strength = _physical.body.strength_share()
	for module in _modules:
		module.contribute(frame, delta)
		if frame.exclusive:
			break
	return frame
