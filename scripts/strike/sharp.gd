class_name Sharp
extends Marker3D

## A sharp part of a weapon (the strike model, documents/strike_model.md): an
## edge (a blade's edge, an axe's bit, a pickaxe's adze) or a point (a blade's
## tip, a pickaxe's pick). A strike that lands on it while it leads the blow is
## a slash instead of blunt, if the struck material takes slashes. Damage only:
## no type changes how anything moves (decided with the player, 2026-10-01).
##
## A direct child of the weapon's body. Its -Z is the way it works: the way an
## edge cuts, or the way a point points. An edge runs along its Y for `length`,
## centred on the node; a point has no length.

## How long the edge is, along the node's Y; 0 for a point.
@export_range(0.0, 2.0, 0.001, "suffix:m") var length := 0.0
## How far from the edge (or the point) a strike may land and still be this
## feature's.
@export_range(0.0, 0.1, 0.001, "suffix:m") var reach := 0.02
## How far the blow may be off the way it works and still count, in degrees.
## Forgiving (decided with the player, 2026-10-01): about 50 for an edge, 35 for
## a point.
@export_range(0.0, 90.0, 0.5, "suffix:°") var max_angle := 50.0


## How far off the way it works a blow is, in degrees, if the blow is this
## feature's. A blow landing at `point`, moving along `motion`, and meeting a
## surface whose normal (out of the struck body) is `normal`, is this feature's
## if it lands within reach and the feature works into that surface within
## max_angle of the blow's motion. All in the body's own space. -1 otherwise.
func fit(point: Vector3, motion: Vector3, normal: Vector3) -> float:
	var works := -transform.basis.z.normalized()
	if works.dot(normal) >= 0.0 or motion.length_squared() < 1e-12:
		return -1.0
	var at := transform.affine_inverse() * point
	var along := clampf(at.y, -length * 0.5, length * 0.5)
	if Vector3(at.x, at.y - along, at.z).length() > reach:
		return -1.0
	var off := rad_to_deg(works.angle_to(motion))
	return off if off <= max_angle else -1.0
