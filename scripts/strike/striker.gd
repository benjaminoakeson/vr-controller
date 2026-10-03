class_name Striker
extends Node

## Makes its parent RigidBody3D strike what it hits (the strike model,
## documents/strike_model.md). Every physical object that can hit something
## carries one: the weapons, the loose props and both hands. A strike is blunt
## unless one of the body's Sharp features dealt it (_sharp_for).
##
## Each tick it reads the contacts its body reported in the last physics step.
## It only reads: it never moves the body or changes its settings. The body must
## report contacts (max_contacts_reported above 0). Godot's Jolt records each
## contact's points and normal where the step's collision test found them (at
## the step's start, or at the impact for a continuous-collision hit), and both
## bodies' velocities there before the solve. The closing speed is therefore the
## one the bodies met with, not what is left after the impact.
##
## When a contact counts: Jolt also reports contacts a couple of centimetres
## short that may never close. A contact touches if its gap at the step's start
## was no more than the distance the bodies closed by during the step, plus
## touch_margin. A pair (this body and one struck body) strikes on the tick it
## starts touching, if it closed at min_speed or faster and has not struck in
## the last rearm_time. It then stays engaged, and does not strike again, until
## it has come apart. Resting, pressing and sliding never strike.
##
## Which type: the best fitting of the body's Sharp children (an edge or point
## that the strike landed on while it led the blow); blunt if none fits.
##
## How hard: the closing speed at the middle of the pair's touching contacts,
## and the mass met there along the normal by the body and the hands holding
## it, as one rigid body. A hand welded on alone adds its mass and its turning
## inertia (the weld locks both); each of two hands holding a point adds its
## mass at its centre. The energy is ½ · mass · speed². The arm's push during
## the impact step is not counted.

## Emitted after the struck body has judged the strike.
signal struck(strike: Strike)

## Before the player's physical layer (DynamicPhysical, -100) and its grabs
## (HandGrab, -86), so Grabbable.holders still names the hands that held the
## body during the step; and before the recorder (-88), so it logs the strike in
## the same tick.
const PRIORITY := -110
const _META := &"striker"
## At most this many struck bodies are followed at once.
const _SLOTS := 8
const _NO_INERTIA := Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)

## Below this closing speed a touch does not strike.
@export_range(0.0, 5.0, 0.05, "suffix:m/s") var min_speed := 0.5
## A pair that came apart strikes again only this long after its last strike,
## so the chatter of a bounce is one strike.
@export_range(0.0, 1.0, 0.01, "suffix:s") var rearm_time := 0.1
## How far beyond what it closed by during the step a contact may still have
## been, and touch.
@export_range(0.0, 0.01, 0.0005, "suffix:m") var touch_margin := 0.001

## The body this marks.
var body: RigidBody3D
## Strikes so far.
var strikes := 0

var _clock := 0.0
# The body's sharp features: its Sharp children.
var _sharps: Array[Sharp] = []
# The body's pose when the step whose contacts are read began.
var _last_transform := Transform3D.IDENTITY
# Per followed struck body (slot): its Strikeable and that one's instance id (0
# for a free slot), whether the pair is engaged, and when it last struck (on
# _clock).
var _targets: Array[Strikeable] = []
var _ids := PackedInt64Array()
var _engaged := PackedByteArray()
var _struck_at := PackedFloat64Array()
# Per slot, this tick's touching contacts: how many, and the sums of their
# points on this body and on the struck one, of their normals and of their
# relative velocities; and the least gap.
var _counts := PackedInt32Array()
var _points := PackedVector3Array()
var _surfaces := PackedVector3Array()
var _normals := PackedVector3Array()
var _velocities := PackedVector3Array()
var _gaps := PackedFloat32Array()


func _enter_tree() -> void:
	body = get_parent() as RigidBody3D
	if body == null:
		push_error("Striker: its parent must be a RigidBody3D.")
		return
	body.set_meta(_META, self)


func _ready() -> void:
	if body == null:
		set_physics_process(false)
		return
	# Once everything is ready: a hand's drive turns its reporting on in its own
	# _ready, after this one's.
	_check_reporting.call_deferred()
	process_physics_priority = PRIORITY
	_targets.resize(_SLOTS)
	_ids.resize(_SLOTS)
	_engaged.resize(_SLOTS)
	_struck_at.resize(_SLOTS)
	_counts.resize(_SLOTS)
	_points.resize(_SLOTS)
	_surfaces.resize(_SLOTS)
	_normals.resize(_SLOTS)
	_velocities.resize(_SLOTS)
	_gaps.resize(_SLOTS)
	_ids.fill(0)
	_engaged.fill(0)
	_struck_at.fill(-INF)
	_last_transform = body.global_transform
	for child in body.get_children():
		if child is Sharp:
			_sharps.append(child)


