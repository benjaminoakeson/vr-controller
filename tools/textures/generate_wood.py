"""Generates a tileable, lightly stylised old-wood texture set.

Outputs albedo, normal (OpenGL / Godot convention) and roughness PNGs. Every
feature is built from noise that wraps at the tile edges, so the set repeats
seamlessly. The look aims between realistic and toon: grain tones are softly
banded and wear has crisp edges, but fine grain and pores keep some realism.

Usage: python3 generate_wood.py OUTPUT_DIR [--size 1024] [--seed 7]
"""

import argparse
import math
import os

import numpy as np
from PIL import Image, ImageDraw

# Palette, sRGB 0-1.
EARLY_WOOD = np.array([0.74, 0.41, 0.17])  # light part of each growth ring
LATE_WOOD = np.array([0.56, 0.27, 0.10])   # darker part toward the ring line
RING_LINE = np.array([0.31, 0.12, 0.04])
STAIN = np.array([0.22, 0.09, 0.03])
BARE_WOOD = np.array([0.86, 0.69, 0.43])   # worn through the finish
SEAM = np.array([0.16, 0.07, 0.03])


def periodic_value_noise(size, cells_x, cells_y, rng):
    """Smooth value noise on a lattice that wraps, sampled at size x size."""
    grid = rng.random((cells_y, cells_x))
    x = np.arange(size) * cells_x / size
    y = np.arange(size) * cells_y / size
    x0, y0 = np.floor(x).astype(int), np.floor(y).astype(int)
    fx, fy = x - x0, y - y0
    fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    x1, y1 = (x0 + 1) % cells_x, (y0 + 1) % cells_y
    top = grid[y0][:, x0] * (1 - fx) + grid[y0][:, x1] * fx
    bottom = grid[y1][:, x0] * (1 - fx) + grid[y1][:, x1] * fx
    return top * (1 - fy)[:, None] + bottom * fy[:, None]


def fbm(size, cells_x, cells_y, rng, octaves=4, gain=0.5):
    """Fractal sum of wrapping value noise, normalised to 0-1."""
    total, amplitude, norm = np.zeros((size, size)), 1.0, 0.0
    for octave in range(octaves):
        total += amplitude * periodic_value_noise(size, cells_x * 2 ** octave, cells_y * 2 ** octave, rng)
        norm += amplitude
        amplitude *= gain
    total /= norm
    return (total - total.min()) / (total.max() - total.min())


