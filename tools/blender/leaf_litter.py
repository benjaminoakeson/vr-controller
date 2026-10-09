"""Builds a small cluster of dead oak leaves lying on the ground, for spawning under oaks in numbers,
and the same leaves crumpled into a ball, which is what the player holds after grabbing a cluster.

Inside an open Blender session (Text Editor > Run Script) it rebuilds the `OakLeafLitter` and
`OakLeafBall` objects in the Environment collection, beside the player model for scale. Headless,
from the repository root, it writes the game models instead:
    blender -b --factory-startup --python tools/blender/leaf_litter.py -- --export [--seed N]

Both are modelled at real scale in metres (unlike craftables.blend's ten-times items) and exported
at 1.0; Blender's +Z becomes +Y in Godot. The cluster's origin is its centre on the ground, the
ball's its centre. Each is one mesh with one material that takes its colour from the `Col`
attribute, so one draw call with no textures. Leaves are single sheets drawn from both sides, laid
one at a time so each rests on what is under it: the ground and earlier leaves in the cluster, a
lumpy core and earlier leaves in the ball. The same seed always gives the same pair.

In Godot both models' import settings swap in `oak_leaf_litter.tres`, the dead_leaf shader, which
takes each leaf's colour from the vertex colours and draws its veins from its UVs: each leaf's own
frame, x across it (0.5 on the midrib, 0 and 1 at its widest) and y along it in Godot (0 at the
base, 1 at the tip; Blender's v runs the other way, as glTF flips it). Godot's y below -0.5 marks
the ball's core, which is no leaf. Blender shows the colours only.
"""

import math
import os
import random
import sys

import bpy
import numpy as np

OUT_DIR = os.path.join(os.getcwd(), "assets", "vegetation", "oak")
CLUSTER_FILE = "oak_leaf_litter.glb"
BALL_FILE = "oak_leaf_ball.glb"
# Where they sit in an open session: beside the player model at the origin, the ball on the ground.
VIEW_OFFSET = (-1.4, 0.0, 0.0)
BALL_VIEW_OFFSET = (-1.05, 0.0, 0.0)
MATERIAL_NAME = "oak_leaf_litter"
COLOUR_ATTRIBUTE = "Col"

# Dead English oak leaves: obovate, four rounded lobes a side, alternate between the sides.
OAK = {
    "name": "OakLeafLitter",
    "ball_name": "OakLeafBall",
    "seed": 1,
    "leaves": 7,
    "spread_m": 0.09,               # leaf centres lie within this radius, so the leaves overlap
    "tilt_deg": 10.0,               # most a leaf leans off the surface it lands on
    "leaf_length_m": (0.10, 0.15),
    "leaf_width_ratio": (0.52, 0.64),
    "lobes_per_side": 4,
    "sinus_depth": (0.45, 0.65),    # share of the half-width a sinus cuts in
    # Dry leaves curl: each half turns about the midrib, the edges roll, the blade arches and twists.
    "fold_deg": (-5.0, 40.0),
    "edge_roll": (0.0, 0.35),
    "arch": (-0.12, 0.25),
    "twist": (-0.3, 0.3),
    "crumple_m": 0.0015,
    # (weight, sRGB): tan, light brown, russet, brown, dark brown, ochre, grey-brown.
    "palette": [
        (0.24, (0.66, 0.50, 0.31)),
        (0.22, (0.56, 0.39, 0.21)),
        (0.18, (0.51, 0.30, 0.15)),
        (0.16, (0.40, 0.25, 0.13)),
        (0.08, (0.26, 0.16, 0.09)),
        (0.07, (0.68, 0.52, 0.23)),
        (0.05, (0.41, 0.33, 0.23)),
    ],
    # The ball: the cluster's leaves, a little scrunched, crumpled over a lumpy core.
    "ball_core_m": 0.026,
    "ball_leaf_scale": 0.85,
    "ball_crumple_m": 0.004,        # each point of a leaf stands off what is under it by up to this
    "ball_fold_deg": (-10.0, 45.0), # each half of a leaf turns down towards the ball by this
    "ball_creases": (3, 5),         # random fold lines crumpling each leaf
    "ball_crease_slope": (0.15, 0.35),  # how steeply a leaf rises (or sinks) away from a crease
    "ball_crease_m": (0.006, 0.012),    # the most creases lift a leaf's points off the ball
    "ball_flare_m": (0.0, 0.015),   # one end of a leaf lifts off the ball by up to this
    "core_colour": (0.22, 0.14, 0.08),
    "occlusion_depth_m": 0.02,      # leaf cover over a point that darkens it fully
    "occlusion_strength": 0.45,
}

