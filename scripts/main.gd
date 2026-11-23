extends Node3D
## Nov 23 milestone: open crates for parts (Nov 17), fight NPCs in turn-based
## battles where the winner takes a part, beat the boss to win, New Game to replay.

const ArtKit := preload("res://scripts/art.gd")
const SfxPlayer := preload("res://scripts/sfx.gd")

const MAP_SIZE := 40.0
const CAMERA_OFFSET := Vector3(0, 9, 9)
const BASE_HP := 10
## You can only attack (melee, stomp or weapon) while wearing all of these.
const REQUIRED_PARTS := ["head", "arm_L", "arm_R", "leg_L", "leg_R"]
const PART_NAMES := {"head": "head", "torso": "torso", "arm_L": "left arm", "arm_R": "right arm", "leg_L": "left leg", "leg_R": "right leg"}
const MISSING_PART_CHANCE := 0.75    ## a chest gives a part you're missing this often
const MIN_CHESTS := 3                ## new chests appear when fewer than this are left unopened
const CAMERA_SMOOTH := 7.0
const HEAL_AMOUNT := 5               ## HP restored by a green health capsule (dropped by knocked-out NPCs)
const WEAPON_CHANCE := 0.35          ## chance a crate holds a ranged weapon instead of a part
const WEAPON_SHOTS := 3              ## shots before the weapon breaks and you're back to melee
const FIRE_COOLDOWN := 0.3

## Ranged weapons found in crates. Fire with F (or the Fire button).
## range = metres, radius = hit size, grow = flame puff gets bigger as it flies, pierce = keeps going after a hit.
const WEAPONS := {
	"laser": {"name": "Laser gun", "damage": 8, "speed": 30.0, "range": 18.0, "radius": 0.35,
		"grow": 0.0, "pierce": false, "color": Color(1.0, 0.2, 0.25)},
	"flamethrower": {"name": "Flamethrower", "damage": 6, "speed": 11.0, "range": 7.0, "radius": 0.6,
		"grow": 1.6, "pierce": true, "color": Color(1.0, 0.55, 0.1)},
}

# Real-time boss fight (boss's own numbers are at the top of boss.gd).
const PLAYER_ATTACK_RANGE := 2.6     ## how close you must be to hit the boss with E
const PLAYER_ATTACK_COOLDOWN := 0.35 ## seconds between your basic attacks
const STOMP_BONUS := 3               ## extra damage for landing on the boss's head
const STOMP_COOLDOWN := 0.4
const BOSS_START_PARTS := 2          ## the boss starts weaker and grows by opening crates
const BOSS_HIT_REACH := 2.6          ## the boss's swing connects if you're still this close
const NPC_HIT_REACH := 2.2           ## an NPC's swipe connects if you're still this close
const NPC_DAMAGE_MIN := 1            ## NPC swipes are weak but they come in packs
const NPC_DAMAGE_MAX := 2

## 0 = new random game every run. The seed is printed, so a game (and every fight) can be replayed.
@export var game_seed: int = 0
@export var crate_count: int = 10
@export var npc_count: int = 4

var rng := RandomNumberGenerator.new()
var library := PartLibrary.new()
var player: Player
var camera: Camera3D
var status_label: Label
var inventory_label: RichTextLabel
var action_button: Button
var end_panel: PanelContainer
var end_label: Label
var held_dirs := {}
var nearby: Node3D = null
var game_over := false
var boss: Boss
var boss_in_range := false
var attack_cooldown := 0.0
var stomp_cooldown := 0.0
var hp_bar: ProgressBar
var hp_label: Label
var hp_fill: StyleBoxFlat
var fire_button: Button
## Ranged weapon you're holding ("" = melee only) and its shots left.
var weapon_id := ""
var weapon_shots := 0
var weapon_node: Node3D = null
var fire_cooldown := 0.0
## Flying shots: {"node", "dir", "travelled", "data", "hit"}
var projectiles: Array = []
var sfx: SfxPlayer
var cam_look := Vector3.ZERO
var cam_shake := 0.0
var flash_rect: ColorRect
var title_panel: Control
var pause_panel: Control
var rule_label: Label
var used_spots: Array[Vector3] = []
var chest_number := 0
var npc_number := 0
## Skip the title screen after "New Game" (the scene reloads, static vars survive).
static var started_once := false


func _ready() -> void:
	if game_seed == 0:
		rng.randomize()
	else:
		rng.seed = game_seed
	print("Game seed: ", rng.seed)

	library.load_parts()
	# Menus keep working while the game is paused; the world nodes pause.
	process_mode = Node.PROCESS_MODE_ALWAYS
	Engine.time_scale = 1.0

	sfx = SfxPlayer.new()
	add_child(sfx)

	ArtKit.build_environment(self)
	ArtKit.build_arena(self, MAP_SIZE, rng)

	player = Player.new()
	player.name = "Player"
	player.process_mode = Node.PROCESS_MODE_PAUSABLE
	player.map_half = MAP_SIZE * 0.5 - 1.0
	add_child(player)
	player.position = Vector3(0, 1, 0)
	player.landed_on.connect(_on_player_landed)
	player.jumped.connect(func() -> void: sfx.play("jump"))
	player.landed_hard.connect(_on_player_landed_hard)
	player.footstep.connect(_on_footstep)

	camera = Camera3D.new()
	camera.fov = 60.0
	add_child(camera)
	camera.current = true
	cam_look = player.global_position
	camera.global_position = cam_look + CAMERA_OFFSET
	camera.look_at(cam_look, Vector3.UP)

	_spawn_props()
	_build_ui()
	_refresh_inventory()
	var n := library.count_from_files()
	print("%d part(s) from Maya." % n)
	_set_status("Open chests to collect a HEAD, two ARMS and two LEGS.\nOnly a full body can fight. Then knock out the red NPCs and beat the purple BOSS!")
	if started_once:
		get_tree().paused = false
	else:
		get_tree().paused = true
		title_panel.visible = true


func _process(delta: float) -> void:
	_update_camera(delta)
	if get_tree().paused:
		return

	attack_cooldown = maxf(0.0, attack_cooldown - delta)
	stomp_cooldown = maxf(0.0, stomp_cooldown - delta)
	fire_cooldown = maxf(0.0, fire_cooldown - delta)
	_update_projectiles(delta)
	boss_in_range = false
	if is_instance_valid(boss) and boss.active and not game_over:
		var d := player.global_position - boss.global_position
		d.y = 0.0
		boss_in_range = d.length() <= PLAYER_ATTACK_RANGE
	_update_action_button()
	_update_hp_bar()


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.physical_keycode == KEY_ESCAPE:
		_toggle_pause()
		return
	if key.physical_keycode == KEY_M:
		var muted := sfx.toggle_mute()
		_set_status("Sound off. Press M to turn it back on." if muted else "Sound on.")
		return
	if get_tree().paused:
		if key.physical_keycode == KEY_ENTER and title_panel.visible:
			_start_game()
		return
	if key.physical_keycode == KEY_E:
		interact()
	elif key.physical_keycode == KEY_SPACE:
		_jump()
	elif key.physical_keycode == KEY_F:
		_fire_weapon()


# ---------------------------------------------------------------- world

# ---------------------------------------------------------------- crates, NPCs, boss

