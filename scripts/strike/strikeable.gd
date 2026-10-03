class_name Strikeable
extends Node

## Marks its parent as an object that takes strikes (the strike model,
## documents/strike_model.md): a physical object whose Striker meets one of the
## object's bodies hard enough strikes it, and the damage is judged here by the
## object's material. The object's bodies are its parent, if that is a body,
## and every body below it, found as it enters the tree: a post is one body,
## while an imported model (an ore vein, with a body per mesh) is struck as one
## object. Any CollisionObject3D will do, a StaticBody3D included: the striker
## measures the strike, so the struck bodies need not report contacts. An object
## that builds its bodies itself hands each one to mark(): a ProceduralTree
## builds its wood body as it becomes ready and again whenever its collision
## streams.
##
## It keeps running totals, for a readout. A Health on the object can take the
## damage.

## Emitted once a strike has been judged (its material and damage filled in).
signal struck(strike: Strike)

const _META := &"strikeable"

## What the object is made of.
@export var material: StrikeMaterial

## The object this marks: the parent.
var object: Node3D
## The damage taken so far, in all and by type (Strike.Kind), and the strikes
## that did it.
var damage := 0
var damage_by_kind := PackedInt32Array([0, 0])
var strikes := 0

# The object and its bodies, which carry the mark.
var _marked: Array[Node] = []


func _enter_tree() -> void:
	object = get_parent() as Node3D
	if object == null:
		push_error("Strikeable: its parent must be a Node3D.")
		return
	_mark(object)
	_mark_bodies(object)
	# An object may build its bodies as it becomes ready, so they are counted then.
	if object.is_node_ready():
		_check_bodies()
	elif not object.ready.is_connected(_check_bodies):
		object.ready.connect(_check_bodies, CONNECT_ONE_SHOT)


func _ready() -> void:
	if material == null:
		push_error("Strikeable: %s has no material." % get_parent().name)


func _exit_tree() -> void:
	for node in _marked:
		if is_instance_valid(node) and node.has_meta(_META) and node.get_meta(_META) == self:
			node.remove_meta(_META)
	_marked.clear()


## The Strikeable marking `node` (a struck object or one of its bodies), or
## null if it has none.
static func of(node: Object) -> Strikeable:
	if node == null or not node.has_meta(_META):
		return null
	return node.get_meta(_META) as Strikeable


## Judges `strike` by this object's material: a type the material does not take
## is struck blunt. Adds it to the totals and reports it.
func receive(strike: Strike) -> void:
	strike.material = material
	if material != null and not material.takes(strike.kind):
		strike.kind = Strike.Kind.BLUNT
	strike.damage = material.damage_of(strike.kind, strike.energy) if material != null else 0
	damage += strike.damage
	damage_by_kind[strike.kind] += strike.damage
	strikes += 1
	struck.emit(strike)


## Marks `body` as one of the object's bodies, for a body the object builds
## after this entered the tree; once, however often it is asked (a felled tree's
## body is marked again each time it is cut). Bodies it marked before and that
## are gone are let go.
func mark(body: CollisionObject3D) -> void:
	_marked.assign(_marked.filter(func(node) -> bool: return is_instance_valid(node)))
	if body in _marked:
		return
	_mark(body)


func _mark(node: Node) -> void:
	node.set_meta(_META, self)
	_marked.append(node)


func _check_bodies() -> void:
	if is_inside_tree() and _marked.size() == 1 and not object is CollisionObject3D:
		push_error("Strikeable: %s has no body to strike." % object.name)


# Marks every body below `node`.
func _mark_bodies(node: Node) -> void:
	for child in node.get_children():
		if child is CollisionObject3D:
			_mark(child)
		_mark_bodies(child)
