extends Node3D
## A creature body for NPCs and the boss: a coloured ball with sockets where limbs attach
## (the same parts and shapes the player collects) and a procedural walk cycle.
## Loaded with preload() by npc.gd and boss.gd. Place it at the body's feet: build()
## lifts the ball so the feet touch the ground.

## Same proportions as the player (player.gd PART_SCALE), times the body size.
const LIMB_SCALE := {"head": 1.75, "torso": 1.3, "arm_L": 2.2, "arm_R": 2.2, "leg_L": 2.2, "leg_R": 2.2}
const LEG_SWING := 0.7
const ARM_SWING := 0.6
const STRIDE := 2.6
const ARM_REST := 0.4
const STEP_BOB := 0.08

var radius := 0.5
var size := 1.0                  # radius / 0.5 (the player's ball)
var ball: MeshInstance3D
var ball_mat: StandardMaterial3D
var body: Node3D                 # ball + sockets; sits at hip height
var sockets := {}
var rest := {}
var hip_height := 0.5            # ball centre above the feet
var walk_phase := 0.0
var idle_time := 0.0


## body_color: the ball. worn: Array of part info dictionaries to put on.
func build(body_color: Color, r: float, worn: Array, library: PartLibrary) -> void:
	radius = r
	size = r / 0.5
	body = Node3D.new()
	add_child(body)
	ball = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = r
	sphere.height = r * 2.0
	ball.mesh = sphere
	ball_mat = StandardMaterial3D.new()
	ball_mat.albedo_color = body_color
	ball_mat.roughness = 0.45
	ball_mat.rim_enabled = true
	ball_mat.rim = 0.35
	ball_mat.emission_enabled = true
	ball_mat.emission = Color(1.0, 0.55, 0.15)
	ball_mat.emission_energy_multiplier = 0.0
	ball.material_override = ball_mat
	body.add_child(ball)
	var positions := {
		"socket_head": Vector3(0, r, 0),
		"socket_torso": Vector3.ZERO,
		"socket_arm_L": Vector3(-r, 0, 0),
		"socket_arm_R": Vector3(r, 0, 0),
		"socket_leg_L": Vector3(-0.4 * r, -0.9 * r, 0),
		"socket_leg_R": Vector3(0.4 * r, -0.9 * r, 0),
	}
	for socket_name in positions:
		var m := Marker3D.new()
		m.name = socket_name
		m.position = positions[socket_name]
		body.add_child(m)
		sockets[socket_name] = m
		rest[socket_name] = positions[socket_name]
	for info in worn:
		wear(info, library, false)
	_update_height()


## Put a part on (replacing what was in that slot).
func wear(info: Dictionary, library: PartLibrary, refit: bool = true) -> void:
	var part_type := str(info.get("type", ""))
	var m: Marker3D = sockets.get("socket_" + part_type)
	if m == null:
		return
	for old in m.get_children():
		old.queue_free()
	var part := library.make_part(info)
	part.scale = Vector3.ONE * float(LIMB_SCALE.get(part_type, 1.0)) * size
	m.add_child(part)
	if refit:
		_update_height()
		var tw := part.create_tween()
		var full := part.scale
		part.scale = full * 0.05
		tw.tween_property(part, "scale", full, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## Highest point of the body (top of the head), above the feet.
func top_height() -> float:
	var top := radius
	var head: Marker3D = sockets["socket_head"]
	for child in head.get_children():
		if child.is_queued_for_deletion():
			continue
		for node in (child as Node).find_children("*", "MeshInstance3D", true, false):
			var mi := node as MeshInstance3D
			var box := _to_body(mi) * mi.get_aabb()
			top = maxf(top, box.end.y)
	return hip_height + top


## Lift the body so the bottom of the legs touches the ground.
func _update_height() -> void:
	var lowest := -radius
	for socket_name in ["socket_leg_L", "socket_leg_R"]:
		var m: Marker3D = sockets[socket_name]
		var saved := m.rotation
		m.rotation = Vector3.ZERO
		for child in m.get_children():
			if child.is_queued_for_deletion():
				continue
			for node in (child as Node).find_children("*", "MeshInstance3D", true, false):
				var mi := node as MeshInstance3D
				var box := _to_body(mi) * mi.get_aabb()
				lowest = minf(lowest, box.position.y)
		m.rotation = saved
	hip_height = -lowest
	body.position.y = hip_height


## Transform of a node relative to the body (works before the rig is in the scene).
func _to_body(node: Node3D) -> Transform3D:
	var t := node.transform
	var p := node.get_parent() as Node3D
	while p != null and p != body:
		t = p.transform * t
		p = p.get_parent() as Node3D
	return t


## windup 0..1 = arms raised overhead for an attack (the warning).
func animate(delta: float, move_speed: float, max_speed: float, windup: float = 0.0) -> void:
	var k := 1.0 - exp(-14.0 * delta)
	idle_time += delta
	var leg_l := 0.0
	var arm_l := 0.0
	var arm_raise := 0.0
	var bob := 0.0
	var lean := 0.0
	var ratio := clampf(move_speed / maxf(max_speed, 0.1), 0.0, 1.0)
	if ratio > 0.05:
		walk_phase += delta * move_speed * STRIDE / size
		var s := sin(walk_phase)
		leg_l = s * LEG_SWING * ratio
		arm_l = -s * ARM_SWING * ratio
		bob = absf(cos(walk_phase)) * STEP_BOB * ratio * size
		lean = 0.15 * ratio
	else:
		walk_phase = lerpf(walk_phase, roundf(walk_phase / PI) * PI, k)
		bob = sin(idle_time * 2.0) * 0.015 * size
		arm_raise = sin(idle_time * 2.0) * 0.05
	if windup > 0.0:
		arm_raise = lerpf(arm_raise, 2.2, windup)   # arms up over the head
		arm_l = lerpf(arm_l, -0.5, windup)
		lean = lerpf(lean, -0.25, windup)           # rear back

	_turn("socket_leg_L", leg_l, 0.0, k)
	_turn("socket_leg_R", -leg_l, 0.0, k)
	_turn("socket_arm_L", arm_l, ARM_REST - arm_raise, k)
	_turn("socket_arm_R", arm_l if windup > 0.0 else -arm_l, -(ARM_REST - arm_raise), k)
	_turn("socket_head", -lean, 0.0, k)
	var upper := lerpf(ball.position.y, bob, k)
	ball.position.y = upper
	for socket_name in ["socket_head", "socket_torso", "socket_arm_L", "socket_arm_R"]:
		var m: Marker3D = sockets[socket_name]
		m.position.y = (rest[socket_name] as Vector3).y + upper


func _turn(socket_name: String, x: float, z: float, k: float) -> void:
	var m: Marker3D = sockets[socket_name]
	m.rotation.x = lerp_angle(m.rotation.x, x, k)
	m.rotation.z = lerp_angle(m.rotation.z, z, k)
