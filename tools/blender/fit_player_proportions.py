"""Copies the Body1 mannequin and fits the copy to the static skeleton's proportions.

Run inside Blender with craftables.blend open (Text Editor > Open > Run Script), or headless on a
copy for testing:
    blender -b --factory-startup <copy of craftables.blend> \
        --python tools/blender/fit_player_proportions.py

Body1_Rig and Body1 are left as they are. The copies, Body1_Fit_Rig and Body1_Fit, stand 0.8 m to
the side. Delete both copies to undo, or to run it again.

The physical player's body follows the static skeleton (scripts/static_skeleton/static_skeleton.gd
and the overrides in scenes/player/rig.tscn), so the character model is fitted to its standing
pose: legs straight, head level, eyes at 1.68 m. Each joint the static skeleton has is moved
there. Body1's A-pose directions, depths (front to back) and the shapes of its head, hands and
feet are kept; its hands keep their own proportions too, and the static skeleton's hand follows
them instead: the report ends with the hand constants for static_skeleton.gd, measured on the
copy (decided 2026-10-02). Body1 is weighted rigidly, one part per bone, so each part goes with its bone:
moved, turned, and stretched or shortened along the bone only, never made thicker or thinner.
At run time the model then stretches only by what the player's body does beyond this pose.

Body1's fingers are modelled curled, as a relaxed hand, so each rigid finger part is a little
banana; straightened at run time (the player's open hand), a finger's parts lined up into a
wave (the little finger, the most curled, looked crooked). The copy's fingers are first
straightened along their own smooth middle lines, cross-sections kept, the bones laid in one
straight line the way the first points (the thumb's metacarpal, which carries no part);
the bones then bend the fingers only as far as the player's do.

Body1's right side (arm, leg, hand, foot, fingers, toes, eye, ear, eyelids) is made of mirrored
copies whose faces point inward, unseen in Blender, which draws both sides, but inside out in
Godot, which draws only the front. The copy's parts are all turned to face outward, and its
custom normals, which only repeat the flat faces, are dropped so none point inward.
"""

import math

import bmesh
import bpy
from mathutils import Matrix, Vector

SOURCE_RIG = "Body1_Rig"
SOURCE_BODY = "Body1"
FIT_RIG = "Body1_Fit_Rig"
FIT_BODY = "Body1_Fit"
# Where the copy stands, beside the original, in metres along Blender's X.
SIDE_OFFSET = Vector((0.8, 0.0, 0.0))

# The static skeleton, in metres (rig.tscn overrides the four limb lengths).
HEAD_OFFSET = Vector((0.0, -0.02, 0.10))  # head centre from the eyes: down, back
NECK_LENGTH = 0.12
TORSO_LENGTH = 0.25
HIP_DISTANCE = 0.25
SHOULDER_OFFSET = Vector((0.18, 0.18, 0.0))  # from the chest centre: out, up
HIP_OFFSET = Vector((0.09, -0.10, 0.0))  # from the pelvis centre: out, up
UPPER_ARM_LENGTH = 0.30
FOREARM_LENGTH = 0.28
THIGH_LENGTH = 0.43
SHIN_LENGTH = 0.43
ANKLE_HEIGHT = 0.08
WRIST_OFFSET = 0.05  # the wrist sits this far behind the palm centre
FINGER_BONES = {
    "Thumb": ("ThumbMetacarpal", "ThumbProximal", "ThumbDistal"),
    "Index": ("IndexProximal", "IndexIntermediate", "IndexDistal"),
    "Middle": ("MiddleProximal", "MiddleIntermediate", "MiddleDistal"),
    "Ring": ("RingProximal", "RingIntermediate", "RingDistal"),
    "Little": ("LittleProximal", "LittleIntermediate", "LittleDistal"),
}

# Heights of the standing pose, legs straight and head level.
EYE_HEIGHT = (ANKLE_HEIGHT + SHIN_LENGTH + THIGH_LENGTH - HIP_OFFSET.y + HIP_DISTANCE
              + TORSO_LENGTH + NECK_LENGTH - HEAD_OFFSET.y)
