"""The final mark broken into its separate shapes, one layer each, for moving by hand.

The pieces overlap where they meet, so they can be dragged apart and later rejoined with
Pathfinder > Unite. Units are the mark's 1000 grid at 1 pt each.
"""
import json
from geom import rounded, transform, d_attr, DEEP, LIME, WHITE
from explore import FINAL

INK, BODY = "#101828", "#475467"
def esc(t): return t.replace("&", "&amp;").replace("<", "&lt;")
def path(segs, fill, pid): return f'<path id="{esc(pid)}" fill="{fill}" d="{d_attr(segs)}"/>'
def rect(x0, y0, x1, y1, r):         # r = (top-left, top-right, bottom-right, bottom-left)
    return rounded([(x0, y0, r[0]), (x1, y0, r[1]), (x1, y1, r[2]), (x0, y1, r[3])])

# ---- the pieces, on the 1000 grid; together they cover the final mark exactly,
# except the joined master's small fillets where the arm and the counter's floor meet the body
import math
# the arm's corners, computed exactly as in explore.mark_U (theta 12.6°, 140 thick, tip centre x 537)
_th = math.radians(12.6); _r = 70; _bx0, _btop = 730, 430
_u = (math.cos(_th), -math.sin(_th)); _nd = (math.sin(_th), math.cos(_th))
_cy = _btop + _r / math.cos(_th)
_tip = (537, _cy + (_bx0 - 537) * math.tan(_th))
def _edge(sign, x):          # y of the arm's top (-1) or bottom (+1) edge at x
    c = _tip[1] - (x - _tip[0]) * math.tan(_th)
    return c + sign * _r / math.cos(_th)
_p_bot = (_tip[0] - _u[0] * _r + _nd[0] * _r, _tip[1] - _u[1] * _r + _nd[1] * _r)
_p_top = (_tip[0] - _u[0] * _r - _nd[0] * _r, _tip[1] - _u[1] * _r - _nd[1] * _r)
ARM = rounded([(_p_top[0], _p_top[1], _r), (_bx0, _btop, 0), (790, _btop + 15, 0),   # tucks 60 into the body,
               (790, _edge(1, 790), 0), (_p_bot[0], _p_bot[1], _r)], fit=True)      # never above its top
BACK = rounded([(0, 0, 240), (300, 0, 0), (300, 235, 0), (235, 235, 40),       # the G's back: both outer
                (235, 765, 40), (300, 765, 0), (300, 1000, 0), (0, 1000, 240)])  # corners, like a [ bracket
PIECES = [("Back of the G", BACK, "struct"),
          ("Top arm",    rect(280, 0, 655, 235, (0, 70, 70, 0)), "struct"),        # runs 20 into the back
          ("Bottom arm", rect(280, 765, 965, 1000, (0, 0, 140, 0)), "struct"),
          ("Body",       rect(730, 430, 965, 1000, (0, 55, 140, 0)), "struct"),
          ("Arm",        ARM, "struct"),
          ("Head",       rect(730, 155, 965, 390, (75, 75, 75, 75)), "accent")]

A = 1400                    # artboard 1: pieces on white, mark at 200,200
MW, MH = FINAL["size"]
TILE_PX = MW * 1024 / 520   # artboard 2: the icon at the size where the mark is full size
T0 = A + 200                # artboard 2 left edge
M2 = (T0 + (TILE_PX - MW) / 2, (TILE_PX - MH) / 2)
R0 = T0 + TILE_PX + 200     # artboard 3: the joined master

groups = {}
bg = [f'<rect id="white ground" x="0" y="0" width="{A}" height="{A}" fill="{WHITE}"/>',
      path(transform(rounded([(100, 100, 185), (924, 100, 185), (924, 924, 185), (100, 924, 185)]),
                     TILE_PX / 1024, T0, 0), DEEP, "icon tile"),
      f'<rect id="white ground" x="{R0}" y="0" width="{A}" height="{A}" fill="{WHITE}"/>']
out = ['<g id="Backgrounds">' + "".join(bg) + "</g>"]
for name, segs, role in PIECES:
    on_white = path(transform(segs, 1, 200, 200), DEEP if role == "struct" else LIME, f"{name} · on white")
    on_tile = path(transform(segs, 1, *M2), WHITE if role == "struct" else LIME, f"{name} · on the icon tile")
    out.append(f'<g id="{esc(name)}">' + on_white + on_tile + "</g>")
ref = "".join(path(transform(segs, 1, R0 + 200, 200), DEEP if role == "struct" else LIME, f"master {n}")
              for n, segs, role in FINAL["parts"])
out.append('<g id="Reference · joined master">' + ref
           + f'<text x="{R0 + 200}" y="1300" font-family="Helvetica Neue" font-size="28" fill="{BODY}">'
             'The joined master, for comparison. Locked.</text></g>')

boards = [("Pieces · on white", 0, 0, A, A), ("Pieces · on the icon tile", T0, 0, TILE_PX, TILE_PX),
          ("Joined master (reference)", R0, 0, A, A)]
W = R0 + A; H = max(A, TILE_PX)
open("greenroom-logo-pieces-v2.svg", "w").write(
    f'<svg xmlns="http://www.w3.org/2000/svg" width="{W:.0f}" height="{H:.0f}" viewBox="0 0 {W:.0f} {H:.0f}">' + "".join(out) + "</svg>")
json.dump({"canvas": [W, H], "boards": boards}, open("pieces-boards.json", "w"), indent=1)
print(round(W), round(H), len(boards), "artboards", [p[0] for p in PIECES])