MIDRIB = (0.25, 0.5, 0.75)          # interior midrib points, as shares of the length
SHADE_MIDRIB = 1.1
SHADE_SINUS = 0.95
SHADE_TIP = 0.8
SHADE_STALK = 0.75
STALK_WIDTH_M = 0.0022              # half-width where it meets the blade
STALK_SHARE = 0.09                  # its length, as a share of the leaf's
GAP_M = 0.0005                      # a leaf rests this far above what it lands on
CORE_UV = (0.5, -1.0)               # in Godot's frame: no leaf, so no veins
BALL_SAMPLE_STEPS = 10              # samples 4 mm apart on the ball's largest leaf triangles


def envelope(t: float) -> float:
    """The leaf's half-width at share t of its length, 1 at the widest (two thirds along)."""
    a, b = 1.4, 0.7
    peak = a / (a + b)
    return (t ** a) * ((1.0 - t) ** b) / ((peak ** a) * ((1.0 - peak) ** b))


def outline(rng: random.Random, p: dict, side: float) -> list:
    """(t, half-width share, shade) from base to apex along one side: a small ear beside the
    stalk, a sinus and a blunt two-point lobe per lobe, then the rounded terminal lobe. The left
    side's lobes sit a little further up, as oak lobes alternate."""
    lobes = p["lobes_per_side"]
    start = 0.1 if side > 0 else 0.15
    end = 0.84 if side > 0 else 0.87
    span = (end - start) / lobes
    stations = [(0.03, 0.22 * rng.uniform(0.8, 1.0), SHADE_TIP)]
    for k in range(lobes):
        sinus = start + k * span
        stations.append((sinus, envelope(sinus) * (1.0 - rng.uniform(*p["sinus_depth"])), SHADE_SINUS))
        centre = sinus + 0.55 * span
        for d in (-0.26, 0.26):
            t = centre + d * span
            # Lobes reach a little towards the apex: each takes the width from just above it.
            stations.append((t, min(envelope(t + 0.07), 1.0) * rng.uniform(0.88, 1.0), SHADE_TIP))
    stations.append((end, envelope(end) * (1.0 - rng.uniform(*p["sinus_depth"])), SHADE_SINUS))
    stations.append((0.93, 0.5 * rng.uniform(0.85, 1.0), SHADE_TIP))
    stations.append((0.985, 0.25 * rng.uniform(0.85, 1.0), SHADE_TIP))
    return stations


def leaf_sheet(rng: random.Random, p: dict):
    """One flat leaf, centred on the origin, base towards -y: (Nx2 positions, triangles, shades)."""
    length = rng.uniform(*p["leaf_length_m"])
    half_width = 0.5 * length * rng.uniform(*p["leaf_width_ratio"])
    t_of = [0.0, 1.0]
    signed_width = [0.0, 0.0]
    shade = [1.0, SHADE_TIP]
    midrib = [0]
    for t in MIDRIB:
        midrib.append(len(t_of))
        t_of.append(t)
        signed_width.append(0.0)
        shade.append(SHADE_MIDRIB)
    midrib.append(1)
    triangles = []
    for side in (1.0, -1.0):
        chain = [0]
        for t, width, station_shade in outline(rng, p, side):
            chain.append(len(t_of))
            t_of.append(t)
            signed_width.append(side * width)
            shade.append(station_shade)
        chain.append(1)
        triangles += zip_chains(chain, midrib, t_of)
    flat = np.column_stack([np.array(signed_width) * half_width, (np.array(t_of) - 0.5) * length])
    # A short stalk below the base.
    stalk = len(flat)
    base_y = -0.5 * length
    flat = np.vstack([flat, [[-STALK_WIDTH_M, base_y], [STALK_WIDTH_M, base_y],
                             [-0.6 * STALK_WIDTH_M, base_y - STALK_SHARE * length],
                             [0.6 * STALK_WIDTH_M, base_y - STALK_SHARE * length]]])
    shade += [SHADE_STALK] * 4
    triangles += [(stalk, stalk + 1, stalk + 3), (stalk, stalk + 3, stalk + 2)]
    # Wind every triangle to face +z.
    for i, (a, b, c) in enumerate(triangles):
        ab, ac = flat[b] - flat[a], flat[c] - flat[a]
        if ab[0] * ac[1] - ab[1] * ac[0] < 0.0:
            triangles[i] = (a, c, b)
    return flat, triangles, np.array(shade), length, half_width


