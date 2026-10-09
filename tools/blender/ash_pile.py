"""Builds a small heap of ash, the size of a leaf litter cluster, for what a fire leaves behind.

Inside an open Blender session (Text Editor > Run Script) it rebuilds the `AshPile` object in the
Environment collection, beside the leaf litter. Headless, from the repository root, it writes the
game model instead:
    blender -b --factory-startup --python tools/blender/ash_pile.py -- --export [--seed N]

Modelled at real scale in metres and exported at 1.0, as the leaf litter is; Blender's +Z becomes +Y
in Godot. The origin is the heap's centre on the ground. It is one mesh with one material that takes
its colour from the `Col` attribute, so one draw call with no textures: a soft mound of grey ash,
pale on top and darker where it thins out over the ground, with a few blocks of charcoal half buried
in it. The mound is a single sheet seen from above, its rim sunk just below the ground so no edge
shows; the ash is smooth shaded and the charcoal flat. The same seed always gives the same heap.

In Godot the model's import settings swap in `ash.tres`, the ash shader (`ash.gdshader`), which
takes the colour from the vertex colours and adds grain and flecks to the ash and cracks to the
charcoal. The UVs tell them apart, u being 0 on ash and 1 on charcoal (Blender's glTF export drops
the colours' alpha unless a material uses it). Blender shows the colours only; they are linear, as
glTF stores them.
"""

import math
import os
import random
import sys

import bpy
import numpy as np

OUT_DIR = os.path.join(os.getcwd(), "assets", "models", "fire")
FILE = "ash_pile.glb"
# Where it sits in an open session: beside the leaf litter (x -1.4), clear of the player model.
VIEW_OFFSET = (-1.75, 0.0, 0.0)
MATERIAL_NAME = "ash_pile"
COLOUR_ATTRIBUTE = "Col"

ASH = {
    "name": "AshPile",
    "seed": 1,
    # The mound: as wide as a leaf litter cluster (0.22 m) and low, as fine ash slumps.
    "radius_m": 0.105,
    "outline": (0.06, 0.05, 0.035, 0.025, 0.02),  # how far the rim wanders in and out, in 2 to 6 waves round
    "height_m": 0.03,               # the mound's top above the ground, before its lumps
    "lumps": (2, 3),                # smaller heaps on it, where pieces burnt down
    "lump_height_m": (0.006, 0.012),
    "lump_width_m": (0.02, 0.035),
    "grain_m": 0.0012,              # the surface's roughness, fading out towards the rim
    "rim_sink_m": 0.002,            # the rim lies this far below the ground
    # (radius as a share of the rim's, points) for each ring round the centre: the points are
    # about as far apart as the rings, so the triangles are even and the centre shows no star.
    "rings": ((0.2, 6), (0.45, 12), (0.7, 16), (0.88, 18), (1.0, 18)),
    # Charcoal: blocks cracked off burnt wood, some as long as twig ends, partly buried.
    "charcoal": 6,
    "charcoal_size_m": ((0.012, 0.035), (0.008, 0.014), (0.006, 0.011)),  # length, width, height
    "charcoal_spread": 0.7,         # share of the rim's radius the pieces lie within
    "charcoal_bury": (0.4, 0.7),    # share of a piece's height under the ash
    "charcoal_jitter": 0.25,        # each corner wanders by up to this share of the piece's size
    "charcoal_tilt_deg": 20.0,      # most a piece leans off the mound's surface
    # sRGB colours: white-grey ash on top, grey on the slopes, dark where it thins over the ground.
    "ash_top": (0.64, 0.63, 0.60),
    "ash_middle": (0.50, 0.49, 0.47),
    "ash_rim": (0.30, 0.28, 0.26),
    "ash_mottle": 0.08,
    "charcoal_colour": (0.075, 0.07, 0.065),
    "charcoal_dust": 0.35,          # how far a piece's upward faces turn to the ash's grey
    "soot_m": 0.025,                # ash darkens within about this of a piece of charcoal
    "soot_strength": 0.3,
}

# A block's six faces as corner cycles; corner i is (x, y, z) = (i >> 2, i >> 1, i) & 1.
BOX_FACES = ((0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3))


