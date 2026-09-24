"""Round 3: sampled variants of F (head + body G) and A (person in the G, abstracted).

Every variant is exact geometry on a 1000 grid; radii auto-fit where a sample
would not otherwise close.
"""
from geom import rounded, circle

GAP = 45


def _rect(x0, y0, x1, y1, r):
    return [(x0, y0, r), (x1, y0, r), (x1, y1, r), (x0, y1, r)]


def head_shape(kind, cx, cy, size, r=None):
    """size = diameter / side."""
    h = size / 2
    if kind == "circle":
        return circle(cx, cy, h)
    if kind == "square":
        return rounded(_rect(cx - h, cy - h, cx + h, cy + h, size * 0.2 if r is None else r), fit=True)
    if kind == "squircle":
        return rounded(_rect(cx - h, cy - h, cx + h, cy + h, size * 0.38), fit=True)
    if kind == "diamond":
        return rounded([(cx, cy - h, 30), (cx + h, cy, 30), (cx, cy + h, 30), (cx - h, cy, 30)], fit=True)
    if kind == "quarter":           # fills a top-right corner, following the G's outer curve
        return rounded([(cx - h, cy - h, 25), (cx + h, cy - h, size * 0.9), (cx + h, cy + h, 25),
                        (cx - h, cy + h, 25)], fit=True)
    raise ValueError(kind)


# ---------------------------------------------------------------------------
# Family F: the G's right stroke is the body; the lime head sits on top of it
# ---------------------------------------------------------------------------
def fam_F(S=235, R=240, Rb=140, arm_end=1000, stem_w=300, stem_top=560, shoulder=60,
          head=None, spur=None, gap=GAP):
    """head: (kind, cx, cy, size) or None. spur: (y0, y1, x_left) hand into the counter."""
    sx0 = 1000 - stem_w
    g = [(0, 0, R), (arm_end, 0, min(70, S / 2)), (arm_end, S, min(70, S / 2)),
         (S, S, 40), (S, 1000 - S, 40), (sx0, 1000 - S, 40)]
    if spur:
        y0, y1, xl = spur[:3]
        cap = spur[3] if len(spur) > 3 else (y1 - y0) / 2     # tip radius: round cap by default
        tilt = spur[4] if len(spur) > 4 else 0                # tip raised by this much
        drop = spur[5] if len(spur) > 5 else 0                # classic G spur: tip turns down
        if drop:
            w = y1 - y0
            g += [(sx0, y1, 20), (xl + w, y1, 20), (xl + w, y1 + drop, w / 2), (xl, y1 + drop, w / 2),
                  (xl, y0, cap)]
        else:
            g += [(sx0, y1, 20), (xl, y1 - tilt, cap), (xl, y0 - tilt, cap)]
        if y0 > stem_top:                  # hand below the shoulder
            g += [(sx0, y0, 0), (sx0, stem_top, shoulder)]
    else:
        g += [(sx0, stem_top, shoulder)]
    g += [(1000, stem_top, shoulder), (1000, 1000, Rb), (0, 1000, R)]
    parts = [("G", rounded(g, fit=True), "struct")]
    if head:
        parts.append(("head", head_shape(*head), "accent"))
    return {"size": (1000, 1000), "axis": None, "parts": parts}


def F_top(kind="square", stem_top=None, stem_w=300, arm_gap=GAP, size=None, neck=GAP, head_r=60, **kw):
    """Head in the top row, over the body column; the arm stops short of it."""
    S = kw.get("S", 235)
    size = size or S
    cx = 1000 - stem_w / 2
    arm_end = 1000 - stem_w - arm_gap if size <= stem_w else cx - size / 2 - arm_gap
    cy = size / 2
    if stem_top is None:
        stem_top = size + neck
    if kind == "square":
        head = ("square", cx, cy, size, head_r)
    else:
        head = (kind, cx, cy, size)
    return fam_F(arm_end=arm_end, stem_w=stem_w, stem_top=stem_top, head=head, **kw)


