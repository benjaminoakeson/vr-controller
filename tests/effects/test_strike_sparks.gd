extends SceneTree

## Checks the flint's sparks (2026-10-05) headlessly, without physics or a
## renderer: which way a strike's sparks go (they follow whichever piece moved,
## sliding across the other; a skim throws them low over the surface, a blow
## straight in straight off it), which strikes spark (only on the listed
## materials, and only sliding fast enough), how many by how fast, and the
## bursts taking turns and hiding once their sparks are out. The strikes
## themselves are measured in tests/harness/run_scenarios.gd; the look needs a
## renderer and the headset.
##
##   godot --headless --xr-mode off --path . -s tests/effects/test_strike_sparks.gd

const STONE := "res://assets/strike/stone.tres"
const WOOD := "res://assets/strike/wood.tres"
const BURST := "res://scenes/effects/spark_burst.tscn"
## Every check the suite makes. Update it when adding or removing a check.
const EXPECTED_CHECKS := 23

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_test_mover()
	_test_spray()
	# Needs the scene tree running, so added nodes become ready.
	await process_frame
	await _test_sparking()
	# A script error ends a test early without failing a check, so count them.
	if _checks != EXPECTED_CHECKS:
		_failures += 1
		print("FAIL  %d of %d checks ran; a test stopped on a script error" % [_checks, EXPECTED_CHECKS])
	print("\n%s" % ("ALL PASSED" if _failures == 0 else "%d FAILED" % _failures))
	quit(0 if _failures == 0 else 1)


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)


## The sparks follow the piece that moved (decided with the player).
func _test_mover() -> void:
	var swing := Vector3(3.0, -1.0, 0.0)
	_check(StrikeSparks.slide_of(_strike(swing, Vector3.ZERO)).is_equal_approx(swing),
			"the flint swung at a still stone: its own slide")
	# The stone swung into a still flint: the flint moves against the stone the
	# opposite way, and the stone's own motion is the surface's.
	_check(StrikeSparks.slide_of(_strike(-swing, swing)).is_equal_approx(swing),
			"the stone swung into a still flint: the stone's slide")
	var flint := Vector3(3.0, 0.0, 0.0)
	var stone := Vector3(0.0, 0.0, 1.0)
	_check(StrikeSparks.slide_of(_strike(flint - stone, stone)).is_equal_approx(flint - stone),
			"both moving, the flint faster: the flint's slide across the stone")
	_check(StrikeSparks.slide_of(_strike(stone - flint, flint)).is_equal_approx(flint - stone),
			"both moving, the stone faster: the stone's slide across the flint")


## The way the sparks go, for a surface facing up.
func _test_spray() -> void:
	var up := Vector3.UP
	var lift := deg_to_rad(15.0)
	# A skim from behind: forward along the stone, closing a little.
	var skim := StrikeSparks.spray_direction(up, Vector3(3.0, -0.5, 0.0), lift)
	_check(is_equal_approx(skim.length(), 1.0), "the way is a unit vector")
	_check(_heading(skim).angle_to(Vector3.RIGHT) < deg_to_rad(0.5),
			"a skim from behind sprays forward, the way it slid (%.2f°)" % rad_to_deg(_heading(skim).angle_to(Vector3.RIGHT)))
	var skim_up := _elevation(skim)
	_check(skim_up > 15.0 and skim_up < 17.5, "a skim sprays low over the surface (%.1f° up)" % skim_up)
	var along := StrikeSparks.spray_direction(up, Vector3(0.0, 0.0, -2.0), lift)
	_check(is_equal_approx(_elevation(along), 15.0), "a slide along the surface: the lift alone (%.2f°)" % _elevation(along))
	var head_on := StrikeSparks.spray_direction(up, Vector3(0.0, -3.0, 0.0), lift)
	_check(head_on.is_equal_approx(up), "a blow straight in sprays straight off the surface")
	var slant := StrikeSparks.spray_direction(up, Vector3(2.0, -2.0, 0.0), lift)
	_check(absf(_elevation(slant) - (90.0 - 75.0 * sqrt(0.5))) < 0.1 and slant.x > 0.0,
			"a 45° blow: forward, raised part-way (%.1f°)" % _elevation(slant))
	_check(is_zero_approx(StrikeSparks.glance_of(up, Vector3(0.0, -3.0, 0.0)))
			and is_equal_approx(StrikeSparks.glance_of(up, Vector3(3.0, 0.0, 0.0)), 1.0),
			"glance: 0 straight in, 1 along the surface")


