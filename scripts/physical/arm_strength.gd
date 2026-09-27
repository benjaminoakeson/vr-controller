class_name ArmStrength
extends RefCounted

## Where one arm's strength lets its hand be: the static skeleton's hand shaped
## by a simulated torque budget at the shoulder and the wrist for what the hand
## holds (decided 2026-09-26: weight comes from a simulated strength model, the
## arm is posed, and a load strains the arm but never makes it give way).
##
## Every tick it takes the tracked wrist and hand rotation and works out a
## command for the hand, in two steps:
##
## - Dip. The shoulder and the wrist each hold the weight the arm bears with a
##   torque (that weight times its horizontal lever from the joint), and bend
##   toward hanging by that torque over their stiffness: the hand about the
##   wrist, then the whole arm about the shoulder, the hand keeping its turn.
##   Every load shows, more the further out it is held, and none makes the arm
##   give way (giving way to where the torque fit dropped 10 kg held out by
##   0.46 m, and the player felt the arm give up, 2026-09-26). The elbow is not
##   modelled: its lever is never longer than the shoulder's.
## - Lag. A follower chases the dipped pose: there this tick while the joints
##   can supply the acceleration on top of holding, otherwise as fast as they
##   can, and never toward it faster than it could stop there (braking with
##   the joints' eccentric strength), so a heavy load lags a fast move and does
##   not swing past. Holding takes at most `hold_share` of a joint's strength,
##   so even an overloaded arm still moves, slowly; but it cannot raise a load
##   heavier than a joint can hold in its pose, which stays on the ground.
##
## Only what the hand holds costs strength (the player's real arm already moves
## the real arm): with nothing held the command is the target exactly and the
## arm is 1:1. Letting go, it is the target at once, and the hand's drive
## closes the gap as it closes any jump of its target, without overshooting
## (a follower catching up smoothly but fast ran the hand 18 mm past after
## letting go of 10 kg, 2026-09-26).
## Positions are the wrist (the arm's end). Units: m, kg, s, N·m, rad.

const GRAVITY := 9.81
const SHOULDER := 0
const WRIST := 1

## Strength of the shoulder and the wrist for what the hand holds, N·m.
var strength := Vector2(80.0, 15.0)
## Each joint dips by the torque it holds over this, N·m/rad.
var stiffness := Vector2(600.0, 100.0)
## Share of a joint's strength holding may take; the rest is kept for moving.
var hold_share := 0.8
## Share of the wrist's strength always left for turning the hand.
var turn_reserve := 0.1
## Muscles resisting a motion (braking, lowering a load) are this much
## stronger than when producing one (about 1.2 to 1.6 in people).
var eccentric := 1.4
## Limits on any motion (tracking glitches), whatever is held.
var free_acceleration := 400.0 # m/s²
var free_angular_acceleration := 3000.0 # rad/s²
var max_speed := 10.0 # m/s
var max_spin := 40.0 # rad/s
## Braking uses this share of the limit, leaving margin so it never
## overshoots.
var brake_margin := 0.85
## The command: the wrist, its velocity and acceleration, and the hand's
## rotation.
var wrist := Vector3.ZERO
var velocity := Vector3.ZERO
var acceleration := Vector3.ZERO
var hand_basis := Basis.IDENTITY
## How far the shoulder (x) and the wrist (y) dip under the weight the arm
## bears, radians, and the torque each holds, N·m, in the tracked pose.
var sag := Vector2.ZERO
var holding := Vector2.ZERO

# What the hand holds, in hand axes from the wrist: mass (kg), centre, and
# inertia about that centre; and the share of its weight the arm bears.
var _load_mass := 0.0
var _load_centre := Vector3.ZERO
var _load_inertia := Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
var _borne := 0.0
var _spin := Vector3.ZERO
var _last_target := Vector3.ZERO
var _last_basis := Basis.IDENTITY
var _started := false
# In the follower's pose, per joint: the torque holding the borne weight
# takes, and the load's first moment about it (torque per unit acceleration
# is moment x acceleration); the load's turning inertia about the wrist; and
# whether the arm can raise the load at all.
var _hold: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _moment: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _turn_inertia := Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
var _can_lift := true


## What the hand holds: mass (kg), its centre and its inertia about that
## centre, both in hand axes from the wrist, and the share of its weight the
## arm bears (0 while it rests on something, 1 clear of everything). Zero mass
## for nothing.
func carry(mass: float, centre: Vector3, inertia: Basis, borne := 1.0) -> void:
	_load_mass = mass
	_load_centre = centre
	_load_inertia = inertia
	_borne = borne if mass > 0.0 else 0.0


