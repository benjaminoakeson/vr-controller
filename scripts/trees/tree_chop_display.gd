class_name TreeChopDisplay
extends Node3D

## Shows the segment line being chopped (TreeChop.current; chopping,
## 2026-10-02). On a trunk line: each side's opening as a number on the bark at
## that side, hidden by the trunk when behind it. On every line: how much is open
## against what cuts through it, "190 / 300", above the line in world up (so it
## reads on a lying log too), drawn over the wood so it reads from any side. It
## follows the line last struck, hides when there is none, and changes nothing.
##
## Once the tree is a lone piece (TreeChop.health), it shows that piece's health
## instead (a HealthDisplay, "50 / 50"), above the bark at its middle in world
## up, kept there as the piece moves.

@export var chop: TreeChop
## How far out from the bark the side numbers stand.
@export_range(0.0, 0.3, 0.01, "suffix:m") var side_offset_m := 0.04
## How far above the line's middle the total stands; a lone piece's health
## stands this far above its bark.
@export_range(0.0, 1.0, 0.01, "suffix:m") var total_height_m := 0.25

var _side_labels: Array[Label3D] = []
var _total: Label3D
var _health: HealthDisplay


func _ready() -> void:
	set_process(false)
	if chop == null:
		push_error("TreeChopDisplay: no chop is assigned.")
		return
	_total = _add_label(48)
	_total.no_depth_test = true
	hide()
	chop.changed.connect(_on_changed)


func _process(_delta: float) -> void:
	_health.global_position = chop.lone_centre() + Vector3.UP * (chop.lone_radius() + total_height_m)


func _on_changed(_line: TreeChop.Line) -> void:
	if chop.health != null:
		_show_health()
		return
	var line := chop.current
	visible = line != null
	if line == null:
		return
	# A number per side on a trunk line, none on a line of one side.
	var count := line.depths.size() if line.depths.size() > 1 else 0
	while _side_labels.size() > count:
		_side_labels.pop_back().queue_free()
	while _side_labels.size() < count:
		_side_labels.append(_add_label(32))
	# Placed again on every change: the line may be another one, or on a piece
	# that has moved since.
	var middle := chop.centre(line)
	var reach := chop.radius(line) + side_offset_m
	for side in count:
		_side_labels[side].global_position = middle + chop.side_direction(line, side) * reach
		_side_labels[side].text = str(line.depths[side])
	_total.global_position = middle + Vector3.UP * total_height_m
	_total.text = "%d / %d" % [line.open, line.total]


## The lone piece's health in place of the chop readout, placed every frame from
## now on.
func _show_health() -> void:
	visible = true
	_total.hide()
	for label in _side_labels:
		label.queue_free()
	_side_labels.clear()
	if _health == null:
		_health = HealthDisplay.new()
		_health.health = chop.health
		_health.pixel_size = 0.002
		_health.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_health.font_size = 48
		_health.outline_size = 12
		add_child(_health)
	set_process(true)
	_process(0.0)


func _add_label(size: int) -> Label3D:
	var label := Label3D.new()
	label.pixel_size = 0.002
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = size
	label.outline_size = 12
	add_child(label)
	return label