func _spawn_props() -> void:
	used_spots = [Vector3.ZERO]
	for i in crate_count:
		_spawn_chest()
	for i in npc_count:
		_add_prop("NPC%d" % (i + 1), "npc", _random_free_spot(used_spots))
	_spawn_boss(_random_free_spot(used_spots, 12.0))


func _spawn_chest() -> Node3D:
	chest_number += 1
	var chest_name := "Chest%d" % chest_number
	_add_prop(chest_name, "crate", _random_free_spot(used_spots, 3.0))
	return get_node(chest_name) as Node3D


## Keep a few unopened chests on the map, so a lost part can always be found again.
func _top_up_chests() -> void:
	var unopened := 0
	for c in get_tree().get_nodes_in_group("crate"):
		if not c.get_meta("opened", false):
			unopened += 1
	while unopened < MIN_CHESTS:
		var chest := _spawn_chest()
		var visual: Node3D = chest.get_meta("visual")
		visual.scale = Vector3(0.01, 0.01, 0.01)
		var tw := visual.create_tween()
		tw.tween_property(visual, "scale", Vector3.ONE, 0.4).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		ArtKit.burst(self, chest.global_position + Vector3(0, 0.5, 0), Color(1.0, 0.85, 0.4), 14, 3.0)
		unopened += 1


func _spawn_boss(pos: Vector3) -> void:
	boss = Boss.new()
	boss.name = "BOSS"
	boss.setup(rng, player, MAP_SIZE * 0.5 - 1.0, library, rng.randi_range(0, Boss.VARIANTS.size() - 1), BOSS_START_PARTS)
	boss.position = pos
	boss.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(boss)
	boss.strike.connect(_on_boss_strike)
	boss.windup_started.connect(func() -> void: sfx.play("windup", 0.0, -4.0))
	boss.reached_crate.connect(_on_boss_reached_crate)


## A random spot at least 3 m from other props (and min_from_center from the start).
func _random_free_spot(used: Array[Vector3], min_from_center: float = 0.0) -> Vector3:
	var half := MAP_SIZE * 0.5 - 2.0
	var pos := Vector3.ZERO
	for attempt in 50:
		pos = Vector3(rng.randf_range(-half, half), 0, rng.randf_range(-half, half))
		var ok := pos.length() >= min_from_center
		for other in used:
			if pos.distance_to(other) < 3.0:
				ok = false
				break
		if ok:
			break
	used.append(pos)
	return pos


func _add_prop(prop_name: String, kind: String, pos: Vector3) -> void:
	# Crates are solid static boxes; NPCs are bodies that wander (npc.gd).
	var root: PhysicsBody3D
	var npc_parts: Array = []
	if kind == "crate":
		root = StaticBody3D.new()
	else:
		var npc := Npc.new()
		npc_parts = npc.setup(rng, MAP_SIZE * 0.5 - 1.0, player, library, npc_number)
		npc_number += 1
		npc.add_to_group("npc")
		npc.process_mode = Node.PROCESS_MODE_PAUSABLE
		npc.strike.connect(_on_npc_strike)
		root = npc
	root.name = prop_name
	root.position = pos
	# Chests face the camera (lock side), NPCs face anywhere.
	root.rotation.y = rng.randf_range(-0.35, 0.35) if kind == "crate" else rng.randf() * TAU
	root.set_meta("kind", kind)
	root.set_meta("opened", false)

	var col := CollisionShape3D.new()
	if kind == "crate":
		root.add_to_group("crate")  # the boss looks these up to go and open them
		var chest := ArtKit.make_chest()
		root.add_child(chest["visual"])
		for k in chest:
			root.set_meta(k, chest[k])
		var box_shape := BoxShape3D.new()
		box_shape.size = Vector3(0.95, 0.9, 0.65)
		col.shape = box_shape
		col.position.y = 0.45
	else:
		# Body, limbs and collision were built by npc.setup() (one of Npc.VARIANTS).
		var npc_body := root as Npc
		root.set_meta("mesh", npc_body.rig.ball)
		root.set_meta("parts", npc_parts)
		var label := Label3D.new()
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.position.y = npc_body.rig.top_height() + 0.4
		label.font_size = 40
		label.pixel_size = 0.008  # bigger, so it's readable from the camera
		label.outline_size = 8
		root.add_child(label)
		root.set_meta("label", label)
		_refresh_npc_label(root)
	if kind == "crate":
		root.add_child(col)

	# Trigger zone: body_entered / body_exited fire when the player walks up or away.
	var area := Area3D.new()
	var trigger := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 1.6
	trigger.shape = sphere
	trigger.position.y = 0.5
	area.add_child(trigger)
	root.add_child(area)
	area.body_entered.connect(_on_prop_entered.bind(root))
	area.body_exited.connect(_on_prop_exited.bind(root))

	add_child(root)


func _on_prop_entered(body: Node3D, prop: Node3D) -> void:
	if body != player or game_over:
		return
	var kind: String = prop.get_meta("kind")
	if kind == "crate":
		if prop.get_meta("opened"):
			return
		nearby = prop
		_set_status("Found a chest! Press E to open it.")
	else:
		if prop.get_meta("dead", false):
			return
		nearby = prop
		if _can_fight():
			_set_status("%s is close. Press E to attack it." % prop.name)
		else:
			_set_status("%s is close, but you can't fight yet.\nStill missing: %s" % [prop.name, _part_list(_missing_parts())])


func _on_prop_exited(body: Node3D, prop: Node3D) -> void:
	if body == player and prop == nearby:
		nearby = null


func interact() -> void:
	if game_over:
		return
	var enemy_close: bool = boss_in_range or (is_instance_valid(nearby) and nearby.get_meta("kind") != "crate")
	if enemy_close and not _can_fight():
		_need_parts_feedback()
		return
	if boss_in_range:
		_attack_boss()
		return
	if not is_instance_valid(nearby):
		return
	var target := nearby
	if target.get_meta("kind") == "crate":
		nearby = null
		_open_crate(target)
	else:
		_attack_npc(target)


# ---------------------------------------------------------------- the full-body rule

## Required parts the player isn't wearing.
func _missing_parts() -> Array:
	var out: Array = []
	for t in REQUIRED_PARTS:
		if not player.equipped.has(t):
			out.append(t)
	return out


func _can_fight() -> bool:
	return _missing_parts().is_empty()


func _part_list(types: Array) -> String:
	var names: Array[String] = []
	for t in types:
		names.append(str(PART_NAMES.get(t, t)).to_upper())
	return ", ".join(names)


## Tried to attack without a full body: say clearly what's missing.
func _need_parts_feedback() -> void:
	if attack_cooldown > 0.0:
		return
	attack_cooldown = PLAYER_ATTACK_COOLDOWN
	sfx.play("click", 0.0, -2.0)
	_shake(0.15)
	_popup_text(player.global_position + Vector3(0, 1.6, 0), "NEED FULL BODY", Color(1.0, 0.45, 0.4))
	_set_status("You can't fight yet! Only a full body can attack.\nStill missing: %s. Open chests to find them." % _part_list(_missing_parts()))
	_pulse_rule_label()


# ---------------------------------------------------------------- chests

