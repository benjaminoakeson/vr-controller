class_name RenderLayers

const WORLD := 1
const MIRROR_SURFACE := 2

static func mask(layer: int) -> int:
	return 1 << (layer - 1)
