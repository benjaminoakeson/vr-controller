class_name PlayerPhysical
extends Node3D

## The physical layer's contract with the rest of the player: where the world
## lets the body be, and the one thing that moves the rig.
##
## An implementation resolves the body every physics tick, publishes the
## result in `snapshot`, and gives the static skeleton its three inputs. The
## rest of the player reads the snapshot and never writes to this layer.
## See documents/player_controller/1 - architecture.md, sections 2 to 5.

## A physical hand (0 left, 1 right) started touching something, moving at
## `speed` m/s. For feedback such as haptics.
signal hand_contact(side: int, speed: float)

## This layer's output, overwritten every tick.
var snapshot := PoseSnapshot.new()


## Gives the layer the tracked rig it reads and moves. Player calls this
## before any node of this layer is ready.
func attach_rig(_rig: PlayerRig) -> void:
	push_error("%s does not implement attach_rig()." % name)