func _open_crate(crate: Node3D) -> void:
	if crate.get_meta("opened"):
		return
	_mark_crate_opened(crate)
	sfx.play("open")

	# Chests favour the parts you're missing, so a lost part can always be found again.
	# Weapons only show up once you have a full body (you couldn't use one before).
	var missing := _missing_parts()
	var reward := {}
	if not missing.is_empty() and rng.randf() < MISSING_PART_CHANCE:
		var t: String = missing[rng.randi_range(0, missing.size() - 1)]
		reward["part"] = library.random_part_of_type(rng, t)
	elif missing.is_empty() and rng.randf() < WEAPON_CHANCE:
		var ids: Array = WEAPONS.keys()
		reward["weapon"] = ids[rng.randi_range(0, ids.size() - 1)]
	else:
		reward["part"] = library.random_part(rng)
	_fly_reward(crate, reward)
	_top_up_chests()


## The reward rises out of the open chest, then flies in an arc onto the player.
func _fly_reward(crate: Node3D, reward: Dictionary) -> void:
	var item: Node3D
	if reward.has("weapon"):
		item = _make_weapon_mesh(str(reward["weapon"]))
	else:
		item = library.make_part(reward["part"])
	add_child(item)
	var start := crate.global_position + Vector3(0, 0.7, 0)
	var top := start + Vector3(0, 1.1, 0)
	item.global_position = start
	item.scale = Vector3.ONE * 0.2
	var spin := item.create_tween().set_loops()
	spin.tween_property(item, "rotation:y", TAU, 0.8).from(0.0)

	var tw := create_tween()
	tw.tween_interval(0.4)  # let the lid swing open first
	tw.tween_property(item, "global_position", top, 0.35).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(item, "scale", Vector3.ONE * 1.8, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(0.25)
	tw.tween_method(_arc_to_player.bind(item, top), 0.0, 1.0, 0.4)
	tw.tween_callback(_reward_arrived.bind(item, str(crate.name), reward))


func _arc_to_player(t: float, item: Node3D, from: Vector3) -> void:
	var target := player.global_position + Vector3(0, 0.3, 0)
	item.global_position = from.lerp(target, t) + Vector3(0, sin(t * PI) * 1.2, 0)
	item.scale = Vector3.ONE * lerpf(1.8, 0.5, t)


func _reward_arrived(item: Node3D, source: String, reward: Dictionary) -> void:
	item.queue_free()
	_receive_reward(source, reward)


func _receive_reward(source: String, reward: Dictionary) -> void:
	if game_over:
		return
	if reward.has("weapon"):
		var id := str(reward["weapon"])
		_give_weapon(id)
		sfx.play("weapon")
		ArtKit.burst(self, player.global_position, WEAPONS[id]["color"], 22, 4.0)
		_set_status("%s held a %s! %d shots: press F (or Fire) to shoot.\nIt breaks after the last shot and you're back to melee." % [source, WEAPONS[id]["name"], WEAPON_SHOTS])
		_refresh_inventory()
		return

	var info: Dictionary = reward["part"]
	var had_full_body := _can_fight()
	var old := player.equip(library.make_part(info), info)
	_pop_in_part(str(info["type"]))
	sfx.play("part")
	ArtKit.burst(self, player.global_position, PartLibrary.STYLE_COLORS.get(info["style"], Color.WHITE), 24, 4.5)
	ArtKit.ring(self, player.global_position - Vector3(0, player.lift + 0.45, 0), Color(1.0, 0.85, 0.4), 1.8)
	var msg := "%s: you got a %s %s! %s" % [source, info["style"], str(PART_NAMES.get(info["type"], info["type"])).to_upper(), _stats_text(info)]
	if not old.is_empty():
		msg += "\nYour old %s %s went into your bag." % [old["style"], PART_NAMES.get(old["type"], old["type"])]
	if _can_fight():
		if not had_full_body:
			msg += "\nFULL BODY! You can fight now."
			sfx.play("win", 0.0, -6.0)
			_popup_text(player.global_position + Vector3(0, 2.0, 0), "FULL BODY!", Color(0.5, 1.0, 0.6))
	else:
		msg += "\nStill missing: %s" % _part_list(_missing_parts())
	_set_status(msg)
	_refresh_inventory()


## The new part pops onto the body with a little overshoot.
func _pop_in_part(part_type: String) -> void:
	var marker: Marker3D = player.sockets.get("socket_" + part_type)
	if marker == null or marker.get_child_count() == 0:
		return
	var part := marker.get_child(marker.get_child_count() - 1) as Node3D
	var full := part.scale
	part.scale = full * 0.05
	var tw := part.create_tween()
	tw.tween_property(part, "scale", full, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## Lid swings open; the chest stays open (and empty) afterwards.
func _mark_crate_opened(crate: Node3D) -> void:
	crate.set_meta("opened", true)
	ArtKit.open_chest(self, crate)


# ---------------------------------------------------------------- real-time boss fight

func _jump() -> void:
	if not game_over and not get_tree().paused:
		player.request_jump()


## Basic attack (E or the Attack button when next to the boss).
func _attack_boss() -> void:
	if attack_cooldown > 0.0 or not is_instance_valid(boss):
		return
	attack_cooldown = PLAYER_ATTACK_COOLDOWN
	var dir := boss.global_position - player.global_position
	dir.y = 0.0
	player.push(dir, 4.0)
	var dmg := _hit(player.total_stats(), boss.stats())
	_damage_boss(dmg, "%d" % dmg, Color(1.0, 0.95, 0.4))


## The player landed on something. On the boss's head = stomp (full body only).
func _on_player_landed(body: Node) -> void:
	if game_over or body != boss or stomp_cooldown > 0.0:
		return
	stomp_cooldown = STOMP_COOLDOWN
	var away := player.global_position - boss.global_position
	away.y = 0.0
	if away.length() < 0.1:
		away = Vector3(1, 0, 0)
	player.bounce(away)
	if not _can_fight():
		_need_parts_feedback()
		return
	var dmg := _hit(player.total_stats(), boss.stats()) + STOMP_BONUS
	sfx.play("stomp")
	ArtKit.ring(self, boss.global_position, Color(1.0, 0.6, 0.2), 3.0)
	_damage_boss(dmg, "STOMP! %d" % dmg, Color(1.0, 0.6, 0.2))


func _on_footstep(pos: Vector3) -> void:
	ArtKit.burst(self, pos, Color(0.55, 0.55, 0.6), 5, 1.5, 0.06, 0.35)
	sfx.play("land", 0.15, -18.0)


func _on_player_landed_hard() -> void:
	sfx.play("land", 0.1, -6.0)
	ArtKit.ring(self, player.global_position - Vector3(0, player.lift + 0.45, 0), Color(0.5, 0.9, 1.0), 1.4, 0.25)


func _damage_boss(dmg: int, popup: String, color: Color) -> void:
	_popup_text(boss.global_position + Vector3(0, 2.4, 0), popup, color)
	ArtKit.burst(self, boss.global_position + Vector3(0, 1.3, 0), color, 16, 5.0)
	sfx.play("hit")
	_shake(0.25)
	_hitstop(0.05)
	var dead := boss.take_damage(dmg)
	if dead:
		_defeat_boss()
	else:
		_set_status("You hit the BOSS for %d.  BOSS HP %d/%d" % [dmg, boss.hp, boss.max_hp])


func _defeat_boss() -> void:
	boss.active = false
	var prize: Dictionary
	if boss.parts.is_empty():
		prize = library.random_part(rng)
	else:
		prize = boss.parts[rng.randi_range(0, boss.parts.size() - 1)]
	var old := player.equip(library.make_part(prize), prize)
	_pop_in_part(str(prize["type"]))
	var msg := "You beat the BOSS! You took its %s %s %s." % [prize["style"], PART_NAMES.get(prize["type"], prize["type"]), _stats_text(prize)]
	if not old.is_empty():
		msg += "\nYour old %s %s went into your bag." % [old["style"], PART_NAMES.get(old["type"], old["type"])]
	ArtKit.burst(self, boss.global_position + Vector3(0, 1.2, 0), Color(0.75, 0.4, 1.0), 60, 8.0, 0.14, 1.0)
	ArtKit.ring(self, boss.global_position, Color(0.75, 0.4, 1.0), 6.0, 0.6)
	_shake(0.6)
	var tw := create_tween()
	tw.tween_interval(0.25)
	tw.tween_property(boss, "scale", Vector3(0.01, 0.01, 0.01), 0.35)
	tw.tween_callback(boss.queue_free)
	_refresh_inventory()
	_end_game(true, "VICTORY!\nYou beat the BOSS.")
	_set_status(msg)


## The boss's wind-up finished: if you didn't get away, you take the hit.
func _on_boss_strike() -> void:
	if game_over:
		return
	ArtKit.ring(self, boss.global_position, Color(1.0, 0.5, 0.2), BOSS_HIT_REACH, 0.25)
	if player.invulnerable > 0.0:
		return
	var away := player.global_position - boss.global_position
	away.y = 0.0
	if away.length() > BOSS_HIT_REACH:
		_popup_text(boss.global_position + Vector3(0, 2.4, 0), "miss", Color(0.8, 0.8, 0.8))
		return
	var dmg := _hit(boss.stats(), player.total_stats())
	_hurt_player(dmg, away, 0.45)
	if player.hp <= 0:
		_player_downed(boss)
	else:
		_set_status("The %s hit you for %d!  Your HP %d/%d" % [_enemy_name(boss), dmg, player.hp, player.max_hp])


## An NPC finished its swipe: weak, but they chase you in packs.
func _on_npc_strike(npc: Node3D) -> void:
	if game_over or not is_instance_valid(npc) or npc.get_meta("dead", false):
		return
	ArtKit.ring(self, npc.global_position, Color(1.0, 0.4, 0.3), NPC_HIT_REACH, 0.2)
	if player.invulnerable > 0.0:
		return
	var away := player.global_position - npc.global_position
	away.y = 0.0
	if away.length() > NPC_HIT_REACH:
		return
	var dmg := rng.randi_range(NPC_DAMAGE_MIN, NPC_DAMAGE_MAX)
	_hurt_player(dmg, away, 0.25)
	if player.hp <= 0:
		_player_downed(npc)
	else:
		_set_status("%s hit you for %d!  Your HP %d/%d\nRun, or get a full body and fight back." % [_enemy_name(npc), dmg, player.hp, player.max_hp])


func _hurt_player(dmg: int, away: Vector3, shake: float) -> void:
	player.take_hit(dmg, away)
	sfx.play("hurt")
	_shake(shake)
	_hitstop(0.08 if shake > 0.3 else 0.04)
	_screen_flash(Color(1.0, 0.1, 0.1, 0.35))
	ArtKit.burst(self, player.global_position, Color(1.0, 0.3, 0.3), 14, 4.0)
	_popup_text(player.global_position + Vector3(0, 1.2, 0), "-%d" % dmg, Color(1.0, 0.35, 0.35))


func _enemy_name(enemy: Node3D) -> String:
	if enemy == boss:
		return str(boss.variant.get("name", "BOSS"))
	if enemy is Npc:
		return str((enemy as Npc).variant.get("name", enemy.name))
	return str(enemy.name)


## Out of HP: whoever knocked you out rips off one of your parts at random and wears it,
## and you respawn away from it. You have to find that part again (chests) before you
## can fight. With no parts left, it's game over.
func _player_downed(attacker: Node3D) -> void:
	var who := _enemy_name(attacker)
	if player.equipped.is_empty():
		_end_game(false, "DEFEATED\n%s knocked you out,\nand you had no parts left." % who)
		_set_status("%s won." % who)
		return
	var lost := player.remove_random_part(rng)
	if attacker == boss:
		boss.add_part(lost)
	elif attacker is Npc:
		var parts: Array = attacker.get_meta("parts")
		parts.append(lost)
		(attacker as Npc).wear(lost)
		_refresh_npc_label(attacker)
	var lost_name := str(PART_NAMES.get(lost["type"], lost["type"])).to_upper()
	ArtKit.burst(self, player.global_position, Color(0.75, 0.4, 1.0), 30, 6.0)
	_screen_flash(Color(0.4, 0.0, 0.5, 0.5))
	sfx.play("lose", 0.0, -4.0)
	_refresh_inventory()
	_top_up_chests()
	# Respawn on the far side of the map from the attacker, full HP, briefly invulnerable.
	var away := -attacker.global_position
	away.y = 0.0
	if away.length() < 0.1:
		away = Vector3(1, 0, 0)
	player.position = away.normalized() * (MAP_SIZE * 0.35) + Vector3(0, 1 + player.lift, 0)
	player.velocity = Vector3.ZERO
	player.knock = Vector3.ZERO
	player.heal_full()
	player.invulnerable = 2.0
	_popup_text(player.global_position + Vector3(0, 2.0, 0), "LOST: " + lost_name, Color(0.85, 0.55, 1.0))
	var msg := "%s knocked you out and ripped off your %s! (Now it's wearing it.)" % [who, lost_name]
	if REQUIRED_PARTS.has(lost["type"]):
		msg += "\nFind a new %s in a chest before you can fight again." % lost_name
	_set_status(msg)
	_pulse_rule_label()


## The boss walked up to a chest: it opens it and takes the part.
func _on_boss_reached_crate(crate: Node3D) -> void:
	if game_over or crate.get_meta("opened"):
		return
	_mark_crate_opened(crate)
	if nearby == crate:
		nearby = null
	var info := library.random_part(rng)
	boss.add_part(info)
	sfx.play("boss_grab", 0.05, -4.0)
	ArtKit.burst(self, crate.global_position + Vector3(0, 1.0, 0), Color(0.75, 0.4, 1.0), 18, 4.0)
	_popup_text(crate.global_position + Vector3(0, 1.5, 0), "BOSS +%s" % PART_NAMES.get(info["type"], info["type"]), Color(0.8, 0.55, 1.0))
	_set_status("The %s opened %s and grabbed a %s %s %s!" % [_enemy_name(boss), crate.name, info["style"], PART_NAMES.get(info["type"], info["type"]), _stats_text(info)])
	_top_up_chests()


## Floating text that rises and fades (damage numbers etc.).
func _popup_text(pos: Vector3, text: String, color: Color) -> void:
	var l := Label3D.new()
	l.text = text
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.font_size = 64
	l.pixel_size = 0.01
	l.outline_size = 12
	l.modulate = color
	add_child(l)
	l.global_position = pos
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(l, "position:y", l.position.y + 1.2, 0.7)
	tw.tween_property(l, "modulate:a", 0.0, 0.7)
	tw.tween_property(l, "outline_modulate:a", 0.0, 0.7)
	tw.chain().tween_callback(l.queue_free)


# ---------------------------------------------------------------- battles

## An NPC's stats: the sum of the parts it carries (the boss also gets a bonus).
func npc_stats(npc: Node3D) -> Dictionary:
	var total := {"attack": 0, "defense": 0, "health": 0, "speed": 0}
	for info in npc.get_meta("parts"):
		for k in total.keys():
			total[k] += int(info.get(k, 0))
	if npc.get_meta("kind") == "boss":
		total["attack"] += 1
		total["health"] += 3
	return total


## One hit: attack plus a random roll, minus half the defender's defence. Always at least 1.
func _hit(attacker: Dictionary, defender: Dictionary) -> int:
	return maxi(1, 2 + int(attacker["attack"]) + rng.randi_range(0, 3) - int(defender["defense"]) / 2)


# ---------------------------------------------------------------- NPCs: knock-outs and health capsules

## Basic attack on a red NPC (E or Attack when next to it). One hit knocks it out.
func _attack_npc(npc: Node3D) -> void:
	if attack_cooldown > 0.0 or npc.get_meta("dead", false):
		return
	attack_cooldown = PLAYER_ATTACK_COOLDOWN
	var dir := npc.global_position - player.global_position
	dir.y = 0.0
	player.push(dir, 4.0)
	_knock_out_npc(npc, "You knocked out %s!" % npc.name)


## The NPC drops one of its parts for you, vanishes, and leaves a green health capsule.
func _knock_out_npc(npc: Node3D, msg: String) -> void:
	if npc.get_meta("dead", false):
		return
	npc.set_meta("dead", true)
	var body := npc as Npc
	body.active = false
	body.collision_layer = 0  # stop blocking the player while it shrinks away
	npc.remove_from_group("npc")
	if nearby == npc:
		nearby = null

	var parts: Array = npc.get_meta("parts")
	if not parts.is_empty():
		var prize: Dictionary = parts[rng.randi_range(0, parts.size() - 1)]
		var old := player.equip(library.make_part(prize), prize)
		_pop_in_part(str(prize["type"]))
		msg += " You took its %s %s %s." % [prize["style"], PART_NAMES.get(prize["type"], prize["type"]), _stats_text(prize)]
		if not old.is_empty():
			msg += "\nYour old %s %s went into your bag." % [old["style"], PART_NAMES.get(old["type"], old["type"])]

	_popup_text(npc.global_position + Vector3(0, 2.2, 0), "KO!", Color(1.0, 0.95, 0.4))
	_flash_node(npc)
	sfx.play("ko")
	sfx.play("hit", 0.1, -4.0)
	_shake(0.25)
	_hitstop(0.06)
	ArtKit.burst(self, npc.global_position + Vector3(0, 1.0, 0), Color(1.0, 0.3, 0.25), 26, 6.0)
	var drop_pos := npc.global_position
	var tw := create_tween()
	tw.tween_interval(0.2)
	tw.tween_property(npc, "scale", Vector3(0.01, 0.01, 0.01), 0.3)
	tw.tween_callback(npc.queue_free)
	_spawn_health_pack(drop_pos)
	_refresh_inventory()
	_set_status(msg + "\nIt dropped a green health capsule (+%d HP)." % HEAL_AMOUNT)


## A spinning green capsule. Walk over it to get HP back.
func _spawn_health_pack(pos: Vector3) -> void:
	var pack := Area3D.new()
	pack.name = "HealthPack"
	add_child(pack)
	pack.global_position = Vector3(pos.x, 0.0, pos.z)

	var trigger := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.8
	trigger.shape = sphere
	trigger.position.y = 0.6
	pack.add_child(trigger)

	var pivot := Node3D.new()
	pivot.position.y = 0.6
	pack.add_child(pivot)
	var pill := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.18
	cap.height = 0.7
	pill.mesh = cap
	pill.rotation.z = PI * 0.5  # lying on its side, like a pill
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 1.0, 0.45)
	mat.emission_enabled = true
	mat.emission = Color(0.2, 1.0, 0.4)
	mat.emission_energy_multiplier = 2.0
	pill.material_override = mat
	pivot.add_child(pill)

	var glow := OmniLight3D.new()
	glow.light_color = Color(0.3, 1.0, 0.45)
	glow.omni_range = 2.0
	glow.light_energy = 1.0
	pivot.add_child(glow)

	var tw := pack.create_tween().set_loops()
	tw.tween_property(pivot, "rotation:y", TAU, 1.6).from(0.0)
	pack.body_entered.connect(_on_pack_entered.bind(pack))


func _on_pack_entered(body: Node3D, pack: Area3D) -> void:
	if body != player or game_over or pack.is_queued_for_deletion():
		return
	if player.hp >= player.max_hp:
		_set_status("Your HP is already full. The health capsule will wait for you.")
		return
	var healed := mini(HEAL_AMOUNT, player.max_hp - player.hp)
	player.hp += healed
	_popup_text(player.global_position + Vector3(0, 1.2, 0), "+%d HP" % healed, Color(0.4, 1.0, 0.5))
	sfx.play("pickup")
	ArtKit.burst(self, pack.global_position + Vector3(0, 0.6, 0), Color(0.3, 1.0, 0.45), 20, 3.5)
	_screen_flash(Color(0.2, 1.0, 0.4, 0.18))
	_set_status("Health capsule: +%d HP.  Your HP %d/%d" % [healed, player.hp, player.max_hp])
	pack.queue_free()


# ---------------------------------------------------------------- ranged weapons

func _give_weapon(id: String) -> void:
	_drop_weapon()
	weapon_id = id
	weapon_shots = WEAPON_SHOTS
	weapon_node = _make_weapon_mesh(id)
	# Held in the right hand; player.gd moves it with the arm's swing.
	player.add_child(weapon_node)
	player.held_item = weapon_node


## A chunky gray gun with a glowing coloured tip, so it never looks like a limb.
func _make_weapon_mesh(id: String) -> Node3D:
	var data: Dictionary = WEAPONS[id]
	var root := Node3D.new()
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.25, 0.27, 0.32)
	body_mat.metallic = 0.7
	body_mat.roughness = 0.35
	var glow := StandardMaterial3D.new()
	glow.albedo_color = data["color"]
	glow.emission_enabled = true
	glow.emission = data["color"]
	glow.emission_energy_multiplier = 3.0
	var parts := [
		[Vector3(0.16, 0.16, 0.42), Vector3(0, 0, 0), body_mat],       # body
		[Vector3(0.1, 0.18, 0.1), Vector3(0, -0.14, 0.1), body_mat],   # grip
		[Vector3(0.09, 0.09, 0.22), Vector3(0, 0.02, -0.3), body_mat], # barrel
		[Vector3(0.12, 0.12, 0.06), Vector3(0, 0.02, -0.42), glow],    # glowing muzzle
		[Vector3(0.17, 0.05, 0.2), Vector3(0, 0.1, 0.0), glow],        # glowing stripe
	]
	if id == "flamethrower":
		parts.append([Vector3(0.14, 0.24, 0.14), Vector3(0, 0.05, 0.28), glow])  # fuel tank
	for p in parts:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = p[0]
		mi.mesh = bm
		mi.position = p[1]
		mi.material_override = p[2]
		root.add_child(mi)
	return root


