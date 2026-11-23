"""
Composite Units - Part Exporter (Maya side of the pipeline).

A window that builds, checks and exports modular body parts for the Godot game.

The contract with Godot (must match on both sides):
  - Part types:  head, torso, arm_L, arm_R, leg_L, leg_R
  - Styles:      robot, beast, slime
  - A part is a group named  <style>_<type>  (e.g. robot_arm_L) containing
    its mesh and a locator named  socket_<type>  at the group's origin.
    The origin is where the part attaches to the body.
  - Export writes  <style>_<type>.fbx  and  <style>_<type>.json  (stats).

How to run (Script Editor, Python tab):
    import sys
    sys.path.append(r"E:\\composite-units\\maya_tools")
    import part_exporter
    part_exporter.show()
"""
import json
import os

import maya.cmds as cmds
import maya.mel as mel

TYPES = ["head", "torso", "arm_L", "arm_R", "leg_L", "leg_R"]
STYLES = ["robot", "beast", "slime"]
STAT_KEYS = ["attack", "defense", "health", "speed"]

# Base stats by part type, plus a bonus by style. The Godot fallback uses the same table.
TYPE_BASE = {
    "head": {"defense": 2},
    "torso": {"health": 5},
    "arm_L": {"attack": 2},
    "arm_R": {"attack": 2},
    "leg_L": {"speed": 2},
    "leg_R": {"speed": 2},
}
STYLE_BONUS = {
    "robot": {"defense": 1},
    "beast": {"attack": 1},
    "slime": {"health": 2},
}
STYLE_COLORS = {
    "robot": (0.62, 0.66, 0.72),
    "beast": (0.55, 0.36, 0.20),
    "slime": (0.35, 0.85, 0.45),
}

# Size (x, y, z) and centre offset of each placeholder part, in centimetres.
# The player's sphere in Godot has a 50 cm radius; sockets sit on its surface.
TYPE_SHAPE = {
    "head": ((36, 32, 36), (0, 18, 0)),
    "torso": ((105, 35, 105), (0, 0, 0)),
    "arm_L": ((45, 14, 14), (-22, 0, 0)),
    "arm_R": ((45, 14, 14), (22, 0, 0)),
    "leg_L": ((14, 35, 14), (0, -17, 0)),
    "leg_R": ((14, 35, 14), (0, -17, 0)),
}

WIN = "cuPartExporterWin"
FOLDER_VAR = "cuPartExportFolder"
TOLERANCE = 0.01


# ---------------------------------------------------------------- stats

def default_stats(style, part_type):
    """Stats for a style + type: the type's base plus the style's bonus."""
    stats = {k: 0 for k in STAT_KEYS}
    for k, v in TYPE_BASE.get(part_type, {}).items():
        stats[k] += v
    for k, v in STYLE_BONUS.get(style, {}).items():
        stats[k] += v
    return stats


def set_stats(root, stats):
    """Store stats on the part's group as attributes, so they live in the scene."""
    for k in STAT_KEYS:
        if not cmds.attributeQuery(k, node=root, exists=True):
            cmds.addAttr(root, longName=k, attributeType="long", keyable=True)
        cmds.setAttr(root + "." + k, int(stats.get(k, 0)))


def get_stats(root):
    """Read stats from the part's group (defaults if the attributes are missing)."""
    style, part_type = split_name(root)
    stats = default_stats(style, part_type)
    for k in STAT_KEYS:
        if cmds.attributeQuery(k, node=root, exists=True):
            stats[k] = cmds.getAttr(root + "." + k)
    return stats


# ---------------------------------------------------------------- naming

def split_name(name):
    """'robot_arm_L' -> ('robot', 'arm_L'). Returns (None, None) if it doesn't fit."""
    short = name.split("|")[-1]
    if "_" not in short:
        return None, None
    style, part_type = short.split("_", 1)
    if part_type not in TYPES:
        return None, None
    return style, part_type


def find_socket(root, part_type):
    """The socket locator directly under the part's group, or None."""
    for child in cmds.listRelatives(root, children=True, type="transform", fullPath=True) or []:
        if child.split("|")[-1].startswith("socket_" + part_type):
            # Full paths: every robot/beast/slime head has a socket_head, so short names clash.
            shapes = cmds.listRelatives(child, shapes=True, fullPath=True) or []
            if any(cmds.nodeType(s) == "locator" for s in shapes):
                return child
    return None


def find_meshes(root):
    """Every mesh transform under the part's group."""
    meshes = []
    for shape in cmds.listRelatives(root, allDescendents=True, type="mesh", fullPath=True) or []:
        meshes.append(cmds.listRelatives(shape, parent=True, fullPath=True)[0])
    return meshes