# ---------------------------------------------------------------------------
# Family P: the person inside the G, reduced to fewer, plainer shapes
# ---------------------------------------------------------------------------
def fam_P(S=150, R=300, jaw="nub", head=("circle", 500, 385, 210), body="trap",
          body_box=(500, 530, 810, 250, 360), floor_dome=None, body_role="struct", head_role="accent"):
    """body_box = (axis, top, bottom, top_w, bottom_w). floor_dome = (cx, w, h) rises from the floor."""
    I = 1000 - S
    g = [(0, 0, R), (1000, 0, S / 2), (1000, S, S / 2), (S, S, R - S), (S, I, R - S)]
    if floor_dome:
        cx, w, h = floor_dome
        g += [(cx - w / 2, I, 25), (cx - w / 2, I - h, w / 2), (cx + w / 2, I - h, w / 2), (cx + w / 2, I, 25)]
    g += [(I, I, R - S)]
    if jaw == "nub":
        g += [(I, 580, 20), (760, 580, 55), (760, 470, 55), (1000, 470, 60)]
    elif jaw == "arm":
        g += [(I, 620, 20), (660, 620, 45), (660, 530, 45), (1000, 530, 60)]
    elif jaw == "bar":
        g += [(I, 640, 20), (640, 640, 60), (640, 500, 60), (1000, 500, 60)]
    elif jaw == "plain":
        g += [(I, 520, 60), (1000, 520, 60)]
    g += [(1000, 1000, R), (0, 1000, R)]
    parts = [("G", rounded(g, fit=True), "struct")]
    if body and body_box:
        ax, top, bot, tw, bw = body_box
        if body == "trap":
            b = [(ax - tw / 2, top, 60), (ax + tw / 2, top, 60), (ax + bw / 2, bot, 30), (ax - bw / 2, bot, 30)]
        elif body == "dome":           # half-disc shoulders
            b = [(ax - bw / 2, top, bw / 2), (ax + bw / 2, top, bw / 2), (ax + bw / 2, bot, 30), (ax - bw / 2, bot, 30)]
        elif body == "tomb":           # trapezoid with a fully round top
            b = [(ax - tw / 2, top, tw / 2), (ax + tw / 2, top, tw / 2), (ax + bw / 2, bot, 30), (ax - bw / 2, bot, 30)]
        elif body == "rect":
            b = _rect(ax - bw / 2, top, ax + bw / 2, bot, 50)
        elif body == "pill":
            b = _rect(ax - bw / 2, top, ax + bw / 2, bot, bw / 2)
        parts.append(("body", rounded(b, fit=True), body_role))
    if head:
        parts.append(("head", head_shape(*head), head_role))
    return {"size": (1000, 1000), "axis": None, "parts": parts}


# ---------------------------------------------------------------------------
# The samples
# ---------------------------------------------------------------------------
V = []
def v(vid, label, m): V.append((vid, label, m))

