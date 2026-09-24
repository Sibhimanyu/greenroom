"""Lay every candidate out on one canvas; each region becomes an artboard in Illustrator."""
import json
from geom import *

FONT = "Helvetica Neue"
INK, BODY, FAINT, LINE = "#101828", "#475467", "#98A2B3", "#EAECF0"
DARK = "#1E1E1E"

NAMES = {"A": "A · Integrated G + person",
         "B": "B · Reaching G + person, gap",
         "C": "C · Bottom bridge (optional)",
         "D": "D · Squared G + two panes",
         "E": "E · Angled panes, carved G",
         "F": "F · Open G, lime pane in the jaw",
         "G": "G · Reach inside the G",
         "H": "H · Screen + camera bubble",
         "I": "I · G with a presence dot",
         "J": "J · Chat-bubble G + screen",
         "K": "K · Door ajar (the green room)",
         "L": "L · Tiled G: four windows",
         "X": "Control · rejected (reads Ei)"}

out = []            # svg body
boards = []         # (name, left, top, width, height)


def esc(t): return t.replace("&", "&amp;").replace("<", "&lt;")


def path(segs, fill, pid=None):
    i = f' id="{esc(pid)}"' if pid else ""
    return f'<path{i} fill="{fill}" d="{d_attr(segs)}"/>'


def rect(x, y, w, h, fill, rid=None, r=0):
    i = f' id="{esc(rid)}"' if rid else ""
    rr = f' rx="{r}" ry="{r}"' if r else ""
    return f'<rect{i} x="{x}" y="{y}" width="{w}" height="{h}"{rr} fill="{fill}"/>'


def text(x, y, s, size, fill=INK, weight="normal", anchor="start"):
    return (f'<text x="{x}" y="{y}" font-family="{FONT}" font-size="{size}" font-weight="{weight}" '
            f'fill="{fill}" text-anchor="{anchor}">{esc(s)}</text>')


def place(m, box):
    """Scale mark m to fit box (x, y, w, h), centred. Returns (scale, dx, dy)."""
    W, H = m["size"]; x, y, w, h = box
    s = min(w / W, h / H)
    return s, x + (w - W * s) / 2, y + (h - H * s) / 2


def mark_svg(m, box, cols, gid):
    s, dx, dy = place(m, box)
    parts = [path(transform(segs, s, dx, dy), cols[role], name) for name, segs, role in m["parts"]]
    return f'<g id="{esc(gid)}">' + "".join(parts) + "</g>"


TILE = rounded([(100, 100, 185), (924, 100, 185), (924, 924, 185), (100, 924, 185)])


def icon_svg(m, x, y, px, gid, mode="colour", mark_w=None):
    k = px / 1024
    W, H = m["size"]; tw = mark_w or (560 if W > H else 520)
    th = tw * H / W
    cols = {"struct": WHITE, "accent": LIME if mode == "colour" else WHITE}
    box = (x + (1024 - tw) / 2 * k, y + (1024 - th) / 2 * k, tw * k, th * k)
    tile = path(transform(TILE, k, x, y), DEEP, "tile")
    return f'<g id="{esc(gid)}">' + tile + mark_svg(m, box, cols, "mark") + "</g>"


def board(name, x, y, w, h):
    boards.append((name, x, y, w, h))


