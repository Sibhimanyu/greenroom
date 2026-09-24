"""The final Greenroom mark only: one clean document, nothing from the exploration."""
import json
from geom import rounded, transform, d_attr, DEEP, LIME, WHITE
from explore import FINAL, FINAL_SMALL_MARK_W

FONT = "Helvetica Neue"
INK, BODY, FAINT = "#101828", "#475467", "#98A2B3"
NAME = "Greenroom mark"
out, boards = [], []


def esc(t): return t.replace("&", "&amp;").replace("<", "&lt;")
def path(segs, fill, pid): return f'<path id="{esc(pid)}" fill="{fill}" d="{d_attr(segs)}"/>'
def rect(x, y, w, h, fill, rid="background"): return f'<rect id="{rid}" x="{x}" y="{y}" width="{w}" height="{h}" fill="{fill}"/>'
def text(x, y, s, size, fill=INK, weight="normal"):
    return f'<text x="{x}" y="{y}" font-family="{FONT}" font-size="{size}" font-weight="{weight}" fill="{fill}">{esc(s)}</text>'


def mark(box, cols, gid):
    MW, MH = FINAL["size"]; x, y, w, h = box; s = min(w / MW, h / MH)
    dx, dy = x + (w - MW * s) / 2, y + (h - MH * s) / 2
    return (f'<g id="{esc(gid)}">' + "".join(path(transform(segs, s, dx, dy), cols[role], name)
                                             for name, segs, role in FINAL["parts"]) + "</g>"), (s, dx, dy)


TILE = rounded([(100, 100, 185), (924, 100, 185), (924, 924, 185), (100, 924, 185)])
def icon(x, y, px, gid, mark_w=520):
    k = px / 1024; o = (1024 - mark_w) / 2 * k
    m, _ = mark((x + o, y + o, mark_w * k, mark_w * k), {"struct": WHITE, "accent": LIME}, "mark")
    return f'<g id="{esc(gid)}">' + path(transform(TILE, k, x, y), DEEP, "tile") + m + "</g>"


COLOUR = {"struct": DEEP, "accent": LIME}
# ---- row 1: construction and the mark on its four grounds
cons = [rect(0, 0, 1024, 1024, WHITE), text(64, 90, "Greenroom mark · construction", 34, INK, "bold")]
m, (s, dx, dy) = mark((152, 200, 640, 640), COLOUR, "mark")
ax = dx + FINAL["axis"] * s; MW, MH = FINAL["size"]
cons += [m, f'<g id="guides"><rect x="{dx:.2f}" y="{dy:.2f}" width="{MW*s:.2f}" height="{MH*s:.2f}" fill="none" '
         f'stroke="{FAINT}" stroke-width="1" stroke-dasharray="4 4"/><line x1="{ax:.2f}" y1="{dy-40:.2f}" x2="{ax:.2f}" '
         f'y2="{dy+MH*s+40:.2f}" stroke="#B42318" stroke-width="1.5" stroke-dasharray="8 5"/></g>']
for i, line in enumerate(["Grid 965 × 1000 · stroke 235 · outer r 240 · bottom-right r 140",
                          "Head 235 square, r 75, on the body's axis (red) · 40 above the body",
                          "Arm 140 thick, rises 12.6° from the shoulder to a round tip",
                          "App icon: tile 824 on 1024, r 185 · mark 520 wide (620 at 16 and 32 px)",
                          "Deep #00401C · lime #78C000 (fill only, never text) · white"]):
    cons.append(text(64, 880 + i * 28, line, 19, BODY))
out.append('<g id="Construction">' + "".join(cons) + "</g>"); boards.append(("Construction", 0, 0, 1024, 1024))

grounds = [("Mark · colour", WHITE, COLOUR), ("Mark · reversed", DEEP, {"struct": WHITE, "accent": LIME}),
           ("Mark · deep green only", WHITE, {"struct": DEEP, "accent": DEEP}),
           ("Mark · white only", "#000000", {"struct": WHITE, "accent": WHITE})]
g = []
for i, (name, bg, cols) in enumerate(grounds):
    x = 1124 * (i + 1)
    g.append(f'<g id="{esc(name)}">' + rect(x, 0, 1024, 1024, bg) + mark((x + 152, 152, 720, 720), cols, "mark")[0] + "</g>")
    boards.append((name.replace(" · ", "-").replace(" ", "-"), x, 0, 1024, 1024))
out.append('<g id="Mark">' + "".join(g) + "</g>")

# ---- row 2: the app icon at every size (1 pt = 1 px); 32 and 16 use the small-size artwork
g = []; x = 0; y = 1200
for px in (1024, 512, 256, 128, 64, 32, 16):
    small = px <= 32
    name = f"App icon {px}" + (" (small-size artwork)" if small else "")
    g.append(icon(x, y, px, name, FINAL_SMALL_MARK_W if small else 520))
    boards.append((f"App-icon-{px}", x, y, px, px))
    x += px + 100
out.append('<g id="App icon">' + "".join(g) + "</g>")

W = max(b[1] + b[3] for b in boards); H = max(b[2] + b[4] for b in boards)
open("greenroom-logo-final-v2.svg", "w").write(
    f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">' + "".join(out) + "</svg>")
json.dump({"canvas": [W, H], "boards": boards}, open("final-boards.json", "w"), indent=1)
print(W, H, len(boards), "artboards")
