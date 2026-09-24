"""Greenroom logo candidates: exact geometry.

Every shape is a polygon whose corners carry a radius. Corners become true
circular arcs (cubic approximation, handle = 4/3 tan(phi/4) r), so the
construction is exact and every radius is a deliberate number.
Units: the mark's own grid, Y down.
"""
import math

DEEP = "#00401C"
LIME = "#78C000"
WHITE = "#FFFFFF"


def _sub(a, b): return (a[0] - b[0], a[1] - b[1])
def _add(a, b): return (a[0] + b[0], a[1] + b[1])
def _mul(a, k): return (a[0] * k, a[1] * k)
def _len(a): return math.hypot(a[0], a[1])
def _norm(a):
    l = _len(a)
    return (a[0] / l, a[1] / l)


def _fit_radii(poly):
    """Shrink radii that would not fit their edges (for sampled variants)."""
    n = len(poly); pts = [p[:2] for p in poly]; r = [p[2] for p in poly]
    def t_of(i):
        a, p, b = pts[i - 1], pts[i], pts[(i + 1) % n]
        u1 = _norm(_sub(a, p)); u2 = _norm(_sub(b, p))
        th = math.acos(max(-1, min(1, u1[0] * u2[0] + u1[1] * u2[1])))
        if r[i] <= 0 or th < 1e-6 or abs(th - math.pi) < 1e-6: return 0.0
        return r[i] / math.tan(th / 2)
    for _ in range(6):
        t = [t_of(i) for i in range(n)]; ok = True
        for i in range(n):
            j = (i + 1) % n; L = _len(_sub(pts[j], pts[i]))
            if t[i] + t[j] > L + 1e-6:
                k = L / (t[i] + t[j]) * 0.999; r[i] *= k; r[j] *= k; ok = False
        if ok: break
    return [(pts[i][0], pts[i][1], r[i]) for i in range(n)]


def rounded(poly, fit=False):
    """poly: [(x, y, r)] -> list of segments ('M'|'L'|'C', pts)."""
    if fit:
        poly = _fit_radii(poly)
    n = len(poly)
    corners = []
    for i in range(n):
        p = poly[i][:2]; r = poly[i][2]
        a = poly[i - 1][:2]; b = poly[(i + 1) % n][:2]
        u1 = _norm(_sub(a, p)); u2 = _norm(_sub(b, p))
        cos_t = max(-1, min(1, u1[0] * u2[0] + u1[1] * u2[1]))
        theta = math.acos(cos_t)          # interior angle between the edges
        if r <= 0 or theta < 1e-6 or abs(theta - math.pi) < 1e-6:
            corners.append((p, p, p, p)); continue
        t = r / math.tan(theta / 2)
        phi = math.pi - theta              # arc sweep
        h = 4 / 3 * math.tan(phi / 4) * r
        t1 = _add(p, _mul(u1, t)); t2 = _add(p, _mul(u2, t))
        c1 = _add(t1, _mul(u1, -h)); c2 = _add(t2, _mul(u2, -h))
        corners.append((t1, c1, c2, t2))
    # sanity: tangents on each edge must not overlap
    for i in range(n):
        p = poly[i][:2]; q = poly[(i + 1) % n][:2]
        used = _len(_sub(corners[i][3], p)) + _len(_sub(corners[(i + 1) % n][0], q))
        if used > _len(_sub(q, p)) + 1e-6:
            raise ValueError(f"radii overlap on edge {i}: {poly[i]} -> {poly[(i+1)%n]}")
    segs = [("M", [corners[0][0]])]
    for i in range(n):
        t1, c1, c2, t2 = corners[i]
        if i > 0:
            segs.append(("L", [t1]))
        if t1 != t2:
            segs.append(("C", [c1, c2, t2]))
    segs.append(("Z", []))
    return segs


def circle(cx, cy, r):
    k = 4 / 3 * math.tan(math.pi / 8) * r
    return [("M", [(cx + r, cy)]),
            ("C", [(cx + r, cy + k), (cx + k, cy + r), (cx, cy + r)]),
            ("C", [(cx - k, cy + r), (cx - r, cy + k), (cx - r, cy)]),
            ("C", [(cx - r, cy - k), (cx - k, cy - r), (cx, cy - r)]),
            ("C", [(cx + k, cy - r), (cx + r, cy - k), (cx + r, cy)]),
            ("Z", [])]


