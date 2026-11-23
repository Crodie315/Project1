extends RefCounted
## Loaded in main.gd as ArtKit (preload), so it works without a global class name.
## Look of the game, all built in code (no texture or model files needed):
## sky and lighting, the arena, crate / NPC looks, particle bursts and the UI theme.
## Colours and sizes are grouped at the top so they're easy to restyle.

# ---------------------------------------------------------------- palette
const SKY_TOP := Color(0.11, 0.13, 0.32)
const SKY_HORIZON := Color(0.78, 0.48, 0.42)
const GROUND_BOTTOM := Color(0.05, 0.05, 0.08)
const TILE_A := Color(0.27, 0.30, 0.37)
const TILE_B := Color(0.24, 0.27, 0.33)
const GRID_GLOW := Color(0.25, 0.75, 0.95)
const WALL_COLOR := Color(0.16, 0.17, 0.22)
const ACCENT := Color(0.3, 0.85, 1.0)        # cyan, matches the player
const WOOD := Color(0.70, 0.46, 0.22)
const WOOD_DARK := Color(0.36, 0.22, 0.10)
const UI_BG := Color(0.07, 0.08, 0.12, 0.86)
const UI_BORDER := Color(0.3, 0.85, 1.0, 0.55)

const GROUND_SHADER := """
shader_type spatial;
uniform vec3 color_a : source_color;
uniform vec3 color_b : source_color;
uniform vec3 grid_color : source_color;
uniform float tile = 2.0;
uniform float grid_strength = 1.0;
varying vec3 world_pos;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 cell = floor(world_pos.xz / tile);
	vec3 c = mix(color_a, color_b, mod(cell.x + cell.y, 2.0));
	c *= 0.9 + 0.2 * hash(cell);
	vec2 f = fract(world_pos.xz / tile);
	float edge = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
	float line = (1.0 - smoothstep(0.0, 0.025, edge)) * grid_strength;
	ALBEDO = mix(c, grid_color * 0.6, line * 0.5);
	EMISSION = grid_color * line * 0.35;
	ROUGHNESS = 0.85;
	METALLIC = 0.1;
}
"""


# ---------------------------------------------------------------- world

## Sky, sun, tone mapping, ambient occlusion, glow and a little fog.
static func build_environment(parent: Node) -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = SKY_TOP
	sky_mat.sky_horizon_color = SKY_HORIZON
	sky_mat.ground_horizon_color = SKY_HORIZON.darkened(0.4)
	sky_mat.ground_bottom_color = GROUND_BOTTOM
	sky_mat.sun_angle_max = 20.0
	var sky := Sky.new()
	sky.sky_material = sky_mat

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.7
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.05
	env.ssao_enabled = true
	env.ssao_radius = 1.2
	env.ssao_intensity = 1.6
	env.glow_enabled = true
	env.glow_intensity = 0.9
	env.glow_bloom = 0.08
	env.glow_hdr_threshold = 0.9
	env.fog_enabled = true
	env.fog_light_color = SKY_HORIZON.lerp(SKY_TOP, 0.5)
	env.fog_density = 0.008
	env.fog_sky_affect = 0.3
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.12
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	parent.add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42, 40, 0)
	sun.light_color = Color(1.0, 0.9, 0.8)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	sun.shadow_blur = 1.5
	sun.directional_shadow_max_distance = 60.0
	parent.add_child(sun)