func _drop_weapon() -> void:
	weapon_id = ""
	weapon_shots = 0
	if is_instance_valid(weapon_node):
		weapon_node.queue_free()
	weapon_node = null


## F or the Fire button. Auto-aims at the nearest NPC / boss in front of you.
func _fire_weapon() -> void:
	if game_over or weapon_shots <= 0 or fire_cooldown > 0.0:
		return
	if not _can_fight():
		_need_parts_feedback()
		return
	fire_cooldown = FIRE_COOLDOWN
	var data: Dictionary = WEAPONS[weapon_id]
	var dir := _aim_direction(float(data["range"]))
	player.rotation.y = atan2(-dir.x, -dir.z)
	_spawn_projectile(dir, data)
	sfx.play(weapon_id if weapon_id == "laser" else "flame")
	_shake(0.12)
	ArtKit.burst(self, player.global_position + dir * 0.9, data["color"], 10, 3.0, 0.07, 0.3)
	weapon_shots -= 1
	if weapon_shots <= 0:
		_set_status("Your %s is used up and fell apart. Back to melee (E)." % data["name"])
		_drop_weapon()
	else:
		_set_status("%s: %d shot(s) left." % [data["name"], weapon_shots])
	_refresh_inventory()


## The way you're facing, or toward the closest enemy within 50 degrees of it.
func _aim_direction(max_range: float) -> Vector3:
	var forward := -player.global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized()
	var best := forward
	var best_d := INF
	var targets: Array = get_tree().get_nodes_in_group("npc")
	if is_instance_valid(boss) and boss.active:
		targets.append(boss)
	for t in targets:
		var to: Vector3 = (t as Node3D).global_position - player.global_position
		to.y = 0.0
		var d := to.length()
		if d < 0.01 or d > max_range or forward.angle_to(to) > deg_to_rad(50.0):
			continue
		if d < best_d:
			best_d = d
			best = to.normalized()
	return best


