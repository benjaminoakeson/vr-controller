class_name SkeletonToggle
extends Node

## Shows or hides the debug drawings over the character model each time the
## right controller's B button is pressed: the static skeleton's drawing and
## the physical layer's shapes, together. They start hidden, so the model is
## what the player sees (2026-10-02; from 2026-09-27 B hid only the static
## skeleton, over the physical shapes). Only the drawings are switched; the
## skeleton and the physical layer keep solving, and nothing else reads
## whether they are shown.

## The controller action that switches it, read from the right controller:
## B on Touch and Pico controllers.
@export var toggle_action := &"by_button"

var _views: Array[Node3D] = []


func attach(rig: PlayerRig, physical_view: Node3D = null) -> void:
	for view: Node3D in [rig.skeleton_view, physical_view]:
		if view != null:
			view.visible = false
			_views.append(view)
	rig.right_controller.button_pressed.connect(_on_button_pressed)


func _on_button_pressed(action: String) -> void:
	if action != toggle_action or _views.is_empty():
		return
	var shown := not _views[0].visible
	for view in _views:
		view.visible = shown