# F · where the head sits, and how long the body is
v("F01", "Reference: F as drawn", fam_F(head=("square", 850, 397.5, 300, 45)))
v("F02", "Head up top, body full height", F_top("square"))
v("F03", "Head up top, body to 420", F_top("square", stem_top=420))
v("F04", "Head up top, F's short body", F_top("square", stem_top=560))
v("F05", "Round head up top, full body", F_top("circle"))
v("F06", "Round head Ø300, full body", F_top("circle", size=300))
v("F07", "Round head, body to 420", F_top("circle", stem_top=420))
v("F08", "Quarter-round head follows the G", F_top("quarter"))
v("F09", "Squircle head up top", F_top("squircle"))
v("F10", "Diamond head (a spark)", F_top("diamond", size=280))
# F · the mouth
v("F11", "Short arm, wide mouth, round head", F_top("circle", arm_gap=240))
v("F12", "Short arm, wide mouth, square head", F_top("square", arm_gap=240))
v("F13", "Wide neck (90) under the head", F_top("circle", neck=90))
v("F14", "Narrow gaps (25) everywhere", F_top("square", arm_gap=25, neck=25))
# F · the body
v("F15", "Rounded shoulders", F_top("circle", shoulder=150))
v("F16", "Dome shoulders, square head", F_top("square", shoulder=150))
v("F17", "Slim body 220 (i-risk)", F_top("circle", stem_w=220, size=220))
v("F18", "Wide body 360, round head", F_top("circle", stem_w=360, size=280))
v("F19", "Hand into the counter at the waist", F_top("circle", spur=(560, 680, 480)))
v("F20", "Hand raised, at the shoulder", F_top("circle", stem_top=280, spur=(280, 400, 500)))
v("F21", "Short hand, square head", F_top("square", spur=(560, 680, 580)))
# F · the G's own weight and roundness
v("F22", "Light stroke 170", F_top("circle", S=170, size=220, stem_w=240))
v("F23", "Heavy stroke 290", F_top("square", S=290, size=290, stem_w=320))
v("F24", "Boxy: small radii", F_top("square", R=110, Rb=60))
v("F25", "Very round: r 420", F_top("circle", R=420, Rb=260))
v("F26", "Square bottom-right, a stance", F_top("circle", Rb=40))
# F · the head in the mouth, body longer (the literal version)
v("F27", "F, body longer, head in the mouth", fam_F(stem_top=470, head=("square", 850, 352.5, 150, 40)))
v("F28", "F, round head in the mouth", fam_F(stem_top=470, head=("circle", 850, 340, 170)))
v("F29", "Head on the arm's tip", fam_F(arm_end=640, stem_top=470, head=("circle", 850, 170, 260)))
v("F30", "Big round head overlaps the arm row", F_top("circle", size=340, arm_gap=40))

# P · the person in the G, plainer each step
v("P01", "Reference: A as drawn", fam_P())
v("P02", "Round-top body", fam_P(body="tomb"))
v("P03", "Half-disc shoulders, floating", fam_P(body="dome", body_box=(500, 560, 810, 0, 380)))
v("P04", "Shoulders rise out of the floor", fam_P(body=None, floor_dome=(500, 380, 250)))
v("P05", "Floor shoulders, plain jaw", fam_P(jaw="plain", body=None, floor_dome=(470, 380, 250), head=("circle", 470, 385, 210)))
v("P06", "Floor shoulders, arm reaches in", fam_P(jaw="arm", body=None, floor_dome=(430, 360, 250), head=("circle", 430, 385, 200)))
v("P07", "Wide low shoulders, small head", fam_P(body=None, floor_dome=(500, 480, 200), head=("circle", 500, 440, 170)))
v("P08", "Window person: square head, pane body", fam_P(head=("square", 500, 385, 200, 45), body="rect", body_box=(500, 530, 810, 0, 330)))
v("P09", "Pill body", fam_P(body="pill", body_box=(500, 530, 810, 0, 260)))
v("P10", "Head only, large", fam_P(jaw="plain", body=None, head=("circle", 470, 500, 330)))
v("P11", "Head + bar pointing at it", fam_P(jaw="bar", body=None, head=("circle", 430, 570, 200)))
v("P12", "Light G, big shoulders", fam_P(S=110, R=260, body=None, floor_dome=(500, 440, 280), head=("circle", 500, 370, 230)))
v("P13", "Heavy G, small person", fam_P(S=200, R=320, body="dome", body_box=(480, 560, 760, 0, 300), head=("circle", 480, 420, 170)))
v("P14", "Keyhole: narrow neck to the floor", fam_P(body="trap", body_box=(500, 520, 850, 110, 360)))
v("P15", "Colours swapped: lime body", fam_P(body="dome", body_box=(500, 560, 810, 0, 380), body_role="accent", head_role="struct"))
v("P16", "Square head on floor shoulders", fam_P(body=None, floor_dome=(500, 380, 250), head=("square", 500, 390, 190, 45)))
v("P17", "Boxy G, window person", fam_P(R=180, head=("square", 500, 385, 200, 40), body="rect", body_box=(500, 530, 810, 0, 330)))
v("P18", "Nub drops away: bar jaw, dome", fam_P(jaw="bar", body="dome", body_box=(420, 560, 810, 0, 340), head=("circle", 420, 420, 190)))
v("P19", "Arm jaw, round-top body", fam_P(jaw="arm", body="tomb", body_box=(430, 540, 810, 250, 330), head=("circle", 430, 390, 200)))
v("P20", "Plain jaw, pill person", fam_P(jaw="plain", body="pill", body_box=(470, 540, 810, 0, 250), head=("circle", 470, 390, 200)))
v("P21", "Shoulders + head touch the G nowhere", fam_P(jaw="plain", body="dome", body_box=(470, 600, 790, 0, 340), head=("circle", 470, 450, 180)))
v("P22", "Squircle head, round-top body", fam_P(head=("squircle", 500, 385, 210), body="tomb"))
v("P23", "Diamond head, dome", fam_P(head=("diamond", 500, 400, 230), body="dome", body_box=(500, 560, 810, 0, 380)))
v("P24", "Teacher and class: two heads", None)   # built below