## Tiled arena floor with a glowing grid, low walls with light strips, corner
## pillars, and rocks / crystals scattered outside the walls.
static func build_arena(parent: Node, map_size: float, rng: RandomNumberGenerator) -> void:
	var half := map_size * 0.5

	# Arena floor (with collision).
	var ground := StaticBody3D.new()
	ground.name = "Ground"
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(map_size, map_size)
	floor_mesh.mesh = plane
	floor_mesh.material_override = _ground_material(TILE_A, TILE_B, 1.0)
	ground.add_child(floor_mesh)
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(map_size, 1, map_size)
	col.shape = box
	col.position = Vector3(0, -0.5, 0)
	ground.add_child(col)
	parent.add_child(ground)

	# Wasteland beyond the walls.
	var outer := MeshInstance3D.new()
	var outer_plane := PlaneMesh.new()
	outer_plane.size = Vector2(240, 240)
	outer.mesh = outer_plane
	outer.position.y = -0.02
	outer.material_override = _ground_material(Color(0.2, 0.17, 0.2), Color(0.18, 0.15, 0.18), 0.0)
	parent.add_child(outer)

	# Walls.
	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_color = WALL_COLOR
	wall_mat.metallic = 0.5
	wall_mat.roughness = 0.45
	var strip_mat := _glow_material(ACCENT, 3.0)
	var t := 0.6
	var length := map_size + t * 2.0
	for side in 4:
		var wall := StaticBody3D.new()
		var along_x := side < 2
		var sgn := 1.0 if side % 2 == 0 else -1.0
		wall.position = Vector3(0, 0, sgn * (half + t * 0.5)) if along_x else Vector3(sgn * (half + t * 0.5), 0, 0)
		var size := Vector3(length, 1.0, t) if along_x else Vector3(t, 1.0, length)
		var wm := MeshInstance3D.new()
		var wbox := BoxMesh.new()
		wbox.size = size
		wm.mesh = wbox
		wm.position.y = 0.5
		wm.material_override = wall_mat
		wall.add_child(wm)
		var strip := MeshInstance3D.new()
		var sbox := BoxMesh.new()
		sbox.size = Vector3(size.x * 0.999, 0.06, size.z + 0.02)
		strip.mesh = sbox
		strip.position.y = 0.82
		strip.material_override = strip_mat
		wall.add_child(strip)
		var wc := CollisionShape3D.new()
		var wshape := BoxShape3D.new()
		wshape.size = Vector3(size.x, 3.0, size.z)
		wc.shape = wshape
		wc.position.y = 1.5
		wall.add_child(wc)
		parent.add_child(wall)

	# Corner pillars with glowing orbs.
	for cx in [-1.0, 1.0]:
		for cz in [-1.0, 1.0]:
			_pillar(parent, Vector3(cx * (half + t * 0.5), 0, cz * (half + t * 0.5)))

	# Rocks and crystals outside the walls.
	var rock_mat := StandardMaterial3D.new()
	rock_mat.albedo_color = Color(0.32, 0.28, 0.32)
	rock_mat.roughness = 0.95
	var crystal_mat := _glow_material(Color(0.7, 0.35, 1.0), 2.0)
	crystal_mat.albedo_color = Color(0.6, 0.3, 0.95)
	for i in 70:
		var pos := _outside_spot(rng, half + 2.0, half + 30.0)
		var mi := MeshInstance3D.new()
		if i % 5 == 0:
			var prism := PrismMesh.new()
			prism.size = Vector3(0.6, 1.0, 0.6)
			mi.mesh = prism
			mi.material_override = crystal_mat
			var s := rng.randf_range(1.0, 2.6)
			mi.scale = Vector3(s * 0.6, s * rng.randf_range(1.2, 2.0), s * 0.6)
			mi.position = pos + Vector3(0, mi.scale.y * 0.45, 0)
			mi.rotation = Vector3(rng.randf_range(-0.3, 0.3), rng.randf() * TAU, rng.randf_range(-0.3, 0.3))
		else:
			var rock := SphereMesh.new()
			rock.radial_segments = 7
			rock.rings = 4
			mi.mesh = rock
			mi.material_override = rock_mat
			var s := rng.randf_range(0.8, 3.2)
			mi.scale = Vector3(s * rng.randf_range(0.8, 1.4), s * rng.randf_range(0.5, 0.9), s * rng.randf_range(0.8, 1.4))
			mi.position = pos + Vector3(0, mi.scale.y * 0.15, 0)
			mi.rotation.y = rng.randf() * TAU
		parent.add_child(mi)


