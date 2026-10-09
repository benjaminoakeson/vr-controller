class_name Storable
extends Node

## Marks its parent RigidBody3D as one of an InventoryItem, which an inventory
## slot can take in (2026-10-06, documents/inventory.md): let go with the hand in
## the slot's zone, it goes into the slot and the body is gone.
##
## A slot keeps only how many it holds, so what comes out is fresh: a burning
## body (lit tinder) and fuel a fire has started on are not taken in, rather than
## coming back whole and unlit.

const _META := &"storable"

## What it is.
@export var item: InventoryItem

## The body this marks.
var body: RigidBody3D


func _enter_tree() -> void:
	body = get_parent() as RigidBody3D
	if body == null:
		push_error("Storable: its parent must be a RigidBody3D.")
		return
	body.set_meta(_META, self)


func _ready() -> void:
	if item == null:
		push_error("Storable: %s has no item." % get_parent().name)


func _exit_tree() -> void:
	if body != null and body.has_meta(_META):
		body.remove_meta(_META)


## The Storable marking `object`, or null if it has none.
static func of(object: Object) -> Storable:
	if object == null or not object.has_meta(_META):
		return null
	return object.get_meta(_META) as Storable


## Whether a slot may take the body in now: not while it burns, once a fire
## has burnt any of its fuel, or once it is going.
func can_store() -> bool:
	if item == null or body == null or body.is_queued_for_deletion():
		return false
	var tinder := Tinder.of(body)
	if tinder != null and tinder.burning:
		return false
	var fuel := Fuel.of(body)
	return fuel == null or fuel.left >= fuel.seconds
