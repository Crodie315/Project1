extends RefCounted
class_name PartLibrary
## Every part the game can hand out. Reads the FBX + JSON files that the Maya
## Part Exporter writes into res://parts/. If there are none yet, it falls back
## to built-in placeholder parts so the game always runs.

const PARTS_DIR := "res://parts/"
const TYPES := ["head", "torso", "arm_L", "arm_R", "leg_L", "leg_R"]
const STYLES := ["robot", "beast", "slime"]
const STAT_KEYS := ["attack", "defense", "health", "speed"]

# Same table as maya_tools/part_exporter.py: base by type, bonus by style.
const TYPE_BASE := {
	"head": {"defense": 2},
	"torso": {"health": 5},
	"arm_L": {"attack": 2},
	"arm_R": {"attack": 2},
	"leg_L": {"speed": 2},
	"leg_R": {"speed": 2},
}
const STYLE_BONUS := {
	"robot": {"defense": 1},
	"beast": {"attack": 1},
	"slime": {"health": 2},
}
const STYLE_COLORS := {
	"robot": Color(0.62, 0.66, 0.72),
	"beast": Color(0.55, 0.36, 0.20),
	"slime": Color(0.35, 0.85, 0.45),
}
# Size and centre offset of each fallback part, in metres (matches the Maya placeholders).
const TYPE_SHAPE := {
	"head": [Vector3(0.36, 0.32, 0.36), Vector3(0, 0.18, 0)],
	"torso": [Vector3(1.05, 0.35, 1.05), Vector3.ZERO],
	"arm_L": [Vector3(0.45, 0.14, 0.14), Vector3(-0.22, 0, 0)],
	"arm_R": [Vector3(0.45, 0.14, 0.14), Vector3(0.22, 0, 0)],
	"leg_L": [Vector3(0.14, 0.35, 0.14), Vector3(0, -0.17, 0)],
	"leg_R": [Vector3(0.14, 0.35, 0.14), Vector3(0, -0.17, 0)],
}

## Each entry: {"type", "style", "attack", "defense", "health", "speed", "path"}
var parts: Array = []
## True when the parts came from Maya exports, false when using the built-in fallback.
var from_files := false


static func default_stats(style: String, part_type: String) -> Dictionary:
	var stats := {"attack": 0, "defense": 0, "health": 0, "speed": 0}
	var base: Dictionary = TYPE_BASE.get(part_type, {})
	for k in base:
		stats[k] += int(base[k])
	var bonus: Dictionary = STYLE_BONUS.get(style, {})
	for k in bonus:
		stats[k] += int(bonus[k])
	return stats


func load_parts() -> void:
	parts.clear()
	var dir := DirAccess.open(PARTS_DIR)
	if dir:
		var seen := {}
		for file in dir.get_files():
			var fname: String = file.trim_suffix(".import")
			if fname.get_extension().to_lower() != "fbx" or seen.has(fname):
				continue
			seen[fname] = true
			var info := _read_info(PARTS_DIR + fname)
			if not info.is_empty():
				parts.append(info)
	from_files = not parts.is_empty()
	# Any part type with no Maya export yet gets built-in placeholders, so every crate can give something.
	for part_type in TYPES:
		if count_from_files(part_type) > 0:
			continue
		for style in STYLES:
			var info := default_stats(style, part_type)
			info["type"] = part_type
			info["style"] = style
			info["path"] = ""
			parts.append(info)


func count_from_files(part_type: String = "") -> int:
	var n := 0
	for info in parts:
		if info["path"] != "" and (part_type == "" or info["type"] == part_type):
			n += 1
	return n


