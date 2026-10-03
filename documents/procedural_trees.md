# Procedural trees

## Decisions (2026-09-26)

- **Scope:** generation only. Chopping and harvesting come later, as a separate design.
  This work adds no cutting code, only the constraints listed below. (2026-10-02:
  chopping has begun; see Chopping.)
- **Structure:** a parametric recursive skeleton, in the style of Weber & Penn (1995),
  "Creation and Rendering of Realistic Trees". Generation has three stages that can be
  tested separately:
  - a species `Resource` (the configuration);
  - `TreeSkeleton` (pure data);
  - `TreeMesher` (ArrayMesh).
- **No pre-built segments.** The tree is one continuous skeleton. Segments existed only
  to serve cutting. (2026-10-02: chopping cuts at a known distance up the trunk, a chop
  ring, but still on the one skeleton; see Chopping. Revised the same day: trees now grow
  in segments, so they can be chopped at any segment line, but the segments are only node
  spacing and one stored length on the one skeleton; see Segments.)
- **Runtime generation from `species` and `seed`,** in the editor and in game. No meshes
  are baked or saved.
- **Leaves:** each species chooses alpha-scissor cards or opaque low-poly clumps, to be
  compared on the headset. They are drawn in a second surface with the species' leaf
  material, so a leafy tree is two draw calls, before shadows.
- **One wood material** (`tree_wood.gdshader`) draws both bark and inner wood.
  `UV2.x = 1` marks inner wood, so a tree's wood is one draw call.

## Built with cutting in mind

- **The skeleton is the only source of truth.** The mesh and the collision are
  always rebuilt from it and never edited directly.
- **The skeleton belongs to each `ProceduralTree` node,** never to the shared species.
- **Bark V is the distance along the branch from its natural base,** multiplied by a
  constant per branch that keeps the texture's proportions on thin branches. Any piece
  of a branch keeps bark that lines up with where it came from.
- **The mesher takes a skeleton, not a node,** and can build caps with inner-wood UVs.
  The trunk's base cap already uses this.
- **Leaf clusters live in the skeleton** as a branch and a distance along it, plus their
  direction, roll, size and a seed for shape details. Leaves therefore stay attached to
  their branch.

## Segments (agreed 2026-10-02)

The player asked for trees that "generate in segments. Segments are chunks the tree can be
chopped into", so that "the entire generated tree can be chopped up cleanly no matter what
is generated". Every segment of a tree is the same length, and the length and the amount
come from ranges in the species settings.

- **Segment length:** `TreeSpecies.segment_length_min_m` to `segment_length_max_m`. Each tree
  (each variant) picks one, its first random draw, and every branch uses it.
- **Segment counts:** `TreeBranchLevel.segments_min` to `segments_max`, at every depth.
  - The trunk picks once, so its height is its count times the length.
  - A branch picks at each place it grows, and the pick is scaled by
    `length_along_parent` (at least one segment), so the pine keeps its cone.
  - These replace the trunk's `length_m`, branches' `length_ratio` and `step_length_m`.
- **Segment lines:** at every whole number of segments along a branch from its natural
  base, there is a skeleton node. `steps_per_segment` (default 2) sets the nodes per
  segment.
  - **Turning:** the path turns (bend, kinks, up bias) only at the nodes between lines,
    each by a segment's worth of the per-metre rates. So every line is a straight joint,
    and a cut there is square to both sides. 1 step keeps a branch straight.
  - **Cut faces:** the cut face at a line is perpendicular to both segments.
- **Frames:** each node keeps the frame its mesh ring is drawn in (`TreeSkeleton.axes`,
  `normals`).
  - The builder works them out once on the whole tree, carrying the normal along each
    branch without twisting. Pieces copy theirs.
  - So a piece is drawn exactly as the whole tree was, and its cut ring meets the other
    piece's at any line, kinked or not. Before this, they met only because the knee ring
    sat in the trunk's first straight stretch.
  - Smooth spline rings run on a curve between two nodes that leaves each along its stored
    axis, so a piece curves as the whole branch did.
- **Where branches grow:** in the middle of one of the parent's segments, at most one place
  a segment.
  - Each base is moved along the parent so its junction is centred in that segment, as
    far as the base stays in it (`TreeSkeleton.junction_span`). The junction runs from just
    behind the parent's centre line to where the branch's bark clears the parent's.
  - A junction longer than a segment crosses a line, and a cut there would go through the
    branch's base. The oak's thick limbs did: 0.64 m on average against 0.5 m segments, so
    43% of its trunk lines ran through one.
  - **The oak's limbs now:** they leave at 70° ± 10° (was 55° ± 12°), at 0.45 of the
    trunk's thickness (was 0.6). They curve up at 12°/m (was 3°/m), so they still reach up
    as before: 1 of 63 limbs ends lower than it starts, as 1 of 64 did.
  - **Result:** 10 of 222 trunk lines over 32 variants run through a junction (4.5%).
    Leaving at 70° alone let leaning trunks' limbs droop: 5 of 63.
- **Collision near a cut:** thick wood now has stretches shorter than its radius.
  - A capsule ending near a cut would reach through the cut face. On a cut branch, any
    shape that would becomes a flat cylinder.
  - The shape at a cut end keeps to the straight stretch next to it.

| Species | Segment length | Trunk | Branches by depth | Steps a segment |
|---|---|---|---|---|
| Oak | 0.45–0.55 m | 7–9 segments (3.2–5.0 m; was 4 m) | 5–7, 2–3, 1 | 2 |
| Birch | 0.45–0.55 m | 18–22 (8.1–12.1 m; was 10 m) | 6–8, 2–3 | 2 |
| Pine | 0.5–0.6 m | 23–27 (11.5–16.2 m; was 14 m) | 7–9, 1–2 | trunk 1 (straight), branches 2 |

- **Kinks:** chances were rescaled to keep kinks per metre, since kinks now happen once a
  segment. The oak trunk went from 0.45 to 0.28, limbs 0.4 to 0.33, depth 2 0.35 to 0.44,
  and depth 3 0.3 to 0.6.
- **Birch trunk rings:** the birch trunk's spline rings went from 2 to 1 a stretch, as it
  has twice the nodes.
- **Cost:** building a variant (three levels plus collision) on the desktop takes 1.7 ms
  for the oak, 5.5 for the birch and 9.7 for the pine.

## Path style

Each `TreeBranchLevel` has one set of path settings that makes every shape:

| Shape | Settings |
|---|---|
| Straight | All path settings at 0 |
| Angular | `kink_chance` and `kink_angle_deg`: sharp turns at single nodes, only those between segment lines. Keep `smooth_mesh` off. |
| Curvy | `bend_deg_per_m` and `bend_frequency`: a smooth turning rate that drifts along the path. Turn `smooth_mesh` on to add spline rings between nodes. |
| Reaching / drooping | `up_bias_deg_per_m`: positive turns toward the sky, negative toward the ground |

`girth_falloff` is a Curve giving radius share over length share. Without a curve, the
radius shrinks linearly from the base radius to `min_radius_m`.

## Branching

`TreeSpecies.branch_levels` holds one `TreeBranchLevel` per depth below the trunk. Each
level also has its own path style and girth settings.

| Setting | What it controls |
|---|---|
| `segments_min`, `segments_max` and `length_along_parent` | Length in segments, picked per branch, times a curve for where the branch grows on its parent (at least one). This curve shapes the crown: long low and short high makes a cone, a peak in the middle makes it round. |
| `radius_ratio` | Base radius as a share of the parent's radius there. A branch is never thicker than its parent. |
| `start_fraction`, `end_fraction`, `density_per_m` | The span of the parent that grows branches, and how many places along it do: in the middles of the parent's segments within the span, evenly spread, at most one a segment. |
| `branches_per_whorl` | Branches sharing one place, spaced evenly around it (pines use 3 to 5) |
| `spread_angle_deg` and `spread_jitter_deg` | "Spread": the starting angle away from the parent's direction |
| `phyllotaxis_deg` and `phyllotaxis_jitter_deg` | Turn around the parent between places (the golden angle is 137.5°) |

Growth is depth-first, with each branch's children grown before its next sibling. It
stops at the deepest level or at `TreeSpecies.max_branches`. A branch starts on its
parent's centre line, so its base is hidden inside the parent without any welding.

## Leaves

Leaves are placed after all branches, so leaf settings never change the branches.
Switching a species between cards and clumps keeps where its leaves grow.

**Placement** is set per branch level (`TreeBranchLevel`, Leaves group), trunk included:
- **How many:** `leaves_per_m` clusters per metre, from `leaf_start_fraction` of a branch's
  length to its tip. 0 means none.
- **Spacing:** `leaf_spacing_jitter` sets how irregular it is. At 0, clusters are even, with
  the last at the tip. At 1, each can be anywhere in its share, so a sparse density on the
  trunk gives the odd spray here and there.
- **Tip leaves:** `tip_leaves` adds that many clusters at the branch's very tip, spaced
  evenly around it, so the branch ends in leaves instead of a bare point. On the trunk this
  tops the tree with leaves.
- **Where a cluster starts:** on the bark, on the side it grows toward
  (`TreeSkeleton.leaf_anchor`). A spray on a thick trunk therefore isn't buried in the
  wood.

Per species (`TreeSpecies`, Leaves group):
- **Direction and size:** each cluster leaves its branch at `leaf_angle_deg` ± jitter,
  facing a random way round the branch, and is `leaf_size_m` ± jitter in size.
- **Cap:** `max_leaves` caps the total.

**Styles:**

| Style | Geometry | Material |
|---|---|---|
| Cards | Two crossed quads per cluster (8 vertices, 4 triangles). The texture is a spray growing rightward from its stem. `leaf_card_stem` is the stem's UV, which sits on the branch. `leaf_card_aspect` is the texture's height to width. | Must use `tree_leaf.gdshader`: double-sided, alpha scissor, and it keeps the crown normal on both sides. |
| Clumps | A lumpy icosahedron per cluster (12 vertices, 20 triangles), set out from the branch by 0.6 of its radius. `leaf_clump_jitter` sets how lumpy it is. | Opaque, for example `leaf_clump_placeholder.tres`. No example species uses clumps now. |

## Example species' looks

