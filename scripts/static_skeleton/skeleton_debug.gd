class_name SkeletonDebug
extends Node3D

## Draws the static skeleton: a sphere at every tracker and a thin box along
## every connection between them, fingers included.
##
## This is a picture of the trackers, not part of them. It reads the skeleton
## after it has solved each tick and writes nothing back, so it can be switched
## off, hidden or deleted without the body noticing. Every sphere carries its
## tracker's full rotation and every box is rolled from the tracker whose bone
## it is, so with a textured material the twist of a forearm or the roll of a
## foot is visible, not just where the joints are.
##
## One sphere mesh and one unit box are shared by everything; a box is sized
## by its node's scale, so a bone changing length costs nothing.

## The tracker whose bone this box draws decides its roll. A bone with no
## `to` node runs `reach` metres down `from`'s own -Z instead, which is how a
## fingertip is drawn past the last joint.
class Bone:
	var from: Node3D
	var to: Node3D
	var roll: Node3D
	var reach := 0.0
	var thickness := 0.0
	var mesh: MeshInstance3D

@export var skeleton: StaticSkeleton
## Materials for the spheres and the boxes. Left empty, a plain translucent
## one is made for each; a textured material with object-space triplanar
## mapping is what makes rotation readable on a sphere.
@export var joint_material: Material
@export var bone_material: Material
@export var joint_radius := 0.03
@export var bone_thickness := 0.02
@export var finger_joint_radius := 0.007
@export var finger_bone_thickness := 0.009
@export var show_fingers := true

var _joint_nodes: Array[Node3D] = []
var _joint_meshes: Array[MeshInstance3D] = []
var _bones: Array[Bone] = []
var _sphere: SphereMesh
var _finger_sphere: SphereMesh
var _box: BoxMesh


func _ready() -> void:
	# Draw straight after the skeleton solves, in the same tick.
	process_physics_priority = StaticSkeleton.SOLVE_PRIORITY + 1
	if skeleton == null:
		push_error("SkeletonDebug: no skeleton assigned.")
		return
	# The fingers are built in the skeleton's own _ready, which runs after its
	# children's, so wait for it when this node sits underneath it.
	if skeleton.is_node_ready():
		_build()
	else:
		skeleton.ready.connect(_build)


func _physics_process(_delta: float) -> void:
	if not visible:
		return
	for i in _joint_nodes.size():
		_joint_meshes[i].global_transform = _joint_nodes[i].global_transform
	for bone in _bones:
		var start := bone.from.global_position
		var end := start - bone.from.global_basis.z * bone.reach if bone.to == null \
				else bone.to.global_position
		var span := end - start
		var length := span.length()
		if length < 0.0005:
			bone.mesh.visible = false
			continue
		bone.mesh.visible = true
		var basis := _look_along(span / length, bone.roll.global_basis) \
				* Basis.from_scale(Vector3(bone.thickness, bone.thickness, length))
		bone.mesh.global_transform = Transform3D(basis, (start + end) * 0.5)


## Lays out every sphere and box once. Nothing here is sized or placed yet -
## that is the tick's job - so this is only the list of what connects to what.
func _build() -> void:
	if joint_material == null:
		joint_material = _plain_material(Color(1.0, 1.0, 1.0, 0.55))
	if bone_material == null:
		bone_material = _plain_material(Color(0.45, 0.72, 0.92, 0.55))
	_sphere = SphereMesh.new()
	_sphere.radius = joint_radius
	_sphere.height = joint_radius * 2.0
	_finger_sphere = SphereMesh.new()
	_finger_sphere.radius = finger_joint_radius
	_finger_sphere.height = finger_joint_radius * 2.0
	_box = BoxMesh.new()

	var s := skeleton

	# The spine, top down.
	_joint(s.eye_tracker)
	_joint(s.head_tracker)
	_joint(s.neck_tracker)
	_joint(s.torso_tracker)
	_joint(s.hip_tracker)
	_bone(s.eye_tracker, s.head_tracker, s.head_tracker)
	_bone(s.head_tracker, s.neck_tracker, s.neck_tracker)
	_bone(s.neck_tracker, s.torso_tracker, s.torso_tracker)
	_bone(s.torso_tracker, s.hip_tracker, s.hip_tracker)

	for is_left in [true, false]:
		_arm(is_left)
		_leg(is_left)


