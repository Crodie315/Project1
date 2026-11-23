extends CharacterBody3D
class_name Player
## The glowing sphere. Moves with WASD or the on-screen pad, has Marker3D
## sockets that parts from Maya snap onto, and adds up the stats of its parts.

const BASE_SPEED := 5.0
const SPEED_PER_POINT := 0.4
const GRAVITY := 22.0
const JUMP_VELOCITY := 11.0      ## ~2.7 m jump: high enough to land on the boss's head
const JUMP_BUFFER := 0.15        ## a jump pressed just before landing still counts
const INVULNERABLE_TIME := 0.8   ## no damage for this long after being hit
const RADIUS := 0.5

## How much bigger each part type is drawn on the player. Same Maya shape, just scaled
## up from its attach point so arms and legs read clearly from the game camera.
const PART_SCALE := {
	"head": 1.75,
	"torso": 1.3,
	"arm_L": 2.2,
	"arm_R": 2.2,
	"leg_L": 2.2,
	"leg_R": 2.2,
}

# ---- body animation (procedural, works on any part: it turns the sockets = the joints)
const LEG_SWING := 0.65          ## how far legs swing forward / back at full speed (radians)
const ARM_SWING := 0.55          ## arms swing opposite to the legs
const STRIDE := 2.4              ## walk-cycle speed per metre moved (bigger = quicker steps)
const ARM_REST := 0.4            ## arms hang this much closer to the body than modelled
const STEP_BOB := 0.07           ## upper body rises and dips with each step
const LEAN := 0.12               ## head leans forward when running
## Where a held weapon sits, relative to the right shoulder (the hand, before PART_SCALE).
const HAND_OFFSET := Vector3(0.285, -0.355, -0.1)

## Fired when the sphere lands on top of something (main.gd checks for the boss = stomp).
signal landed_on(body: Node)
signal jumped
## Landed after a real fall (for the landing sound and dust ring).
signal landed_hard
## A foot touched down while walking (main.gd puffs a little dust).
signal footstep(pos: Vector3)

## Live HP for real-time fights with the boss. max_hp = 10 + health from parts (set by main.gd).
var hp := 0
var max_hp := 0
var invulnerable := 0.0
## Push from hits, stomps and attack lunges; fades out quickly.
var knock := Vector3.ZERO
var jump_buffer := 0.0
## The collision sphere. It moves down when legs are on, so the body stands on its legs.
var body_col: CollisionShape3D
## How far the legs lift the body off the ground (0 with no legs).
var lift := 0.0
var walk_phase := 0.0
var idle_time := 0.0
## A weapon held in the right hand; follows the arm's swing.
var held_item: Node3D = null

## Half-width of the area the player may walk in (set by main.gd).
var map_half := 19.0
## Direction from the on-screen controller buttons (x = left/right, y = forward/back).
var ui_direction := Vector2.ZERO
## socket name -> Marker3D. Names must match the Maya locators exactly.
var sockets := {}
## part type -> info Dictionary of the part attached there.
var equipped := {}
## Parts that were replaced by a newer one. Kept for battles later.
var bag: Array = []

# Where each socket sits on the sphere. Forward is -Z, left is -X.
const SOCKET_POSITIONS := {
	"socket_head": Vector3(0, 0.5, 0),
	"socket_torso": Vector3(0, 0, 0),
	"socket_arm_L": Vector3(-0.5, 0, 0),
	"socket_arm_R": Vector3(0.5, 0, 0),
	"socket_leg_L": Vector3(-0.2, -0.45, 0),
	"socket_leg_R": Vector3(0.2, -0.45, 0),
}


func _ready() -> void:
	_build_body()
	_build_sockets()


func _build_body() -> void:
	var mesh_inst := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = RADIUS
	sphere.height = RADIUS * 2.0
	mesh_inst.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.9, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.3, 0.85, 1.0)
	mat.emission_energy_multiplier = 2.5
	mesh_inst.material_override = mat
	add_child(mesh_inst)

	var glow := OmniLight3D.new()
	glow.light_color = Color(0.4, 0.9, 1.0)
	glow.omni_range = 3.0
	glow.light_energy = 1.5
	add_child(glow)

	var col := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = RADIUS
	col.shape = shape
	add_child(col)
	body_col = col


