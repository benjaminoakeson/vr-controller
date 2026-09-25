# Locomotion baseline

## Purpose

Step 1 of the [handoff sequence](2%20-%20prototype_handoff.md#recommended-implementation-sequence):
record how the current `CharacterBody3D` controller behaves on the existing level,
so the dynamic-body prototype can be run through the same scenarios and compared
by numbers. Nothing here changes locomotion.

Results come from two sources and are kept apart:

- **Simulated (headless):** scripted headset, controller and stick input on the desktop,
  with no XR runtime. It is deterministic and repeatable, so it is the regression
  baseline. It says nothing about comfort, real tracking noise or Quest 3S performance.
- **Headset:** a guided session through WiVRn on this PC. Nothing from a headset
  session has been recorded yet. The Quest renders the stream, but the game runs on
  the desktop GPU/CPU, so these are not standalone Quest 3S performance results
  either.

## How it is measured

- `LocomotionRecorder` (`scripts/debug/locomotion_recorder.gd`, in the player scene)
  reads the body, rig and static skeleton after each physics tick and writes a CSV.
  It never writes to them. In normal play it records nothing.
- `tests/baseline/simulated_rig.gd` registers stand-in `head`, `left_hand` and
  `right_hand` trackers with the `XRServer`. The scene's unchanged `XRCamera3D` and
  `XRController3D` nodes follow them, so gameplay code runs as it would with a
  runtime. Only its inputs are simulated.
- `tests/baseline/run_baseline.gd` runs the scenarios below on fresh copies of
  `scenes/level.tscn`. `tests/baseline/recording_analysis.gd` measures every
  recording, simulated or headset, the same way.
- Guided headset mode (`-- --record-baseline`) shows one plain instruction at a
  time above the left hand. `BaselineChecklist` ticks each off by recognising it in
  the recording, with a short buzz each time. The game closes itself when the list
  is finished. `tests/baseline/analyze_session.gd` then measures the session item by
  item.

Commands (run from the project root; `--xr-mode off` keeps headless runs from ever
starting a headset session):

```sh
# Simulated baseline: CSVs + results.json under user://baselines/simulated/<time>/
godot --headless --xr-mode off --fixed-fps 72 --path . -s tests/baseline/run_baseline.gd
# Checklist detection against those recordings (exit code 0 = every item detected)
godot --headless --xr-mode off --path . -s tests/baseline/check_checklist.gd -- <run directory>
# Guided mode smoke test without a headset
godot --headless --xr-mode off --fixed-fps 72 --path . -s tests/baseline/run_guided_smoke.gd -- --record-baseline
# Headset session (WiVRn connected), then its analysis
godot --path . -- --record-baseline
godot --headless --xr-mode off --path . -s tests/baseline/analyze_session.gd
```

`user://` is `~/.local/share/godot/app_userdata/VRController/` on this machine.

## Simulated results

Conditions: Godot 4.7.2 headless on the desktop, Jolt, 72 physics ticks, fixed
72 fps, simulated head at 1.7 m. Scene tuning as committed: `max_walk_speed` 1.5 m/s,
`walk_acceleration` 15, script defaults otherwise. Recorded 2026-09-25, run
`2026-09-25T13-04-59`. Two consecutive runs produced identical results.

| Scenario | What was driven | Result |
| --- | --- | --- |
| Stand | Standing still, 3 s | No drift; body 0.6 mm above the floor; reference feet steady at −3 mm |
| Flat, full stick | 5 s at full stick, release | 1.50 m/s against 1.50 commanded; 90 % of speed in 0.083 s; stops in 0.069 s over 0.035 m |
| Flat, half stick | 6 s at 0.5 stick, release | 0.62 m/s against 0.62 commanded (the deadzone remap turns 0.5 into 41 %); stops in 0.028 s |
| Steps up (3 × 0.25 m) | Full stick up all three | Reaches the 0.755 m top in 2.1 s, no stalls. Each step: a single-tick lift of 0.125–0.136 m (a 9–10 m/s spike), then 3 ticks (0.042 s) flagged airborne |
| Steps down | Turn round over 1 s, full stick down | Each step is a 0.19 m drop, 0.111 s airborne, landing at 2.05 m/s. Reference feet reach −0.256 m (one foot on the lower tread) |
| Long 15° ramp | Down to the platform, turn, back up | 1.50 m/s along the slope both ways (ratio 1.00); slope read 14.9° down, 14.4° up; never airborne |
| Lower 15° ramp | From the lower floor up to the platform | 1.50 m/s, climbs 1.74 m, reaches the platform |
| Floor hole drop | Walk in at full stick | Falls 3.93 m in 0.79 s; lands at 8.05 m/s with no bounce; reference feet on the floor 0.5 s later |
| Head into wall | Real head walks 1 m toward the wall at 0.5 m/s | The rig is pulled back 0.199 m for the 0.2 m the head moved past the stop, at most 7 mm per tick. The head is held 0.20 m (the body radius) from the wall face and never enters it |
| Crouch | Head 1.70 → 0.80 m over 1 s, hold, stand | Body height unchanged, never airborne, reference feet unchanged |
| Run, moderate pumping | Grips, hands ±0.15 m at 1.5 Hz, full stick | Run factor 0.22 → 2.21 m/s |
| Run, hard pumping | Grips, hands ±0.25 m at 2.5 Hz, full stick | Run factor 1.00 → 5.83–6.00 m/s; 90 % of speed in 0.32 s; stops in 0.25 s over 0.68 m |

Physics-time readings from headless runs are not meaningful and are not reported.

### Characteristics to carry into the proposal

1. **Speed changes are nearly instant.** Full walking speed arrives in about 0.08 s
   and the body stops within 4 cm. There is no perceptible momentum. The force-limited
   body will feel heavier by design; responsiveness targets need choosing, not copying.
2. **Step-up is a teleport.** Each 0.25 m step lifts the body, and the camera,
   12–14 cm in one tick, and the grounded flag flickers off for 3 ticks. Stepping down
   is a real 0.11 s fall. Both need an explicit comfort decision in the new body.
3. **The body is always directly under the head.** Leaning the head forward moves
   the whole body. The head cannot get closer than 0.2 m to a wall, and cannot lean
   over a counter or ledge.
4. **Walls push the view back 1:1.** Head motion past an obstacle is removed by
   moving the rig. There is no fade or other feedback.
5. **Speed is held along slopes.** 15° ramps give exactly the walking speed along
   the surface in both directions. That is the behaviour the new motor's slope
   compensation is meant to preserve.
6. **Leaving the level is unrecoverable.** Walking off the platform's far edge falls
   forever; there is no out-of-bounds recovery.
7. **The level loops.** Main floor → long ramp down → platform → lower ramp down →
   lower floor, and back up the same way. The floor hole is a shortcut down, not a
   dead end.

### Static solver note (not changed)

The simulated harness found one edge case in `StaticSkeleton._solve_torso`
(`static_skeleton.gd` line 737 area). When the chest direction and its target are
almost exactly opposite, `Vector3.slerp` builds an axis whose length rounds to about
1.0007, and Godot rejects it with "axis must be normalized". It fired only on an
instant 180° head turn in one tick. With a realistic 1 s turn it did not occur. Arms
crossed so the hand direction exactly opposes the chest might trigger it in headset.
A guard that skips the slerp when its weight is zero or the vectors are antiparallel
would fix it. It is left for a separate agreed change.

## Headset session

### What to do

1. Put the headset on and connect WiVRn as usual, with space to take a step forward.
2. Tell Claude you are ready. Claude starts the test.
3. Read the words above your left hand and do what they say. You will feel a buzz
   each time one is done, and the next one appears. There are 10, and it takes a few
   minutes.
4. The last one, a 4 m drop through the hole in the floor, is optional. When the
   words say **All done**, the game closes by itself. Take the headset off and tell
   Claude. If you want to stop early, or you fall off the edge of the level, just say
   so and Claude will stop it.

Keep your feet still during the stick tests. Everything else, including finding and
analysing the recording, is automatic.

### Results

Awaiting the first session. It will be recorded here with the recording name, the
refresh and physics rates reported during it, the same measurements as the simulated
table, and subjective notes. Headset-only questions are: comfort of step-up snaps and
wall pull-back, real tracking noise while standing and crouching, arm-pump
detection with real arms, and behaviour when the refresh rate changes mid-session
(earlier logs show WiVRn moving between 72, 90 and 120 Hz).