| Species | Bark | Inner wood tint | Leaves (cards) |
|---|---|---|---|
| Straight pine | `tree_wood_pine.tres`: the original brown noise bark | warm brown | `tree_leaf_pine.tres`, using `pine/pine_leaf.png`. Stem (0.01, 0.48), aspect 1. |
| Angular oak | `tree_wood_oak.tres`: `bark_oak.png`, fissured plates, 0.7 m tiles | darker brown | `tree_leaf_oak.tres`, using `oak/oak_leaf.png`. Stem (0, 0.5), aspect 0.69. |
| Curvy birch | `tree_wood_birch.tres`: `bark_birch.png`, white with black striations, 0.5 m tiles | pale cream | `tree_leaf_birch.tres`, using `birch/birch_leaf.png`. Stem (0.03, 0.66), aspect 1. |

Leaves per species:

| Species | Top of the trunk | Along the branches | On the trunk |
|---|---|---|---|
| Pine | 4 tip sprays | Branches and twigs at 2.5/m | 0.25/m, jittered |
| Oak | 3 tip sprays | Branches and twigs at 4/m | 0.3/m, jittered |
| Birch | 3 tip sprays | Twigs at 4.5/m | 0.3/m, jittered |

- **Barks:** both are 512 px, tile seamlessly, and were generated with numpy. The oak is
  vertically stretched cellular noise, whose cell borders are the fissures. The birch is
  warm white with horizontal lenticel dashes and dark striation bands.
- **Inner wood:** all three share `tree_inner_rings.tres`, neutral rings coloured per
  species with `inner_tint`.
- **Imports:** the bark and leaf textures import VRAM-compressed with mipmaps.
  Alpha-scissor cards shimmer badly without mipmaps.

**Shading:** leaf normals point out of the crown, rounded a little per corner. This is a
common way to shade stylised foliage as one soft volume. It still needs judging in the
headset.
- **Crown shape:** the builder records the box around the clusters in
  `TreeSkeleton.crown_middle` and `crown_half_size`.
- **Normals:** `TreeMesher.crown_normal` gives the normal of the ellipsoid through that
  box. The box is thickened to at least 0.4 of its longest half size, so a flat crown's
  thin axis can't take over.
- **Why the skeleton keeps it:** a piece of the tree keeps the shading it had.
- **Why cards need the leaf shader:** with culling off, Godot flips the normal on back
  faces. `tree_leaf.gdshader` flips it back, so a card lights the same from either side.
  With a plain double-sided StandardMaterial3D, about a third of the cards facing the
  player lit as if facing into the crown.

## Collision (agreed 2026-09-27)

**Wood** (`TreeCollider.wood`) is capsules on one `StaticBody3D` per tree, on the Static
layer, so the player body, hands and fingers all meet it, and a head leaning into a branch
darkens the view as it does at walls.
- **Where capsules go:** each branch is walked through its nodes. A capsule keeps going
  while the path stays within `collision_tolerance_m` of its axis and the radius changes by
  no more than `collision_radius_tolerance_m`. Its radius is the middle of that range.
- **Result:** straight, even stretches take one capsule; bends and steep tapers take more,
  only where they are. Points are added between nodes where the taper is steeper than the
  radius tolerance.
- **Twigs:** a branch's collision stops exactly where it thins to `collision_min_radius_m`,
  2.5 cm by default. Twigs pass through, so hands don't snag and the body doesn't get
  caught in them.

**Leaves** (`TreeCollider.leaves`) are touch-only.
- **Shapes:** one box around each card cluster's two quads, or a sphere per clump.
- **Area:** they sit on an `Area3D` on the Foliage layer (layer 10, bit 512) with mask 0 and
  monitoring off, so nothing is blocked and the area does no work of its own.
- **Detection:** hands or props can find leaves later by querying or overlapping layer 10,
  for rustle, haptics or slowing hands. `leaf_touch_volumes` turns them off per species.
- **Choppable trees** (2026-10-02): their area monitors what breaks leaves (hands, held
  items, props and enemies; see Chopping, Limbs, small branches and leaves). Only those
  trees pay for it.

**Cost:**
- Shapes go straight onto the collision objects through shape owners, with no node per
  shape.
- Each rebuild fills fresh objects before they enter the physics world.
- A standing tree does no per-frame work: the static body is not simulated, and the area
  doesn't monitor.

**Editor:** `ProceduralTree.show_collision` draws every shape as one line mesh, wood orange
and leaves green, in one draw call. It is slow to build and meant for checking only.

**Streaming** (`TreeCollisionStreamer`, agreed 2026-09-27): put trees under a streamer node
and set its `target` to the player's body or headset.
- **Radii:** its `ProceduralTree` children get collision within `build_radius_m` (30 m) of
  the target and lose it beyond `release_radius_m` (36 m). In between a tree keeps what it
  has, so walking along the edge doesn't rebuild it over and over.
- **Load:** trees under a streamer build no collision on load except near the target.
- **Fixed cost per tick:** it checks `checks_per_tick` (64) trees' distances in turn, and
  builds at most `builds_per_tick` (1), nearest first.
- **Jumps:** if the target moves more than `jump_distance_m` (5 m) in one tick (teleport,
  respawn), it checks and builds every tree at once. `refresh_now()` does the same on
  demand.
- **No target:** every tree keeps its collision.
- **Standalone trees:** a tree not under a streamer always has collision, as before.
- **Only the target counts:** a thrown prop or another character far from it passes
  through trees there.

Measured on the desktop with 1,000 trees and the target walking:
- about 16 µs per tick of streamer work;
- about 113 µs for a full check after a jump, not counting the collision builds that
  follow. A jump builds every nearby tree in that tick, so a teleport into a dense spot
  costs one longer frame; teleports usually happen under a fade.

On the desktop, seed 1, not measured on Quest:

| Species | Capsules | Leaf volumes | Regenerate, no collision | With wood | With wood and leaves |
|---|---|---|---|---|---|
| Straight pine | 57 | 231 | 4.5 ms | 4.4 ms | 5.2 ms |
| Angular oak | 38 | 140 | 2.2 ms | 2.4 ms | 2.8 ms |
| Curvy birch | 15 | 155 | 3.4 ms | 3.5 ms | 4.0 ms |

- **Oak capsules:** most of the oak's capsules come from its steep trunk taper. Raising
  `collision_radius_tolerance_m` trades accuracy at the bark for fewer capsules.
- **Regenerate timings:** these are desktop timings of `ProceduralTree.regenerate` in a
  running scene. They don't include any shape building the physics engine defers to its
  next step.

## Detail levels (agreed 2026-09-27)

Every tree has three meshes, all built from the same skeleton, so they keep one shape
(`TreeMesher.Level`):

| Level | Wood | Leaves |
|---|---|---|
| Full | Everything | Every cluster |
| Medium | Half the sides, no smoothing rings; branches thinner at the base than `lod_medium_min_branch_radius_m` (1.5 cm) are left out | One cluster in `lod_medium_leaf_step` (2), each scaled by the step's square root so the crown keeps its leaf area |
| Far | 3 sides; only branches from `lod_far_min_branch_radius_m` (4 cm) | One cluster in `lod_far_leaf_step` (4), scaled the same way |

**Switching:** `ProceduralTree` puts each level on its own internal instance.
- **Culling:** the engine's visibility ranges cull each level, with no script running per
  frame.
- **Distances:** levels change around `lod_medium_distance_m` (25 m) and
  `lod_far_distance_m` (60 m). The tree fades out entirely around `lod_hide_distance_m`
  (250 m; 0 for never).
- **Fade band:** each change dissolves over `lod_fade_band_m` (4 m), never an abrupt pop.
- **Preview:** `detail_preview` pins one level at every distance, for checking it in the
  editor.

**The fade is our own dithered crossfade** (`tree_lod.gdshaderinc`). Godot's built-in
visibility-range fade doesn't fit:
- **Mobile, our renderer:** the 4.7 source has no fade handling in its render lists at all,
  so it would silently pop.
- **Forward+:** it draws fading objects in the alpha-blended pass
  (`render_forward_clustered.cpp`), which is costly and unsorted for foliage.

How it works:
- **Complementary pixels:** in a band, both levels are drawn, and each discards the pixels
  of a 4×4 ordered-dither pattern the other keeps. Every pixel is drawn exactly once.
- **Where distance is measured from:** the main camera, in every pass, so shadows fade with
  the tree and not with the light.
- **Where distance is measured to:** the engine measures visibility ranges to the centre of
  each instance's world bounds (`renderer_scene_cull.cpp`). So all three levels share one
  `custom_aabb`, and the shaders measure to its centre, passed as the `lod_centre` instance
  uniform.
- **Settings per instance:** `lod_fade` holds each level's fade distances, so materials stay
  shared.
- **Material requirement:** any material on a tree must include `tree_lod.gdshaderinc` to
  fade. `tree_wood`, `tree_leaf` and `tree_clump.gdshader` do. The clump placeholder is now
  a `tree_clump` material.

Triangles on the desktop, seed 1, full / medium / far:

| Species | Wood + leaf triangles |
|---|---|
| Straight pine | 4,852 / 2,360 / 1,210 |
| Angular oak | 2,714 / 970 / 392 |
| Curvy birch | 5,745 / 1,062 / 441 |

Building the two extra levels adds 1 to 2 ms per tree. Regenerating a whole tree in a
running scene, with all levels and collision, takes 7.4 ms (pine), 3.8 ms (oak) and 5.0 ms
(birch) on the desktop.

## Sharing and forests (agreed 2026-09-27)

**Variants** (`TreeSpecies`, Variety group): a species grows `variants` different trees (8
by default; 0 makes every seed unique).
- **Seed:** a tree's seed picks its variant (`variant_for`) and, from its own generator, a
  turn about the vertical (±`turn_variation_deg`) and a uniform size change
  (±`size_variation`) (`variation_for`).
- **Where the turn and size go:** onto the tree's internal level instances, body, area and
  outline, never onto the node, so the node's transform stays yours.

**Sharing** (`TreeCache`): every tree on the same species and variant shares one skeleton,
the three detail meshes and the collision shapes.
- **When things are built:** a variant is built the first time a tree needs it. Its
  collision shapes are worked out only when a tree first gets collision.
