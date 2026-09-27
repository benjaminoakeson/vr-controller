extends LocomotionModule

## The right controller's A button jumps: one upward push, only while the
## ground is holding the body up. A press while in the air, or while recovery
## holds the body, is dropped rather than saved for later.

@export var jump_action := &"ax_button"
## How high a jump from flat ground rises, in metres.
@export_range(0.05, 2.0, 0.05, "suffix:m") var jump_height := 0.4

## Physics frame of the latest press, or -1.
var _pressed_on := -1


func attach(p_rig: PlayerRig, p_physical: DynamicPhysical) -> void:
	super(p_rig, p_physical)
	rig.right_controller.button_pressed.connect(_on_button_pressed)


func contribute(frame: LocomotionFrame, _delta: float) -> void:
	var fresh := _pressed_on >= 0 and Engine.get_physics_frames() - _pressed_on <= 1
	_pressed_on = -1
	if fresh and physical.ground.supported:
		frame.jump_speed = sqrt(2.0 * physical.body.get_gravity().length() * jump_height)


func _on_button_pressed(action: String) -> void:
	if action == jump_action:
		_pressed_on = Engine.get_physics_frames()