# P24: a lime head with shoulders, and a smaller deep head behind: teacher + class
_p = fam_P(jaw="plain", body=None, floor_dome=(420, 330, 230), head=("circle", 420, 420, 180))
_p["parts"].insert(1, ("class", circle(640, 560, 80), "struct"))
V[-1] = ("P24", "Teacher and a student", _p)

# M · crosses between the two families
v("M01", "Round head, body to 420, round shoulders", F_top("circle", stem_top=420, shoulder=150))
v("M02", "Body to 420, hand raised", F_top("circle", stem_top=420, spur=(420, 540, 520)))
v("M03", "Square head, round shoulders, hand", F_top("square", stem_top=420, shoulder=150, spur=(560, 680, 560)))
v("M04", "Wide mouth, round shoulders, round head", F_top("circle", arm_gap=240, shoulder=150))
v("M05", "Wide neck, head Ø260", F_top("circle", size=260, neck=100))
v("M06", "Heavy G, shoulders from the floor", fam_P(S=235, R=300, jaw="plain", body=None, floor_dome=(460, 300, 190), head=("circle", 460, 450, 170)))
v("M07", "Shoulders lean on the jaw", fam_P(jaw="plain", body=None, floor_dome=(600, 420, 250), head=("circle", 600, 385, 210)))
v("M08", "Arm reaches almost to the head", fam_P(jaw="arm", body=None, floor_dome=(400, 330, 230), head=("circle", 400, 420, 200)))
v("M09", "Light G, arm, floor shoulders", fam_P(S=110, R=260, jaw="arm", body=None, floor_dome=(420, 380, 260), head=("circle", 420, 380, 210)))
v("M10", "Light head-and-body G", F_top("circle", S=150, size=200, stem_w=230, stem_top=400))
v("M11", "Boxy, square head, body to 420", F_top("square", R=110, Rb=60, stem_top=420))
v("M12", "Quarter head, body to 420, shoulders", F_top("quarter", stem_top=420, shoulder=150))

# R4 · F02 plus a hand that completes the G (the body's arm is the G's crossbar)
H = lambda **k: F_top("square", **k)
v("R01", "Hand at the waist, short", H(spur=(560, 680, 580)))
v("R02", "Hand at mid-height, the G's bar", H(spur=(480, 600, 560)))
v("R03", "Hand reaches to the counter centre", H(spur=(480, 600, 470)))
v("R04", "Long reach, 120 short of the stem", H(spur=(480, 600, 355)))
v("R05", "Thin hand 90", H(spur=(500, 590, 520)))
v("R06", "Thick hand 150", H(spur=(470, 620, 520)))
v("R07", "Square-ended hand", H(spur=(480, 600, 520, 30)))
v("R08", "Hand raised a little (tilt 50)", H(spur=(500, 620, 520, 60, 50)))
v("R09", "Hand raised more (tilt 110)", H(spur=(520, 640, 540, 60, 110)))
v("R10", "Classic G spur: hand turns down", H(spur=(470, 580, 520, 55, 0, 110)))
v("R11", "Hand at the shoulder, flush", H(stem_top=280, spur=(280, 400, 520)))
v("R12", "Low hand, just above the floor", H(spur=(600, 720, 560)))
v("R13", "Hand + rounded shoulders", H(shoulder=150, spur=(480, 600, 520)))
v("R14", "Hand + round head", F_top("circle", spur=(480, 600, 520)))
v("R15", "Hand + narrow gaps (25)", H(arm_gap=25, neck=25, spur=(480, 600, 520)))