def find_parts():
    """Every top-level group named <style>_<type>."""
    parts = []
    for node in cmds.ls(assemblies=True, long=True):
        style, part_type = split_name(node)
        if style:
            parts.append(node)
    return parts


# ---------------------------------------------------------------- building

def paint(obj, style):
    """Flat colour per style. One shader per style, made once."""
    shader = "cu_%s_mat" % style
    if not cmds.objExists(shader):
        shader = cmds.shadingNode("lambert", asShader=True, name=shader)
        cmds.setAttr(shader + ".color", *STYLE_COLORS.get(style, (0.7, 0.7, 0.7)), type="double3")
        sg = cmds.sets(renderable=True, noSurfaceShader=True, empty=True, name=shader + "SG")
        cmds.connectAttr(shader + ".outColor", sg + ".surfaceShader")
    cmds.sets(obj, edit=True, forceElement=shader + "SG")


# Recognisable limb shapes, in cm. Same table as scripts/part_library.gd in Godot (metres there).
# Each piece: (shape, size xyz, position xyz, z-rotation degrees, role)
#   shape  "long" = limb segment, "ball" = joint / skull, "block" = hand / foot / plate, "eye"
#   role   "skin" (style colour), "dark", "eye", "glow"
# Robot = boxes, beast and slime = rounded blobs. Forward is -Z. _R parts mirror the _L design.
LIMBS = {
    "arm_L": [
        ("ball", (15, 15, 15), (-3, 0, 0), 0, "skin"),
        ("long", (8.5, 24, 8.5), (-11.5, -7.5, 0), -50, "skin"),
        ("ball", (9.5, 9.5, 9.5), (-20, -15, 0), 0, "dark"),
        ("long", (7.5, 22, 7.5), (-24.5, -24.5, 0), -25, "skin"),
        ("block", (10, 11, 8), (-28.5, -35.5, 0), -25, "skin"),
        ("block", (3.5, 6, 3.5), (-25.5, -33.5, -5.5), -25, "dark"),
    ],
    "leg_L": [
        ("ball", (11, 11, 11), (0, 0, 0), 0, "skin"),
        ("long", (10, 19, 10), (0, -9, 0), 0, "skin"),
        ("ball", (8.5, 8.5, 8.5), (0, -18.5, -1), 0, "dark"),
        ("long", (8, 17, 8), (0, -27, 0), 0, "skin"),
        ("block", (10, 5.5, 18), (0, -35.5, -4.5), 0, "skin"),
    ],
    "head": [
        ("long", (10, 8, 10), (0, 3, 0), 0, "dark"),
        ("ball", (30, 28, 28), (0, 19, 0), 0, "skin"),
        ("eye", (6.5, 6.5, 6.5), (-6.5, 21, -12.5), 0, "eye"),
        ("eye", (6.5, 6.5, 6.5), (6.5, 21, -12.5), 0, "eye"),
        ("block", (10, 1.8, 2), (0, 12, -13.5), 0, "dark"),
    ],
    "torso": [
        ("block", (66, 44, 20), (0, 6, -38), 0, "skin"),
        ("block", (62, 42, 20), (0, 6, 38), 0, "skin"),
        ("block", (24, 16, 6), (-15, 14, -49), 0, "dark"),
        ("block", (24, 16, 6), (15, 14, -49), 0, "dark"),
        ("block", (104, 10, 104), (0, -22, 0), 0, "dark"),
    ],
}
STYLE_EXTRAS = {
    "robot": {"head": [
        ("long", (2, 12, 2), (0, 38, 0), 0, "dark"),
        ("ball", (5, 5, 5), (0, 45, 0), 0, "glow"),
    ]},
    "beast": {
        "head": [
            ("ball", (9, 13, 5), (-12, 33, 2), 25, "dark"),
            ("ball", (9, 13, 5), (12, 33, 2), -25, "dark"),
            ("ball", (12, 8, 10), (0, 15, -13), 0, "skin"),
        ],
        "arm_L": [
            ("block", (2, 5, 2), (-30, -42, -3), -25, "dark"),
            ("block", (2, 5, 2), (-30, -42, 3), -25, "dark"),
        ],
        "leg_L": [
            ("block", (2.5, 2.5, 5), (-3, -37, -14.5), 0, "dark"),
            ("block", (2.5, 2.5, 5), (3, -37, -14.5), 0, "dark"),
        ],
    },
    "slime": {"head": [
        ("ball", (12, 10, 12), (0, 35, 2), 0, "skin"),
    ]},
}
ROLE_COLORS = {"eye": (0.97, 0.97, 0.95), "glow": (0.3, 0.9, 1.0)}