def smoothstep(edge0, edge1, x):
    t = np.clip((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def soft_bands(x, levels, softness=0.25):
    """Quantises 0-1 values into `levels` steps with softened edges: the toon part of the look."""
    scaled = x * (levels - 1)
    base = np.floor(scaled)
    frac = scaled - base
    return (base + smoothstep(0.5 - softness, 0.5 + softness, frac)) / (levels - 1)


def box_blur(a, radius):
    """Wrapping box blur, so blurred maps still tile."""
    out = np.zeros_like(a)
    for dy in range(-radius, radius + 1):
        for dx in range(-radius, radius + 1):
            out += np.roll(np.roll(a, dy, axis=0), dx, axis=1)
    return out / (2 * radius + 1) ** 2


def lerp(a, b, t):
    t = t[..., None] if np.ndim(t) == 2 else t
    return a * (1 - t) + b * t


def wrapped_strokes(size, strokes, supersample=2):
    """Anti-aliased strokes that wrap at the edges; returns a 0-1 mask."""
    big = size * supersample
    image = Image.new("L", (big, big), 0)
    draw = ImageDraw.Draw(image)
    for (x0, y0, x1, y1, width, value) in strokes:
        for ox in (-big, 0, big):
            for oy in (-big, 0, big):
                draw.line([(x0 * big + ox, y0 * big + oy), (x1 * big + ox, y1 * big + oy)],
                          fill=int(value * 255), width=max(1, round(width * supersample)))
    return np.asarray(image.resize((size, size), Image.LANCZOS), dtype=np.float64) / 255.0


def generate(size, seed, boards=3, rings=64):
    rng = np.random.default_rng(seed)
    v = (np.arange(size) / size)[:, None] * np.ones((1, size))

    # Growth rings run along x. The warp keeps whole-number periods so the tile wraps.
    warp = fbm(size, 3, 6, rng) * 1.2 + fbm(size, 10, 20, rng, octaves=3) * 0.25
    phase = v * rings + warp
    ring = phase - np.floor(phase)                        # 0 just after a ring line, rising to 1
    tone = soft_bands(ring ** 1.6, levels=3, softness=0.3)
    line_width = 0.05 + 0.05 * fbm(size, 6, 12, rng, octaves=2)
    ring_line = 1 - smoothstep(0.0, line_width, ring)     # crisp-ish dark line at each ring
    fine = fbm(size, 16, 280, rng, octaves=2)             # faint fine grain
    hairlines = smoothstep(0.64, 0.72, fbm(size, 6, 420, rng, octaves=2))  # dense thin dark grain lines
    streaks = soft_bands(smoothstep(0.35, 0.9, fbm(size, 2, 48, rng)), levels=3, softness=0.35)  # long dark streaks
    pores = smoothstep(0.76, 0.84, fbm(size, 70, 800, rng, octaves=1))

    # Boards: a thin seam between each, and a small tint per board.
    board_v = v * boards
    board_index = np.floor(board_v).astype(int)
    board_frac = board_v - board_index
    seam_width = 0.012 * boards
    seam = 1 - smoothstep(0.0, seam_width, np.minimum(board_frac, 1 - board_frac))
    seam_shadow = 1 - smoothstep(0.0, seam_width * 3, board_frac)  # darker just below each seam
    tint = rng.uniform(-0.06, 0.06, boards)[board_index]

    stain = soft_bands(smoothstep(0.45, 0.85, fbm(size, 2, 20, rng)), levels=3, softness=0.35)  # streaks along the grain

    # Chips: flecks stretched along the grain, clustered in worn areas.
    worn = smoothstep(0.5, 0.75, fbm(size, 3, 5, rng))
    flecks = smoothstep(0.72, 0.755, fbm(size, 36, 220, rng, octaves=3))  # small, stretched along the grain
    chips = np.clip(flecks * (0.25 + 0.75 * worn), 0, 1)
    chips = smoothstep(0.35, 0.55, chips)                 # crisp edges

    # Scratches, mostly across the grain as in the reference.
    strokes_light, strokes_dark = [], []
    for i in range(90):
        x, y = rng.random(), rng.random()
        angle = math.radians(rng.normal(90, 25) if rng.random() < 0.75 else rng.uniform(0, 180))
        length = rng.uniform(0.02, 0.12)
        dx, dy = math.cos(angle) * length, math.sin(angle) * length
        stroke = (x, y, x + dx, y + dy, rng.uniform(0.7, 1.5), rng.uniform(0.35, 0.8))
        (strokes_light if rng.random() < 0.35 else strokes_dark).append(stroke)
    scratch_light = wrapped_strokes(size, strokes_light)
    scratch_dark = wrapped_strokes(size, strokes_dark)

    # Albedo.
    color = lerp(EARLY_WOOD, LATE_WOOD, tone)
    color = lerp(color, RING_LINE, ring_line * 0.75)
    color *= (0.97 + 0.06 * fine)[..., None]
    color = lerp(color, RING_LINE, hairlines * 0.45)
    color = lerp(color, STAIN, streaks * 0.35)
    color = lerp(color, RING_LINE, pores * 0.5)
    color *= (1 + tint)[..., None]
    color = lerp(color, STAIN, stain * 0.42)
    color = lerp(color, color * 0.85, seam_shadow * 0.4)
    bare = BARE_WOOD * (0.94 + 0.08 * (1 - ring_line))[..., None]  # a hint of grain in the bare wood
    color = lerp(color, bare, chips)
    color = lerp(color, BARE_WOOD * 0.95, scratch_light * 0.8)
    color = lerp(color, STAIN, scratch_dark * 0.75)
    color = lerp(color, SEAM, seam)
    albedo = np.clip(color, 0, 1)

    # Height: ring lines, pores, chips, scratches and seams sit below the varnished surface.
    height = (1.0 - 0.25 * ring_line - 0.1 * hairlines - 0.12 * pores - 0.45 * chips - 0.35 * (scratch_light + scratch_dark)
              - 0.9 * seam + 0.04 * fine)
    height = box_blur(height, 1)
    dx = np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)
    dy = np.roll(height, -1, axis=0) - np.roll(height, 1, axis=0)
    strength = size / 256
    normal = np.dstack([-dx * strength, dy * strength, np.ones_like(height)])  # +Y up (OpenGL / Godot)
    normal /= np.linalg.norm(normal, axis=2, keepdims=True)

    roughness = (0.58 + 0.06 * ring_line - 0.06 * stain + 0.3 * chips
                 + 0.2 * np.clip(scratch_light + scratch_dark, 0, 1) + 0.3 * seam)
    roughness = np.clip(roughness, 0, 1)
    return albedo, normal, roughness


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("output")
    parser.add_argument("--size", type=int, default=1024)
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args()
    os.makedirs(args.output, exist_ok=True)
    albedo, normal, roughness = generate(args.size, args.seed)
    Image.fromarray((albedo * 255).round().astype(np.uint8)).save(os.path.join(args.output, "wood_albedo.png"))
    Image.fromarray(((normal * 0.5 + 0.5) * 255).round().astype(np.uint8)).save(os.path.join(args.output, "wood_normal.png"))
    Image.fromarray((roughness * 255).round().astype(np.uint8)).save(os.path.join(args.output, "wood_roughness.png"))
    print("WROTE", args.output)


if __name__ == "__main__":
    main()
