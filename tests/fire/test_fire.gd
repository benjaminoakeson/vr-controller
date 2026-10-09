extends SceneTree

## Checks fire rung 1 (2026-10-05) headlessly, without a renderer: a fuel
## burning down and going, its readout, the fuel each prop carries (the
## player's numbers), lighting tinder (only once; a fire lights the tinder by
## it), the leaves burning down to ash on the ground (its embers dying, cold
## after) or to nothing off it, the fire's and the ash's growth, and the flint's
## sparks lighting tinder near the strike and no farther. The
## burning itself, fuel by fuel over time, is measured in
## tests/harness/run_scenarios.gd (the fire_* scenarios); the look needs a
## renderer and the headset.
##
##   godot --headless --xr-mode off --path . -s tests/fire/test_fire.gd

const LITTER := "res://scenes/props/oak_leaf_litter.tscn"
const STICK := "res://scenes/props/wood/stick.tscn"
const LOG := "res://scenes/props/wood/log.tscn"
const FLINT := "res://scenes/props/stone/flint.tscn"
const STONE := "res://assets/strike/stone.tres"
## Every check the suite makes. Update it when adding or removing a check.
const EXPECTED_CHECKS := 31

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_test_format()
	_test_props()
	# Needs the scene tree running, so added nodes become ready.
	await process_frame
	await _test_burning()
	await _test_lighting()
	await _test_ash()
	await _test_sparks()
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


func _test_format() -> void:
	_check(FuelDisplay.format(90) == "1:30" and FuelDisplay.format(300) == "5:00",
			"the readout reads minutes and seconds (90 s: %s, 300 s: %s)" % [FuelDisplay.format(90), FuelDisplay.format(300)])
	_check(FuelDisplay.format(59) == "0:59" and FuelDisplay.format(1) == "0:01" and FuelDisplay.format(0) == "0:00",
			"under a minute: 0:59, 0:01, 0:00")


## The player's numbers: leaf litter 30 s, a stick 1.5 min, a log 5 min.
func _test_props() -> void:
	var litter := (load(LITTER) as PackedScene).instantiate()
	var stick := (load(STICK) as PackedScene).instantiate()
	var log := (load(LOG) as PackedScene).instantiate()
	_check((litter.get_node(^"Fuel") as Fuel).seconds == 30.0, "leaf litter burns 30 s")
	_check((stick.get_node(^"Fuel") as Fuel).seconds == 90.0, "a stick burns 90 s")
	_check((log.get_node(^"Fuel") as Fuel).seconds == 300.0, "a log burns 300 s")
	var tinder := litter.get_node(^"Tinder") as Tinder
	_check(tinder.fuel == litter.get_node(^"Fuel") and is_equal_approx(tinder.reach, 0.3),
			"the litter is tinder, burning its own fuel, looking 0.3 m round for more")
	_check(is_equal_approx(tinder.fire_growth, 0.2) and is_equal_approx(tinder.fire_growth_most, 1.0)
			and is_equal_approx((litter as LeafLitter).ash_growth, 0.1) and is_equal_approx((litter as LeafLitter).ash_growth_most, 1.0),
			"the fire grows 20 % a fuel held and the ash 10 % a fuel burnt, each to at most 100 % more")
	_check(stick.get_node_or_null(^"Tinder") == null and log.get_node_or_null(^"Tinder") == null,
			"sticks and logs are fuel, not tinder")
	_check(not (litter.get_node(^"Fuel") as Fuel).vanishes and (stick.get_node(^"Fuel") as Fuel).vanishes
			and (log.get_node(^"Fuel") as Fuel).vanishes and (litter as LeafLitter).tinder == tinder
			and (litter as LeafLitter).ash_model == litter.get_node(^"AshModel"),
			"spent, sticks and logs vanish; the litter's body stays, to turn to ash")
	_check(is_equal_approx(Tinder.growth_of(0, 0.1, 1.0), 1.0) and is_equal_approx(Tinder.growth_of(3, 0.1, 1.0), 1.3)
			and is_equal_approx(Tinder.growth_of(10, 0.1, 1.0), 2.0) and is_equal_approx(Tinder.growth_of(12, 0.1, 1.0), 2.0),
			"the fire grows 10 % a fuel, to at most 100 % more")
	_check(is_equal_approx(Tinder.width_of(1.0, 2.0), 1.0) and is_equal_approx(Tinder.width_of(2.0, 2.0), 3.0)
			and is_equal_approx(Tinder.width_of(1.5, 1.0), 1.5) and is_equal_approx(Tinder.width_of(0.5, 2.0), 0.5),
			"growing, its base widens twice as fast as it rises; embers keep their shape")
	var flint := (load(FLINT) as PackedScene).instantiate()
	var igniter := flint.get_node(^"SparkIgniter") as SparkIgniter
	_check(igniter.sparks == flint.get_node(^"Sparks") and igniter.reach == 0.3,
			"the flint's sparks light tinder within 0.3 m")
	for node: Node in [litter, stick, log, flint]:
		node.free()


func _test_burning() -> void:
	var stick := _add(STICK, Vector3(0.0, 10.0, 0.0))
	stick.freeze = true
	await process_frame
	var fuel := Fuel.of(stick)
	_check(fuel != null and fuel.left == fuel.seconds and fuel.seconds > 0.0,
			"a fuel starts full, found from its body (%.1f s)" % (fuel.left if fuel != null else -1.0))
	fuel.left = 90.0
	var spent := [0]
	fuel.spent.connect(func() -> void: spent[0] += 1)
	var burnt := fuel.burn(40.0)
	_check(burnt == 40.0 and fuel.left == 50.0, "burning 40 s of 90 leaves 50 (%.1f)" % fuel.left)
	burnt = fuel.burn(80.0)
	_check(burnt == 50.0 and fuel.left == 0.0, "burning more than is left burns what is left (%.1f)" % burnt)
	_check(spent[0] == 1 and stick.is_queued_for_deletion(), "spent once, and its body goes")
	_check(fuel.burn(5.0) == 0.0 and spent[0] == 1, "nothing left: it burns no more, and is spent only once")
	await process_frame


