# Inventory

## Decisions (2026-10-06)

The player asked for an inventory slot system:

- **Storable items.** "For now I would like the wood log, stick, leaf litter, stone, and flint
  all storable objects. Each object should be stackable up to 999."
- **The slot's look.** "A floating square (with rounded corners) floating in space, always
  facing the player so he can see the contents of the slot. The slot if empty should show
  nothing and if occupied show the model of the object in the slot with the quantity in the
  top right corner of the slot. The slot should look like a super clear glass. Should be see
  through with a dicernable edge."
- **Selecting.** "A zone within 3d space (potentially a sphere collider) should detect hand
  presence and if the hand is present in the slot, then it should expand by 25% to show its
  been selected (This is without the player pressing any buttons...)"
- **Taking.** "If the player grabs, then the object in the slot should appear in the players
  hand (If multiple objects present in the slot, then the player grabs 1 object out of the
  slot subtracting the quantity -1)."
- **Sources.** "These inventory slots will stem from different objects and will need to be
  placed in paticular places." A faint debug line runs from a slot to its source.
- **The first slot.** Above the mouth of the furnace, attached to it: "if the furnace moves,
  the slot moves. If the furnace is destroyed, the slot is destroyed and when a slot is
  destroyed then the contents within that slot should be ejected at the slots location."

Chosen with the player at plan review:

- **Storing.** Let go of a held storable item with the hand in the zone. It is refused, and
  falls as usual, for another item, a full stack, or something burning.
- **Ejecting.** Every item comes out as its prop, laid round the slot's place. That is fine
  for tens; a full 999 stack would be 999 bodies at once and is a later design (a dropped
  bundle, say).
- **Destruction.** "Lets not test it for the furnace, but for future objects this will be
  possible." The furnace cannot be destroyed; the slot ejects when any source is destroyed,
  checked in the focused test.
- **An empty slot still shows its glass**, with nothing in it.