- **Read-only:** a tree's `skeleton` is shared. A future cut must copy it and build that
  tree's own meshes (copy on write).
- **Regenerate:** clears that species from the cache and rebuilds the tree. Other trees of
  the species keep their old build until they regenerate too. That's the same as before,
  since editing a species never updated trees by itself.
- **In the editor:** trees build no collision there unless `show_collision` is on, since
  the editor never simulates physics.

**Forests** (`TreeScatter`): grows `tree_count` trees over `area_size_m` from `forest_seed`,
so the same seed always gives the same forest.
- **Spacing:** points are dart-thrown with at least `min_spacing_m` between trees, and none
  within `clearing_radius_m` of the centre.
- **Species mix:** repeat a species in `species` to make it more common.
- **Where trees go:** under the given `streamer` as internal children (never saved), so
  collision streams. The ground is taken as flat at the scatter's height.
- **Updating:** "Scatter again" regrows the forest.

**Test scene:** `scenes/forest_test.tscn` has the `VrController` in an 8 m clearing.
- **Forest:** 400 trees over 180 × 180 m (pine, oak and birch, 8 variants each), streaming
  collision to `VrController/Physical/Body`.
- **Ground:** 400 m with collision and a tiled grass material without the heightmap.
- **Light:** the forest environment and a sun whose shadows reach 60 m.

Measured in a copy of the full project with the real player, XR off, on the desktop:
- **Load:** 228 ms with sharing (24 variants built) against 1,877 ms with every tree
  unique (400 built).
- **Collision near the spawn:** 31 trees.
- **One view from the spawn (desktop, not Quest):**

| Setup | Objects | Draw calls | Triangles |
|---|---|---|---|
| As built | 385 | 385 | 803,000 |
| Sun shadows off | 240 | 240 | 319,000 |
| Switch distances 15 m / 35 m, hidden past 120 m | 377 | 377 | 646,000 |

## Impostors (agreed 2026-09-27)

Trees placed by a `TreeScatter` are drawn beyond `impostor_distance_m` (100 m) as a picture
of themselves on a card that turns to face the player. Every card of a species is in one
MultiMesh, so a whole forest's distant trees cost one draw call per species. This needs
the species to have variants; 0 impostor distance turns it off.

**Baking** (`TreeImpostors`, rendered when the level loads):
- **What's rendered:** each variant's far-level mesh, from the side, with an orthographic
  camera in an offscreen viewport and an unlit bake shader (`tree_impostor_bake.gdshader`).
- **Two pictures:** colour with a transparent background, and world-space normals so the
  card is lit like the real tree.
- **Speed:** all of a species' variants render in the same frame, taking 74 to 194 ms per
  species on the desktop.
- **Storage:** pictures go into two `Texture2DArray`s, one layer per variant, all framed on
  the same square. They're `impostor_resolution` px (256), with transparent edges filled
  and mipmaps.
- **Why the far level:** baking the level the card replaces keeps the handoff's density and
  look.
- **Without a renderer** (headless): nothing is baked, and trees keep their own far level
  and hide distance.

**Drawing** (`tree_impostor.gdshader`):
- **Per-card data:** each instance is placed where the tree's levels measure their distance
  to, and carries the tree's turn and size, plus its variant's layer and picture centre.
- **Placement:** the card stands upright facing the main camera, the same for both eyes,
  positioned so the picture's trunk stands on the real trunk.
- **Lighting:** baked normals turned with the card, and the leaves' specular (0.15).
- **Near trees:** closer than the fade band, a card collapses to a point.

**Handoff:**
- **When:** once a species' pictures are baked, its trees set `impostor_handoff`, and their
  far level ends at the impostor distance.
- **How:** it dissolves into the card over the fade band with the same dither, measured to
  the same point, so each pixel is drawn exactly once.
- **Known difference:** a single picture shows each variant from one side, while the real
  tree is turned by its seed. The crown arrangement shifts a little during the 4 m
  dissolve; the trunk stays put. 8 views per variant would remove that at 8 times the
  texture memory.

**Refreshing:** "Scatter again" and a tree's "Regenerate" clear the cached pictures along
with the cached meshes.

Measured on the desktop:
- **2,500 trees over 500 × 500 m, from the middle, one view:** 248 draw calls and 494,000
  triangles with impostors, against 1,097 draw calls and 1,061,000 triangles without. The
  two renders look nearly the same.
- **`forest_test.tscn`, now 2,000 trees over 400 × 400 m:**
  - loads in 286 ms with the player (24 variants built);
  - one view from the spawn is 370 draw calls and 789,000 triangles, shadows included,
    about the same as the old 400-tree forest, with the whole forest visible.

## Chopping (agreed 2026-10-02)

A tree is chopped at its **segment lines** (see Segments): a line every segment along every
branch, from its natural base. Every line on wood thick enough to hit can be chopped,
standing or felled, and every one behaves the same (step 1b, 2026-10-02: "The player should
be able to chop at any segment line along the tree and it should behave the same... Branches
are to be treated the same"). A line is a distance along its branch on the one skeleton, so
the skeleton stays the source of truth. The first trunk line (one segment up, 0.45–0.55 m on
the oak) is where a tree was chopped down before; it replaced the knee ring (0.4 m).

**Which lines can be chopped** (`TreeChop.choppable`):
- **Thick enough to hit** (`TreeSkeleton.line_is_wood`): the wood is at least
  `collision_min_radius_m` (2.5 cm) thick at the line and half a segment beyond it, so the
  piece cut off there has collision to land on and be struck. (The review of step 1b found
  pieces cut where the wood only just reached 2.5 cm. Their only collision was a few
  millimetres of cut face, and one fell through the level's floor. Over 32 variants the rule
  takes 6% of the oak's wood lines, 14% of the pine's and 10% of the birch's.)
- **Clear of its parent:** past where the branch's bark clears its parent's
  (`TreeSkeleton.bark_clear_distance`); closer in, the cut would run through the parent too.
- **Not through a junction:** no live branch's junction (`TreeSkeleton.junction_span`) crosses
  it (`line_blocked`), since a cut there would go through that branch's base. Only a junction
  crossing the line blocks it. The plan said "within the notch's reach of a junction", but
  that blocked 98 of 222 oak trunk lines, among them every line of the level's oak from 2 m
  up. Cuts 1–27 mm from a junction that doesn't cross the line don't pop in the probes; a
  notch there may show a little of the branch's buried base, to be judged in the headset.
  A limb cut off leaves its stub, whose junction still blocks a line it crosses (step 1c
  breaks a piece with only blocked lines left into loot).
- **Twigs** (`TreeSkeleton.is_twig`: no line that is wood to chop, neither a root nor a cut
  stub) have no lines. They break off whole on any strike at `BREAK_SPEED` (2 m/s) or
  faster, with everything growing from them and their leaves. A leaf on a twig takes the
  twig; a leaf on wood with lines goes alone.

**How a slash counts.** `TreeChop` is a child of the tree, with a `Strikeable` of wood beside
it.
- **Only slashes chop:** a strike dealt by a `Sharp` edge or point. Blunt blows are still
  strikes, with their haptics and readout, but cut nothing.
- **On the branch nearest the bark:** a strike lands on the branch whose bark is nearest its
  point (`TreeSkeleton.nearest`), and counts only within 0.1 m of that bark.
- **Forgiving (2026-10-02, "some of my hits I feel don't register"):**
  - The line being chopped (`current`, the one last struck) keeps every slash within
    `band_m` (0.35 m) of it along its branch, up to three quarters of a segment, so the next
    line can still be started.
  - Otherwise a slash counts on the nearest line within `band_m` that can be chopped, passing
    over lines that can't. With lines 0.47 m apart on the oak, every slash on choppable wood
    counts somewhere.
- **Sides:** a trunk line has `sides` (8) round it; any other line one side, all round.
  - Sides are numbered from the node frame the notch is drawn in (`TreeSkeleton.normals`), so
    a notch opens on the side chopped on every line and every piece. Numbering them from
    `any_perpendicular`, as the knee ring did, was up to 178° off the drawn notch on high oak
    lines.
  - A slash opens the side it lands on by its damage (1 to 10), up to the line's cap. On a
    trunk line it also opens the sides either side by `spill_share` (0.25) of its damage,
    rounded, so the cut spreads round the trunk and its notch fades into the next sides.
  - A full side takes no more and spreads none, so the player chops around the trunk.
- **What a line takes:** what cuts through scales with the wood's cross-section:
  `first_line_total` (300) at the trunk's first line, `300 × (r / r_line1)²`, at least
  `least_total` (10). The whole tree's trunk radius at its first line,
  `TreeSkeleton.first_line_radius`, is kept by every piece, so a log scales as the tree did.
  Each of a trunk line's sides takes the total over `sides_to_cut` (6), rounded up, so six
  full sides always cut it: 50 at the first line. (Rounded to the nearest, six full sides
  fell 1 or 2 short on a quarter of the oak's trunk lines and over a third of the pine's and
  birch's. On a thin lying log the spill could then fill every side within reach and leave
  it uncut.)
  - The level's oak, trunk lines 1–8: 300/50, 266/45, 250/42, 245/41, 245/41, 247/42,
    244/41, 233/39 (total/cap).
  - Its limbs: the thick one can't be chopped at its line 1 (still inside the trunk's bark,
    which it clears 1 cm further out), so lines 2–5 at 27, 18, 11 and 10; the other at lines
    1–3, 31, 18 and 10; one small branch at its line 1, 10. The other 10 of its 14 branches
    are twigs.
- **Through:** at its total, `TreeChop` cuts the tree there itself (`ProceduralTree.sever`).
  What is left with no line to chop is a lone piece, which breaks into loot (see Lone
  pieces).
  - A standing tree's trunk line tips the part above over away from the wood still uncut,
    hinged to the stump (see Felling), and emits `felled`. Above head height too.
  - Any other line just lets the part beyond go: a branch drops, a log comes off a felled
    trunk (bucking). No tipping, no hinge.
  - The cut line is gone from both parts. A part cut off takes the lines it carries, as they
    were (each keyed by its branch's `branch_id` and line number), and the tree's settings.

| Setting (`TreeChop`) | Default |
|---|---|
| `band_m` | 0.35 m along the branch (0.15 at first: "way too precise"; 0.3 still missed hits) |
| `sides` | 8, on trunk lines |
| `first_line_total` | 300 at the trunk's first line (six sides of 50, about 19 full-strength blows with the spill) |
| `least_total` | 10 |
| `sides_to_cut` | 6: each side of a trunk line takes a sixth of its total, rounded up (over `sides` instead, if that is fewer, so a line can always be cut through) |
| `spill_share` | 0.25 (a full-strength slash opens each side next to it by 3) |
| `impact_speed` | 2 m/s: how fast a felled piece's branch must hit something solid to break at its nearest line (see Fall damage) |

Distances are in the tree's own metres, before its ±15% size variation.

**Every strike is judged for the recorder.** `TreeChop` writes what it made of a strike on
`Strike.judged`: the outcome (`TreeChop.Outcome`: counted, blunt, no damage, off the bark,
off every line, blocked, full side, twig broken (only if it did break), twig held, lone), the
branch's depth, the line it counted on or the nearest, how far along the branch from that
line it landed, and the side. `LocomotionRecorder` writes them per hand with the strike's
point (`left_strike_x` ... `right_chop_side`), so a recorded session (`-- --record-session`)
shows why a hit didn't count.

**Why hits didn't register (2026-10-02, investigated after the user's report).** No
recording covered that session, so this comes from the code, the older recordings and
headless probes:
- **The axe's corners were blunt.** Its `Bit` (the Sharp edge) was 0.178 m long on a head
  whose front face is 0.216 m tall, so the face's toe and heel corners sat 2.4 cm off the
  edge, outside its 2 cm reach. A swinging axe usually lands a corner first, which read
  blunt, and its edge settling on the bark a tick later couldn't strike again (a pair
  strikes only on the tick it starts touching). In a Jolt probe 29 of 60 level swings and 25
  of 40 diagonal ones read blunt. The Bit now covers the whole face (`length` 0.216): 0 of
  60 and 3 of 40.