def zip_chains(outer: list, inner: list, t_of: list) -> list:
    """Triangles between two chains that share their ends, stepping whichever is behind."""
    triangles = []
    i = j = 0
    while i < len(outer) - 1 or j < len(inner) - 1:
        step_outer = j == len(inner) - 1 or (i < len(outer) - 1 and t_of[outer[i + 1]] <= t_of[inner[j + 1]])
        if step_outer:
            triangle = (outer[i], outer[i + 1], inner[j])
            i += 1
        else:
            triangle = (outer[i], inner[j + 1], inner[j])
            j += 1
        if len(set(triangle)) == 3:
            triangles.append(triangle)
    return triangles


def curl(rng: random.Random, p: dict, flat: np.ndarray, length: float, half_width: float) -> np.ndarray:
    """The flat leaf curled as a dry one is: (Nx3 positions)."""
    x, y = flat[:, 0], flat[:, 1]
    across = np.abs(x)
    fold = math.radians(rng.uniform(*p["fold_deg"]))
    # Each half turns about the midrib, keeping its width; positive folds cup the leaf.
    points = np.column_stack([x * math.cos(fold), y, across * math.sin(fold)])
    along = y / (0.5 * length)
    edge = np.clip(across / half_width, 0.0, 1.0)
    points[:, 2] += rng.uniform(*p["edge_roll"]) * half_width * edge ** 3
    points[:, 2] += rng.uniform(*p["arch"]) * 0.5 * length * along ** 2
    points[:, 2] += rng.uniform(*p["twist"]) * x * along
    points[:, 2] += np.array([rng.gauss(0.0, p["crumple_m"]) for _ in x]) * (edge > 0.05)
    return points


class HeightField:
    """The cluster's top surface on a grid: the ground, then each leaf as it is laid down."""

    CELL_M = 0.012

    def __init__(self, reach_m: float):
        self.origin = -reach_m
        self.size = int(2.0 * reach_m / self.CELL_M) + 1
        self.top = np.zeros((self.size, self.size))

    def _cells(self, points: np.ndarray):
        cells = np.floor((points[:, :2] - self.origin) / self.CELL_M).astype(int)
        cells = np.clip(cells, 0, self.size - 1)
        return cells[:, 0], cells[:, 1]

    def at(self, points: np.ndarray) -> np.ndarray:
        return self.top[self._cells(points)]

    def lay(self, points: np.ndarray) -> None:
        np.maximum.at(self.top, self._cells(points), points[:, 2])

    def normal(self, x: float, y: float, reach: float) -> np.ndarray:
        """The surface's normal, smoothed over reach either side."""
        probes = np.array([(x + reach, y), (x - reach, y), (x, y + reach), (x, y - reach)])
        h = self.at(probes)
        n = np.array([(h[1] - h[0]) / (2.0 * reach), (h[3] - h[2]) / (2.0 * reach), 1.0])
        return n / np.linalg.norm(n)


def surface_samples(points: np.ndarray, triangles: list, steps: int = 3) -> np.ndarray:
    """Points over each triangle on a grid of steps along each edge (3: corners, thirds of the
    edges and the centre), triangle by triangle. Keep them closer than a field's cells."""
    weights = np.array([(i, j, steps - i - j) for i in range(steps + 1) for j in range(steps + 1 - i)],
                       dtype=float) / steps
    return np.einsum("kj,tjd->tkd", weights, points[np.array(triangles)]).reshape(-1, 3)