func _spawn_projectile(dir: Vector3, data: Dictionary) -> void:
	var mi := MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = data["color"]
	if float(data["grow"]) > 0.0:
		# Flame puff: a see-through ball that swells as it flies.
		var ball := SphereMesh.new()
		ball.radius = float(data["radius"])
		ball.height = float(data["radius"]) * 2.0
		mi.mesh = ball
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color.a = 0.75
	else:
		# Laser bolt: a thin glowing rod.
		var rod := BoxMesh.new()
		rod.size = Vector3(0.08, 0.08, 0.9)
		mi.mesh = rod
	mi.material_override = mat
	add_child(mi)
	mi.global_position = player.global_position + dir * 0.7 + Vector3(0, 0.1, 0)
	mi.look_at(mi.global_position + dir, Vector3.UP)
	projectiles.append({"node": mi, "dir": dir, "travelled": 0.0, "data": data, "hit": []})


func _update_projectiles(delta: float) -> void:
	for i in range(projectiles.size() - 1, -1, -1):
		var p: Dictionary = projectiles[i]
		var node: Node3D = p["node"]
		var data: Dictionary = p["data"]
		var step := float(data["speed"]) * delta
		node.global_position += (p["dir"] as Vector3) * step
		p["travelled"] = float(p["travelled"]) + step
		var t := float(p["travelled"]) / float(data["range"])
		var grow := 1.0 + float(data["grow"]) * t
		if float(data["grow"]) > 0.0:
			node.scale = Vector3.ONE * grow
		var done := t >= 1.0 or game_over
		if not done:
			done = _projectile_hits(p, float(data["radius"]) * grow)
		if done:
			node.queue_free()
			projectiles.remove_at(i)


