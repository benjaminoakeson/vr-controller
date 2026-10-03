"""Exports the player's character model, Body1_Fit on Body1_Fit_Rig, from craftables.blend as a glTF binary.

Run from the repository root, after tools/blender/fit_player_proportions.py has made the fitted copy
and craftables.blend has been saved:
    blender -b --factory-startup <path>/craftables.blend \
        --python tools/blender/export_player.py

Writes assets/models/player/body1.glb. The body is modelled at life size, so nothing is scaled; the
rig is exported where it would stand at the origin, wherever it sits in the file (the fitted copy
stands beside the original). Its Subdivision modifier is applied at level 1, about 36k triangles,
and its faces stay flat-shaded as modelled. Blender's -Y, the way the body faces, becomes +Z in
Godot. The .blend file is not modified.
"""

import os

import bpy
from mathutils import Matrix

RIG = "Body1_Fit_Rig"
BODY = "Body1_Fit"
SUBDIVISION_LEVEL = 1
OUT_PATH = os.path.join(os.getcwd(), "assets", "models", "player", "body1.glb")

# In an open session the in-memory edits below (the rig's placement, the subdivision level,
# back-face culling on materials the original Body1 shares) could be saved into the file.
if not bpy.app.background:
    raise SystemExit("Run headless from the repository root: blender -b --factory-startup "
                     "<craftables.blend> --python tools/blender/export_player.py")

rig = bpy.data.objects[RIG]
body = bpy.data.objects[BODY]
rig.matrix_world = Matrix.Identity(4)
for modifier in body.modifiers:
    if modifier.type == "SUBSURF":
        # The exporter applies modifiers at their viewport level.
        modifier.levels = SUBDIVISION_LEVEL
# The parts are closed with outward normals, so back faces need not be drawn, and the
# player's eyes sit inside the head without seeing its inside.
for material in body.data.materials:
    material.use_backface_culling = True

for other in bpy.context.view_layer.objects:
    other.select_set(False)
for exported in (rig, body):
    exported.hide_set(False)
    exported.select_set(True)
os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
bpy.ops.export_scene.gltf(
    filepath=OUT_PATH,
    export_format="GLB",
    use_selection=True,
    export_yup=True,
    export_apply=True,
    export_skins=True,
    export_materials="EXPORT",
    export_animations=False,
)
