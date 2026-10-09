class_name Grabbable
extends Node

## Marks its parent RigidBody3D as something a hand may grab. Grabbing is
## opt-in (decided 2026-09-25): a bare rigid body can be pushed, not grabbed.
##
## It puts the body on the Grabbable layer, where the hands look for things to
## grab, and lets a hand find this component from the body. While hands hold
## the body it keeps which hands hold it, the first to grab leading, and the
## body's own layers: it puts the body on the Held layer at the first grab and
## gives the layers back once the last hand has let go and is clear of it
## (2026-09-27, two-handed holds). While a hand brings the body into its seat
## (2026-10-02, HandGrab), the body is frozen and on the Seating layer, meeting
## nothing; seated, it stays there until clear of what a held body meets, then
## goes onto the Held layer. Only the hands' HandGrab calls these.
##
## A held body meets the hands, but never the hands holding it (2026-10-03, at
## the player's request): each hand's body is a collision exception of it from
## that hand's grab until the hand has let go and is clear of it, so a hold
## never fights its own palm, fingers or forearm, while the other hand blocks,
## pushes and is pushed by it as by any prop.
##
## Its handles are shapes a hand holds only one way (2026-09-27): straight
## along the fist, with the palm on a side (see handles). The rest of the body
## is held as the hand meets it.
##
## The body is drawn where its last physics step left it, without physics
## interpolation (rung 8.1, 2026-10-02): the avatar is posed on the tick, so an
## interpolated body is drawn behind the hand holding it, by up to its motion
## in a tick (10-13 cm at a run in the harness; the player saw the held object
## drift out of the hand while running). Physics runs at the display's rate,
## so interpolation gains a loose body little.
##
## A body may change what it is when picked up or let go (2026-10-04, a leaf
## pile that becomes a ball in the hand: LeafLitter). grabbed comes before the
## first grab keeps the body's layers, so it keeps what the body became, and
## set_own_layers changes the layers a let-go body gets back.

## A hand grabs the body: emitted before the grab keeps the body's own layers.
signal grabbed(hand: HandGrab)
## The last hand holding the body has let it go (a throw has already set its
## velocity).
signal released(hand: HandGrab)

## The Grabbable collision layer (layer 3), where the hands search.
const GRABBABLE_LAYER := 4
## While held, the body is on the Held layer (layer 4), meeting the level,
## loose props, what the other hand holds, the hands not holding it and
## enemies, but not the player's body: section 6.8.
const HELD_LAYER := 8
const HELD_MASK := 1 | 2 | 8 | 32 | 256
## While a hand seats it, and until it is clear of what HELD_MASK meets, the
## body is on the Seating layer (layer 11), meeting nothing: only the hands'
## grab search and fingers look for it. An empty mask alone is not enough: a
## frozen body on the Held layer with no mask still flung a prop whose mask
## has Held 1 m (harness, 2026-10-02).
const SEATING_LAYER := 1024
const _META := &"grabbable"

## Whether hands may grab the body now.
@export var enabled := true
## Whether hands may grab the body while it is frozen and no hand holds it
## (a leaf pile lying fixed where it is); otherwise a frozen body is fixed.
@export var grab_frozen := false
## Shapes of the body held as handles, each a box, capsule or cylinder whose
## own Y runs along the handle. A hand beside one holds it with the handle's Y
## along the fist's grip, toward the thumb or the little finger, and its palm
## on one of the handle's sides across the shape's Z: of those four, the one
## nearest how the hand meets it. It holds it where it meets it, the palm wholly
## on the handle. A hand beyond either end cannot hold it there.
@export var handles: Array[CollisionShape3D] = []
## How far a hand holds its handles leaned from the fist's grip line: their +Y
## end toward the fingers (so a sword leans forward), and held the other way
## round, toward the wrist, along the same line through the fist.
@export_range(-45.0, 45.0, 0.5, "radians_as_degrees") var handle_lean := 0.0

## The body this marks.
var body: RigidBody3D
## The hands holding the body, the lead (the first to grab) first.
var holders: Array[HandGrab] = []
## Whether the body, held, meets what a held body meets (the Held layer); not
## while a hand seats it, nor until it is clear of everything once seated.
var solid := true

# Hands that have let go and may still overlap the body.
var _clearing: Array[HandGrab] = []
# The body's own layers, contact reporting and freeze mode, kept from its
# first grab until the last hand that held it is clear of it.
var _saved := false
var _freeze_mode := RigidBody3D.FREEZE_MODE_STATIC
var _layer := 0
var _mask := 0
var _monitor := false
var _reported := 0


func _enter_tree() -> void:
	body = get_parent() as RigidBody3D
	if body == null:
		push_error("Grabbable: its parent must be a RigidBody3D.")
		return
	body.collision_layer |= GRABBABLE_LAYER
	body.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	body.set_meta(_META, self)