- **The ring was below the swing.** On the post, the player's striking hand was at 1.30 m
  (median) when they chose the height; the ring's band covered 0.17–0.76 m. Every line
  chopping fixes that.
- Ruled out: the bark margin, `nearest`, leaves, the strike's re-arm time, and the 2 J
  threshold (only taps and bounces fell under it).

**Being struck.** A tree's wood body is built at runtime and rebuilt whenever its collision
streams or the tree is cut. So the tree hands each body it builds to its `Strikeable`
(`Strikeable.mark`, which marks a body once however often it is asked: a felled part that
was bucked marked its body twice, and freeing it then logged an engine error).

**Readout** (`TreeChopDisplay`). It follows the line last struck, a full side's too, so the
player sees that side is full. On a trunk line it shows each side's opening on the bark at
that side, hidden when behind the wood; on every line the total against what cuts through
it, "190 / 300", above the line in world up (so it reads on a lying log too), drawn over the
wood. It hides when no line is being chopped, as after a cut,
until the next strike. Each felled part has its own. A lone piece's shows its health
instead (see Lone pieces).

**Ladder.** Each rung is tested in the headset before the next.
1. **The chop ring: built.** Strikes reach the tree, and the ring opens.
2. **The fall: built** (see Felling).
3. **Notches: built** (see Notches).
4. **Limbs, small branches and leaves: built** (see below). Since step 1b, limbs and small
   branches are chopped at their lines like the trunk; only twigs break.
5. **Segments: built.** Step 1a, trees grow in segments; step 1b, every line chops,
   standing or felled, including bucking a felled trunk into logs.
6. **Lone segments: built (step 1c).** A part cut down to one segment shows its HP and
   breaks into loot (3 logs a trunk segment, a stick a branch segment).
7. **Fall damage: built (rung 7, 2026-10-03).** A falling part's branches break at their
   lines when they hit something solid hard (see Fall damage).

### Lone pieces (step 1c, built 2026-10-02)

Asked at the review of the segments plan: "The root of the tree wont move but if the
segment above the first root segment is chopped, then the trunk should have an hp amount
that when destroyed, drops wood logs as loot. This rule should apply for each segment...
Make each segment drop 3 wood logs. The branches behave the same way... drops a stick for
its loot while destroying the branch". Decided with the player: the HP is fixed per kind,
and only slashes take it.