Revised with the player after the headset (2026-10-07, "It actually looks and feels really
good"):

- **A flat bubble.** "I would like the slot to look more 3D. It should look more like a flat
  bubble. It should have length extended backwards to give the slot depth but not a lot so
  the slot still looks somewhat flat." The pane became a shallow superellipsoid 3.5 cm deep
  (a quarter of its side), reaching back from where the pane was, the item in its middle.
  Its glass is lit: a Fresnel rim gives the edge (picked from three renders: the first rim
  was lost against the sky, and 5 cm deep read as a glass block).
- **Adjustable corners.** "Can you also add the ability to adjust the rounding of the slots
  corners?" `corner_radius` (m) on the slot: 0 square, half its side round, 2.5 cm the
  first look. The count moves in along the diagonal to stay on the glass.

My calls, to revisit in the headset:

- **The palm selects.** The palm's grab point inside the zone, a 0.10 m ball, selects a slot;
  a selected slot stays selected 1 cm past its zone, so it does not flicker at the edge.
- **A slot comes before a prop.** Gripping in a slot that holds something takes from it ahead
  of anything else in reach; an empty slot leaves the grip to an ordinary grab.
- **Only one hand stores.** Only the last hand holding an item stores it, and only by opening
  the grip: slipping or losing tracking drops it as before.
- **Stored items come back fresh**, so lit tinder (embers too) and fuel a fire has burnt any
  of are refused.
- **A taken item lies across the palm**, its longest side along the fist and its thinnest on
  the palm, its surface on the grab point. A stick is then held by its handle, as from the
  floor. (First built turned as the slot showed it: a log met the palm by a corner 7 cm from
  the grab point.)
- **The count shows from 1.** The litter shows as a pile; it comes into the hand as a ball, as
  any litter does.
- **The source line is always drawn** (`show_source_line`), through other geometry as the
  debug drawings are, not on the B toggle.

## The model

| Piece | File | Role |
| --- | --- | --- |
| InventoryItem | `scripts/inventory/inventory_item.gd`, `assets/items/*.tres` | Shared configuration for a kind of item: its prop scene (a path, since the prop's Storable refers back to the item), its display model and turn, whether it ejects lying down, 999 to a stack. |
| Storable | `scripts/inventory/storable.gd` | On a prop's body: which item it is, and whether it may be stored now. On the log, stick, leaf litter, stone and flint scenes (so chopped logs and sticks too). |
| InventorySlot | `scripts/inventory/inventory_slot.gd`, `scenes/inventory/inventory_slot.tscn` | An Area3D: its Zone (a ball) on the Interface layer (7), which nothing meets. The glass pane, model and count on a Face turned to the camera each frame, grown by `hover_scale` while touched; the line to its source; `accepts`, `store`, `take`; ejects in `_exit_tree` when it or its source is being destroyed. |
| InventoryEject | `scripts/inventory/inventory_eject.gd` | Lays a destroyed slot's items in rings round its place, 16 a tick, each clear (LootDrop's checks), long items on their side, litter as a ball. |
| SlotBubbleMesh | `scripts/inventory/slot_bubble_mesh.gd` | The glass's shape (2026-10-07): a superellipsoid one unit across (outline exponent 0.3, a rounded square face on; profile 0.5, nearly flat faces and a rounded rim), 48 points round, 24 rings, about 2,300 triangles; drawn back to front, double-sided, in one draw call. A `@tool` primitive mesh, so it shows in the editor; the slot scales it to `size` by `depth`. `outline_exponent_for` turns a corner radius into its outline exponent, matched where the corner crosses the diagonal; a slot whose corners differ from the scene's mesh gets its own copy. |
| Slot glass | `assets/materials/inventory/slot_glass.gdshader` | Lit, smooth (roughness 0.06), premultiplied so reflections and highlights stay whole: 3 % opaque face on, up to 88 % toward the rim (Fresnel, power 1.6), the rim glowing a little of itself. No refraction. (A flat pane's distance-field rim at first.) |
| HandGrab | `scripts/physical/hand_grab.gd` | Each tick finds the slot round the palm's grab point (a point query on the Interface layer) and touches it; takes on the grip closing there; stores on the grip opening there. |

- **Where items go.** Taken and ejected items go into the source's parent, as LootDrop's loot
  goes into the object's parent, so they stay when the source goes.
- **Destroyed means freed with `queue_free`**, the slot, its source or a node between.
  Anything above the source (the level unloading) ejects nothing.
- **Taking places the prop before it enters the tree**, so the physics server has it there
  in the same tick, and the grab starts from where the slot put it, with no query: the
  normal seat (0.08 s) and weld follow.
- **Storing lets go first, then frees the body.** It clears the throw history first, so a
  store is no throw. HandGrab's let-go list now checks a body is still there before casting
  it: a stored body is freed while listed.

| Tunable | Where | Value |
| --- | --- | --- |
| Zone radius | slot's Zone shape | 0.10 m |
| Glass side | `InventorySlot.size` | 0.15 m |
| Glass depth | `InventorySlot.depth` | 0.035 m, reaching back |
| Corner radius | `InventorySlot.corner_radius` | 0.025 m (0 square, `size` / 2 round) |
| Hover growth | `hover_scale` / `grow_time` | 1.25 / 0.05 s |
| Model fill | `model_fill` | 0.7 of the glass's face |
| Selection margin | `HandGrab.slot_margin` | 0.01 m |
| Stack | `InventoryItem.max_stack` | 999 |
| Eject rate | `InventoryEject.per_tick` | 16 a tick |
| Furnace slot | `scenes/props/furnace.tscn` | (0, 0.9, 0.9) in the furnace's space: 27 cm above the mouth's top, 10 cm out from its face |

## Ladder

1. **One slot above the furnace's mouth** (this rung): show, select, take, store, eject.

Later, not built:

- Slots on the player (belt, back) and several on one source.
- Big stacks dropped as one thing.
- Sources that can be destroyed (the furnace).
- Item state kept in storage (partly burnt fuel).
- A haptic tick on selecting; the source lines on the B toggle.

## Checks

```
godot --headless --xr-mode off --path . -s tests/inventory/test_inventory_slot.gd
godot --headless --xr-mode off --fixed-fps 72 --path . -s tests/harness/run_scenarios.gd -- slot_take slot_take_stick slot_store slot_refuse
```

### Rung 1 (2026-10-07, simulated, desktop)

- **Focused test (29 checks then; 31 now), all pass.** It covers:
  - the five props' items;
  - Jolt's point query finding the zone (with monitoring off) inside it and not 13 cm off;
  - storing and refusing (another item, 999, burning litter, a burnt stick, a bare body);
  - the display (empty: glass only; one: model and "1");
  - a taken log lying across the palm, its surface 7 mm from the grab point (the outline's
    point spacing), nothing past the palm;
  - growing to 1.25 and back;
  - facing the camera, level;
  - moving with its source, the line following;
  - ejecting five sticks within 0.49 m, 0.49 m apart, lying down, and three litter balls,
    loose; and nothing when the level unloads.
- **Harness.** The slot is taken out of every other scenario, as the weapons are, so their
  solve order is unchanged.

  | Scenario | Result |
  | --- | --- |
  | `slot_take` | Grown to 1.25 before the grip; a stone held to the end at 0.1 mm from its grab point, at most 0.90 m/s; 3 → 2; drawn out, back to 1.0. |
  | `slot_take_stick` | The stick held by its handle 0.0° off the fist's line, 2.8 mm gap; 2 → 1. |
  | `slot_store` | The stone let go in the empty slot: gone, the slot holds 1 stone, no throw, the hand idle. |
  | `slot_refuse` | A stick let go in a slot holding a stone: still 1 stone, the stick fell from 0.89 m to the floor. |

- **Full harness** (196 scenarios): the 192 others are identical, value by value (results.json), to an
  untouched copy's run; 57 criteria fail in both, all of them before this rung, in this environment.
- **Look** (a windowed render on the desktop, not the headset): the pane reads as clear glass
  with a crisp rim against the sky and the furnace; counts 1 to 999 legible at about 0.5 m;
  every item's model recognisable; the hovered slot visibly larger; the source line faint.

### Flat bubble (2026-10-07, simulated, desktop)

- The focused test (29) and the four slot scenarios pass unchanged. The glass is drawing
  only, and the harness takes the slot out of every other scenario.
- **Look** (windowed renders on the desktop): the glass reads as a shallow bubble, with a
  bright rounded rim against the sky and the furnace. Turned 40° to the camera, its rounded
  depth shows. The count stays crisp in front.
- Not measured: the cost of about 2,300 triangles and per-pixel lighting a slot on the
  Quest 3S (it was 2 triangles, unshaded).

### Adjustable corners (2026-10-07, simulated, desktop)

- The focused test (31: two new) and the four slot scenarios pass. The new checks: radius
  0 is square, half the side is round, 2.5 cm is the first look; a round slot gets its own
  glass with its count inside the circle, while a usual one keeps the shared mesh.
- **Look** (a windowed render): radii 0, 1.25, 2.5, 5 and 7.5 cm run from a sharp square to
  a disc, with the count inside each.

### Headset (pending)

Walk to the furnace: the slot floats above its mouth, facing you.

1. Put a hand in: it grows. Take the hand out: it shrinks back.
2. Store a stick, a stone, the flint, a leaf ball and a chopped log, each in turn: one kind
   at a time. Another kind, or a burning ball, falls instead.
3. Grip in it: one comes out into the hand, across the palm.

Judge:

- whether the zone is easy to find without looking, and whether it ever selects by
  accident (reaching past to the furnace);
- the count's legibility at arm's length;
- the glass edge against the sky and the furnace.

Not checked: Quest 3S cost (about four draw calls a slot, one transparent pane), and the
eject, which nothing in the level triggers yet.
