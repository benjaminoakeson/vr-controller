extends RefCounted

## Stands in for the headset and controllers when there is no XR runtime.
##
## It registers head and hand trackers with the XRServer under the names the
## OpenXR runtime would use, so the player scene's XRCamera3D and
## XRController3D nodes follow them without any change to gameplay code.
## Poses are in the XR origin's space - the player's room - exactly as a real
## runtime reports them. Only for use with XR disabled (`--xr-mode off`).

## A relaxed standing pose, in metres, before the facing is applied.
const HEAD_HEIGHT := 1.7
const HAND_REST := Vector3(0.22, 1.0, -0.25)

## Where the head is in the room and which way it faces, in radians about +Y
## from facing -Z.
var head_position := Vector3(0.0, HEAD_HEIGHT, 0.0)
var yaw := 0.0
## Hand positions relative to the head's footprint on the floor, in the
## head's facing: X to the right, Y up, -Z ahead.
var left_hand := Vector3(-HAND_REST.x, HAND_REST.y, HAND_REST.z)
var right_hand := HAND_REST
var stick := Vector2.ZERO
var left_grip := 0.0
var right_grip := 0.0

var _head: XRPositionalTracker
var _left: XRControllerTracker
var _right: XRControllerTracker


func _init() -> void:
	_head = XRPositionalTracker.new()
	_head.type = XRServer.TRACKER_HEAD
	_head.name = &"head"
	_left = _controller(&"left_hand", XRPositionalTracker.TRACKER_HAND_LEFT)
	_right = _controller(&"right_hand", XRPositionalTracker.TRACKER_HAND_RIGHT)
	for tracker: XRPositionalTracker in [_head, _left, _right]:
		XRServer.add_tracker(tracker)
	apply()


## Faces the head the way a world direction points, ignoring its height.
func face(direction: Vector3) -> void:
	yaw = atan2(-direction.x, -direction.z)


## Pushes the current values to the trackers. Call once per physics tick,
## before the player's nodes process.
func apply() -> void:
	var facing := Basis(Vector3.UP, yaw)
	var footprint := Vector3(head_position.x, 0.0, head_position.z)
	_pose(_head, Transform3D(facing, head_position))
	_pose(_left, Transform3D(facing, footprint + facing * left_hand))
	_pose(_right, Transform3D(facing, footprint + facing * right_hand))
	_left.set_input(&"primary", stick)
	_left.set_input(&"grip", left_grip)
	_right.set_input(&"grip", right_grip)


## Removes the trackers, so a following test starts clean.
func release() -> void:
	for tracker: XRPositionalTracker in [_head, _left, _right]:
		XRServer.remove_tracker(tracker)


func _controller(tracker_name: StringName, hand: XRPositionalTracker.TrackerHand) -> XRControllerTracker:
	var tracker := XRControllerTracker.new()
	tracker.type = XRServer.TRACKER_CONTROLLER
	tracker.name = tracker_name
	tracker.hand = hand
	return tracker


func _pose(tracker: XRPositionalTracker, transform: Transform3D) -> void:
	tracker.set_pose(&"default", transform, Vector3.ZERO, Vector3.ZERO,
			XRPose.XR_TRACKING_CONFIDENCE_HIGH)