# ---------------------------------------------------------------------------
# R5 · Y: the G's hand moves into the person, a second arm joins it
# ---------------------------------------------------------------------------
import math as _m


def capsule(p0, p1, t):
    ux, uy = p1[0] - p0[0], p1[1] - p0[1]; l = _m.hypot(ux, uy); ux, uy = ux / l, uy / l
    nx, ny = -uy * t / 2, ux * t / 2
    return rounded([(p0[0] + nx, p0[1] + ny, t / 2), (p1[0] + nx, p1[1] + ny, t / 2),
                    (p1[0] - nx, p1[1] - ny, t / 2), (p0[0] - nx, p0[1] - ny, t / 2)], fit=True)


def fam_Y(theta=45, L=200, t=90, gap=0, jaw="plain", head_d=210, body="trap", scale=1.0,
          bent=None, hands=False, v_arms=False, wave=None, reach=None, lift=0):
    """theta: arm angle above horizontal. bent: forearm angle (arms go out flat, then up).
    wave: (right_theta, left_theta). v_arms: arms spring from the chest as a V. lift: raise the person."""
    ax, feet = 500, 810
    def P(x, y):                                     # scale the person about the feet
        return (ax + (x - ax) * scale, feet + (y - feet) * scale - lift)
    top, tw, bw = 530, 250, 360
    hx, hy = P(500, 365)                             # 60 clear of the shoulders
    m = fam_P(jaw=jaw, body=None, head=None)
    parts = m["parts"]
    if body == "trap":
        b = [P(ax - tw / 2, top) + (60 * scale,), P(ax + tw / 2, top) + (60 * scale,),
             P(ax + bw / 2, feet) + (30,), P(ax - bw / 2, feet) + (30,)]
    elif body == "tomb":
        b = [P(ax - tw / 2, top) + (tw / 2 * scale,), P(ax + tw / 2, top) + (tw / 2 * scale,),
             P(ax + bw / 2, feet) + (30,), P(ax - bw / 2, feet) + (30,)]
    elif body == "dome":
        b = [P(ax - bw / 2, top + 30) + (bw / 2 * scale,), P(ax + bw / 2, top + 30) + (bw / 2 * scale,),
             P(ax + bw / 2, feet) + (30,), P(ax - bw / 2, feet) + (30,)]
    parts.append(("body", rounded(b, fit=True), "struct"))
    tt = t * scale; LL = L * scale
    arms = []
    for side in (1, -1):                              # 1 = right (the G's old hand), -1 = left
        th = theta
        if wave:
            th = wave[0] if side == 1 else wave[1]
        if v_arms:
            s0 = P(ax + side * 40, top + 110)
        else:
            s0 = P(ax + side * (tw / 2 + 5), top + t / 2 + 15)      # outer shoulder corner
        d = (side * _m.cos(_m.radians(th)), -_m.sin(_m.radians(th)))
        start = (s0[0] + d[0] * gap, s0[1] + d[1] * gap) if gap else s0
        if bent is not None:
            elbow = (start[0] + side * LL * 0.55, start[1])
            b2 = (side * _m.cos(_m.radians(bent)), -_m.sin(_m.radians(bent)))
            tip = (elbow[0] + b2[0] * LL * 0.6, elbow[1] + b2[1] * LL * 0.6)
            arms.append(capsule(start, elbow, tt)); arms.append(capsule(elbow, tip, tt))
        else:
            ln = LL if not (reach and side == 1) else reach * scale
            tip = (start[0] + d[0] * ln, start[1] + d[1] * ln)
            arms.append(capsule(start, tip, tt))
        if hands:
            parts.append((f"hand {'R' if side == 1 else 'L'}", circle(tip[0] + d[0] * (tt * 0.9), tip[1] + d[1] * (tt * 0.9), tt * 0.55), "accent"))
    for i, a in enumerate(arms):
        parts.insert(1 + i, (f"arm {i + 1}", a, "struct"))
    parts.append(("head", circle(hx, hy, head_d / 2 * scale), "accent"))
    return m


