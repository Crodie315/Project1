# Composite Units

**Research Project 1** · Direction: *Connect things*: a Maya → Godot asset pipeline and the game it feeds.
**Software:** Autodesk Maya 2025 (Python: part builder + exporter) · Godot 4.7.2 (GDScript: the game)

You start as a glowing ball with no body. You open treasure chests to collect body parts (a head, arms, legs, a torso) that were built and exported in Maya, and each part snaps onto you and changes your stats. Only a **complete body can fight**. Red NPCs chase you, and a purple BOSS hunts you and steals parts. Beat the BOSS to win.

---

## 1. How to run

**Requires:** Godot 4.7.2, and Autodesk Maya 2025 with the FBX plugin (Maya is only needed to rebuild or export parts; the exported parts are already in `parts/`).

### Play the game
1. Open `project.godot` in Godot 4.7.2.
2. Press **F5**. A title screen explains the rules; press **Play** (or Enter).

| Action | Keyboard | On screen |
|---|---|---|
| Move | WASD / arrow keys | direction pad (bottom left) |
| Jump | Space | Jump |
| Open a chest / attack | E | Open chest / Attack |
| Fire a ranged weapon | F | Fire (appears while holding one) |
| Pause | Esc | |
| Sound on / off | M | |

### Build and export parts in Maya
In the Script Editor's Python tab:
```python
import sys
sys.path.append(r"E:\composite-units\maya_tools")
import part_exporter
part_exporter.show()
```
1. **Build full placeholder library** builds all 18 parts (robot / beast / slime × head, torso, arm_L, arm_R, leg_L, leg_R). Each part is a group `<style>_<type>` holding one mesh `<style>_<type>_limb` and a `socket_<type>` locator at its origin, with its stats stored as attributes.
2. Set **Parts folder** to this project's `parts/` folder.
3. **Check parts** lists any problem: wrong name, missing socket, or pivot not on the socket.
4. **Export All** writes `<style>_<type>.fbx` + `<style>_<type>.json` for every part that passes.
5. For your own model: select the mesh, pick a style and type, click **Make part from selected mesh**, set the stats, click **Apply stats**, then export.

Godot picks up the new files on its next import.

---

## 2. Why the game has limbs

Body parts are the centre of this project, so in the final version they became the main thing the player sees and plays with.

**1. The body is the rule, so it has to be visible.** The core rule is *only a full body can fight*. Anyone watching a run should understand it without reading anything. A ball with no arms can't fight; a ball with a head, two arms and two legs can. Earlier versions attached flat blobs and bars, and from the game camera the player still looked like a bare ball even with five parts on, so the rule was invisible. Recognisable limbs fix that: an arm has a shoulder, elbow and hand; a leg has a knee and a foot; a head has eyes. The parts are drawn large (arms and legs 2.2×, the head 1.75×) and thick, so they read clearly from above.

**2. What you see is your inventory.** There is no hidden equipment screen to check. The body on screen *is* the state of the game: missing a left leg means you can see it's missing. When an enemy knocks you out and rips off a part, it disappears from you and appears on the enemy.

**3. Enemies are made of the same parts.** NPCs and the BOSS wear limbs from the same library the player collects. When you knock out an NPC you take one of the parts it is visibly wearing. When the BOSS grabs a part from a chest, you see it swap onto its body. So you can judge an enemy by looking at it, and every fight is about parts changing hands.

**4. Limbs make the movement read like a body.** With legs on, the ball stands up on them. Walking swings the legs from the hips, the arms swing opposite them, and the upper body bobs with each step. Jumping lifts the knees and throws the arms up. The animation is procedural: it turns the sockets (the joints), so it works on any part, including ones modelled by hand in Maya.

**5. It shows off the pipeline.** Every limb is a part from the Maya tool, following the same naming and socket contract (section 5). The Maya builder and the Godot fallback use the same shape table, so a part rebuilt and re-exported from Maya looks and attaches exactly the same in the game.

---

## 3. Game mechanics

### Goal
Collect a full body, survive the NPCs, and empty the BOSS's health bar.

