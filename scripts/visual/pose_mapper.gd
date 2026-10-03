class_name PoseMapper
extends Node

## The skeletal layer: poses the character model on the physical player every
## physics tick, from the physical layer's snapshot. It only reads the physical
## and static layers and writes nothing but the model's bones.
##
## The model (Body1, fitted in Blender to the static skeleton's proportions by
## tools/blender/fit_player_proportions.py) is posed where the physical body
## is, not where the static skeleton wants it: its legs where the body stands,
## its arms through the physical elbows to the physical hands, its fingers
## curled as far as the physical fingers are. The static skeleton gives only
## what the physical parts do not have: where the eyes are, and which way the
## torso, neck and hips face.
##
## Two kinds of bone:
## - a segment (torso, neck, arms, legs) runs between two of the physical
##   body's joints, turned about its own length toward a reference direction,
##   and lengthened or shortened along it to reach: its part stretches with it,
##   never thicker or thinner, so the model's joints stay on the physical ones
##   whatever the body does;
## - a rigid bone (head, eyes, collarbones, hands, finger roots, feet, toes)
##   keeps its shape on a frame of the physical body: the head on the eyes, a
##   hand on its physical hand, a foot on its sole.
## Each finger bone turns with its physical bone from the model's own rest:
## at the static skeleton's straight rest the model's finger is as modelled,
## and every bend the physical finger makes is added to it. The model's thumb
## so keeps its 18.7° tilt in front of the palm while the physical thumb lies
## flat (laid flat 2026-10-02 so a pressed palm lies flat; pointed along it,
## the model's thumb sank into the side of its palm).
##
## Every bone is made parentless when the model loads, each keeping where it
## stood, so a stretched bone does not stretch the bones below it. A skeleton's
## bones cannot carry the skew a stretched parent would pass on.

## After the physical layer has published this tick (Physical.finish_tick).
const SOLVE_PRIORITY := StaticSkeleton.SOLVE_PRIORITY + 30

const SIDES := ["Left", "Right"]
const FINGERS := ["Thumb", "Index", "Middle", "Ring", "Little"]
const PHALANGES := ["Proximal", "Intermediate", "Distal"]
const THUMB_PHALANGES := ["Metacarpal", "Proximal", "Distal"]
const TORSO := ["Hips", "Spine", "Chest", "Neck"]
## The model faces +Z, its right hand toward -X. The static skeleton's frames
## face -Z, their right toward +X.
const MODEL_FORWARD := Vector3.BACK
const MODEL_RIGHT := Vector3.LEFT
## How much an elbow or knee must bend before its own bend, rather than the
## way the limb would bend, turns its bones: |first - second| of the two bones'
## directions across the bone, 0.1 being about 6° from straight or folded.
const HINGE_BIAS := 0.1

## The model's skeleton. Its bones are Godot's humanoid profile's.
@export var skeleton: Skeleton3D
## The model, hidden while the physical layer has no body to follow (the
## kinematic comparison body publishes none).
@export var model: Node3D

var _physical: PlayerPhysical
var _static: StaticSkeleton
var _ready_to_pose := false

## Per bone, by index: where it stood in the model's rest pose, in skeleton
## space, and for a segment its turn about its length relative to its
## reference direction, and its length between the joints it runs between.
var _rest: Array[Transform3D] = []
var _correction: Array[Basis] = []
var _length := PackedFloat32Array()

