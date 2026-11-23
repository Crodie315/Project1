"""
Composite Units - Nov 10 pipeline test (Maya side).

Builds ONE placeholder part (a left arm), follows the naming contract,
checks the pivot sits on the socket, and exports FBX + JSON into the
Godot project's parts/ folder.

How to run:
    Maya > Windows > General Editors > Script Editor > Python tab
    Paste this file (or: exec(open(r"<path>/export_test_part.py").read()))
    Run it, then pick  composite-units/parts  in the folder dialog.

The full tool with a window and "Export All" comes in week two (Nov 17).
"""
import json
import os

import maya.cmds as cmds
import maya.mel as mel

STYLE = "placeholder"
PART_TYPE = "arm_L"  # contract: head, torso, arm_L, arm_R, leg_L, leg_R
STATS = {"attack": 1, "defense": 0, "health": 0, "speed": 0}


def build_placeholder_arm():
    """Cylinder lying along -X (the character's left) with one end on the origin."""
    root_name = "%s_%s" % (STYLE, PART_TYPE)
    if cmds.objExists(root_name):
        cmds.delete(root_name)

    # Sizes in centimeters: 40 cm long, 10 cm radius (0.4 m in Godot if units convert).
    geo = cmds.polyCylinder(name=PART_TYPE + "_geo", radius=10, height=40, subdivisionsAxis=12)[0]
    cmds.rotate(0, 0, 90, geo)          # Y axis -> lying along X
    cmds.move(-20, 0, 0, geo)           # spans X = -40 .. 0, attach end at the origin
    cmds.makeIdentity(geo, apply=True, translate=True, rotate=True, scale=True)
    cmds.xform(geo, worldSpace=True, pivots=(0, 0, 0))

    # The socket locator: same name as the Marker3D on the Godot player.
    loc = cmds.spaceLocator(name="socket_" + PART_TYPE)[0]
    root = cmds.group(geo, loc, name=root_name)
    cmds.xform(root, worldSpace=True, pivots=(0, 0, 0))
    return root, geo, loc


def check_pivot(geo, loc, tolerance=0.01):
    """The part attaches at its pivot, so the pivot must sit on the socket."""
    pivot = cmds.xform(geo, query=True, worldSpace=True, rotatePivot=True)
    socket = cmds.xform(loc, query=True, worldSpace=True, translation=True)
    dist = sum((a - b) ** 2 for a, b in zip(pivot, socket)) ** 0.5
    if dist > tolerance:
        cmds.warning("Pivot of %s is %.3f units away from %s." % (geo, dist, loc))
        return False
    print("Pivot check OK: %s pivot is on %s" % (geo, loc))
    return True


def export_part(root, out_dir):
    if not cmds.pluginInfo("fbxmaya", query=True, loaded=True):
        cmds.loadPlugin("fbxmaya")

    base = os.path.join(out_dir, root).replace("\\", "/")
    fbx_path = base + ".fbx"
    json_path = base + ".json"

    # Fixed export settings so every part exports the same way.
    mel.eval("FBXResetExport")
    mel.eval("FBXExportUpAxis y")
    mel.eval("FBXExportSmoothingGroups -v true")
    mel.eval("FBXExportTriangulate -v false")
    mel.eval("FBXExportCameras -v false")
    mel.eval("FBXExportLights -v false")
    mel.eval("FBXExportInAscii -v false")

    cmds.select(root, replace=True)
    mel.eval('FBXExport -f "%s" -s' % fbx_path)

    data = {"type": PART_TYPE, "style": STYLE}
    data.update(STATS)
    with open(json_path, "w") as f:
        json.dump(data, f, indent=2)

    print("Exported %s" % fbx_path)
    print("Wrote    %s" % json_path)


def main():
    folder = cmds.fileDialog2(fileMode=3, caption="Pick the Godot project's parts folder")
    if not folder:
        print("Cancelled.")
        return
    root, geo, loc = build_placeholder_arm()
    if not check_pivot(geo, loc):
        return
    export_part(root, folder[0])


main()