# ---------------------------------------------------------------- per-direction rows
COL = [0, 1224, 2448, 3672, 4896, 6120]
ROW_H = 1400
ROWS = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L"]
BLOCK_W = 7000                      # two blocks of six rows; the canvas tops out at 16383 pt
SPECS = {"A": ["Grid 1000 × 1000 · stroke 150 · outer r 300 · inner r 150",
              "Head Ø210 and body share axis x = 500 (red)",
              "Gaps 40: head–body, body–floor · nub 90 × 110, r 55"],
        "B": ["Grid 1040 × 800 · stroke 140 · outer r 250 · inner r 110",
              "Head Ø290 and body share axis x = 820 (red)",
              "Hand 120 thick, top flush with shoulder · gaps 40"],
        "C": ["As B; G base runs on into the body",
              "Slot between jaw and body: round bottom, r 23, no pinch",
              "Head Ø290 and body share axis x = 820 (red)"],
        "D": ["Grid 1170 × 1000 · stroke 265 · outer r 200 · inner r 60",
              "Bar floats 76 off the stem · panes r 70",
              "One gap, 52: G to panes, pane to pane"],
        "E": ["Grid 1060 × 1000 · outer edges 759 tall, inner edges full height",
              "G is a squared spiral channel 80 wide, cut from the inner edge",
              "Right column mirrors the tilt · gaps 56 · shoulders cut 57"],
        "F": ["Grid 1000 × 1000 · stroke 235 · jaw stem 300 wide",
              "Lime pane 300 × 235, r 45, flush with the G's right edge",
              "Gaps 45 above and below the lime pane"],
        "G": ["As A · the G's bar is an arm, 90 thick, round hand",
              "Person moves left to axis x = 450 (red)",
              "Hand stops ~50 short of the shoulder"],
        "H": ["Grid 1000 × 1000 · frame 150 · outer r 220 · inner r 70",
              "Frame opens at the bottom-right corner, round ends",
              "Camera bubble Ø380 · 50 clear of both ends"],
        "I": ["Grid 1000 × 1000 · stroke 170 · outer r 320 · inner r 150",
              "Crossbar 140 thick from the jaw",
              "Presence dot Ø180, 40 off the bar's tip, at the counter centre"],
        "J": ["As I, with a tail at the bottom left: grid 1000 × 1130",
              "Screen pane 290 × 270, r 40, top left of the counter",
              "60 clear of the crossbar"],
        "K": ["Frame 700 × 1000 · stroke 150 · outer r 200",
              "Door hinged 50 off the frame · outer edge 780 tall",
              "The open door is the lime accent"],
        "L": ["Four windows, gaps 50: screen, meeting, chat, cue",
              "Screen 300 wide, outer r 200 · the G's mouth 260 to 420",
              "Cue pane 240 × 230 rises off the chat pane as the jaw"]}


def draw_row(key, name, m, spec, bx, y):
    """One direction's full set: construction, colour, reversed, mono, app icon 1024 and small sizes."""
    W, H = m["size"]
    g = [f'<g id="{esc(name)}">']

    # construction sheet
    x = bx + COL[0]
    s, dx, dy = place(m, (x + 152, y + 200, 720, 640))
    cons = [rect(x, y, 1024, 1024, WHITE, "background")]
    cons.append(mark_svg(m, (x + 152, y + 200, 720, 640), {"struct": DEEP, "accent": LIME}, "mark"))
    axis_line = ""
    if m["axis"] is not None:
        ax = dx + m["axis"] * s
        axis_line = (f'<line x1="{ax:.2f}" y1="{dy-40:.2f}" x2="{ax:.2f}" y2="{dy+H*s+40:.2f}" '
                     f'stroke="#B42318" stroke-width="1.5" stroke-dasharray="8 5"/>')
    cons.append(f'<g id="guides">'
                f'<rect x="{dx:.2f}" y="{dy:.2f}" width="{W*s:.2f}" height="{H*s:.2f}" fill="none" stroke="{FAINT}" stroke-width="1" stroke-dasharray="4 4"/>'
                + axis_line + '</g>')
    cons.append(text(x + 64, y + 90, name, 34, INK, "bold"))
    for i, line in enumerate(spec):
        cons.append(text(x + 64, y + 912 + i * 30, line, 20, BODY))
    g.append(f'<g id="{key} construction">' + "".join(cons) + "</g>")
    board(f"{key}-construction", x, y, 1024, 1024)

    # colour / reversed / mono marks, 1024 squares
    box = lambda x0: (x0 + 152, y + 152, 720, 720)
    g.append(f'<g id="{key} colour">' + rect((bx + COL[1]), y, 1024, 1024, WHITE, "background")
             + mark_svg(m, box((bx + COL[1])), {"struct": DEEP, "accent": LIME}, "mark") + "</g>")
    board(f"{key}-mark-colour", (bx + COL[1]), y, 1024, 1024)
    g.append(f'<g id="{key} reversed">' + rect((bx + COL[2]), y, 1024, 1024, DEEP, "background")
             + mark_svg(m, box((bx + COL[2])), {"struct": WHITE, "accent": LIME}, "mark") + "</g>")
    board(f"{key}-mark-reversed", (bx + COL[2]), y, 1024, 1024)
    g.append(f'<g id="{key} mono">' + rect((bx + COL[3]), y, 1024, 1024, WHITE, "background")
             + mark_svg(m, box((bx + COL[3])), {"struct": DEEP, "accent": DEEP}, "mark") + "</g>")
    board(f"{key}-mark-mono", (bx + COL[3]), y, 1024, 1024)

    # app icon at 1024 and the small sizes, each its own artboard (1 pt = 1 px)
    g.append(icon_svg(m, (bx + COL[4]), y, 1024, f"{key} icon 1024"))
    board(f"{key}-icon-1024", (bx + COL[4]), y, 1024, 1024)
    xs = bx + COL[5]
    for px in (128, 64, 32, 16):
        g.append(icon_svg(m, xs, y, px, f"{key} icon {px}"))
        board(f"{key}-icon-{px}", xs, y, px, px)
        xs += px + 60
    g.append("</g>")
    return g