- **Lone:** a piece of a tree with no line left that can be chopped (`TreeChop.is_lone`),
  usually one segment with whatever stubs and twigs grow from it. A blocked line doesn't
  keep it attached, so a piece whose only lines a junction crosses is lone too, and every
  tree can be broken up completely. TreeChop looks when a piece is cut off (at the end of
  the frame, once the piece has the tree's settings) and whenever its tree is cut (at once):
  the stump is lone in the tick line 1 is cut through. A standing tree is lone only once its
  trunk is cut, as the user put it ("The root of the tree wont move but if the segment
  above the first root segment is chopped"), so an uncut tree with no line to chop stays
  whole.
- **What it gets,** on the piece's `FelledTree` body, or on the tree itself for the stump,
  which never moves:
  - a `Health` of `trunk_segment_health` (50) if its main branch is the trunk, else
    `branch_segment_health` (10), that only slashes take (`Health.kinds`);
  - a `LootDrop` of `logs_per_segment` (3) logs (`scenes/props/wood/log.tscn`) or
    `sticks_per_segment` (1) stick (`stick.tscn`) for each segment of wood its main branch
    holds (at least 2.5 cm thick where the segment starts, `TreeSkeleton.wood_segments`;
    at least one), laid round its
    middle (`LootDrop.centre`: a `LoneMiddle` marker on the body) on their sides
    (`LootDrop.lay_down`). Laid standing, as ores are, 8 of 9 logs in the harness landed on
    their flat ends and stayed standing, and a stick never fit upright beside a lying branch.
- **The loot** (2026-10-02, the player: "the stick and log loot should have some angular
  damp so they dont roll away forever. The stick should be maybe 2.5kg and the logs can be
  8kg"): a log weighs 8 kg and a stick 2.5 kg (the level's own log and stick too). Jolt has
  no rolling resistance, so each damps its spin:
  - The stick, a round cylinder, rolled on forever below 1 mm a tick (a creep of Jolt's
    contact cache) at any angular damp up to 3, and took 6 s to stop at 4. At 6 a 1 m/s roll
    stops in 0.46 m and 1.75 s, and a 1.5 m/s one in 0.69 m and 2 s (`loot_stick_roll`). The
    cost: a thrown stick keeps only 4% of its spin after 0.5 s, so it hardly tumbles. A
    faceted collider would stop it with little damp, but its grip handle must stay a
    cylinder.
  - The log's lumpy hull stops it at any damp, so it takes 1, as felled pieces do: rolled at
    1.5 m/s it stops in 0.46 m and 1 s (`loot_log_roll`), and a throw keeps 57% of its spin
    after 0.5 s.
  - On a slope a round stick still rolls slowly down, at about 0.27 m/s on 5°.
- **Readout:** the chop readout gives way to the piece's health, "50 / 50"
  (`HealthDisplay`), above the bark at its middle in world up, kept there as the piece moves.
  Unlike the chop readout it is hidden behind what stands in front of it, as a vein's is, so
  the labels of logs lying about don't show through walls.
- **Rolling:** a lone piece damps its spin at `lone_angular_damp` (16 a second, where other
  pieces take 1), so it doesn't roll off when walked over or pushed (2026-10-03: "the
  individual stick and log segments also roll way too easily when walking over them or
  pushing them").
  - **Walking into a log:** measured on the level's oak (75 kg log, 25 kg stick). A log
    walked into rolls on 0.10 to 0.26 m after the last touch (2.5 to 3.1 m at 1), and is at
    rest in 0.7 to 3.3 s. While pushed, it slows the player to 0.78 m/s: the legs push at
    most 900 N, so it is still pushed along, 1.3 m in a 2.25 s walk.
  - **A stick:** kicked, it moves 0.2 m and rests in 1.3 s (0.9 m and 5.6 s at 1). Lying
    across the way, it is stepped over.
  - **The thin tip that crept:** a thin branch tip that crept on for ever at up to 10 slows
    to about 0.02 m/s at 16 and falls asleep.
  - **In the air:** a lone piece tumbles less as it falls.
  - Bigger pieces keep `FelledTree.ROLLING_DAMP`, so a felled top tips and falls as before.
- **At 0:** the piece is gone, as an ore vein is, and its loot is laid still in a ring round
  its middle, clear of everything but the piece; once the piece is gone it falls. For the
  stump, the whole tree goes. What rests on the piece is woken first (every rigid body in a
  box round its wood, 5 cm wider): Jolt leaves a sleeping body where it slept when what held
  it up goes, and a felled top propped on its stump hung in the air once the stump went
  (found in review; on the level's oak it hung until woken, then dropped 0.11 m).
- **Strikes:** every slash that does damage on a lone piece, wherever it lands, takes its
  health and is judged `LONE` for the recorder; one on a twig at `BREAK_SPEED` or faster
  breaks the twig off as well, as any fast strike does. Blunt blows take nothing (`BLUNT`)
  and still break twigs.
- **The vein's parts, shared:** `Health.kinds` takes every kind by default, and LootDrop's
  `centre` is unset and `lay_down` off, so the veins are unchanged. LootDrop now also passes over the object
  itself when it is a body (a felled piece), as it did every body below it (the stump's wood
  body among them), so nothing of the piece blocks its loot.

| Setting (`TreeChop`, Lone pieces) | Default |
|---|---|
| `log_scene`, `logs_per_segment` | `log.tscn`, 3 a segment of trunk |
| `stick_scene`, `sticks_per_segment` | `stick.tscn`, 1 a segment of branch |
| `trunk_segment_health` | 50 (five full-strength slashes) |
| `branch_segment_health` | 10 (one) |
| `lone_angular_damp` | 16 a second: a lone piece's spin damping, so walking into it doesn't send it rolling |

### Fall damage (rung 7, built 2026-10-03)

The player: "When branches impact the ground, they should damage and depending on the
impact, they should break their segments". Decided with them: only branch lines, so the
trunk stays whole and is bucked with the axe; anything solid counts; and "apply the damage
of the max health of that segment, so it always breaks".

- **The rule:** a felled piece's branch (not its trunk, a twig or a lone piece) that hits
  something solid at `impact_speed` (2 m/s, `ProceduralTree.BREAK_SPEED`, which also breaks
  twigs and leaves) or faster breaks at its segment line nearest the hit, at any distance
  from it. The line is cut through as slashes cut it, and the part beyond becomes a piece
  of its own and moves on.
- **What is solid:** whatever is on the Static layer: the level's floor, stumps, standing
  trees and other pieces.
  - Props, held items, hands and the player don't break branches. They strike, and only
    slashes chop, so a thrown axe doesn't sever lines.
  - A standing tree that a falling piece hits loses nothing, because it can't report
    contacts.
  - A piece lying there that another hits hard breaks too, since the closing speed is
    relative.
- **A speed, not an energy:** pieces weigh 25 to 900 kg, and a limb rocking at 0.16 m/s
  already carries wood's 2 J damage threshold. The speed keeps settling from breaking
  anything: landings come in at 3 to 8 m/s, and settling stays under 1 m/s.
- **How a piece reads its impacts** (`FelledTree._read_impacts`):
  - It has the engine report its contacts (`MAX_CONTACTS`, 64). When there are more, the
    engine keeps the deepest and drops the shallowest, which is a fresh impact's. A 75 kg
    log lying among the other pieces reported 30.
  - It reads them every tick before Striker can cut it (`PRIORITY`).
  - It counts a contact that touches, by the strikes' own test (`Striker.touches`), and
    closes fast enough.
  - The contact's shape names the branch (`ProceduralTree.branch_of_shape`), and
    `TreeSkeleton.nearest_on` gives where along it. The nearest branch to the point would
    mislabel junctions, where a limb's capsules start inside its parent.
- **At most one cut a tick:**
  - Each cut builds two pieces' meshes and collision, 1 to 7 ms on the desktop.
  - So impacts mark lines (`TreeChop.impact`, emitting `impacted`), and at most one breaks
    each physics tick across every tree (`TreeChop.break_next`, `IMPACT_CUTS_PER_TICK`).
  - A marked line goes with its piece until it breaks, so none is lost.
- **A moving piece cut keeps its motion:** each part moves as the point its centre of mass
  is now at did (`FelledTree.centre_of_mass`). The engine already holds a cut's new shapes
  in the tick of the cut. Both parts used to take the whole's velocity, which for a limb of
  a spinning top was 1.5 m/s off in a check and 2.5 m/s in a probe. Every cut before fall
  damage was on a piece at rest.
- **What a landing does** (harness, the level's oak):
  - **The felled top:** it lands and breaks 6 times, limb 1 at lines 5, 4, 3 and 2 and limb
    8 at lines 3 and 2, closing at 2.5 to 7.3 m/s. It goes from 900 to 700 kg, every broken
    piece 25 kg but one 75 kg, and the trunk stays whole. The top rests 4 s after the cut;
    the last of its pieces rests at 8 s.
  - **Limb 1 cut off the standing tree:** it falls about 3 m, lands at 6.4 m/s and ends in
    its segments, 5 pieces.
  - **Any free fall from more than about 0.2 m** reaches 2 m/s, so a limb cut off a lying
    top breaks up too: dropped from 0.5 m it broke 3 times. A limb laid down from 2 cm
    stays whole (`chop_limb_set_down`).
  - **Why it breaks again:** each segment bounces and slaps down again, and every hit is
    measured once. That is the literal rule; the headset judges it, and `impact_speed`
    tunes it (about 4 m/s for drops of 0.8 m or more, 6 m/s for 1.8 m or more).
- **Cost:** a fall-damage cut takes 0.5 to 2.9 ms on the desktop, and the tick it happens in
  1.5 to 3.9 ms, against 0.6 to 0.8 ms usually. Quest is unmeasured.
- **Known limits, from the physics, not the rule:**
  - Broken segments roll and rock for 4 to 7 s, up to 1.3 m, as nothing resists rolling.
  - A thin broken tip (about 3 cm round) can creep on at 7 cm/s and never sleep. This is
    Jolt's round-shape creep, the stick's (see Lone pieces).
  - A felled top that has lost its limbs may lie with its butt up to 26 cm off the floor,
    so a log bucked off it there drops.
- **Limit:** at 72 Hz an impact can't count twice: Jolt's 2 cm look-ahead leaves at most
  1.58 m/s closing the next tick. Above about 120 Hz it could, so keep `impact_speed` at
  1.6 m/s or more.

### Felling (rung 2, built 2026-10-02)

Decided with the player: the tree falls away from the uncut wood and stays where it lands.
At first it passed through the player. After the first headset try it meets everything,
and it should be very heavy.

- **Which way:** `TreeChop.fall_direction(line)`. The tree falls away from what is left of
  the line, each side weighing as much as is left of it, as a tree tips away from the hinge it
  stands on. If what is left is even all round (two opposite sides, say), it falls away from
  the side the last slash opened, which is the player's.
- **The split:** `TreeChop` cuts the tree itself (`ProceduralTree.sever(branch, distance,
  toward)`) and emits `felled(distance, toward)`. Until step 1b the level wired `felled` to
  `ProceduralTree.fell`, which is gone.
  - `TreeSkeleton.split` cuts the skeleton at the line into two skeletons. Every node, branch
    and leaf keeps its distance along its branch, and both keep the crown box, so leaf
    shading doesn't change.
  - The tree keeps the stump, built as its own `TreeCache.Entry` outside the cache. Its trunk
    ends at the line in an inner-wood cap, and its collision ends there flat, in a cylinder.
  - Everything above becomes a `FelledTree`.
- **Bark that lines up:** each branch keeps its natural base radius (`branch_base_radius`),
  which sets its sides and texture repeats.
  - The stump's last ring of bark and the top's first are the same vertices, with the same
    texture coordinates.
  - The ring frames match at every line: each node keeps the frame its ring is drawn in,
    and every line is a straight joint (see Segments).
- **The falling top** (`FelledTree`, a `RigidBody3D` beside the tree):
  - Its wood is a `ProceduralTree` of its own, grown from its piece of the skeleton
    (`grow_piece`) and colliding through the body. So it is drawn with the three detail
    levels, and chopped and broken as a standing tree is (see Limbs, small branches and
    leaves).
  - It collides through capsules, flat at the cut (a cylinder) so it rests on the stump.
    Rounded ends would overlap the stump and throw the pieces apart.
  - It moves with continuous collision detection (`continuous_cd`), as the weapons do, so a
    thin piece falling fast can't pass through the level's thin floor between two ticks.
  - **Its mass is its segments'** (2026-10-02, the player: "Trees are insanely heavy in real
    life and I would like them to be here. I think each segment (trunk root) should be 75kg
    and each branch segment should be 25kg... the weight of the new chunk should be the
    combined weight of all the connecting segments"): `trunk_segment_mass_kg` (75) for each
    segment of wood on its trunk and `branch_segment_mass_kg` (25) for each on any other
    branch, weighed again at every cut (`FelledTree._weigh`).
    - A segment of wood is at least 2.5 cm thick where it starts
      (`TreeSkeleton.wood_segments`). Twigs (`TreeSkeleton.is_twig`) weigh nothing, though a
      few are 5 to 6 cm thick at the base: they break off whole, as leaves do, so a piece
      weighs the same before and after. Counting them would make whole trees 4-8% heavier.
    - A cut splits the weight exactly: the two pieces weigh what the whole did (checked over
      66,000 cuts of 24 trees). The level's oak: the top felled at line 1, 900 kg (8 trunk
      and 12 branch segments; 1,156 kg before, by its shapes' volume at 700 kg/m³); limb 1
      cut off at its line 2, 150 kg (27 kg before); a one-segment trunk log, 75 kg (123 kg
      before); a limb's last segment, 25 kg (1.7 kg before).
    - What it does not change: how a piece tips, falls and settles on its own (Jolt scales a
      body's inertia with its mass, and the tipping spin cancels it), so falls look as before.
      Walking into a trunk log lying on its side still rolls it: the trunk collides as round
      capsules with no rolling resistance, and the body pushes on whatever the log weighs
      (a 75 kg log rolled 3.2 m ahead of a walk, the 123 kg one 2.9 m).
  - It is on the Static layer, as the stump and every standing tree are, and scans every
    layer props do. It meets the floor, the stump, loose and held props, the player's body
    and the hands. The ground sense counts it, so the player can stand on it. A limb cut off
    above the player (125-150 kg since the weights by segment) shoves them about as it
    lands, 0.2 to 0.6 m in probes, and can pin a hand.
  - Headset bug, fixed: the top had no layer of its own, with only Static and Dynamic in
    its mask. Other bodies then met it only through its mask, and Jolt left its mass out
    of those contacts. A dropped axe drove the 1,336 kg top into the floor at the axe's own
    speed, the same at 50 kg, and it spun there. On a layer, the same drop moves it 7 mm
    (`chop_axe_drop_on_log`), and a 500 N push for 2 s moves it about 2 cm.
  - Known limit: a thin prop lying where the top lands can be pushed through the floor.
    The level's floor is a thin one-sided mesh. The axe lying flat (2.5 cm) is lost this
    way, at any top mass down to 100 kg, while a 10 cm box is pushed aside and stays. A
    falling limb does it too: a stick lying across where limb 1 lands went under at 5 of 9
    places (4 of 9 when the limb weighed 27 kg).
- **Tipping over:** it starts resting flat on the stump. At its first physics tick it is spun
  about the cut's edge on the falling side, at 1.25 times the least spin that lifts its
  centre of mass over that edge (worked out from its mass and inertia). It goes over slowly
  at first, as a felled tree does, and gravity does the rest.
- **Hinged (2026-10-02):** from then until it has turned 45° (`HINGE_BREAK_DEG`), a hinge joint holds
  it to the stump at that edge, as the hinge of wood a feller leaves does. The hinge turns
  only about the level axis square to the way it falls.
  - **Why:** the level's oak grown in segments leans: it kinks 19° just above line 1, so
    its centre of mass sits 0.34 m off its trunk, square to the way the scenario fells it.
    Without the hinge, it rolled along the stump's edge as it tipped and fell 50° off. Now
    it falls straight to 50°.
  - **Afterwards:** once its crown is down, a lopsided top can still roll on over a limb.
- **Afterwards:**
  - The stump keeps its `Strikeable` and `TreeChop`. Cut at line 1, it has no line left to
    chop and is lone: its health shows, and slashes break it into 3 logs, the tree with it
    (see Lone pieces). Cut higher, it keeps the lines below the cut, which still chop.
  - The readout hides until the next strike.
  - The top sleeps where it lands.
  - The top's branches break at their lines where they land hard (see Fall damage).
  - The top's leaves break against what it meets as it falls or lies: the floor, the stump
    and props, at any speed (the player's call, 2026-10-02: "if the leaves ever touch
    anything, they should be deleted"). Since the next round, not the player's body, and
    the hands only at a swing's speed (see Limbs, small branches and leaves).
    - In `chop_tree_falls`, 22 of its 28 clusters are gone by the time it lies at rest. A
      cluster on a twig takes the twig and its other clusters with it; before segments, 16
      went when each cluster went alone.
  - The trunk's notch ends: the stump and the top are cut flat there.

### Notches (rung 3, built 2026-10-02)

As a line opens, its bark opens in one V notch running round the branch
(`TreeMesher.build_band`). The notch is deepest where the ring is most open and fades
smoothly between sides, so the player sees where they have chopped and how far.

- **Shape:** its depth at each angle round the trunk (`TreeMesher.notch_depth`):
  - each side's opening, `depths[k] / cap` (the line's), at the middle of side k, eased
    (smoothstep) into the next side's between them;
  - so one opened side's notch fades to nothing at the middles of the sides either side,
    half as deep at its corners, and opened sides next to each other make one groove.
  - The V's bottom runs `notch_depth_share` (0.9) of the trunk's radius in from the bark
    where a side is fully open.
  - Its mouth reaches `notch_height_share` (0.25) of its depth up and down the bark from
    the line, so the mouth narrows as the notch fades.
  - The notch's faces are inner wood, laid out as on a cap, so the growth rings show, with
    smooth normals round the trunk.
- **Revised after the first headset look (2026-10-02):** "far too jarring of a transition
  between chopped sides... the notch should be shorter".
  - At first each side was its own V with walls between sides, and its mouth was 0.5 of
    its depth: 33 cm tall for a full side.
  - Now it is one fading groove, drawn in `BAND_COLUMNS_PER_SIDE` (4) columns a side, its
    mouth half as tall: 17 cm for a full side.
  - The spill into the next sides (above) makes the fade the line's real state, not just
    its look.
- **Drawing it:** TreeChop asks the tree (`ProceduralTree.notch_ring`) whenever a line
  changes: a standing tree's first trunk line from when it is ready, so its first chop costs
  no more than the rest, and any other line from its first cut.
  - From a line's first call, the full detail level leaves a band of its branch around the
    line out: the deepest notch's mouth plus 1 cm, 0.38 to 0.56 m up the level's oak's
    trunk. That level's wood is the tree's own, rebuilt once for each new line.
  - Each line's band is a small mesh on an instance of its own, rebuilt with its notch each
    time: the trunk's in 0.88 ms on the desktop. Only the line struck is rebuilt. One mesh
    for every line took 2.8 ms with two limbs' bands in it, and a pine has 40 limbs.
  - The band and the full level share the ring list, frames and bark layout, so they meet
    exactly. The band's columns between the trunk's corners lie on its flat sides.
  - The band is drawn and dissolved with the full level. The medium and far levels are too
    far to show notches and keep the variant's meshes.
- **Collision is unchanged:** strikes still land on the wood's capsules.

### Limbs, small branches and leaves (rung 4, built 2026-10-02)

Asked by the player after the notches:
- Leaves "need to destroy when any force is applied meaning the player swings his axe through
  the leaves. If the player walks through the leaves then it shouldn't destroy". A falling
  tree's leaves still break on its surroundings.
- More segmentations, "choppable regardless of weather or not the tree is felled". A branch
  ring is "1 side accounting for the entire radius of that branch ring", with "maybe 30 hp".

Decided together:
- Rings on the main limbs only. "The others break with the leaves they are attached to. If
  no leaves are attached, then they should break the same way the leaves do."
- A limb cut through falls off as its own piece, and its ring shows as a notch, like the
  trunk's.
- The force of a fall breaking branches comes next.

**Since step 1b** every branch is chopped at its segment lines as the trunk is (see
Chopping), and only twigs break. What rung 4 built, and what became of it:

**Where a blow lands.** It lands on the branch whose bark is nearest its point
(`TreeSkeleton.nearest`), skipping what is gone. Wood with lines is chopped at them; a twig
breaks.

**Limb rings (rung 4, replaced by lines in step 1b).** Each limb had one ring of one side,
`limb_ring_offset_m` (0.1 m) beyond where its bark cleared the trunk's all round, taking
`limb_health` (30, three full-strength blows) from slashes within `limb_band_m` (0.25 m).
- At first the ring was 0.15 m beyond where the limb's middle left the trunk's bark. The
  limb's underside was still inside the trunk there, so a limb cut off jumped 2 cm as the
  two pushed apart. That is why a branch's lines start past where its bark clears its
  parent's.
- A limb's line now takes what its cross-section gives (27, 18, 11 and 10 along the level's
  oak's thick limb), its notch deepening evenly all round, with no band drawn until the first
  cut.
- At its total the limb is cut off (`ProceduralTree.sever`) and falls as a `FelledTree` of
  its own. The tree keeps a capped stub, with no line.

**Twigs** (until step 1b, small branches: every branch two below the trunk or deeper). Any
blow on one at `ProceduralTree.BREAK_SPEED` (2 m/s) or faster breaks it off whole, with
everything growing from it and their leaves.
- It is simply gone. Its wood, collision and touch volumes are switched off, and the tree is
  drawn again without it at the end of the frame.
- It doesn't fall as a piece.
- A small branch thick enough to have a line is chopped now (one on the level's oak), and a
  limb too thin for one is a twig.

**Leaves.** Each cluster's touch volume watches hands, held items, props and enemies. It
never watches the player's body: walking through leaves is not attacking them.
- **Speed:** something moving through a cluster at `BREAK_SPEED` or faster, against the tree
  there, breaks it. Slower, it passes through.
- **What breaks:** a cluster on a twig breaks the twig, with its other clusters. A cluster on
  wood with lines goes alone.
- **Felled pieces:** their clusters also break against their surroundings (the floor,
  stumps, standing trees and props) at any speed, as they fall or lie. Held items and hands
  still need the speed.
- **Bare twigs** break the same way. A twig with no leaves of its own has touch volumes
  along its wood that is too thin for collision (`TreeCollider.twigs`, at least 3 cm round).
  The birch grows them: its first-level branches carry no leaves (theirs grow on the
  branches beyond), and its thin ones are twigs.

**How it is built:**
- **Own trees:** a choppable tree is its own from the start: `TreeChop` makes it so when it
  is ready (`ProceduralTree.make_own`). In step 1b's first build only drawing its first
  line's notch did, so a tree whose first line couldn't be chopped judged twigs broken that
  never broke.
  - Its wood and leaves are drawn apart, each rebuilt only when something changes, at most
    once a frame.
  - Its foliage area watches what touches it.
  - Other trees are unchanged, with shared meshes and a foliage area that watches nothing.
- **Pieces:** a `FelledTree` is a `RigidBody3D` whose wood is a `ProceduralTree` piece. It
  has a `Strikeable` of the tree's material, a `TreeChop` with the lines it carries, and a
  readout.
- **Cutting** is one call for every line, `sever(branch, distance, toward)`, which `TreeChop`
  makes itself; `toward` tips a felled top over. What was broken off stays gone in both
  pieces (`TreeSkeleton.pruned`).

**Rolling.** Jolt has no rolling resistance, so a bare limb rolled 2 m along the floor after
landing.
- **The fix:** felled pieces now damp their spin, `FelledTree.ROLLING_DAMP` (1.0 a second,
  plus the world's 0.1).
- **What remains:** a limb still rocks on its crook, within about 7 cm, for a few seconds
  before it sleeps. Damping spin slows rolling only by about a third, since most of a
  rolling log's motion is its travel.
- **The cost:** the felled top tips a little slower: on the oak grown before segments, it
  passed 60° at 2.2 s instead of 1.9 s. At 2.0 the limb stopped sooner, but the top tipped
  a third slower.

**Measured in the harness** (simulated, desktop; step 1b, the level's oak grown in segments):

| Scenario | What happens |
|---|---|
| `chop_axe_tree` | The axe pushed bit first at 4 m/s into trunk line 1 slashes with 13.5 J, for 2 damage. It opens one side by 2 and the sides either side by 1 ("4 / 300"). |
| `chop_axe_fell` | The same blow on line 1, 299 open, fells the tree in the tick it lands. Its top splits off to fall, and the stump stays, solid. |
| `chop_box_tree` | A 2 kg box at 4 m/s strikes line 1 blunt (17 J) and opens nothing. |
| `chop_axe_high` | The same push as `chop_axe_tree` at trunk line 4, 1.8 m up where the level has it (the tree lowered so the hand reaches it): a slash for 2 that opens line 4 ("4 / 245"), which the readout now shows. |
| `chop_axe_toe` | The axe swung level into line 1, its head rolled 20° so the corner of its toe meets the bark first: a slash for 2, dealt by the bit's toe ("4 / 300"). Before the bit ran the head's whole face, a corner fell outside its reach and struck blunt. |
| `chop_tree_falls` | The tree where the level has it, felled at line 1 with two sides uncut. The top tips over the stump's edge slowly, hinged to it (8° at 0.5 s, 14° at 1 s, 21° at 1.5 s, 37° at 2 s, 60° at 2.4 s), its centre of mass going exactly the way it was felled until the hinge breaks. Once its crown is down, it rolls on over a limb and lies propped at 76°, at rest 3.6 s after the cut and asleep at 4.1 s: its centre of mass ends 2.2 m along, 27° off the way it was felled. 22 of its 28 leaf clusters are gone. (Grown before segments, it fell within 1° and lay flat, but that tree didn't lean.) |
| `chop_axe_drop_on_log` | The same fall, then the axe dropped from 1.2 m onto the top lying at rest. The axe bounces off onto the floor, and the top moves 0.1 mm and sleeps again. |
| `chop_high_cut` | The tree felled at trunk line 5, 2.35 m up the tree, two sides uncut. The top tips off the five-segment stump faster than from line 1 (11° at 0.5 s, 26° at 1 s, 66° at 1.5 s), at up to 4.7 m/s, and lies at rest 4.9 s after the cut, all its leaf clusters gone. It goes the way it was felled until it has tipped 50°; lying across the stump, it then slides off sideways, its centre of mass ending 2.2 m away and 92° off. The stump stays. |
| `chop_buck_log` | The fall of `chop_tree_falls`, then at 6 s, the top lying at rest, its trunk line 4 cut through: two pieces in that tick, the line gone from both (the top keeps lines 2 and 3, the log 5 to 8). No pop: over the first 4 ticks neither went 0.22 m/s, and the cut faces stayed within 5 mm along the trunk. Each settles about 6 cm onto what holds it up now, and both lie at rest 0.2 s after the cut. |
| `chop_branch_line` | The oak's thickest limb cut through at its line 2 (0.94 m along it, 27), the first it can be chopped at. It comes off in that tick as its own piece and falls to rest on the floor; the tree keeps a capped stub with no line, its other lines, and still stands. (It replaced `chop_limb_falls`, which cut the limb ring.) |
| `leaves_box_slow` | A 2 kg box, gravity off, sent at 1 m/s through the middle of a leaf cluster on a limb: all 28 clusters stay. |
| `leaves_box_fast` | The same at 4 m/s: that cluster breaks, alone (27 left, no branch broken). |
| `chop_root_loot` | The tree felled at line 1 as in `chop_tree_falls`; once the top lies at rest, the stump, lone from the fell's tick with 50 health, is slashed to 0 at full strength: five slashes, each judged `LONE`, the readout showing each value. The stump doesn't move. At 0 the tree is gone, and three logs are laid on their sides on a 0.221 m ring round its middle; they fall and lie at rest on the floor within 0.5 s, not thrown (1.75 m/s at most, against 2.13 falling freely from where they were laid). The top, propped on the stump, is woken in the tick the stump goes and settles 3.4 cm onto the floor, at rest 0.13 s later (it hung in the air before the wake was added). |
| `chop_log_loot` | The top bucked at its line 2, as in `chop_buck_log`: the log between lines 1 and 2, lone with 50 health while the rest of the top isn't, slashed to 0. It goes, and three logs drop round its middle. It lies beside the stump, so two of them are raised a spacing (0.383 m) clear of the stump and the rest of the top; they fall up to 0.8 m without being thrown and rest within 1.6 s and 0.3 m of where they were laid, one sometimes leaning on the stump. The rest of the top moves 0.2 mm. |
| `chop_stick_loot` | Limb 1 cut at its last line (5) on the standing tree: its tip falls 3.8 m to the floor, lone with 10 health. One slash breaks it, and one stick is laid on its side at its middle, 1 cm above the floor, and lies still. The tree stands. |
| `loot_log_roll` | A log as its scene makes it (8 kg, angular damp 1), laid on its side on the open floor and set rolling across its length at 1.5 m/s: it never goes faster, and rests 0.46 m on, 1 s after. |
| `loot_stick_roll` | The same for a stick (2.5 kg, angular damp 6): it rests 0.69 m on, 2 s after. |

Every scenario that cuts the tree also weighs each piece when it appears and whenever it is
cut (75 kg a trunk segment, 25 kg a branch segment, twigs left out), checks that a cut
splits the weight exactly, and that each piece keeps its weight as twigs break off it. The
level's oak: the top 900 kg (600 kg cut at line 5), limb 1 150 kg, a bucked one-segment log
75 kg; the loot logs 8 kg and the stick 2.5 kg. Falls, rests and drops are as before the
weights, within a few hundredths of a second.

Since fall damage, every scenario that fells or cuts also follows every piece broken off
on landing:
- **Breaks:** how many, the first breaks where they always repeat, no trunk line broken,
  every break hit at `impact_speed` or more and marked by one impact, and at most one
  fall-damage cut a tick.
- **No piece thrown:** none faster than its parent at its centre plus free fall from its
  height, plus 10%.
- **Rest:** every piece at rest by the scenario's time. A piece broken off by an impact may
  still creep under 0.1 m/s, touching something and sunk no more than 2 cm.
- **Contacts:** peak contacts under the cap (`FelledTree.MAX_CONTACTS`, 64).
- **Longer limits:** the felling scenarios run up to 13-18 s, as broken segments roll and
  rock for up to 7 s.
- **Bucking:** a log bucked off a top that lies on its stubs now drops, so the buck's no-pop
  check leaves out free fall.

| Scenario | What happens |
|---|---|
| `chop_limb_set_down` | Limb 1 cut off and laid level 2 cm above the open floor: its hardest contact closes at 0.75 m/s, it rests in 0.35 s, and nothing breaks. |

The full harness run against the main checkout's gave the same results for every other
scenario, failures included, word for word.

A wide trunk meets more than the blade. With the post scenarios' longer push, the hand
holding the axe touched the bark beside the bit 14 ms after it (blunt, opening nothing). The
axe scenarios therefore meet the trunk 30° round, where it curves away from the hand.

**Checks:**

```
godot --headless --xr-mode off --path . -s tests/trees/test_tree_chop.gd
godot --headless --xr-mode off --fixed-fps 72 --path . -s tests/harness/run_scenarios.gd -- chop_axe_tree chop_axe_fell chop_box_tree chop_axe_high chop_axe_toe chop_tree_falls chop_axe_drop_on_log chop_high_cut chop_buck_log chop_branch_line leaves_box_slow leaves_box_fast chop_root_loot chop_log_loot chop_stick_loot loot_log_roll loot_stick_roll chop_limb_set_down
```

The test (152 checks) covers:
- the tree struck through its wood body, also after the body is rebuilt;
- a sapling too thin to chop anywhere: its own all the same, with no line being chopped
  and the readout hidden;
- sides: each side's middle on its side at line 1 and on a high line of a leaning oak,
  numbered from the node frame the notch is drawn in;
- slashes opening their side up to its cap and spilling onto the sides either side; a full
  side taking no more, spreading none, and becoming the line the readout shows; blunt and
  too-weak strikes opening nothing;
- which line a slash counts on: the line being chopped keeping slashes within `band_m`, up
  to three quarters of a segment off; otherwise the nearest that can be chopped, passing
  over one inside a junction;
- what a line takes: 300 at line 1, by its cross-section higher up and on limbs, at least
  10; six full sides cutting through every trunk line of the oak and the pine that can be
  chopped (caps rounded up);
- which lines are wood: one thick enough at the line but not half a segment on isn't, and
  its branch is then a twig;
- the skeleton split at a line: nodes, branches and leaves on the right piece; the segment
  length, first line radius and frames kept; bark rings and texture identical at every
  trunk line and a limb line; cut faces of inner wood, and collision ending flat at the cut;
- the notch: line 1's band drawn from the start, the full level open over it and meeting it
  exactly, a half-open side's depth, fade and mouth, a second line's band, and cutting
  through ending the notch;
- the fall direction: away from the uncut wood, or from the last slash's side when even;
- felling at line 1: once, at 300, level and away from the uncut wood; the stump with no
  line left; the top a `FelledTree` on the Static layer, meeting everything, colliding
  continuously and hinged to the stump as it tips; its lines kept as they were; a leaf on
  wood going alone and one on a twig taking the twig;
- a high cut at line 4: the stump keeps lines 1 to 3, which still chop, and the top tips
  over hinged;
- branch lines: one side, by cross-section, the first past where the limb's bark clears the
  trunk's; cut through, the limb falls as its own piece, not tipped, and the tree keeps a
  capped stub;
- bucking: the felled top cut at a line into two `FelledTree`s, neither tipped, both
  chopping on with the tree's settings and the lines on their side of the cut;
- blocked lines: a line a junction crosses opening nothing, a slash beside it counting on
  the next line, still blocked by a cut limb's stub, chopped once the limb is gone;
- twigs: holding at 1.5 m/s and breaking off whole at 3 m/s with their wood, collision and
  leaves, drawn again as wood only; a branch with a line not breaking; the pine's thin
  limbs breaking as twigs, slashed or with a prop swung through their leaves;
- leaves on a standing tree: watching hands, held items, props and enemies only; nothing
  broken by walking through or at 1.5 m/s; at 3 m/s a cluster on wood going alone and one
  on a twig taking the twig; bare twigs, made on the oak and grown on the birch, breaking
  as leaves do;
- fall damage:
  - `impact` marks a branch's nearest line, once, from 2.00 m/s up (1.99 marks nothing),
    at any distance from the hit, and never the trunk, a twig, a gone branch, a lone piece
    or a standing tree;
  - `break_next` cuts as a slash would, one cut a tick across pieces, a marked line going
    with its piece;
  - `impact_speed` reaches pieces;
  - `branch_of_shape` names each of a top's 16 shapes' branch, and `nearest_on` agrees
    with `nearest`;
  - a spinning top cut in two keeps the same velocity at the cut on both pieces (1.48 m/s
    off before);
  - drops onto a floor: a limb from 0.08 m (1.1 m/s) breaks nothing, a 2 kg crate at 4 m/s
    breaks nothing, and from 0.5 m (3 m/s) it breaks at three lines, with no engine
    errors;
- verdicts: off the bark, off every line, and `locate`;
- the readout: line 1 at ready, the sides and total after a slash, following a branch
  line, hiding once a line is cut through;
- lone pieces: a standing tree not lone, the stump lone in the fell's tick and the top not,
  a one-segment log bucked off the top lone, a piece whose only line is blocked lone with
  loot for both its segments, a stub with a line to chop keeping its piece from being lone
  until that line is cut; health of 50 for trunk wood and 10 for a branch, taken only by
  slashes (judged `LONE` wherever they land, a fast one on a twig breaking it too; a blunt
  blow breaking a twig and taking nothing), with the tree's settings reaching every piece; a
  tree with nothing to chop staying whole until its trunk is cut; the readout showing the
  health above the bark at the middle, depth-tested, following a falling piece; and at 0 the
  piece or tree freed, with 3 logs or a stick a segment laid on their sides round its
  middle, none raised by the piece's own bodies, and a box asleep on the stump woken to
  fall when the stump goes;
- weights: the species' 75 and 25 kg a segment (the density gone), the segments each piece
  of a cut holds, each piece's mass by the rule and the engine's alike (the top 900 kg, a
  limb 150 kg, its tip 25 kg, a log 75 kg), a cut splitting the weight exactly, a twig
  breaking off leaving it, a piece of twig-thin wood weighing 1 kg; and the loot's 8 and
  2.5 kg and angular damps (1 and 6), none overridden in the level. The generation test
  checks `TreeSkeleton.wood_segments` against the radii at the segment lines;
- the level's wiring.

**In the headset (2026-10-02, user reports):**
- "That worked." One chop filled a side, which they didn't want, so `side_cap` went from 10
  to 50 and `fell_at` from 60 to 300.
- With the fading notch and spill: "That looks and feels WAY better." The ring was "way too
  precise", so `band_m` went from 0.15 to 0.3 m. No recording covered it, so where the
  missed blows landed wasn't measured.
- "The leaves stay rendered until the main branch breaks": the leaf redraw bug above, fixed
  2026-10-02. The oak's trunk also carries 7 clusters of its own (5 at its top), which go
  only one at a time.
- After step 1a (trees in segments): "Chopping needs to again be more forgiving. Some of my
  hits I feel don't register and I think its because they don't land in the hit zone." What
  was found and fixed is under "Why hits didn't register"; `band_m` went to 0.35 m, and the
  recorder now logs each strike's point and verdict. "The tree changed when I hit play vs
  seeing it in the editor": the editor had kept a tree from before its scripts reloaded, and
  restarting the editor fixed it. "Other than that, it was awesome."
- After step 1b (every line chops): "chopping looks good".
- After step 1c: "Wow that feels great. The only thing that feels off is the weight of it
  all": weights by segment followed, with the loot's mass and damp (see Felling, Lone
  pieces).
- After the weights: "That feels way better."
- After fall damage (recorded session, 153 s):
  - The user: "Looked great when it fell! The branches broke like they should. No hitches
    when pieces broke." But "the individual stick and log segments also roll way too easily
    when walking over them or pushing them", so lone pieces now damp their spin (see Lone
    pieces).
  - Telemetry: felling at line 1 took 30 strikes in 12.3 s. Bucking the felled top at line
    8 took 48 strikes in 29.9 s: 13 landed on sides already full, the top of the lying log,
    and 9 read blunt. It cut through once the lower sides were reached. Each lone piece broke
    in about 6 slashes.
  - Inference: limb segments the player never chopped were broken into sticks, broken off
    when the top landed.
- Still to judge: whether lone pieces now stay put underfoot, and whether bucking a lying log
  (its sides on the ground out of reach) is slower than it should be.

## Build order

1. **Trunk only: built.** Skeleton, bark tube with continuous UVs, tip cone and inner-wood
   base cap, with the three example species in `scenes/tree_lab.tscn`.
2. **Recursive branches: built.** The example species are:
   - a pine with drooping whorls in a cone;
   - an oak with three angular levels;
   - a birch with curvy branches and drooping twigs.
3. **Leaves: built.**
   - each example species has its own leaf card texture and bark (see "Example species'
     looks");
   - clumps remain available as a style.
4. **Collision: built.** Wood capsules on the Static layer, twigs pass through, and leaves are
   touch-only volumes on the Foliage layer (see Collision).
5. Optimization, one rung at a time:
   - **Collision streaming: built.** `TreeCollisionStreamer` (see Collision).
   - **Detail levels: built.** Three levels with a dithered crossfade (see Detail levels).
   - **Sharing, variety and forests: built.** See Sharing and forests.
   - **Impostors: built.** See Impostors.
   - **Next:** Quest 3S measurements in `forest_test.tscn`.
6. **Chopping:** rungs 1 to 4 (the chop ring, the fall, the notches, limbs and leaves)
   built 2026-10-02, then step 1a (trees grown in segments), step 1b (every line chops,
   standing or felled, bucking included) and step 1c (lone segments breaking into logs
   and sticks). The force of a falling part breaking branches is next (see Chopping).

## Checks

```
godot --headless --xr-mode off --path . -s tests/trees/test_tree_generation.gd
```

The test covers determinism, straight, kink and bend limits, droop, node spacing, girth
falloff, mesh size, bark UVs, the cap marking, face winding, branching and leaves. For
branching it checks:
- where branches start;
- that no branch is thicker than its parent;
- the spread angle;
- the count;
- the branch limit;
- that each branch's nodes are stored together.

For collision it checks:
- that capsules cover every solid node of the three species within the tolerances;
- that a straight, even trunk is one capsule, and a looser tolerance never gives more;
- that twigs get no capsules;
- that every card corner lies inside its touch box, and clump spheres are centred;
- the tree node's layers, masks and shape counts;
- streaming: which trees have collision on load, while walking (at most one build per tick,
  and the gap between the radii holds), after a jump, and with no target.

For detail levels it checks:
- that each level is cheaper and keeps one cluster in its leaf step;
- that thin branches are left out, with no empty surface built;
- that kept clusters are enlarged to keep the leaf area;
- that the three levels share bounds and sit at the species' distances;
- that at every distance each pixel is drawn by exactly one level. The test mirrors the
  shader's dither rule over the whole range, with no gaps or double draws.
- that the preview works.

For leaves it checks:
- placement for leaf minimum depth 1 and 2, and angle;
- trees with no leaves, which must build without engine errors;
- that leaves don't change the branches;
- that placement is the same across styles;
- the recorded crown box;
- crown normals with exact values;
- that leaf normals stay within their rounding of the crown normal, including on the tall
  pine crown;
- card stem, UVs and aspect;
- the clump centre offset and UV area;
- clump winding;
- counts per style;
- the leaf limit.

The run fails if fewer than `EXPECTED_CHECKS` checks ran, so a test that stops on a script
error can't pass. It also prints generation time on the machine running it.

Step 1, measured on the desktop (not Quest 3S):

| Species | Time per trunk | Triangles |
|---|---|---|
| Straight pine | 89 µs | 240 |
| Angular oak | 68 µs | 160 |
| Curvy birch | 264 µs | 854 |

Step 2, whole branched trees without leaves, on the same desktop. Times are averaged over seeds 0 to 99; counts are for seed 99:

| Species | Time per tree | Branches | Triangles |
|---|---|---|---|
| Straight pine | 2.2 ms | 105 | 3,928 |
| Angular oak | 1.1 ms | 45 | 2,154 |
| Curvy birch | 2.1 ms | 47 | 5,125 |

Step 3, the whole tree with leaves (tip sprays and trunk sprouts included), on the same
desktop. Times are averaged over seeds 0 to 99; counts are for seed 99:

| Species | Time per tree | Branches | Wood triangles | Clusters | Leaf triangles |
|---|---|---|---|---|---|
| Straight pine (cards) | 4.0 ms | 105 | 3,928 | 231 | 924 |
| Angular oak (cards) | 2.2 ms | 45 | 2,154 | 140 | 560 |
| Curvy birch (cards) | 3.4 ms | 47 | 5,125 | 155 | 620 |

No headset or Quest measurements have been taken yet.

## Risks to measure in step 5

- **Shadows in a forest:** on the desktop they are about 60% of the forest's triangles,
  because every tree within the 60 m shadow range is drawn again into the cascades at full
  or medium detail. Levers, all visual trade-offs to decide on the headset:
  - fewer or shorter cascades;
  - no shadows from the medium and far levels, so shadows fade out with the full level;
  - no shadows from leaf cards.
- **Draw calls:** within the impostor distance each visible tree is its own draw calls,
  about 370 objects from the forest's spawn. Lowering `impostor_distance_m` trades them for
  cards.
- **Impostor memory:** runtime-baked pictures stay uncompressed. That's about 0.6 MB per
  variant at 256 px (colour and normals with mipmaps), 15 MB for the 24 in the test forest.
- **Impostors in stereo:** the cards are flat. Past 100 m that shouldn't show, but check it
  in the headset, along with the handoff.
- **Resources reloaded at runtime:** in the full project, something reloads the species
  resources from disk after a scene enters the tree, dropping edits made to them at
  runtime. Harmless now, but worth finding before any code changes species while the game
  runs.

- **`discard` on the bark shader:** the crossfade needs it on the wood, and it's there all
  the time, not only while fading. On tile-based mobile GPUs, shaders that discard can lose
  early hidden-surface rejection. The leaves already discard, so they cost nothing extra.
  - **Mitigation if it shows:** swap to a dithering variant of the wood material only
    inside fade bands.
- **Stereo dither:** the 4×4 pattern is fixed on screen in each eye, so a tree inside a fade
  band may shimmer slightly in the headset. The bands are 4 m wide.
- **Generation time:** three levels make each tree slower to build. Many trees at load may
  need spreading over frames, or sharing meshes between trees with the same species and
  seed.

- **Collision with many trees:** streaming keeps far trees free of physics objects. The
  cost of building a tree's collision on Quest (0.5 to 0.8 ms on the desktop) is not
  measured. If one build per tick shows as a hitch, spread each tree's build over more
  ticks.

These came from the step 3 review. They are measured on the desktop or inferred, and none
has been measured on a Quest.
- **Leaf shadows:**
  - Cards cast alpha-tested shadows through the tree's single mesh instance.
  - The directional light's defaults are four cascades out to 100 m.
  - About 3.3 to 3.6 card layers cover each shadow texel.
  - Leaf shadows can't yet be turned off separately from the wood. One option is a
    separate leaf mesh instance with its own shadow setting.
- **Card overdraw:**
  - Only part of each leaf texture passes the alpha scissor: 28% of `oak_leaf.png`, 30%
    of `birch_leaf.png` and 41% of `pine_leaf.png`.
  - The crowns measured about 3 to 4 card layers per pixel on the CPU.
  - A convex outline fitted to the texture (about 56% of the quad) would halve the discarded
    fragments. It would have to be set per leaf texture.
- **Texture import:** the leaf and bark textures are imported desktop-only (S3TC/BPTC). A
  Quest export needs ETC2/ASTC.
- **Alpha-to-coverage:** it could smooth card edges once MSAA is chosen for the headset.
