extends CharacterBody3D
class_name Npc
## A red NPC with a body and limbs (see VARIANTS). Wanders the map, and when you
## come close it CHASES you: it raises its arms (the warning) and swipes.
## One hit from a full-bodied player knocks it out (handled in main.gd).

const Rig := preload("res://scripts/rig.gd")

const WALK_SPEED := 2.6      ## wandering
const CHASE_SPEED := 3.9     ## chasing you (your base speed is 5; the boss chases at 4.3)
const AGGRO_RANGE := 8.0     ## starts chasing when you're this close
const GIVE_UP_RANGE := 12.0  ## stops chasing when you get this far away
const ATTACK_RANGE := 1.8    ## starts its swipe this close
const WINDUP_TIME := 0.45    ## arms up for this long before the swipe lands
const ATTACK_COOLDOWN := 1.6
const WANDER_RADIUS := 6.0
const GRAVITY := 22.0

## The looks. Each NPC is one of these; it carries (and can drop) parts it's wearing.
## parts: slot -> style. radius: body size (the player's ball is 0.5).
const VARIANTS := [
	{"name": "Grunt", "color": Color(0.85, 0.22, 0.2), "radius": 0.42,
		"parts": {"head": "robot", "arm_L": "beast", "arm_R": "beast", "leg_L": "robot", "leg_R": "robot"}},
	{"name": "Brute", "color": Color(0.7, 0.15, 0.12), "radius": 0.5,
		"parts": {"head": "beast", "torso": "beast", "arm_L": "beast", "arm_R": "beast", "leg_L": "beast", "leg_R": "beast"}},
	{"name": "Slimeling", "color": Color(0.95, 0.35, 0.3), "radius": 0.36,
		"parts": {"head": "slime", "arm_L": "slime", "arm_R": "slime", "leg_L": "slime", "leg_R": "slime"}},
	{"name": "Scout", "color": Color(0.9, 0.3, 0.15), "radius": 0.38,
		"parts": {"head": "robot", "arm_L": "robot", "arm_R": "slime", "leg_L": "robot", "leg_R": "robot"}},
	{"name": "Mauler", "color": Color(0.75, 0.2, 0.3), "radius": 0.46,
		"parts": {"head": "beast", "torso": "robot", "arm_L": "robot", "arm_R": "beast", "leg_L": "beast", "leg_R": "beast"}},
]

## The swipe landed (main.gd checks range and deals damage).
signal strike(npc: Node3D)

enum State { WANDER, CHASE, WINDUP, RECOVER }

var rng: RandomNumberGenerator
var player: Node3D
var library: PartLibrary
var variant: Dictionary
var map_half := 18.0
var active := true
var rig: Rig
var state := State.WANDER
var state_time := 0.0
var target := Vector3.ZERO
var pause := 0.0


## Call before add_child. Builds the body and collision. Returns the parts it carries.
func setup(random: RandomNumberGenerator, half: float, target_player: Node3D, lib: PartLibrary, variant_index: int) -> Array:
	rng = random
	map_half = half
	player = target_player
	library = lib
	variant = VARIANTS[variant_index % VARIANTS.size()]
	var worn: Array = []
	var slots: Dictionary = variant["parts"]
	for slot in slots:
		worn.append(library.part_info(str(slots[slot]), str(slot)))
	rig = Rig.new()
	add_child(rig)
	rig.build(variant["color"], float(variant["radius"]), worn, library)

	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = float(variant["radius"])
	cap.height = maxf(rig.hip_height + cap.radius, cap.radius * 2.0)
	col.shape = cap
	col.position.y = cap.height * 0.5
	add_child(col)

	# It carries two of the parts it's wearing; knock it out to take one.
	var carried := worn.duplicate()
	carried.shuffle()
	return carried.slice(0, 2)


func _ready() -> void:
	_new_target()
	pause = rng.randf_range(0.0, 1.0)


## A part taken from the player goes onto its body.
func wear(info: Dictionary) -> void:
	rig.wear(info, library)


func _physics_process(delta: float) -> void:
	if not active:
		return
	state_time += delta
	var to_player := player.global_position - global_position
	to_player.y = 0.0
	var dist := to_player.length()
	var move := Vector3.ZERO
	var windup := 0.0

	match state:
		State.WANDER:
			if dist < AGGRO_RANGE:
				_set_state(State.CHASE)
			elif pause > 0.0:
				pause -= delta
			else:
				var to_target := target - global_position
				to_target.y = 0.0
				if to_target.length() < 0.6 or state_time > 7.0:
					_new_target()
					pause = rng.randf_range(0.3, 1.0)
				else:
					move = to_target.normalized() * WALK_SPEED
		State.CHASE:
			if dist > GIVE_UP_RANGE:
				_new_target()
				_set_state(State.WANDER)
			elif dist <= ATTACK_RANGE:
				_set_state(State.WINDUP)
			else:
				move = to_player.normalized() * CHASE_SPEED
		State.WINDUP:
			windup = clampf(state_time / WINDUP_TIME, 0.0, 1.0)
			_face(to_player, delta * 3.0)
			if state_time >= WINDUP_TIME:
				_lunge()
				strike.emit(self)
				_set_state(State.RECOVER)
		State.RECOVER:
			if dist > 0.01:
				move = -to_player.normalized() * WALK_SPEED * 0.4
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
	rig.animate(delta, move.length(), CHASE_SPEED, windup)
	rig.ball_mat.emission_energy_multiplier = 2.5 * windup


func _set_state(s: State) -> void:
	state = s
	state_time = 0.0


func _face(dir: Vector3, weight: float) -> void:
	if dir.length() < 0.01:
		return
	rotation.y = lerp_angle(rotation.y, atan2(-dir.x, -dir.z), minf(1.0, 8.0 * weight))


func _lunge() -> void:
	var tw := rig.create_tween()
	tw.tween_property(rig, "position:z", -0.6, 0.07)
	tw.tween_property(rig, "position:z", 0.0, 0.18)


func _new_target() -> void:
	state_time = 0.0
	target = global_position + Vector3(rng.randf_range(-WANDER_RADIUS, WANDER_RADIUS), 0.0, rng.randf_range(-WANDER_RADIUS, WANDER_RADIUS))
	target.x = clampf(target.x, -map_half, map_half)
	target.z = clampf(target.z, -map_half, map_half)
