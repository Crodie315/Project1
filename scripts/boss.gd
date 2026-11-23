extends CharacterBody3D
class_name Boss
## The purple BOSS. It never stands still: it walks to unopened crates to grab
## parts (getting stronger), wanders when there are none left, and chases the
## player when they come close. Its attack has a short wind-up (it swells and
## glows) so the player can see it coming and dodge or jump away.
## A health bar floats above it; main.gd deals the damage.

const Rig := preload("res://scripts/rig.gd")

## The boss is one of these, wearing a full body in its style. Grabbing parts from
## chests (or taking yours) visibly swaps them onto its body.
const VARIANTS := [
	{"name": "IRON TITAN", "style": "robot", "color": Color(0.5, 0.25, 0.85), "radius": 0.62},
	{"name": "ALPHA BEAST", "style": "beast", "color": Color(0.45, 0.18, 0.7), "radius": 0.66},
	{"name": "SLIME KING", "style": "slime", "color": Color(0.62, 0.3, 0.95), "radius": 0.6},
]

signal reached_crate(crate: Node3D)
## The wind-up finished. main.gd checks whether the player is still in range.
signal strike
## The glowing wind-up began (for the warning sound).
signal windup_started

# ---------------------------------------------------------------- tuning
const BASE_MAX_HP := 30          ## HP before any parts
const HP_PER_HEALTH_POINT := 2   ## each "health" point on a part adds this much max HP
const WALK_SPEED := 3.0          ## wandering / walking to crates
const CHASE_SPEED := 4.3         ## chasing the player (player base speed is 5)
const SPEED_PER_POINT := 0.2     ## extra speed per "speed" stat point
const AGGRO_RANGE := 8.0         ## starts chasing when the player is this close
const GIVE_UP_RANGE := 13.0      ## stops chasing when the player gets this far away
const ATTACK_RANGE := 2.0        ## starts the wind-up when this close
const WINDUP_TIME := 0.6         ## seconds of warning before the hit lands
const ATTACK_COOLDOWN := 1.4     ## seconds before it can attack again
const CRATE_REACH := 1.7         ## opens a crate when this close to it
const GRAVITY := 22.0

const BAR_WIDTH := 1.6
const BAR_HEIGHT := 0.18

enum State { WANDER, SEEK_CRATE, CHASE, WINDUP, RECOVER }

var player: Node3D
var rng: RandomNumberGenerator
var map_half := 18.0
## Parts the boss carries. Its stats are the sum of them (+1 attack).
var parts: Array = []
var max_hp := BASE_MAX_HP
var hp := BASE_MAX_HP
var active := true

var state := State.WANDER
var state_time := 0.0
var wander_target := Vector3.ZERO
var crate_target: Node3D = null

var visual: Node3D
var rig: Rig
var library: PartLibrary
var variant: Dictionary
var body_mat: StandardMaterial3D
var body_col: CollisionShape3D
var bar_nodes: Array[Node3D] = []
var label: Label3D
var bar_fill_mesh: QuadMesh
var bar_fill_mat: StandardMaterial3D


## Call before add_child. It carries `carry` of the parts it's wearing (its stats,
## and what you can win), plus whatever it grabs later.
func setup(random: RandomNumberGenerator, target: Node3D, half: float, lib: PartLibrary, variant_index: int, carry: int) -> void:
	rng = random
	player = target
	map_half = half
	library = lib
	variant = VARIANTS[variant_index % VARIANTS.size()]
	var worn: Array = []
	for t in PartLibrary.TYPES:
		worn.append(library.part_info(str(variant["style"]), str(t)))
	rig = Rig.new()
	rig.build(variant["color"], float(variant["radius"]), worn, library)
	var carried := worn.duplicate()
	carried.shuffle()
	parts = carried.slice(0, carry)
	max_hp = BASE_MAX_HP + HP_PER_HEALTH_POINT * int(stats()["health"])
	hp = max_hp


func _ready() -> void:
	_build_body()
	_build_health_bar()
	refresh_label()
	_pick_goal()


# ---------------------------------------------------------------- stats / damage

func stats() -> Dictionary:
	var total := {"attack": 1, "defense": 0, "health": 0, "speed": 0}
	for info in parts:
		for k in total.keys():
			total[k] += int(info.get(k, 0))
	return total


