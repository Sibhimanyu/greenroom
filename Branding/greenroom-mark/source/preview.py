from PIL import Image, ImageDraw
from geom import *
import sys

def draw_mark(img, m, box, colours, ss):
    W, H = m["size"]; x0, y0, bw, bh = box
    s = min(bw / W, bh / H); dx = x0 + (bw - W * s) / 2; dy = y0 + (bh - H * s) / 2
    d = ImageDraw.Draw(img)
    for name, segs, role in m["parts"]:
        pts = [(x * ss, y * ss) for x, y in flatten(transform(segs, s, dx, dy))]
        d.polygon(pts, fill=colours[role])

def icon(m, px, ss=8, mode="colour"):
    N = px * ss
    img = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([100/1024*N, 100/1024*N, 924/1024*N, 924/1024*N], radius=185/1024*N, fill=DEEP)
    cols = {"struct": WHITE, "accent": LIME if mode == "colour" else WHITE}
    W, H = m["size"]; tw = 560 if W > H else 520
    th = tw * H / W
    draw_mark(img, m, ((1024 - tw) / 2 / 1024 * px, (1024 - th) / 2 / 1024 * px, tw / 1024 * px, th / 1024 * px), cols, ss)
    return img.resize((px, px), Image.LANCZOS)

if __name__ == '__main__':
    keys = sys.argv[1:] or ["A", "B", "C", "K"]
    sizes = [256, 64, 32, 16]
    row_h = 270
    board = Image.new("RGB", (40 + 300 * 2 + 400, 20 + row_h * len(keys)), "#FFFFFF")
    for i, k in enumerate(keys):
        m = MARKS[k]()
        y = 10 + i * row_h
        # colour mark on white, big
        N = 256; ss = 4
        im = Image.new("RGBA", (N * ss, N * ss), (255, 255, 255, 255))
        draw_mark(im, m, (8, 8, N - 16, N - 16), {"struct": DEEP, "accent": LIME}, ss)
        board.paste(im.resize((N, N), Image.LANCZOS), (10, y))
        x = 290
        for px in sizes:
            ic = icon(m, px)
            board.paste(ic, (x, y), ic); x += px + 16
        # dark surround for small sizes
        dark = Image.new("RGB", (120, 60), "#1E1E1E")
        for j, px in enumerate([32, 16]):
            ic = icon(m, px); dark.paste(ic, (8 + j * 50, 14), ic)
        board.paste(dark, (x, y))
    board.save("preview.png")