func _ready() -> void:
	for handle in handles:
		if handle == null or handle_extent(handle.shape) == Vector3.ZERO:
			push_error("Grabbable: a handle must be a box, capsule or cylinder shape.")


func _exit_tree() -> void:
	if body != null and body.has_meta(_META):
		body.remove_meta(_META)


## The Grabbable marking `object`, or null if it has none.
static func of(object: Object) -> Grabbable:
	if object == null or not object.has_meta(_META):
		return null
	return object.get_meta(_META) as Grabbable


## A handle shape's half extents in its own axes: along the handle (Y; a
## capsule's straight side only) and across it toward the palm (Z), with X the
## rest. Zero for any other shape.
static func handle_extent(shape: Shape3D) -> Vector3:
	if shape is BoxShape3D:
		return (shape as BoxShape3D).size * 0.5
	if shape is CylinderShape3D:
		var cylinder := shape as CylinderShape3D
		return Vector3(cylinder.radius, cylinder.height * 0.5, cylinder.radius)
	if shape is CapsuleShape3D:
		var capsule := shape as CapsuleShape3D
		return Vector3(capsule.radius, maxf(capsule.height * 0.5 - capsule.radius, 0.0), capsule.radius)
	return Vector3.ZERO


## Whether `hand` may grab the body now: nothing holds it, or one other hand
## holds it. A hand may take back what it or the other hand has let go and is
## not yet clear of (with the hand kept by it, that is up to restore_limit).
func open_to(hand: HandGrab) -> bool:
	if not enabled:
		return false
	return holders.is_empty() or (holders.size() == 1 and holders[0] != hand)


## `hand` grabs the body. The first grab puts it on the Held layer, reporting
## its contacts, so a hand can tell whether it rests on something. A grab
## while a hand that let go is still clearing it keeps what the first saved:
## the body is on the Held layer then, not its own. From now the body does not
## meet `hand` (a hand taking back what it is still clearing never stopped
## ignoring it; Jolt counts each exception added, so it is added once).
func hold(hand: HandGrab) -> void:
	grabbed.emit(hand)
	if hand not in holders and hand not in _clearing:
		body.add_collision_exception_with(hand.drive.hand)
	_clearing.erase(hand)
	if not _saved:
		_saved = true
		_layer = body.collision_layer
		_mask = body.collision_mask
		_monitor = body.contact_monitor
		_reported = body.max_contacts_reported
		_freeze_mode = body.freeze_mode
		body.collision_layer = HELD_LAYER
		body.collision_mask = HELD_MASK
		body.contact_monitor = true
		body.max_contacts_reported = maxi(_reported, 4)
	holders.append(hand)


## A hand starts seating the body: frozen, it moves only as the hand places
## it, and meets nothing on the way.
func seat() -> void:
	body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	body.freeze = true
	body.collision_layer = SEATING_LAYER
	body.collision_mask = 0
	solid = false
	body.sleeping = false


## The body is in its seat: physics moves it again, still meeting nothing
## until solidify().
func seated() -> void:
	body.freeze = false
	body.sleeping = false


## The held body meets what a held body meets (the Held layer).
func solidify() -> void:
	body.collision_layer = HELD_LAYER
	body.collision_mask = HELD_MASK
	solid = true


## `hand` lets go. The body keeps the Held layer until every hand that let go
## is clear of it (clear_of()).
func let_go(hand: HandGrab) -> void:
	holders.erase(hand)
	if hand not in _clearing:
		_clearing.append(hand)
	if holders.is_empty():
		released.emit(hand)


## Changes the body's own layers: at once if no hand holds it or is clearing
## it, otherwise the ones it gets back once they are all clear of it.
func set_own_layers(layer: int, mask: int) -> void:
	if _saved:
		_layer = layer
		_mask = mask
	else:
		body.collision_layer = layer
		body.collision_mask = mask


## `hand`, having let go, is clear of the body, which meets it again. Once no
## hand holds it and every hand that let go is clear, the body gets its own
## layers back.
func clear_of(hand: HandGrab) -> void:
	if hand in _clearing and hand not in holders:
		body.remove_collision_exception_with(hand.drive.hand)
	_clearing.erase(hand)
	if holders.is_empty() and _clearing.is_empty() and _saved:
		_saved = false
		body.collision_layer = _layer
		body.collision_mask = _mask
		body.contact_monitor = _monitor
		body.max_contacts_reported = _reported
		body.freeze_mode = _freeze_mode


## The bodies of the hands the body does not meet (those holding it, and those
## that let go and are not yet clear of it), for shape queries, which do not
## honour collision exceptions.
func ignored_hands() -> Array[RID]:
	var rids: Array[RID] = []
	for hand in holders + _clearing:
		rids.append(hand.drive.hand.get_rid())
	return rids


## The other hand holding the body with `hand`, or null.
func partner_of(hand: HandGrab) -> HandGrab:
	for holder in holders:
		if holder != hand:
			return holder
	return null