def orientation(normal: np.ndarray, yaw: float, flip: bool) -> np.ndarray:
    """Rotation taking a leaf's +z to normal, turned by yaw about it, upside down if flip."""
    c, s = math.cos(yaw), math.sin(yaw)
    turn = np.array([[c, -s, 0.0], [s, c, 0.0], [0.0, 0.0, 1.0]])
    if flip:
        turn = turn @ np.diag([-1.0, 1.0, -1.0])
    v = np.cross((0.0, 0.0, 1.0), normal)
    skew = np.array([[0.0, -v[2], v[1]], [v[2], 0.0, -v[0]], [-v[1], v[0], 0.0]])
    align = np.eye(3) + skew + skew @ skew / (1.0 + normal[2])
    return align @ turn


def tilted(rng: random.Random, normal: np.ndarray, max_deg: float) -> np.ndarray:
    lean = math.tan(math.radians(rng.uniform(0.0, max_deg)))
    azimuth = rng.uniform(0.0, math.tau)
    n = normal + lean * np.array([math.cos(azimuth), math.sin(azimuth), 0.0])
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


def srgb_to_linear(c: np.ndarray) -> np.ndarray:
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def cluster(p: dict, seed: int):
    """The cluster as (Nx3 positions, triangles, Nx3 sRGB colours, Nx2 leaf UVs, stats), and its
    leaves as (flat positions, triangles, colours, UVs) for the ball."""
    rng = random.Random(seed)
    field = HeightField(p["spread_m"] + p["leaf_length_m"][1])
    weights = [w for w, _ in p["palette"]]
    colours = [np.array(c) for _, c in p["palette"]]

    def in_cluster():
        angle, r = rng.uniform(0.0, math.tau), p["spread_m"] * math.sqrt(rng.random())
        return (r * math.cos(angle), r * math.sin(angle))

    blocks, leaves = [], []
    for x, y in spots(rng, p["leaves"], in_cluster, candidates=3):
        flat, leaf_triangles, shade, length, half_width = leaf_sheet(rng, p)
        points = curl(rng, p, flat, length, half_width)
        normal = tilted(rng, field.normal(x, y, 0.5 * length), p["tilt_deg"])
        flip = rng.random() < 0.2
        points = points @ orientation(normal, rng.uniform(0.0, math.tau), flip).T + (x, y, 0.0)
        samples = surface_samples(points, leaf_triangles)
        lift = GAP_M - (samples[:, 2] - field.at(samples)).min()
        points[:, 2] += lift
        field.lay(samples + (0.0, 0.0, lift))
        base = colours[rng.choices(range(len(colours)), weights)[0]]
        base = base * rng.uniform(0.92, 1.08) * np.array([1.0 + rng.gauss(0.0, 0.03) for _ in range(3)])
        jitter = np.array([rng.uniform(0.96, 1.04) for _ in shade])
        colour = np.clip(base[None, :] * (shade * jitter)[:, None], 0.0, 1.0)
        uv = np.column_stack([0.5 + flat[:, 0] / (2.0 * half_width), 0.5 + flat[:, 1] / length])
        blocks.append((points, leaf_triangles, colour, uv))
        leaves.append((flat, leaf_triangles, colour, uv))

    positions, triangles, colours, uvs = joined(blocks)
    # Darken what later leaves cover.
    cover = np.clip((field.at(positions) - positions[:, 2]) / p["occlusion_depth_m"], 0.0, 1.0)
    colours = colours * (1.0 - p["occlusion_strength"] * cover)[:, None]
    stats = {
        "leaves": p["leaves"],
        "triangles": len(triangles),
        "vertices": len(positions),
        "top_m": float(positions[:, 2].max()),
        "across_m": float(max(np.ptp(positions[:, 0]), np.ptp(positions[:, 1]))),
    }
    return (positions, triangles, colours, uvs, stats), leaves


def joined(blocks: list):
    """One mesh from (positions, triangles, colours, UVs) blocks: (positions, triangles, colours, UVs)."""
    triangles, offset = [], 0
    for points, block_triangles, *_ in blocks:
        triangles.extend(tuple(i + offset for i in t) for t in block_triangles)
        offset += len(points)
    return (np.vstack([b[0] for b in blocks]), triangles, np.vstack([b[2] for b in blocks]),
            np.vstack([b[3] for b in blocks]))


