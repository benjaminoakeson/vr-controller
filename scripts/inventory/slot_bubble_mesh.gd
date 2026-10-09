@tool
class_name SlotBubbleMesh
extends PrimitiveMesh

## An inventory slot's glass as a flat bubble (2026-10-07, at the player's
## request: "more like a flat bubble... length extended backwards to give the
## slot depth but not a lot"): a superellipsoid one unit across each way (from
## -0.5 to 0.5), which the slot scales to its side and depth. Seen face on it is
## a rounded square; its faces are nearly flat and its rim rounds over between
## them.
##
## The triangles run from the back (-Z) to the front (+Z): drawn double-sided in
## that order, the far wall blends first and the near wall over it, which is
## right for a bubble always turned to face the viewer (InventorySlot), in one
## draw call.

## How square the outline is: 1 a circle, toward 0 a square (0.3 matches a
## rounded square whose corners are a third of its half side).
@export_range(0.05, 1.0, 0.01) var outline_exponent := 0.3:
	set(value):
		outline_exponent = value
		request_update()
## How flat the faces are: 1 an ellipse's profile, toward 0 flat faces with a
## tight rim.
@export_range(0.05, 1.0, 0.01) var profile_exponent := 0.5:
	set(value):
		profile_exponent = value
		request_update()
## Points round the outline.
@export_range(8, 128, 1) var segments := 48:
	set(value):
		segments = value
		request_update()
## Rings from the back's middle to the front's.
@export_range(4, 64, 1) var rings := 24:
	set(value):
		rings = value
		request_update()


## The outline_exponent whose outline matches, at its corners, a rounded square
## whose corners' radius is `rounding` of its half side: 0 square (the
## exponent at its least), 1 a circle (1). Matched where the corner crosses the
## diagonal: a third rounds to about 0.3.
static func outline_exponent_for(rounding: float) -> float:
	var diagonal := 1.0 - clampf(rounding, 0.0, 1.0) * (1.0 - sqrt(0.5))
	return clampf(-2.0 * log(diagonal) / log(2.0), 0.05, 1.0)


## How far along the diagonal from the middle the outline of exponent `e`
## reaches, against the half side.
static func diagonal_reach(e: float) -> float:
	return pow(2.0, -e * 0.5)


func _create_mesh_array() -> Array:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for ring in rings + 1:
		# Spaced closer toward the rim, where the profile turns fastest.
		var u := 2.0 * ring / rings - 1.0
		var phi := signf(u) * u * u * PI * 0.5
		for segment in segments:
			var theta := TAU * segment / segments - PI
			vertices.append(Vector3(
					_cos(phi, profile_exponent) * _cos(theta, outline_exponent),
					_cos(phi, profile_exponent) * _sin(theta, outline_exponent),
					_sin(phi, profile_exponent)) * 0.5)
			normals.append(Vector3(
					_cos(phi, 2.0 - profile_exponent) * _cos(theta, 2.0 - outline_exponent),
					_cos(phi, 2.0 - profile_exponent) * _sin(theta, 2.0 - outline_exponent),
					_sin(phi, 2.0 - profile_exponent)).normalized())
	for ring in rings:
		for segment in segments:
			var a := ring * segments + segment
			var b := ring * segments + (segment + 1) % segments
			var c := a + segments
			var d := b + segments
			indices.append_array([a, c, b, b, c, d])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	return arrays


# The superellipsoid's signed powers: sign(cos w) |cos w|^e, and of sin.
static func _cos(w: float, e: float) -> float:
	var c := cos(w)
	return signf(c) * pow(absf(c), e)


static func _sin(w: float, e: float) -> float:
	var s := sin(w)
	return signf(s) * pow(absf(s), e)
