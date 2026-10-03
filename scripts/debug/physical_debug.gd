class_name PhysicalDebug
extends Node3D

## Shows the physical layer: the body's collision capsule, faint; each palm's
## box, white when the drive is relaxed and red when it pushes at full
## strength; each finger bone as a capsule; the body parts (torso, limbs,
## head) in their own shapes, blue; and each hand's grab: a dot at the hand's
## grab point and one at the object's, joined by a line, yellow for a
## candidate, orange while pulling it in and green while holding it.
## The player shows it in every run, from its Visual slot, until the character
## model takes that slot (2026-09-27). It reads the physical layer's snapshot
## and writes nothing back.

const RELAXED := Color(1.0, 1.0, 1.0, 0.6)
const STRAINED := Color(1.0, 0.1, 0.05, 0.8)
const BODY_PART := Color(0.35, 0.6, 1.0, 0.35)
## Faint: the capsule encloses the body parts. Its axis stands under the
## head's centre, 10 cm behind the eyes, so the eyes sit about 2 cm above its
## rounded top: looking down, a thin band of it shows 5 to 8 cm away.
const BODY := Color(0.85, 0.9, 1.0, 0.12)
const GRAB_COLOURS: Array[Color] = [Color(1.0, 0.9, 0.1), Color(1.0, 0.55, 0.1), Color(0.2, 1.0, 0.3)]

var _physical: PlayerPhysical
var _body: MeshInstance3D
var _body_mesh := CapsuleMesh.new()
var _palms: Array[MeshInstance3D] = []
var _materials: Array[StandardMaterial3D] = []
var _box := BoxMesh.new()
var _bones: Array[MeshInstance3D] = []
var _bone_material := StandardMaterial3D.new()
var _parts: Array[MeshInstance3D] = []
var _part_material := StandardMaterial3D.new()
var _grab_dots: Array[MeshInstance3D] = []
var _grab_materials: Array[StandardMaterial3D] = []
var _grab_lines := ImmediateMesh.new()
var _grab_line_material := StandardMaterial3D.new()


func attach(physical: PlayerPhysical) -> void:
	_physical = physical


func _ready() -> void:
	var body_material := StandardMaterial3D.new()
	body_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	body_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	body_material.albedo_color = BODY
	_body_mesh.radial_segments = 16
	_body_mesh.rings = 4
	_body = MeshInstance3D.new()
	_body.mesh = _body_mesh
	_body.material_override = body_material
	_body.top_level = true
	_body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_body)
	for i in 2:
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		var palm := MeshInstance3D.new()
		palm.mesh = _box
		palm.material_override = material
		palm.top_level = true
		palm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(palm)
		_palms.append(palm)
		_materials.append(material)
	_bone_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_bone_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_bone_material.albedo_color = RELAXED
	_part_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_part_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_part_material.albedo_color = BODY_PART
	# Per hand: the hand's grab point, then the object's.
	for i in 4:
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.no_depth_test = true
		material.albedo_color = RELAXED
		var dot_mesh := SphereMesh.new()
		dot_mesh.radius = 0.004 if i % 2 == 0 else 0.007
		dot_mesh.height = dot_mesh.radius * 2.0
		var dot := MeshInstance3D.new()
		dot.mesh = dot_mesh
		dot.material_override = material
		dot.top_level = true
		dot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(dot)
		_grab_dots.append(dot)
		_grab_materials.append(material)
	_grab_line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_grab_line_material.no_depth_test = true
	_grab_line_material.vertex_color_use_as_albedo = true
	var lines := MeshInstance3D.new()
	lines.mesh = _grab_lines
	lines.material_override = _grab_line_material
	lines.top_level = true
	lines.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(lines)


func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	var state := _physical.snapshot
	_show_body(state)
	var visible_hands := state.hand_strength > 0.0
	if visible_hands and not _box.size.is_equal_approx(state.palm_size):
		_box.size = state.palm_size
	for i in 2:
		_palms[i].visible = visible_hands
		if visible_hands:
			_palms[i].global_transform = state.hands[i].translated_local(Vector3(0.0, 0.0, -state.palm_shift))
			_materials[i].albedo_color = RELAXED.lerp(STRAINED,
					clampf(state.hand_force[i] / state.hand_strength, 0.0, 1.0))
	_show_fingers(state)
	_show_body_parts(state)
	_show_grabs(state)


