class_name Tinder
extends Node

## Something sparks light, which then burns (2026-10-05): the leaf litter, lit
## by the flint's sparks (SparkIgniter). Lit, it burns its own fuel first; burnt
## down, it emits burnt_down (the litter turns to ash where it lies: LeafLitter)
## and burns on, on the fuel it holds within `reach` (the player: "When a leaf
## litter is lit on fire, I would like the fuel of the leaf litter to burn out
## first... Once the leaf litter is an ash pile, then the fire should search for
## other fuel"). It holds that fuel from the moment it is in reach, showing it
## and growing for it, but burns none until its own is gone. It burns one at a
## time, in the order they came within reach, nearest first among those that
## came together, so the times add up: litter with two sticks and a log by it
## burns 30 + 90 + 90 + 300 s. A fuel moved out of reach stops burning and keeps
## what it has left. Each fuel goes when spent (Fuel), and each one burnt to
## nothing grows the ash (consumed).
##
## With nothing left to burn, the ash keeps embers, a small fire, for
## ember_seconds (decided with the player): fuel brought within reach then
## catches, and the fire burns on; otherwise it goes out, and the ash stays cold.
##
## The fire grows with the fuel it holds: by fire_growth for each, up to
## fire_growth_most more (the player: 20 % each, raised from 10 %, to at most
## 100 % more, so five fuels make it twice its size), and
## shrinks again as they burn away. Growing, its base spreads base_growth times
## as fast as its flames rise (the player: "increase the radius of the base of
## the fire so it gets wider and taller"), so a big fire is a wide one.
##
## It lights the unlit tinder within reach, which then burns as a fire of its
## own (2026-10-05, the player: "If I bring a leaf litter ball/pile to a burning
## leaf litter, it should start the other"). A fire lit so first looks round it
## in its next tick, so a row of piles catches one a tick, not all at once.
##
## The fire stays lit whatever its body does: held, thrown, rolled up into a
## ball or laid down as a pile. Its flames stand upright on `centre`, turning
## with nothing, since the flame shader lays them out in the fire's own plane.
##
## A fuel burns for one fire at a time: a fire takes no fuel another holds, and
## no fire takes tinder as fuel, so two fires never burn each other's litter.
##
## Its body is its parent. Unlit, it does nothing each tick, as there will be
## many litter piles.

## Emitted once, when it is lit.
signal lit
## Emitted once, when its own fuel is gone: what becomes of its body is the
## body's to decide (ash, or nothing).
signal burnt_down
## Emitted each time a fuel it held burns to nothing, with how many have.
signal consumed(count: int)
## Emitted once, when its embers die.
signal went_out

const _META := &"tinder"
## The most bodies one look for fuel finds.
const _MAX_FOUND := 32

## Its own fuel, burnt first.
@export var fuel: Fuel
## Where it burns: the flames stand here, and fuel is looked for round it.
@export var centre: Node3D
## The fire shown while it burns (scenes/effects/fire.tscn).
@export var fire_scene: PackedScene
## The fire's size against the scene's own, burning alone.
@export_range(0.1, 2.0, 0.05) var fire_scale := 0.5

@export_group("Fuel")
## How near fuel must lie for it to burn, and tinder to catch: any part of its
## shapes within this of `centre` (0.5 m at first; 0.3 m, the player, 2026-10-05).
@export_range(0.0, 2.0, 0.01, "suffix:m") var reach := 0.3
## Where fuel is looked for: Dynamic (sticks, logs, balls of litter),
## Grabbable (litter piles lie on it alone) and Held.
@export_flags_3d_physics var fuel_mask := 2 | 4 | 8
## How often it looks for fuel, while it burns.
@export_range(0.05, 2.0, 0.05, "suffix:s") var look_interval := 0.25