## Whether the command differs from the target: whether the hand holds
## anything.
func shaping() -> bool:
	return _load_mass > 0.0


## Puts the command on the target, at rest.
func reset(wrist_target: Vector3, hand_target: Basis) -> void:
	wrist = wrist_target
	velocity = Vector3.ZERO
	acceleration = Vector3.ZERO
	hand_basis = hand_target.orthonormalized()
	_spin = Vector3.ZERO
	_last_target = wrist_target
	_last_basis = hand_basis
	_started = true


## Moves the command by `offset`, keeping its motion: the player was moved
## (recentred, respawned), and the arm goes with them.
func shift(offset: Vector3) -> void:
	wrist += offset
	_last_target += offset


## Shapes this tick's command from the tracked wrist and hand rotation.
func update(shoulder: Vector3, wrist_target: Vector3, hand_target: Basis, delta: float) -> void:
	if not _started:
		reset(wrist_target, hand_target)
	var dipped := _dipped(shoulder, wrist_target, hand_target.orthonormalized())
	_measure(shoulder)
	_follow_position(dipped.origin, delta)
	_follow_rotation(dipped.basis, delta)


## The tracked pose dipped under the weight the arm bears: the hand about the
## wrist, then the arm about the shoulder (the hand keeping its turn), each by
## the torque it holds over its stiffness, never past hanging.
func _dipped(shoulder: Vector3, at_wrist: Vector3, basis: Basis) -> Transform3D:
	var weight := _load_mass * _borne * GRAVITY
	var lever := basis * _load_centre
	holding.y = _horizontal(lever) * weight
	sag.y = minf(holding.y / stiffness.y, lever.angle_to(Vector3.DOWN))
	var hand := _toward_hanging(lever, sag.y) * basis
	var arm := at_wrist + hand * _load_centre - shoulder
	holding.x = _horizontal(arm) * weight
	sag.x = minf(holding.x / stiffness.x, arm.angle_to(Vector3.DOWN))
	if sag.x <= 0.0:
		return Transform3D(hand, at_wrist)
	return Transform3D(hand, shoulder + _toward_hanging(arm, sag.x) * (at_wrist - shoulder))


## The rotation turning `lever` toward hanging by `angle`.
static func _toward_hanging(lever: Vector3, angle: float) -> Basis:
	var axis := lever.cross(Vector3.DOWN)
	if angle <= 0.0 or axis.length_squared() < 1e-12:
		return Basis.IDENTITY
	return Basis(axis.normalized(), angle)


## What the joints need in the follower's pose, and whether the arm can raise
## the load: lifting it bears all its weight, even off a support.
func _measure(shoulder: Vector3) -> void:
	var load_at := wrist + hand_basis * _load_centre
	_moment[SHOULDER] = (load_at - shoulder) * _load_mass
	_moment[WRIST] = (load_at - wrist) * _load_mass
	_can_lift = true
	for joint in 2:
		_hold[joint] = _moment[joint].cross(Vector3.UP * GRAVITY) * _borne
		if _horizontal(_moment[joint]) * GRAVITY > strength[joint]:
			_can_lift = false
	_turn_inertia = add(to_world(_load_inertia, hand_basis), point_inertia(load_at - wrist, _load_mass))


## Moves the follower toward `target`: this tick within the arm's strength,
## otherwise at the largest acceleration it has, never faster toward it than
## it could stop there, and never up while the arm cannot lift the load.
## Holding nothing, it is the target, moving as it does, however it jumps.
func _follow_position(target: Vector3, delta: float) -> void:
	var target_velocity := (target - _last_target) / delta
	_last_target = target
	if not shaping():
		acceleration = (target_velocity - velocity) / delta
		velocity = target_velocity
		wrist = target
		return
	# Across the line to the target it moves as the target does; along it, no
	# faster than it could still stop at the target, and at most the rest of
	# the way this tick.
	var gap := target - wrist
	var distance := gap.length()
	var wanted := target_velocity
	if distance > 1e-7:
		var toward := gap / distance
		var braking := _acceleration_limit(-toward, true) * brake_margin
		var along := minf(target_velocity.dot(toward) + distance / delta,
				_braking_speed(distance, braking, delta))
		wanted = target_velocity.slide(toward) + toward * along
	if not _can_lift:
		wanted.y = minf(wanted.y, 0.0)
	wanted = wanted.limit_length(max_speed)
	var change := (wanted - velocity) / delta
	var size := change.length()
	acceleration = Vector3.ZERO
	if size > 1e-9:
		var direction := change / size
		acceleration = direction * minf(size, _acceleration_limit(direction, direction.dot(velocity) < 0.0))
	velocity += acceleration * delta
	wrist += velocity * delta