v("Y01", "Arms out flat: the G's hand joins the person", fam_Y(theta=0, L=190))
v("Y02", "Arms up 20°", fam_Y(theta=20))
v("Y03", "Arms up 35°", fam_Y(theta=35))
v("Y04", "Arms up 45°: happy", fam_Y(theta=45))
v("Y05", "Arms up 60°: cheering", fam_Y(theta=60, L=190))
v("Y06", "Arms up 75°: hands up", fam_Y(theta=75, L=180))
v("Y07", "45°, arms float free of the body", fam_Y(theta=45, gap=70, L=160))
v("Y08", "45°, thin arms 70", fam_Y(theta=45, t=70))
v("Y09", "45°, thick arms 120", fam_Y(theta=45, t=120, L=180))
v("Y10", "45°, short arms", fam_Y(theta=45, L=130))
v("Y11", "45°, long arms into the G's mouth", fam_Y(theta=40, L=250, scale=0.92))
v("Y12", "Hooray: out, then up", fam_Y(bent=90, L=230, scale=0.95))
v("Y13", "Hooray, forearms flung wide", fam_Y(bent=65, L=230, scale=0.95))
v("Y14", "45°, round-top body", fam_Y(theta=45, body="tomb"))
v("Y15", "45°, half-disc body", fam_Y(theta=45, body="dome"))
v("Y16", "45°, lime hands", fam_Y(theta=45, L=150, hands=True))
v("Y17", "V cheer from the chest", fam_Y(theta=55, v_arms=True, L=250, t=85))
v("Y18", "Waving: right up, left down", fam_Y(wave=(60, -25), L=190))
v("Y19", "45°, right hand reaches the jaw", fam_Y(theta=40, reach=300, scale=0.95))
v("Y20", "45°, the G keeps its own hand too", fam_Y(theta=45, jaw="nub", L=170))
v("Y21", "45°, bigger head", fam_Y(theta=45, head_d=240, L=190))
v("Y22", "60°, detached, lime hands", fam_Y(theta=60, gap=60, L=140, hands=True))
v("Y23", "Hooray, detached forearms", fam_Y(bent=90, L=230, scale=0.95, t=80))
v("Y24", "45°, person lifted, standing tall", fam_Y(theta=45, lift=30, scale=0.9))


# ---------------------------------------------------------------------------
# R6 · fine-tuning the finalists: one slight change per sample
# ---------------------------------------------------------------------------
def T(hand, **kw):
    """Finalist geometry with overrides. hand = (y0, y1, x_tip, cap, tilt)."""
    kw.setdefault("size", 235)
    return F_top("square", spur=hand, **kw)

R03 = (480, 600, 470, 60, 0)
R08 = (500, 620, 520, 60, 50)
def h(base, y0=None, y1=None, x=None, cap=None, tilt=None, dy=0):
    b = list(base)
    if y0 is not None: b[0] = y0
    if y1 is not None: b[1] = y1
    b[0] += dy; b[1] += dy
    if x is not None: b[2] = x
    if tilt is not None: b[4] = tilt
    b[3] = (b[1] - b[0]) / 2 if cap is None else cap
    return tuple(b)