NECK_BASE_HEIGHT = EYE_HEIGHT + HEAD_OFFSET.y - NECK_LENGTH
CHEST_HEIGHT = NECK_BASE_HEIGHT - TORSO_LENGTH
SHOULDER_HEIGHT = CHEST_HEIGHT + SHOULDER_OFFSET.y
HIP_SOCKET_HEIGHT = CHEST_HEIGHT - HIP_DISTANCE + HIP_OFFSET.y
TORSO_BONES = ("Hips", "Spine", "Chest")


class Fit:
    """Where one bone goes: its new head, its new direction and length."""

    def __init__(self, bone: bpy.types.Bone, head: Vector, tail: Vector) -> None:
        self.old_head = bone.head_local.copy()
        self.old_axis = (bone.tail_local - bone.head_local).normalized()
        self.old_length = bone.length
        self.head = head
        self.length = (tail - head).length
        self.turn = self.old_axis.rotation_difference((tail - head).normalized()).to_matrix()

    @property
    def stretch(self) -> float:
        return self.length / self.old_length

    def carry(self, point: Vector) -> Vector:
        """A point on this bone's part, moved, turned and stretched along the bone with it."""
        offset = point - self.old_head
        along = offset.dot(self.old_axis)
        offset += self.old_axis * along * (self.stretch - 1.0)
        return self.head + self.turn @ offset


def main() -> None:
    if FIT_RIG in bpy.data.objects or FIT_BODY in bpy.data.objects:
        raise SystemExit(f"{FIT_RIG} or {FIT_BODY} already exists; delete both to fit again.")
    rig = bpy.data.objects[SOURCE_RIG]
    body = bpy.data.objects[SOURCE_BODY]
    if bpy.context.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")

    fit_rig, fit_body = _copy(rig, body)
    _straighten_fingers(fit_rig, fit_body, body.matrix_world.inverted() @ rig.matrix_world)
    _resplit_thumbs(fit_rig, fit_body, body.matrix_world.inverted() @ rig.matrix_world)
    fits = _fits(fit_rig.data.bones)
    _move_bones(fit_rig, fits)
    _move_parts(fit_body, rig.matrix_world.inverted() @ body.matrix_world, fits)
    flipped = _face_outward(fit_body)
    _report(fits, fit_body)
    print(f"Turned {flipped} inside-out parts to face outward")
    _report_hand(fit_rig.data.bones)


def _fits(bones) -> dict:
    """Works out every bone's fit, parents before children."""
    fits = {}
    eyes = (bones["LeftEye"].head_local + bones["RightEye"].head_local) / 2.0
    head_lift = Vector((0.0, 0.0, EYE_HEIGHT - eyes.z))
    old_sockets = (bones["LeftUpperLeg"].head_local.z + bones["RightUpperLeg"].head_local.z) / 2.0
    old_neck = bones["Neck"].head_local.z
    torso_scale = (NECK_BASE_HEIGHT - HIP_SOCKET_HEIGHT) / (old_neck - old_sockets)

    def torso(point: Vector) -> Vector:
        # The torso chain keeps Body1's spacing between the hip sockets and the neck base.
        return Vector((point.x, point.y, HIP_SOCKET_HEIGHT + (point.z - old_sockets) * torso_scale))

    def along(bone, head: Vector, length: float) -> Vector:
        return head + (bone.tail_local - bone.head_local).normalized() * length

    def walk(bone) -> None:
        name = bone.name
        side = 1.0 if name.startswith("Left") else -1.0
        parent = fits.get(bone.parent.name) if bone.parent else None
        # A joint the static skeleton has no say over stays on its parent's part.
        head = parent.carry(bone.head_local) if parent else bone.head_local.copy()
        tail = head + (bone.tail_local - bone.head_local)
        part = name.removeprefix("Left").removeprefix("Right")
        if name in TORSO_BONES:
            head, tail = torso(bone.head_local), torso(bone.tail_local)
        elif name == "Neck":
            head = torso(bone.head_local)
            tail = bones["Head"].head_local + head_lift
        elif name == "Head":
            head, tail = bone.head_local + head_lift, bone.tail_local + head_lift
        elif part == "Shoulder":
            # The collarbone keeps its shape; its tail goes to the shoulder socket.
            socket = _socket(bones[name.replace("Shoulder", "UpperArm")], side)
            tail = socket
            head = socket - (bone.tail_local - bone.head_local)
        elif part == "UpperArm":
            tail = along(bone, head, UPPER_ARM_LENGTH)
        elif part == "LowerArm":
            tail = along(bone, head, FOREARM_LENGTH)
        elif part == "UpperLeg":
            head = Vector((side * HIP_OFFSET.x, bone.head_local.y, HIP_SOCKET_HEIGHT))
            tail = along(bone, head, THIGH_LENGTH)
        elif part == "LowerLeg":
            # The shin reaches down to where Body1's ankle is, so its feet stay on the floor.
            axis = (bone.tail_local - bone.head_local).normalized()
            tail = along(bone, head, (head.z - bone.tail_local.z) / -axis.z)
        fits[name] = Fit(bone, head, tail)
        for child in bone.children:
            walk(child)

    for root in (bone for bone in bones if bone.parent is None):
        walk(root)
    return fits


