"""Open the layout SVG in Illustrator, make named artboards and layers, save .ai, export PNGs."""
import json, os
from call import call
SVG = os.path.abspath("greenroom-logo-candidates-v12.svg")
meta = json.load(open("boards.json"))
doc = json.loads(call("OpenDocument", {"filePath": SVG}))
l, t = doc["artboards"][0]["bounds"][:2]
first = doc["artboards"][0]["name"]
for name, x, y, w, h in meta["boards"]:
    call("CreateArtboard", {"artboardName": name, "left": x + l, "top": y + t, "width": w, "height": h, "backgroundColor": "none"})
call("DeleteArtboard", {"artboardName": first})
st = json.loads(call("GetCanvasStructure", {"maxDepth": 1}))["objects_basic_details"]
base = st[0]
for child in base["children"]:                     # bottom of list = back; create back-to-front
    pass
for child in reversed(base["children"]):
    lid = json.loads(call("CreateLayer", {"layerName": child["name"], "position": "front"}))["uuid"]
    call("MoveObjectsToContainer", {"uuids": [child["uuid"]], "parentID": lid, "position": "front"})
call("DeleteObjects", {"uuids": [base["uuid"]]})
L = {n["name"]: n["uuid"] for n in json.loads(call("GetCanvasStructure", {"maxDepth": 0}))["objects_basic_details"]}
for n in ["Review board"] + sorted([k for k in L if k != "Review board"], reverse=True):   # A ends on top
    call("ArrangeArt", {"operation": "bring_to_front", "uuids": [L[n]]})
TOPMOST = ["FINAL · Greenroom mark (R03 reach, R08 tilt, hand 140)", "Finalists · R03 and R08", "Tuning R03: one slight change per sample",
           "Tuning R08: one slight change per sample", "Finalist 1 · R03 · hand to the counter centre",
           "Finalist 2 · R08 · hand tilted up", "Winners · pick one"]
for n in reversed(TOPMOST):                          # first in the list ends up on top
    call("ArrangeArt", {"operation": "bring_to_front", "uuids": [L[n]]})
os.makedirs("out/png", exist_ok=True)
print(call("Export", {"format": "AI", "outputPath": os.path.abspath("out/greenroom-logo-candidates-new.ai")}))
for i, (name, *_ ) in enumerate(meta["boards"], 1):
    call("Export", {"format": "PNG", "targetType": "ARTBOARD", "artboardIndex": i, "resolution": 72,
                    "backgroundColor": "transparent", "outputPath": os.path.abspath(f"out/png/{name}.png")})
print(call("ListArtboards", {})[:300])
print(call("GetCanvasStructure", {"maxDepth": 0})[:800])