func _exit_tree() -> void:
	if body != null and body.has_meta(_META):
		body.remove_meta(_META)


func _check_reporting() -> void:
	if body.max_contacts_reported <= 0:
		push_warning("Striker: %s reports no contacts (max_contacts_reported), so it cannot strike." % body.name)


## The Striker marking `object`, or null if it has none.
static func of(object: Object) -> Striker:
	if object == null or not object.has_meta(_META):
		return null
	return object.get_meta(_META) as Striker


func _physics_process(delta: float) -> void:
	_clock += delta
	var state := PhysicsServer3D.body_get_direct_state(body.get_rid())
	var count := state.get_contact_count() if state != null else 0
	if count == 0 or state.sleeping or body.freeze:
		# Nothing can strike now; every pair counts as apart, so one that
		# touches again later can strike.
		_engaged.fill(0)
	else:
		_gather(state, count)
		_judge(state)
	_last_transform = body.global_transform


## Whether a contact touches (see above): its gap at the step's start (m) was no
## more than the distance the bodies closed by during the step (`closing`, m/s,
## over `step`, s), plus `margin` (m). Jolt also reports contacts a couple of
## centimetres short that may never close. A felled piece of a tree reads its
## impacts this way too (FelledTree, fall damage).
static func touches(gap: float, closing: float, step: float, margin: float) -> bool:
	return gap <= maxf(closing, 0.0) * step + margin


# Sums each struck body's touching contacts into its slot.
func _gather(state: PhysicsDirectBodyState3D, count: int) -> void:
	_counts.fill(0)
	_points.fill(Vector3.ZERO)
	_surfaces.fill(Vector3.ZERO)
	_normals.fill(Vector3.ZERO)
	_velocities.fill(Vector3.ZERO)
	_gaps.fill(INF)
	for i in count:
		var target := Strikeable.of(state.get_contact_collider_object(i))
		if target == null:
			continue
		# The normal points out of the struck body, toward this one.
		var normal := state.get_contact_local_normal(i)
		var point := state.get_contact_local_position(i)
		var surface := state.get_contact_collider_position(i)
		var gap := (point - surface).dot(normal)
		var relative := state.get_contact_local_velocity_at_position(i) \
				- state.get_contact_collider_velocity_at_position(i)
		if not touches(gap, -relative.dot(normal), state.step, touch_margin):
			continue
		var slot := _slot_of(target)
		if slot < 0:
			continue
		_counts[slot] += 1
		_points[slot] = _points[slot] + point
		_surfaces[slot] = _surfaces[slot] + surface
		_normals[slot] = _normals[slot] + normal
		_velocities[slot] = _velocities[slot] + relative
		_gaps[slot] = minf(_gaps[slot], gap)


# The slot following `target`, taken for it if it has none; -1 if all are busy.
func _slot_of(target: Strikeable) -> int:
	var id := target.get_instance_id()
	var free := -1
	for slot in _SLOTS:
		if _ids[slot] == id:
			return slot
		if free < 0 and _counts[slot] == 0 and (_ids[slot] == 0
				or (_engaged[slot] == 0 and _clock - _struck_at[slot] >= rearm_time)):
			free = slot
	if free >= 0:
		_ids[free] = id
		_targets[free] = target
		_engaged[free] = 0
		_struck_at[free] = -INF
	return free


# Strikes each struck body this body has started touching, fast enough.
func _judge(state: PhysicsDirectBodyState3D) -> void:
	for slot in _SLOTS:
		if _ids[slot] == 0:
			continue
		var count := _counts[slot]
		if count == 0:
			_engaged[slot] = 0
			continue
		if _engaged[slot] == 1:
			continue
		_engaged[slot] = 1
		if _normals[slot].length_squared() < 1e-12:
			continue
		var normal := _normals[slot].normalized()
		# A rigid body's velocity is linear in position, so the mean of the
		# contacts' velocities is the velocity at their middle.
		var velocity := _velocities[slot] / count
		var speed := -velocity.dot(normal)
		if speed < min_speed or _clock - _struck_at[slot] < rearm_time:
			continue
		_struck_at[slot] = _clock
		_strike(state, _targets[slot], _points[slot] / count, _surfaces[slot] / count, normal,
				velocity, _gaps[slot])