@export_group("Growth")
## How much bigger the fire is for each fuel it holds, as a share of its size
## alone; and the most bigger it gets.
@export_range(0.0, 1.0, 0.01) var fire_growth := 0.2
@export_range(0.0, 3.0, 0.05) var fire_growth_most := 1.0
## How much faster the base widens than the flames rise, as the fire grows: 1
## keeps its shape; 2 makes a fire twice as tall three times as wide. Embers keep
## their shape.
@export_range(0.0, 5.0, 0.05) var base_growth := 2.0
## How long the fire takes to reach a new size: the time constant of its easing.
@export_range(0.01, 5.0, 0.01, "suffix:s") var grow_time := 0.5

@export_group("Embers")
## How long burnt-down tinder with nothing to burn keeps its embers.
@export_range(0.0, 120.0, 0.5, "suffix:s") var ember_seconds := 15.0
## The embers' fire, as a share of its size alone.
@export_range(0.05, 1.0, 0.05) var ember_size := 0.5

## Its body.
var body: CollisionObject3D
## Whether it is burning, embers included.
var burning := false
## How many fuels it held have burnt to nothing.
var consumed_count := 0
## The fire's size against fire_scale, as it grows to: 1 alone, more for each
## fuel it holds, ember_size for embers.
var size := 1.0

# The fuel within reach it holds, in the order it burns them.
var _queue: Array[Fuel] = []
var _fire: Node3D
var _until_look := 0.0
# The size drawn, easing toward `size`.
var _shown_size := 1.0
# How long its embers have glowed with nothing to burn.
var _embers := 0.0
var _query := PhysicsShapeQueryParameters3D.new()


func _enter_tree() -> void:
	body = get_parent() as CollisionObject3D
	if body == null:
		push_error("Tinder: its parent must be a CollisionObject3D.")
		return
	body.set_meta(_META, self)


func _ready() -> void:
	set_process(false)
	set_physics_process(false)
	if fuel == null or centre == null or fire_scene == null:
		push_error("Tinder: fuel, centre and fire_scene must all be assigned.")
		return
	var sphere := SphereShape3D.new()
	sphere.radius = reach
	_query.shape = sphere
	_query.collision_mask = fuel_mask
	_query.exclude = [body.get_rid()]


func _exit_tree() -> void:
	_let_go_of_fuel()
	if body != null and body.has_meta(_META):
		body.remove_meta(_META)


## The Tinder of `object`, or null if it has none.
static func of(object: Object) -> Tinder:
	if object == null or not object.has_meta(_META):
		return null
	return object.get_meta(_META) as Tinder


## How big a fire holding `count` fuels is against its size alone, growing by
## `each` for each, at most `most` more.
static func growth_of(count: int, each: float, most: float) -> float:
	return 1.0 + minf(count * each, most)


## How wide a fire's base is against its size alone, for a fire `size` tall:
## growing, its base widens `base_growth` times as fast; smaller (embers), it
## keeps its shape.
static func width_of(size: float, base_growth: float) -> float:
	return size if size <= 1.0 else 1.0 + (size - 1.0) * base_growth


## Lights it, unless it is burning already or has nothing left (burnt down,
## its ash stays cold). Whether it lit. It looks round it for fuel and tinder in
## its first tick, before it burns.
func ignite() -> bool:
	if burning or fuel == null or fuel.left <= 0.0:
		return false
	burning = true
	fuel.fire = self
	_fire = fire_scene.instantiate() as Node3D
	# Drawn where it is set, as the held bodies it burns on are (Grabbable).
	_fire.top_level = true
	_fire.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_fire)
	size = 1.0
	_shown_size = 1.0
	_place_fire()
	_until_look = 0.0
	set_process(true)
	set_physics_process(true)
	lit.emit()
	return true


# Placed each frame, after the frame's physics steps: where its body is drawn.
func _process(delta: float) -> void:
	_shown_size = lerpf(_shown_size, size, 1.0 - exp(-delta / grow_time))
	_place_fire()