var _torso: PackedInt32Array
var _neck: int
var _head: int
var _eyes: PackedInt32Array
## The rest frames the rigid bones hang on: the head's at the eyes, the
## torso's from between the hip sockets up to the neck, each hand's at its
## wrist and each foot's on the ground under its ankle. Static skeleton axes:
## -Z forward (toward the fingers, the toes), +Y up (toward the thumb).
var _head_frame: Transform3D
var _torso_frame: Transform3D
var _torso_length := 0.0
var _hand_frame: Array[Transform3D] = [Transform3D.IDENTITY, Transform3D.IDENTITY]
var _sole_frame: Array[Transform3D] = [Transform3D.IDENTITY, Transform3D.IDENTITY]
## Per side.
var _shoulder: PackedInt32Array
var _upper_arm: PackedInt32Array
var _lower_arm: PackedInt32Array
var _hand: PackedInt32Array
var _upper_leg: PackedInt32Array
var _lower_leg: PackedInt32Array
var _foot: PackedInt32Array
var _toes: PackedInt32Array
## Per side, finger and phalanx (side * 15 + finger * 3 + phalanx, the
## snapshot's finger order).
var _fingers: PackedInt32Array
## Which way each elbow faced last tick, in the torso's frame, for an arm too
## straight to tell: a straight arm keeps facing the way it last bent, turning
## with the body.
var _elbow_facing: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]


func attach(physical: PlayerPhysical, rig: PlayerRig) -> void:
	_physical = physical
	_static = rig.skeleton


func _ready() -> void:
	process_physics_priority = SOLVE_PRIORITY
	if skeleton == null or _static == null:
		push_error("PoseMapper: skeleton and the rig must both be assigned.")
		return
	# The static skeleton builds its fingers when it is ready.
	if not _static.is_node_ready():
		await _static.ready
	_find_bones()
	_flatten()
	_measure_rest()
	_ready_to_pose = true


func _physics_process(_delta: float) -> void:
	if not _ready_to_pose:
		return
	var state := _physical.snapshot
	var has_body := state.body_joints.size() == BodyParts.Joint.size() and state.hand_strength > 0.0
	if model != null:
		model.visible = has_body
	if not has_body:
		return
	var to_model := skeleton.global_transform.affine_inverse()
	var joints := state.body_joints

	# Torso: between the hip sockets and the neck, facing as the static torso does.
	var hips := (joints[BodyParts.Joint.LEFT_HIP] + joints[BodyParts.Joint.RIGHT_HIP]) * 0.5
	var neck := joints[BodyParts.Joint.NECK]
	var torso_forward := -_static.torso_tracker.global_basis.z
	var torso := Transform3D(_frame(neck - hips, -torso_forward), hips)
	var torso_stretch := (neck - hips).length() / _torso_length
	for i in 3:
		var bone := _torso[i]
		var from := _on_torso(torso, torso_stretch, _rest[bone].origin)
		var to := _on_torso(torso, torso_stretch, _rest[_torso[i + 1]].origin)
		_pose(bone, to_model * _segment(bone, from, to, torso_forward))

	# Head on the eyes; the neck from its base up to the head.
	var eyes := _static.eye_tracker.global_transform.orthonormalized()
	var head := eyes * _head_frame.affine_inverse()
	_pose(_head, to_model * head * _rest[_head])
	for eye in _eyes:
		_pose(eye, to_model * head * _rest[eye])
	var neck_forward := -_static.neck_tracker.global_basis.z
	_pose(_neck, to_model * _segment(_neck, neck, (head * _rest[_head]).origin, neck_forward))

	for side in 2:
		_pose_arm(side, state, torso, to_model)
		_pose_leg(side, state, to_model)