def _socket(upper_arm, side: float) -> Vector:
    """The static skeleton's shoulder socket, at Body1's depth."""
    return Vector((side * SHOULDER_OFFSET.x, upper_arm.head_local.y, SHOULDER_HEIGHT))


def _copy(rig, body):
    fit_rig = rig.copy()
    fit_rig.data = rig.data.copy()
    fit_rig.name = fit_rig.data.name = FIT_RIG
    fit_body = body.copy()
    fit_body.data = body.data.copy()
    fit_body.name = fit_body.data.name = FIT_BODY
    for collection in rig.users_collection:
        collection.objects.link(fit_rig)
    for collection in body.users_collection:
        collection.objects.link(fit_body)
    fit_body.parent = fit_rig
    for modifier in fit_body.modifiers:
        if modifier.type == "ARMATURE":
            modifier.object = fit_rig
    fit_rig.location = rig.location + SIDE_OFFSET
    return fit_rig, fit_body


def _move_bones(fit_rig, fits: dict) -> None:
    _edit_bones(fit_rig, {name: (fit.head, fit.head + fit.turn @ fit.old_axis * fit.length)
                          for name, fit in fits.items()})


def _move_parts(fit_body, to_rig: Matrix, fits: dict) -> None:
    """Carries every vertex with the bone (or, at finger splits, the bones) it is weighted to."""
    names = {group.index: group.name for group in fit_body.vertex_groups}
    from_rig = to_rig.inverted()
    for vertex in fit_body.data.vertices:
        point = to_rig @ vertex.co
        moved = Vector()
        total = 0.0
        for weight in vertex.groups:
            fit = fits.get(names[weight.group])
            if fit is not None and weight.weight > 0.0:
                moved += fit.carry(point) * weight.weight
                total += weight.weight
        if total > 0.0:
            vertex.co = from_rig @ (moved / total)
    fit_body.data.update()


def _straighten_fingers(fit_rig, fit_body, to_body: Matrix) -> None:
    """Straightens each finger's geometry and bones along the way its root bone points."""
    names = {group.index: group.name for group in fit_body.vertex_groups}
    owner = {}
    for vertex in fit_body.data.vertices:
        if vertex.groups:
            owner[vertex.index] = names[max(vertex.groups, key=lambda weight: weight.weight).group]
    carrying = set(owner.values())
    bones = fit_rig.data.bones
    straight = {}
    for side in ("Left", "Right"):
        for parts in FINGER_BONES.values():
            # The bones that carry the finger (the thumb's metacarpal carries none).
            chain = [side + part for part in parts if side + part in carrying]
            points = [vertex for vertex in fit_body.data.vertices if owner.get(vertex.index) in chain]
            # The finger's middle, root to tip. Its bones would not do: a sharp corner at a
            # knuckle creases the part there, and the little finger's bones cut across it.
            knuckles = [bones[name].head_local.copy() for name in chain] + [bones[chain[-1]].tail_local.copy()]
            line = _middle_line([to_body.inverted() @ vertex.co for vertex in points], knuckles)
            first = bones[side + parts[0]]
            axis = (first.tail_local - first.head_local).normalized()
            for vertex in points:
                vertex.co = to_body @ _unbend(line, axis, to_body.inverted() @ vertex.co)
            for i, name in enumerate(chain):
                straight[name] = (_unbend(line, axis, knuckles[i], on_line=True),
                                  _unbend(line, axis, knuckles[i + 1], on_line=True))
    fit_body.data.update()
    _edit_bones(fit_rig, straight)