def transform(segs, s, dx, dy):
    return [(op, [(x * s + dx, y * s + dy) for x, y in pts]) for op, pts in segs]


def d_attr(segs):
    out = []
    for op, pts in segs:
        out.append(op + " ".join(f"{x:.3f},{y:.3f}" for x, y in pts))
    return " ".join(out)


def flatten(segs, steps=24):
    """Polyline for raster previews."""
    pts = []; cur = None
    for op, p in segs:
        if op in ("M", "L"):
            cur = p[0]; pts.append(cur)
        elif op == "C":
            p0 = cur; p1, p2, p3 = p
            for k in range(1, steps + 1):
                t = k / steps; mt = 1 - t
                pts.append((mt**3 * p0[0] + 3 * mt * mt * t * p1[0] + 3 * mt * t * t * p2[0] + t**3 * p3[0],
                            mt**3 * p0[1] + 3 * mt * mt * t * p1[1] + 3 * mt * t * t * p2[1] + t**3 * p3[1]))
            cur = p3
    return pts


# ---------------------------------------------------------------------------
# A · Integrated G + person            grid 1000 x 1000, stroke 150
# ---------------------------------------------------------------------------
def mark_A():
    S, R = 150, 300           # stroke, outer radius; inner radius = R - S
    g = [(0, 0, R), (1000, 0, S / 2), (1000, S, S / 2),        # top arm, round cap
         (S, S, R - S), (S, 1000 - S, R - S),                  # counter, left side
         (1000 - S, 1000 - S, R - S),                          # counter floor -> stem
         (1000 - S, 580, 20), (760, 580, 55), (760, 470, 55),  # the jaw's nub
         (1000, 470, 60), (1000, 1000, R), (0, 1000, R)]
    ax = 500                                  # one axis for head and body
    head = circle(ax, 385, 105)               # 280..490
    body = [(ax - 125, 530, 60), (ax + 125, 530, 60),         # shoulders
            (ax + 180, 810, 30), (ax - 180, 810, 30)]         # sits 40 above the floor
    return {"size": (1000, 1000), "axis": ax,
            "parts": [("G", rounded(g), "struct"), ("body", rounded(body), "struct"),
                      ("head", head, "accent")]}


# ---------------------------------------------------------------------------
# B · Reaching G + person, with a gap  grid 1040 x 800, stroke 140
# ---------------------------------------------------------------------------
def _b_common():
    S, R = 140, 250
    ax = 820                                  # person axis
    head = circle(ax, 145, 145)               # 0..290
    body = [(ax - 190, 330, 0), (ax + 190, 330, 90),          # 40 below the head; left shoulder is the arm
            (ax + 220, 800, 40), (ax - 220, 800, 40)]         # 600..1040 at the base
    # the hand: the G's crossbar, run on through the jaw into the shoulder
    hand = [(260, 330, 60), (700, 330, 0), (700, 450, 0), (260, 450, 60)]   # top flush with the shoulder
    return S, R, ax, head, body, hand


def mark_B():
    S, R, ax, head, body, hand = _b_common()
    g = [(0, 0, R), (560, 0, 40), (560, S, 40),               # top arm
         (S, S, R - S), (S, 800 - S, R - S),                   # counter
         (420, 800 - S, 30),                                   # floor meets jaw
         (420, 390, 0), (560, 390, 0),                         # jaw top, under the hand
         (560, 800, 40), (0, 800, R)]
    return {"size": (1040, 800), "axis": ax,
            "parts": [("G", rounded(g), "struct"), ("hand", rounded(hand), "struct"),
                      ("body", rounded(body), "struct"), ("head", head, "accent")]}


def mark_C():
    """B with the G's base run on into the body: one base, a round-bottomed slot."""
    S, R, ax, head, body, hand = _b_common()
    # body's left edge at the bridge's top (y = 660)
    x_top, x_bot = ax - 190, ax - 220
    xl = x_top + (x_bot - x_top) * (660 - 330) / (800 - 330)
    base = [(0, 0, R), (560, 0, 40), (560, S, 40),
            (S, S, R - S), (S, 800 - S, R - S),
            (420, 800 - S, 30), (420, 390, 0), (560, 390, 0),
            (560, 660, 23), (xl, 660, 23),                     # slot: round bottom, no pinch
            (ax - 190, 330, 0), (ax + 190, 330, 90),
            (ax + 220, 800, 40), (0, 800, R)]
    return {"size": (1040, 800), "axis": ax,
            "parts": [("G + body", rounded(base), "struct"), ("hand", rounded(hand), "struct"),
                      ("head", head, "accent")]}