static func _outside_spot(rng: RandomNumberGenerator, min_d: float, max_d: float) -> Vector3:
	for attempt in 30:
		var p := Vector3(rng.randf_range(-max_d, max_d), 0, rng.randf_range(-max_d, max_d))
		if maxf(absf(p.x), absf(p.z)) >= min_d:
			return p
	return Vector3(max_d, 0, max_d)


static func _pillar(parent: Node, pos: Vector3) -> void:
	var root := Node3D.new()
	root.position = pos
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.45
	cyl.bottom_radius = 0.6
	cyl.height = 3.0
	mi.mesh = cyl
	mi.position.y = 1.5
	var mat := StandardMaterial3D.new()
	mat.albedo_color = WALL_COLOR.lightened(0.1)
	mat.metallic = 0.5
	mat.roughness = 0.4
	mi.material_override = mat
	root.add_child(mi)
	var orb := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.35
	sphere.height = 0.7
	orb.mesh = sphere
	orb.position.y = 3.4
	orb.material_override = _glow_material(ACCENT, 4.0)
	root.add_child(orb)
	var light := OmniLight3D.new()
	light.light_color = ACCENT
	light.omni_range = 7.0
	light.light_energy = 1.2
	light.position.y = 3.4
	root.add_child(light)
	parent.add_child(root)


static func _ground_material(a: Color, b: Color, grid: float) -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = GROUND_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("color_a", a)
	mat.set_shader_parameter("color_b", b)
	mat.set_shader_parameter("grid_color", GRID_GLOW)
	mat.set_shader_parameter("grid_strength", grid)
	return mat


static func _glow_material(color: Color, energy: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = energy
	return mat


# ---------------------------------------------------------------- props

## A treasure chest: wooden base, rounded lid on a hinge at the back, iron bands,
## a gold lock at the front (+Z, facing the camera) and a floating gold "?" above it.
## Returns {"visual", "lid" (hinge pivot), "marker", "light"}.
static func make_chest() -> Dictionary:
	var visual := Node3D.new()
	var wood := StandardMaterial3D.new()
	wood.albedo_color = WOOD
	wood.roughness = 0.8
	var iron := StandardMaterial3D.new()
	iron.albedo_color = Color(0.22, 0.22, 0.26)
	iron.metallic = 0.8
	iron.roughness = 0.35
	var gold := StandardMaterial3D.new()
	gold.albedo_color = Color(1.0, 0.78, 0.25)
	gold.metallic = 1.0
	gold.roughness = 0.25

	var w := 0.95
	var h := 0.55
	var d := 0.65
	# Base box.
	_box_piece(visual, Vector3(w, h, d), Vector3(0, h * 0.5, 0), wood)
	# Darker wood rim along the top edge.
	_box_piece(visual, Vector3(w + 0.02, 0.06, d + 0.02), Vector3(0, h - 0.03, 0), _darker(wood))
	# Iron bands and corners on the base.
	for sx in [-1.0, 1.0]:
		_box_piece(visual, Vector3(0.07, h + 0.01, d + 0.03), Vector3(sx * w * 0.3, h * 0.5, 0), iron)
		_box_piece(visual, Vector3(0.06, h + 0.02, 0.06), Vector3(sx * (w * 0.5 - 0.02), h * 0.5, d * 0.5 - 0.02), iron)
	# Gold lock plate on the front.
	_box_piece(visual, Vector3(0.16, 0.18, 0.05), Vector3(0, h - 0.1, d * 0.5 + 0.02), gold)

	# Lid: a half-cylinder (CSG: cylinder minus its lower half) on a hinge at the back edge.
	var lid := Node3D.new()
	lid.position = Vector3(0, h, -d * 0.5)
	visual.add_child(lid)
	var dome := CSGCombiner3D.new()
	dome.position = Vector3(0, 0, d * 0.5)
	lid.add_child(dome)
	var r := d * 0.5
	_csg_half(dome, r, w, wood)
	for sx in [-1.0, 1.0]:
		_csg_half(dome, r + 0.015, 0.07, iron, sx * w * 0.3)
	var cut := CSGBox3D.new()
	cut.operation = CSGShape3D.OPERATION_SUBTRACTION
	cut.size = Vector3(w + 0.4, r + 0.1, d + 0.4)
	cut.position.y = -(r + 0.1) * 0.5
	dome.add_child(cut)
	# Hasp hanging from the lid over the lock.
	_box_piece(dome, Vector3(0.1, 0.12, 0.04), Vector3(0, 0.02, r + 0.02), gold)

	# Warm light that flares up when it opens.
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.8, 0.35)
	light.omni_range = 4.0
	light.light_energy = 0.0
	light.position.y = 0.9
	visual.add_child(light)

	var marker := Label3D.new()
	marker.text = "?"
	marker.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	marker.font_size = 96
	marker.pixel_size = 0.008
	marker.outline_size = 14
	marker.modulate = Color(1.6, 1.25, 0.35)  # above 1.0 so it glows
	marker.position.y = 1.6
	visual.add_child(marker)
	var tw := marker.create_tween().set_loops()
	tw.tween_property(marker, "position:y", 1.8, 0.6).set_trans(Tween.TRANS_SINE)
	tw.tween_property(marker, "position:y", 1.6, 0.6).set_trans(Tween.TRANS_SINE)
	return {"visual": visual, "lid": lid, "marker": marker, "light": light}