## A new part from a crate (or taken from the player). Health parts raise max HP.
func add_part(info: Dictionary) -> void:
	parts.append(info)
	rig.wear(info, library)
	_fit_body()
	var gain := HP_PER_HEALTH_POINT * int(info.get("health", 0))
	max_hp += gain
	hp += gain
	refresh_label()


## Returns true if this hit defeated the boss.
func take_damage(amount: int) -> bool:
	hp = maxi(0, hp - amount)
	_flash()
	refresh_label()
	return hp <= 0


func refresh_label() -> void:
	if label == null:
		return
	var s := stats()
	label.text = "%s  %d/%d\nATK %d DEF %d SPD %d" % [variant.get("name", "BOSS"), hp, max_hp, s["attack"], s["defense"], s["speed"]]
	var ratio := clampf(float(hp) / float(max_hp), 0.0, 1.0)
	bar_fill_mesh.size = Vector2(BAR_WIDTH * ratio, BAR_HEIGHT)
	# Keep the bar's left edge fixed while it shrinks.
	bar_fill_mesh.center_offset = Vector3(-BAR_WIDTH * (1.0 - ratio) * 0.5, 0.0, 0.01)
	if ratio > 0.5:
		bar_fill_mat.albedo_color = Color(0.3, 0.9, 0.35)
	elif ratio > 0.25:
		bar_fill_mat.albedo_color = Color(0.95, 0.8, 0.2)
	else:
		bar_fill_mat.albedo_color = Color(0.95, 0.25, 0.2)


# ---------------------------------------------------------------- AI

func _physics_process(delta: float) -> void:
	if not active:
		return
	state_time += delta

	var to_player := player.global_position - global_position
	to_player.y = 0.0
	var dist := to_player.length()
	var spd := float(stats()["speed"])
	var move := Vector3.ZERO

	match state:
		State.WANDER, State.SEEK_CRATE:
			if dist < AGGRO_RANGE:
				_set_state(State.CHASE)
			elif state == State.SEEK_CRATE:
				if not is_instance_valid(crate_target) or crate_target.get_meta("opened", false):
					_pick_goal()
				else:
					var to_crate := crate_target.global_position - global_position
					to_crate.y = 0.0
					if to_crate.length() <= CRATE_REACH:
						var crate := crate_target
						crate_target = null
						reached_crate.emit(crate)
						_pick_goal()
					else:
						move = to_crate.normalized() * (WALK_SPEED + SPEED_PER_POINT * spd)
			else:
				var to_target := wander_target - global_position
				to_target.y = 0.0
				if to_target.length() < 0.8 or state_time > 6.0:
					_pick_goal()
				else:
					move = to_target.normalized() * (WALK_SPEED + SPEED_PER_POINT * spd)
		State.CHASE:
			if dist > GIVE_UP_RANGE:
				_pick_goal()
			elif dist <= ATTACK_RANGE:
				_set_state(State.WINDUP)
				windup_started.emit()
			else:
				move = to_player.normalized() * (CHASE_SPEED + SPEED_PER_POINT * spd)
		State.WINDUP:
			_face(to_player, delta * 3.0)
			if state_time >= WINDUP_TIME:
				_lunge()
				strike.emit()
				_set_state(State.RECOVER)
		State.RECOVER:
			# Back off a little after swinging, so it keeps moving.
			if dist > 0.01:
				move = -to_player.normalized() * WALK_SPEED * 0.5
			if state_time >= ATTACK_COOLDOWN:
				_set_state(State.CHASE)

	velocity.x = move.x
	velocity.z = move.z
	if is_on_floor() and velocity.y <= 0.0:
		velocity.y = 0.0
	else:
		velocity.y -= GRAVITY * delta
	move_and_slide()

	if state != State.WINDUP and state != State.RECOVER and move.length() > 0.1:
		_face(move, delta)

	position.x = clampf(position.x, -map_half, map_half)
	position.z = clampf(position.z, -map_half, map_half)
	var windup := clampf(state_time / WINDUP_TIME, 0.0, 1.0) if state == State.WINDUP else 0.0
	rig.animate(delta, move.length(), CHASE_SPEED, windup)