def _resplit_thumbs(fit_rig, fit_body, to_body: Matrix) -> None:
    """Lays each thumb's three bones along the part of the thumb that can be seen.

    Body1's thumb metacarpal carries nothing: it ran 47 mm inside the palm from near the wrist,
    and the static skeleton's thumb with it (the player: the thumb should be where the model's
    is, 2026-10-02). Now the metacarpal starts where the visible thumb leaves the palm and takes
    the first half of its first part, the proximal the second half, and the distal its tip part,
    each vertex weighted to the bone it lies along.
    """
    bones = fit_rig.data.bones
    places = {}
    splits = {}
    for side in ("Left", "Right"):
        metacarpal, proximal, distal = (side + part for part in FINGER_BONES["Thumb"])
        base = bones[proximal].head_local.copy()
        crease = bones[distal].head_local.copy()
        tip = bones[distal].tail_local.copy()
        axis = (tip - base).normalized()
        middle = base + (crease - base) * 0.5
        places[metacarpal] = (base, middle)
        places[proximal] = (middle, crease)
        places[distal] = (crease, tip)
        splits[side] = (base, axis, (middle - base).length, (crease - base).length)
    names = {group.index: group.name for group in fit_body.vertex_groups}
    groups = {}
    for side, (base, axis, first, second) in splits.items():
        parts = [side + part for part in FINGER_BONES["Thumb"]]
        for name in parts:
            groups[name] = fit_body.vertex_groups.get(name) or fit_body.vertex_groups.new(name=name)
        for vertex in fit_body.data.vertices:
            if not vertex.groups:
                continue
            owner = names.get(max(vertex.groups, key=lambda weight: weight.weight).group)
            if owner not in parts[1:]:
                continue
            along = (to_body.inverted() @ vertex.co - base).dot(axis)
            bone = parts[0] if along < first else parts[1] if along < second else parts[2]
            for name in parts:
                groups[name].remove([vertex.index])
            groups[bone].add([vertex.index], 1.0, "REPLACE")
    _edit_bones(fit_rig, places)


def _middle_line(points: list, knuckles: list, rounds: int = 4) -> list:
    """The finger's middle line from root to tip: a smooth line through its knuckles, each point
    then moved, a few times over, to the middle of the finger where it is (the centre of the
    finger's points in a thin slice square to the line there), and smoothed."""
    line = _smooth(knuckles)
    for _ in range(rounds):
        moved = [line[0]]
        for k in range(1, len(line) - 1):
            tangent = _tangent(line, k)
            half = (line[k + 1] - line[k - 1]).length * 0.5
            near = [point for point in points
                    if abs((point - line[k]).dot(tangent)) < half and (point - line[k]).length < 0.025]
            if len(near) < 4:
                moved.append(line[k])
                continue
            shift = sum(near, Vector()) / len(near) - line[k]
            moved.append(line[k] + shift - tangent * shift.dot(tangent))
        moved.append(line[-1])
        line = [moved[0]] + [(moved[k - 1] + moved[k] * 2.0 + moved[k + 1]) * 0.25
                             for k in range(1, len(moved) - 1)] + [moved[-1]]
    return line


def _smooth(knuckles: list, steps: int = 8) -> list:
    """A Catmull-Rom curve through the knuckles, as `steps` points per bone."""
    ends = [knuckles[0] * 2.0 - knuckles[1]] + knuckles + [knuckles[-1] * 2.0 - knuckles[-2]]
    line = [knuckles[0].copy()]
    for i in range(1, len(ends) - 2):
        p0, p1, p2, p3 = ends[i - 1], ends[i], ends[i + 1], ends[i + 2]
        for step in range(1, steps + 1):
            t = step / steps
            line.append(0.5 * (2.0 * p1 + (p2 - p0) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t * t
                               + (3.0 * p1 - p0 - 3.0 * p2 + p3) * t * t * t))
    return line


