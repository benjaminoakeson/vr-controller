class_name StrikeSparks
extends Node

## Throws sparks where its body's strikes land on certain materials: the
## flint's on stone (2026-10-05). One burst a strike (the Striker's rules: a
## touch that closes fast enough, once), from the struck point, the way the
## strike travelled. The sparks follow whichever piece moved, sliding across the
## other (decided with the player: swing the flint and they follow the flint;
## swing the stone into a still flint and they follow the stone). A skim throws a
## tight fan forward, low over the surface; a blow straight in splashes a wide
## cone off it. Faster strikes throw more sparks, faster.
##
## Visual only: it listens to its body's Striker and changes nothing.

## Emitted for each burst: from where (world space), the way the sparks mainly
## go (unit), and how strong the strike was for sparks, 0 to 1.
signal sparked(point: Vector3, direction: Vector3, strength: float)

## The body's Striker, whose strikes spark.
@export var striker: Striker
## The struck materials that spark.
@export var materials: Array[StrikeMaterial] = []
## One burst of sparks (a SparkBurst scene). `bursts` of them take turns, so
## quick strikes do not cut each other short.
@export var burst_scene: PackedScene
@export_range(1, 8) var bursts := 3

@export_group("Strength")
## The speed the moving piece slid across the other at, below which a strike
## throws no sparks; at it, the fewest. At full_speed and above, the most.
@export_range(0.0, 10.0, 0.05, "suffix:m/s") var min_speed := 1.0
@export_range(0.1, 20.0, 0.05, "suffix:m/s") var full_speed := 6.0
## How many sparks a burst throws: at min_speed, and at full_speed (at most the
## burst's 32).
@export var counts := Vector2i(8, 28)
## The sparks' mean speed, as a share of the sliding speed, and the least and
## most it may be, in m/s.
@export_range(0.0, 2.0, 0.05) var speed_share := 0.9
@export var speed_limits := Vector2(1.5, 5.0)

@export_group("Spray")
## How far above the surface a skim's sparks leave.
@export_range(0.0, 90.0, 0.5, "suffix:°") var lift := 15.0
## How wide the cone is (half-angle), for a skim and for a blow straight in;
## between, by how glancing the blow was.
@export_range(0.0, 90.0, 0.5, "suffix:°") var skim_spread := 20.0
@export_range(0.0, 90.0, 0.5, "suffix:°") var head_on_spread := 70.0

var _bursts: Array[SparkBurst] = []
var _next := 0


func _ready() -> void:
	if striker == null or burst_scene == null:
		push_error("StrikeSparks: striker and burst_scene must both be assigned.")
		return
	for i in bursts:
		var burst := burst_scene.instantiate() as SparkBurst
		add_child(burst)
		_bursts.append(burst)
	striker.struck.connect(_on_struck)


func _on_struck(strike: Strike) -> void:
	if strike.material not in materials:
		return
	var slide := slide_of(strike)
	var slide_speed := slide.length()
	if slide_speed < min_speed:
		return
	var strength := clampf((slide_speed - min_speed) / (full_speed - min_speed), 0.0, 1.0) \
			if full_speed > min_speed else 1.0
	var direction := spray_direction(strike.normal, slide, deg_to_rad(lift))
	var spread := deg_to_rad(lerpf(head_on_spread, skim_spread, glance_of(strike.normal, slide)))
	var speed := clampf(slide_speed * speed_share, speed_limits.x, speed_limits.y)
	var count := roundi(lerpf(counts.x, counts.y, strength))
	_bursts[_next].fire(strike.point, direction, strike.normal, spread, speed, count)
	_next = (_next + 1) % _bursts.size()
	sparked.emit(strike.point, direction, strength)


## How the piece that moved slid across the other at a strike, in m/s: the
## striker's motion against the struck body, unless the struck body was moving
## faster (in the world), then its motion against the striker.
static func slide_of(strike: Strike) -> Vector3:
	var striker_motion := strike.velocity + strike.surface_velocity
	if strike.surface_velocity.length_squared() > striker_motion.length_squared():
		return -strike.velocity
	return strike.velocity


## How glancing a `slide` over a surface with `normal` (unit) is: 0 for straight
## in (or out), 1 for along the surface.
static func glance_of(normal: Vector3, slide: Vector3) -> float:
	var length := slide.length()
	return (slide - normal * slide.dot(normal)).length() / length if length > 0.0 else 0.0


## The way the sparks mainly go from a `slide` over a surface with `normal`
## (unit, out of the struck body): along the surface the way the slide goes,
## `lift_angle` (radians) above it for a pure skim, rising toward the normal the
## straighter in the blow came; the normal itself for a blow straight in.
static func spray_direction(normal: Vector3, slide: Vector3, lift_angle: float) -> Vector3:
	var across := slide - normal * slide.dot(normal)
	if across.length_squared() < 1e-8:
		return normal
	var elevation := lerpf(PI * 0.5, lift_angle, across.length() / slide.length())
	return across.normalized() * cos(elevation) + normal * sin(elevation)