# ---------------------------------------------------------------------------
# Control · the rejected K shape (reads "Ei") -- for the comparison board only
# ---------------------------------------------------------------------------
def mark_X():
    S, R = 140, 230
    g = [(0, 0, R), (520, 0, 40), (520, S, 40), (S, S, R - S),
         (S, 330, 0), (380, 330, 50), (380, 470, 50), (S, 470, 0),    # long middle bar
         (S, 800 - S, R - S), (520, 800 - S, 40), (520, 800, 40), (0, 800, R)]
    ax = 700
    head = circle(ax, 120, 110)
    body = [(ax - 100, 290, 60), (ax + 100, 290, 60), (ax + 100, 800, 40), (ax - 100, 800, 40)]
    return {"size": (800, 800), "axis": ax,
            "parts": [("G", rounded(g), "struct"), ("body", rounded(body), "struct"),
                      ("head", head, "accent")]}


# ---------------------------------------------------------------------------
# D · Squared G + two panes (from 93a02ec7)   grid 1170 x 1000, stroke 265
# ---------------------------------------------------------------------------
def mark_D():
    S, R, gap = 265, 200, 52
    g = [(0, 0, R), (718, 0, 45), (718, S, 45),              # top arm, squared end
         (S, S, 60), (S, 1000 - S, 60),                      # counter
         (718, 1000 - S, 45), (718, 1000, 45), (0, 1000, R)]
    bar = [(S + 76, 452, 45), (718, 452, 45), (718, 624, 45), (S + 76, 624, 45)]   # floats off the stem
    x0 = 718 + gap
    lime = [(x0, 0, 70), (1170, 0, 70), (1170, 374, 70), (x0, 374, 70)]
    pane = [(x0, 374 + gap, 70), (1170, 374 + gap, 70), (1170, 1000, 70), (x0, 1000, 70)]
    return {"size": (1170, 1000), "axis": None,
            "parts": [("G", rounded(g), "struct"), ("bar", rounded(bar), "struct"),
                      ("pane", rounded(pane), "struct"), ("lime pane", rounded(lime), "accent")]}


# ---------------------------------------------------------------------------
# E · Angled panes with a carved G (from 72e596a3)   grid 1060 x 1000
# ---------------------------------------------------------------------------
def mark_E():
    # left pane: outer edge short, inner edge full height (opens like a book)
    # the G is a squared spiral channel, 80 wide, cut in from the inner edge
    left = [(0, 129, 45), (587, 0, 55),
            (587, 410, 20), (258, 410, 30), (258, 700, 30), (450, 700, 30),
            (450, 590, 15), (370, 590, 15), (370, 620, 10), (338, 620, 10), (338, 490, 10),
            (587, 490, 20),
            (587, 1000, 55), (0, 888, 45)]
    x0, x1 = 643, 1060                      # right column, 56 gap
    def top(x): return 30 + (129 - 30) * (x - x0) / (x1 - x0)
    lime = [(x0, top(x0), 40), (x1, top(x1), 40), (x1, 453, 40), (x0, 453, 40)]
    y0 = 453 + 56
    pane = [(x0, y0 + 57, 20), (x0 + 57, y0, 20), (x1 - 57, y0, 20), (x1, y0 + 57, 20),   # cut shoulders
            (x1, 888, 45), (x0, 970, 45)]
    return {"size": (1060, 1000), "axis": None,
            "parts": [("left pane + G", rounded(left), "struct"), ("pane", rounded(pane), "struct"),
                      ("lime pane", rounded(lime), "accent")]}


# ---------------------------------------------------------------------------
# F · Open G with a lime pane in the jaw (from the screenshot)   grid 1000 x 1000
# ---------------------------------------------------------------------------
def mark_F():
    S = 235
    g = [(0, 0, 240), (1000, 0, 70), (1000, S, 70),
         (S, S, 40), (S, 1000 - S, 40),
         (700, 1000 - S, 40), (700, 560, 60), (1000, 560, 60),     # jaw stem, 300 wide
         (1000, 1000, 140), (0, 1000, 240)]
    lime = [(700, 280, 45), (1000, 280, 45), (1000, 515, 45), (700, 515, 45)]   # 45 gaps above and below
    return {"size": (1000, 1000), "axis": None,
            "parts": [("G", rounded(g), "struct"), ("lime pane", rounded(lime), "accent")]}