func _build_sockets() -> void:
	for socket_name in SOCKET_POSITIONS:
		var marker := Marker3D.new()
		marker.name = socket_name
		marker.position = SOCKET_POSITIONS[socket_name]
		add_child(marker)
		sockets[socket_name] = marker


func _physics_process(delta: float) -> void:
	invulnerable = maxf(0.0, invulnerable - delta)
	jump_buffer = maxf(0.0, jump_buffer - delta)

	var input := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_W): input.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S): input.y += 1.0
	if Input.is_physical_key_pressed(KEY_A): input.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D): input.x += 1.0
	input += ui_direction
	input = input.limit_length(1.0)

	var speed := BASE_SPEED + SPEED_PER_POINT * float(total_stats()["speed"])
	var dir := Vector3(input.x, 0.0, input.y)
	velocity.x = dir.x * speed + knock.x
	velocity.z = dir.z * speed + knock.z
	knock = knock.move_toward(Vector3.ZERO, 25.0 * delta)
	if is_on_floor() and velocity.y <= 0.0:
		velocity.y = 0.0
		if jump_buffer > 0.0:
			velocity.y = JUMP_VELOCITY
			jump_buffer = 0.0
			jumped.emit()
			_squash(Vector3(0.8, 1.25, 0.8))
	else:
		velocity.y -= GRAVITY * delta
	var falling := velocity.y < -0.5
	var fall_speed := -velocity.y
	move_and_slide()
	if falling and fall_speed > 6.0 and is_on_floor():
		landed_hard.emit()
		_squash(Vector3(1.25, 0.75, 1.25))

	# Landed on top of something this frame? (normal pointing up = we hit its top)
	if falling:
		for i in get_slide_collision_count():
			var c := get_slide_collision(i)
			if c.get_normal().y > 0.6:
				landed_on.emit(c.get_collider())

	# Turn to face the way we're moving, so attached parts turn with the body.
	if dir.length() > 0.01:
		var target_angle := atan2(-dir.x, -dir.z)
		rotation.y = lerp_angle(rotation.y, target_angle, 10.0 * delta)

	# Stay on the map.
	position.x = clampf(position.x, -map_half, map_half)
	position.z = clampf(position.z, -map_half, map_half)

	_animate(delta, Vector2(velocity.x, velocity.z).length(), speed)


## Walk cycle, jump / fall poses and idle breathing, made by turning the sockets.
## Rotating a socket swings everything attached to it around the joint.
func _animate(delta: float, move_speed: float, max_speed: float) -> void:
	var leg_l := 0.0         # forward swing of each leg (+ = forward)
	var leg_r := 0.0
	var arm_l := 0.0         # forward swing of each arm
	var arm_r := 0.0
	var arm_raise := 0.0     # arms lifted out to the sides (jumping)
	var bob := 0.0
	var lean := 0.0
	var k := 1.0 - exp(-14.0 * delta)
	idle_time += delta

	if is_on_floor():
		var ratio := clampf(move_speed / maxf(max_speed, 0.1), 0.0, 1.0)
		if ratio > 0.05:
			var before := sin(walk_phase)
			walk_phase += delta * move_speed * STRIDE
			var s := sin(walk_phase)
			leg_l = s * LEG_SWING * ratio
			leg_r = -leg_l
			arm_l = -s * ARM_SWING * ratio
			arm_r = -arm_l
			bob = absf(cos(walk_phase)) * STEP_BOB * ratio
			lean = LEAN * ratio
			if signf(before) != signf(s) and equipped.has("leg_L"):
				footstep.emit(global_position + Vector3(0, -(lift + RADIUS) + 0.05, 0))
		else:
			# Idle: settle the step, breathe, let the arms sway a little.
			walk_phase = lerpf(walk_phase, roundf(walk_phase / PI) * PI, k)
			bob = sin(idle_time * 2.2) * 0.015
			arm_raise = sin(idle_time * 2.2) * 0.04
	elif velocity.y > 0.0:
		# Going up: knees up, arms thrown up and out.
		leg_l = 0.75
		leg_r = 0.35
		arm_raise = 0.9
		arm_l = -0.3
		arm_r = -0.3
	else:
		# Coming down: legs reach for the ground, arms out for balance.
		leg_l = 0.25
		leg_r = -0.2
		arm_raise = 0.55

	_turn_x("socket_leg_L", leg_l, k)
	_turn_x("socket_leg_R", leg_r, k)
	_turn_arm("socket_arm_L", arm_l, ARM_REST - arm_raise, k)
	_turn_arm("socket_arm_R", arm_r, -(ARM_REST - arm_raise), k)
	_turn_x("socket_head", -lean, k)

	# Upper body (ball, head, torso, arms) bobs with the steps; legs stay planted.
	var ball := get_child(0) as Node3D
	ball.position.y = lerpf(ball.position.y, bob, k)
	for socket_name in ["socket_head", "socket_torso", "socket_arm_L", "socket_arm_R"]:
		var m: Marker3D = sockets[socket_name]
		m.position.y = SOCKET_POSITIONS[socket_name].y + ball.position.y

	if is_instance_valid(held_item):
		var shoulder: Marker3D = sockets["socket_arm_R"]
		var hand := HAND_OFFSET * float(PART_SCALE.get("arm_R", 1.0))
		held_item.transform = shoulder.transform * Transform3D(Basis(), hand)


