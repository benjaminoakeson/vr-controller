class_name Climbable
extends Node

## Marks its parent StaticBody3D as a climbing hold (2026-09-28): a hand whose
## grip closes on it is pulled onto it and held there, and while a hand holds
## a hold its arm moves the body (HandGrab, HandDrive: climbing).
##
## It puts the body on the ClimbHold layer, where the hands look for holds,
## beside its own layers (a hold stays on Static, so the body, hands and
## fingers still touch it), and lets a hand find this component from the body.

## The ClimbHold collision layer (layer 8), where the hands search.
const CLIMB_HOLD_LAYER := 128
const _META := &"climbable"

## Whether hands may hold it now; a hold that stops being one is let go.
@export var enabled := true

## The body this marks.
var body: StaticBody3D


func _enter_tree() -> void:
	body = get_parent() as StaticBody3D
	if body == null:
		push_error("Climbable: its parent must be a StaticBody3D.")
		return
	if body.collision_layer & 1 == 0:
		push_warning("Climbable: a hold should stay on the Static layer, so the body and hands touch it.")
	body.collision_layer |= CLIMB_HOLD_LAYER
	body.set_meta(_META, self)


func _exit_tree() -> void:
	if body != null and body.has_meta(_META):
		body.remove_meta(_META)


## The Climbable marking `object`, or null if it has none.
static func of(object: Object) -> Climbable:
	if object == null or not object.has_meta(_META):
		return null
	return object.get_meta(_META) as Climbable
