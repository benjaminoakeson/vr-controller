class_name TreeCollisionStreamer
extends Node3D

## Gives the ProceduralTree nodes directly under it collision only while a
## target, normally the player, is near them. Far trees then hold no physics
## objects at all, which keeps load time, memory and the physics world small in
## a large forest.
##
## A tree gets collision within the build radius and loses it beyond the
## release radius; between the two it keeps whatever it has, so a player
## walking along the edge doesn't make a tree build and free over and over.
##
## Work per physics tick stays fixed however many trees there are: it checks a
## few trees' distances in turn, and builds at most a few trees' collision,
## nearest first. When the target jumps further than a step in one tick
## (teleporting, respawning), every tree is checked and built at once instead,
## so the target never arrives among trees without collision.
##
## Only the target is considered: a thrown prop or another character far from
## it passes through trees there.

## What trees must be near to have collision: the player's body or headset.
## With no target, every tree keeps its collision.
@export var target: Node3D
## Trees within this distance of the target get collision.
@export_range(5.0, 200.0, 1.0, "suffix:m") var build_radius_m := 30.0
## Trees beyond this distance lose it. Keep it above the build radius.
@export_range(5.0, 250.0, 1.0, "suffix:m") var release_radius_m := 36.0
## Trees whose distance is checked each physics tick, in turn.
@export_range(1, 1024, 1) var checks_per_tick := 64
## Trees whose collision is built each physics tick, at most.
@export_range(1, 16, 1) var builds_per_tick := 1
## A target moving further than this in one tick has jumped: check and build
## every tree at once.
@export_range(0.5, 100.0, 0.5, "suffix:m") var jump_distance_m := 5.0

var _trees: Array[ProceduralTree] = []
## Trees near enough to need collision, not yet built.
var _waiting: Array[ProceduralTree] = []
var _cursor := 0
var _last_target_position := Vector3.INF


func _enter_tree() -> void:
	# Connected before the children enter, so trees placed in the scene are
	# switched off before their own _ready would build collision.
	if not child_entered_tree.is_connected(_on_child_entered):
		child_entered_tree.connect(_on_child_entered)
		child_exiting_tree.connect(_on_child_exiting)


func _ready() -> void:
	refresh_now()


## Checks every tree and builds or frees its collision straight away. Called by
## itself when the target jumps; call it after moving the target by other means.
func refresh_now() -> void:
	_waiting.clear()
	if target == null:
		for tree in _trees:
			tree.collision_active = true
		return
	var here := target.global_position
	for tree in _trees:
		var distance_squared := here.distance_squared_to(tree.global_position)
		if tree.collision_active:
			tree.collision_active = distance_squared <= release_radius_m * release_radius_m
		else:
			tree.collision_active = distance_squared <= build_radius_m * build_radius_m
	_last_target_position = here


func _physics_process(_delta: float) -> void:
	if target == null or _trees.is_empty():
		return
	var here := target.global_position
	if here.distance_to(_last_target_position) > jump_distance_m:
		refresh_now()
		return
	_last_target_position = here
	for i in mini(checks_per_tick, _trees.size()):
		_cursor = (_cursor + 1) % _trees.size()
		_check(_trees[_cursor], here)
	for i in mini(builds_per_tick, _waiting.size()):
		var tree := _take_nearest(here)
		if here.distance_squared_to(tree.global_position) <= release_radius_m * release_radius_m:
			tree.collision_active = true


func _check(tree: ProceduralTree, here: Vector3) -> void:
	var distance_squared := here.distance_squared_to(tree.global_position)
	if tree.collision_active:
		if distance_squared > release_radius_m * release_radius_m:
			tree.collision_active = false
	elif distance_squared <= build_radius_m * build_radius_m:
		if not _waiting.has(tree):
			_waiting.append(tree)
	else:
		_waiting.erase(tree)


func _take_nearest(here: Vector3) -> ProceduralTree:
	var nearest := 0
	for i in range(1, _waiting.size()):
		if here.distance_squared_to(_waiting[i].global_position) \
				< here.distance_squared_to(_waiting[nearest].global_position):
			nearest = i
	var tree := _waiting[nearest]
	_waiting.remove_at(nearest)
	return tree


func _on_child_entered(node: Node) -> void:
	var tree := node as ProceduralTree
	if tree == null:
		return
	tree.collision_active = false
	_trees.append(tree)
	# A tree added while the game runs is checked on the next jump or turn;
	# check it now so a tree placed beside the player is solid at once.
	if is_node_ready() and target != null:
		_check(tree, target.global_position)


func _on_child_exiting(node: Node) -> void:
	var tree := node as ProceduralTree
	if tree == null:
		return
	_trees.erase(tree)
	_waiting.erase(tree)
	_cursor = 0