def limb_pieces(style, part_type):
    mirror = part_type.endswith("_R")
    base = part_type.replace("_R", "_L") if mirror else part_type
    pieces = list(LIMBS.get(base, [])) + list(STYLE_EXTRAS.get(style, {}).get(base, []))
    if mirror:
        pieces = [(sh, size, (-pos[0], pos[1], pos[2]), -rot, role) for sh, size, pos, rot, role in pieces]
    return pieces


def paint_color(obj, shader, rgb):
    if not cmds.objExists(shader):
        shader = cmds.shadingNode("lambert", asShader=True, name=shader)
        cmds.setAttr(shader + ".color", *rgb, type="double3")
        sg = cmds.sets(renderable=True, noSurfaceShader=True, empty=True, name=shader + "SG")
        cmds.connectAttr(shader + ".outColor", sg + ".surfaceShader")
    cmds.sets(obj, edit=True, forceElement=shader + "SG")


def _make_piece(style, shape, size, pos, rot_z, name):
    sx, sy, sz = size
    if shape == "eye" and style == "robot":
        geo = cmds.polyCube(width=1, height=1, depth=1, name=name)[0]
        sx, sy, sz = sx * 1.3, sy * 0.6, sz * 0.5
    elif style == "robot":
        geo = cmds.polyCube(width=1, height=1, depth=1, name=name)[0]
    else:
        geo = cmds.polySphere(radius=0.5, subdivisionsAxis=16, subdivisionsHeight=10, name=name)[0]
    cmds.scale(sx, sy, sz, geo)
    cmds.rotate(0, 0, rot_z, geo)
    cmds.move(pos[0], pos[1], pos[2], geo)
    return geo


def build_placeholder(style, part_type, position=(0, 0, 0)):
    """A recognisable part (arm with elbow and hand, leg with knee and foot, head with eyes...)
    built from simple primitives and merged into one mesh named <style>_<type>_limb."""
    name = "%s_%s" % (style, part_type)
    if cmds.objExists(name):
        cmds.delete(name)
    r, g, b = STYLE_COLORS.get(style, (0.7, 0.7, 0.7))
    pieces = []
    for i, (shape, size, pos, rot, role) in enumerate(limb_pieces(style, part_type)):
        geo = _make_piece(style, shape, size, pos, rot, "%s_piece%d" % (name, i))
        if role == "dark":
            paint_color(geo, "cu_%s_dark_mat" % style, (r * 0.55, g * 0.55, b * 0.55))
        elif role in ROLE_COLORS:
            paint_color(geo, "cu_%s_mat" % role, ROLE_COLORS[role])
        else:
            paint(geo, style)
        pieces.append(geo)
    geo = cmds.polyUnite(pieces, name=name + "_limb", constructionHistory=False)[0]
    cmds.xform(geo, worldSpace=True, pivots=(0, 0, 0))

    loc = cmds.spaceLocator(name="tmp_socket")[0]
    root = cmds.group(geo, loc, name=name)
    cmds.xform(root, worldSpace=True, pivots=(0, 0, 0))
    cmds.rename(root + "|" + loc, "socket_" + part_type)
    set_stats(root, default_stats(style, part_type))
    cmds.move(position[0], position[1], position[2], root)
    return root


def build_library():
    """All 3 styles x 6 types, laid out in a grid so you can see them. One undo step."""
    cmds.undoInfo(openChunk=True, chunkName="build_part_library")
    try:
        built = []
        for row, style in enumerate(STYLES):
            for col, part_type in enumerate(TYPES):
                built.append(build_placeholder(style, part_type, (col * 150, 0, row * 150)))
        cmds.select(clear=True)
    finally:
        cmds.undoInfo(closeChunk=True)
    return built


def make_part_from_selection(style, part_type):
    """Turn the selected mesh(es) into a part: group them, add the socket at the origin."""
    sel = cmds.ls(selection=True, type="transform")
    if not sel:
        cmds.warning("Select the mesh you modelled first.")
        return None
    name = "%s_%s" % (style, part_type)
    if cmds.objExists(name):
        cmds.warning("%s already exists. Rename or delete it first." % name)
        return None
    cmds.undoInfo(openChunk=True, chunkName="make_part")
    try:
        for obj in sel:
            cmds.xform(obj, worldSpace=True, pivots=(0, 0, 0))
        loc = cmds.spaceLocator(name="tmp_socket")[0]
        root = cmds.group(sel + [loc], name=name)
        cmds.xform(root, worldSpace=True, pivots=(0, 0, 0))
        cmds.rename(root + "|" + loc, "socket_" + part_type)
        set_stats(root, default_stats(style, part_type))
        cmds.select(root)
    finally:
        cmds.undoInfo(closeChunk=True)
    return root