def _unbend(line: list, axis: Vector, point: Vector, on_line: bool = False) -> Vector:
    """Where a point of a curled finger goes when its smooth middle line (`line`, root to tip,
    through the knuckles) is laid straight along `axis` from the root: as far along, turned as
    the finger turns there, so a part curled along its length comes out straight."""
    best = None
    travelled = 0.0
    for i in range(len(line) - 1):
        start, end = line[i], line[i + 1]
        span = end - start
        share = max(0.0, min(1.0, (point - start).dot(span) / max(span.length_squared, 1e-12)))
        nearest = start + span * share
        gap = (point - nearest).length
        if best is None or gap < best[0]:
            best = (gap, i, share, nearest, travelled + span.length * share)
        travelled += span.length
    _, i, share, nearest, along = best
    if on_line:
        return line[0] + axis * along
    turns = [_tangent(line, k).rotation_difference(axis) for k in (i, i + 1)]
    turn = turns[0].slerp(turns[1], share)
    return line[0] + axis * along + turn @ (point - nearest)


def _tangent(line: list, k: int) -> Vector:
    """The line's direction at its kth point, between the segments either side."""
    before = line[k] - line[k - 1] if k > 0 else line[1] - line[0]
    after = line[k + 1] - line[k] if k < len(line) - 1 else line[-1] - line[-2]
    return (before.normalized() + after.normalized()).normalized()


def _edit_bones(fit_rig, places: dict) -> None:
    """Moves the named bones of the copy to (head, tail), each turned the least to point there."""
    for other in bpy.context.view_layer.objects:
        other.select_set(False)
    fit_rig.hide_set(False)
    fit_rig.select_set(True)
    bpy.context.view_layer.objects.active = fit_rig
    bpy.ops.object.mode_set(mode="EDIT")
    edit_bones = fit_rig.data.edit_bones
    connected = {bone.name: bone.use_connect for bone in edit_bones}
    # Unconnected while moving, so setting one bone cannot drag its neighbour.
    for bone in edit_bones:
        bone.use_connect = False
    for name, (head, tail) in places.items():
        bone = edit_bones[name]
        rest = bone.matrix.copy()
        turn = rest.to_3x3().col[1].normalized().rotation_difference((tail - head).normalized())
        bone.matrix = Matrix.Translation(head) @ turn.to_matrix().to_4x4() @ rest.to_3x3().to_4x4()
        bone.length = (tail - head).length
    for bone in edit_bones:
        bone.use_connect = connected[bone.name]
    bpy.ops.object.mode_set(mode="OBJECT")


def _face_outward(fit_body) -> int:
    """Turns every closed part whose faces point inward to face outward; returns how many."""
    mesh = fit_body.data
    if "custom_normal" in mesh.attributes:
        # Every face is flat-shaded (sharp), so these only repeated the faces' own normals.
        mesh.attributes.remove(mesh.attributes["custom_normal"])
    mesh_data = bmesh.new()
    mesh_data.from_mesh(mesh)
    flipped = 0
    for part in _parts(mesh_data):
        centre = sum((face.calc_center_median() for face in part), Vector()) / len(part)
        # Positive for a closed surface whose faces point outward (three times its volume).
        volume = sum((face.calc_center_median() - centre).dot(face.normal) * face.calc_area() for face in part)
        if volume < 0.0:
            bmesh.ops.reverse_faces(mesh_data, faces=part)
            flipped += 1
    mesh_data.to_mesh(mesh)
    mesh_data.free()
    mesh.update()
    return flipped


def _parts(mesh_data) -> list:
    """The mesh's separate pieces, each a list of its faces."""
    seen = set()
    parts = []
    for first in mesh_data.faces:
        if first.index in seen:
            continue
        seen.add(first.index)
        part, stack = [], [first]
        while stack:
            face = stack.pop()
            part.append(face)
            for edge in face.edges:
                for neighbour in edge.link_faces:
                    if neighbour.index not in seen:
                        seen.add(neighbour.index)
                        stack.append(neighbour)
        parts.append(part)
    return parts


