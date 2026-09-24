"""Build one Illustrator document from an SVG + artboard list: artboards, one layer per top-level
group, layer order, optional locks. Saves an .ai and PNGs of every artboard.
usage: run_doc.py SVG BOARDS_JSON OUT_AI PNG_DIR "Top layer|Next layer|..." ["Locked layer|..."]"""
import json, os, sys
from call import call
svg, bj, out_ai, png_dir, order = sys.argv[1:6]
locked = sys.argv[6].split("|") if len(sys.argv) > 6 and sys.argv[6] else []
meta = json.load(open(bj))
doc = json.loads(call("OpenDocument", {"filePath": os.path.abspath(svg)}))
l, t = doc["artboards"][0]["bounds"][:2]; first = doc["artboards"][0]["name"]
for name, x, y, w, h in meta["boards"]:
    call("CreateArtboard", {"artboardName": name, "left": x + l, "top": y + t, "width": w, "height": h, "backgroundColor": "none"})
call("DeleteArtboard", {"artboardName": first})
base = json.loads(call("GetCanvasStructure", {"maxDepth": 1}))["objects_basic_details"][0]
for child in reversed(base["children"]):
    lid = json.loads(call("CreateLayer", {"layerName": child["name"], "position": "front"}))["uuid"]
    call("MoveObjectsToContainer", {"uuids": [child["uuid"]], "parentID": lid, "position": "front"})
call("DeleteObjects", {"uuids": [base["uuid"]]})
L = {n["name"]: n for n in json.loads(call("GetCanvasStructure", {"maxDepth": 0}))["objects_basic_details"]}
for n in reversed(order.split("|")):                    # first named ends on top
    call("ArrangeArt", {"operation": "bring_to_front", "uuids": [L[n]["uuid"]]})
for n in locked:                                        # lock everything inside these layers
    sub = json.loads(call("GetCanvasStructure", {"maxDepth": 2, "uuids": [L[n]["uuid"]]}))["objects_basic_details"][0]
    kids = [c["uuid"] for g in sub.get("children", []) for c in (g.get("children") or [g])]
    if kids:
        print("lock", n, call("SetAppearance", {"uuids": kids, "locked": True})[:120])
print(call("Export", {"format": "AI", "outputPath": os.path.abspath(out_ai)}))
os.makedirs(png_dir, exist_ok=True)
for i, (name, *_ ) in enumerate(meta["boards"], 1):
    call("Export", {"format": "PNG", "targetType": "ARTBOARD", "artboardIndex": i, "resolution": 72,
                    "backgroundColor": "transparent", "outputPath": os.path.abspath(f"{png_dir}/{name}.png")})
print([n["name"] for n in json.loads(call("GetCanvasStructure", {"maxDepth": 0}))["objects_basic_details"]])
print([a["name"] for a in json.loads(call("ListArtboards", {}))["artboards"]])