func _turn_x(socket_name: String, angle: float, k: float) -> void:
	var m: Marker3D = sockets[socket_name]
	m.rotation.x = lerp_angle(m.rotation.x, angle, k)


func _turn_arm(socket_name: String, swing: float, out: float, k: float) -> void:
	var m: Marker3D = sockets[socket_name]
	m.rotation.x = lerp_angle(m.rotation.x, swing, k)
	m.rotation.z = lerp_angle(m.rotation.z, out, k)


## Attach a part and record its stats. If the socket already had a part,
## the old one goes into the bag. Returns the replaced part's info, or {}.
func equip(part: Node3D, info: Dictionary) -> Dictionary:
	var part_type: String = info.get("type", "")
	var socket_name := "socket_" + part_type
	if not sockets.has(socket_name):
		part.queue_free()
		return {}
	var old: Dictionary = {}
	if equipped.has(part_type):
		old = equipped[part_type]
		bag.append(old)
	attach_part(part, socket_name)
	equipped[part_type] = info
	_update_leg_lift()
	return old


## Take one random attached part off (it was lost in a battle). Returns its info, or {}.
func remove_random_part(rng: RandomNumberGenerator) -> Dictionary:
	if equipped.is_empty():
		return {}
	var types: Array = equipped.keys()
	var part_type: String = types[rng.randi_range(0, types.size() - 1)]
	var info: Dictionary = equipped[part_type]
	equipped.erase(part_type)
	var marker: Marker3D = sockets["socket_" + part_type]
	for child in marker.get_children():
		child.queue_free()
	_update_leg_lift()
	return info


## Take a spare of this type out of the bag, if there is one. Returns its info, or {}.
func take_spare(part_type: String) -> Dictionary:
	for i in bag.size():
		var info: Dictionary = bag[i]
		if info["type"] == part_type:
			bag.remove_at(i)
			return info
	return {}