### Body parts and stats
There are 6 part slots: **head, torso, left arm, right arm, left leg, right leg**, in 3 styles: **robot, beast, slime**. Each part adds stats: a base value by slot plus a bonus by style (the values come from each part's JSON file exported from Maya).

| Slot | Base stat | | Style | Bonus | Look |
|---|---|---|---|---|---|
| Head | Defense +2 | | Robot | Defense +1 | grey metal boxes, glowing antenna |
| Torso | Health +5 | | Beast | Attack +1 | chunky brown, ears and claws |
| Arm (each) | Attack +2 | | Slime | Health +2 | see-through green blobs |
| Leg (each) | Speed +2 | | | | |

- **HP** = 10 + Health. **Run speed** = 5 + 0.4 per Speed point.
- A new part replaces the one in that slot; the old one goes into your **bag** (shown in the panel).

### The full-body rule
- You can only attack (melee, stomp or weapon) while wearing a **head, both arms and both legs**. The torso is optional (extra HP).
- The banner above your HP bar shows `BODY 3/5 – can't fight yet` (red) or `READY TO FIGHT` (green). The panel on the right ticks off each part, and missing ones are marked in red.
- Pressing attack without a full body shows **NEED FULL BODY** and lists what's missing.

### Treasure chests
- A gold **?** floats over every unopened chest. Press **E** next to one: the lid swings open, the reward rises out and flies onto you, and it pops into place.
- **Chests favour what you're missing:** 75% of the time, a chest gives a part for one of your empty required slots.
- **Weapons** appear only once you have a full body (35% chance per chest).
- **New chests appear** whenever fewer than 3 unopened ones are left, so a lost part can always be found again.

### Combat
- **Melee (E):** damage = 2 + your Attack + a random 0–3 − half the target's Defense (at least 1). Cooldown 0.35 s.
- **Stomp:** jump (about 2.7 m high) and land on the BOSS's head: melee damage **+3**, and you bounce off.
- **Ranged weapons** (from chests, **3 shots**, then the weapon breaks and you're back to melee). Press **F**; shots auto-aim at the nearest enemy within 50° of where you're facing.
  - **Laser gun:** fast bolt, 18 m range, 8 damage.
  - **Flamethrower:** a 7 m fireball that grows and passes through enemies, 6 damage.
  - Against the BOSS, weapons also add half your Attack.
- After being hit you are invulnerable for 0.8 s (the HP bar blinks).

### Red NPCs
- There are five designs, each with its own body size and mix of parts: **Grunt, Brute, Slimeling, Scout, Mauler**.
- They wander the arena. When you come within **8 m**, they **chase you** at 3.9 m/s (you run at 5), and they give up beyond 12 m.
- **Swipe:** their arms rise and their body glows for 0.45 s (the warning), then they swipe for **1–2 damage**. Weak alone, dangerous in a group.
- **One hit knocks an NPC out** (with a full body). You take one of the parts it is wearing, and it drops a spinning **green health capsule** worth **+5 HP**. The capsule waits for you if your HP is full.

### The BOSS
- One of three designs, picked at random each game: **IRON TITAN** (robot), **ALPHA BEAST** (beast), **SLIME KING** (slime). It wears a full body in its style.
- **It never stands still.** It walks to the nearest unopened chest and takes the part, getting stronger and visibly swapping the part onto its body. It wanders when no chests are left, and **chases you within 8 m** (4.3 m/s).
- **Attack:** it raises its arms, swells and glows orange for **0.6 s**, then strikes everything within 2.6 m. Move or jump away and it misses.
- **HP** = 30 + 2 per Health point it carries, shown in a bar above it that goes from green to yellow to red. Its stats come from the parts it carries: it starts with 2 of the parts it's wearing, and gains every part it grabs.
- Empty the bar to **win**, and you take one of its parts.

### Being knocked out
- At 0 HP, **whoever knocked you out (BOSS or NPC) rips off one of your parts at random and wears it.**
- You respawn on the far side of the arena with full HP and 2 s of invulnerability.
- If that was a required part, you **can't fight until you find a new one** in a chest.
- If you had no parts left, it's **game over**. **New Game** starts a fresh map.

### Game feel
Everything is built in code, so the project has no texture, model or audio files besides the Maya parts:
- **Look:** sky, lighting, the tiled arena with glowing grid and walls, chests, particle bursts and the UI theme (`scripts/art.gd`).
- **Sound:** sound effects and background music (`scripts/sfx.gd`).
- **Feedback:** camera shake, a brief freeze on heavy hits, screen flashes (red when hurt, green when healed), and floating damage numbers.

---

## 4. What changed from the proposal

| Proposal | Final game | Why |
|---|---|---|
| Turn-based, automatic battles | Real-time fighting: melee, stomp, ranged weapons | The automatic fights ended in one click and felt like nothing happened. Real-time fights let the player dodge, run and choose. |
| Static boss | Boss always moving, chasing, grabbing chests, with a health bar | A boss that stood still and lost to one attack didn't feel like a boss. |
| Static NPCs | NPCs in 5 designs that wander, chase and swipe | To make the player feel hunted. |
| Plain crates | Treasure chests with an opening animation | So opening one feels like a reward. |
| Placeholder blobs and bars | Recognisable limbs on the player and enemies | See section 2. |
| Win or lose parts in battles | The full-body rule, and losing a specific part when knocked out | One simple rule that anyone watching can follow. |

---

## 5. The pipeline (Maya → Godot contract)

The same rules are used on both sides:
- **Part types:** `head`, `torso`, `arm_L`, `arm_R`, `leg_L`, `leg_R`. **Styles:** `robot`, `beast`, `slime`.
- **Naming:** a part is a group named `<style>_<type>` containing its mesh and a locator `socket_<type>` at the group's origin. The origin is where it attaches to a body.
- **Files:** each part exports as `<style>_<type>.fbx` plus `<style>_<type>.json`, for example `{"type": "arm_L", "style": "beast", "attack": 3, "defense": 0, "health": 0, "speed": 0}`.
- **Units:** Maya works in cm and Godot in m. The FBX import scales the parts, and as a safety net the game shrinks any part over 5 m by 100×.
- **Shapes:** the limb shape table exists in both `maya_tools/part_exporter.py` (cm) and `scripts/part_library.gd` (m). Parts exported with the older one-blob builder (mesh named `<style>_<type>_geo`) are shown with the new limb shapes in the game; your own modelled parts and re-exported parts are used exactly as exported.

**In Godot:** `PartLibrary` reads every FBX + JSON in `parts/`. The player and every enemy have `Marker3D` sockets with the same names. Attaching a part means `add_child` on the socket, then lining the part's own `socket_` locator up with the marker.

---

## 6. Project layout

| File | What it does |
|---|---|
| `maya_tools/part_exporter.py` | Maya Part Exporter window: build recognisable parts, check them, export FBX + JSON |
| `maya_tools/export_test_part.py` | the Nov 10 one-part pipeline test |
| `parts/` | exported parts (FBX + JSON) |
| `scripts/main.gd` | game flow: arena, camera, chests, the full-body rule, combat, NPC / boss events, HUD, title and pause screens |
| `scripts/part_library.gd` | loads parts from `parts/`, the limb shape table, hands out parts |
| `scripts/player.gd` | the player: movement, jumping, HP, sockets, equipping parts, walk / jump animation |
| `scripts/rig.gd` | creature body for NPCs and the boss: limbs on sockets plus a walk cycle |
| `scripts/npc.gd` | red NPCs: 5 designs; wander, chase and swipe |
| `scripts/boss.gd` | the BOSS: 3 designs; chest-grabbing, chasing, wind-up attack, health bar |
| `scripts/art.gd` | sky, arena, chests and their opening animation, particle effects, UI theme |
| `scripts/sfx.gd` | sound effects and music made in code |

### Tuning
All the numbers are constants at the top of the scripts:
- `main.gd`: heal amount, chest odds, weapon table, attack range, stomp bonus, NPC damage.
- `player.gd`: part sizes (`PART_SCALE`) and animation (`LEG_SWING`, `ARM_SWING`, `STRIDE`).
- `part_library.gd`: limb thickness (`LIMB_THICKNESS`).
- `npc.gd` and `boss.gd`: speeds, ranges, wind-up times, and the `VARIANTS` lists. Copy a line to add a new design.

The game prints its random seed when it starts. Set `game_seed` on the Main node to replay the same map.

---

## Appendix: original proposal (Nov 2026)

**Plan:** a Maya Python tool that builds and exports modular body parts with sockets and stats, feeding a small Godot game where a glowing sphere explores a map, opens crates and fights NPCs to win or lose parts.

**Milestones as proposed:**
- **Nov 10:** the pipeline works once (one part from Maya snaps onto the sphere).
- **Nov 17:** the core loop (Maya tool finished; crates give parts; stats add up).
- **Nov 23:** battles and polish (boss, win/lose, New Game, 2–3 styles).

**Riskiest part as predicted:** the Maya → Godot hand-off (socket names, cm vs m, pivots, orientation). It was proven first, on Nov 10.