## Opening animation: the chest rattles, the lid swings open, gold light and sparks burst out.
static func open_chest(parent: Node, chest: Node3D) -> void:
	var visual: Node3D = chest.get_meta("visual")
	var lid: Node3D = chest.get_meta("lid")
	var marker: Node3D = chest.get_meta("marker")
	var light: OmniLight3D = chest.get_meta("light")
	marker.visible = false
	var tw := visual.create_tween()
	tw.tween_property(visual, "rotation:z", 0.08, 0.05)
	tw.tween_property(visual, "rotation:z", -0.08, 0.07)
	tw.tween_property(visual, "rotation:z", 0.05, 0.06)
	tw.tween_property(visual, "rotation:z", 0.0, 0.05)
	tw.tween_property(lid, "rotation:x", deg_to_rad(-110.0), 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(light, "light_energy", 4.0, 0.15)
	tw.tween_callback(func() -> void:
		burst(parent, chest.global_position + Vector3(0, 0.8, 0), Color(1.0, 0.8, 0.3), 26, 5.0)
	)
	tw.tween_property(light, "light_energy", 0.6, 0.8)


static func _box_piece(parent: Node3D, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.material_override = mat
	parent.add_child(mi)
	return mi


static func _csg_half(dome: CSGCombiner3D, radius: float, length: float, mat: Material, x: float = 0.0) -> void:
	var cyl := CSGCylinder3D.new()
	cyl.radius = radius
	cyl.height = length
	cyl.sides = 20
	cyl.rotation.z = PI * 0.5  # axis along X
	cyl.position.x = x
	cyl.material = mat
	dome.add_child(cyl)


static func _darker(mat: StandardMaterial3D) -> StandardMaterial3D:
	var m := mat.duplicate() as StandardMaterial3D
	m.albedo_color = mat.albedo_color.darkened(0.35)
	return m


## Cartoon eyes on the front of an NPC capsule (child of its mesh).
static func add_eyes(mesh: Node3D, height: float, forward: float, size: float) -> void:
	var white := StandardMaterial3D.new()
	white.albedo_color = Color(0.98, 0.98, 0.98)
	var black := StandardMaterial3D.new()
	black.albedo_color = Color(0.03, 0.03, 0.05)
	for sx in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		var es := SphereMesh.new()
		es.radius = size
		es.height = size * 2.0
		eye.mesh = es
		eye.material_override = white
		eye.position = Vector3(sx * size * 1.45, height, -forward)
		mesh.add_child(eye)
		var pupil := MeshInstance3D.new()
		var ps := SphereMesh.new()
		ps.radius = size * 0.5
		ps.height = size
		pupil.mesh = ps
		pupil.material_override = black
		pupil.position = Vector3(0, 0, -size * 0.7)
		eye.add_child(pupil)


# ---------------------------------------------------------------- effects

## A one-shot burst of glowing bits (hits, knock-outs, crates, pickups).
static func burst(parent: Node, pos: Vector3, color: Color, amount: int = 18, speed: float = 5.0, size: float = 0.09, lifetime: float = 0.55) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = amount
	p.lifetime = lifetime
	p.direction = Vector3.UP
	p.spread = 180.0
	p.initial_velocity_min = speed * 0.4
	p.initial_velocity_max = speed
	p.gravity = Vector3(0, -9.0, 0)
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.2
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 1.0))
	curve.add_point(Vector2(1.0, 0.0))
	p.scale_amount_curve = curve
	var mesh := SphereMesh.new()
	mesh.radius = size
	mesh.height = size * 2.0
	mesh.radial_segments = 6
	mesh.rings = 3
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(color.r * 2.0, color.g * 2.0, color.b * 2.0)  # over 1.0 = glows
	mesh.material = mat
	p.mesh = mesh
	parent.add_child(p)
	p.global_position = pos
	p.emitting = true
	parent.get_tree().create_timer(lifetime + 0.3).timeout.connect(p.queue_free)