func _pose_arm(side: int, state: PoseSnapshot, torso: Transform3D, to_model: Transform3D) -> void:
	var joints := state.body_joints
	var shoulder := joints[BodyParts.Joint.LEFT_SHOULDER + side]
	var elbow := joints[BodyParts.Joint.LEFT_ELBOW + side]
	var wrist := joints[BodyParts.Joint.LEFT_WRIST + side]
	var hand_basis := state.hands[side].basis.orthonormalized()
	# The collarbone keeps its shape, its outer end on the shoulder socket.
	var collar_rest := Transform3D(_torso_frame.basis, _rest[_upper_arm[side]].origin)
	var collar := Transform3D(torso.basis, shoulder) * collar_rest.affine_inverse()
	_pose(_shoulder[side], to_model * collar * _rest[_shoulder[side]])
	# The upper arm faces the way the elbow bends, or straight, the way it last
	# faced (the drive's pole jumps as an arm straightens: a twist of 93° in one
	# tick with the arm still); the forearm turns with the hand.
	var elbow_faces := _hinge_facing(shoulder, elbow, wrist, torso.basis * _elbow_facing[side])
	var across := elbow_faces.slide((elbow - shoulder).normalized())
	if not across.is_zero_approx():
		_elbow_facing[side] = (torso.basis.inverse() * across).normalized()
	_pose(_upper_arm[side], to_model * _segment(_upper_arm[side], shoulder, elbow, elbow_faces))
	_pose(_lower_arm[side], to_model * _segment(_lower_arm[side], elbow, wrist, hand_basis.y))
	var hand := Transform3D(hand_basis, wrist) * _hand_frame[side].affine_inverse()
	_pose(_hand[side], to_model * hand * _rest[_hand[side]])
	_pose_fingers(side, state, hand, to_model)


## Each finger's root stays on the model's hand; each bone turns as its
## physical bone has from the straight rest, and the next joint is the model's
## length along it.
func _pose_fingers(side: int, state: PoseSnapshot, hand: Transform3D, to_model: Transform3D) -> void:
	var physical := state.finger_bones.size() == 30
	for finger in 5:
		var joint := Vector3.ZERO
		for phalanx in 3:
			var index := side * 15 + finger * 3 + phalanx
			var bone := _fingers[index]
			if not physical:
				_pose(bone, to_model * hand * _rest[bone])
				continue
			if phalanx == 0:
				joint = (hand * _rest[bone]).origin
			var basis := state.finger_bones[index].basis.orthonormalized() * _correction[bone]
			_pose(bone, to_model * Transform3D(basis, joint))
			joint += basis.y * _length[bone]


func _pose_leg(side: int, state: PoseSnapshot, to_model: Transform3D) -> void:
	var joints := state.body_joints
	var hip := joints[BodyParts.Joint.LEFT_HIP + side]
	var knee := joints[BodyParts.Joint.LEFT_KNEE + side]
	# The foot stands on the physical sole, its ankle the model's own height above it.
	var foot := state.body_soles[side] * _sole_frame[side].affine_inverse()
	var ankle := (foot * _rest[_foot[side]]).origin
	var right := _static.hip_tracker.global_basis.x
	_pose(_upper_leg[side], to_model * _segment(_upper_leg[side], hip, knee,
			_knee_facing(hip, knee, ankle, knee - hip, right)))
	_pose(_lower_leg[side], to_model * _segment(_lower_leg[side], knee, ankle,
			_knee_facing(hip, knee, ankle, ankle - knee, right)))
	_pose(_foot[side], to_model * foot * _rest[_foot[side]])
	_pose(_toes[side], to_model * foot * _rest[_toes[side]])


## Which way an elbow faces: the way it sticks out, between its two bones, or
## on an arm too straight or too folded to tell, `otherwise` (the way it last
## faced). Measured on the bones, not against the line from shoulder to wrist,
## which swings as a pressed hand nears the shoulder.
static func _hinge_facing(from: Vector3, joint: Vector3, to: Vector3, otherwise: Vector3) -> Vector3:
	return (joint - from).normalized() - (to - joint).normalized() + otherwise.normalized() * HINGE_BIAS