## A flint's StrikeSparks fed strikes as its Striker would report them.
func _test_sparking() -> void:
	var flint := RigidBody3D.new()
	flint.max_contacts_reported = 4
	var striker := Striker.new()
	flint.add_child(striker)
	var sparks := StrikeSparks.new()
	sparks.striker = striker
	sparks.materials = [load(STONE)]
	sparks.burst_scene = load(BURST)
	flint.add_child(sparks)
	root.add_child(flint)
	await process_frame
	var heard: Array[Dictionary] = []
	sparks.sparked.connect(func(point: Vector3, direction: Vector3, strength: float) -> void:
		heard.append({"point": point, "direction": direction, "strength": strength}))
	var bursts: Array[SparkBurst] = []
	for child in sparks.get_children():
		if child is SparkBurst:
			bursts.append(child)
	_check(bursts.size() == 3 and bursts.all(func(burst: SparkBurst) -> bool: return not burst.visible),
			"three bursts, all hidden at first")

	var point := Vector3(1.0, 1.0, -3.0)
	var skim := Vector3(3.0, -0.5, 0.0)
	striker.struck.emit(_strike(skim, Vector3.ZERO, STONE, point))
	_check(heard.size() == 1, "a skim on stone sparks once")
	var expected := StrikeSparks.spray_direction(Vector3.UP, skim, deg_to_rad(sparks.lift))
	_check(heard.size() == 1 and heard[0].point.is_equal_approx(point)
			and heard[0].direction.is_equal_approx(expected),
			"from the struck point, the way spray_direction gives")
	_check(heard.size() == 1 and absf(heard[0].strength - (skim.length() - 1.0) / 5.0) < 1e-4,
			"strength by sliding speed between 1 and 6 m/s (%.3f)" % (heard[0].strength if heard.size() == 1 else -1.0))
	_check(bursts[0].visible and bursts[0].global_position.is_equal_approx(point),
			"the first burst shows at the struck point")

	striker.struck.emit(_strike(skim, Vector3.ZERO, WOOD, point))
	_check(heard.size() == 1, "on wood: no sparks")
	striker.struck.emit(_strike(Vector3(0.6, -0.6, 0.0), Vector3.ZERO, STONE, point))
	_check(heard.size() == 1, "sliding at 0.85 m/s: no sparks")

	striker.struck.emit(_strike(Vector3(1.0, 0.0, 0.0), Vector3.ZERO, STONE, point))
	_check(int(bursts[1].get_instance_shader_parameter(&"count")) == sparks.counts.x,
			"at the least sliding speed: the fewest sparks (%s)" % bursts[1].get_instance_shader_parameter(&"count"))
	striker.struck.emit(_strike(Vector3(8.0, -1.0, 0.0), Vector3.ZERO, STONE, point))
	_check(int(bursts[2].get_instance_shader_parameter(&"count")) == sparks.counts.y
			and is_equal_approx(bursts[2].get_instance_shader_parameter(&"speed"), sparks.speed_limits.y),
			"far faster: the most sparks, at the fastest (%s, %s m/s)"
			% [bursts[2].get_instance_shader_parameter(&"count"), bursts[2].get_instance_shader_parameter(&"speed")])
	_check(bursts.all(func(burst: SparkBurst) -> bool: return burst.visible), "the three bursts took turns")
	var far := Vector3(0.0, 1.0, 0.0)
	striker.struck.emit(_strike(skim, Vector3.ZERO, STONE, far))
	_check(bursts[0].global_position.is_equal_approx(far), "a fourth strike takes the first burst again")

	await create_timer(0.7).timeout
	_check(bursts.all(func(burst: SparkBurst) -> bool: return not burst.visible and not burst.is_processing()),
			"once their sparks are out, the bursts hide and stop")
	flint.free()


# A strike on a surface facing up, at `point`, made of `material`: the striker
# moving against it with `velocity`, the surface itself with `surface_velocity`.
func _strike(velocity: Vector3, surface_velocity: Vector3, material := STONE,
		point := Vector3.ZERO) -> Strike:
	var strike := Strike.new()
	strike.material = load(material)
	strike.point = point
	strike.normal = Vector3.UP
	strike.velocity = velocity
	strike.surface_velocity = surface_velocity
	strike.speed = -velocity.dot(Vector3.UP)
	return strike


# A way's heading over an upward-facing surface.
func _heading(way: Vector3) -> Vector3:
	return Vector3(way.x, 0.0, way.z).normalized()


# How far above an upward-facing surface a way rises, in degrees.
func _elevation(way: Vector3) -> float:
	return rad_to_deg(asin(clampf(way.y, -1.0, 1.0)))