TUNE = {
 "R03": [("Base: R03 as chosen", T(h(R03))),
         ("Hand thinner: 100", T(h(R03, 490, 590))),
         ("Hand thicker: 140", T(h(R03, 470, 610))),
         ("Reach shorter: tip at 520", T(h(R03, x=520))),
         ("Reach longer: tip at 420", T(h(R03, x=420))),
         ("Hand 40 higher", T(h(R03, dy=-40))),
         ("Hand 40 lower", T(h(R03, dy=40))),
         ("Squarer tip, r 35", T(h(R03, cap=35))),
         ("A hint of tilt: 20", T(h(R03, tilt=20))),
         ("Halfway to R08: tilt 30", T(h(R03, tilt=30))),
         ("Head smaller: 215", T(h(R03), size=215)),
         ("Head bigger: 255", T(h(R03), size=255)),
         ("Head sharper: r 35", T(h(R03), head_r=35)),
         ("Head softer: r 90", T(h(R03), head_r=90)),
         ("Neck tighter: 30", T(h(R03), neck=30)),
         ("Neck looser: 65", T(h(R03), neck=65)),
         ("Mouth tighter: 30", T(h(R03), arm_gap=30)),
         ("Mouth wider: 70", T(h(R03), arm_gap=70)),
         ("Stroke lighter: 215", T(h(R03), S=215)),
         ("Stroke heavier: 255", T(h(R03), S=255)),
         ("Body narrower: 280", T(h(R03), stem_w=280)),
         ("Body wider: 320", T(h(R03), stem_w=320)),
         ("Corners tighter: r 200", T(h(R03), R=200)),
         ("Corners rounder: r 290", T(h(R03), R=290))],
 "R08": [("Base: R08 as chosen", T(h(R08))),
         ("Tilt less: 30", T(h(R08, tilt=30))),
         ("Tilt more: 70", T(h(R08, tilt=70))),
         ("Tilt most: 90", T(h(R08, tilt=90))),
         ("Hand thinner: 100", T(h(R08, 510, 610))),
         ("Hand thicker: 140", T(h(R08, 490, 630))),
         ("Reach shorter: tip at 570", T(h(R08, x=570))),
         ("Reach longer: tip at 470", T(h(R08, x=470))),
         ("Hand 40 higher", T(h(R08, dy=-40))),
         ("Hand 40 lower", T(h(R08, dy=40))),
         ("Squarer tip, r 35", T(h(R08, cap=35))),
         ("Longer, thinner, tilt 60", T(h(R08, 505, 605, x=480, tilt=60))),
         ("Head smaller: 215", T(h(R08), size=215)),
         ("Head bigger: 255", T(h(R08), size=255)),
         ("Head sharper: r 35", T(h(R08), head_r=35)),
         ("Head softer: r 90", T(h(R08), head_r=90)),
         ("Neck tighter: 30", T(h(R08), neck=30)),
         ("Neck looser: 65", T(h(R08), neck=65)),
         ("Mouth tighter: 30", T(h(R08), arm_gap=30)),
         ("Mouth wider: 70", T(h(R08), arm_gap=70)),
         ("Stroke lighter: 215", T(h(R08), S=215)),
         ("Stroke heavier: 255", T(h(R08), S=255)),
         ("Body wider: 320", T(h(R08), stem_w=320)),
         ("Corners rounder: r 290", T(h(R08), R=290))],
}
for fin, items in TUNE.items():
    for i, (label, m) in enumerate(items):
        v(f"{fin}.{i:02d}", label, m)


# ---------------------------------------------------------------------------
# FINAL (decided 2026-09-24, revised the same day): R03's level hand, thickened to 140 for small sizes
# ---------------------------------------------------------------------------
FINAL = T(h(R03, 470, 610))          # level; the tilted try was h(R03, 470, 610, tilt=30)
FINAL_SMALL_MARK_W = 620      # at 16 and 32 px the mark is drawn larger in the tile (520 above that)


