import sys
from PIL import Image, ImageDraw, ImageFont
from geom import DEEP, LIME, WHITE
from preview import icon, draw_mark
from explore import V
prefix = sys.argv[1] if len(sys.argv) > 1 else ""
items = [x for x in V if x[0].startswith(prefix)]
cols = 6; cw, ch = 300, 240
img = Image.new("RGB", (cols * cw, ((len(items) + cols - 1) // cols) * ch), "#FFFFFF")
d = ImageDraw.Draw(img)
try: f = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 13)
except: f = None
for i, (vid, label, m) in enumerate(items):
    x = (i % cols) * cw; y = (i // cols) * ch
    ic = icon(m, 160); img.paste(ic, (x + 10, y + 10), ic)
    mk = Image.new("RGBA", (400, 400), (255, 255, 255, 255)); draw_mark(mk, m, (5, 5, 90, 90), {"struct": DEEP, "accent": LIME}, 4)
    mk = mk.resize((100, 100), Image.LANCZOS); img.paste(mk, (x + 176, y + 10))
    for j, px in enumerate((32, 16)):
        s = icon(m, px); img.paste(s, (x + 180 + j * 40, y + 130), s)
    d.text((x + 10, y + 180), vid, fill="#101828", font=f)
    d.text((x + 10, y + 198), label[:34], fill="#475467", font=f)
img.save(f"explore-{prefix or 'all'}.png")
print(len(items))
