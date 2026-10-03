"""Exports the weapons and tools, the ore and wood items, the furnace and its bellows from craftables.blend as glTF binaries.

Run from the repository root:
    blender -b --factory-startup <path>/craftables.blend \
        --python tools/blender/export_weapons.py [-- Name ...]

Names after "--" export only those weapons.

craftables.blend is modelled at ten times life size (its sword is 6.8 units
long), so each weapon is scaled by 0.1 to metres with its object transform
applied. The origin stays where it is in Blender: inside the grip for the
blades, at the centre of the head for the pickaxe and axe, at the middle of the ore and wood items,
at the middle of the base for the furnace (its mouth faces +Z in Godot, its bellows port +X).
The bellows is an empty over its parts (base, lid, bag): each part becomes its own node at its own
origin (the lid's is its hinge) under a root at the empty's origin, beside the nozzle. Its offset
from the furnace's origin in the file is where it fits the port: 0.6651 m along +X, 0.2549 m up.
Blender's +Z, along the blade (and the log and stick), becomes +Y in Godot. The .blend file is not
modified.
"""

import os
import sys

import bpy
from mathutils import Matrix, Vector

# Blender object name -> file written under assets/models/.
WEAPONS = {"Dagger": "weapons/dagger.glb", "Sword": "weapons/sword.glb", "LongSword": "weapons/longsword.glb",
           "Pickaxe": "weapons/pickaxe.glb", "Axe": "weapons/axe.glb",
           "CopperOre": "ores/copper_ore.glb", "IronOre": "ores/iron_ore.glb", "GoldOre": "ores/gold_ore.glb",
           "SilverOre": "ores/silver_ore.glb", "CobaltOre": "ores/cobalt_ore.glb",
           "Log": "wood/log.glb", "Stick": "wood/stick.glb", "Furnace": "props/furnace.glb",
           "Bellows": "props/bellows.glb"}
SCALE = 0.1
OUT_DIR = os.path.join(os.getcwd(), "assets", "models")

# In an open session the in-memory edits below (renames, back-face culling on
# materials the other craftables share) could be saved into the file.
if not bpy.app.background:
    raise SystemExit("Run headless from the repository root: blender -b --factory-startup "
                     "<craftables.blend> --python tools/blender/export_weapons.py")


def applied_copy(source: bpy.types.Object, name: str, origin: Vector) -> bpy.types.Object:
    """A copy of a mesh object in metres, placed at its origin's offset from origin."""
    weapon = source.copy()
    weapon.data = source.data.copy()
    weapon.name = name
    weapon.data.name = name
    weapon.parent = None
    weapon.matrix_parent_inverse = Matrix.Identity(4)
    bpy.context.scene.collection.objects.link(weapon)
    # Rotation and scale are applied, to the shape keys too (the bellows' bag has a Closed key);
    # the position is not, so each model keeps its own origin wherever the object sits in the
    # file (the ore items lie in a row).
    placement = source.matrix_world.copy()
    placement.translation = (0.0, 0.0, 0.0)
    weapon.data.transform(Matrix.Scale(SCALE, 4) @ placement, shape_keys=True)
    weapon.matrix_world = Matrix.Translation((source.matrix_world.translation - origin) * SCALE)
    # The meshes are closed with outward normals, so back faces need not be
    # drawn (Blender's default exports them double-sided).
    for material in weapon.data.materials:
        material.use_backface_culling = True
    return weapon


def export(name: str, file_name: str) -> None:
    source = bpy.data.objects[name]
    parts = [source] if source.type == "MESH" else [child for child in source.children if child.type == "MESH"]
    original_names = {obj: obj.name for obj in [source, *parts]}
    for obj in original_names:
        obj.name += "_source"
    origin = source.matrix_world.translation.copy()
    exported = [applied_copy(part, original_names[part], origin) for part in parts]
    if source.type != "MESH":
        root = bpy.data.objects.new(name, None)
        bpy.context.scene.collection.objects.link(root)
        for part in exported:
            part.parent = root
        exported.append(root)

    for other in bpy.context.view_layer.objects:
        other.select_set(False)
    for weapon in exported:
        weapon.hide_set(False)
        weapon.select_set(True)
    path = os.path.join(OUT_DIR, file_name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.ops.export_scene.gltf(
        filepath=path,
        export_format="GLB",
        use_selection=True,
        export_yup=True,
        export_apply=True,
        export_materials="EXPORT",
        export_animations=False,
    )
    for weapon in exported:
        bpy.data.objects.remove(weapon)
    for obj, original_name in original_names.items():
        obj.name = original_name


os.makedirs(OUT_DIR, exist_ok=True)
names = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else list(WEAPONS)
for weapon_name in names:
    export(weapon_name, WEAPONS[weapon_name])
