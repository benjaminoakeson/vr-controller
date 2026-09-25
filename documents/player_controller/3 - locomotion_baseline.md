# Locomotion baseline capture

## Purpose

Step 1 of the [handoff sequence](2%20-%20prototype_handoff.md#recommended-implementation-sequence):
record how the current `CharacterBody3D` controller behaves on the existing level,
so the dynamic-body prototype can be run through the same tests and compared with
numbers rather than memory. Nothing here changes locomotion.

## Recorder

`LocomotionRecorder` (`scripts/debug/locomotion_recorder.gd`) sits in
`scenes/player/vr_controller.tscn`. It reads the body, rig and static skeleton after
each physics tick and writes nothing back.

- **Start/stop a run:** press **Y** (left `by_button`). A short haptic pulse confirms
  each toggle.
- **Readout:** the label above the left controller shows the run state, measured
  / commanded speed (m/s, averaged over 0.25 s), ground or air with the ground slope,
  and the current physics rate.
- **Output:** one CSV per run under `user://baselines/`, plus a one-line summary in
  the log. The log line at the start of a run prints the full file path. On desktop
  it is `~/.local/share/godot/app_userdata/VRController/baselines/`. On Quest it is
  the app's user data folder, which can be retrieved with `adb pull`.

CSV columns: time, physics rate, delta, body position, speed (3D, horizontal,
vertical), commanded speed, grounded, slope, run factor, rig pull-back this tick,
head height, reference foot heights above the body, and the previous frame's
physics-process time.

Speeds come from how far the body actually moved, including the body following the
headset. **Stand still in the room during stick-locomotion runs.** The recorder and
readout are debug overhead. Remove or disable them before performance profiling.

## Conditions to note per session

Device, build/commit, renderer, reported display rate and physics rate (readout),
whether the mirror is in view, and the scene's `max_walk_speed` (1.5 m/s) and
`walk_acceleration` (15) overrides.

## Runs

Fixture locations are in world coordinates; the player starts at the origin, with the
mirror 2 m ahead at −Z.

| # | Fixture | Action | Look for |
| --- | --- | --- | --- |
| 1 | Main floor | Full stick forward ~5 s, release | Walking vs commanded speed, stopping distance/time |
| 2 | Main floor | Half stick forward ~5 s | Analog scaling |
| 3 | Steps, X 3–5 m at Z 2 m (0.25 m rises) | Walk up all three, then back down | Largest grounded rise, foot heights on treads, any snags |
| 4 | 15° ramps leading up from the lower level (`CSGBox3D6`, `CSGBox3D9`) | Walk up and down at full stick | Speed held along the slope, slope readout |
| 5 | Floor hole at (−4, 2.75) | Walk in and drop to the lower floor | Airborne time, top speed, landing, feet on landing |
| 6 | Wall at Z 4 m | Physically lean/step your head into the wall | Rig pull-back total, comfort of the correction |
| 7 | Anywhere open | Crouch fully, hold, stand | Lowest head, foot placement, capsule behaviour |
| 8 | Main floor | Both grips + stick + arm pumping | Run factor, top speed vs 1.5 m/s walk |

## Results

Record one row per run, with the CSV file name. Add subjective notes on feel.

| # | CSV | Walking / commanded (m/s) | Top (m/s) | Airborne (s) | Largest rise (m) | Pull-back (m) | Lowest head (m) | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | | |

## Verified so far

A headless run (no headset; HMD placed at 1.7 m) dropped the body through the floor
hole: 0.85 s airborne, top speed 8.71 m/s, landing at y = −4.0 m. That is consistent
with a 4 m fall, and it confirms CSV output and the summary line. No headset run has
been recorded yet.
