# Fantasy VR RPG

A standalone-first fantasy VR RPG with survival elements, physical interaction,
and a persistent world shaped by its community.

The repository is currently named `vr-controller`. This README captures the game's
intended direction, based on the project design document dated March 31, 2026,
and subsequent technical decisions. The systems below describe the vision;
they are not a list of completed features.

## The vision

Players arrive as colonizers in a mysterious new land and build a life around a
shared, player-maintained village. Beyond that home lies a vast open world of
wildlife, monster camps, forgotten ruins, hidden temples, and dangerous caves.
Survival and community work support increasingly ambitious adventures, while
exploration, looting, crafting, and defeating stronger enemies drive progression.

The world should invite curiosity. Its early atmosphere is innocent, peaceful,
and welcoming; deeper exploration gradually reveals darker themes and the
history of an extinct civilization.

### Core pillars

- **Physical immersion:** inhabit a physical body and interact directly with
  tools, weapons, materials, inventory, and the environment.
- **A community-driven world:** maintain a shared home, specialize in useful
  skills, trade goods, and contribute to other players' adventures.
- **Adventure and exploration:** discover places, solve puzzles, uncover lore,
  and earn the equipment and knowledge needed to venture farther.

### Inspirations

The Legend of Zelda, Skyrim, BONEWORKS, A Township Tale, Valheim, and Terraria
inform the overall vision. Blade & Sorcery is an additional reference for
discussions of physical VR interaction and combat. These are references for
experience and feel, rather than specifications to reproduce wholesale.

## The intended gameplay loop

1. Prepare in the hub village: craft equipment, cook food, brew potions, trade,
   and plan an expedition.
2. Explore the world, gather resources, discover points of interest, and uncover
   quests and fragments of its history.
3. Overcome environmental challenges, puzzles, and enemies to recover loot,
   recipes, magical items, and rarer materials.
4. Return to the community, improve equipment and shared facilities, and prepare
   to face more demanding regions and encounters.

## World and storytelling

### The hub village

A centralized, player-maintained village or city serves as the community's
headquarters. It contains workbenches, shops, and customizable spaces. Players
can specialize in blacksmithing, farming, hunting, and other skills that support
the town.

### A persistent environment

The world includes a dynamic day/night cycle, sun, rain, thunderstorms, and
wildlife. Its environments and creatures should convey a sense of mystery and
encourage players to explore beyond familiar ground.

### Environmental narrative

Storytelling is primarily passive: visual details and discoverable lore fragments
reveal an extinct civilization divided into two factions, one pursuing peace
and the other power. As progression introduces darker places and themes,
unnatural enemies help reveal the history of the evil faction.

### Points of interest

| Location | Intended experience |
| --- | --- |
| Camps | Small or medium monster-infested locations containing loot. |
| Ruins | Small or medium abandoned places with puzzles and enemies. |
| Villages | NPC settlements offering quests and direction for adventures. |
| Temples | Large, hidden structures with difficult puzzles, magical items, and stronger enemies; players must purify them of evil. |
| Dungeons | Large, hidden structures containing concealed items and challenges. |
| Caves | Dark, dangerous areas where players harvest high-tier ores. |

## The player and physical interaction

- **Physical body:** the player has a full physical body that interacts with the
  world.
- **Vitals:** health, stamina, and hunger shape survival. Running and climbing
  consume stamina; hunger recovery directly affects health and stamina.
- **Character creation:** a GUI supports detailed customization of face, body,
  and race.
- **Combat:** weapon weight affects swing speed and strength. Heavy armor offers
  power at the cost of mobility.
- **Symbolic magic:** draw symbols in the air to activate spells. Magic serves
  combat and practical needs, such as using fire to illuminate a cave.
- **Morality:** frequent unforgiven player-killing provokes random attacks from
  powerful unnatural enemies. Good spirits may guide good players toward loot.

### Diary and map

A physical notebook tracks quests, progression, and recipes. It is strapped to
the player at a dedicated location that cannot be changed.

The diary provides access to a map held with both hands. The intended control
scheme uses one thumbstick for movement and the other to pan the map. The map
shows discovered points of interest and other players' locations.

### Physical inventory

Inventory uses a physical bag or belt with visible items, rather than stereotypical
floating slots. Items move aside as players access other items. Progression
includes larger craftable bags, carts, and specialized small bags for stackable
goods.

