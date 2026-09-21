class_name PlanarMirror
extends Node3D

## A flat mirror that reflects what the viewer would see, in stereo.
##
## One camera per eye sits behind the mirror at that eye's position reflected
## through the mirror plane, and renders through an off-axis frustum that
## exactly covers the surface. The surface shows each eye its own image, so the
## reflection has real depth. Outside VR both cameras use the active camera's
## position. The mirror faces +Z and must not be scaled; change its size with
## the size property.

const DEFAULT_SIZE := Vector2(1.2, 2.0)
const DEFAULT_RESOLUTION_HEIGHT := 2560
const DEFAULT_FAR_DISTANCE := 50.0
const FRAME_BORDER := 0.05
const FRAME_DEPTH := 0.04
# Keeps the frame just behind the surface, where the reflection's near plane clips it.
const FRAME_GAP := 0.001
# The viewer must be at least this far in front for the reflection to render.
const MINIMUM_VIEW_DISTANCE := 0.01
# Runs after the XR camera has its pose for the frame.
const PROCESS_PRIORITY_AFTER_TRACKING := 1
const LEFT_VIEW := 0
const RIGHT_VIEW := 1
const STEREO_VIEW_COUNT := 2
const MIRROR_SHADER := preload("res://assets/materials/mirror/stereo_mirror.gdshader")

@export var size := DEFAULT_SIZE
@export var resolution_height := DEFAULT_RESOLUTION_HEIGHT
@export var far_distance := DEFAULT_FAR_DISTANCE

@onready var _surface: MeshInstance3D = $Surface
@onready var _frame: MeshInstance3D = $Frame
@onready var _left_viewport: SubViewport = $LeftEyeViewport
@onready var _right_viewport: SubViewport = $RightEyeViewport
@onready var _left_camera: Camera3D = $LeftEyeViewport/Camera
@onready var _right_camera: Camera3D = $RightEyeViewport/Camera


func _ready() -> void:
	process_priority = PROCESS_PRIORITY_AFTER_TRACKING
	_apply_size()
	# The surface sits on its own layer so the reflection cameras never draw it.
	_surface.layers = RenderLayers.mask(RenderLayers.MIRROR_SURFACE)
	_surface.material_override = _create_surface_material()
	var reflection_environment := _create_reflection_environment()
	for camera: Camera3D in [_left_camera, _right_camera]:
		camera.cull_mask &= ~_surface.layers
		camera.keep_aspect = Camera3D.KEEP_HEIGHT
		camera.environment = reflection_environment


func _process(_delta: float) -> void:
	var viewer := get_viewport().get_camera_3d()
	if viewer == null:
		return

	var xr_interface := XRServer.primary_interface
	if xr_interface != null and xr_interface.is_initialized() and xr_interface.get_view_count() == STEREO_VIEW_COUNT:
		update_reflection(
			xr_interface.get_transform_for_view(LEFT_VIEW, XRServer.world_origin).origin,
			xr_interface.get_transform_for_view(RIGHT_VIEW, XRServer.world_origin).origin
		)
	else:
		update_reflection(viewer.global_position, viewer.global_position)


## Places each eye's reflection camera for eyes at the given global positions.
## Returns false, and stops rendering, when the viewer is behind the mirror.
func update_reflection(left_eye_position: Vector3, right_eye_position: Vector3) -> bool:
	var world_to_mirror := global_transform.affine_inverse()
	var left_eye := world_to_mirror * left_eye_position
	var right_eye := world_to_mirror * right_eye_position
	var is_in_front := left_eye.z > MINIMUM_VIEW_DISTANCE and right_eye.z > MINIMUM_VIEW_DISTANCE
	var update_mode := SubViewport.UPDATE_ALWAYS if is_in_front else SubViewport.UPDATE_DISABLED
	_left_viewport.render_target_update_mode = update_mode
	_right_viewport.render_target_update_mode = update_mode
	if not is_in_front:
		return false

	_place_camera(_left_camera, left_eye)
	_place_camera(_right_camera, right_eye)
	return true


func _place_camera(camera: Camera3D, local_eye: Vector3) -> void:
	# Mirrored behind the plane, looking back through it toward the eye.
	var reflected_eye := Vector3(local_eye.x, local_eye.y, -local_eye.z)
	camera.global_transform = global_transform * Transform3D(Basis(Vector3.UP, PI), reflected_eye)
	# Off-axis frustum whose near plane is exactly the mirror surface.
	camera.set_frustum(size.y, Vector2(local_eye.x, -local_eye.y), local_eye.z, far_distance)


func _apply_size() -> void:
	(_surface.mesh as QuadMesh).size = size
	(_frame.mesh as BoxMesh).size = Vector3(size.x + FRAME_BORDER * 2.0, size.y + FRAME_BORDER * 2.0, FRAME_DEPTH)
	_frame.position = Vector3(0.0, 0.0, -(FRAME_DEPTH * 0.5 + FRAME_GAP))
	var viewport_size := Vector2i(roundi(resolution_height * size.x / size.y), resolution_height)
	_left_viewport.size = viewport_size
	_right_viewport.size = viewport_size


func _create_surface_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = MIRROR_SHADER
	material.set_shader_parameter(&"left_eye_reflection", _left_viewport.get_texture())
	material.set_shader_parameter(&"right_eye_reflection", _right_viewport.get_texture())
	return material


# A copy of the world's environment without glow. The player's camera already
# applies glow to the mirror surface, so glowing the reflection would double it.
func _create_reflection_environment() -> Environment:
	var world := get_world_3d()
	var world_environment := world.environment if world.environment != null else world.fallback_environment
	if world_environment == null:
		return null
	var reflection_environment := world_environment.duplicate() as Environment
	reflection_environment.glow_enabled = false
	return reflection_environment
