# Research Project 1 Proposal: *Composite Units*

**Direction:** Connect things — a Maya → Godot asset pipeline and the game it feeds.
**Software:** Autodesk Maya (Python, modeling + export tool) · Godot 4.7.2 (GDScript, the game)

## 1. The project in one sentence
A Maya Python tool that builds and exports modular body parts (head, torso, arms, legs) with sockets and stats, feeding a small Godot 4.6 game where a glowing sphere explores a map, opens crates, and fights NPCs to win or lose parts.

## 2. Why this one
Today I can write Maya tools that change a scene. Afterward I'll be able to build a **pipeline between two programs**: a Maya tool that enforces a naming/socket convention and exports assets with data, and a game engine that reads them. I'll also learn the basics of a real engine (scenes, nodes, signals, GDScript) and a modular part system like real character-customization games.

## 3. What I'll show
- **The Maya tool:** a window that names socket locators, checks pivots, writes stats/style to JSON, and exports the whole part library with one button.
- **The game:** a playable Godot build, demoed live, plus a short recording of a full run.

## 4. The three weeks
- **By Nov 10 — the pipeline works once.** Godot project + repo set up. Sphere moves on a grey map (on-screen buttons + WASD). Crates and NPCs spawn. **One placeholder part exported from Maya lands in Godot and snaps onto the sphere.**
- **By Nov 17 — the core loop.** Maya tool finished (naming, pivot check, JSON, export-all). Crates give a random part that snaps on; stats add up; inventory shows in the controller.
- **By Nov 23 — battles and polish.** Turn-based battles (seeded random) with a lunge and flash; winner takes a part; boss NPC; win/lose; New Game. Model 2–3 styles to replace placeholders.

## 5. The smallest version that still counts
The Maya export tool plus a Godot game where the sphere moves, opens crates, and snaps on random parts exported from Maya, using placeholder shapes. Cut order if time runs short: automated tests → boss → battle animation → third style → battles.

## 6. The riskiest part
The Maya → Godot hand-off: socket names, scale (cm vs m), pivots, and orientation surviving FBX export so parts attach correctly. That's why it is the first thing proven, by Nov 10.

---

## Technical plan

**The contract (same on both sides)**
- Part types: `head`, `torso`, `arm_L`, `arm_R`, `leg_L`, `leg_R`
- Maya locator / Godot Marker3D names: `socket_<type>` (e.g. `socket_arm_L`)
- Each part exports as `<style>_<type>.fbx` + `<style>_<type>.json`
- JSON example: `{"type": "arm_L", "style": "robot", "attack": 3, "defense": 0, "health": 0, "speed": 0}`

**Maya tool (Python + Qt window)**
1. Pick part type and style from dropdowns; set stats.
2. Create/rename the socket locator by the convention.
3. Check the pivot sits on the socket; warn if not.
4. Export FBX (fixed unit/scale settings) and write the JSON beside it.
5. "Export All" exports the whole library to the Godot project's `parts/` folder.

**Godot game**
- Player: `CharacterBody3D` (glowing sphere) with `Marker3D` sockets.
- Crates and NPCs: `Area3D`; `body_entered` opens a crate or starts a fight.
- Attach = `add_child` on the marker + reset transform. Detach = reparent to the winner.
- Battle rules in one script with a seeded `RandomNumberGenerator`.
- Optional: GUT tests for battle math and part transfer, run with `godot --headless`.

**Git**
- `.gitignore` with `.godot/` before the first commit.
- Small commits after each working step; a commit at every milestone.

---

## Challenges I expect, and questions for you

These are the parts I'm least sure about. I'd really appreciate any advice or good approaches you can suggest.

1. **Maya → Godot hand-off.** I'm worried about scale (Maya in cm, Godot in m), locator names changing or the hierarchy being rearranged during FBX export, and pivots/axes making parts attach crooked.
   *Question:* Are there FBX export settings or Godot import settings you'd recommend so socket names and scale come through reliably?

2. **Learning Godot from zero.** Scenes, nodes, signals and GDScript are all new to me, and I want to understand the code well enough to explain it, not just use what the agent writes.
   *Question:* Is there a tutorial or small sample project you'd suggest to get up to speed quickly?

3. **The Nov 10 milestone.** It includes Godot setup, movement, spawning and the first part arriving from Maya, which is a lot for a few days.
   *Question:* If I can't finish everything, is it OK to prioritize the one-part pipeline test and move movement/spawning polish to the next week?

4. **Batch FBX export from Python.** I haven't scripted Maya's FBX exporter before (loading the plugin, setting options consistently).
   *Question:* Do you recommend setting FBX options through `mel.eval("FBXExport...")` commands, or loading a saved export preset?

5. **Battles.** The logic is simple, but the battle UI, balancing stats, and animating a part moving from one body to another may take longer than I expect.
   *Question:* Would a text-based battle result (no animation) be acceptable for the first version?

6. **Modeling the styles.** I'm a beginner in modeling, and 2–3 styles × 6 part types is up to 18 models.
   *Question:* Is it acceptable to keep the parts very simple and stylized, or to show fewer styles, since the focus is the pipeline?

7. **GUT headless tests.** Setting up automated tests in an engine I'm new to is extra work.
   *Question:* Is it fine to treat testing as optional and add it only if time allows?

