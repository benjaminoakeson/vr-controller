@tool
class_name TreeImpostors
extends RefCounted

## Pictures of a species' variants for drawing distant trees as cards
## (tree_impostor.gdshader), made once per species when a level first needs
## them and shared by every forest.
##
## Each variant's far-level mesh (what the card replaces, so the handoff keeps
## its look) is rendered from the side (looking along -Z)
## with an orthographic camera in an offscreen viewport, twice: its colour
## unlit, and its world-space normals, so the card can be lit like the real
## tree. All variants are rendered in the same frame. The pictures go into two
## texture arrays, one layer per variant, all framed on the same square so one
## card size fits the species.
##
## Needs a renderer: without one (headless), nothing is baked and trees keep
## their own far level.
##
## Tool script, so its static state is set up in the editor too.

## A species' pictures.
class Baked:
	var color: Texture2DArray
	var normal: Texture2DArray
	## Side of the square each picture shows, in metres.
	var card_size := 0.0


## Species to Baked.
static var _baked := {}
## Species being baked now.
static var _baking := {}


static func can_bake() -> bool:
	return DisplayServer.get_name() != "headless"


## A species' pictures, or null before they are baked.
static func baked(species: TreeSpecies) -> Baked:
	return _baked.get(species)


## Drops a species' pictures, after its settings were edited.
static func forget(species: TreeSpecies) -> void:
	_baked.erase(species)


## The fade an impostor card uses: in over the band around the species'
## impostor distance, the band its trees' far levels fade out over.
static func fade_for(species: TreeSpecies) -> Vector4:
	var handoff := species.lod_changes(true).z
	var band := species.lod_fade_band_m
	return Vector4(handoff - band * 0.5, handoff + band * 0.5, 0.0, 0.0)


## Bakes a species' pictures, if they aren't already, using `host` to hold the
## offscreen viewports for the frame it takes. Returns them, or null if they
## can't be baked.
static func bake(species: TreeSpecies, host: Node) -> Baked:
	if _baked.has(species):
		return _baked[species]
	if not species.has_impostors() or not can_bake() or not host.is_inside_tree():
		return null
	while _baking.has(species):
		await host.get_tree().process_frame
	if _baked.has(species):
		return _baked[species]
	_baking[species] = true
	var built: Array[TreeCache.Entry] = []
	var frame := 0.0
	for variant in species.variants:
		var entry := TreeCache.fetch(species, variant)
		built.append(entry)
		frame = maxf(frame, maxf(entry.bounds.size.x, entry.bounds.size.y))
	# A little margin, so no leaf touches the edge and bleeds when filtered.
	frame *= 1.04
	var views: Array[SubViewport] = []
	for entry in built:
		for write_normal in [false, true]:
			var view := _picture_view(entry, frame, species.impostor_resolution, write_normal)
			host.add_child(view, false, Node.INTERNAL_MODE_BACK)
			views.append(view)
	# Drawn in the next frame; wait for two, in case this one was already drawing.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var colors: Array[Image] = []
	var normals: Array[Image] = []
	for i in views.size():
		var picture := views[i].get_texture().get_image()
		picture.convert(Image.FORMAT_RGBA8)
		# Transparent pixels take their neighbours' colour, so filtering and
		# mipmaps don't darken the edges.
		picture.fix_alpha_edges()
		picture.generate_mipmaps()
		(normals if i % 2 == 1 else colors).append(picture)
		views[i].queue_free()
	var result := Baked.new()
	result.color = Texture2DArray.new()
	result.color.create_from_images(colors)
	result.normal = Texture2DArray.new()
	result.normal.create_from_images(normals)
	result.card_size = frame
	_baked[species] = result
	_baking.erase(species)
	return result


## An offscreen viewport drawing one variant, framed on a square of side
## `frame` around its bounds, once.
static func _picture_view(entry: TreeCache.Entry, frame: float, resolution: int,
		write_normal: bool) -> SubViewport:
	var view := SubViewport.new()
	view.size = Vector2i(resolution, resolution)
	view.transparent_bg = true
	view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ONCE
	view.msaa_3d = Viewport.MSAA_DISABLED
	var centre := entry.bounds.get_center()
	var depth := entry.bounds.size.length()
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = frame
	camera.near = 0.05
	camera.far = depth * 2.0 + 1.0
	camera.position = centre + Vector3(0.0, 0.0, depth + 0.5)
	view.add_child(camera)
	var tree := MeshInstance3D.new()
	tree.mesh = entry.meshes[TreeMesher.Level.FAR]
	for surface in tree.mesh.get_surface_count():
		tree.set_surface_override_material(surface,
				_picture_material(tree.mesh.surface_get_material(surface), write_normal))
	view.add_child(tree)
	return view


## A material drawing a tree surface for its picture, from the material it is
## drawn with in the game.
static func _picture_material(source: Material, write_normal: bool) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = preload("res://assets/vegetation/trees/tree_impostor_bake.gdshader")
	material.set_shader_parameter(&"write_normal", write_normal)
	var shader_source := source as ShaderMaterial
	if shader_source == null:
		return material
	# Settings left at their shader's default read back as null.
	var parameters := {}
	for uniform: Dictionary in shader_source.shader.get_shader_uniform_list():
		var name := String(uniform["name"])
		parameters[name] = shader_source.get_shader_parameter(name)
	if parameters.has("bark_albedo"):
		material.set_shader_parameter("albedo_texture", parameters["bark_albedo"])
		if parameters["bark_tint"] != null:
			material.set_shader_parameter("tint", parameters["bark_tint"])
	elif parameters.has("albedo_texture"):
		material.set_shader_parameter("albedo_texture", parameters["albedo_texture"])
		if parameters["albedo_tint"] != null:
			material.set_shader_parameter("tint", parameters["albedo_tint"])
		var threshold: Variant = parameters.get("alpha_scissor_threshold")
		material.set_shader_parameter("alpha_scissor", threshold if threshold != null else 0.5)
	elif parameters.has("albedo_color"):
		var color: Variant = parameters["albedo_color"]
		material.set_shader_parameter("tint", color if color != null else Color(0.16, 0.3, 0.14))
	return material
