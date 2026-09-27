extends LocomotionModule

## Keeps the body under the head while the player moves in their room.
##
## The body is asked to move at the head's own walking velocity (its movement
## in the room, turned into world space), plus a correction that closes any
## remaining gap between the footprint of the head's centre (behind the eyes)
## and the feet. With the head's velocity fed forward, a steady walk leaves no
## gap; the correction only mops up starts, stops and anything the body was
## held back by. The rig
## carrier leaves this following out of what it carries, so it never moves
## the view.

## Gaps smaller than this are left alone, so tracking jitter does not keep
## the body shuffling.
@export_range(0.0, 0.1, 0.005, "suffix:m") var dead_zone := 0.01
## The remaining gap is closed at this time constant.
@export_range(0.05, 2.0, 0.01, "suffix:s") var follow_time := 0.2
## Following is never asked to go faster than this, which also caps the
## effect of a tracking jump.
@export_range(0.5, 10.0, 0.1, "suffix:m/s") var max_follow_speed := 3.0

var _last_head := Vector3.ZERO
# Physics frame of the last measurement: after a skipped tick (recovery took
# over) the head's movement since then is not a walking velocity.
var _measured_on := -2


func contribute(frame: LocomotionFrame, delta: float) -> void:
	var lead := physical.carrier.head_lead
	var distance := lead.length()
	var correction := Vector3.ZERO
	if distance > dead_zone:
		correction = lead / distance * ((distance - dead_zone) / follow_time)
	frame.follow = (_head_velocity(delta) + correction).limit_length(max_follow_speed)


## The horizontal velocity of the head's centre from the player's own
## movement in the room, in world space. The centre, not the eyes: the eyes
## swing round it as the head turns, and turning the head is not walking.
func _head_velocity(delta: float) -> Vector3:
	var head := rig.to_local(rig.head_centre())
	var tick := Engine.get_physics_frames()
	var continuous := tick - _measured_on == 1
	var moved := head - _last_head
	_last_head = head
	_measured_on = tick
	if not continuous:
		return Vector3.ZERO
	var velocity := rig.global_basis * Vector3(moved.x, 0.0, moved.z) / delta
	return Vector3(velocity.x, 0.0, velocity.z)