# ===========================================================================
# Second brainstorm, 2026-09-23
# ===========================================================================
def mark_G():
    """A's enclosure with B's reach: the G's crossbar is an arm toward the person."""
    S, R = 150, 300
    g = [(0, 0, R), (1000, 0, S / 2), (1000, S, S / 2),
         (S, S, R - S), (S, 1000 - S, R - S), (1000 - S, 1000 - S, R - S),
         (1000 - S, 620, 20), (640, 620, 45), (640, 530, 45),      # the arm, round hand
         (1000, 530, 60), (1000, 1000, R), (0, 1000, R)]
    ax = 450
    head = circle(ax, 385, 105)
    body = [(ax - 125, 530, 60), (ax + 125, 530, 60), (ax + 180, 810, 30), (ax - 180, 810, 30)]
    return {"size": (1000, 1000), "axis": ax,
            "parts": [("G + arm", rounded(g), "struct"), ("body", rounded(body), "struct"),
                      ("head", head, "accent")]}


def mark_H():
    """Screen frame, open at one corner, where the camera bubble sits."""
    S, R = 150, 220
    frame = [(0, 0, R), (1000, 0, R), (1000, 540, S / 2), (850, 540, S / 2),
             (850, S, R - S), (S, S, R - S), (S, 850, R - S),
             (540, 850, S / 2), (540, 1000, S / 2), (0, 1000, R)]
    return {"size": (1000, 1000), "axis": None,
            "parts": [("screen", rounded(frame), "struct"), ("camera", circle(780, 780, 190), "accent")]}


def _g_classic(S=170, R=320):
    return [(0, 0, R), (1000, 0, S / 2), (1000, S, S / 2),
            (S, S, R - S), (S, 1000 - S, R - S), (1000 - S, 1000 - S, R - S),
            (1000 - S, 640, 20), (640, 640, 60), (640, 500, 60),   # crossbar 140
            (1000, 500, 60), (1000, 1000, R)]


def mark_I():
    """One G; a lime dot at the tip of its bar, centred in the counter."""
    g = _g_classic() + [(0, 1000, 320)]
    return {"size": (1000, 1000), "axis": None,
            "parts": [("G", rounded(g), "struct"), ("presence", circle(510, 570, 90), "accent")]}


def mark_J():
    """The G is also a speech bubble; the lime pane inside is the screen."""
    g = _g_classic() + [(330, 1000, 40), (0, 1130, 25)]            # tail at the bottom left
    screen = [(290, 290, 40), (580, 290, 40), (580, 560, 40), (290, 560, 40)]
    return {"size": (1000, 1130), "axis": None,
            "parts": [("G bubble", rounded(g), "struct"), ("screen", rounded(screen), "accent")]}


def mark_K():
    """The green room: a door frame, and the door swung open in lime."""
    S = 150
    frame = [(0, 0, 200), (700, 0, 40), (700, S, 40), (S, S, 50),
             (S, 1000 - S, 50), (700, 1000 - S, 40), (700, 1000, 40), (0, 1000, 200)]
    door = [(750, 0, 30), (1000, 110, 40), (1000, 890, 40), (750, 1000, 30)]
    return {"size": (1000, 1000), "axis": None,
            "parts": [("frame", rounded(frame), "struct"), ("open door", rounded(door), "accent")]}


def mark_L():
    """Four workspace windows, arranged so their shapes spell the G."""
    left = [(0, 0, 200), (300, 0, 60), (300, 1000, 60), (0, 1000, 200)]
    top = [(350, 0, 60), (1000, 0, 110), (1000, 260, 60), (350, 260, 60)]
    bottom = [(350, 700, 60), (1000, 700, 60), (1000, 1000, 200), (350, 1000, 60)]
    lime = [(760, 420, 50), (1000, 420, 50), (1000, 650, 50), (760, 650, 50)]   # the jaw, rising off the chat pane
    return {"size": (1000, 1000), "axis": None,
            "parts": [("screen", rounded(left), "struct"), ("meeting", rounded(top), "struct"),
                      ("chat", rounded(bottom), "struct"), ("cue", rounded(lime), "accent")]}


MARKS = {"A": mark_A, "B": mark_B, "C": mark_C, "D": mark_D, "E": mark_E, "F": mark_F, "G": mark_G, "H": mark_H, "I": mark_I, "J": mark_J, "K": mark_K, "L": mark_L, "X": mark_X}
