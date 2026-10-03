class_name PlayerRig
extends XROrigin3D

## The tracked half of the player: the XR origin, the headset and controllers
## the runtime poses inside it, and the static skeleton solved from them.
##
## The runtime owns the head and controller poses. The origin itself is moved
## only by the physical layer, which carries it with the body. This script
## writes nothing but, once, what the headset camera draws; it names the
## parts, so the rest of the player can be wired to them without reaching into
## this scene.

@export var head: XRCamera3D
@export var left_controller: XRController3D
@export var right_controller: XRController3D
@export var skeleton: StaticSkeleton
## The static skeleton's drawing, which the interface can hide.
@export var skeleton_view: SkeletonDebug


func _ready() -> void:
	# The eyes sit inside the model's head and neck, which only reflections
	# show (MirrorOnlyParts).
	head.cull_mask &= ~RenderLayers.mask(RenderLayers.MIRROR_ONLY)


## Where the middle of the player's head is, in world space: the static
## skeleton's head offset from the eyes, behind and a little below them. The
## body stands under this, not under the eyes: a standing player's body is
## behind their eyes, not around them.
func head_centre() -> Vector3:
	return head.global_transform.translated_local(skeleton.head_offset).origin
