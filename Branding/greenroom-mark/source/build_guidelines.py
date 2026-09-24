"""Greenroom brand guidelines: 13 landscape pages, one artboard and one layer each.

Follows DESIGN.md: mono uppercase eyebrows in --brand-green, ink/body/faint neutrals, lime as a
fill only (never text), danger red only for the "never do" page. SF Pro / SF Mono are the brand's
platform fonts; Illustrator here has Helvetica Neue and Menlo, so those stand in.
"""
import json, math
from PIL import ImageFont
from geom import rounded, transform, d_attr, circle, DEEP, LIME, WHITE
from explore import FINAL, FINAL_SMALL_MARK_W, U_DROP
from build_pieces import PIECES

BRAND_GREEN, INK, BODY, FAINT, LINE, SOFT = "#2F6118", "#101828", "#475467", "#98A2B3", "#EAECF0", "#F9FAFB"
DANGER, AMBER, TINT = "#B42318", "#B9770E", "#CFDDD3"
SANS, MONO = "Helvetica Neue", "Menlo"
PW, PH, GAPX, GAPY, COLS = 1920, 1080, 160, 160, 3
_F = {("n", False): ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", 100, index=0),
      ("b", False): ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", 100, index=1)}
MW, MH = FINAL["size"]; X = 235                         # x: the stroke of the G, the unit of everything


def esc(t): return t.replace("&", "&amp;").replace("<", "&lt;")
def path(segs, fill, pid, extra=""): return f'<path id="{esc(pid)}" fill="{fill}"{extra} d="{d_attr(segs)}"/>'
def rect(x, y, w, h, fill, r=0, rid="shape", extra=""):
    rr = f' rx="{r}" ry="{r}"' if r else ""
    return f'<rect id="{rid}" x="{x:.2f}" y="{y:.2f}" width="{w:.2f}" height="{h:.2f}"{rr} fill="{fill}"{extra}/>'
def line(x1, y1, x2, y2, stroke, w=2, dash=None):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    return f'<line x1="{x1:.2f}" y1="{y1:.2f}" x2="{x2:.2f}" y2="{y2:.2f}" stroke="{stroke}" stroke-width="{w}"{d}/>'
def text(x, y, s, size, fill=INK, bold=False, mono=False, anchor="start", ls=0):
    fam = MONO if mono else SANS; wt = "bold" if bold else "normal"
    l = f' letter-spacing="{ls:.2f}"' if ls else ""
    return (f'<text x="{x:.2f}" y="{y:.2f}" font-family="{fam}" font-size="{size}" font-weight="{wt}" '
            f'fill="{fill}" text-anchor="{anchor}"{l}>{esc(s)}</text>')
def width(s, size, bold=False): return _F[("b" if bold else "n", False)].getlength(s) * size / 100
def wrap(s, w, size, bold=False):
    out, cur = [], ""
    for word in s.split():
        t = (cur + " " + word).strip()
        if width(t, size, bold) > w and cur: out.append(cur); cur = word
        else: cur = t
    return out + [cur]
def para(x, y, s, w, size=24, fill=BODY, lh=1.5, bold=False):
    return [text(x, y + i * size * lh, l, size, fill, bold) for i, l in enumerate(wrap(s, w, size, bold))]


COL = {"struct": DEEP, "accent": LIME}
def mark(box, cols=COL, m=FINAL, gid="mark", extra=""):
    W, H = m["size"]; x, y, w, h = box; s = min(w / W, h / H)
    dx, dy = x + (w - W * s) / 2, y + (h - H * s) / 2
    return (f'<g id="{gid}">' + "".join(path(transform(g, s, dx, dy), cols[r], n, extra) for n, g, r in m["parts"]) + "</g>"), (s, dx, dy)

TILE = rounded([(100, 100, 185), (924, 100, 185), (924, 924, 185), (100, 924, 185)])
def icon(x, y, px, gid="app icon", mode="colour"):
    k = px / 1024; mw = FINAL_SMALL_MARK_W if px <= 32 else 520
    mh = mw * MH / MW; box = (x + (1024 - mw) / 2 * k, y + (1024 - mh) / 2 * k, mw * k, mh * k)
    cols = {"struct": WHITE, "accent": LIME if mode == "colour" else WHITE}
    return f'<g id="{esc(gid)}">' + path(transform(TILE, k, x, y), DEEP, "tile") + mark(box, cols)[0] + "</g>"

def wordmark(x, baseline, size, fill=DEEP, anchor="start"):
    return text(x, baseline, "Greenroom", size, fill, bold=True, anchor=anchor, ls=-0.025 * size)
def wordmark_w(size): return width("Greenroom", size, True) - 8 * 0.025 * size

def lockup_h(x, y, h, dark=False):
    """Horizontal lockup, mark h tall at (x, y). Gap = x; name cap height = 0.55 h."""
    cols = {"struct": WHITE, "accent": LIME} if dark else COL
    mw = h * MW / MH; gap = X / MH * h; size = 0.55 * h / 0.714
    return (mark((x, y, mw, h), cols)[0] + wordmark(x + mw + gap, y + h / 2 + 0.55 * h / 2, size, WHITE if dark else DEEP),
            mw + gap + wordmark_w(size))

def lockup_v(cx, y, h):
    mw = h * MW / MH; size = 0.42 * h / 0.714 * 1.0
    return mark((cx - mw / 2, y, mw, h))[0] + wordmark(cx, y + h + X / MH * h + 0.3 * h, size, DEEP, anchor="middle")

def check(x, y, ok=True, s=34):
    if ok:
        return (f'<polyline points="{x:.1f},{y + s * .55:.1f} {x + s * .4:.1f},{y + s * .9:.1f} {x + s:.1f},{y + s * .1:.1f}" '
                f'fill="none" stroke="{BRAND_GREEN}" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/>')
    return line(x, y, x + s, y + s, DANGER, 6) + line(x + s, y, x, y + s, DANGER, 6)


# ---------------------------------------------------------------------------------------- pages
pages, boards = [], []
TOTAL = 13
def page(n, name, eyebrow=None, title=None, lede=None, bg=WHITE, footer_fill=FAINT):
    i = n - 1; x0 = (i % COLS) * (PW + GAPX); y0 = (i // COLS) * (PH + GAPY)
    el = [rect(x0, y0, PW, PH, bg, rid="page")]
    if eyebrow:
        el.append(text(x0 + 120, y0 + 130, eyebrow.upper(), 20, BRAND_GREEN, mono=True, ls=1.6))
    if title:
        el.append(text(x0 + 120, y0 + 205, title, 60, INK, bold=True, ls=-1.2))
    if lede:
        el += para(x0 + 120, y0 + 262, lede, 1180, 24, BODY)
    el.append(text(x0 + 120, y0 + PH - 50, "Greenroom · Brand guidelines · v1.0 · September 2026", 16, footer_fill))
    el.append(text(x0 + PW - 120, y0 + PH - 50, f"{n:02d} / {TOTAL}", 16, footer_fill, mono=True, anchor="end"))
    boards.append((f"{n:02d} {name}", x0, y0, PW, PH))
    return x0, y0, el
def done(n, name, el): pages.append(f'<g id="{esc(f"{n:02d} · {name}")}">' + "".join(el) + "</g>")


# 01 cover ------------------------------------------------------------------------------------
x0, y0, el = page(1, "Cover", bg=DEEP, footer_fill="#7FA08A")
el.append(mark((x0 + 160, y0 + 230, 560 * MW / MH, 560), {"struct": WHITE, "accent": LIME})[0])
el.append(wordmark(x0 + 860, y0 + 520, 150, WHITE))
el.append(text(x0 + 866, y0 + 600, "Brand guidelines", 44, TINT))
el += [text(x0 + 866, y0 + 690 + i * 36, l, 22, TINT) for i, l in enumerate(
    ["The mark, its construction and colour, the app icon,", "the name, and how to use them. Version 1.0, September 2026."])]
done(1, "Cover", el)

# 02 the mark ----------------------------------------------------------------------------------
x0, y0, el = page(2, "The mark", "01 · The mark", "One G, and someone in it",
                  "Greenroom sets up a screen-shared class in one click. The mark is the letter G drawn as one "
                  "stroke, with the teacher standing in it: a head, a body, and an arm raised to greet the room.")
PANELS = [("The letter", {"Back of the G", "Top arm", "Bottom arm", "Body"}, "A single, heavy G. Its right side doubles as the body."),
          ("The person", {"Head", "Body", "Arm"}, "A square head over a body the same width as the stroke."),
          ("The gesture", {"Arm"}, "The arm rises from the shoulder: ready, and welcoming.")]
for j, (name, on, cap) in enumerate(PANELS):
    px = x0 + 120 + j * 570; py = y0 + 380
    el.append(rect(px, py, 530, 470, SOFT, 14, "panel"))
    s = 330 / MH; dx = px + (530 - MW * s) / 2; dy = py + 40
    for n2, segs, role in PIECES:
        fill = (LIME if role == "accent" else DEEP) if n2 in on else ("#DDE3DF" if role == "struct" else "#E4EDD6")
        el.append(path(transform(segs, s, dx, dy), fill, n2))
    el.append(text(px + 30, py + 420, name, 26, INK, bold=True))
    el += para(px + 30, py + 510, cap, 470, 20, BODY)
done(2, "The mark", el)

# 03 construction ------------------------------------------------------------------------------
x0, y0, el = page(3, "Construction", "02 · Construction", "Built on one measurement",
                  "Every part is sized from x, the stroke of the G. The head is x square and the body is x wide, "
                  "so the person and the letter are drawn with the same pen.")
m, (s, dx, dy) = mark((x0 + 200, y0 + 410, 520 * MW / MH, 520))
el.append(m)
P = lambda ux, uy: (dx + ux * s, dy + uy * s)
def dim_h(u0, u1, uy, label, above=True):
    (a, y), (b, _) = P(u0, uy), P(u1, uy)
    ty = y - 12 if above else y + 28
    return [line(a, y, b, y, FAINT, 2), line(a, y - 8, a, y + 8, FAINT, 2), line(b, y - 8, b, y + 8, FAINT, 2),
            text((a + b) / 2, ty, label, 18, BODY, mono=True, anchor="middle")]
def dim_v(ux, u0, u1, label, right=True):
    (x, a), (_, b) = P(ux, u0), P(ux, u1)
    return [line(x, a, x, b, FAINT, 2), line(x - 8, a, x + 8, a, FAINT, 2), line(x - 8, b, x + 8, b, FAINT, 2),
            text(x + (14 if right else -14), (a + b) / 2 + 6, label, 18, BODY, mono=True, anchor="start" if right else "end")]
el += dim_h(0, 235, -40, "x")
el += dim_h(730, 965, -40, "x")
el += dim_h(655, 730, -40, "0.32x")
el += dim_v(-40, 0, 235, "x", right=False)
el += dim_v(1005, 155, 390, "x")
el += dim_v(1005, 390, 430, "0.17x")
el += dim_h(730, 965, 1045, "x", above=False)
ax, _ = P(FINAL["axis"], 0)
el.append(line(ax, dy - 30, ax, dy + MH * s + 30, DANGER, 1.5, "8 5"))
el.append(text(dx + MW * s + 60, dy + MH * s * 0.62, "one axis:", 16, DANGER, mono=True))
el.append(text(dx + MW * s + 60, dy + MH * s * 0.62 + 24, "head and body", 16, DANGER, mono=True))
el.append(text(P(265, 715)[0], P(265, 715)[1], "arm 0.6x, 12.6°", 18, BODY, mono=True))
SPEC = [("x", "235 · the stroke of the G"), ("Mark", "965 × 1000 (4.1x by 4.25x)"), ("Head", "x square, corner r 75"),
        ("Body", "x wide, 0.17x below the head"), ("Arm", "0.6x thick, raised 12.6°, round tip"),
        ("Corners", "outer r 240 · bottom-right r 140 · inner r 40"), ("Mouth", "the top arm stops 0.32x short of the head"),
        ("Colour", "deep #00401C · lime #78C000 head")]
for k, (a, b) in enumerate(SPEC):
    yy = y0 + 400 + k * 62
    el += [text(x0 + 1060, yy, a.upper(), 18, BRAND_GREEN, mono=True, ls=1.4), text(x0 + 1240, yy, b, 22, INK),
           line(x0 + 1060, yy + 22, x0 + 1800, yy + 22, LINE, 1)]
done(3, "Construction", el)

# 04 clear space and minimum size -------------------------------------------------------------
x0, y0, el = page(4, "Clear space and size", "03 · Clear space and minimum size", "Give it room",
                  "Keep a clear space of at least x (one head) on every side. Nothing else enters it: no text, "
                  "no edges, no other marks.")
h = 360; mw = h * MW / MH; xu = X / MH * h; mx, my = x0 + 120 + xu + 60, y0 + 370 + xu
el.append(rect(mx - xu, my - xu, mw + 2 * xu, h + 2 * xu, "none", rid="clear space",
               extra=f' stroke="{FAINT}" stroke-width="2" stroke-dasharray="8 6"'))
for cx, cy in ((mx - xu, my - xu), (mx + mw, my - xu), (mx - xu, my + h), (mx + mw, my + h)):
    el.append(rect(cx, cy, xu, xu, "#E4EDD6", rid="x"))
    el.append(text(cx + xu / 2, cy + xu / 2 + 7, "x", 20, BRAND_GREEN, mono=True, anchor="middle"))
el.append(mark((mx, my, mw, h))[0])
bx = x0 + 1080
el.append(text(bx, y0 + 400, "MINIMUM SIZE", 18, BRAND_GREEN, mono=True, ls=1.4))
for k, (label, px) in enumerate([("Screen: 24 px tall", 24), ("Comfortable: 48 px", 48), ("Print: 8 mm tall", 23)]):
    yy = y0 + 450 + k * 120
    el.append(mark((bx, yy, px * MW / MH, px))[0])
    el.append(text(bx + 90, yy + px / 2 + 8, label, 22, INK))
el += para(bx, y0 + 830, "Smaller than this, use the app icon's small-size artwork instead of the bare mark.", 700, 20, BODY)
done(4, "Clear space and size", el)

# 05 colour ------------------------------------------------------------------------------------
x0, y0, el = page(5, "Colour", "04 · Colour", "Two greens and white",
                  "The mark uses a deep structural green and a lime highlight. Text uses its own green. "
                  "Lime is a fill, never text: it measures 2.25:1 on white.")
SW = [("Deep", "#00401C", "0 · 64 · 28", "The mark's structure, reversed grounds, high-emphasis", "12.0:1 on white", WHITE),
      ("Lime", "#78C000", "120 · 192 · 0", "The head. Fills and tints only, never text", "2.25:1 · fill only", DEEP),
      ("White", "#FFFFFF", "255 · 255 · 255", "Grounds; the mark reversed on deep", "—", INK),
      ("Brand green", "#2F6118", "47 · 97 · 24", "Links, buttons, eyebrows. Green text", "7.38:1 on white", WHITE),
      ("Ink", "#101828", "16 · 24 · 40", "Headings and primary text", "17.7:1 on white", WHITE)]
for k, (name, hexv, rgb, role, cr, tc) in enumerate(SW):
    cx = x0 + 120 + k * 344; cy = y0 + 380
    el.append(rect(cx, cy, 320, 300, hexv, 14, name, f' stroke="{LINE}" stroke-width="2"' if hexv == "#FFFFFF" else ""))
    el.append(text(cx + 24, cy + 50, name, 26, tc, bold=True))
    el += [text(cx, cy + 340, hexv, 22, INK, mono=True), text(cx, cy + 372, "RGB " + rgb, 18, BODY, mono=True),
           text(cx, cy + 402, cr, 18, BODY, mono=True)]
    el += para(cx, cy + 440, role, 300, 18, BODY, 1.45)
el.append(text(x0 + 120, y0 + 960, "Balance: deep and white carry the layout; lime is always the smallest area. "
               "No CMYK or Pantone is defined yet; proof print from these values.", 18, BODY))
done(5, "Colour", el)

# 06 versions ----------------------------------------------------------------------------------
x0, y0, el = page(6, "Versions", "05 · Versions", "Four versions, one shape",
                  "Use the colour mark wherever you can. The others exist for grounds and processes where two colours won't hold.")
VERS = [("Colour", WHITE, COL, "On white and light grounds. The default."),
        ("Reversed", DEEP, {"struct": WHITE, "accent": LIME}, "On deep green and dark grounds."),
        ("Deep green only", WHITE, {"struct": DEEP, "accent": DEEP}, "One-colour print, embossing, stamps."),
        ("White only", INK, {"struct": WHITE, "accent": WHITE}, "One colour on dark or photographic grounds.")]
for k, (name, bg, cols, use) in enumerate(VERS):
    cx = x0 + 120 + k * 430; cy = y0 + 370
    el.append(rect(cx, cy, 400, 400, bg, 14, name, f' stroke="{LINE}" stroke-width="2"' if bg == WHITE else ""))
    el.append(mark((cx + 90, cy + 80, 240 * MW / MH + 1, 240), cols)[0])
    el.append(text(cx, cy + 450, name, 24, INK, bold=True))
    el += para(cx, cy + 488, use, 390, 19, BODY)
done(6, "Versions", el)

# 07 app icon ----------------------------------------------------------------------------------
x0, y0, el = page(7, "App icon", "06 · App icon", "The app icon",
                  "The reversed mark on a deep green tile. At 32 px and below the mark is drawn larger, so the head and arm stay open.")
ix, iy = x0 + 120, y0 + 350
el.append(rect(ix, iy, 580, 580, "none", rid="canvas 1024", extra=f' stroke="{FAINT}" stroke-width="1.5" stroke-dasharray="6 5"'))
el.append(icon(ix, iy, 580, "icon, spec"))
k580 = 580 / 1024
el += [text(ix + 290, iy + 610, "canvas 1024 · tile 824, r 185 · mark 520 wide", 18, BODY, mono=True, anchor="middle")]
sx = x0 + 800; sy = y0 + 380
el.append(text(sx, sy, "SIZES, AT ACTUAL SIZE", 18, BRAND_GREEN, mono=True, ls=1.4))
xx = sx
for px in (256, 128, 64, 32, 16):
    el.append(icon(xx, sy + 30 + (256 - px), px, f"icon {px}"))
    el.append(text(xx + px / 2, sy + 330, f"{px}" + (" *" if px <= 32 else ""), 18, BODY, mono=True, anchor="middle"))
    xx += px + 50
el.append(text(sx, sy + 372, "* small-size artwork: mark 620 wide instead of 520", 18, BODY))
el.append(rect(sx, sy + 420, 960, 170, "#1E1E1E", 16, "dark ground"))
xx = sx + 40
for px in (128, 64, 32, 16):
    el.append(icon(xx, sy + 420 + (170 - px) / 2, px, f"dark {px}")); xx += px + 60
el.append(text(sx + 700, sy + 515, "on dark", 18, "#98A2B3", mono=True))
el.append(text(sx, sy + 630, "Ship it as Greenroom.icns. Plain rounded corners; Apple's continuous-corner shape is a later refinement.", 17, BODY))
done(7, "App icon", el)

# 08 wordmark and lockups ----------------------------------------------------------------------
x0, y0, el = page(8, "Wordmark and lockups", "07 · Wordmark and lockups", "With the name",
                  "Greenroom is set in the system face, bold, tracked in slightly, in deep green. The gap to the mark is x, "
                  "and the name's capitals are 0.55 of the mark's height.")
lk, w = lockup_h(x0 + 120, y0 + 380, 170)
el.append(lk)
el.append(rect(x0 + 120 - 40, y0 + 380 - 40, w + 80, 250, "none", rid="clear space",
               extra=f' stroke="{FAINT}" stroke-width="1.5" stroke-dasharray="8 6"'))
el.append(text(x0 + 120, y0 + 640, "Horizontal · the default", 20, BODY))
el.append(rect(x0 + 1100, y0 + 330, 700, 330, DEEP, 16, "deep ground"))
lk2, w2 = lockup_h(x0 + 1100 + (700 - lockup_h(0, 0, 120)[1]) / 2, y0 + 435, 120, dark=True)
el.append(lk2)
el.append(text(x0 + 1100, y0 + 690, "Reversed, on deep", 20, BODY))
el.append(lockup_v(x0 + 420, y0 + 730, 150))
el.append(text(x0 + 620, y0 + 820, "Stacked · for square spaces", 20, BODY))
el += para(x0 + 1100, y0 + 790, "Never set the name in lime, and never rebuild it in another typeface. "
           "The live text here is Helvetica Neue Bold standing in for SF Pro Bold; outline the final wordmark from SF Pro.",
           700, 19, BODY)
done(8, "Wordmark and lockups", el)

# 09 typography --------------------------------------------------------------------------------
x0, y0, el = page(9, "Typography", "08 · Typography", "The system voice",
                  "Two voices, on purpose. Prose is the human speaking, in the Mac's own face. Mono is the machine: "
                  "paths, ports, versions, anything you could paste into a terminal.")
el.append(text(x0 + 120, y0 + 600, "Aa", 260, INK, bold=True, ls=-6))
el.append(text(x0 + 120, y0 + 660, "SF Pro · display, body and UI", 22, BODY))
el.append(text(x0 + 120, y0 + 760, "01 · THE WHOLE SYSTEM", 22, BRAND_GREEN, mono=True, ls=1.8))
el.append(text(x0 + 120, y0 + 800, "SF Mono · eyebrows and machine facts", 22, BODY))
el.append(text(x0 + 120, y0 + 850, "~/Documents/Greenroom", 22, INK, mono=True))
SCALE = [("h1", 46, True, "800 · -0.025em · 1.1"), ("h2", 32, True, "800 · -0.02em · 1.15"), ("h3", 17, True, "700 · 1.3"),
         ("lede", 17.5, False, "400 · 1.6"), ("body", 16, False, "400 · 1.6"), ("caption", 14.5, False, "400 · 1.5"),
         ("micro", 13, True, "500–700 · 1.4")]
ty = y0 + 420
for role, size, bold, meta in SCALE:
    el += [text(x0 + 900, ty, role.upper(), 16, BRAND_GREEN, mono=True, ls=1.3),
           text(x0 + 1040, ty, "Set up the class", size * 1.2, INK, bold=bold),
           text(x0 + 1800, ty, f"{size}px · {meta}", 15, BODY, mono=True, anchor="end"),
           line(x0 + 900, ty + 20, x0 + 1800, ty + 20, LINE, 1)]
    ty += 78
el.append(text(x0 + 900, ty + 20, "Sizes are the site's scale. This file sets SF Pro in Helvetica Neue and SF Mono in Menlo.", 17, BODY))
done(9, "Typography", el)

# 10 backgrounds -------------------------------------------------------------------------------
x0, y0, el = page(10, "Backgrounds", "09 · Backgrounds", "Where it sits",
                  "Keep contrast high and grounds plain. On lime, switch to the deep-green-only mark so the head doesn't vanish.")
BG = [(WHITE, COL, True, "White"), (SOFT, COL, True, "Soft grey"), (DEEP, {"struct": WHITE, "accent": LIME}, True, "Deep green"),
      (INK, {"struct": WHITE, "accent": LIME}, True, "Ink"), (LIME, {"struct": DEEP, "accent": DEEP}, True, "Lime: deep only"),
      (BRAND_GREEN, COL, False, "Mid green"), (AMBER, COL, False, "Amber"), ("#8FB88A", COL, False, "Low-contrast tint")]
for k, (bg, cols, ok, name) in enumerate(BG):
    cx = x0 + 120 + (k % 4) * 430; cy = y0 + 340 + (k // 4) * 330
    el.append(rect(cx, cy, 400, 250, bg, 14, name, f' stroke="{LINE}" stroke-width="2"' if bg in (WHITE, SOFT) else ""))
    el.append(mark((cx + 200 - 75 * MW / MH, cy + 50, 150 * MW / MH, 150), cols)[0])
    el.append(check(cx, cy + 268, ok, 26))
    el.append(text(cx + 44, cy + 290, name, 20, INK))
done(10, "Backgrounds", el)

# 11 misuse ------------------------------------------------------------------------------------
x0, y0, el = page(11, "Misuse", "10 · Misuse", "Please don't",
                  "The mark only works as drawn, and the name is always written in full. Each of these breaks the letter, the person, or both.")
TW, TH = 316, 250                              # five tiles across, two rows
def cell(k):
    return x0 + 120 + (k % 5) * 340, y0 + 330 + (k // 5) * 340
defs = ('<defs><linearGradient id="bad-gradient" x1="0" y1="0" x2="1" y2="1">'
        f'<stop offset="0" stop-color="#78C000"/><stop offset="1" stop-color="#00401C"/></linearGradient></defs>')
el.append(defs)
MIS = ["Don't stretch or squash it", "Don't rotate it", "Don't recolour it", "Don't add gradients or effects",
       "Don't outline it", "Don't move the pieces", "Don't set the name in lime", "Don't use low-contrast grounds",
       "Don't use the mark as the G"]
for k, cap in enumerate(MIS):
    cx, cy = cell(k)
    el.append(rect(cx, cy, TW, TH, SOFT, 14, "tile"))
    bh = 130; bw = bh * MW / MH; bx, by = cx + (TW - bw) / 2, cy + 60
    c = (bx + bw / 2, by + bh / 2)
    if k == 0:
        el.append(f'<g transform="translate({c[0]:.1f},{c[1]:.1f}) scale(1.45,0.72) translate({-c[0]:.1f},{-c[1]:.1f})">' + mark((bx, by, bw, bh))[0] + "</g>")
    elif k == 1:
        el.append(f'<g transform="rotate(-14 {c[0]:.1f} {c[1]:.1f})">' + mark((bx, by, bw, bh))[0] + "</g>")
    elif k == 2:
        el.append(mark((bx, by, bw, bh), {"struct": "#2E6BE6", "accent": "#F2A900"})[0])
    elif k == 3:
        el.append(mark((bx, by, bw, bh), {"struct": "url(#bad-gradient)", "accent": LIME})[0])
    elif k == 4:
        el.append(mark((bx, by, bw, bh), {"struct": "none", "accent": "none"}, extra=f' stroke="{DEEP}" stroke-width="5"')[0])
    elif k == 5:
        dh = 140; dw = dh * 965 / 1100
        el.append(mark((cx + (TW - dw) / 2, by - 5, dw, dh), m=U_DROP)[0])
    elif k == 6:                                   # mark 60 tall, name at 38 in lime
        mw6 = 60 * MW / MH; x6 = cx + (TW - (mw6 + 14 + wordmark_w(38))) / 2
        el.append(mark((x6, cy + 95, mw6, 60))[0])
        el.append(wordmark(x6 + mw6 + 14, cy + 95 + 30 + 14, 38, LIME))
    elif k == 7:
        el.append(rect(cx, cy, TW, TH, "#5E8F4E", 14, "low-contrast ground"))
        el.append(mark((bx, by, bw, bh), {"struct": DEEP, "accent": LIME})[0])
    elif k == 8:                                   # the mark standing in for the name's G: reads "reenroom"
        size = 48; ch = size * 0.714; mw8 = ch * MW / MH
        rw = width("reenroom", size, True) - 7 * 0.025 * size
        x8 = cx + (TW - (mw8 + 5 + rw)) / 2; base = cy + 140
        el.append(mark((x8, base - ch, mw8, ch))[0])
        el.append(text(x8 + mw8 + 5, base, "reenroom", size, DEEP, bold=True, ls=-0.025 * size))
    el.append(check(cx, cy + 268, False, 22))
    el.append(text(cx + 36, cy + 288, cap, 18, INK))
done(11, "Misuse", el)

# 12 in use ------------------------------------------------------------------------------------
x0, y0, el = page(12, "In use", "11 · In use", "In the wild",
                  "Where people actually meet the mark: the Dock, the site header, a browser tab. Grey shapes stand in for other apps.")
dx0, dy0 = x0 + 120, y0 + 360
el.append(rect(dx0, dy0, 820, 150, "#2B2F36", 30, "dock"))
xx = dx0 + 30
for k in range(6):
    if k == 3:
        el.append(icon(xx - 8, dy0 + 11, 112, "Greenroom in the Dock"))
        el.append(f'<circle cx="{xx + 48:.1f}" cy="{dy0 + 138:.1f}" r="5" fill="#E6E8EB"/>')
    else:
        el.append(rect(xx + 8, dy0 + 27, 80, 80, ["#8A94A6", "#C0C6D0", "#6B7280", "#9AA4B2", "#B8BFC9"][k % 5], 18, "other app"))
    xx += 128
el.append(text(dx0, dy0 + 190, "The Dock, at 112 px", 20, BODY))
wx, wy = x0 + 120, y0 + 620
el.append(rect(wx, wy, 1680, 120, WHITE, 14, "site header", f' stroke="{LINE}" stroke-width="2"'))
lk, w = lockup_h(wx + 40, wy + 30, 60)
el.append(lk)
for k, lab in enumerate(["How it works", "Transparency", "Guide"]):
    el.append(text(wx + 1000 + k * 170, wy + 70, lab, 20, BRAND_GREEN, bold=True))
el.append(rect(wx + 1500, wy + 34, 140, 52, DEEP, 10, "button"))
el.append(text(wx + 1570, wy + 67, "Download", 19, WHITE, bold=True, anchor="middle"))
el.append(text(wx, wy + 160, "The site header: horizontal lockup, 60 px mark", 20, BODY))
tx, ty2 = x0 + 1060, y0 + 360
el.append(rect(tx, ty2, 740, 150, "#E9EBEE", 14, "browser"))
el.append(rect(tx + 24, ty2 + 40, 300, 70, WHITE, 12, "tab"))
el.append(icon(tx + 44, ty2 + 67, 16, "favicon"))
el.append(text(tx + 74, ty2 + 81, "Greenroom", 18, INK))
el.append(text(tx, ty2 + 190, "A browser tab: the 16 px small-size icon", 20, BODY))
done(12, "In use", el)

# 13 files -------------------------------------------------------------------------------------
x0, y0, el = page(13, "Files", "12 · Files", "The files",
                  "All of it lives in Branding/greenroom-mark/ in the Greenroom repository. Everything is exact vector geometry: start from the master, don't redraw.")
FILES = [("greenroom-logo-final.ai", "The master: construction, four versions, the app icon at every size"),
         ("greenroom-logo-pieces.ai", "Every shape on its own layer, for experiments"),
         ("greenroom-brand-guidelines.ai", "This document"),
         ("Greenroom.icns", "The macOS app icon, every size; Greenroom.iconset/ holds the PNGs"),
         ("svg/greenroom-mark-*.svg", "Colour, reversed, deep green only, white only"),
         ("svg/greenroom-app-icon*.svg", "The app icon, regular and small-size"),
         ("png/ · png-pieces/ · png-guidelines/", "Every artboard at 1:1"),
         ("brainstorm/ · source/", "The exploration that led here, and the scripts that draw it all")]
for k, (p, what) in enumerate(FILES):
    yy = y0 + 390 + k * 70
    el += [text(x0 + 120, yy, p, 22, INK, mono=True), text(x0 + 900, yy, what, 22, BODY),
           line(x0 + 120, yy + 26, x0 + 1800, yy + 26, LINE, 1)]
done(13, "Files", el)

W = COLS * PW + (COLS - 1) * GAPX; H = math.ceil(TOTAL / COLS) * (PH + GAPY) - GAPY
open("greenroom-brand-guidelines-v6.svg", "w").write(
    f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">' + "".join(pages) + "</svg>")
json.dump({"canvas": [W, H], "boards": boards}, open("guidelines-boards.json", "w"), indent=1)
print(W, H, len(boards), "pages")
