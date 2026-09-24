"""Open the final-only SVG, name artboards and layers, save greenroom-logo-final.ai."""
import json, os
from call import call
meta = json.load(open("final-boards.json"))
doc = json.loads(call("OpenDocument", {"filePath": os.path.abspath("greenroom-logo-final-level.svg")}))
l, t = doc["artboards"][0]["bounds"][:2]; first = doc["artboards"][0]["name"]
for name, x, y, w, h in meta["boards"]:
    call("CreateArtboard", {"artboardName": name, "left": x + l, "top": y + t, "width": w, "height": h, "backgroundColor": "none"})
call("DeleteArtboard", {"artboardName": first})
base = json.loads(call("GetCanvasStructure", {"maxDepth": 1}))["objects_basic_details"][0]
for child in reversed(base["children"]):
    lid = json.loads(call("CreateLayer", {"layerName": child["name"], "position": "front"}))["uuid"]
    call("MoveObjectsToContainer", {"uuids": [child["uuid"]], "parentID": lid, "position": "front"})
call("DeleteObjects", {"uuids": [base["uuid"]]})
L = {n["name"]: n["uuid"] for n in json.loads(call("GetCanvasStructure", {"maxDepth": 0}))["objects_basic_details"]}
for n in ["App icon", "Mark", "Construction"]:          # Construction ends on top
    call("ArrangeArt", {"operation": "bring_to_front", "uuids": [L[n]]})
print(call("Export", {"format": "AI", "outputPath": os.path.abspath("out/final/greenroom-logo-final-level.ai")}))
os.makedirs("out/final/png", exist_ok=True)
for i, (name, *_ ) in enumerate(meta["boards"], 1):
    call("Export", {"format": "PNG", "targetType": "ARTBOARD", "artboardIndex": i, "resolution": 72,
                    "backgroundColor": "transparent", "outputPath": os.path.abspath(f"out/final/png/{name}.png")})
print([n["name"] for n in json.loads(call("GetCanvasStructure", {"maxDepth": 0}))["objects_basic_details"]])
print([a["name"] for a in json.loads(call("ListArtboards", {}))["artboards"]])
