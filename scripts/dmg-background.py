#!/usr/bin/env python3
"""Render the install-window backdrop for the release DMG.

Finder draws the disk image's two icons on top of this picture, so every
coordinate here is tied to the icon positions and window size in
scripts/make-dmg.sh - change one, change both. Output is a multi-resolution
TIFF (1x + 2x) so the artwork stays crisp on Retina displays.

    python3 scripts/dmg-background.py Branding/dmg-background.tiff

The palette is the site's (docs/index.html): #8fd06a signal green on the
near-black greens the app icon already lives on.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

# Window geometry - must match make-dmg.sh's --window-size / --icon.
WIN_W, WIN_H = 620, 400
APP_ICON = (160, 198)   # centre of Greenroom.app
DEST_ICON = (460, 198)  # centre of the Applications drop-link

FONT_PATH = "/System/Library/Fonts/SFNS.ttf"

BG_TOP = (11, 26, 17)       # deep forest, near-black
BG_BOTTOM = (18, 40, 25)
GLOW = (110, 190, 80)
SIGNAL = (143, 208, 106)    # #8fd06a - the brand's action green
TITLE_LIGHT = (238, 246, 231)
SUBTLE = (150, 176, 146)
FAINT = (131, 158, 127)

# Finder draws the icon labels itself, in the *viewer's* system text colour:
# black in light mode, white in dark. A static backdrop can't follow that, so
# each icon sits on a mid-tone card chosen to keep both legible - roughly
# 7:1 against black and 3:1 against white. Pure dark or pure light artwork
# looks great in one appearance and loses the labels entirely in the other.
CARD = (134, 160, 127)
CARD_EDGE = (166, 190, 158)
CARD_W, CARD_TOP, CARD_H, CARD_R = 176, 112, 184, 24


def font(size, weight="Regular"):
    f = ImageFont.truetype(FONT_PATH, size)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass  # non-variable fallback - shape stays right, weight may not
    return f


def centred(draw, text, fnt):
    """Width of `text`, for manual centring across mixed-colour runs."""
    return draw.textbbox((0, 0), text, font=fnt)[2]


def bezier(p0, p1, p2, steps=120):
    pts = []
    for i in range(steps + 1):
        t = i / steps
        u = 1 - t
        pts.append((
            u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0],
            u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1],
        ))
    return pts


def render(s):
    """Render the backdrop at scale factor `s` (1 or 2)."""
    W, H = WIN_W * s, WIN_H * s
    img = Image.new("RGB", (W, H), BG_TOP)

    # Vertical gradient - the window reads as one continuous surface rather
    # than a flat swatch, which flat colour makes obvious at this size.
    grad = ImageDraw.Draw(img)
    for y in range(H):
        t = y / max(H - 1, 1)
        grad.line(
            [(0, y), (W, y)],
            fill=tuple(int(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOTTOM)),
        )

    # Glow behind the app icon, echoing the light burst inside the mark.
    glow = Image.new("L", (W, H), 0)
    gd = ImageDraw.Draw(glow)
    cx, cy = APP_ICON[0] * s, APP_ICON[1] * s
    r = 74 * s
    gd.ellipse([cx - r, cy - r, cx + r, cy + r], fill=54)
    glow = glow.filter(ImageFilter.GaussianBlur(42 * s))
    img = Image.composite(Image.new("RGB", (W, H), GLOW), img, glow)

    # The two label cards, each with a soft drop shadow so it reads as a
    # raised surface rather than a flat patch.
    def card_box(centre_x):
        return [
            (centre_x - CARD_W / 2) * s, CARD_TOP * s,
            (centre_x + CARD_W / 2) * s, (CARD_TOP + CARD_H) * s,
        ]

    boxes = [card_box(APP_ICON[0]), card_box(DEST_ICON[0])]

    shadow = Image.new("L", (W, H), 0)
    shd = ImageDraw.Draw(shadow)
    for b in boxes:
        shd.rounded_rectangle(
            [b[0], b[1] + 6 * s, b[2], b[3] + 6 * s], radius=CARD_R * s, fill=120
        )
    shadow = shadow.filter(ImageFilter.GaussianBlur(11 * s))
    img = Image.composite(Image.new("RGB", (W, H), (0, 0, 0)), img, shadow)

    plate = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    pd = ImageDraw.Draw(plate)
    for b in boxes:
        pd.rounded_rectangle(
            b, radius=CARD_R * s, fill=CARD + (255,),
            outline=CARD_EDGE + (255,), width=max(1, int(s)),
        )
    img = Image.alpha_composite(img.convert("RGBA"), plate).convert("RGB")

    d = ImageDraw.Draw(img)

    # Wordmark, set as two colour runs the way the logo lockup splits it.
    f_title = font(29 * s, "Semibold")
    green, dark = "Green", "room"
    w_all = centred(d, green + dark, f_title)
    x = (W - w_all) / 2
    y = 38 * s
    d.text((x, y), green, font=f_title, fill=SIGNAL)
    d.text((x + centred(d, green, f_title), y), dark, font=f_title, fill=TITLE_LIGHT)

    # Instruction line.
    f_sub = font(13 * s, "Regular")
    sub = "Drag Greenroom into your Applications folder"
    d.text(((W - centred(d, sub, f_sub)) / 2, 84 * s), sub, font=f_sub, fill=SUBTLE)

    # The arrow: a shallow arc between the two icon slots. It starts and ends
    # clear of the 128px icons so Finder's artwork never collides with it.
    y_mid = APP_ICON[1] * s
    start = (APP_ICON[0] * s + 104 * s, y_mid)
    end = (DEST_ICON[0] * s - 104 * s, y_mid)
    ctrl = ((start[0] + end[0]) / 2, y_mid - 30 * s)
    curve = bezier(start, ctrl, end)

    shaft = Image.new("L", (W, H), 0)
    sd = ImageDraw.Draw(shaft)
    sd.line(curve, fill=255, width=int(4.5 * s), joint="curve")

    # Arrowhead aimed down the curve's final tangent.
    ax, ay = curve[-1]
    px, py = curve[-6]
    dx, dy = ax - px, ay - py
    ln = max((dx * dx + dy * dy) ** 0.5, 1e-6)
    dx, dy = dx / ln, dy / ln
    nx, ny = -dy, dx
    L, Wd = 17 * s, 9 * s
    sd.polygon(
        [
            (ax + dx * L, ay + dy * L),
            (ax - dx * 2 + nx * Wd, ay - dy * 2 + ny * Wd),
            (ax - dx * 2 - nx * Wd, ay - dy * 2 - ny * Wd),
        ],
        fill=255,
    )

    # Soft halo under the arrow so it sits in the scene instead of on it.
    halo = shaft.filter(ImageFilter.GaussianBlur(7 * s)).point(lambda v: int(v * 0.55))
    img = Image.composite(Image.new("RGB", (W, H), GLOW), img, halo)
    img = Image.composite(Image.new("RGB", (W, H), SIGNAL), img, shaft)

    # Gatekeeper hint - the one thing every first-time installer trips on.
    # Re-bind the draw handle: Image.composite above returned a new image, so
    # the old one now points at an orphan.
    d = ImageDraw.Draw(img)
    f_foot = font(11 * s, "Regular")
    foot = "First launch: System Settings › Privacy & Security › Open Anyway"
    # Kept well above WIN_H: Finder's title bar and status bar eat ~50pt of
    # the window, so the last ~50pt of this artwork is never on screen.
    d.text(((W - centred(d, foot, f_foot)) / 2, 320 * s), foot, font=f_foot, fill=FAINT)

    return img


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "Branding/dmg-background.tiff")
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        one, two = Path(tmp) / "1x.png", Path(tmp) / "2x.png"
        render(1).save(one)
        render(2).save(two)
        # tiffutil packs both scales into one file; Finder picks per display.
        subprocess.run(
            ["tiffutil", "-cathidpicheck", str(one), str(two), "-out", str(out)],
            check=True, capture_output=True,
        )
    print(f"wrote {out} ({WIN_W}x{WIN_H} @1x+@2x)")


if __name__ == "__main__":
    main()