for r, key in enumerate(ROWS):
    out.extend(draw_row(key, NAMES[key], MARKS[key](), SPECS[key], (r // 6) * BLOCK_W, (r % 6) * ROW_H))

# ---------------------------------------------------------------- comparison board
BX, BY, BW, BH = 0, 6 * ROW_H, 3000, 3670
cmp_ = [rect(BX, BY, BW, BH, WHITE, "background")]
cmp_.append(text(BX + 80, BY + 110, "Greenroom mark: side-by-side review", 48, INK, "bold"))
cmp_.append(text(BX + 80, BY + 160, "Actual vector geometry at each size. Ask a fresh viewer what the mark looks like "
                 "before explaining G, person, windows or hand, and write the answer in the last column.", 22, BODY))
heads = [(560, "128"), (740, "64"), (860, "32"), (930, "16"),
         (1060, "on dark: 64 · 32 · 16"), (1440, "mono 32 · 16"), (1640, "mark 64, light"), (1860, "mark 32 · 16"),
         (2100, "Fresh-viewer read (before explaining)")]
for hx, ht in heads:
    cmp_.append(text(BX + hx, BY + 250, ht, 18, FAINT))
notes = {"A": "Reads as one icon; no adjacent-letter reading.",
         "B": "Strongest gesture; watch for “Gi” at 32 and 16.",
         "C": "One base; check the body stays distinct at 32.",
         "D": "Same build as the rejected K: likely reads “Ei”.",
         "E": "Keeps the workspace; the carved G fades at 16.",
         "F": "Simplest; may read as a C with a square.",
         "G": "A's enclosure with B's reach; one shape.",
         "H": "Screen + camera; the G is implied. May read “Q”.",
         "I": "Strongest at 16; the dot may read as a period.",
         "J": "Adds chat; the tail is fussy at 16.",
         "K": "Names the room; the weakest G.",
         "L": "Windows spell the G; close to “E” at large sizes.",
         "X": "Rejected control. Reads “Ei”. Do not ship."}
for i, key in enumerate(ROWS + ["X"]):
    m = MARKS[key](); y = BY + 300 + i * 250
    cmp_.append(rect(BX + 60, y - 20, BW - 120, 220, "#F9FAFB", r=14))
    cmp_.append(text(BX + 90, y + 40, NAMES[key], 28, INK, "bold"))
    cmp_.append(text(BX + 90, y + 80, notes[key], 19, BODY))
    for px, hx in ((128, 560), (64, 740), (32, 860), (16, 930)):
        cmp_.append(icon_svg(m, BX + hx, y + 20, px, f"{key} {px}"))
    cmp_.append(rect(BX + 1040, y + 10, 360, 124, DARK, r=10))
    for px, hx in ((64, 1070), (32, 1170), (16, 1240)):
        cmp_.append(icon_svg(m, BX + hx, y + 30, px, f"{key} dark {px}"))
    for px, hx in ((32, 1440), (16, 1500)):
        cmp_.append(icon_svg(m, BX + hx, y + 20, px, f"{key} mono {px}", mode="mono"))
    cmp_.append(mark_svg(m, (BX + 1640, y + 20, 64, 64), {"struct": DEEP, "accent": LIME}, f"{key} mark 64"))
    cmp_.append(mark_svg(m, (BX + 1860, y + 20, 32, 32), {"struct": DEEP, "accent": LIME}, f"{key} mark 32"))
    cmp_.append(mark_svg(m, (BX + 1920, y + 20, 16, 16), {"struct": DEEP, "accent": LIME}, f"{key} mark 16"))
    cmp_.append(f'<line x1="{BX+2100}" y1="{y+100}" x2="{BX+2880}" y2="{y+100}" stroke="{LINE}" stroke-width="2"/>')
    cmp_.append(f'<line x1="{BX+2100}" y1="{y+170}" x2="{BX+2880}" y2="{y+170}" stroke="{LINE}" stroke-width="2"/>')
cmp_.append(text(BX + 80, BY + BH - 60, "Colours: deep #00401C · lime #78C000 (fill only, never text) · white. "
                 "Flat fills, no gradients. Icon tile 824 on a 1024 canvas, r 185.", 18, FAINT))
out.append('<g id="Review board">' + "".join(cmp_) + "</g>")
board("Review-board", BX, BY, BW, BH)

# ---------------------------------------------------------------- round 3 exploration sheets
from explore import V as VARIANTS
FAMS = [("F", "Round 3 · F: head on top, the G's right stroke is the body"),
        ("P", "Round 3 · P: the person in the G, made plainer"),
        ("M", "Round 3 · M: crosses between F and P"),
        ("R", "Round 4 · R: F02 with a hand that completes the G"),
        ("Y", "Round 5 · Y: the G's hand joins the person, both arms up")]
SLOTS = [(3200, 8400), (6300, 8400), (9400, 8400), (12500, 8400), (3200, 10300), (6300, 10300), (9400, 10300), (12500, 10300)]
CELL_W, CELL_H, PER = 560, 460, 15
sheet_no = 0
for fam, title in FAMS:
    items = [x for x in VARIANTS if x[0].startswith(fam) and "." not in x[0]]
    chunks = [items[i:i + PER] for i in range(0, len(items), PER)]
    for c, chunk in enumerate(chunks):
        sx, sy = SLOTS[sheet_no]; sheet_no += 1
        name = f"{title} ({c + 1}/{len(chunks)})" if len(chunks) > 1 else title
        sw, sh = 5 * CELL_W + 160, 3 * CELL_H + 300
        el = [rect(sx, sy, sw, sh, WHITE, "background"), text(sx + 80, sy + 100, name, 40, INK, "bold"),
              text(sx + 80, sy + 145, "Each cell: app icon 256 · mark 150 · icons 64 · 32 · 16 · mono 32. Exact vector geometry.", 20, BODY)]
        for i, (vid, label, m) in enumerate(chunk):
            cx = sx + 80 + (i % 5) * CELL_W; cy = sy + 200 + (i // 5) * CELL_H
            cell = [rect(cx, cy, CELL_W - 30, CELL_H - 30, "#F9FAFB", r=14),
                    icon_svg(m, cx + 14, cy + 14, 256, "icon 256"),
                    rect(cx + 290, cy + 14, 220, 190, WHITE, r=10),
                    mark_svg(m, (cx + 325, cy + 34, 150, 150), {"struct": DEEP, "accent": LIME}, "mark"),
                    icon_svg(m, cx + 290, cy + 216, 64, "icon 64"),
                    icon_svg(m, cx + 370, cy + 232, 32, "icon 32"),
                    icon_svg(m, cx + 418, cy + 240, 16, "icon 16"),
                    icon_svg(m, cx + 450, cy + 232, 32, "mono 32", mode="mono"),
                    text(cx + 14, cy + 312, vid, 26, INK, "bold"),
                    text(cx + 14, cy + 346, label, 19, BODY)]
            el.append(f'<g id="{esc(vid + " · " + label)}">' + "".join(cell) + "</g>")
        out.append(f'<g id="{esc(name)}">' + "".join(el) + "</g>")
        board(f"R3-{fam}-sheet-{c + 1}", sx, sy, sw, sh)

# ---------------------------------------------------------------- winners, up top
TOP = 3300                                   # everything above moves down to make room
_shifted, _depth = [], 0
for e in out:                                # shift top-level groups only, never their children
    if _depth == 0 and e.startswith('<g id='):
        e = e.replace('<g id=', f'<g transform="translate(0,{TOP})" id=', 1)
    _depth += e.count('<g ') + e.count('<g>') - e.count('</g>')
    _shifted.append(e)
out[:] = _shifted
boards[:] = [(n, x, y + TOP, w, h) for n, x, y, w, h in boards]
VBY = {vid: (label, m) for vid, label, m in VARIANTS}
WIN = [("R03", "F02 + a hand to the counter centre",
        "The hand completes the G and reads as an arm.", "The hand thins out at 16 px."),
       ("Y04", "A, both arms up at 45°",
        "Happy and welcoming; the person reads first.", "Arms merge into the shoulders at 16 px."),
       ("M02", "Round head, body to 420, hand raised",
        "The clearest G of the head-and-body line.", "The round head is softer than the squares."),
       ("R08", "F02 + a hand tilted up",
        "The most human: a reach, almost a wave.", "The tilt disappears under 32 px."),
       ("Y15", "Half-disc body, arms up",
        "The most abstract person; very friendly.", "No G hand; the G leans on its jaw alone."),
       ("F02", "Your pick, as drawn",
        "Simplest; strongest at 16 px.", "Dot over a column can drift toward “Gi”.")]
WW = 900; wx0 = 80
el = [rect(0, 0, 160 + len(WIN) * WW, 1560, WHITE, "background"),
      text(80, 110, "Pick one: six winners from the board", 56, INK, "bold"),
      text(80, 165, "Ranked. Everything below is the exploration they came from. "
           "Exact vector geometry at every size; nobody has done a cold read yet.", 24, BODY)]
for i, (vid, name, why, watch) in enumerate(WIN):
    label, m = VBY[vid]; x = wx0 + i * WW; y = 230
    cell = [rect(x, y, WW - 40, 1270, "#F9FAFB", r=18),
            text(x + 30, y + 60, f"{i + 1} · {vid}" + ("   ·   my pick" if i == 0 else ""), 34, INK, "bold"),
            text(x + 30, y + 100, name, 22, BODY),
            icon_svg(m, x + 30, y + 130, 512, "icon 512"),
            rect(x + 570, y + 150, 260, 220, WHITE, r=12),
            mark_svg(m, (x + 610, y + 170, 180, 180), {"struct": DEEP, "accent": LIME}, "mark colour"),
            rect(x + 570, y + 390, 260, 220, DEEP, r=12),
            mark_svg(m, (x + 610, y + 410, 180, 180), {"struct": WHITE, "accent": LIME}, "mark reversed"),
            icon_svg(m, x + 30, y + 680, 128, "icon 128"),
            icon_svg(m, x + 180, y + 712, 64, "icon 64"),
            icon_svg(m, x + 266, y + 728, 32, "icon 32"),
            icon_svg(m, x + 320, y + 736, 16, "icon 16"),
            rect(x + 370, y + 690, 200, 110, DARK, r=10),
            icon_svg(m, x + 400, y + 729, 32, "dark 32"),
            icon_svg(m, x + 460, y + 737, 16, "dark 16"),
            icon_svg(m, x + 600, y + 729, 32, "mono 32", mode="mono"),
            icon_svg(m, x + 650, y + 737, 16, "mono 16", mode="mono"),
            mark_svg(m, (x + 700, y + 700, 100, 100), {"struct": DEEP, "accent": DEEP}, "mark mono"),
            text(x + 30, y + 880, "Why", 20, FAINT, "bold"),
            text(x + 30, y + 915, why, 21, INK),
            text(x + 30, y + 980, "Watch", 20, FAINT, "bold"),
            text(x + 30, y + 1015, watch, 21, INK),
            text(x + 30, y + 1080, "Fresh-viewer read:", 20, FAINT, "bold"),
            f'<line x1="{x + 30}" y1="{y + 1160}" x2="{x + WW - 70}" y2="{y + 1160}" stroke="{LINE}" stroke-width="2"/>',
            f'<line x1="{x + 30}" y1="{y + 1220}" x2="{x + WW - 70}" y2="{y + 1220}" stroke="{LINE}" stroke-width="2"/>']
    el.append(f'<g id="{esc(f"{i + 1} · {vid} · {name}")}">' + "".join(cell) + "</g>")
WX = 9600                                    # the six-winner board sits right of the finalists
WY = 1700
wboard = f'<g transform="translate({WX},{WY})" id="Winners · pick one">' + "".join(el) + "</g>"
out.append(wboard)
_front = [("Winners-pick-one", WX, WY, 160 + len(WIN) * WW, 1560)]

# ---------------------------------------------------------------- finalists, chosen 2026-09-24
FIN = [("R03", "Finalist 1 · R03 · hand to the counter centre",
        ["Grid 1000 × 1000 · stroke 235 · outer r 240 · bottom-right r 140",
         "Head 235 square, r 60, on the body's axis x = 850 (red) · gaps 45",
         "Hand 120 thick at y 480–600, reaches x 470, round end"]),
       ("R08", "Finalist 2 · R08 · hand tilted up",
        ["Grid 1000 × 1000 · stroke 235 · outer r 240 · bottom-right r 140",
         "Head 235 square, r 60, on the body's axis x = 850 (red) · gaps 45",
         "Hand 120 thick, rises 50 from body to tip, reaches x 520"])]
for i, (vid, name, spec) in enumerate(FIN):
    m = dict(VBY[vid][1]); m["axis"] = 850
    n0 = len(boards)
    out.append("".join(draw_row(vid, name, m, spec, 0, i * ROW_H)))
    _front += boards[n0:]; del boards[n0:]

FX, FW = 7300, 1000
fb = [rect(0, 0, 160 + 2 * FW, 3200, WHITE, "background"),
      text(80, 110, "Finalists: R03 and R08", 56, INK, "bold"),
      text(80, 165, "Chosen 2026-09-24. Same G, same head; only the hand differs.", 24, BODY)]
for i, (vid, name, spec) in enumerate(FIN):
    m = VBY[vid][1]; x = 80 + i * FW; y = 230
    c = [rect(x, y, FW - 40, 2890, "#F9FAFB", r=18),
         text(x + 30, y + 64, name, 32, INK, "bold"),
         icon_svg(m, x + 30, y + 100, 900, "icon 900"),
         rect(x + 30, y + 1040, 440, 440, WHITE, r=14),
         mark_svg(m, (x + 90, y + 1100, 320, 320), {"struct": DEEP, "accent": LIME}, "mark colour"),
         rect(x + 490, y + 1040, 440, 440, DEEP, r=14),
         mark_svg(m, (x + 550, y + 1100, 320, 320), {"struct": WHITE, "accent": LIME}, "mark reversed"),
         rect(x + 30, y + 1500, 440, 440, WHITE, r=14),
         mark_svg(m, (x + 90, y + 1560, 320, 320), {"struct": DEEP, "accent": DEEP}, "mark mono"),
         rect(x + 490, y + 1500, 440, 440, "#000000", r=14),
         mark_svg(m, (x + 550, y + 1560, 320, 320), {"struct": WHITE, "accent": WHITE}, "mark mono reversed"),
         text(x + 30, y + 2000, "App icon on light", 20, FAINT, "bold"),
         icon_svg(m, x + 30, y + 2030, 256, "icon 256"),
         icon_svg(m, x + 306, y + 2126, 128, "icon 128"),
         icon_svg(m, x + 454, y + 2190, 64, "icon 64"),
         icon_svg(m, x + 538, y + 2222, 32, "icon 32"),
         icon_svg(m, x + 590, y + 2238, 16, "icon 16"),
         rect(x + 640, y + 2030, 290, 256, DARK, r=12),
         text(x + 660, y + 2066, "On dark", 18, "#98A2B3", "bold"),
         icon_svg(m, x + 660, y + 2150, 128, "dark 128"),
         icon_svg(m, x + 800, y + 2190, 64, "dark 64"),
         icon_svg(m, x + 800, y + 2150, 32, "dark 32"),
         icon_svg(m, x + 850, y + 2158, 16, "dark 16"),
         text(x + 30, y + 2360, "Construction", 20, FAINT, "bold")]
    for j, line in enumerate(spec):
        c.append(text(x + 30, y + 2400 + j * 34, line, 21, INK))
    c += [text(x + 30, y + 2540, "Fresh-viewer read:", 20, FAINT, "bold"),
          f'<line x1="{x + 30}" y1="{y + 2620}" x2="{x + FW - 70}" y2="{y + 2620}" stroke="{LINE}" stroke-width="2"/>',
          f'<line x1="{x + 30}" y1="{y + 2690}" x2="{x + FW - 70}" y2="{y + 2690}" stroke="{LINE}" stroke-width="2"/>']
    fb.append(f'<g id="{esc(name)}">' + "".join(c) + "</g>")
out.append(f'<g transform="translate({FX},0)" id="Finalists · R03 and R08">' + "".join(fb) + "</g>")
boards[:0] = [("Finalists-R03-R08", FX, 0, 160 + 2 * FW, 3200)] + _front

# ---------------------------------------------------------------- R6 · fine-tuning sheets, next to the finalists
TUNE_SHEETS = [("R03", "Tuning R03: one slight change per sample", 13700, TOP),
               ("R08", "Tuning R08: one slight change per sample", 13700, TOP + 3260)]
_tune_boards = []
for fin, title, sx, sy in TUNE_SHEETS:
    items = [x for x in VARIANTS if x[0].startswith(fin + ".")]
    sw, sh = 4 * CELL_W + 160, 6 * CELL_H + 300
    el = [rect(sx, sy, sw, sh, WHITE, "background"), text(sx + 80, sy + 100, title, 40, INK, "bold"),
          text(sx + 80, sy + 145, "Cell .00 is the finalist as chosen. Every other cell changes one thing.", 20, BODY)]
    for i, (vid, label, m) in enumerate(items):
        cx = sx + 80 + (i % 4) * CELL_W; cy = sy + 200 + (i // 4) * CELL_H
        cell = [rect(cx, cy, CELL_W - 30, CELL_H - 30, "#EEF6E6" if i == 0 else "#F9FAFB", r=14),
                icon_svg(m, cx + 14, cy + 14, 256, "icon 256"),
                rect(cx + 290, cy + 14, 220, 190, WHITE, r=10),
                mark_svg(m, (cx + 325, cy + 34, 150, 150), {"struct": DEEP, "accent": LIME}, "mark"),
                icon_svg(m, cx + 290, cy + 216, 64, "icon 64"),
                icon_svg(m, cx + 370, cy + 232, 32, "icon 32"),
                icon_svg(m, cx + 418, cy + 240, 16, "icon 16"),
                icon_svg(m, cx + 450, cy + 232, 32, "mono 32", mode="mono"),
                text(cx + 14, cy + 312, vid, 26, INK, "bold"),
                text(cx + 14, cy + 346, label, 19, BODY)]
        el.append(f'<g id="{esc(vid + " · " + label)}">' + "".join(cell) + "</g>")
    out.append(f'<g id="{esc(title)}">' + "".join(el) + "</g>")
    _tune_boards.append((f"Tuning-{fin}", sx, sy, sw, sh))
boards[1:1] = _tune_boards                   # right after the finalists board

# ---------------------------------------------------------------- FINAL, top right
from explore import FINAL, FINAL_SMALL_MARK_W
FINAL_NAME = "FINAL · Greenroom mark (R03 reach, R08 tilt, hand 140)"
fm = dict(FINAL); fm["axis"] = 850
n0 = len(boards)
row = draw_row("FINAL", FINAL_NAME, fm,
               ["Grid 1000 × 1000 · stroke 235 · outer r 240 · bottom-right r 140",
                "Head 235 square, r 60, on the body's axis x = 850 (red) · gaps 45",
                "Hand 140 thick, rises 30 to its tip at x 470 · small sizes: mark 620"], WX, 0)
xs = WX + 6540 + 60
for px in (32, 16):                            # small-size masters: the mark drawn larger in the tile
    row.insert(-1, icon_svg(fm, xs, 0, px, f"FINAL icon {px} small master", mark_w=FINAL_SMALL_MARK_W))
    board(f"FINAL-icon-{px}-small-master", xs, 0, px, px)
    xs += px + 60
out.append("".join(row))
_fin = boards[n0:]; del boards[n0:]; boards[:0] = _fin      # the final's artboards come first
CW = max(b[1] + b[3] for b in boards); CH = max(b[2] + b[4] for b in boards)
svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{CW}" height="{CH}" viewBox="0 0 {CW} {CH}">'
       + "".join(out) + "</svg>")
open("greenroom-logo-candidates-v12.svg", "w").write(svg)
json.dump({"canvas": [CW, CH], "boards": boards}, open("boards.json", "w"), indent=1)
print(CW, CH, len(boards), "artboards")
