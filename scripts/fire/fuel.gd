class_name Fuel
extends Node

## What a fire burns (2026-10-05): how long its body keeps a fire going, in
## seconds of burning. A fire burns one fuel at a time, so the times add up
## (the player's numbers: leaf litter 30 s, a stick 1.5 min, a log 5 min). It
## burns only while a fire holds it (Tinder), and while one does, a readout
## above it shows what is left. Spent, its body is gone, unless it is the
## body's to decide (leaf litter turns to ash: LeafLitter).
##
## Its body is its parent.

## Emitted as it burns, with the seconds left.
signal changed(left: float)
## Emitted once, when nothing is left; its body goes in the same tick if it
## vanishes.
signal spent

const _META := &"fuel"
## How far beyond its body's shapes a spent body wakes what rests on it, in
## metres.
const _WAKE_MARGIN := 0.05
## What counts as nothing left, in seconds: whole ticks of burning leave a
## rounding error (1 s less 72 ticks of 1/72 s is about 1e-15 s), which would
## otherwise hold a fuel a tick longer, showing "0:01".
const _EMPTY := 1e-6

## How long it keeps a fire going.
@export_range(0.0, 3600.0, 0.5, "suffix:s") var seconds := 30.0
## Whether its body goes when it is spent; if not, what becomes of it is the
## body's to decide, on spent.
@export var vanishes := true
## Where its readout stands above, in world up: its body if unset.
@export var centre: Node3D
## How far above `centre` the readout stands.
@export_range(0.0, 2.0, 0.01, "suffix:m") var readout_height := 0.2

## Its body, which it marks and which goes when it is spent.
var body: Node3D
## The seconds of burning left, from `seconds` down to 0.
var left := 0.0
## The fire holding it (burning it, or with it in reach to burn), or null. The
## readout shows while one does.
var fire: Tinder:
	set(value):
		fire = value
		_show_readout(value != null)

var _display: FuelDisplay


func _enter_tree() -> void:
	body = get_parent() as Node3D
	if body == null:
		push_error("Fuel: its parent must be a Node3D.")
		return
	body.set_meta(_META, self)


func _ready() -> void:
	left = seconds


func _exit_tree() -> void:
	if body != null and body.has_meta(_META):
		body.remove_meta(_META)


## The Fuel of `object`, or null if it has none.
static func of(object: Object) -> Fuel:
	if object == null or not object.has_meta(_META):
		return null
	return object.get_meta(_META) as Fuel


## Where its readout stands above.
func middle() -> Vector3:
	return centre.global_position if is_instance_valid(centre) else body.global_position


## Burns up to `amount` seconds of it and returns how much it burnt: all of
## `amount`, or what was left. With nothing left, its body goes.
func burn(amount: float) -> float:
	if amount <= 0.0 or left <= 0.0:
		return 0.0
	var burnt := amount if amount < left - _EMPTY else left
	left -= burnt
	changed.emit(left)
	if left <= 0.0:
		left = 0.0
		spent.emit()
		if vanishes:
			_go()
	return burnt


## Its body goes, waking first what rests on it: Jolt leaves a sleeping body
## where it slept when what held it up is gone (as TreeChop._break_up).
func _go() -> void:
	var space := body.get_world_3d().direct_space_state if body.is_inside_tree() else null
	var bounds := _bounds()
	if space != null and bounds.has_volume():
		var box := BoxShape3D.new()
		box.size = bounds.size + Vector3.ONE * 2.0 * _WAKE_MARGIN
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = box
		query.transform = Transform3D(Basis.IDENTITY, bounds.get_center())
		for hit in space.intersect_shape(query, 32):
			var resting := hit.collider as RigidBody3D
			if resting != null and resting != body:
				resting.sleeping = false
	body.queue_free()


# The world box round its body's collision shapes; empty if it has none.
func _bounds() -> AABB:
	var bounds := AABB()
	var first := true
	for child in body.get_children():
		var holder := child as CollisionShape3D
		if holder == null or holder.shape == null or holder.disabled:
			continue
		var box := holder.global_transform * holder.shape.get_debug_mesh().get_aabb()
		bounds = box if first else bounds.merge(box)
		first = false
	return bounds


func _show_readout(shown: bool) -> void:
	if shown and _display == null:
		_display = FuelDisplay.new()
		_display.fuel = self
		add_child(_display)
	if _display != null:
		_display.visible = shown
		_display.set_process(shown)