## Which way a knee faces, seen from one of its bones (`along`, hip to knee or
## knee to ankle): the way it bends, and on a leg too straight or too folded to
## tell, a quarter turn forward of that bone about the hips' left-right axis
## (`right`): a standing leg's front forward, a raised thigh's up, a shin
## folded back under it down. A knee bends only forward: bent the other way
## (the physical legs fold so, drawn up when climbing), it keeps its front in
## front rather than turning the leg round. Not the static skeleton's knee
## pole, which, taken from the foot, swings round a straight trailing leg (49°
## in one tick).
static func _knee_facing(hip: Vector3, knee: Vector3, ankle: Vector3, along: Vector3, right: Vector3) -> Vector3:
	var front := right.cross(along).normalized()
	var bend := ((knee - hip).normalized() - (ankle - knee).normalized()).slide(along.normalized())
	bend -= front * minf(bend.dot(front), 0.0)
	return bend + front * HINGE_BIAS


## A segment bone's pose between `from` and `to`, turned about its length so
## its rest relation to `toward` holds, and stretched along it to reach.
func _segment(bone: int, from: Vector3, to: Vector3, toward: Vector3) -> Transform3D:
	var span := to - from
	var basis := _frame(span, toward) * _correction[bone]
	return Transform3D(basis.scaled_local(Vector3(1.0, span.length() / _length[bone], 1.0)), from)


func _pose(bone: int, pose: Transform3D) -> void:
	skeleton.set_bone_pose(bone, pose)


## A point of the model's rest torso, carried onto the live torso: turned with
## it and stretched along its length.
func _on_torso(torso: Transform3D, stretch: float, point: Vector3) -> Vector3:
	var local := _torso_frame.affine_inverse() * point
	local.y *= stretch
	return torso * local


## A right-handed basis with +Y along `axis` and +Z toward `toward` (the part
## of it across the axis).
static func _frame(axis: Vector3, toward: Vector3) -> Basis:
	var y := axis.normalized()
	var z := toward.slide(y)
	if z.length_squared() < 1e-10:
		z = Vector3.FORWARD.slide(y) if absf(y.z) < 0.9 else Vector3.UP.slide(y)
	z = z.normalized()
	return Basis(y.cross(z), y, z)


func _find_bones() -> void:
	for name: String in TORSO:
		_torso.append(_bone(name))
	_neck = _torso[3]
	_head = _bone("Head")
	_eyes = PackedInt32Array([_bone("LeftEye"), _bone("RightEye")])
	for side: String in SIDES:
		_shoulder.append(_bone(side + "Shoulder"))
		_upper_arm.append(_bone(side + "UpperArm"))
		_lower_arm.append(_bone(side + "LowerArm"))
		_hand.append(_bone(side + "Hand"))
		_upper_leg.append(_bone(side + "UpperLeg"))
		_lower_leg.append(_bone(side + "LowerLeg"))
		_foot.append(_bone(side + "Foot"))
		_toes.append(_bone(side + "Toes"))
		for finger in 5:
			var names: Array = THUMB_PHALANGES if finger == 0 else PHALANGES
			for phalanx in 3:
				_fingers.append(_bone(side + FINGERS[finger] + names[phalanx]))


func _bone(bone_name: String) -> int:
	var bone := skeleton.find_bone(bone_name)
	if bone < 0:
		push_error("PoseMapper: the model has no bone named %s." % bone_name)
	return bone


## Makes every bone parentless, standing where it stood.
func _flatten() -> void:
	var count := skeleton.get_bone_count()
	_rest.resize(count)
	for bone in count:
		_rest[bone] = skeleton.get_bone_global_rest(bone)
	for bone in count:
		skeleton.set_bone_parent(bone, -1)
	for bone in count:
		skeleton.set_bone_rest(bone, _rest[bone])
		skeleton.set_bone_pose(bone, _rest[bone])


