class_name StrikeMaterial
extends Resource

## What a struck body is made of, and how strikes damage it (the strike model,
## documents/strike_model.md). A strike does 1 to 10 damage (2026-10-02), by how
## strong it was for this material: 1 at the threshold energy, 10 at the full
## energy and above, in a straight line between, rounded to a whole number. A
## strike below the threshold does none. Each damage type (blunt, slash) has its
## own threshold and full energy. A material that does not take slashes (stone)
## is struck blunt instead.
##
## Shared, read-only configuration: nothing about one particular struck body is
## stored here.

## A small number naming the material in recordings, whose columns hold
## numbers: 1 cloth, 2 wood, 3 stone.
@export var id := 0
## The name a readout shows.
@export var display_name := ""

@export_group("Blunt")
## The least energy a blunt strike must bring to do any damage; such a strike
## does the least (Strike.MIN_DAMAGE).
@export_range(0.0, 200.0, 0.1, "suffix:J") var blunt_threshold := 2.0
## The energy of a full-strength blunt strike: it, and anything harder, does the
## most damage (Strike.MAX_DAMAGE).
@export_range(0.0, 1000.0, 0.1, "suffix:J") var blunt_full_energy := 60.0

@export_group("Slash")
## Whether a sharp part's blow does slash damage here; if not, it is struck
## blunt.
@export var takes_slash := true
@export_range(0.0, 200.0, 0.1, "suffix:J") var slash_threshold := 2.0
@export_range(0.0, 1000.0, 0.1, "suffix:J") var slash_full_energy := 60.0


## Whether this material takes damage of `kind` (blunt always).
func takes(kind: Strike.Kind) -> bool:
	return takes_slash if kind == Strike.Kind.SLASH else true


## The least energy a strike of `kind` must bring to do any damage, in joules.
func threshold_of(kind: Strike.Kind) -> float:
	return slash_threshold if kind == Strike.Kind.SLASH else blunt_threshold


## The energy at which a strike of `kind` does the most damage, in joules.
func full_energy_of(kind: Strike.Kind) -> float:
	return slash_full_energy if kind == Strike.Kind.SLASH else blunt_full_energy


## The damage done by a strike of `kind` that brings `energy` joules: none below
## the threshold, else Strike.MIN_DAMAGE to Strike.MAX_DAMAGE by its strength,
## 0 at the threshold and 1 at the full energy.
func damage_of(kind: Strike.Kind, energy: float) -> int:
	var threshold := threshold_of(kind)
	if energy < threshold:
		return 0
	var span := full_energy_of(kind) - threshold
	var strength := clampf((energy - threshold) / span, 0.0, 1.0) if span > 0.0 else 1.0
	return roundi(lerpf(Strike.MIN_DAMAGE, Strike.MAX_DAMAGE, strength))
