"""Writes assets/effects/fire/flame.png, the one texture the fire's flames and smoke sample.

Run from the repository root:
    python3 tools/effects/make_flame_texture.py

Red is one flame tongue: a round bulb low down that tapers to a point near the
top, brightest at its core and zero along every border, so the texture can
repeat without the tongue bleeding across its edges. Green is a soft noise that
tiles in both directions; the shader scrolls it up through the tongue and eats
the tongue away where it is low. Its values are spread evenly over 0-1, so
raising an erosion threshold removes a steady share of the flame. Blue is one
soft puff of smoke: round, its edge made lumpy by the same noise, and zero along
every border. The noise is seeded, so the file comes out the same every run.
"""

import os

import numpy as np
from PIL import Image

SIZE = 128
OUTPUT = os.path.join("assets", "effects", "fire", "flame.png")


def tongue(size: int) -> np.ndarray:
    # Height from the bottom edge and offset from the middle, both 0-1 of the image.
    y, x = np.mgrid[0:size, 0:size].astype(np.float64)
    height = 1.0 - (y + 0.5) / size
    across = np.abs((x + 0.5) / size - 0.5)

    bulb_height, bulb_radius, tip_height = 0.28, 0.23, 0.95
    # Below the bulb's middle: distance from the bulb's centre. Above it: how far
    # across the narrowing width, which closes to nothing at the tip.
    below = np.hypot(across, height - bulb_height) / bulb_radius
    rise = np.clip((height - bulb_height) / (tip_height - bulb_height), 0.0, 1.0)
    width = bulb_radius * (1.0 - rise) ** 0.65
    above = np.where(width > 1e-4, across / np.maximum(width, 1e-4), 2.0)
    distance = np.where(height < bulb_height, below, above)

    # Squared, so the core is flat across its middle rather than a ridge.
    core = np.clip(1.0 - distance ** 2, 0.0, 1.0) ** 1.6
    # A softer tip: the upper part fades along its height as well as across.
    core *= 1.0 - 0.6 * rise ** 2
    return core


def tiling_noise(size: int, seed: int) -> np.ndarray:
    # Random phases on a falling spectrum; an inverse FFT of any spectrum tiles.
    rng = np.random.default_rng(seed)
    fx = np.fft.fftfreq(size)[None, :]
    fy = np.fft.fftfreq(size)[:, None]
    frequency = np.hypot(fx, fy) * size
    amplitude = 1.0 / np.maximum(frequency, 1.0) ** 1.2
    # Blobs about a tongue wide down to a tenth of one: no single blob filling the
    # image, and no fine grain, which shimmers once mipmapped in the headset.
    amplitude[(frequency < 2.0) | (frequency > 20.0)] = 0.0
    phase = rng.uniform(0.0, 2.0 * np.pi, (size, size))
    field = np.real(np.fft.ifft2(amplitude * np.exp(1j * phase)))
    # Even out the histogram: rank each value, so 0-1 is evenly used.
    ranks = field.ravel().argsort().argsort()
    return (ranks / (ranks.size - 1)).reshape(size, size)


def puff(size: int, noise: np.ndarray) -> np.ndarray:
    y, x = np.mgrid[0:size, 0:size].astype(np.float64)
    # Distance from the middle, 1 just inside the borders.
    radius = np.hypot((x + 0.5) / size - 0.5, (y + 0.5) / size - 0.5) * 2.1
    density = np.clip(1.0 - radius + (noise - 0.5) * 0.35, 0.0, 1.0) ** 1.5
    # Whatever the noise does, nothing reaches the borders.
    return density * np.clip((1.0 - radius) / 0.15, 0.0, 1.0)


def main() -> None:
    red = tongue(SIZE)
    green = tiling_noise(SIZE, seed=7)
    blue = puff(SIZE, green)
    pixels = np.stack([red, green, blue], axis=-1)
    Image.fromarray(np.round(pixels * 255.0).astype(np.uint8), "RGB").save(OUTPUT)
    print("wrote", OUTPUT)


if __name__ == "__main__":
    main()
