class_name HandStrikes
extends Node

## Publishes the strikes one hand makes (the strike model, documents/
## strike_model.md) to the snapshot, for the recorder. These are its own strikes
## (a punch or a slap: the hand body's Striker), the strikes of what it holds,
## and the first strike by what it last let go of, within let_go_time (a throw
## or a drop). It only listens; HandGrab is unchanged.

## Emitted for each strike counted for this hand, after the snapshot has it.
signal struck(strike: Strike, source: Source)

enum Source {
	NONE,
	## The hand itself struck.
	HAND,
	## Something the hand held struck.
	HELD,
	## Something the hand was last to let go of struck, within let_go_time.
	LET_GO,
}

@export var grab: HandGrab
## The hand body's own Striker.
@export var striker: Striker
## How long after the hand lets go of something its first strike still counts
## as this hand's, in seconds.
@export_range(0.0, 10.0, 0.1, "suffix:s") var let_go_time := 2.0

var _physical: DynamicPhysical
var _side := 0
var _clock := 0.0
# The Striker of what the hand holds or last held, and whether it still holds
# it; when it let go, and whether a strike has been counted for that since.
var _held: Striker
var _holding := false
var _let_go_at := -INF
var _let_go_counted := true


func attach(_rig: PlayerRig, physical: DynamicPhysical) -> void:
	_physical = physical
	_side = grab.drive.side
	striker.struck.connect(_on_hand_struck)


func _ready() -> void:
	if grab == null or striker == null:
		push_error("HandStrikes: grab and striker must both be assigned.")
		set_physics_process(false)
		return
	# After the hand's grab (+4) has taken hold or let go this tick.
	process_physics_priority = StaticSkeleton.SOLVE_PRIORITY + 8


func _exit_tree() -> void:
	if is_instance_valid(_held) and _held.struck.is_connected(_on_held_struck):
		_held.struck.disconnect(_on_held_struck)


func _physics_process(delta: float) -> void:
	_clock += delta
	# While idle, the grab's target is only a candidate.
	var held := Striker.of(grab.target) if grab.state != HandGrab.State.IDLE else null
	if held != null:
		if held != _held:
			_follow(held)
		_holding = true
	elif _holding:
		_holding = false
		_let_go_at = _clock
		# Let go while the other hand still holds it: not this hand's throw.
		var grabbable := Grabbable.of(_held.body) if is_instance_valid(_held) else null
		_let_go_counted = grabbable != null and not grabbable.holders.is_empty()


func _follow(held: Striker) -> void:
	if is_instance_valid(_held) and _held.struck.is_connected(_on_held_struck):
		_held.struck.disconnect(_on_held_struck)
	_held = held
	_held.struck.connect(_on_held_struck)


func _on_hand_struck(strike: Strike) -> void:
	_publish(strike, Source.HAND)


func _on_held_struck(strike: Strike) -> void:
	if strike.held_by & (1 << _side):
		_publish(strike, Source.HELD)
	elif strike.held_by == 0 and not _holding and not _let_go_counted \
			and _clock - _let_go_at <= let_go_time:
		_let_go_counted = true
		_publish(strike, Source.LET_GO)


func _publish(strike: Strike, source: Source) -> void:
	var snapshot := _physical.snapshot
	snapshot.strikes[_side] += 1
	snapshot.last_strikes[_side] = strike
	snapshot.strike_sources[_side] = source
	struck.emit(strike, source)