def _report(fits: dict, fit_body) -> None:
    print(f"Fitted {FIT_RIG} / {FIT_BODY}: eyes at {EYE_HEIGHT:.3f} m, neck base {NECK_BASE_HEIGHT:.3f}, "
          f"shoulder sockets {SHOULDER_HEIGHT:.3f}, hip sockets {HIP_SOCKET_HEIGHT:.3f}")
    print(f"{'bone':24} {'was':>7} {'now':>7} {'stretch':>8}")
    for name, fit in fits.items():
        if abs(fit.stretch - 1.0) > 0.001:
            print(f"{name:24} {fit.old_length:7.4f} {fit.length:7.4f} {fit.stretch:8.3f}")
    heights = [vertex.co.z for vertex in fit_body.data.vertices]
    print(f"Mesh (before subdivision) from {min(heights):.4f} to {max(heights):.4f} m high")


def _report_hand(bones) -> None:
    """Prints the static skeleton's hand constants for the copy's hand, in its hand space.

    The frame is the one the skeletal layer lays the model's hand on the static hand by
    (PoseMapper._rest_hand_basis): -Z from the wrist toward the middle finger's root, +Y
    toward the thumb's side, and the palm centre WRIST_OFFSET ahead of the wrist. A root is
    (forward, toward the thumb, toward the palm) from the palm centre; a finger's spread is how
    far it points toward the thumb side, its tilt how far toward the palm. Both hands are
    measured, mirrored and averaged.
    """
    roots, lengths, spreads, pitches = {}, {}, {}, {}
    for side in ("Left", "Right"):
        wrist = bones[side + "Hand"].head_local
        forward = (bones[side + "MiddleProximal"].head_local - wrist).normalized()
        across = bones[side + "IndexProximal"].head_local - bones[side + "LittleProximal"].head_local
        thumb = (across - forward * across.dot(forward)).normalized()
        # The palm faces -X in a right hand's space and +X in a left's: thumb x forward,
        # or its opposite.
        palm = thumb.cross(forward) if side == "Right" else forward.cross(thumb)
        centre = wrist + forward * WRIST_OFFSET
        for finger, parts in FINGER_BONES.items():
            first = bones[side + parts[0]]
            offset = first.head_local - centre
            point = (first.tail_local - first.head_local).normalized()
            for table, value in ((roots, Vector((offset.dot(forward), offset.dot(thumb), offset.dot(palm)))),
                                 (lengths, Vector([bones[side + part].length for part in parts])),
                                 (spreads, math.degrees(math.atan2(point.dot(thumb), point.dot(forward)))),
                                 (pitches, math.degrees(math.atan2(point.dot(palm), point.dot(forward))))):
                table.setdefault(finger, []).append(value)
    mean = lambda values: sum(values[1:], values[0]) / len(values)
    fingers = list(FINGER_BONES)
    print("Static skeleton hand constants for this model (scripts/static_skeleton/static_skeleton.gd):")
    print("const FINGER_ROOTS: Array[Vector3] = [")
    for finger in fingers:
        root = mean(roots[finger])
        print(f"\tVector3({root.x:.4f}, {root.y:.4f}, {root.z:.4f}),")
    print("]\nconst FINGER_LENGTHS: Array[Vector3] = [")
    for finger in fingers:
        length = mean(lengths[finger])
        print(f"\tVector3({length.x:.4f}, {length.y:.4f}, {length.z:.4f}),")
    print("]")
    print("const FINGER_SPREADS: Array[float] = [0.0, "
          + ", ".join(f"{mean(spreads[finger]):.1f}" for finger in fingers[1:]) + "]")
    print("const FINGER_PITCHES: Array[float] = [0.0, "
          + ", ".join(f"{mean(pitches[finger]):.1f}" for finger in fingers[1:]) + "]")
    print(f"@export var thumb_spread_degrees := {mean(spreads['Thumb']):.1f}")
    print(f"@export var thumb_pitch_degrees := {mean(pitches['Thumb']):.1f}")


main()