func _process(delta: float) -> void:
	# Wind-up warning: swell and glow orange, then settle back.
	var target_scale := Vector3.ONE
	var glow := 0.0
	if state == State.WINDUP and active:
		var t := clampf(state_time / WINDUP_TIME, 0.0, 1.0)
		target_scale *= 1.0 + 0.2 * t
		glow = 3.0 * t
	rig.ball.scale = rig.ball.scale.lerp(target_scale, minf(1.0, 15.0 * delta))
	body_mat.emission_energy_multiplier = lerpf(body_mat.emission_energy_multiplier, glow, minf(1.0, 15.0 * delta))


func _set_state(s: State) -> void:
	state = s
	state_time = 0.0


## Next goal: the nearest unopened crate, or a random spot if none are left.
func _pick_goal() -> void:
	crate_target = _nearest_unopened_crate()
	if crate_target:
		_set_state(State.SEEK_CRATE)
	else:
		wander_target = Vector3(rng.randf_range(-map_half, map_half), 0.0, rng.randf_range(-map_half, map_half))
		_set_state(State.WANDER)


func _nearest_unopened_crate() -> Node3D:
	var best: Node3D = null
	var best_d := INF
	for node in get_tree().get_nodes_in_group("crate"):
		var crate := node as Node3D
		if crate == null or crate.get_meta("opened", false):
			continue
		var d := global_position.distance_to(crate.global_position)
		if d < best_d:
			best_d = d
			best = crate
	return best


func _face(dir: Vector3, weight: float) -> void:
	if dir.length() < 0.01:
		return
	rotation.y = lerp_angle(rotation.y, atan2(-dir.x, -dir.z), minf(1.0, 8.0 * weight))


# ---------------------------------------------------------------- visuals

func _build_body() -> void:
	add_child(rig)
	visual = rig
	body_mat = rig.ball_mat
	body_col = CollisionShape3D.new()
	body_col.shape = CapsuleShape3D.new()
	add_child(body_col)
	_fit_body()


## Collision and health bar follow the body's height (it changes when parts swap).
func _fit_body() -> void:
	if body_col == null:
		return
	var cap := body_col.shape as CapsuleShape3D
	cap.radius = rig.radius
	cap.height = maxf(rig.hip_height + rig.radius, rig.radius * 2.0)
	body_col.position.y = cap.height * 0.5
	var bar_y := rig.top_height() + 0.4
	for i in bar_nodes.size():
		bar_nodes[i].position.y = bar_y + (0.5 if bar_nodes[i] == label else 0.0)


func _build_health_bar() -> void:
	var bar_y := rig.top_height() + 0.4

	var bg := MeshInstance3D.new()
	var bg_mesh := QuadMesh.new()
	bg_mesh.size = Vector2(BAR_WIDTH + 0.08, BAR_HEIGHT + 0.08)
	bg.mesh = bg_mesh
	bg.material_override = _bar_material(Color(0.08, 0.08, 0.1, 0.85), 0)
	bg.position.y = bar_y
	add_child(bg)

	var fill := MeshInstance3D.new()
	bar_fill_mesh = QuadMesh.new()
	bar_fill_mesh.size = Vector2(BAR_WIDTH, BAR_HEIGHT)
	fill.mesh = bar_fill_mesh
	bar_fill_mat = _bar_material(Color(0.3, 0.9, 0.35), 1)
	fill.material_override = bar_fill_mat
	fill.position.y = bar_y
	add_child(fill)

	label = Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.font_size = 48
	label.pixel_size = 0.008
	label.outline_size = 10
	label.position.y = bar_y + 0.5
	add_child(label)
	bar_nodes = [bg, fill, label]


## Always faces the camera, ignores lighting, and draws on top of everything.
func _bar_material(color: Color, priority: int) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.render_priority = priority
	mat.albedo_color = color
	return mat


func _flash() -> void:
	var tw := create_tween()
	tw.tween_property(body_mat, "albedo_color", Color.WHITE, 0.06)
	tw.tween_property(body_mat, "albedo_color", variant["color"], 0.2)


func _lunge() -> void:
	var tw := create_tween()
	tw.tween_property(visual, "position:z", -0.7, 0.08)
	tw.tween_property(visual, "position:z", 0.0, 0.2)