# ---------------------------------------------------------------- checking

def _distance(a, b):
    return sum((x - y) ** 2 for x, y in zip(a, b)) ** 0.5


def check_part(root):
    """Return a list of problems. An empty list means the part is ready to export."""
    problems = []
    short = root.split("|")[-1]
    style, part_type = split_name(root)
    if not style:
        return ["%s: name must be <style>_<type>, e.g. robot_arm_L." % short]
    if style not in STYLES:
        problems.append("%s: style '%s' is not one of %s." % (short, style, ", ".join(STYLES)))

    socket = find_socket(root, part_type)
    if socket is None:
        problems.append("%s: no locator named socket_%s directly inside it." % (short, part_type))
    else:
        local = cmds.xform(socket, query=True, objectSpace=True, translation=True)
        if _distance(local, (0, 0, 0)) > TOLERANCE:
            problems.append("%s: socket_%s is not at the group's origin." % (short, part_type))

    meshes = find_meshes(root)
    if not meshes:
        problems.append("%s: no mesh inside it." % short)
    root_pivot = cmds.xform(root, query=True, worldSpace=True, rotatePivot=True)
    root_pos = cmds.xform(root, query=True, worldSpace=True, translation=True)
    if _distance(root_pivot, root_pos) > TOLERANCE:
        problems.append("%s: the group's pivot is not at its origin." % short)
    if socket is not None:
        socket_world = cmds.xform(socket, query=True, worldSpace=True, translation=True)
        for mesh in meshes:
            pivot = cmds.xform(mesh, query=True, worldSpace=True, rotatePivot=True)
            if _distance(pivot, socket_world) > TOLERANCE:
                problems.append("%s: pivot of %s is not on the socket." % (short, mesh.split("|")[-1]))
    return problems


# ---------------------------------------------------------------- exporting

def _set_fbx_options():
    if not cmds.pluginInfo("fbxmaya", query=True, loaded=True):
        cmds.loadPlugin("fbxmaya")
    mel.eval("FBXResetExport")
    mel.eval("FBXExportUpAxis y")
    mel.eval("FBXExportSmoothingGroups -v true")
    mel.eval("FBXExportTriangulate -v false")
    mel.eval("FBXExportCameras -v false")
    mel.eval("FBXExportLights -v false")
    mel.eval("FBXExportInAscii -v false")


def export_part(root, folder):
    """Export one part as FBX + JSON. The part is moved to the origin for export, then put back."""
    style, part_type = split_name(root)
    short = root.split("|")[-1]
    base = os.path.join(folder, short).replace("\\", "/")
    position = cmds.xform(root, query=True, worldSpace=True, translation=True)
    cmds.xform(root, worldSpace=True, translation=(0, 0, 0))
    try:
        cmds.select(root, replace=True)
        mel.eval('FBXExport -f "%s.fbx" -s' % base)
    finally:
        cmds.xform(root, worldSpace=True, translation=position)
        cmds.select(clear=True)
    data = {"type": part_type, "style": style}
    data.update(get_stats(root))
    with open(base + ".json", "w") as f:
        json.dump(data, f, indent=2)
    return base + ".fbx"


def export_parts(roots, folder):
    """Check every part, export the good ones, and report. Returns (exported, skipped)."""
    if not folder or not os.path.isdir(folder):
        cmds.warning("Pick the Godot project's parts folder first.")
        return [], []
    _set_fbx_options()
    exported, skipped = [], []
    for root in roots:
        problems = check_part(root)
        if problems:
            skipped.append(root.split("|")[-1])
            for p in problems:
                print("SKIPPED " + p)
            continue
        exported.append(export_part(root, folder))
        print("Exported " + exported[-1])
    msg = "Exported %d part(s), skipped %d." % (len(exported), len(skipped))
    if skipped:
        cmds.warning(msg + " See the Script Editor for why.")
    else:
        print(msg)
    return exported, skipped


# ---------------------------------------------------------------- window

def _ui_style():
    return cmds.optionMenuGrp("cuStyle", query=True, value=True)


def _ui_type():
    return cmds.optionMenuGrp("cuType", query=True, value=True)


def _ui_folder():
    return cmds.textFieldButtonGrp("cuFolder", query=True, text=True)


def _ui_stats():
    return {k: cmds.intFieldGrp("cuStat_" + k, query=True, value1=True) for k in STAT_KEYS}


