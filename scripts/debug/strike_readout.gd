class_name StrikeReadout
extends Label3D

## Shows the strikes a struck body takes (the strike model), for tuning in the
## headset. It lists the body's material and its damage so far, in all and by
## type, and the last strike's striker (and the sharp feature that dealt it), its
## type, energy, closing speed, the mass it met and the damage it did. For a
## moment it also puts a dot where the strike landed. It changes nothing.

const KIND_NAMES: Array[String] = ["Blunt", "Slash"]

@export var strikeable: Strikeable
## How long the dot stays, fading, in seconds.
@export_range(0.1, 5.0, 0.1, "suffix:s") var marker_time := 1.0
@export_range(0.002, 0.05, 0.001, "suffix:m") var marker_radius := 0.015

var _marker: MeshInstance3D
var _marker_material: StandardMaterial3D
var _shown := 0.0


func _ready() -> void:
	set_process(false)
	if strikeable == null:
		push_error("StrikeReadout: no strikeable is assigned.")
		return
	_marker_material = StandardMaterial3D.new()
	_marker_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_marker_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_marker_material.albedo_color = Color(1.0, 0.45, 0.1)
	var sphere := SphereMesh.new()
	sphere.radius = marker_radius
	sphere.height = marker_radius * 2.0
	sphere.radial_segments = 12
	sphere.rings = 6
	sphere.material = _marker_material
	_marker = MeshInstance3D.new()
	_marker.mesh = sphere
	_marker.top_level = true
	_marker.visible = false
	add_child(_marker)
	strikeable.struck.connect(_on_struck)
	text = _title()


func _process(delta: float) -> void:
	_shown -= delta
	if _shown <= 0.0:
		_marker.visible = false
		set_process(false)
		return
	_marker_material.albedo_color.a = _shown / marker_time


func _on_struck(strike: Strike) -> void:
	var outcome := "damage %d" % strike.damage if strike.damage > 0 \
			else "below %.1f J: no damage" % strikeable.material.threshold_of(strike.kind)
	var by := String(strike.striker.name)
	if strike.feature != null:
		by += " (%s)" % strike.feature.name
	text = "%s\n%s %s: %.1f J at %.1f m/s (%.2f kg)\n%s" % [_title(), by, KIND_NAMES[strike.kind],
			strike.energy, strike.speed, strike.effective_mass, outcome]
	# Moved during a physics tick: without the reset it would glide there.
	_marker.global_position = strike.point
	_marker.reset_physics_interpolation()
	_marker.visible = true
	_marker_material.albedo_color.a = 1.0
	_shown = marker_time
	set_process(true)


func _title() -> String:
	var material := strikeable.material
	var by := strikeable.damage_by_kind
	return "%s: damage %d in %d strikes\nslash %d, blunt %d" % [
			material.display_name if material != null else "?", strikeable.damage, strikeable.strikes,
			by[Strike.Kind.SLASH], by[Strike.Kind.BLUNT]]
