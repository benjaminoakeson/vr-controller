class_name FelledTree
extends RigidBody3D

## A part of a tree cut off it at a segment line (chopping, 2026-10-02): the top
## above where it was felled, a branch chopped off, or a log bucked off a felled
## part (ProceduralTree.sever). One rigid body, whose wood is a ProceduralTree
## grown from its own piece of the skeleton (`piece`), drawn with the tree's three
## detail levels and colliding through this body. It starts where it was on the
## tree and falls under gravity alone; a felled top first tips over the stump's
## edge the way it was felled, hinged to it. It stays where it lands.
##
## It is chopped as the tree was, at every segment line it carries: its wood
## takes strikes (a Strikeable of the tree's material), it has a TreeChop, with
## the tree's settings and the lines it carried as they were, and a readout
## (TreeChopDisplay). Its twigs and leaves break as a tree's do, and against its
## surroundings as it falls (ProceduralTree).
##
## It meets everything (2026-10-02, after the first headset try): it is on the
## Static layer, as the stump and every standing tree are, so the player's body,
## the hands and the ground sense meet it as part of the level, and it scans
## every layer props do. It may knock the player about as it falls.
##
## It must be on a layer. With no layer of its own, other bodies met it only
## through its mask, and Jolt then left its mass out of their contacts: a 2 kg
## box dropped on the 1,336 kg top drove it into the floor at the box's own
## speed, whatever the top weighed.
##
## Fall damage (2026-10-03): it reads its contacts every tick, and each touching
## one with something solid (on the Static layer: the floor, a stump, a standing
## tree, another piece) closing at its chop's impact_speed or faster marks the
## hit branch's nearest line to break (TreeChop.impact), which then breaks
## (TreeChop.break_next). Props, held items, hands and the player strike it
## instead.

const STATIC_LAYER := 1
## What it meets: what props meet (the Static, Dynamic, Held, Player, Hands and
## Enemy layers).
const MASK := 1 | 2 | 8 | 16 | 32 | 256
## The least spin that carries the centre of mass over the stump's edge, times
## this, starts it over: enough to go, and slow at first, as a felled tree is.
const TIP_MARGIN := 1.25
## The spin it starts with if its centre of mass already hangs over the edge.
const LEANING_SPIN := 0.1
## How far it turns over the stump's edge held to it there, as by the hinge of
## wood a feller leaves, before the hinge breaks and it falls as it will
## (2026-10-02: a top leaning to one side rolled off along the edge, 50° from
## the way it was felled, without it).
const HINGE_BREAK_DEG := 45.0
## Its spin's damping, per second, added to the world's: the rolling resistance
## that stops a log or a limb rolling on along the ground (2026-10-02: with
## none, a limb cut off rolled on at 0.3 m/s for seconds).
const ROLLING_DAMP := 1.0
## How many contacts the engine reports for a piece that can be chopped, for its
## fall damage. When there are more, the engine keeps the deepest and drops the
## shallowest, a fresh impact's. A 75 kg log lying among the other pieces of a
## felled oak reported 30, so this keeps twice that room.
const MAX_CONTACTS := 64
## Before Striker's, so its contacts are read before a slash can cut it that tick.
const PRIORITY := Striker.PRIORITY - 10
## A contact touches if its gap is no more than this beyond what the bodies
## closed by in the step, in metres (as Striker's touch_margin).
const TOUCH_MARGIN := 0.001

var species: TreeSpecies
## Its wood: the piece of the tree it is.
var piece: ProceduralTree
## What chops it at its segment lines.
var chop: TreeChop
## Its shape: the piece of the tree's skeleton, in the tree's space.
var skeleton: TreeSkeleton:
	get:
		return piece.skeleton if piece else null

var _entry: TreeCache.Entry
## The tree's turn and size, from the tree's space to this body's.
var _variation := Transform3D.IDENTITY
var _material: StrikeMaterial
# How it is to tip over, until its first physics tick: the way it falls, the
# middle of the cut and the cut's radius, in the world.
var _toward := Vector3.ZERO
var _cut_centre := Vector3.ZERO
var _cut_radius := 0.0
# What it is hinged to while it tips (the stump's body), the hinge, and how it
# was turned when the hinge was made.
var _hinged_to: PhysicsBody3D
var _hinge: HingeJoint3D
var _hinged_basis := Basis.IDENTITY
# The physics tick it was last cut in: its contacts that tick were read from
# its shapes before the cut.
var _reshaped_tick := -1


## What it is: the tree's species, its built piece, the tree's turn and size,
## and what its wood is made of for strikes (none: it cannot be chopped). Call
## before it enters the tree.
func setup(tree_species: TreeSpecies, entry: TreeCache.Entry, variation: Transform3D,
		material: StrikeMaterial = null) -> void:
	species = tree_species
	_entry = entry
	_variation = variation
	_material = material


## Starts it tipping over `toward` (level, in the world) over the edge of the cut
## on that side, at its first physics tick, when its mass and inertia are known;
## hinged there to `stump` (the body it was cut from), if given, until it has
## turned HINGE_BREAK_DEG.
func tip_over(toward: Vector3, cut_centre: Vector3, cut_radius: float, stump: PhysicsBody3D = null) -> void:
	_toward = Vector3(toward.x, 0.0, toward.z).normalized()
	_cut_centre = cut_centre
	_cut_radius = cut_radius
	_hinged_to = stump


## How many leaf clusters it has left.
func leaves_left() -> int:
	return piece.leaves_left()


## Its centre of mass in the world, as the engine has it: in the tick it is cut,
## already where its new shapes put it.
func centre_of_mass() -> Vector3:
	return global_position + PhysicsServer3D.body_get_direct_state(get_rid()).center_of_mass


