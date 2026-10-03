class_name LocomotionFrame
extends RefCounted

## One tick's movement plan: filled in by the locomotion modules in order,
## then applied by the body. The same instance is reused every tick.

## The stick's direction over the ground, with length 0 to 1.
var wish := Vector3.ZERO
## Speed at full stick, in m/s: a walk, or faster while running.
var top_speed := 0.0
## The share of the legs' strength left once they carry what the hands hold,
## 0 to 1 (CapsuleBody.strength_share()): the stick's speed is that share of
## top_speed. Following the head is not slowed: the room is walked for real.
var strength := 1.0
## How much of a run the arms are asking for, 0 to 1.
var run_factor := 0.0
## Horizontal velocity that brings the body back under the head, in m/s.
var follow := Vector3.ZERO
## The capsule height wanted, in metres, or below zero to keep the current one.
var target_height := -1.0
## How far the legs should be drawn up (the capsule's bottom above the feet),
## in metres, or below zero to keep them as they are.
var target_tuck := -1.0
## Upward speed wanted while lifting the body up a step, in m/s; zero otherwise.
var lift_speed := 0.0
## Set while that lift is the legs standing up out of a tuck (LegTuck), not
## a step.
var standing_up := false
## Upward take-off speed for a jump this tick, in m/s; zero otherwise.
var jump_speed := 0.0
## A snap turn this tick, in radians about the vertical (positive turns the
## view left); zero otherwise.
var turn := 0.0
## Set while the body must hold still: the head is not tracked, or a
## relocation is under way.
var hold := false
## 0 to 1: how far the view should be blacked out.
var blackout := 0.0
## Set by a module that takes over the tick, which ends the chain.
var exclusive := false


func reset() -> void:
	wish = Vector3.ZERO
	top_speed = 0.0
	strength = 1.0
	run_factor = 0.0
	follow = Vector3.ZERO
	target_height = -1.0
	target_tuck = -1.0
	lift_speed = 0.0
	standing_up = false
	jump_speed = 0.0
	turn = 0.0
	hold = false
	blackout = 0.0
	exclusive = false


## The movement intent handed to the static skeleton, in m/s.
func commanded_travel() -> Vector3:
	return wish * top_speed * strength


## The horizontal velocity the body should reach, in m/s.
func desired_velocity() -> Vector3:
	return Vector3.ZERO if hold else wish * top_speed * strength + follow