## Turns the follower toward `target` as the wrist's strength allows.
func _follow_rotation(target: Basis, delta: float) -> void:
	var target_spin := rotation_between(_last_basis, target) / delta
	_last_basis = target
	if not shaping():
		_spin = target_spin
		hand_basis = target
		return
	var gap := rotation_between(hand_basis, target) - target_spin * delta
	var distance := gap.length()
	var wanted := target_spin
	if distance > 1e-7:
		var toward := gap / distance
		var braking := _turn_limit(-toward) * brake_margin
		wanted += toward * minf(distance / delta, _braking_speed(distance, braking, delta))
	wanted = wanted.limit_length(max_spin)
	var change := (wanted - _spin) / delta
	var size := change.length()
	if size > 1e-9:
		var direction := change / size
		_spin += direction * minf(size, _turn_limit(direction)) * delta
	hand_basis = rotated(hand_basis, _spin * delta).orthonormalized()


## The largest acceleration of the wrist along `direction` (unit) both joints
## can supply on top of holding, m/s².
func _acceleration_limit(direction: Vector3, braking: bool) -> float:
	var best := free_acceleration
	for joint in 2:
		var limit: float = strength[joint] * (eccentric if braking else 1.0)
		var held: Vector3 = _hold[joint].limit_length(strength[joint] * hold_share)
		best = minf(best, _largest_scale(held, _moment[joint].cross(direction), limit))
	return maxf(best, 0.0)


## The largest angular acceleration of the hand about `direction` (unit) the
## wrist can supply on top of holding and carrying, rad/s².
func _turn_limit(direction: Vector3) -> float:
	var limit := strength[WRIST]
	var fixed := (_hold[WRIST] + _moment[WRIST].cross(acceleration)).limit_length(limit * (1.0 - turn_reserve))
	return minf(free_angular_acceleration, _largest_scale(fixed, _turn_inertia * direction, limit))


## The largest s >= 0 with |fixed + s need| <= limit.
static func _largest_scale(fixed: Vector3, need: Vector3, limit: float) -> float:
	var nn := need.length_squared()
	if nn < 1e-12:
		return INF
	var fn := fixed.dot(need)
	var room := fn * fn - nn * (fixed.length_squared() - limit * limit)
	if room <= 0.0:
		return 0.0
	return maxf((-fn + sqrt(room)) / nn, 0.0)


## The fastest one can move and still stop within `distance`, braking at
## `braking` (per-tick integration), m/s.
static func _braking_speed(distance: float, braking: float, delta: float) -> float:
	if braking <= 0.0:
		return 0.0
	var half := braking * delta * 0.5
	return sqrt(2.0 * braking * distance + half * half) - half


static func _horizontal(v: Vector3) -> float:
	return Vector2(v.x, v.z).length()


## The rotation that turns `from` into `to`, as an axis scaled by its angle.
static func rotation_between(from: Basis, to: Basis) -> Vector3:
	var turn := Quaternion(to.orthonormalized()) * Quaternion(from.orthonormalized()).inverse()
	if turn.w < 0.0:
		turn = -turn
	var angle := turn.get_angle()
	return turn.get_axis() * angle if angle > 1e-6 else Vector3.ZERO


## `basis` turned by the rotation vector `turn` (axis times angle).
static func rotated(basis: Basis, turn: Vector3) -> Basis:
	var angle := turn.length()
	if angle < 1e-9:
		return basis
	return Basis(turn / angle, angle) * basis


## A point mass's inertia about the origin: m (|r|²I - r rᵀ).
static func point_inertia(offset: Vector3, mass: float) -> Basis:
	var r2 := offset.length_squared()
	return Basis(
		Vector3(r2 - offset.x * offset.x, -offset.y * offset.x, -offset.z * offset.x),
		Vector3(-offset.x * offset.y, r2 - offset.y * offset.y, -offset.z * offset.y),
		Vector3(-offset.x * offset.z, -offset.y * offset.z, r2 - offset.z * offset.z)) * mass


static func add(a: Basis, b: Basis) -> Basis:
	return Basis(a.x + b.x, a.y + b.y, a.z + b.z)


## An inertia tensor given in `frame`'s axes, in world axes.
static func to_world(inertia: Basis, frame: Basis) -> Basis:
	var r := frame.orthonormalized()
	return r * inertia * r.transposed()