---

## How to run (Nov 23 milestone)

**Requires:** Godot 4.7.2, Autodesk Maya 2025 (with the FBX plugin).

### Maya: build and export the part library
In the Script Editor's Python tab:
```python
import sys
sys.path.append(r"E:\composite-units\maya_tools")
import part_exporter
part_exporter.show()
```
1. **Build full placeholder library** makes 18 parts (robot / beast / slime x head, torso, arm_L, arm_R, leg_L, leg_R), each a group named `<style>_<type>` with a `socket_<type>` locator at its origin and stats stored as attributes.
2. Set **Parts folder** to this project's `parts/` folder.
3. **Check parts** lists any problem (wrong name, missing socket, pivot off the socket).
4. **Export All** writes `<style>_<type>.fbx` + `<style>_<type>.json` for every part that passes.
5. Your own model: select the mesh, pick style and type, **Make part from selected mesh**, set stats, **Apply stats**, export.

### Godot: play
Open `project.godot` in Godot 4.7.2 and press **F5**. A title screen explains the rules; press **Play** (or Enter).

**Controls:** WASD / arrows or the on-screen pad to move, **Space** jump, **E** open a chest / attack, **F** fire a weapon, **Esc** pause, **M** sound on/off.

**The rule: only a full body can fight.** You start as a glowing ball. You need a **head, two arms and two legs** (the torso is optional, it adds health) before you can attack anything with melee, a stomp or a weapon. The bar above your HP shows `BODY 3/5`, and the panel on the right ticks off each part. Trying to attack without a full body tells you what's missing.

- **Treasure chests** (gold "?" above them): press **E** next to one. The lid swings open and the part flies out and pops onto your body: arms with elbows and hands, legs with knees and feet, a head with eyes, in the robot, beast or slime style. Chests favour parts you're missing, and new chests appear when fewer than 3 are left. Once you have a full body, a chest may hold a **Laser gun** or **Flamethrower** instead (3 shots, **F** to fire, auto-aims at the nearest enemy in front of you).
- **Red NPCs** have bodies and limbs in five designs (Grunt, Brute, Slimeling, Scout, Mauler; `VARIANTS` in `scripts/npc.gd`). They wander, and when you come within 8 m they **chase you** (3.9 m/s, you run at 5) and swipe: raised arms and a glow mean a swipe is coming. Swipes are weak (1-2 damage) but they come in packs. With a full body, one hit knocks an NPC out: you take one of the parts it's wearing and it drops a **green health capsule** (+5 HP). If an NPC knocks you out, it takes one of your parts and wears it.
- **The purple BOSS** is one of three designs (IRON TITAN, ALPHA BEAST, SLIME KING; `VARIANTS` in `scripts/boss.gd`), wearing a full body in its style. Parts it grabs from chests or takes from you visibly swap onto its body. It is always moving: it grabs parts from chests (getting stronger) and chases you when you're within 8 m. When it swells and glows orange, it's about to strike; move or jump away. A health bar floats above it. Hit it with **E** or **jump on its head** for a stomp (+3 damage). Empty the bar to win.
- **If the boss knocks you out**, it rips off one of your parts at random and you respawn on the far side. You have to find that part again in a chest before you can fight. With no parts left, it's game over.
- Arms and legs are drawn 2x size on the player (`PART_SCALE` in `scripts/player.gd`); with legs on, the body stands on them.
- Everything you see and hear is built in code: sky, arena, chests, particle effects, the UI theme (`scripts/art.gd`) and the sound effects and music (`scripts/sfx.gd`).
- Tuning numbers: `scripts/main.gd` (heal amount, weapon chance and table, attack range, stomp bonus), `scripts/boss.gd` (boss speed, ranges, wind-up, HP), `scripts/npc.gd` (NPC speed).

### Maya: recognisable part shapes
**Build full placeholder library** now builds recognisable parts (arm with shoulder, elbow and hand; leg with knee and foot; head with eyes; chest plates for the torso) in each style, merged into one mesh named `<style>_<type>_limb`. Rebuild the library and **Export All** to send them to Godot. Parts exported with the old one-blob builder (a mesh named `<style>_<type>_geo`) are swapped for the same shapes in the game automatically; your own modelled parts are used exactly as exported.

**Project layout**
- `maya_tools/part_exporter.py` — the Maya Part Exporter window (build, check, export)
- `maya_tools/export_test_part.py` — the Nov 10 one-part pipeline test
- `scripts/part_library.gd` — reads `parts/*.fbx` + `*.json`, hands out random parts
- `scripts/player.gd` — the sphere, movement, jumping, HP, sockets, `equip()`, stats
- `scripts/npc.gd` — red NPCs: five designs, wander / chase / swipe
- `scripts/rig.gd` — creature body for NPCs and the boss: limbs on sockets plus a walk cycle
- `scripts/art.gd` — sky, arena, chests, particle effects, UI theme
- `scripts/sfx.gd` — sound effects and music generated in code
- `scripts/boss.gd` — the real-time boss: wander / crate-grabbing / chase / attack AI and its health bar
- `scripts/main.gd` — map, camera, crates, NPCs and boss, battles, controller, inventory and win/lose UI
- `parts/` — exported FBX + JSON parts
