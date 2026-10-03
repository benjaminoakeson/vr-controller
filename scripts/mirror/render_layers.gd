class_name RenderLayers

const WORLD := 1
const MIRROR_SURFACE := 2
## Drawn only by the mirror's reflection cameras, never by the player's own
## camera: the player's head and neck, which their eyes sit inside.
const MIRROR_ONLY := 3
## Fire smoke (scenes/effects/fire.tscn): every camera draws it, but the fire's
## own light leaves it out (its light_cull_mask), as it sits too close to light it.
const FIRE_SMOKE := 4

static func mask(layer: int) -> int:
	return 1 << (layer - 1)