func _physics_process(delta: float) -> void:
	# Burnt down off the ground, its body is going (another tick may come first
	# in a slow frame).
	if body.is_queued_for_deletion():
		return
	_until_look -= delta
	if _until_look <= 0.0:
		_until_look += look_interval
		_look()
	# What one fuel lacks of the tick, the next burns.
	var rest := delta
	while rest > 0.0:
		var burning_now := _burning()
		if burning_now == null:
			break
		var burnt := burning_now.burn(rest)
		if burnt <= 0.0:
			break
		rest -= burnt
		if burning_now.left > 0.0:
			continue
		if burning_now == fuel:
			_burn_down()
			if body.is_queued_for_deletion():
				return
		else:
			consumed_count += 1
			consumed.emit(consumed_count)
	var held := _held()
	if fuel.left <= 0.0 and held == 0:
		size = ember_size
		_embers += delta
		if _embers >= ember_seconds:
			_go_out()
	else:
		size = growth_of(held, fire_growth, fire_growth_most)
		_embers = 0.0


## The fuel it burns now: its own while it lasts, then the first held within
## reach; none for embers.
func _burning() -> Fuel:
	if fuel.left > 0.0:
		return fuel
	while not _queue.is_empty():
		var first := _queue[0]
		if is_instance_valid(first) and first.left > 0.0:
			return first
		_queue.pop_front()
	return null


# How many fuels it holds that have something left.
func _held() -> int:
	var count := 0
	for held in _queue:
		if is_instance_valid(held) and held.left > 0.0:
			count += 1
	return count


## Its own fuel is gone: its readout goes, and its body decides what it
## becomes (it may go, the fire with it).
func _burn_down() -> void:
	fuel.fire = null
	burnt_down.emit()


## Its embers die: the fire goes and it burns no more, nor lights again.
func _go_out() -> void:
	burning = false
	set_process(false)
	set_physics_process(false)
	_fire.queue_free()
	_fire = null
	_let_go_of_fuel()
	went_out.emit()


func _let_go_of_fuel() -> void:
	for held in _queue:
		if is_instance_valid(held) and held.fire == self:
			held.fire = null
	_queue.clear()


## Lights the unlit tinder now within reach. Holds the fuel now within reach
## that no other fire holds, after what it held already, nearest first; lets go
## of what it held that is out of reach.
func _look() -> void:
	_query.transform = Transform3D(Basis.IDENTITY, centre.global_position)
	var found: Array[Fuel] = []
	var catching: Array[Tinder] = []
	for hit in body.get_world_3d().direct_space_state.intersect_shape(_query, _MAX_FOUND):
		var tinder := Tinder.of(hit.collider)
		if tinder != null:
			if not tinder.burning and tinder not in catching:
				catching.append(tinder)
			continue
		var other := Fuel.of(hit.collider)
		if other != null and other != fuel and other.left > 0.0 and other not in found \
				and (other.fire == null or other.fire == self):
			found.append(other)
	for held in _queue.duplicate():
		if not is_instance_valid(held) or held not in found:
			_queue.erase(held)
			if is_instance_valid(held) and held.fire == self:
				held.fire = null
	var arrived := found.filter(func(other: Fuel) -> bool: return other not in _queue)
	var from := centre.global_position
	arrived.sort_custom(func(a: Fuel, b: Fuel) -> bool:
		return a.body.global_position.distance_squared_to(from) < b.body.global_position.distance_squared_to(from))
	for other: Fuel in arrived:
		other.fire = self
		_queue.append(other)
	for tinder in catching:
		tinder.ignite()


## The flames on `centre`, upright and at fire_scale, grown: the flame shader
## takes their height from the fire's Y scale and spreads their base over its X
## and Z.
func _place_fire() -> void:
	var tall := fire_scale * _shown_size
	var wide := fire_scale * width_of(_shown_size, base_growth)
	_fire.global_transform = Transform3D(Basis.from_scale(Vector3(wide, tall, wide)), centre.global_position)