## Checks one shot against the boss and NPCs. Returns true if the shot should stop.
func _projectile_hits(p: Dictionary, radius: float) -> bool:
	var pos: Vector3 = (p["node"] as Node3D).global_position
	var data: Dictionary = p["data"]
	var hit: Array = p["hit"]
	if is_instance_valid(boss) and boss.active and not hit.has(boss):
		var d := Vector2(pos.x - boss.global_position.x, pos.z - boss.global_position.z).length()
		if d < radius + 0.5:
			hit.append(boss)
			var dmg := int(data["damage"]) + int(player.total_stats()["attack"]) / 2
			_damage_boss(dmg, "%d" % dmg, data["color"])
			if not data["pierce"]:
				return true
	for node in get_tree().get_nodes_in_group("npc"):
		var npc := node as Node3D
		var d := Vector2(pos.x - npc.global_position.x, pos.z - npc.global_position.z).length()
		if d < radius + 0.4:
			_knock_out_npc(npc, "Your %s knocked out %s!" % [data["name"], npc.name])
			if not data["pierce"]:
				return true
	return false


func _flash_node(npc: Node3D) -> void:
	var mesh_inst: MeshInstance3D = npc.get_meta("mesh")
	var mat := mesh_inst.material_override as StandardMaterial3D
	var base := mat.albedo_color
	var tw := create_tween()
	tw.tween_property(mat, "albedo_color", Color.WHITE, 0.08)
	tw.tween_property(mat, "albedo_color", base, 0.2)


func _refresh_npc_label(npc: Node3D) -> void:
	var label: Label3D = npc.get_meta("label")
	label.text = "%s\n%s" % [_enemy_name(npc), _short_stats(npc_stats(npc))]


# ---------------------------------------------------------------- win / lose

