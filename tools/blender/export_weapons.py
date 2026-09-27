"""Exports the dagger and sword from craftables.blend as glTF binaries for Godot.

Run from the repository root:
    blender -b --factory-startup <path>/craftables.blend \
        --python tools/blender/export_weapons.py

craftables.blend is modelled at ten times life size (its sword is 6.8 units
long), so each weapon is scaled by 0.1 to metres with its object transform
applied. The origin stays where it is in Blender, inside the grip. Blender's
+Z, along the blade, becomes +Y in Godot. The .blend file is not modified.
"""

import os

import bpy
from mathutils import Matrix

# Blender object name -> file written to assets/models/weapons/.
WEAPONS = {"Dagger": "dagger.glb", "Sword": "sword.glb"}
SCALE = 0.1
OUT_DIR = os.path.join(os.getcwd(), "assets", "models", "weapons")

# In an open session the in-memory edits below (renames, back-face culling on
# materials the other craftables share) could be saved into the file.
if not bpy.app.background:
    raise SystemExit("Run headless from the repository root: blender -b --factory-startup "
                     "<craftables.blend> --python tools/blender/export_weapons.py")


def export(name: str, file_name: str) -> None:
    source = bpy.data.objects[name]
    source.name = name + "_source"
    weapon = source.copy()
    weapon.data = source.data.copy()
    weapon.name = name
    weapon.data.name = name
    bpy.context.scene.collection.objects.link(weapon)
    weapon.data.transform(Matrix.Scale(SCALE, 4) @ source.matrix_world)
    weapon.matrix_world = Matrix.Identity(4)
    # The meshes are closed with outward normals, so back faces need not be
    # drawn (Blender's default exports them double-sided).
    for material in weapon.data.materials:
        material.use_backface_culling = True

    for other in bpy.context.view_layer.objects:
        other.select_set(False)
    weapon.hide_set(False)
    weapon.select_set(True)
    bpy.ops.export_scene.gltf(
        filepath=os.path.join(OUT_DIR, file_name),
        export_format="GLB",
        use_selection=True,
        export_yup=True,
        export_apply=True,
        export_materials="EXPORT",
        export_animations=False,
    )
    bpy.data.objects.remove(weapon)
    source.name = name


os.makedirs(OUT_DIR, exist_ok=True)
for weapon_name, weapon_file in WEAPONS.items():
    export(weapon_name, weapon_file)