## Quick squash-and-stretch of the glowing ball (jumping, landing).
func _squash(amount: Vector3) -> void:
	var mesh_inst := get_child(0) as Node3D
	var tw := create_tween()
	tw.tween_property(mesh_inst, "scale", amount, 0.06)
	tw.tween_property(mesh_inst, "scale", Vector3.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## Space / Jump button. Buffered so a press just before landing still jumps.
func request_jump() -> void:
	jump_buffer = JUMP_BUFFER


## After a stomp: bounce up and off to the side, so you don't land on the same spot again.
func bounce(away: Vector3) -> void:
	velocity.y = JUMP_VELOCITY * 0.8
	knock = away.normalized() * 6.0


## Short forward shove when attacking.
func push(dir: Vector3, force: float) -> void:
	knock = dir.normalized() * force


## Real-time hit from the boss: lose HP, get knocked back, blink invulnerable.
func take_hit(amount: int, from_dir: Vector3) -> void:
	hp = maxi(0, hp - amount)
	invulnerable = INVULNERABLE_TIME
	knock = from_dir.normalized() * 9.0
	velocity.y = 5.0
	flash()


## Called whenever parts change. Gaining max HP also heals by the same amount.
func set_max_hp(new_max: int) -> void:
	if new_max > max_hp:
		hp += new_max - max_hp
	max_hp = new_max
	hp = clampi(hp, 0, max_hp)


func heal_full() -> void:
	hp = max_hp


## Quick red flash on the sphere when it takes a hit.
func flash() -> void:
	var mesh_inst := get_child(0) as MeshInstance3D
	var mat := mesh_inst.material_override as StandardMaterial3D
	var tw := create_tween()
	tw.tween_property(mat, "emission", Color(1.0, 0.2, 0.2), 0.08)
	tw.tween_property(mat, "emission", Color(0.3, 0.85, 1.0), 0.3)


## Sum of the stats of every attached part.
func total_stats() -> Dictionary:
	var total := {"attack": 0, "defense": 0, "health": 0, "speed": 0}
	for info in equipped.values():
		for k in total.keys():
			total[k] += int(info.get(k, 0))
	return total


## Snap a part onto a socket: add_child on the marker + reset transform.
func attach_part(part: Node3D, socket_name: String) -> bool:
	if not sockets.has(socket_name):
		return false
	var marker: Marker3D = sockets[socket_name]
	for old in marker.get_children():
		old.queue_free()
	marker.add_child(part)
	part.position = Vector3.ZERO
	part.rotation = Vector3.ZERO

	# Safety net for the cm -> m hand-off: a part over 5 m is almost surely still in cm.
	if mesh_size(part).length() > 5.0:
		part.scale *= 0.01
		push_warning("%s looked 100x too big; scaled it to metres." % part.name)

	# Draw it bigger (shape unchanged). Scaling is around the part's origin = its attach point.
	part.scale *= float(PART_SCALE.get(socket_name.trim_prefix("socket_"), 1.0))

	# If the FBX still contains its Maya socket locator, line that point up with the marker.
	var own_socket := part.find_child(socket_name, true, false) as Node3D
	if own_socket == null:
		own_socket = part.find_child("socket_*", true, false) as Node3D
	if own_socket:
		part.global_position += marker.global_position - own_socket.global_position
	return true


## Bigger legs reach below the sphere. Move the collision sphere down to the bottom of
## the legs, so the body stands on its feet instead of the legs sinking into the floor.
func _update_leg_lift() -> void:
	var lowest := -RADIUS
	# Measure with the legs standing straight (not mid-step).
	var saved := {}
	for socket_name in ["socket_leg_L", "socket_leg_R"]:
		var leg: Marker3D = sockets[socket_name]
		saved[socket_name] = leg.rotation
		leg.rotation = Vector3.ZERO
	var to_local := global_transform.affine_inverse()
	for socket_name in ["socket_leg_L", "socket_leg_R"]:
		var marker: Marker3D = sockets[socket_name]
		for child in marker.get_children():
			if child.is_queued_for_deletion():
				continue
			for node in child.find_children("*", "MeshInstance3D", true, false):
				var mi := node as MeshInstance3D
				var box: AABB = to_local * mi.global_transform * mi.get_aabb()
				lowest = minf(lowest, box.position.y)
	for socket_name in saved:
		(sockets[socket_name] as Marker3D).rotation = saved[socket_name]
	var new_lift := -lowest - RADIUS
	position.y += new_lift - lift
	lift = new_lift
	body_col.position.y = -lift


## World-space size of all meshes under a node (the node must be in the scene tree).
static func mesh_size(node: Node3D) -> Vector3:
	var box := AABB()
	var first := true
	for child in node.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		var b := mi.global_transform * mi.get_aabb()
		if first:
			box = b
			first = false
		else:
			box = box.merge(b)
	return box.size
