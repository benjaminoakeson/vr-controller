extends LocomotionModule

## Keeps the player safe when something goes wrong, and takes over the tick
## while it does:
## - while the head is not tracked, the body holds still (gravity still acts);
## - a body that falls out of the level is respawned where it started;
## - a head that stays far ahead of the body, which means the player walked
##   through something the body could not follow, is brought back over it.
## Both moves happen with the view blacked out.

enum Move { NONE, RECENTRE, RESPAWN }

## Below this world height the body has left the level.
@export var kill_height := -20.0
## A head leading the body by more than this, for longer than
## `lead_limit_time`, is recentred.
@export_range(0.2, 2.0, 0.05, "suffix:m") var lead_limit := 0.6
@export_range(0.0, 3.0, 0.05, "suffix:s") var lead_limit_time := 0.5
## How long the view has to go black before the move. Must be at least the
## view fade's darkening time.
@export_range(0.05, 1.0, 0.01, "suffix:s") var blackout_time := 0.2
## How long the view stays black after the move.
@export_range(0.0, 1.0, 0.01, "suffix:s") var black_hold := 0.1

var _pending := Move.NONE
var _moved := false
var _timer := 0.0
var _over_limit_for := 0.0
var _spawn := Vector3.ZERO
var _spawn_known := false


func contribute(frame: LocomotionFrame, delta: float) -> void:
	var carrier := physical.carrier
	var body := physical.body
	if not _spawn_known:
		_spawn = body.global_position
		_spawn_known = true
	if _pending == Move.NONE:
		_watch(carrier, body, delta)
	if _pending != Move.NONE:
		_continue_move(carrier, body, delta)
		frame.blackout = 1.0
	if _pending != Move.NONE or not carrier.head_tracked:
		frame.hold = true
		frame.exclusive = true


func _watch(carrier: RigCarrier, body: CapsuleBody, delta: float) -> void:
	if body.global_position.y < kill_height:
		_start(Move.RESPAWN)
		return
	if carrier.head_tracked and carrier.head_lead.length() > lead_limit:
		_over_limit_for += delta
		if _over_limit_for >= lead_limit_time:
			_start(Move.RECENTRE)
	else:
		_over_limit_for = 0.0


func _start(move: Move) -> void:
	_pending = move
	_moved = false
	_timer = 0.0
	_over_limit_for = 0.0


## Waits for the view to be black, moves, holds it black a moment, lets go.
func _continue_move(carrier: RigCarrier, body: CapsuleBody, delta: float) -> void:
	_timer += delta
	if not _moved and _timer >= blackout_time:
		match _pending:
			Move.RECENTRE:
				carrier.move_rig(-carrier.head_lead)
			Move.RESPAWN:
				carrier.relocate(_spawn - body.global_position)
		_moved = true
		_timer = 0.0
	elif _moved and _timer >= black_hold:
		_pending = Move.NONE
