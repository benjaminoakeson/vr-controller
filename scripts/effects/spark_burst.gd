class_name SparkBurst
extends MultiMeshInstance3D

## One burst of sparks from a strike (2026-10-05), drawn entirely by its
## material's shader (assets/effects/sparks/sparks.gdshader): the sparks fly
## closed-form paths from the struck point, so nothing simulates; this node only
## places the burst, hands the shader its settings, and tells it how old the
## burst is. Hidden, and processing nothing, between bursts.
##
## It stands in world space (top_level), so the bodies that struck moving on do
## not carry the sparks along. It is drawn without physics interpolation: it is
## placed during a physics tick, and interpolated it would slide over from where
## its last burst was.

## The material's spark-life range (s); the burst hides after its longest. The
## material sets it, so it reads the same here without a renderer.
const _LIFE := &"life"

var _age := 0.0
var _duration := 0.0


func _ready() -> void:
	top_level = true
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	var material := material_override as ShaderMaterial
	var life: Variant = material.get_shader_parameter(_LIFE) if material != null else null
	if life is Vector2:
		_duration = life.y
	else:
		push_error("SparkBurst: its material must set the sparks' life.")
	_hide()


## Throws `count` sparks from `point` (world space): mainly along `direction`
## (unit), within `spread` of it (half-angle, radians), at a mean `speed` (m/s),
## bouncing off a surface with `normal` (unit, out of the struck body). Cuts
## short any burst still showing.
func fire(point: Vector3, direction: Vector3, normal: Vector3, spread: float, speed: float,
		count: int) -> void:
	global_transform = Transform3D(Basis.IDENTITY, point)
	_age = 0.0
	set_instance_shader_parameter(&"age", _age)
	set_instance_shader_parameter(&"seed", float(randi() % 16777216))
	set_instance_shader_parameter(&"direction", direction)
	set_instance_shader_parameter(&"surface_normal", normal)
	set_instance_shader_parameter(&"spread", spread)
	set_instance_shader_parameter(&"speed", speed)
	set_instance_shader_parameter(&"count", float(count))
	visible = true
	set_process(true)


func _process(delta: float) -> void:
	_age += delta
	if _age >= _duration:
		_hide()
		return
	set_instance_shader_parameter(&"age", _age)


func _hide() -> void:
	visible = false
	set_process(false)