## Reads <name>.json next to the FBX. Falls back to the <style>_<type> file name.
func _read_info(fbx_path: String) -> Dictionary:
	var pieces := fbx_path.get_file().get_basename().split("_", true, 1)
	if pieces.size() != 2:
		return {}
	var info := {"style": pieces[0], "type": pieces[1]}
	var json_path := fbx_path.get_basename() + ".json"
	if FileAccess.file_exists(json_path):
		var data = JSON.parse_string(FileAccess.get_file_as_string(json_path))
		if data is Dictionary:
			info.merge(data, true)
	if not TYPES.has(info["type"]):
		return {}
	var defaults := default_stats(str(info["style"]), str(info["type"]))
	for k in STAT_KEYS:
		info[k] = int(info.get(k, defaults[k]))
	info["path"] = fbx_path
	return info


func random_part(rng: RandomNumberGenerator) -> Dictionary:
	var info: Dictionary = parts[rng.randi_range(0, parts.size() - 1)]
	return info.duplicate()


## The part for one style + type (from Maya if exported, else the built-in stats).
func part_info(style: String, part_type: String) -> Dictionary:
	for info in parts:
		if info["style"] == style and info["type"] == part_type:
			var found: Dictionary = info
			return found.duplicate()
	var made := default_stats(style, part_type)
	made["type"] = part_type
	made["style"] = style
	made["path"] = ""
	return made


## A random part of one type (used so chests can give the parts you're missing).
func random_part_of_type(rng: RandomNumberGenerator, part_type: String) -> Dictionary:
	var options: Array = []
	for info in parts:
		if info["type"] == part_type:
			options.append(info)
	if options.is_empty():
		return random_part(rng)
	var pick: Dictionary = options[rng.randi_range(0, options.size() - 1)]
	return pick.duplicate()


## A new node for this part, ready to attach to a socket.
## Old one-blob placeholder exports (a mesh named <style>_<type>_geo) are swapped for
## the limb shapes below. Your own modelled parts, and parts re-exported with the
## updated Maya builder, are used exactly as exported.
func make_part(info: Dictionary) -> Node3D:
	var path: String = info.get("path", "")
	if path != "":
		var scene := load(path) as PackedScene
		if scene:
			var node := scene.instantiate() as Node3D
			var old_geo := "%s_%s_geo" % [info["style"], info["type"]]
			if node.find_child(old_geo, true, false) == null:
				return node
			node.free()
	return build_limb(str(info["style"]), str(info["type"]))