## A flat ring that expands and fades (stomps, boss strikes, landing).
static func ring(parent: Node, pos: Vector3, color: Color, radius: float = 2.5, time: float = 0.35) -> void:
	var mi := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.85
	torus.outer_radius = 1.0
	mi.mesh = torus
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(color.r * 1.6, color.g * 1.6, color.b * 1.6, 0.9)
	mi.material_override = mat
	parent.add_child(mi)
	mi.global_position = pos + Vector3(0, 0.06, 0)
	mi.scale = Vector3(0.2, 0.1, 0.2)
	var tw := mi.create_tween().set_parallel(true)
	tw.tween_property(mi, "scale", Vector3(radius, 0.1, radius), time).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color:a", 0.0, time)
	tw.chain().tween_callback(mi.queue_free)


# ---------------------------------------------------------------- UI theme

static func make_theme() -> Theme:
	var theme := Theme.new()
	theme.default_font_size = 18

	var panel := _box(UI_BG, 12, UI_BORDER, 1)
	panel.content_margin_left = 14
	panel.content_margin_right = 14
	panel.content_margin_top = 10
	panel.content_margin_bottom = 10
	theme.set_stylebox("panel", "PanelContainer", panel)

	theme.set_stylebox("normal", "Button", _box(Color(0.12, 0.15, 0.22, 0.92), 10, UI_BORDER, 1))
	theme.set_stylebox("hover", "Button", _box(Color(0.17, 0.24, 0.34, 0.95), 10, ACCENT, 2))
	theme.set_stylebox("pressed", "Button", _box(Color(0.1, 0.42, 0.55, 0.95), 10, ACCENT, 2))
	theme.set_stylebox("disabled", "Button", _box(Color(0.1, 0.1, 0.13, 0.6), 10, Color(1, 1, 1, 0.08), 1))
	theme.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	theme.set_color("font_color", "Button", Color(0.92, 0.97, 1.0))
	theme.set_color("font_hover_color", "Button", Color(1, 1, 1))
	theme.set_color("font_pressed_color", "Button", Color(1, 1, 1))
	theme.set_color("font_disabled_color", "Button", Color(1, 1, 1, 0.3))

	theme.set_color("font_color", "Label", Color(0.93, 0.96, 1.0))
	theme.set_color("font_outline_color", "Label", Color(0, 0, 0, 0.8))
	theme.set_constant("outline_size", "Label", 4)
	return theme


static func _box(bg: Color, radius: int, border: Color, border_w: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.border_color = border
	sb.set_border_width_all(border_w)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = 4
	return sb
