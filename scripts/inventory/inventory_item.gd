class_name InventoryItem
extends Resource

## A kind of thing an inventory slot can hold (2026-10-06, documents/inventory.md):
## the prop it comes out as, the model a slot shows for it, and how many make a
## full stack. A slot holds a count of one item; every one comes out fresh, as
## its scene makes it.
##
## Shared, read-only configuration: nothing about one stored thing is kept here.

## A short name for recordings and tests.
@export var id := &""
## The name a readout shows.
@export var display_name := ""
## The prop scene one of it comes out as. A path, not the scene: the scene's
## Storable refers back to this item, and a scene and a resource that each hold
## the other cannot be loaded.
@export_file("*.tscn") var scene := ""
## What a slot shows for it: a model, fitted to the slot (no collision shapes).
@export var model: PackedScene
## How the slot turns the model before fitting it, in degrees, about the slot's
## own axes (X right, Y up, Z toward the player).
@export var display_rotation := Vector3.ZERO
## Whether one ejected from a slot is laid on its side, its length (its Y)
## level: for long things (logs, sticks), which laid standing land on their
## ends and stay standing (LootDrop.lay_down).
@export var lay_down := false
## The most one slot holds.
@export_range(1, 9999, 1) var max_stack := 999

var _scene: PackedScene


## The prop scene, loaded the first time it is asked for.
func packed_scene() -> PackedScene:
	if _scene == null and not scene.is_empty():
		_scene = load(scene) as PackedScene
	return _scene