class SphereField:
    """The ball's outer surface as a radius for each direction, on a latitude-longitude grid."""

    ROWS, COLUMNS = 24, 48              # cells of 7.5 degrees, 4.6 mm across at 3.5 cm

    def __init__(self, radius_at):
        latitude = (np.arange(self.ROWS) + 0.5) / self.ROWS * math.pi
        longitude = (np.arange(self.COLUMNS) + 0.5) / self.COLUMNS * math.tau - math.pi
        latitude, longitude = np.meshgrid(latitude, longitude, indexing="ij")
        directions = np.stack([np.sin(latitude) * np.cos(longitude), np.sin(latitude) * np.sin(longitude),
                               np.cos(latitude)], axis=-1)
        self.radius = radius_at(directions.reshape(-1, 3)).reshape(self.ROWS, self.COLUMNS)

    def _cells(self, points: np.ndarray):
        latitude = np.arccos(np.clip(points[:, 2] / np.linalg.norm(points, axis=1), -1.0, 1.0))
        longitude = np.arctan2(points[:, 1], points[:, 0])
        row = np.clip((latitude / math.pi * self.ROWS).astype(int), 0, self.ROWS - 1)
        column = np.clip(((longitude + math.pi) / math.tau * self.COLUMNS).astype(int), 0, self.COLUMNS - 1)
        return row, column

    def at(self, points: np.ndarray) -> np.ndarray:
        return self.radius[self._cells(points)]

    def lay(self, points: np.ndarray) -> None:
        np.maximum.at(self.radius, self._cells(points), np.linalg.norm(points, axis=1))


def unit(vectors: np.ndarray) -> np.ndarray:
    return vectors / np.linalg.norm(vectors, axis=-1, keepdims=True)


def random_direction(rng: random.Random) -> np.ndarray:
    return unit(np.array([rng.gauss(0.0, 1.0) for _ in range(3)]))


def folded_over(flat: np.ndarray, centre: np.ndarray, yaw: float, fold: float, radius_at) -> np.ndarray:
    """A flat leaf laid over the ball with its middle at centre: the midrib follows the surface,
    radius_at giving its height under each point, and each half is a straight blade turned fold
    radians down towards the ball, so the lobed edges stand off it."""
    across = unit(np.cross(centre, (0.0, 0.0, 1.0) if abs(centre[2]) < 0.9 else (1.0, 0.0, 0.0)))
    along = np.cross(centre, across)
    across, along = math.cos(yaw) * across + math.sin(yaw) * along, math.cos(yaw) * along - math.sin(yaw) * across
    angle = (flat[:, 1] / radius_at(centre[None, :]))[:, None]
    spine = np.cos(angle) * centre + np.sin(angle) * along
    side = flat[:, :1]
    blade = math.cos(fold) * side * across - math.sin(fold) * np.abs(side) * spine
    return spine * radius_at(spine)[:, None] + blade


def subdivided(triangles: list, *arrays: np.ndarray):
    """Each triangle split in four at its edges' middles, for a leaf that crumples finely:
    (triangles, then each per-point array with values for the new points)."""
    grown, middles = [list(a) for a in arrays], {}

    def middle(a: int, b: int) -> int:
        key = (min(a, b), max(a, b))
        if key not in middles:
            middles[key] = len(grown[0])
            for values in grown:
                values.append(0.5 * (values[a] + values[b]))
        return middles[key]

    finer = []
    for a, b, c in triangles:
        ab, bc, ca = middle(a, b), middle(b, c), middle(c, a)
        finer += [(a, ab, ca), (b, bc, ab), (c, ca, bc), (ab, bc, ca)]
    return (finer, *(np.array(values) for values in grown))