## Measures the rest pose against the frames the bones are posed on.
func _measure_rest() -> void:
	var count := skeleton.get_bone_count()
	_correction.resize(count)
	_length.resize(count)
	var hips := (_rest[_upper_leg[0]].origin + _rest[_upper_leg[1]].origin) * 0.5
	var neck := _rest[_neck].origin
	_torso_frame = Transform3D(_frame(neck - hips, -MODEL_FORWARD), hips)
	_torso_length = (neck - hips).length()
	for i in 3:
		_measure_segment(_torso[i], _rest[_torso[i + 1]].origin, MODEL_FORWARD)
	_measure_segment(_neck, _rest[_head].origin, MODEL_FORWARD)
	var eyes := (_rest[_eyes[0]].origin + _rest[_eyes[1]].origin) * 0.5
	_head_frame = Transform3D(_frame(Vector3.UP, -MODEL_FORWARD), eyes)
	for side in 2:
		var hand := _rest[_hand[side]]
		_hand_frame[side] = Transform3D(_rest_hand_basis(side), hand.origin)
		var elbow := _rest[_lower_arm[side]].origin
		var shoulder := _rest[_upper_arm[side]].origin
		var bend := (elbow - shoulder).slide((hand.origin - shoulder).normalized())
		var elbow_faces := _hinge_facing(shoulder, elbow, hand.origin, bend)
		_measure_segment(_upper_arm[side], elbow, elbow_faces)
		var across := elbow_faces.slide((elbow - shoulder).normalized())
		_elbow_facing[side] = (_torso_frame.basis.inverse() * across).normalized()
		_measure_segment(_lower_arm[side], hand.origin, _hand_frame[side].basis.y)
		var ankle := _rest[_foot[side]].origin
		var knee := _rest[_lower_leg[side]].origin
		var hip := _rest[_upper_leg[side]].origin
		_measure_segment(_upper_leg[side], knee, _knee_facing(hip, knee, ankle, knee - hip, MODEL_RIGHT))
		_measure_segment(_lower_leg[side], ankle, _knee_facing(hip, knee, ankle, ankle - knee, MODEL_RIGHT))
		var toes := (_rest[_toes[side]].origin - ankle).slide(Vector3.UP)
		_sole_frame[side] = Transform3D(_frame(Vector3.UP, -toes), Vector3(ankle.x, 0.0, ankle.z))
		_measure_fingers(side)


func _measure_segment(bone: int, to: Vector3, toward: Vector3) -> void:
	var span := to - _rest[bone].origin
	_correction[bone] = _frame(span, toward).inverse() * _rest[bone].basis
	_length[bone] = span.length()


## The model's rest hand in the static skeleton's hand axes: -Z toward the
## fingers, +Y toward the thumb, the middle finger's root where the static
## hand has it (a little toward the thumb from straight ahead of the wrist).
func _rest_hand_basis(side: int) -> Basis:
	var wrist := _rest[_hand[side]].origin
	var middle := _rest[_fingers[side * 15 + 2 * 3]].origin
	var index := _rest[_fingers[side * 15 + 1 * 3]].origin
	var little := _rest[_fingers[side * 15 + 4 * 3]].origin
	var forward := (middle - wrist).normalized()
	var thumb := (index - little).slide(forward).normalized()
	var root := StaticSkeleton.FINGER_ROOTS[StaticSkeleton.Finger.MIDDLE] * _static.hand_scale
	var aside := atan2(root.y, root.x + _static.wrist_offset.z)
	var fingers := forward * cos(aside) - thumb * sin(aside)
	return _frame(thumb * cos(aside) + forward * sin(aside), -fingers)


## Each finger bone's rest against the static skeleton's straight finger laid
## on the model's rest hand, and its length to the next joint.
func _measure_fingers(side: int) -> void:
	var is_left := side == 0
	var hand := _hand_frame[side].basis
	for finger in 5:
		var straight := Transform3D.IDENTITY
		for phalanx in 3:
			straight *= _static.finger_rest(is_left, finger, phalanx)
			var bone := _fingers[side * 15 + finger * 3 + phalanx]
			_correction[bone] = (hand * straight.basis).inverse() * _rest[bone].basis
			if phalanx < 2:
				_length[bone] = _rest[bone].origin.distance_to(_rest[_fingers[side * 15 + finger * 3 + phalanx + 1]].origin)