def heap(rng: random.Random, p: dict):
    """The mound's rim radius as a function of angle, and its height above the ground as a function
    of x and y (arrays), lumps included."""
    phases = [rng.uniform(0.0, math.tau) for _ in p["outline"]]

    def rim(theta):
        waves = sum(a * np.cos((k + 2) * theta + f) for k, (a, f) in enumerate(zip(p["outline"], phases)))
        return p["radius_m"] * (1.0 + waves)

    lumps = []
    for _ in range(rng.randint(*p["lumps"])):
        angle, r = rng.uniform(0.0, math.tau), 0.55 * p["radius_m"] * math.sqrt(rng.random())
        lumps.append((r * math.cos(angle), r * math.sin(angle), rng.uniform(*p["lump_height_m"]),
                      rng.uniform(*p["lump_width_m"])))

    def height(x, y):
        s = np.hypot(x, y) / rim(np.arctan2(y, x))
        inside = np.clip(1.0 - s * s, 0.0, 1.0)
        h = p["height_m"] * inside ** 2
        for lx, ly, lh, lw in lumps:
            h = h + lh * np.exp(-((x - lx) ** 2 + (y - ly) ** 2) / lw ** 2) * inside
        return h

    return rim, height


def mound(rng: random.Random, p: dict, rim, height):
    """The ash as a sheet over rings round the centre: (Nx3 positions, triangles)."""
    xs, ys, shares = [0.0], [0.0], [0.0]
    triangles, inner = [], None
    for share, count in p["rings"]:
        start = rng.uniform(0.0, math.tau)
        angles = sorted((start + (k + rng.uniform(-0.15, 0.15)) * math.tau / count) % math.tau
                        for k in range(count))
        outer = [(len(xs) + k, theta) for k, theta in enumerate(angles)]
        for theta in angles:
            r = share * float(rim(theta))
            xs.append(r * math.cos(theta))
            ys.append(r * math.sin(theta))
            shares.append(share)
        if inner is None:
            triangles += [(0, outer[k][0], outer[(k + 1) % count][0]) for k in range(count)]
        else:
            triangles += zip_rings(inner, outer)
        inner = outer
    x, y, share = np.array(xs), np.array(ys), np.array(shares)
    grain = np.array([rng.gauss(0.0, p["grain_m"]) for _ in x]) * (1.0 - share)
    z = np.where(share >= 1.0, -p["rim_sink_m"], height(x, y) + grain)
    return np.column_stack([x, y, z]), triangles


def zip_rings(inner: list, outer: list) -> list:
    """Triangles, facing up, between two rings of (index, angle) in order of angle, stepping round
    whichever ring is behind. Each ring's first point starts it within a step of angle 0, so the
    strip starts and ends on the edge between them."""
    triangles = []
    i = j = 0
    while i < len(inner) or j < len(outer):
        next_inner = inner[(i + 1) % len(inner)][1] + (math.tau if i + 1 >= len(inner) else 0.0)
        next_outer = outer[(j + 1) % len(outer)][1] + (math.tau if j + 1 >= len(outer) else 0.0)
        a, b = inner[i % len(inner)][0], outer[j % len(outer)][0]
        if j == len(outer) or (i < len(inner) and next_inner <= next_outer):
            triangles.append((a, b, inner[(i + 1) % len(inner)][0]))
            i += 1
        else:
            triangles.append((a, b, outer[(j + 1) % len(outer)][0]))
            j += 1
    return triangles


def surface_normal(height, x: float, y: float, step: float = 0.01) -> np.ndarray:
    """The mound's normal at (x, y), from its slope over step either side."""
    h = height(np.array([x + step, x - step, x, x]), np.array([y, y, y + step, y - step]))
    n = np.array([(h[1] - h[0]) / (2.0 * step), (h[3] - h[2]) / (2.0 * step), 1.0])
    return n / np.linalg.norm(n)


def spots(rng: random.Random, count: int, pick, candidates: int = 8) -> list:
    """count spots spread evenly: each the candidate from pick() furthest from those before."""
    chosen = []
    for _ in range(count):
        options = [np.array(pick()) for _ in range(candidates)]
        if chosen:
            taken = np.array(chosen)
            options.sort(key=lambda o: -np.min(np.linalg.norm(taken - o, axis=1)))
        chosen.append(options[0])
    return chosen


def tilted(rng: random.Random, normal: np.ndarray, max_deg: float) -> np.ndarray:
    lean = math.tan(math.radians(rng.uniform(0.0, max_deg)))
    azimuth = rng.uniform(0.0, math.tau)
    n = normal + lean * np.array([math.cos(azimuth), math.sin(azimuth), 0.0])
    return n / np.linalg.norm(n)


def orientation(normal: np.ndarray, yaw: float) -> np.ndarray:
    """Rotation taking +z to normal, turned by yaw about it."""
    c, s = math.cos(yaw), math.sin(yaw)
    turn = np.array([[c, -s, 0.0], [s, c, 0.0], [0.0, 0.0, 1.0]])
    v = np.cross((0.0, 0.0, 1.0), normal)
    skew = np.array([[0.0, -v[2], v[1]], [v[2], 0.0, -v[0]], [-v[1], v[0], 0.0]])
    return (np.eye(3) + skew + skew @ skew / (1.0 + normal[2])) @ turn