def creased(rng: random.Random, p: dict, flat: np.ndarray) -> np.ndarray:
    """Height off the ball for each point of a crumpled leaf: ridges and valleys along a few
    random fold lines across it."""
    height = np.zeros(len(flat))
    for _ in range(rng.randint(*p["ball_creases"])):
        through = flat[rng.randrange(len(flat))]
        heading = rng.uniform(0.0, math.pi)
        normal = np.array([-math.sin(heading), math.cos(heading)])
        slope = rng.choice((-1.0, 1.0)) * rng.uniform(*p["ball_crease_slope"])
        height += slope * np.abs((flat - through) @ normal)
    height -= height.min()
    return height * rng.uniform(*p["ball_crease_m"]) / max(height.max(), 1e-9)


def icosphere() -> tuple:
    """A unit icosphere subdivided once: (42x3 directions, 80 triangles)."""
    t = (1.0 + math.sqrt(5.0)) / 2.0
    points = [unit(np.array(v, dtype=float)) for v in (
        (-1, t, 0), (1, t, 0), (-1, -t, 0), (1, -t, 0), (0, -1, t), (0, 1, t),
        (0, -1, -t), (0, 1, -t), (t, 0, -1), (t, 0, 1), (-t, 0, -1), (-t, 0, 1))]
    faces = [(0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4), (11, 10, 2),
             (10, 7, 6), (7, 1, 8), (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9), (4, 9, 5),
             (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1)]
    middles = {}

    def middle(a: int, b: int) -> int:
        key = (min(a, b), max(a, b))
        if key not in middles:
            middles[key] = len(points)
            points.append(unit(points[a] + points[b]))
        return middles[key]

    triangles = []
    for a, b, c in faces:
        ab, bc, ca = middle(a, b), middle(b, c), middle(c, a)
        triangles += [(a, ab, ca), (b, bc, ab), (c, ca, bc), (ab, bc, ca)]
    return np.array(points), triangles


def ball(p: dict, leaves: list, seed: int):
    """The cluster's leaves crumpled into a ball: (Nx3 positions, triangles, Nx3 sRGB colours, Nx2 UVs, stats)."""
    rng = random.Random(seed + 1000)
    core = p["ball_core_m"]
    bumps = [(random_direction(rng), rng.uniform(-0.2, 0.3), rng.uniform(0.1, 0.3)) for _ in range(8)]

    def core_radius(directions: np.ndarray) -> np.ndarray:
        return core * (1.0 + sum(a * np.exp((directions @ c - 1.0) / w) for c, a, w in bumps))

    field = SphereField(core_radius)
    directions, core_triangles = icosphere()
    core_points = directions * core_radius(directions)[:, None]
    mottle = np.array([rng.uniform(0.7, 1.2) for _ in core_points])[:, None]
    blocks = [(core_points, core_triangles, np.array(p["core_colour"]) * mottle, np.tile(CORE_UV, (len(core_points), 1)))]
    centres = spots(rng, len(leaves), lambda: random_direction(rng))
    for (flat, triangles, colour, uv), centre in zip(leaves, centres):
        triangles, flat, colour, uv = subdivided(triangles, flat * p["ball_leaf_scale"], colour, uv)
        stand_off = creased(rng, p, flat) + np.array([rng.uniform(0.0, p["ball_crumple_m"]) for _ in flat])
        # One end lifts off the ball, as a crumpled leaf's tip or stalk end does.
        along = rng.choice((-1.0, 1.0)) * flat[:, 1] / np.abs(flat[:, 1]).max()
        stand_off += rng.uniform(*p["ball_flare_m"]) * np.clip((along - 0.3) / 0.7, 0.0, 1.0) ** 2
        fold = math.radians(rng.uniform(*p["ball_fold_deg"]))
        yaw = rng.uniform(0.0, math.tau)
        points = folded_over(flat, centre, yaw, fold, lambda d: field.at(d) + GAP_M)
        points += unit(points) * stand_off[:, None]
        corners = np.array(triangles).ravel()
        for _ in range(3):
            # Push out the corners of any triangle that dips under what is already there.
            samples = surface_samples(points, triangles, BALL_SAMPLE_STEPS)
            short = (field.at(samples) + GAP_M - np.linalg.norm(samples, axis=1))
            short = short.reshape(len(triangles), -1).max(axis=1)
            if short.max() <= 0.0:
                break
            push = np.zeros(len(points))
            np.maximum.at(push, corners, np.repeat(short, 3))
            points += unit(points) * push[:, None]
        field.lay(surface_samples(points, triangles, BALL_SAMPLE_STEPS))
        blocks.append((points, triangles, colour, uv))

    positions, triangles, colours, uvs = joined(blocks)
    cover = np.clip((field.at(positions) - np.linalg.norm(positions, axis=1)) / p["occlusion_depth_m"], 0.0, 1.0)
    colours = colours * (1.0 - p["occlusion_strength"] * cover)[:, None]
    surface = np.linalg.norm(positions, axis=1)
    stats = {
        "leaves": len(leaves),
        "triangles": len(triangles),
        "vertices": len(positions),
        # A sphere collider about this size fits it.
        "median_radius_m": float(np.median(field.radius)),
        "max_radius_m": float(surface.max()),
    }
    return positions, triangles, colours, uvs, stats


