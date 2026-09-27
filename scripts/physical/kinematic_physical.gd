class_name KinematicPhysical
extends PlayerPhysical

## The kinematic comparison body: the original CharacterBody3D PlayerBody,
## unchanged, behind the physical layer's contract. It is kept so the dynamic
## body can be run against it on the same scenarios until rung 3 passes.

@export var body: PlayerBody

var _rig: PlayerRig


func attach_rig(rig: PlayerRig) -> void:
	if body == null:
		push_error("KinematicPhysical: no body assigned.")
		return
	_rig = rig
	body.origin = rig
	body.hmd = rig.head
	body.left_controller = rig.left_controller
	body.right_controller = rig.right_controller
	body.skeleton = rig.skeleton


func _ready() -> void:
	# After the body has moved this tick, before the skeleton solves.
	process_physics_priority = StaticSkeleton.SOLVE_PRIORITY - 5


func _physics_process(delta: float) -> void:
	snapshot.tick += 1
	snapshot.delta = delta
	snapshot.body_position = body.global_position
	snapshot.body_velocity = body.velocity
	snapshot.body_height = maxf(_rig.head.position.y, body.min_body_height)
	snapshot.supported = body.grounded
	snapshot.ground_normal = body.ground_normal
	snapshot.commanded_travel = _rig.skeleton.commanded_travel
	snapshot.run_factor = body.run_factor
	snapshot.rig_correction = body.origin_correction
	var lead := _rig.head.global_position - body.global_position
	snapshot.head_lead = Vector3(lead.x, 0.0, lead.z)