func _strike(state: PhysicsDirectBodyState3D, target: Strikeable, point: Vector3,
		surface: Vector3, normal: Vector3, velocity: Vector3, gap: float) -> void:
	var hands := _holding_hands()
	var strike := Strike.new()
	var speed := -velocity.dot(normal)
	strike.striker = body
	strike.target = target.object
	strike.feature = _sharp_for(point, normal, velocity)
	if strike.feature != null:
		strike.kind = Strike.Kind.SLASH
	strike.point = surface
	strike.normal = normal
	strike.speed = speed
	strike.gap = gap
	for hand in hands:
		strike.held_by |= 1 << hand.drive.side
	strike.effective_mass = _effective_mass(state, point, normal, hands)
	strike.energy = 0.5 * strike.effective_mass * speed * speed
	strikes += 1
	target.receive(strike)
	struck.emit(strike)


# The Sharp feature that dealt a strike landing at `point` (on this body, in
# world space) on a surface with `normal`, closing with `velocity`: the best
# fitting one (Sharp.fit), or null for a blunt part. A contact is found where
# the step's collision test saw it: at the step's start for most contacts, at
# the impact (about where the body stopped) for a continuous-collision hit. So
# both poses are tried and the better fit counts.
func _sharp_for(point: Vector3, normal: Vector3, velocity: Vector3) -> Sharp:
	var best: Sharp = null
	var best_off := INF
	for pose: Transform3D in [_last_transform, body.global_transform]:
		var into := pose.basis.transposed()
		var at := pose.affine_inverse() * point
		var motion := into * velocity
		var across := into * normal
		for sharp in _sharps:
			var off := sharp.fit(at, motion, across)
			if off >= 0.0 and off < best_off:
				best_off = off
				best = sharp
	return best


# The hands holding the body: those of its Grabbable that have it in hand.
func _holding_hands() -> Array[HandGrab]:
	var hands: Array[HandGrab] = []
	var grabbable := Grabbable.of(body)
	if grabbable != null:
		for hand in grabbable.holders:
			if hand.state == HandGrab.State.HOLDING:
				hands.append(hand)
	return hands


# The mass met at `point` along `normal` (world space, where the step's
# collision test found them) by the body and `hands`, as one rigid body, in kg.
# Worked in the body's own space, where the welded hands sit still, after
# taking the point and normal into it from the pose they were found at.
func _effective_mass(state: PhysicsDirectBodyState3D, point: Vector3, normal: Vector3,
		hands: Array[HandGrab]) -> float:
	var basis := body.global_basis
	var to_local := body.global_transform.affine_inverse()
	# Each part: its mass, its centre of mass and its turning inertia about that
	# centre, in the body's space.
	var masses: Array[float] = [1.0 / state.inverse_mass]
	var centres: Array[Vector3] = [state.center_of_mass_local]
	var inertias: Array[Basis] = [basis.transposed() * state.inverse_inertia_tensor.inverse() * basis]
	for hand in hands:
		var hand_body := hand.drive.hand
		var hand_state := PhysicsServer3D.body_get_direct_state(hand_body.get_rid())
		masses.append(1.0 / hand_state.inverse_mass)
		centres.append(to_local * (hand_body.global_transform * hand_state.center_of_mass_local))
		inertias.append(basis.transposed() * hand_state.inverse_inertia_tensor.inverse() * basis
				if hand.hold_kind == HandGrab.Hold.WELD else _NO_INERTIA)
	var total := 0.0
	var weighted := Vector3.ZERO
	for i in masses.size():
		total += masses[i]
		weighted += centres[i] * masses[i]
	var centre := weighted / total
	var inertia := _NO_INERTIA
	for i in masses.size():
		inertia = _sum(inertia, _sum(inertias[i], _point_inertia(masses[i], centres[i] - centre)))
	var arm := _last_transform.affine_inverse() * point - centre
	var along := (_last_transform.basis.transposed() * normal).normalized()
	var turn := arm.cross(along)
	return 1.0 / (1.0 / total + turn.dot(inertia.inverse() * turn))


# The turning inertia of a point mass `mass` at `offset`, about the origin.
static func _point_inertia(mass: float, offset: Vector3) -> Basis:
	var square := offset.length_squared()
	return Basis(
			Vector3(square - offset.x * offset.x, -offset.y * offset.x, -offset.z * offset.x),
			Vector3(-offset.x * offset.y, square - offset.y * offset.y, -offset.z * offset.y),
			Vector3(-offset.x * offset.z, -offset.y * offset.z, square - offset.z * offset.z)) * mass


static func _sum(a: Basis, b: Basis) -> Basis:
	return Basis(a.x + b.x, a.y + b.y, a.z + b.z)
