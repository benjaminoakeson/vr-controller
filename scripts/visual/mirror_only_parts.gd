class_name MirrorOnlyParts
extends Node

## Shows the character model's head and neck in reflections only. The player's
## eyes sit inside the head, so in first person it would only ever show as
## pieces at the edge of the view; in the mirror it looks as modelled.
##
## The model is one skinned mesh whose parts are separate surfaces. When it
## loads, the surfaces skinned only to `bones` move to a copy of the model's
## mesh instance on RenderLayers.MIRROR_ONLY, which the player's camera does
## not draw and the mirror's cameras do. The copy keeps the model's skin and
## skeleton, so PoseMapper poses both alike, and it hides with the model.

## The model's mesh instance.
@export var model_mesh: MeshInstance3D
## The bones whose parts only reflections show: the head with its eyes, and the neck.
@export var bones: PackedStringArray = ["Head", "LeftEye", "RightEye", "Neck"]

## The copy drawing the parts only reflections show, once the model has loaded.
var mirror_only_mesh: MeshInstance3D


func _ready() -> void:
	if model_mesh == null or not model_mesh.mesh is ArrayMesh or model_mesh.skin == null:
		push_error("MirrorOnlyParts: model_mesh must be a skinned ArrayMesh instance.")
		return
	var mesh := model_mesh.mesh as ArrayMesh
	var binds := _binds_on_bones(model_mesh.skin)
	var mirror_only := PackedInt32Array()
	for surface in mesh.get_surface_count():
		if _skinned_only_to(mesh, surface, binds):
			mirror_only.append(surface)
	if mirror_only.is_empty():
		push_error("MirrorOnlyParts: no part of the model is skinned only to %s." % ", ".join(bones))
		return

	# Copies of the whole mesh, each with the other's surfaces removed, keep
	# every surface's materials and levels of detail.
	var body := mesh.duplicate() as ArrayMesh
	var reflected := mesh.duplicate() as ArrayMesh
	for surface in range(mesh.get_surface_count() - 1, -1, -1):
		if surface in mirror_only:
			body.surface_remove(surface)
		else:
			reflected.surface_remove(surface)
	mirror_only_mesh = model_mesh.duplicate() as MeshInstance3D
	mirror_only_mesh.name = String(model_mesh.name) + "MirrorOnly"
	mirror_only_mesh.mesh = reflected
	mirror_only_mesh.layers = RenderLayers.mask(RenderLayers.MIRROR_ONLY)
	model_mesh.mesh = body
	model_mesh.add_sibling(mirror_only_mesh)


## The skin's binds (the bone indices its vertices carry) on one of `bones`.
func _binds_on_bones(skin: Skin) -> PackedInt32Array:
	var binds := PackedInt32Array()
	for bind in skin.get_bind_count():
		if String(skin.get_bind_name(bind)) in bones:
			binds.append(bind)
	return binds


static func _skinned_only_to(mesh: ArrayMesh, surface: int, binds: PackedInt32Array) -> bool:
	var arrays := mesh.surface_get_arrays(surface)
	var bone_indices: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	if bone_indices.is_empty():
		return false
	for i in bone_indices.size():
		if weights[i] > 0.0 and not binds.has(bone_indices[i]):
			return false
	return true