func _end_game(won: bool, text: String) -> void:
	game_over = true
	player.set_physics_process(false)
	if is_instance_valid(boss):
		boss.active = false
	action_button.disabled = true
	end_label.text = text
	end_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.6) if won else Color(1.0, 0.45, 0.45))
	sfx.play("win" if won else "lose", 0.0)
	end_panel.visible = true
	end_panel.scale = Vector2(0.6, 0.6)
	end_panel.pivot_offset = end_panel.size * 0.5
	var tw := end_panel.create_tween()
	tw.tween_property(end_panel, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _new_game() -> void:
	sfx.play("click")
	Engine.time_scale = 1.0
	get_tree().paused = false
	get_tree().reload_current_scene()


func _start_game() -> void:
	sfx.play("click")
	started_once = true
	title_panel.visible = false
	cam_look = player.global_position
	get_tree().paused = false


func _toggle_pause() -> void:
	if title_panel.visible or game_over:
		return
	var pausing := not get_tree().paused
	get_tree().paused = pausing
	pause_panel.visible = pausing
	sfx.play("click")


# ---------------------------------------------------------------- camera and screen effects

var title_angle := 0.0

func _update_camera(delta: float) -> void:
	if title_panel != null and title_panel.visible:
		# Slow orbit around the arena behind the title screen.
		title_angle += delta * 0.12
		camera.global_position = Vector3(sin(title_angle) * 22.0, 13.0, cos(title_angle) * 22.0)
		camera.look_at(Vector3.ZERO, Vector3.UP)
		return
	cam_look = cam_look.lerp(player.global_position, 1.0 - exp(-CAMERA_SMOOTH * delta))
	camera.global_position = cam_look + CAMERA_OFFSET
	camera.look_at(cam_look, Vector3.UP)
	if cam_shake > 0.0:
		var s := cam_shake * cam_shake * 0.6
		camera.global_position += Vector3(randf_range(-s, s), randf_range(-s, s), randf_range(-s, s))
		cam_shake = maxf(0.0, cam_shake - delta * 2.5)


## Camera shake, 0..1.
func _shake(amount: float) -> void:
	cam_shake = minf(1.0, maxf(cam_shake, amount))


## Freeze the game for a split second so hits feel heavy.
func _hitstop(duration: float) -> void:
	Engine.time_scale = 0.05
	await get_tree().create_timer(duration, true, false, true).timeout
	Engine.time_scale = 1.0


## A coloured flash over the whole screen that fades out (hurt = red, heal = green).
func _screen_flash(color: Color) -> void:
	flash_rect.color = color
	var tw := flash_rect.create_tween()
	tw.tween_property(flash_rect, "color:a", 0.0, 0.4)


func _pulse_rule_label() -> void:
	var panel := rule_label.get_parent() as Control
	panel.pivot_offset = panel.size * 0.5
	var tw := panel.create_tween()
	tw.tween_property(panel, "scale", Vector2(1.18, 1.18), 0.1)
	tw.tween_property(panel, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK)


# ---------------------------------------------------------------- UI

func _anchor(c: Control, left: float, top: float, right: float, bottom: float) -> void:
	c.anchor_left = left
	c.anchor_top = top
	c.anchor_right = right
	c.anchor_bottom = bottom


func _offsets(c: Control, left: float, top: float, right: float, bottom: float) -> void:
	c.offset_left = left
	c.offset_top = top
	c.offset_right = right
	c.offset_bottom = bottom


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.theme = ArtKit.make_theme()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# Screen flash (under everything else).
	flash_rect = ColorRect.new()
	flash_rect.color = Color(1, 0, 0, 0)
	flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(flash_rect)
	flash_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# Message box, top left.
	var status_panel := PanelContainer.new()
	root.add_child(status_panel)
	_anchor(status_panel, 0, 0, 0, 0)
	_offsets(status_panel, 16, 16, 600, 16)
	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.custom_minimum_size = Vector2(560, 0)
	status_label.add_theme_font_size_override("font_size", 17)
	status_panel.add_child(status_label)

	# The rule, just above the HP bar: how many of the 5 body parts you have.
	var rule_panel := PanelContainer.new()
	root.add_child(rule_panel)
	_anchor(rule_panel, 0.5, 1, 0.5, 1)
	_offsets(rule_panel, -230, -150, 230, -100)
	rule_label = Label.new()
	rule_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rule_label.add_theme_font_size_override("font_size", 20)
	rule_panel.add_child(rule_label)

	# Body / stats panel, top right.
	var panel := PanelContainer.new()
	root.add_child(panel)
	_anchor(panel, 1, 0, 1, 0)
	_offsets(panel, -300, 16, -16, 16)
	inventory_label = RichTextLabel.new()
	inventory_label.bbcode_enabled = true
	inventory_label.fit_content = true
	inventory_label.scroll_active = false
	inventory_label.custom_minimum_size = Vector2(260, 0)
	inventory_label.add_theme_font_size_override("normal_font_size", 16)
	inventory_label.add_theme_font_size_override("bold_font_size", 17)
	inventory_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(inventory_label)

	# Direction pad, bottom left.
	var pad := GridContainer.new()
	pad.columns = 3
	var layout := [["", "up", ""], ["left", "", "right"], ["", "down", ""]]
	var labels := {"up": "▲", "down": "▼", "left": "◀", "right": "▶"}
	var dirs := {"up": Vector2(0, -1), "down": Vector2(0, 1), "left": Vector2(-1, 0), "right": Vector2(1, 0)}
	for row in layout:
		for key in row:
			if key == "":
				var spacer := Control.new()
				spacer.custom_minimum_size = Vector2(64, 64)
				pad.add_child(spacer)
				continue
			var b := Button.new()
			b.text = labels[key]
			b.custom_minimum_size = Vector2(64, 64)
			b.focus_mode = Control.FOCUS_NONE
			b.add_theme_font_size_override("font_size", 26)
			var d: Vector2 = dirs[key]
			b.button_down.connect(_on_dir_down.bind(key, d))
			b.button_up.connect(_on_dir_up.bind(key))
			pad.add_child(b)
	root.add_child(pad)
	pad.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 24)

	# Action button (Open / Attack), bottom right.
	action_button = _corner_button(root, "Open (E)", Rect2(-184, -88, 160, 64), 20)
	action_button.disabled = true
	action_button.pressed.connect(interact)
	# Fire button, left of the action button. Only shown while you hold a weapon.
	fire_button = _corner_button(root, "", Rect2(-404, -88, 204, 64), 17)
	fire_button.visible = false
	fire_button.pressed.connect(_fire_weapon)
	# Jump button, above the action button.
	var jump_button := _corner_button(root, "Jump (Space)", Rect2(-184, -160, 160, 60), 20)
	jump_button.button_down.connect(_jump)

	# Player HP bar, bottom centre.
	var hp_panel := PanelContainer.new()
	root.add_child(hp_panel)
	_anchor(hp_panel, 0.5, 1, 0.5, 1)
	_offsets(hp_panel, -190, -92, 190, -20)
	var hp_box := VBoxContainer.new()
	hp_panel.add_child(hp_box)
	hp_label = Label.new()
	hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hp_label.add_theme_font_size_override("font_size", 18)
	hp_box.add_child(hp_label)
	hp_bar = ProgressBar.new()
	hp_bar.show_percentage = false
	hp_bar.custom_minimum_size = Vector2(340, 18)
	var hp_bg := StyleBoxFlat.new()
	hp_bg.bg_color = Color(0.04, 0.05, 0.08, 0.9)
	hp_bg.set_corner_radius_all(6)
	hp_fill = StyleBoxFlat.new()
	hp_fill.bg_color = Color(0.3, 0.85, 1.0)
	hp_fill.set_corner_radius_all(6)
	hp_bar.add_theme_stylebox_override("background", hp_bg)
	hp_bar.add_theme_stylebox_override("fill", hp_fill)
	hp_box.add_child(hp_bar)

	# Win / lose panel, centre, hidden until the game ends.
	end_panel = PanelContainer.new()
	end_panel.visible = false
	root.add_child(end_panel)
	_anchor(end_panel, 0.5, 0.5, 0.5, 0.5)
	_offsets(end_panel, -240, -130, 240, 130)
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 18)
	end_panel.add_child(box)
	end_label = Label.new()
	end_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	end_label.add_theme_font_size_override("font_size", 34)
	box.add_child(end_label)
	var again := Button.new()
	again.text = "New Game"
	again.custom_minimum_size = Vector2(220, 60)
	again.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	again.add_theme_font_size_override("font_size", 24)
	again.pressed.connect(_new_game)
	box.add_child(again)

	pause_panel = _build_pause(root)
	title_panel = _build_title(root)


func _corner_button(root: Control, text: String, r: Rect2, font: int) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", font)
	root.add_child(b)
	_anchor(b, 1, 1, 1, 1)
	_offsets(b, r.position.x, r.position.y, r.position.x + r.size.x, r.position.y + r.size.y)
	return b


const CONTROLS_TEXT := "WASD / arrows: move      Space: jump      E: open / attack\nF: fire weapon      Esc: pause      M: sound on / off"

