class_name FireLight
extends OmniLight3D

## The light a fire casts, flickering (2026-10-03). Its energy wavers about the
## energy it starts with by three sine waves at unrelated rates, which read as
## an irregular flicker without allocating or sampling noise. Each fire starts
## at a random point in the waves, so neighbouring fires never flicker together.
## Kept gentle and slow on purpose: a fast, deep flicker filling the view is a
## comfort risk in the headset. It casts no shadow, and fades out with distance
## (Light3D's distance fade), which is what keeps many fires affordable.

## How far the energy swings either way, as a share of the starting energy.
@export_range(0.0, 0.5, 0.01) var flicker := 0.15
## How fast the flicker runs: 1 is the base rates of about 1, 2 and 4 Hz.
@export_range(0.1, 3.0, 0.05) var speed := 1.0

var _base_energy := 0.0
var _time := 0.0


func _ready() -> void:
	_base_energy = light_energy
	_time = randf() * 100.0


func _process(delta: float) -> void:
	_time += delta * speed
	var waver := 0.5 * sin(_time * 6.9) + 0.3 * sin(_time * 13.3 + 1.7) + 0.2 * sin(_time * 24.1 + 0.4)
	light_energy = _base_energy * (1.0 + flicker * waver)
