class_name LocomotionFrame
extends RefCounted

## One tick's movement plan: filled in by the locomotion modules in order,
## then applied by the body. The same instance is reused every tick.

## The stick's direction over the ground, with length 0 to 1.
var wish := Vector3.ZERO
## Speed at full stick, in m/s: a walk, or faster while running.
var top_speed := 0.0
## How much of a run the arms are asking for, 0 to 1.
var run_factor := 0.0
## Horizontal velocity that brings the body back under the head, in m/s.
var follow := Vector3.ZERO
## The capsule height wanted, in metres, or below zero to keep the current one.
var target_height := -1.0
## Upward speed wanted while lifting the body up a step, in m/s; zero otherwise.
var lift_speed := 0.0
## Upward take-off speed for a jump this tick, in m/s; zero otherwise.
var jump_speed := 0.0
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
	run_factor = 0.0
	follow = Vector3.ZERO
	target_height = -1.0
	lift_speed = 0.0
	jump_speed = 0.0
	hold = false
	blackout = 0.0
	exclusive = false


## The movement intent handed to the static skeleton, in m/s.
func commanded_travel() -> Vector3:
	return wish * top_speed


## The horizontal velocity the body should reach, in m/s.
func desired_velocity() -> Vector3:
	return Vector3.ZERO if hold else wish * top_speed + follow