func _arm(is_left: bool) -> void:
	var s := skeleton
	var shoulder := s.left_shoulder_tracker if is_left else s.right_shoulder_tracker
	var elbow := s.left_elbow_tracker if is_left else s.right_elbow_tracker
	var forearm := s.left_forearm_tracker if is_left else s.right_forearm_tracker
	var wrist := s.left_wrist_tracker if is_left else s.right_wrist_tracker
	var hand := s.left_hand_tracker if is_left else s.right_hand_tracker

	for joint in [shoulder, elbow, forearm, wrist, hand]:
		_joint(joint)
	_bone(s.neck_tracker, shoulder, s.torso_tracker)
	# The upper arm rolls with the shoulder and the forearm with its tracker,
	# which is where the arm's twist is spent.
	_bone(shoulder, elbow, shoulder)
	_bone(elbow, forearm, forearm)
	_bone(forearm, wrist, forearm)
	_bone(wrist, hand, hand)

	if not show_fingers:
		return
	for finger in StaticSkeleton.Finger.size():
		var previous := hand
		for phalanx in StaticSkeleton.Phalanx.size():
			var joint := s.finger_joint(is_left, finger, phalanx)
			if joint == null:
				return
			_joint(joint, true)
			_bone(previous, joint, joint, true)
			previous = joint
		# The last bone has no joint at its end; it runs its own length.
		var tip_length: float = StaticSkeleton.FINGER_LENGTHS[finger][
				StaticSkeleton.Phalanx.TIP] * s.hand_scale
		_bone(previous, null, previous, true, tip_length)


func _leg(is_left: bool) -> void:
	var s := skeleton
	var socket := s.left_hip_tracker if is_left else s.right_hip_tracker
	var knee := s.left_knee_tracker if is_left else s.right_knee_tracker
	var ankle := s.left_ankle_tracker if is_left else s.right_ankle_tracker
	var foot := s.left_foot_tracker if is_left else s.right_foot_tracker

	for joint in [socket, knee, ankle, foot]:
		_joint(joint)
	_bone(s.hip_tracker, socket, s.hip_tracker)
	_bone(socket, knee, socket)
	_bone(knee, ankle, knee)
	_bone(ankle, foot, foot)


func _joint(node: Node3D, finger := false) -> void:
	if node == null:
		return
	var mesh := MeshInstance3D.new()
	mesh.mesh = _finger_sphere if finger else _sphere
	mesh.material_override = joint_material
	add_child(mesh)
	_joint_nodes.append(node)
	_joint_meshes.append(mesh)


func _bone(from: Node3D, to: Node3D, roll: Node3D, finger := false, reach := 0.0) -> void:
	if from == null or roll == null or (to == null and reach <= 0.0):
		return
	var bone := Bone.new()
	bone.from = from
	bone.to = to
	bone.roll = roll
	bone.reach = reach
	bone.thickness = finger_bone_thickness if finger else bone_thickness
	bone.mesh = MeshInstance3D.new()
	bone.mesh.mesh = _box
	bone.mesh.material_override = bone_material
	add_child(bone.mesh)
	_bones.append(bone)


## A basis whose -Z runs along `direction`, rolled from the reference: its up
## axis where that is usable, its forward where the bone runs along its up -
## the spine and a hanging arm both do.
func _look_along(direction: Vector3, reference: Basis) -> Basis:
	var up := reference.y
	if absf(direction.dot(up)) > 0.9:
		up = -reference.z
	return Basis.looking_at(direction, up)


func _plain_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = color
	return material