def charcoal_piece(rng: random.Random, p: dict):
    """One block of charcoal centred on the origin, its length along x, with chipped corners: (its
    six faces' triangles as Nx3 positions, two triangles a face, and its height)."""
    size = np.array([rng.uniform(*limits) for limits in p["charcoal_size_m"]])
    corners = np.array([((i >> 2) & 1, (i >> 1) & 1, i & 1) for i in range(8)], dtype=float) - 0.5
    corners = corners * size + np.array([[rng.uniform(-1.0, 1.0) for _ in range(3)] for _ in range(8)]) \
        * p["charcoal_jitter"] * size
    faces = []
    for a, b, c, d in BOX_FACES:
        for triangle in ((a, b, c), (a, c, d)):
            points = corners[list(triangle)]
            # Wind each triangle to face out of the block.
            if np.dot(np.cross(points[1] - points[0], points[2] - points[0]), points.mean(axis=0)) < 0.0:
                points = points[[0, 2, 1]]
            faces.append(points)
    return np.vstack(faces), size[2]


def charcoal(rng: random.Random, p: dict, height):
    """The charcoal pieces laid into the mound: a list of (Nx3 positions, Nx3 face normals) blocks
    with three points a triangle, and the pieces' centres on the ground plane."""
    spread = p["charcoal_spread"] * p["radius_m"]

    def in_heap():
        angle, r = rng.uniform(0.0, math.tau), spread * math.sqrt(rng.random())
        return (r * math.cos(angle), r * math.sin(angle))

    pieces, centres = [], []
    for x, y in spots(rng, p["charcoal"], in_heap, candidates=4):
        points, tall = charcoal_piece(rng, p)
        normal = tilted(rng, surface_normal(height, x, y), p["charcoal_tilt_deg"])
        points = points @ orientation(normal, rng.uniform(0.0, math.tau)).T
        surface = float(height(np.array([x]), np.array([y]))[0])
        points = points + (x, y, surface) + normal * (0.5 - rng.uniform(*p["charcoal_bury"])) * tall
        triangles = points.reshape(-1, 3, 3)
        normals = np.cross(triangles[:, 1] - triangles[:, 0], triangles[:, 2] - triangles[:, 0])
        normals = np.repeat(normals / np.linalg.norm(normals, axis=1, keepdims=True), 3, axis=0)
        pieces.append((points, normals))
        centres.append((x, y))
    return pieces, np.array(centres)


def ash_colours(rng: random.Random, p: dict, positions: np.ndarray, centres: np.ndarray):
    """sRGB colours for the mound's points: by the ash's depth, mottled and sooty by charcoal."""
    rim, middle, top = (np.array(p[k]) for k in ("ash_rim", "ash_middle", "ash_top"))
    depth = np.clip(positions[:, 2] / p["height_m"], 0.0, 1.0)[:, None]
    colours = np.where(depth < 0.5, rim + (middle - rim) * depth / 0.5, middle + (top - middle) * (depth - 0.5) / 0.5)
    colours = colours * np.array([1.0 + rng.gauss(0.0, p["ash_mottle"]) for _ in colours])[:, None]
    nearest = np.min(np.linalg.norm(positions[:, None, :2] - centres[None, :, :], axis=2), axis=1)
    colours = colours * (1.0 - p["soot_strength"] * np.exp(-(nearest / p["soot_m"]) ** 2))[:, None]
    return np.clip(colours, 0.0, 1.0)