def litter_material() -> bpy.types.Material:
    """Base colour from the `Col` attribute, rough, drawn from both sides."""
    material = bpy.data.materials.get(MATERIAL_NAME) or bpy.data.materials.new(MATERIAL_NAME)
    nodes, links = material.node_tree.nodes, material.node_tree.links
    nodes.clear()
    output = nodes.new("ShaderNodeOutputMaterial")
    shader = nodes.new("ShaderNodeBsdfPrincipled")
    colour = nodes.new("ShaderNodeVertexColor")
    colour.layer_name = COLOUR_ATTRIBUTE
    shader.inputs["Roughness"].default_value = 0.9
    links.new(colour.outputs["Color"], shader.inputs["Base Color"])
    links.new(shader.outputs["BSDF"], output.inputs["Surface"])
    material.use_backface_culling = False
    return material


def mesh_object(name: str, positions, triangles, colours, uvs, stats) -> bpy.types.Object:
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(positions.tolist(), [], triangles)
    corners = np.zeros(len(mesh.loops), dtype=np.int32)
    mesh.loops.foreach_get("vertex_index", corners)
    blender_uvs = np.column_stack([uvs[:, 0], 1.0 - uvs[:, 1]])
    mesh.uv_layers.new(name="UVMap").data.foreach_set("uv", blender_uvs[corners].ravel().tolist())
    mesh.polygons.foreach_set("use_smooth", [True] * len(mesh.polygons))
    attribute = mesh.color_attributes.new(COLOUR_ATTRIBUTE, "FLOAT_COLOR", "POINT")
    rgba = np.column_stack([srgb_to_linear(colours), np.ones(len(colours))])
    attribute.data.foreach_set("color", rgba.ravel().tolist())
    mesh.materials.append(litter_material())
    mesh.validate()
    print(f"{name}: " + ", ".join(f"{k} {v:.3f}" if isinstance(v, float) else f"{k} {v}" for k, v in stats.items()))
    return bpy.data.objects.new(name, mesh)


def build(p: dict, seed: int) -> tuple:
    """The cluster and the ball made of its leaves, as new objects."""
    cluster_mesh, leaves = cluster(p, seed)
    print(f"seed {seed}")
    return mesh_object(p["name"], *cluster_mesh), mesh_object(p["ball_name"], *ball(p, leaves, seed))


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
    seed = int(argv[argv.index("--seed") + 1]) if "--seed" in argv else OAK["seed"]
    pile, crumpled = build(OAK, seed)
    if "--export" not in argv:
        show(pile, OAK["name"], VIEW_OFFSET)
        resting = -min(v.co.z for v in crumpled.data.vertices)
        show(crumpled, OAK["ball_name"], (BALL_VIEW_OFFSET[0], BALL_VIEW_OFFSET[1], resting))
        return
    if not bpy.app.background:
        raise SystemExit("Export headless: blender -b --factory-startup --python tools/blender/leaf_litter.py -- --export")
    after = argv[argv.index("--export") + 1:]
    out_dir = after[0] if after and not after[0].startswith("--") else OUT_DIR
    export(pile, os.path.join(out_dir, CLUSTER_FILE))
    export(crumpled, os.path.join(out_dir, BALL_FILE))


if __name__ == "__main__":
    main(sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else [])