func _ready() -> void:
	name = "FelledTree"
	collision_layer = STATIC_LAYER
	collision_mask = MASK
	angular_damp = ROLLING_DAMP
	# A thin piece falls fast enough to pass through the level's thin floor
	# between two ticks, as weapons would.
	continuous_cd = true
	piece = ProceduralTree.new()
	piece.name = "Wood"
	if _material:
		var strikeable := Strikeable.new()
		strikeable.material = _material
		chop = TreeChop.new()
		chop.strikeable = strikeable
		var display := TreeChopDisplay.new()
		display.chop = chop
		piece.add_child(strikeable)
		piece.add_child(chop)
		piece.add_child(display)
		# Jolt reports contacts without contact_monitor.
		max_contacts_reported = MAX_CONTACTS
		process_physics_priority = PRIORITY
	piece.grow_piece(species, _entry, _variation, self)
	piece.reshaped.connect(_on_reshaped)
	add_child(piece)
	_weigh()


## Its mass, again whenever it is cut: the sum of its segments of wood
## (TreeSkeleton.wood_segments), trunk_segment_mass_kg each on its trunk and
## branch_segment_mass_kg each on any other branch but a twig, which weighs
## nothing (so a twig breaking off leaves it as heavy); at least 1 kg.
func _weigh() -> void:
	var min_radius := species.collision_min_radius_m
	var total := 0.0
	for branch in skeleton.branch_count():
		if skeleton.is_twig(branch, min_radius):
			continue
		var each: float = species.trunk_segment_mass_kg if skeleton.branch_depth[branch] == 0 \
				else species.branch_segment_mass_kg
		total += each * skeleton.wood_segments(branch, min_radius)
	mass = maxf(total, 1.0)


func _on_reshaped() -> void:
	_reshaped_tick = Engine.get_physics_frames()
	_weigh()


func _physics_process(_delta: float) -> void:
	if _toward != Vector3.ZERO and _start_tipping(PhysicsServer3D.body_get_direct_state(get_rid())):
		_toward = Vector3.ZERO
	if _hinge and (_hinged_basis.inverse() * global_basis).get_rotation_quaternion().get_angle() \
			> deg_to_rad(HINGE_BREAK_DEG):
		_hinge.queue_free()
		_hinge = null
	if chop:
		_read_impacts()
		chop.break_next()


## Marks the branch lines its hard hits on something solid break at (fall
## damage, see above), reading every contact before any cut. Not while asleep or
## frozen, once it is lone, or in a tick it was cut in (those contacts are its
## shapes' from before the cut).
func _read_impacts() -> void:
	if sleeping or freeze or chop.health != null or _reshaped_tick == Engine.get_physics_frames():
		return
	var state := PhysicsServer3D.body_get_direct_state(get_rid())
	for i in state.get_contact_count():
		# The normal points out of what it hit, toward this body.
		var normal := state.get_contact_local_normal(i)
		var relative := state.get_contact_local_velocity_at_position(i) \
				- state.get_contact_collider_velocity_at_position(i)
		var closing := -relative.dot(normal)
		if closing < chop.impact_speed:
			continue
		var other := state.get_contact_collider_object(i)
		var layer: int = other.get("collision_layer") if other and "collision_layer" in other else 0
		if not layer & STATIC_LAYER:
			continue
		var point := state.get_contact_local_position(i)
		if not Striker.touches((point - state.get_contact_collider_position(i)).dot(normal), closing,
				state.step, TOUCH_MARGIN):
			continue
		chop.impact(point, closing, piece.branch_of_shape(state.get_contact_local_shape(i)))


## Spins it about the cut's edge on the falling side just fast enough, with the
## margin, to lift its centre of mass over that edge; gravity does the rest.
## Hinges it there, if it has a stump. False, to try again next tick, until the
## engine has worked out its inertia.
func _start_tipping(state: PhysicsDirectBodyState3D) -> bool:
	var axis := Vector3.UP.cross(_toward).normalized()
	var inverse_inertia := axis.dot(state.inverse_inertia_tensor * axis)
	if inverse_inertia <= 0.0:
		return false
	var pivot := _cut_centre + _toward * _cut_radius
	var arm := global_position + state.center_of_mass - pivot
	var across := arm - axis * arm.dot(axis)
	# How far the centre of mass must rise to stand right over the edge.
	var lift := across.length() - across.y
	var inertia_about_edge := 1.0 / inverse_inertia + mass * across.length_squared()
	var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
	var spin := LEANING_SPIN
	if lift > 0.0 and across.dot(_toward) < 0.0:
		spin = maxf(sqrt(2.0 * mass * gravity * lift / inertia_about_edge) * TIP_MARGIN, LEANING_SPIN)
	angular_velocity = axis * spin
	linear_velocity = (axis * spin).cross(arm)
	if is_instance_valid(_hinged_to) and _hinged_to.is_inside_tree():
		_hinge_at(pivot, axis)
	return true


## Hinges it to its stump at `pivot`, turning only about `axis`. The hinge
## stays where it was made, whatever this body does, and the two don't collide
## while it holds.
func _hinge_at(pivot: Vector3, axis: Vector3) -> void:
	_hinge = HingeJoint3D.new()
	_hinge.top_level = true
	add_child(_hinge)
	# A hinge turns about its Z.
	_hinge.global_transform = Transform3D(Basis(Vector3.UP, _toward, axis), pivot)
	_hinge.node_a = _hinge.get_path_to(self)
	_hinge.node_b = _hinge.get_path_to(_hinged_to)
	_hinged_basis = global_basis