## The body's collision capsule: its feet at the body's position (its bottom
## above them by the legs' tuck), resized only when the capsule is.
func _show_body(state: PoseSnapshot) -> void:
	_body.visible = state.body_radius > 0.0
	if not _body.visible:
		return
	var length := state.body_height - state.body_tuck
	if not is_equal_approx(_body_mesh.radius, state.body_radius) \
			or not is_equal_approx(_body_mesh.height, length):
		_body_mesh.radius = state.body_radius
		_body_mesh.height = length
	_body.global_transform = Transform3D(Basis.IDENTITY,
			state.body_position + Vector3.UP * (state.body_tuck + length * 0.5))


## Each hand's grab point, its candidate's or held object's grab point, and a
## line between them, coloured by the grab's state.
func _show_grabs(state: PoseSnapshot) -> void:
	_grab_lines.clear_surfaces()
	var drawing := false
	for side in 2:
		var hand := state.grab_hand_points[side]
		var object := state.grab_object_points[side]
		var has_object := state.grab_state[side] != 0 or not object.is_equal_approx(hand)
		var colour := GRAB_COLOURS[state.grab_state[side]]
		_grab_dots[side * 2].visible = state.hand_strength > 0.0
		_grab_dots[side * 2].global_position = hand
		_grab_dots[side * 2 + 1].visible = has_object
		_grab_dots[side * 2 + 1].global_position = object
		_grab_materials[side * 2 + 1].albedo_color = colour
		if not has_object:
			continue
		if not drawing:
			_grab_lines.surface_begin(Mesh.PRIMITIVE_LINES)
			drawing = true
		_grab_lines.surface_set_color(colour)
		_grab_lines.surface_add_vertex(hand)
		_grab_lines.surface_set_color(colour)
		_grab_lines.surface_add_vertex(object)
	if drawing:
		_grab_lines.surface_end()


## One mesh per body part, rebuilt whenever its shape's size changes.
func _show_body_parts(state: PoseSnapshot) -> void:
	for i in state.body_part_shapes.size():
		if i >= _parts.size():
			var mesh_instance := MeshInstance3D.new()
			mesh_instance.material_override = _part_material
			mesh_instance.top_level = true
			mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(mesh_instance)
			_parts.append(mesh_instance)
		var shape := state.body_part_shapes[i]
		var part := _parts[i]
		part.visible = shape != null
		if shape == null:
			continue
		_fit_mesh(part, shape)
		part.global_transform = state.body_parts[i]


func _fit_mesh(part: MeshInstance3D, shape: Shape3D) -> void:
	if shape is CapsuleShape3D:
		var capsule := shape as CapsuleShape3D
		var mesh := part.mesh as CapsuleMesh
		if mesh == null:
			mesh = CapsuleMesh.new()
			mesh.radial_segments = 10
			mesh.rings = 3
			part.mesh = mesh
		if not is_equal_approx(mesh.radius, capsule.radius) or not is_equal_approx(mesh.height, capsule.height):
			mesh.radius = capsule.radius
			mesh.height = capsule.height
	elif shape is SphereShape3D:
		var sphere := shape as SphereShape3D
		if part.mesh == null:
			var mesh := SphereMesh.new()
			mesh.radius = sphere.radius
			mesh.height = sphere.radius * 2.0
			mesh.radial_segments = 12
			mesh.rings = 6
			part.mesh = mesh
	elif shape is BoxShape3D:
		if part.mesh == null:
			var mesh := BoxMesh.new()
			mesh.size = (shape as BoxShape3D).size
			part.mesh = mesh


## One capsule per finger bone, made once its size is known; the capsule mesh
## runs along its Y, so it is laid along the bone's -Z.
func _show_fingers(state: PoseSnapshot) -> void:
	for i in state.finger_sizes.size():
		var size := state.finger_sizes[i]
		if i >= _bones.size():
			var capsule := MeshInstance3D.new()
			capsule.material_override = _bone_material
			capsule.top_level = true
			capsule.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(capsule)
			_bones.append(capsule)
		var bone := _bones[i]
		bone.visible = size.x > 0.0
		if not bone.visible:
			continue
		if bone.mesh == null:
			var mesh := CapsuleMesh.new()
			mesh.radius = size.x
			mesh.height = maxf(size.y, size.x * 2.0)
			mesh.radial_segments = 8
			mesh.rings = 2
			bone.mesh = mesh
		bone.global_transform = state.finger_bones[i] \
				* Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(0.0, 0.0, -size.y * 0.5))
