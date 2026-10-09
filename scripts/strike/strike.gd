class_name Strike
extends RefCounted

## One strike: a physical object meeting a struck body hard enough to count
## (the strike model, documents/strike_model.md). The object's Striker measures
## it and the struck body's Strikeable judges it. Made only when a strike
## happens.

## The damage types: two, decided with the player 2026-10-02 (damage only; no
## type changes how anything moves). A strike is a slash if a Sharp part of the
## striker (an edge or a point) dealt it, and blunt otherwise.
enum Kind { BLUNT, SLASH }

## The damage a strike does (2026-10-02), a whole number: the least for a
## strike at its material's threshold energy, the most for a full-strength one.
## A strike below the threshold does none.
const MIN_DAMAGE := 1
const MAX_DAMAGE := 10

## The body that struck, and the object struck: a struck body, or a model whose
## bodies take strikes as one (its Strikeable's parent).
var striker: RigidBody3D
var target: Node3D
## What the struck body is made of (filled in by its Strikeable).
var material: StrikeMaterial
## The damage type, and the Sharp feature that dealt it (null for a blunt part).
## The Strikeable turns a type its material does not take into blunt.
var kind := Kind.BLUNT
var feature: Sharp
## Where it landed on the struck body's surface, and that surface's normal (out
## of the struck body), in world space.
var point := Vector3.ZERO
var normal := Vector3.ZERO
## How fast the striker closed on the struck body along the normal before the
## impact, in m/s.
var speed := 0.0
## How the striker moved against the struck body where it landed, before the
## impact (world space, m/s): along the normal it closes (-speed), across it it
## slides. And how the struck surface itself moved there; the striker's own
## motion is the sum of the two. Kept for effects (StrikeSparks), 2026-10-05.
var velocity := Vector3.ZERO
var surface_velocity := Vector3.ZERO
## The mass the strike met there along the normal (the striker and the hands
## holding it), in kg.
var effective_mass := 0.0
## ½ · effective_mass · speed², in joules.
var energy := 0.0
## The damage it did: 0 below its material's threshold, else MIN_DAMAGE to
## MAX_DAMAGE (filled in by the Strikeable).
var damage := 0
## The hands holding the striker during the step: 1 the left, 2 the right.
var held_by := 0
## How far apart the surfaces were at the start of that step, in metres
## (negative when already overlapping). Kept for measurement.
var gap := 0.0
## What the struck object made of it, for measurement, filled in by whatever
## judges it there (empty if nothing does): a tree's TreeChop gives its
## "outcome" (TreeChop.Outcome), the branch's "depth", the "line" it counted on
## or the nearest, its "offset" from that line along the branch (m) and the
## "side" it opened (2026-10-02).
var judged := {}