# ---------------------------------------------------------------------------
# U · the user's hand edit (2026-09-24), rebuilt as exact geometry
#   head dropped into the mouth, arm raised from the shoulder, body optionally below the base
# ---------------------------------------------------------------------------
def mark_U(drop=100, theta=12.6, hand=140, tip_x=537, head_r=75):
    S, R = 235, 240
    bx0, bx1, btop = 730, 965, 430                 # body: 235 wide, 40 under the head
    r = hand / 2; th = _m.radians(theta)
    u = (_m.cos(th), -_m.sin(th))                  # along the arm, toward the body (right and up)
    nd = (_m.sin(th), _m.cos(th))                  # the arm's downward normal
    cy_at_body = btop + r / _m.cos(th)             # the arm's top edge meets the body's top corner
    tip = (tip_x, cy_at_body + (bx0 - tip_x) * _m.tan(th))
    bot_at_body = cy_at_body + r / _m.cos(th)
    p_bot = (tip[0] - u[0] * r + nd[0] * r, tip[1] - u[1] * r + nd[1] * r)
    p_top = (tip[0] - u[0] * r - nd[0] * r, tip[1] - u[1] * r - nd[1] * r)
    g = [(0, 0, R), (655, 0, 70), (655, S, 70), (S, S, 40), (S, 1000 - S, 40),
         (bx0, 1000 - S, 40), (bx0, bot_at_body, 20), (p_bot[0], p_bot[1], r), (p_top[0], p_top[1], r),
         (bx0, btop, 30), (bx1, btop, 55)]
    if drop:
        g += [(bx1, 1000 + drop, 117), (bx0, 1000 + drop, drop), (bx0, 1000, 0)]
    else:
        g += [(bx1, 1000, 140)]
    g += [(0, 1000, R)]
    head = rounded(_rect(bx0, 155, bx1, 390, head_r), fit=True)
    return {"size": (965, 1000 + drop), "axis": (bx0 + bx1) / 2,
            "parts": [("G + person", rounded(g, fit=True), "struct"), ("head", head, "accent")]}

U_DROP = mark_U(drop=100)
U_BASE = mark_U(drop=0)


# V · the user's second edit (2026-09-24): taller G, top arm across the full width,
#     a smaller head tucked under it, raised arm, body on the base
def mark_V(W=839, arm_end=815, head=(633, 266, 180, 45), bx0=604, btop=476, hand=111, theta=13.6,
           tip_x=466, br=80, R=240, S=235):
    bx1 = W
    r = hand / 2; th = _m.radians(theta)
    u = (_m.cos(th), -_m.sin(th)); nd = (_m.sin(th), _m.cos(th))
    cy_at_body = btop + r / _m.cos(th)
    tip = (tip_x, cy_at_body + (bx0 - tip_x) * _m.tan(th))
    bot_at_body = cy_at_body + r / _m.cos(th)
    p_bot = (tip[0] - u[0] * r + nd[0] * r, tip[1] - u[1] * r + nd[1] * r)
    p_top = (tip[0] - u[0] * r - nd[0] * r, tip[1] - u[1] * r - nd[1] * r)
    g = [(0, 0, R), (arm_end, 0, 70), (arm_end, S, 70), (S, S, 40), (S, 1000 - S, 40),
         (bx0, 1000 - S, 40), (bx0, bot_at_body, 20), (p_bot[0], p_bot[1], r), (p_top[0], p_top[1], r),
         (bx0, btop, 25), (bx1, btop, 35), (bx1, 1000, br), (0, 1000, R)]
    hx, hy, hs, hr = head
    return {"size": (W, 1000), "axis": bx0 + (bx1 - bx0) / 2,
            "parts": [("G + person", rounded(g, fit=True), "struct"),
                      ("head", rounded(_rect(hx, hy, hx + hs, hy + hs, hr), fit=True), "accent")]}

V_EDIT = mark_V()
# the middle ground: the taller G and full-width arm, with the head back to 235 and gaps back to 45
V_MID = mark_V(head=(604, 280, 235, 60), btop=560, hand=120, theta=12, tip_x=480)

# THE FINAL (chosen 2026-09-24): version 2 of the user's edit, head in the mouth, arm raised,
# body on the base. Supersedes the level-hand FINAL above.
FINAL = U_BASE