func _test_lighting() -> void:
	var litter := _add(LITTER, Vector3(20.0, 0.0, 0.0))
	var near := _add(LITTER, Vector3(20.3, 0.0, 0.0))
	var stick := _add(STICK, Vector3(30.0, 10.0, 0.0))
	stick.freeze = true
	await physics_frame
	var tinder := Tinder.of(litter)
	var display_before := tinder.fuel.get_child_count()
	_check(tinder != null and not tinder.burning and display_before == 0,
			"unlit tinder: found from its body, not burning, no readout made")
	_check(tinder.ignite() and tinder.burning, "lit")
	var display := tinder.fuel.get_child(0) as FuelDisplay if tinder.fuel.get_child_count() == 1 else null
	_check(display != null and display.visible and display.text == "0:30",
			"lit, its fuel shows what is left above it (%s)" % (display.text if display != null else "none"))
	_check(not tinder.ignite(), "lit already: it does not light again")
	# Its first tick looks round it.
	await physics_frame
	await physics_frame
	var caught := Tinder.of(near)
	_check(caught.burning and caught.fuel.fire == caught,
			"the unlit tinder 0.3 m off catches, burning its own fuel, not the first fire's")
	var fuel := Fuel.of(stick)
	fuel.fire = tinder
	fuel.fire = null
	_check(fuel.get_child_count() == 1 and not (fuel.get_child(0) as FuelDisplay).visible,
			"let go of, a fuel's readout hides")
	for node: Node in [litter, near, stick]:
		node.free()


## Leaves burnt down lying on the ground are ash there, which nothing meets and
## no hand picks up; with nothing to burn its embers die, and it lies cold.
## Burnt down in the air, nothing is left.
func _test_ash() -> void:
	var ground := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4.0, 0.2, 4.0)
	floor_shape.shape = box
	ground.add_child(floor_shape)
	ground.position = Vector3(50.0, -0.1, 0.0)
	root.add_child(ground)
	var litter := _add(LITTER, Vector3(50.0, 0.0, 0.0)) as LeafLitter
	var tinder := litter.tinder
	tinder.ember_seconds = 0.1
	var flying := _add(LITTER, Vector3(60.0, 10.0, 0.0)) as LeafLitter
	flying.roll_up()
	await physics_frame
	litter.tinder.fuel.left = 0.05
	tinder.ignite()
	flying.tinder.fuel.left = 0.05
	flying.tinder.ignite()
	for i in 6:
		await physics_frame
	_check(litter.form == LeafLitter.Form.ASH and litter.ash_model.visible and not litter.pile_model.visible
			and not litter.is_queued_for_deletion(), "burnt down lying as a pile: a heap of ash, where it lay")
	_check(not litter.grabbable.enabled and litter.collision_layer == 0 and litter.collision_mask == 0,
			"the ash is no hand's to pick up, and meets nothing")
	_check(tinder.burning and is_equal_approx(tinder.size, tinder.ember_size),
			"with nothing to burn, embers: a small fire (%.2f)" % tinder.size)
	_check(not is_instance_valid(flying) or flying.is_queued_for_deletion(), "burnt down in the air: nothing is left")
	for i in 12:
		await physics_frame
	_check(not tinder.burning and tinder.get_child_count() == 0 and litter.ash_model.visible and not tinder.ignite(),
			"its embers died: the ash lies cold, its fire gone, and does not light again")
	litter.free()
	ground.free()


func _test_sparks() -> void:
	var flint := _add(FLINT, Vector3(0.0, 40.0, -5.0))
	flint.freeze = true
	var point := Vector3(0.0, 1.0, -5.0)
	# Each pile's sphere (5 cm) sits 5 cm above its origin.
	var near := _add(LITTER, point + Vector3(0.25, -0.05, 0.0))
	var far := _add(LITTER, point + Vector3(-0.45, -0.05, 0.0))
	await physics_frame
	await physics_frame
	var lit: Array[Tinder] = []
	(flint.get_node(^"SparkIgniter") as SparkIgniter).ignited.connect(func(tinder: Tinder) -> void: lit.append(tinder))
	var strike := Strike.new()
	strike.material = load(STONE)
	strike.point = point
	strike.normal = Vector3.UP
	strike.velocity = Vector3(3.0, -0.5, 0.0)
	strike.speed = 0.5
	Striker.of(flint).struck.emit(strike)
	_check(lit.size() == 1 and lit[0] == Tinder.of(near) and Tinder.of(near).burning,
			"a burst lights the tinder 0.2 m from the strike, at once")
	_check(not Tinder.of(far).burning, "and not the tinder 0.4 m off")
	strike.material = load("res://assets/strike/wood.tres")
	Striker.of(flint).struck.emit(strike)
	_check(lit.size() == 1, "a strike that throws no sparks lights nothing")
	for node: Node in [flint, near, far]:
		node.free()


func _add(path: String, at: Vector3) -> RigidBody3D:
	var body := (load(path) as PackedScene).instantiate() as RigidBody3D
	body.position = at
	root.add_child(body)
	return body