# ---------------------------------------------------------------- limb shapes
# Same table as maya_tools/part_exporter.py (there in cm, here in metres).
# Each piece: [shape, size, position, z-rotation in degrees, role]
#   shape  "long" = limb segment, "ball" = joint / skull, "block" = hand / foot / plate
#   role   "skin" (style colour), "eye", "dark", "glow"
# Robot builds everything from boxes, beast uses capsules and balls, slime uses blobs.
# Forward is -Z. Sizes are before PART_SCALE in player.gd (arms and legs are drawn 2x).
const LIMBS := {
	"arm_L": [
		["ball", Vector3(0.15, 0.15, 0.15), Vector3(-0.03, 0.0, 0.0), 0.0, "skin"],
		["long", Vector3(0.085, 0.24, 0.085), Vector3(-0.115, -0.075, 0.0), -50.0, "skin"],
		["ball", Vector3(0.095, 0.095, 0.095), Vector3(-0.2, -0.15, 0.0), 0.0, "dark"],
		["long", Vector3(0.075, 0.22, 0.075), Vector3(-0.245, -0.245, 0.0), -25.0, "skin"],
		["block", Vector3(0.1, 0.11, 0.08), Vector3(-0.285, -0.355, 0.0), -25.0, "skin"],
		["block", Vector3(0.035, 0.06, 0.035), Vector3(-0.255, -0.335, -0.055), -25.0, "dark"],
	],
	"leg_L": [
		["ball", Vector3(0.11, 0.11, 0.11), Vector3(0.0, 0.0, 0.0), 0.0, "skin"],
		["long", Vector3(0.1, 0.19, 0.1), Vector3(0.0, -0.09, 0.0), 0.0, "skin"],
		["ball", Vector3(0.085, 0.085, 0.085), Vector3(0.0, -0.185, -0.01), 0.0, "dark"],
		["long", Vector3(0.08, 0.17, 0.08), Vector3(0.0, -0.27, 0.0), 0.0, "skin"],
		["block", Vector3(0.1, 0.055, 0.18), Vector3(0.0, -0.355, -0.045), 0.0, "skin"],
	],
	"head": [
		["long", Vector3(0.1, 0.08, 0.1), Vector3(0.0, 0.03, 0.0), 0.0, "dark"],
		["ball", Vector3(0.3, 0.28, 0.28), Vector3(0.0, 0.19, 0.0), 0.0, "skin"],
		["eye", Vector3(0.065, 0.065, 0.065), Vector3(-0.065, 0.21, -0.125), 0.0, "eye"],
		["eye", Vector3(0.065, 0.065, 0.065), Vector3(0.065, 0.21, -0.125), 0.0, "eye"],
		["block", Vector3(0.1, 0.018, 0.02), Vector3(0.0, 0.12, -0.135), 0.0, "dark"],
	],
	"torso": [
		["block", Vector3(0.66, 0.44, 0.2), Vector3(0.0, 0.06, -0.38), 0.0, "skin"],
		["block", Vector3(0.62, 0.42, 0.2), Vector3(0.0, 0.06, 0.38), 0.0, "skin"],
		["block", Vector3(0.24, 0.16, 0.06), Vector3(-0.15, 0.14, -0.49), 0.0, "dark"],
		["block", Vector3(0.24, 0.16, 0.06), Vector3(0.15, 0.14, -0.49), 0.0, "dark"],
		["block", Vector3(1.04, 0.1, 1.04), Vector3(0.0, -0.22, 0.0), 0.0, "dark"],
	],
}
## Extra pieces per style (ears, antenna, claws...). Mirrored for _R types like the limbs.
const STYLE_EXTRAS := {
	"robot": {
		"head": [
			["long", Vector3(0.02, 0.12, 0.02), Vector3(0.0, 0.38, 0.0), 0.0, "dark"],
			["ball", Vector3(0.05, 0.05, 0.05), Vector3(0.0, 0.45, 0.0), 0.0, "glow"],
		],
	},
	"beast": {
		"head": [
			["ball", Vector3(0.09, 0.13, 0.05), Vector3(-0.12, 0.33, 0.02), 25.0, "dark"],
			["ball", Vector3(0.09, 0.13, 0.05), Vector3(0.12, 0.33, 0.02), -25.0, "dark"],
			["ball", Vector3(0.12, 0.08, 0.1), Vector3(0.0, 0.15, -0.13), 0.0, "skin"],
		],
		"arm_L": [
			["block", Vector3(0.02, 0.05, 0.02), Vector3(-0.3, -0.42, -0.03), -25.0, "dark"],
			["block", Vector3(0.02, 0.05, 0.02), Vector3(-0.3, -0.42, 0.03), -25.0, "dark"],
		],
		"leg_L": [
			["block", Vector3(0.025, 0.025, 0.05), Vector3(-0.03, -0.37, -0.145), 0.0, "dark"],
			["block", Vector3(0.025, 0.025, 0.05), Vector3(0.03, -0.37, -0.145), 0.0, "dark"],
		],
	},
	"slime": {
		"head": [
			["ball", Vector3(0.12, 0.1, 0.12), Vector3(0.0, 0.35, 0.02), 0.0, "skin"],
		],
	},
}


## Arms and legs are built this much thicker than the table (width and depth only).
const LIMB_THICKNESS := 1.35


