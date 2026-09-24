"""Production assets for the repo, the site and the app, each on its own artboard at 1 pt = 1 px.

  lockup-colour / lockup-reversed   README header and Branding/greenroom-logo.png (light and dark)
  mark-colour-1024                  Branding/greenroom-mark.png
  site-logo-mark-256                docs/logo-mark.png (the site header shows it 34 px tall)
  app-logomark-512                  App/Assets.xcassets/LogoMark.imageset/logomark.png
  site-favicon-128                  docs/favicon.png (small-size artwork: browsers show it at 16-32 px)
  site-apple-touch-180              docs/apple-touch-icon.png
"""
import json
import build_guidelines as bg
from build_guidelines import lockup_h, mark, icon, MW, MH, WHITE, LIME, DEEP

out, boards = [], []
x = 0                                             # left edge of the next artboard
def add(name, w, h, body):
    global x
    out.append(f'<g id="{name}">{body}</g>'); boards.append((name, x, 0, w, h)); x += w + 200

H, M = 240, 40                                    # lockup: mark 240 tall, 40 margin all round
for name, dark in (("lockup-colour", False), ("lockup-reversed", True)):
    b, w = lockup_h(x + M, M, H, dark=dark)
    add(name, round(w + 2 * M), H + 2 * M, b)
add("mark-colour-1024", round(1024 * MW / MH), 1024, mark((x, 0, 1024 * MW / MH, 1024))[0])
add("site-logo-mark-256", round(256 * MW / MH), 256, mark((x, 0, 256 * MW / MH, 256))[0])
add("app-logomark-512", 512, 512, mark((x + (512 - 512 * MW / MH) / 2, 0, 512 * MW / MH, 512))[0])

# favicon: the small-size artwork (mark 620 wide in the 1024 tile) drawn at 128
k = 128 / 1024; mw = bg.FINAL_SMALL_MARK_W; mh = mw * MH / MW
fav = (bg.path(bg.transform(bg.TILE, k, x, 0), DEEP, "tile")
       + mark((x + (1024 - mw) / 2 * k, (1024 - mh) / 2 * k, mw * k, mh * k), {"struct": WHITE, "accent": LIME})[0])
add("site-favicon-128", 128, 128, fav)
add("site-apple-touch-180", 180, 180, icon(x, 0, 180, "apple touch icon"))

W = x - 200; Hc = max(b[4] for b in boards)
open("greenroom-assets.svg", "w").write(
    f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{Hc}" viewBox="0 0 {W} {Hc}">' + "".join(out) + "</svg>")
json.dump({"canvas": [W, Hc], "boards": boards}, open("assets-boards.json", "w"), indent=1)
print(W, Hc, [(b[0], b[3], b[4]) for b in boards])
