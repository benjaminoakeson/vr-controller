class_name Health
extends Node

## How much damage an object takes before it is gone (2026-10-02). A strike does
## Strike.MIN_DAMAGE to Strike.MAX_DAMAGE (1 to 10, the strike model,
## documents/strike_model.md), so an object's health counts blows: 30 takes
## three full-strength blows, or up to thirty of the lightest.
##
## It takes the damage of its Strikeable's strikes, of the kinds it takes. When
## its health reaches 0 the object is dead: it emits depleted, once, and what
## that does is the object's to decide. An ore vein frees itself, and its
## LootDrop drops its ore; so does a tree's lone segment (TreeChop), which takes
## slashes only.

## Emitted when the health changes, with what is left; and once when ready.
signal changed(current: int)
## Emitted once, when the health reaches 0.
signal depleted

## The health it starts with, in damage points.
@export_range(1, 1000, 1) var maximum := 30
## The struck object whose strikes damage it.
@export var strikeable: Strikeable
## The kinds of strike that damage it (Strike.Kind, a bit each): all of them by
## default.
@export_flags("Blunt", "Slash") var kinds := 3

## What is left, from maximum down to 0.
var current := 0


func _ready() -> void:
	current = maximum
	if strikeable == null:
		push_error("Health: no strikeable is assigned.")
	else:
		strikeable.struck.connect(_on_struck)
	changed.emit(current)


## Takes `amount` damage, down to 0. Once at 0 it takes no more.
func take_damage(amount: int) -> void:
	if amount <= 0 or current == 0:
		return
	current = maxi(current - amount, 0)
	changed.emit(current)
	if current == 0:
		depleted.emit()


func _on_struck(strike: Strike) -> void:
	if kinds & (1 << strike.kind):
		take_damage(strike.damage)
