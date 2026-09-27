class_name Player
extends Node3D

## The player: the composition root that joins the controller's layers.
##
## Each layer is its own scene with one job. The rig is what the XR runtime
## tracks, plus the static skeleton solved from it. The physical layer is
## where the world lets the body be, and it is what moves the rig. This node
## only wires them together and adds the debug tools on request. It never
## moves during play.
##
## See documents/player_controller/1 - architecture.md.

## Command-line user arguments (after `--`) that add the debug tools. The
## guided headset session runs inside them, so its argument counts too.
const DEBUG_ARGUMENTS: Array[String] = ["--player-debug", "--record-baseline", "--record-session"]

@export var rig: PlayerRig
@export var physical: PlayerPhysical
@export var interface: PlayerInterface

@export_group("Debug")
## The recorder, readout and guided session, added only when asked for.
@export var debug_scene: PackedScene
## Add the debug tools to every run, not only when a command-line argument
## asks for them.
@export var debug_always := false

## The debug tools once added, otherwise null.
var debug: PlayerDebug


func _enter_tree() -> void:
	if rig == null or physical == null:
		push_error("Player: rig and physical must both be assigned.")
		return
	# Wired on entering the tree rather than in _ready: children are ready
	# before their parent, and the body checks its references when it is.
	physical.attach_rig(rig)
	if interface != null:
		interface.attach(rig, physical)


func _ready() -> void:
	if debug_always or _debug_requested():
		enable_debug()


## Adds the debug tools if they are not present yet, and returns them.
func enable_debug() -> PlayerDebug:
	if debug != null:
		return debug
	if debug_scene == null:
		push_error("Player: no debug scene assigned.")
		return null
	debug = debug_scene.instantiate() as PlayerDebug
	debug.attach(rig, physical)
	add_child(debug)
	return debug


func _debug_requested() -> bool:
	for argument in OS.get_cmdline_user_args():
		if argument in DEBUG_ARGUMENTS:
			return true
	return false
