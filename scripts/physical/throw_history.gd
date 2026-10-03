class_name ThrowHistory
extends RefCounted

## A held prop's last moments, for throwing it (2026-09-30, decided with the
## player): where its centre of mass was and how it spun, each tick, over the
## last `window` seconds. Let go, the prop leaves with the velocity of a
## quadratic least-squares fit through those places, read at the last one,
## and with a straight-line fit through the spins read there too. A fit keeps
## up with a throw that is still speeding up and turning, where an average of
## the last ticks lags it (on the harness's overhand throw, a 5-tick average
## of the box's velocity was 14° behind the player's hand and 30 % slow), and
## it smooths a tick's jitter that the prop's own velocity at the release
## would carry.

## How far back the history reaches, in seconds (HandGrab.throw_window).
var window := 0.06

var _clock := 0.0
var _times := PackedFloat64Array()
var _places: Array[Vector3] = []
var _spins: Array[Vector3] = []


## Forgets everything (a new hold, or the player moved).
func clear() -> void:
	_clock = 0.0
	_times.clear()
	_places.clear()
	_spins.clear()


## Adds this tick's centre of mass and spin, `delta` after the last.
func add(delta: float, place: Vector3, spin: Vector3) -> void:
	_clock += delta
	_times.append(_clock)
	_places.append(place)
	_spins.append(spin)
	while _times.size() > 1 and _clock - _times[0] > window + 1e-6:
		_times.remove_at(0)
		_places.remove_at(0)
		_spins.remove_at(0)


## Turns the history with the player's snap turn, so the turn is no motion.
func turn(turning: Transform3D) -> void:
	for i in _places.size():
		_places[i] = turning * _places[i]
		_spins[i] = turning.basis * _spins[i]


## Whether there are enough ticks for the fits.
func ready() -> bool:
	return _times.size() >= 3


## The velocity at the last tick of a quadratic fit through the places.
func velocity() -> Vector3:
	# Times from the last tick, so the fit's linear term is the velocity there.
	var sums := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0])
	var moments: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
	for i in _times.size():
		var time := _times[i] - _clock
		var power := 1.0
		for k in 5:
			sums[k] += power
			if k < 3:
				moments[k] += _places[i] * power
			power *= time
	# Normal equations [s0 s1 s2; s1 s2 s3; s2 s3 s4] [a b c] = moments, by
	# Cramer's rule for b alone.
	var det := _determinant(sums[0], sums[1], sums[2], sums[1], sums[2], sums[3], sums[2], sums[3], sums[4])
	if absf(det) < 1e-18:
		return Vector3.ZERO
	var result := Vector3.ZERO
	for axis in 3:
		result[axis] = _determinant(sums[0], moments[0][axis], sums[2], sums[1], moments[1][axis], sums[3],
				sums[2], moments[2][axis], sums[4]) / det
	return result


## The spin at the last tick of a straight-line fit through the spins.
func spin() -> Vector3:
	var count := float(_times.size())
	var mean_time := 0.0
	var mean_spin := Vector3.ZERO
	for i in _times.size():
		mean_time += (_times[i] - _clock) / count
		mean_spin += _spins[i] / count
	var spread := 0.0
	var covariance := Vector3.ZERO
	for i in _times.size():
		var time := _times[i] - _clock - mean_time
		spread += time * time
		covariance += (_spins[i] - mean_spin) * time
	var slope := covariance / spread if spread > 1e-18 else Vector3.ZERO
	return mean_spin - slope * mean_time


static func _determinant(a: float, b: float, c: float, d: float, e: float, f: float,
		g: float, h: float, i: float) -> float:
	return a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
