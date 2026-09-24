"""Your edit, cleaned up, beside two alternatives: one comparison board plus mark and icon artboards."""
import json
from geom import rounded, transform, d_attr, DEEP, LIME, WHITE
from explore import U_DROP, U_BASE, V_EDIT, V_MID, FINAL, FINAL_SMALL_MARK_W

INK, BODY, FAINT, DARK = "#101828", "#475467", "#98A2B3", "#1E1E1E"
def esc(t): return t.replace("&", "&amp;").replace("<", "&lt;")
def path(segs, fill, pid): return f'<path id="{esc(pid)}" fill="{fill}" d="{d_attr(segs)}"/>'
def rect(x, y, w, h, fill, rid="background", r=0):
    rr = f' rx="{r}" ry="{r}"' if r else ""
    return f'<rect id="{rid}" x="{x}" y="{y}" width="{w}" height="{h}"{rr} fill="{fill}"/>'
def text(x, y, s, size, fill=INK, weight="normal"):
    return f'<text x="{x}" y="{y}" font-family="Helvetica Neue" font-size="{size}" font-weight="{weight}" fill="{fill}">{esc(s)}</text>'


def mark(m, box, cols, gid):
    W, H = m["size"]; x, y, w, h = box; s = min(w / W, h / H)
    dx, dy = x + (w - W * s) / 2, y + (h - H * s) / 2
    return f'<g id="{esc(gid)}">' + "".join(path(transform(g, s, dx, dy), cols[role], n) for n, g, role in m["parts"]) + "</g>"


TILE = rounded([(100, 100, 185), (924, 100, 185), (924, 924, 185), (100, 924, 185)])
def icon(m, x, y, px, gid, white_only=False):
    k = px / 1024; mw = FINAL_SMALL_MARK_W if px <= 32 else 520
    W, H = m["size"]; mh = min(mw * H / W, 700 if px <= 32 else 600)     # tall marks: cap the height in the tile
    box = (x + (1024 - mw) / 2 * k, y + (1024 - mh) / 2 * k, mw * k, mh * k)
    cols = {"struct": WHITE, "accent": WHITE if white_only else LIME}
    return f'<g id="{esc(gid)}">' + path(transform(TILE, k, x, y), DEEP, "tile") + mark(m, box, cols, "mark") + "</g>"


V = [("1 · Your first edit", U_DROP,
      ["Head in the G's mouth; arm raised from the shoulder",
       "Body drops 100 below the base", "Watch: reads “Gj”"]),
     ("2 · First edit, body on the base", U_BASE,
      ["Same head and raised arm; body ends on the base",
       "Head 235, gaps 40–75", "The person survives at 16 px"]),
     ("3 · Your second edit", V_EDIT,
      ["Taller G; top arm across the full width",
       "Head 180 tucked under the arm, gaps ~30", "Watch: the head drowns at 16 px"]),
     ("4 · The middle ground", V_MID,
      ["Your taller G and full-width arm",
       "Head back to 235, gaps back to 45; arm 120 at 12°", "Tests whether the letter and the person can both win"]),
     ("5 · The current final", FINAL,
      ["Level hand 140; head in the top row", "The calmest and most letter-like", "For comparison"])]

out, boards = [], []
CW = 1060; BW = 160 + len(V) * CW; BH = 1900
el = [rect(0, 0, BW, BH, WHITE), text(80, 110, "Your edits, rebuilt: five versions side by side", 52, INK, "bold"),
      text(80, 160, "Exact geometry. 32 and 16 px use the small-size artwork. Enlarge in Illustrator to compare.", 24, BODY)]
for i, (name, m, notes) in enumerate(V):
    x = 80 + i * CW; y = 220
    c = [rect(x, y, CW - 40, 1620, "#F9FAFB", r=18), text(x + 30, y + 64, name, 34, INK, "bold"),
         icon(m, x + 30, y + 100, 640, "icon 640"),
         rect(x + 690, y + 100, 300, 300, WHITE, r=14),
         mark(m, (x + 720, y + 130, 240, 240), {"struct": DEEP, "accent": LIME}, "mark colour"),
         rect(x + 690, y + 420, 300, 300, DEEP, r=14),
         mark(m, (x + 720, y + 450, 240, 240), {"struct": WHITE, "accent": LIME}, "mark reversed"),
         text(x + 30, y + 800, "App icon · 128 · 64 · 32 · 16", 20, FAINT, "bold"),
         icon(m, x + 30, y + 830, 128, "icon 128"), icon(m, x + 190, y + 862, 64, "icon 64"),
         icon(m, x + 286, y + 878, 32, "icon 32"), icon(m, x + 350, y + 886, 16, "icon 16"),
         rect(x + 420, y + 820, 570, 150, DARK, r=12),
         icon(m, x + 450, y + 831, 128, "dark 128"), icon(m, x + 610, y + 863, 64, "dark 64"),
         icon(m, x + 706, y + 879, 32, "dark 32"), icon(m, x + 770, y + 887, 16, "dark 16"),
         icon(m, x + 830, y + 879, 32, "white only 32", white_only=True), icon(m, x + 894, y + 887, 16, "white only 16", white_only=True)]
    for j, line in enumerate(notes):
        c.append(text(x + 30, y + 1060 + j * 40, line, 23, INK if j < 2 else BODY))
    c.append(text(x + 30, y + 1240, "Fresh-viewer read at 32 px:", 21, FAINT, "bold"))
    c += [f'<line x1="{x + 30}" y1="{y + 1330}" x2="{x + CW - 70}" y2="{y + 1330}" stroke="#EAECF0" stroke-width="2"/>',
          f'<line x1="{x + 30}" y1="{y + 1410}" x2="{x + CW - 70}" y2="{y + 1410}" stroke="#EAECF0" stroke-width="2"/>']
    el.append(f'<g id="{esc(name)}">' + "".join(c) + "</g>")
out.append('<g id="Comparison">' + "".join(el) + "</g>"); boards.append(("Comparison", 0, 0, BW, BH))

# one mark artboard and one app-icon artboard per version, below the board
for i, (name, m, _) in enumerate(V):
    x = i * 2248; y = BH + 200; key = name.split(" · ")[0]
    out.append(f'<g id="{esc(name)} · artboards">' + rect(x, y, 1024, 1024, WHITE)
               + mark(m, (x + 152, y + 152, 720, 720), {"struct": DEEP, "accent": LIME}, "mark colour")
               + icon(m, x + 1124, y, 1024, "app icon 1024") + "</g>")
    boards += [(f"Version-{key}-mark", x, y, 1024, 1024), (f"Version-{key}-app-icon", x + 1124, y, 1024, 1024)]

W = max(b[1] + b[3] for b in boards); H = max(b[2] + b[4] for b in boards)
open("greenroom-logo-compare.svg", "w").write(
    f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">' + "".join(out) + "</svg>")
json.dump({"canvas": [W, H], "boards": boards}, open("compare-boards.json", "w"), indent=1)
print(W, H, len(boards), "artboards")