## Pieces for a style + type. _R types are the _L design mirrored left-to-right.
static func limb_pieces(style: String, part_type: String) -> Array:
	var mirror := part_type.ends_with("_R")
	var base_type := part_type.replace("_R", "_L") if mirror else part_type
	var pieces: Array = []
	pieces.append_array(LIMBS.get(base_type, []))
	var extras: Dictionary = STYLE_EXTRAS.get(style, {})
	pieces.append_array(extras.get(base_type, []))
	if not mirror:
		return pieces
	var out: Array = []
	for p in pieces:
		var pos: Vector3 = p[2]
		out.append([p[0], p[1], Vector3(-pos.x, pos.y, pos.z), -float(p[3]), p[4]])
	return out


func build_limb(style: String, part_type: String) -> Node3D:
	var root := Node3D.new()
	root.name = "%s_%s" % [style, part_type]
	var skin := _style_material(style)
	var dark := skin.duplicate() as StandardMaterial3D
	dark.albedo_color = skin.albedo_color.darkened(0.45)
	for p in limb_pieces(style, part_type):
		var shape: String = p[0]
		var size: Vector3 = p[1]
		if part_type.begins_with("arm") or part_type.begins_with("leg"):
			size = Vector3(size.x * LIMB_THICKNESS, size.y, size.z * LIMB_THICKNESS)
		var role: String = p[4]
		var mi := MeshInstance3D.new()
		mi.mesh = _piece_mesh(style, shape, size)
		if mi.mesh is SphereMesh:
			mi.scale = size  # unit ball stretched to the piece's size
		mi.position = p[2]
		mi.rotation.z = deg_to_rad(float(p[3]))
		match role:
			"dark":
				mi.material_override = dark
			"eye":
				mi.material_override = _eye_material(style)
				if style != "robot":
					_add_pupil(mi)
			"glow":
				mi.material_override = _glow(Color(0.3, 0.9, 1.0))
			_:
				mi.material_override = skin
		root.add_child(mi)
	var socket := Marker3D.new()
	socket.name = "socket_" + part_type
	root.add_child(socket)
	return root


## Robot = boxes, beast = capsules for segments and balls for joints, slime = soft blobs.
static func _piece_mesh(style: String, shape: String, size: Vector3) -> Mesh:
	if shape == "eye":
		if style == "robot":
			var visor := BoxMesh.new()
			visor.size = Vector3(size.x * 1.3, size.y * 0.6, size.z * 0.5)
			return visor
		return _sphere(size)
	if style == "robot":
		var box := BoxMesh.new()
		box.size = size
		return box
	if style == "beast" and shape == "long":
		var cap := CapsuleMesh.new()
		cap.radius = size.x * 0.5
		cap.height = maxf(size.y, size.x)
		return cap
	return _sphere(size)


## A unit ball (1 m across); build_limb scales it to the piece size.
static func _sphere(_size: Vector3) -> Mesh:
	var sm := SphereMesh.new()
	sm.radius = 0.5
	sm.height = 1.0
	sm.radial_segments = 16
	sm.rings = 8
	return sm


func _style_material(style: String) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = STYLE_COLORS.get(style, Color(0.7, 0.7, 0.7))
	match style:
		"robot":
			mat.metallic = 0.75
			mat.roughness = 0.3
		"beast":
			mat.roughness = 0.85
		"slime":
			mat.roughness = 0.08
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color.a = 0.82
			mat.rim_enabled = true
			mat.rim = 0.6
	return mat


static func _eye_material(style: String) -> StandardMaterial3D:
	if style == "robot":
		return _glow(Color(1.0, 0.3, 0.3))
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.98, 0.98, 0.95)
	return mat


static func _glow(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 3.0
	return mat


## Pupil on a unit-ball eye (the eye's scale sizes it).
static func _add_pupil(eye: MeshInstance3D) -> void:
	var pupil := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.25
	sm.height = 0.5
	pupil.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.03, 0.03, 0.05)
	pupil.material_override = mat
	pupil.position = Vector3(0, 0, -0.38)
	eye.add_child(pupil)
