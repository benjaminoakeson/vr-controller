class_name Grabbable
extends Node

## Marks its parent RigidBody3D as something a hand may grab. Grabbing is
## opt-in (decided 2026-09-25): a bare rigid body can be pushed, not grabbed.
##
## It puts the body on the Grabbable layer, where the hands look for things to
## grab, and lets a hand find this component from the body. Per-object grab
## settings and authored grip poses belong here later.

## The Grabbable collision layer (layer 3), where the hands search.
const GRABBABLE_LAYER := 4
const _META := &"grabbable"

## Whether hands may grab the body now.
@export var enabled := true

## The body this marks.
var body: RigidBody3D


func _enter_tree() -> void:
	body = get_parent() as RigidBody3D
	if body == null:
		push_error("Grabbable: its parent must be a RigidBody3D.")
		return
	body.collision_layer |= GRABBABLE_LAYER
	body.set_meta(_META, self)


func _exit_tree() -> void:
	if body != null and body.has_meta(_META):
		body.remove_meta(_META)


## The Grabbable marking `object`, or null if it has none.
static func of(object: Object) -> Grabbable:
	if object == null or not object.has_meta(_META):
		return null
	return object.get_meta(_META) as Grabbable