## Crafting, survival, and community life

| System | Intended interaction |
| --- | --- |
| Woodworking and crafting | Follow physical recipes discovered during adventures. |
| Blacksmithing | Smelt ore, pour molds, hammer, and sharpen at community stations. |
| Agriculture | Till soil, plant crops, and fence in animals to supply food and ingredients for buff-giving potions. |
| Cooking | Cook stews in pots; stews provide the greatest hunger recovery and may grant buffs. |
| Potion brewing | Heat, swish, stir, hit, and mix ingredients through physical actions. |
| Pets | Tame creatures through a difficult process. Pets may be cosmetic or assist in combat, and can die. |
| Markets | Sell items at community shops with player-set asking prices. A player's shop remains active for a predetermined period. |
| Currency | Gold coins serve as the common currency and can be found throughout the world. |

## Enemies and progression

- **Natural enemies** are hostile creatures encountered in their native habitats.
  They provide the world's more familiar challenges.
- **Unnatural enemies** allow more unusual designs and are more aggressive and
  difficult to fight. They connect darker regions to the world's lore.
- **Enemy varieties** in both groups include grunts, brutes, giants, quick enemies,
  flying enemies, and other roles.
- **Bosses** test player ability and strength, rewarding victory with high-value
  loot.

Progression should connect stronger encounters with exploration, crafting,
equipment, and discovery, giving players reasons to return to the community
and then venture out again.

## Sound and atmosphere

- **Ambient audio:** ongoing wind, rustling, and wildlife give environments a
  sense of life.
- **Interaction sounds:** movement, grabbing, and objects respond audibly to
  player actions.
- **Spatial voice:** proximity-based VOIP changes volume with distance.
- **Music:** soft atmospheric tracks appear periodically, leaving room for the
  world itself to be heard. Skyrim, The Legend of Zelda: Ocarina of Time, and
  Minecraft are references for the intended emotional tone.

## Technical direction

| Area | Agreed baseline |
| --- | --- |
| Primary platform | Standalone VR |
| Minimum supported device | Meta Quest 3S |
| Engine | Godot 4.7 |
| Renderer | Mobile |
| XR interface | OpenXR |
| Physics engine | Jolt |
| Target display refresh | 72 Hz |
| Baseline physics rate | 72 ticks per second |

Consistent frame times and reliable physical interactions are core requirements.
The 72 Hz target provides approximately 13.89 ms per display frame; actual
application budgets must leave headroom and be measured on Quest 3S.

XR startup requests 72 Hz when available and matches physics to the runtime's
reported active refresh rate. If that rate is unknown, physics falls back to
72 ticks per second. Higher refresh-rate modes require separate validation.

The persistent world, physical inventory, enemies, weather, and community systems
must be designed within standalone CPU, GPU, and memory limits. Physics optimization
is especially important: active bodies, contacts, joints, and queries need measured
budgets. Performance must be checked during sustained headset use, not inferred
from desktop frame rates.

Code should favor cohesive modules, composition where useful, explicit ownership,
and separation of tracking, simulation, game rules, and presentation. See
[controller design and implementation handoff](documents/player_controller/2%20-%20prototype_handoff.md)
for repository development guidance. Additional local assistant guidance lives in
`CLAUDE.md`, which is currently ignored by Git.

## Current stage and next decisions

The project is an early VR foundation, with code for XR startup, player-body
movement, a skeleton, and a stereo mirror. The broader RPG described here remains
the intended destination. Its persistence, multiplayer, progression, and content
systems are not established by this document as implemented features.

The existing main scene, `scenes/level.tscn`, is the test arena, containing floors,
a wall, ramps, steps, and a stereo mirror. The current character-body controller
already supports room-scale correction, slope-aware walking, step assistance, and
arm-pump running; the shared force-based body and physical hands remain planned.

Near-term development should extend this arena to validate the physical interaction
foundation and 72 Hz performance on Quest 3S. See the
[physical prototype handoff](documents/player_controller/2%20-%20prototype_handoff.md)
for the reviewed implementation, migration requirements, and validation scope. Numerical
performance budgets and supported scene complexity still need on-device evidence.

Before expanding toward the full world, define a small playable slice of the
core loop and resolve major scope questions: player count, multiplayer authority,
world persistence and saving, world loading, and the rules governing shared spaces
and player conflict. These are open design decisions, not commitments to a
particular implementation.