def charcoal_colours(rng: random.Random, p: dict, normals: np.ndarray) -> np.ndarray:
    """sRGB colours for a piece's points, one shade a triangle, its upward faces dusted with ash."""
    base = np.array(p["charcoal_colour"])
    shade = np.repeat([rng.uniform(0.8, 1.25) for _ in range(len(normals) // 3)], 3)[:, None]
    dust = p["charcoal_dust"] * np.clip(normals[:, 2], 0.0, 1.0)[:, None] ** 2
    return np.clip(base * shade * (1.0 - dust) + np.array(p["ash_middle"]) * dust, 0.0, 1.0)


def srgb_to_linear(c: np.ndarray) -> np.ndarray:
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def ash_pile(p: dict, seed: int):
    """The heap as (Nx3 positions, triangles, Nx3 sRGB colours, N charcoal marks (1 on charcoal, 0 on
    ash), per-triangle smooth flags, stats)."""
    rng = random.Random(seed)
    rim, height = heap(rng, p)
    positions, triangles = mound(rng, p, rim, height)
    pieces, centres = charcoal(rng, p, height)
    colours = ash_colours(rng, p, positions, centres)
    smooth = [True] * len(triangles)
    blocks, block_colours, marks = [positions], [colours], [np.zeros(len(positions))]
    offset = len(positions)
    for points, normals in pieces:
        triangles += [(offset + i, offset + i + 1, offset + i + 2) for i in range(0, len(points), 3)]
        smooth += [False] * (len(points) // 3)
        blocks.append(points)
        block_colours.append(charcoal_colours(rng, p, normals))
        marks.append(np.ones(len(points)))
        offset += len(points)
    positions = np.vstack(blocks)
    stats = {
        "charcoal": len(pieces),
        "triangles": len(triangles),
        "vertices": len(positions),
        "ash_top_m": float(blocks[0][:, 2].max()),
        "top_m": float(positions[:, 2].max()),
        "across_m": float(max(np.ptp(blocks[0][:, 0]), np.ptp(blocks[0][:, 1]))),
    }
    return positions, triangles, np.vstack(block_colours), np.concatenate(marks), smooth, stats


def ash_material() -> bpy.types.Material:
    """Base colour from the `Col` attribute, fully rough."""
    material = bpy.data.materials.get(MATERIAL_NAME) or bpy.data.materials.new(MATERIAL_NAME)
    nodes, links = material.node_tree.nodes, material.node_tree.links
    nodes.clear()
    output = nodes.new("ShaderNodeOutputMaterial")
    shader = nodes.new("ShaderNodeBsdfPrincipled")
    colour = nodes.new("ShaderNodeVertexColor")
    colour.layer_name = COLOUR_ATTRIBUTE
    shader.inputs["Roughness"].default_value = 1.0
    links.new(colour.outputs["Color"], shader.inputs["Base Color"])
    links.new(shader.outputs["BSDF"], output.inputs["Surface"])
    material.use_backface_culling = True
    return material


def mesh_object(name: str, positions, triangles, colours, charcoal_marks, smooth, stats) -> bpy.types.Object:
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(positions.tolist(), [], triangles)
    mesh.polygons.foreach_set("use_smooth", smooth)
    corners = np.zeros(len(mesh.loops), dtype=np.int32)
    mesh.loops.foreach_get("vertex_index", corners)
    uvs = np.column_stack([charcoal_marks, np.zeros(len(charcoal_marks))])
    mesh.uv_layers.new(name="UVMap").data.foreach_set("uv", uvs[corners].ravel().tolist())
    attribute = mesh.color_attributes.new(COLOUR_ATTRIBUTE, "FLOAT_COLOR", "POINT")
    rgba = np.column_stack([srgb_to_linear(colours), np.ones(len(colours))])
    attribute.data.foreach_set("color", rgba.ravel().tolist())
    mesh.materials.append(ash_material())
    mesh.validate()
    print(f"{name}: " + ", ".join(f"{k} {v:.3f}" if isinstance(v, float) else f"{k} {v}" for k, v in stats.items()))
    return bpy.data.objects.new(name, mesh)


def show(obj: bpy.types.Object, name: str, location) -> None:
    """Replace the object called name in the open file, in the Environment collection."""
    for previous in [o for o in bpy.data.objects if o.name == name and o is not obj]:
        mesh = previous.data
        bpy.data.objects.remove(previous)
        if mesh.users == 0:
            bpy.data.meshes.remove(mesh)
    obj.name = obj.data.name = name
    collection = bpy.data.collections.get("Environment") or bpy.context.scene.collection
    collection.objects.link(obj)
    obj.location = location


def export(obj: bpy.types.Object, path: str) -> None:
    bpy.context.scene.collection.objects.link(obj)
    for other in bpy.context.view_layer.objects:
        other.select_set(False)
    obj.select_set(True)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.ops.export_scene.gltf(
        filepath=path,
        export_format="GLB",
        use_selection=True,
        export_yup=True,
        export_apply=True,
        export_materials="EXPORT",
        export_vertex_color="MATERIAL",
        export_animations=False,
    )
    print("wrote", path)


def main(argv: list) -> None:
    seed = int(argv[argv.index("--seed") + 1]) if "--seed" in argv else ASH["seed"]
    print(f"seed {seed}")
    pile = mesh_object(ASH["name"], *ash_pile(ASH, seed))
    if "--export" not in argv:
        show(pile, ASH["name"], VIEW_OFFSET)
        return
    if not bpy.app.background:
        raise SystemExit("Export headless: blender -b --factory-startup --python tools/blender/ash_pile.py -- --export")
    after = argv[argv.index("--export") + 1:]
    out_dir = after[0] if after and not after[0].startswith("--") else OUT_DIR
    export(pile, os.path.join(out_dir, FILE))


if __name__ == "__main__":
    main(sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else [])