func _build_title(root: Control) -> Control:
	var shade := ColorRect.new()
	shade.color = Color(0.02, 0.03, 0.07, 0.72)
	shade.visible = false
	root.add_child(shade)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var center := CenterContainer.new()
	shade.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 16)
	center.add_child(col)

	var title := Label.new()
	title.text = "COMPOSITE UNITS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 76)
	title.add_theme_color_override("font_color", ArtKit.ACCENT.lightened(0.2))
	title.add_theme_color_override("font_outline_color", Color(0.05, 0.1, 0.2))
	title.add_theme_constant_override("outline_size", 14)
	col.add_child(title)
	var sub := Label.new()
	sub.text = "Build a body from parts.  Beat the BOSS."
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 24)
	col.add_child(sub)

	var rules_panel := PanelContainer.new()
	col.add_child(rules_panel)
	var rules := Label.new()
	rules.text = "\n".join([
		"1.  You start as a glowing ball. Open treasure chests to get body parts.",
		"2.  Only a FULL BODY can fight: HEAD + 2 ARMS + 2 LEGS.",
		"3.  Red NPCs chase you and swipe (raised arms = incoming). One hit knocks one out.",
		"4.  Chests can also hold a Laser gun or Flamethrower (3 shots).",
		"5.  The purple BOSS hunts you and grabs chests too. Dodge its glowing wind-up.",
		"6.  Knocked out? Your attacker rips off a part - find it again to keep fighting.",
		"7.  Empty the BOSS health bar to win.",
	])
	rules.add_theme_font_size_override("font_size", 18)
	rules_panel.add_child(rules)
	var controls := Label.new()
	controls.text = CONTROLS_TEXT
	controls.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	controls.add_theme_font_size_override("font_size", 16)
	controls.add_theme_color_override("font_color", Color(0.75, 0.85, 0.95))
	col.add_child(controls)

	var play := Button.new()
	play.text = "PLAY"
	play.custom_minimum_size = Vector2(260, 70)
	play.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	play.add_theme_font_size_override("font_size", 30)
	play.pressed.connect(_start_game)
	col.add_child(play)
	var hint := Label.new()
	hint.text = "or press Enter"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 14)
	col.add_child(hint)
	var tw := play.create_tween().set_loops()
	tw.tween_property(play, "modulate", Color(1.25, 1.25, 1.25), 0.7)
	tw.tween_property(play, "modulate", Color.WHITE, 0.7)
	return shade


func _build_pause(root: Control) -> Control:
	var shade := ColorRect.new()
	shade.color = Color(0.02, 0.03, 0.07, 0.6)
	shade.visible = false
	root.add_child(shade)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var center := CenterContainer.new()
	shade.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := PanelContainer.new()
	center.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	panel.add_child(col)
	var title := Label.new()
	title.text = "PAUSED"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 40)
	col.add_child(title)
	var controls := Label.new()
	controls.text = CONTROLS_TEXT
	controls.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(controls)
	var resume := Button.new()
	resume.text = "Resume"
	resume.custom_minimum_size = Vector2(220, 54)
	resume.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	resume.pressed.connect(_toggle_pause)
	col.add_child(resume)
	var restart := Button.new()
	restart.text = "New Game"
	restart.custom_minimum_size = Vector2(220, 54)
	restart.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	restart.pressed.connect(_new_game)
	col.add_child(restart)
	return shade


## Open / Attack, depending on what you're next to. The boss wins if both.
func _update_action_button() -> void:
	var enemy_close: bool = boss_in_range or (is_instance_valid(nearby) and nearby.get_meta("kind") != "crate")
	if game_over:
		action_button.disabled = true
	elif enemy_close:
		# Still pressable without a full body: it explains what's missing.
		action_button.text = "Attack (E)" if _can_fight() else "Need full body"
		action_button.disabled = false
	elif is_instance_valid(nearby):
		action_button.text = "Open chest (E)"
		action_button.disabled = false
	else:
		action_button.disabled = true
	fire_button.visible = weapon_shots > 0 and not game_over
	if fire_button.visible:
		fire_button.text = "Fire %s (F)  x%d" % [WEAPONS[weapon_id]["name"], weapon_shots]


func _update_hp_bar() -> void:
	hp_bar.max_value = maxi(1, player.max_hp)
	hp_bar.value = player.hp
	hp_label.text = "HP  %d / %d" % [player.hp, player.max_hp]
	# Blink while invulnerable after a hit; red when low.
	var blink := player.invulnerable > 0.0 and int(player.invulnerable * 10.0) % 2 == 0
	var low := player.hp * 3 <= player.max_hp
	hp_fill.bg_color = Color(1.0, 0.4, 0.4) if blink or low else Color(0.3, 0.85, 1.0)


func _refresh_inventory() -> void:
	player.set_max_hp(BASE_HP + int(player.total_stats()["health"]))
	var lines: Array[String] = ["[b]BODY[/b]"]
	for part_type in PartLibrary.TYPES:
		var label := str(PART_NAMES.get(part_type, part_type)).capitalize()
		var needed := REQUIRED_PARTS.has(part_type)
		if player.equipped.has(part_type):
			var info: Dictionary = player.equipped[part_type]
			lines.append("[color=#7dff9a]✓[/color] %s  [color=#9fb3c8]%s[/color]" % [label, info["style"]])
		elif needed:
			lines.append("[color=#ff6b6b]✗ %s  missing[/color]" % label)
		else:
			lines.append("[color=#6b7a8c]-  %s  (optional)[/color]" % label)
	var t := player.total_stats()
	lines.append("")
	lines.append("[b]STATS[/b]")
	lines.append("Attack %d    Defense %d" % [t["attack"], t["defense"]])
	lines.append("Health %d (+%d base)    Speed %d" % [t["health"], BASE_HP, t["speed"]])
	lines.append("")
	if weapon_shots > 0:
		lines.append("Weapon  [color=#ffb347]%s (%d/%d)[/color]" % [WEAPONS[weapon_id]["name"], weapon_shots, WEAPON_SHOTS])
	else:
		lines.append("Weapon  none")
	lines.append("Bag: %d spare part(s)" % player.bag.size())
	inventory_label.text = "\n".join(lines)

	var have := REQUIRED_PARTS.size() - _missing_parts().size()
	if _can_fight():
		rule_label.text = "FULL BODY  %d/%d  -  READY TO FIGHT" % [have, REQUIRED_PARTS.size()]
		rule_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.6))
	else:
		rule_label.text = "BODY  %d/%d  -  can't fight yet" % [have, REQUIRED_PARTS.size()]
		rule_label.add_theme_color_override("font_color", Color(1.0, 0.55, 0.5))


func _stats_text(info: Dictionary) -> String:
	var bits: Array[String] = []
	for k in PartLibrary.STAT_KEYS:
		var v := int(info.get(k, 0))
		if v != 0:
			bits.append("%s +%d" % [k, v])
	return "(" + ", ".join(bits) + ")"


func _short_stats(s: Dictionary) -> String:
	return "ATK %d DEF %d HP %d SPD %d" % [s["attack"], s["defense"], int(s["health"]) + BASE_HP, s["speed"]]


func _on_dir_down(key: String, d: Vector2) -> void:
	held_dirs[key] = d
	_update_ui_direction()


func _on_dir_up(key: String) -> void:
	held_dirs.erase(key)
	_update_ui_direction()


func _update_ui_direction() -> void:
	var total := Vector2.ZERO
	for v in held_dirs.values():
		total += v
	player.ui_direction = total


func _set_status(text: String) -> void:
	status_label.text = text
	print(text)
