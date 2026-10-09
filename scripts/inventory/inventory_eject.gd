class_name InventoryEject
extends Node

## What a destroyed inventory slot held, coming out where the slot was
## (2026-10-06, documents/inventory.md): every one of them, as its prop, laid in
## rings round the slot's place, each clear of the others and of what it would
## meet (LootDrop's checks; one in a taken place is tried higher), then falling.
## Long items lie on their side; leaf litter comes out as a ball, which falls,
## rather than a pile fixed in the air. A few come out a tick, then it goes.
##
## InventorySlot makes it and adds it to the destroyed node's parent, where the
## items go.

## A drop whose place is taken is tried up to this many spacings higher, and
## left at the last (LootDrop).
const _RISES := 8

## How many come out a tick.
@export_range(1, 256, 1) var per_tick := 16
## The space kept between two items, in metres.
@export_range(0.0, 0.2, 0.005, "suffix:m") var gap := 0.02

## What comes out, how many, and where the slot was (world space).
var item: InventoryItem
var count := 0
var at := Vector3.ZERO

var _out := 0
var _spacing := 0.0


func _physics_process(_delta: float) -> void:
	var world := get_parent()
	var scene := item.packed_scene() if item != null else null
	if scene == null or world == null:
		queue_free()
		return
	var frame := (world as Node3D).global_transform if world is Node3D else Transform3D.IDENTITY
	var space := get_viewport().world_3d.direct_space_state
	var ignore: Array[RID] = []
	for i in mini(per_tick, count - _out):
		var body := scene.instantiate() as Node3D
		if _spacing <= 0.0:
			_spacing = 2.0 * LootDrop.reach_of(body) + gap
		var pose := _place(_out)
		var rises := 0
		while rises < _RISES and not LootDrop.is_clear(body, pose, space, ignore):
			pose.origin.y += _spacing
			rises += 1
		body.transform = frame.affine_inverse() * pose
		world.add_child(body)
		var litter := body as LeafLitter
		if litter != null:
			litter.roll_up()
		_out += 1
	if _out >= count:
		queue_free()


## Where the `index`th item lies: the first at the slot's place, then rings a
## spacing apart, each holding as many as fit a spacing apart round it.
func _place(index: int) -> Transform3D:
	var ring := 0
	var first := 0
	var fits := 1
	while index >= first + fits:
		first += fits
		ring += 1
		fits = maxi(int(TAU * ring), 1)
	var angle := TAU * (index - first + 0.5 * (ring % 2)) / fits
	var pose := Transform3D(Basis(Vector3.UP, -angle),
			at + Vector3(cos(angle), 0.0, sin(angle)) * ring * _spacing)
	if item.lay_down:
		# Turned about the line out from the middle: its Y goes along the ring.
		pose.basis = pose.basis * Basis(Vector3.RIGHT, PI / 2.0)
	return pose
