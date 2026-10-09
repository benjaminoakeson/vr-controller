class_name FuelDisplay
extends Label3D

## Shows how long a fuel has left to burn, above it, as "1:30" (2026-10-05),
## while a fire holds it (Fuel makes and shows it). Drawn over everything, so
## the flames and the wood never hide it, and kept above its body in world up
## as the body moves. It changes nothing; a readout for now.

@export var fuel: Fuel

# The whole seconds shown, so the text changes only when they do.
var _shown := -1


func _ready() -> void:
	if fuel == null:
		push_error("FuelDisplay: no fuel is assigned.")
		return
	billboard = BaseMaterial3D.BILLBOARD_ENABLED
	pixel_size = 0.002
	font_size = 48
	outline_size = 12
	no_depth_test = true
	top_level = true
	# Drawn where it is set, as the held bodies it follows are (Grabbable).
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	fuel.changed.connect(_on_changed)
	_on_changed(fuel.left)


func _process(_delta: float) -> void:
	global_position = fuel.middle() + Vector3.UP * fuel.readout_height


func _on_changed(left: float) -> void:
	var whole := ceili(left)
	if whole == _shown:
		return
	_shown = whole
	text = format(whole)


## `seconds` as minutes and seconds: 90 is "1:30".
static func format(seconds: int) -> String:
	@warning_ignore("integer_division")
	return "%d:%02d" % [seconds / 60, seconds % 60]
