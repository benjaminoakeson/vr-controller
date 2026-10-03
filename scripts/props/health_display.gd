class_name HealthDisplay
extends Label3D

## Shows an object's health above it (2026-10-02): what is left of the most, as
## "24 / 30". It updates only when the health changes, and changes nothing.

@export var health: Health


func _ready() -> void:
	if health == null:
		push_error("HealthDisplay: no health is assigned.")
		return
	health.changed.connect(_on_changed)
	_on_changed(health.current)


func _on_changed(current: int) -> void:
	text = "%d / %d" % [current, health.maximum]