def _fill_default_stats(*_):
    stats = default_stats(_ui_style(), _ui_type())
    for k in STAT_KEYS:
        cmds.intFieldGrp("cuStat_" + k, edit=True, value1=stats[k])


def _selected_parts():
    roots = []
    for node in cmds.ls(selection=True, long=True) or []:
        path = node.split("|")
        while len(path) > 1:
            candidate = "|".join(path)
            if split_name(candidate)[0] and len(path) == 2:
                roots.append(candidate)
                break
            path = path[:-1]
    return list(dict.fromkeys(roots))


def _on_browse(*_):
    folder = cmds.fileDialog2(fileMode=3, caption="Pick the Godot project's parts folder")
    if folder:
        cmds.textFieldButtonGrp("cuFolder", edit=True, text=folder[0])
        cmds.optionVar(stringValue=(FOLDER_VAR, folder[0]))


def _on_build_one(*_):
    root = build_placeholder(_ui_style(), _ui_type())
    set_stats(root, _ui_stats())
    cmds.select(root)


def _on_build_library(*_):
    built = build_library()
    print("Built %d placeholder parts." % len(built))


def _on_make_from_selection(*_):
    root = make_part_from_selection(_ui_style(), _ui_type())
    if root:
        set_stats(root, _ui_stats())


def _on_apply_stats(*_):
    roots = _selected_parts()
    if not roots:
        cmds.warning("Select a part (a group named <style>_<type>) first.")
        return
    for root in roots:
        set_stats(root, _ui_stats())
    print("Stats set on: " + ", ".join(r.split("|")[-1] for r in roots))


def _on_check(*_):
    roots = _selected_parts() or find_parts()
    if not roots:
        cmds.warning("No parts in the scene.")
        return
    bad = 0
    for root in roots:
        problems = check_part(root)
        if problems:
            bad += 1
            for p in problems:
                print("PROBLEM " + p)
        else:
            print("OK      " + root.split("|")[-1])
    if bad:
        cmds.warning("%d of %d part(s) have problems. See the Script Editor." % (bad, len(roots)))
    else:
        print("All %d part(s) are ready to export." % len(roots))


def _on_export_selected(*_):
    roots = _selected_parts()
    if not roots:
        cmds.warning("Select a part (a group named <style>_<type>) first.")
        return
    export_parts(roots, _ui_folder())


def _on_export_all(*_):
    roots = find_parts()
    if not roots:
        cmds.warning("No parts in the scene. Build the placeholder library first.")
        return
    export_parts(roots, _ui_folder())


def show():
    if cmds.window(WIN, exists=True):
        cmds.deleteUI(WIN)
    size = (440, 520)
    cmds.window(WIN, title="Composite Units - Part Exporter", widthHeight=size)
    cmds.columnLayout(adjustableColumn=True, rowSpacing=6, columnOffset=("both", 10))

    cmds.frameLayout(label="Part", marginWidth=6, marginHeight=6)
    cmds.optionMenuGrp("cuStyle", label="Style", changeCommand=_fill_default_stats)
    for s in STYLES:
        cmds.menuItem(label=s)
    cmds.optionMenuGrp("cuType", label="Type", changeCommand=_fill_default_stats)
    for t in TYPES:
        cmds.menuItem(label=t)
    cmds.setParent("..")

    cmds.frameLayout(label="Stats", marginWidth=6, marginHeight=6)
    for k in STAT_KEYS:
        cmds.intFieldGrp("cuStat_" + k, label=k.capitalize(), value1=0)
    cmds.button(label="Apply stats to selected part", command=_on_apply_stats)
    cmds.setParent("..")

    cmds.frameLayout(label="Build", marginWidth=6, marginHeight=6)
    cmds.button(label="Build one placeholder part", command=_on_build_one)
    cmds.button(label="Build full placeholder library (3 styles x 6 types)", command=_on_build_library)
    cmds.button(label="Make part from selected mesh", command=_on_make_from_selection)
    cmds.setParent("..")

    cmds.frameLayout(label="Export", marginWidth=6, marginHeight=6)
    cmds.textFieldButtonGrp("cuFolder", label="Parts folder", buttonLabel="Browse",
                            text=cmds.optionVar(query=FOLDER_VAR) if cmds.optionVar(exists=FOLDER_VAR) else "",
                            buttonCommand=_on_browse)
    cmds.button(label="Check parts", command=_on_check)
    cmds.button(label="Export selected", command=_on_export_selected)
    cmds.button(label="Export All", height=36, command=_on_export_all)
    cmds.setParent("..")

    _fill_default_stats()
    cmds.showWindow(WIN)
    cmds.window(WIN, edit=True, widthHeight=size)
