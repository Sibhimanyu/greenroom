"""The mark as vector PDFs for the app's asset catalog (LogoMark): sharp at any size.

  python3 build_pdf_mark.py OUT_DIR   ->  logomark.pdf (light), logomark-dark.pdf (dark)
The geometry is explore.FINAL, written straight into PDF path operators (m / l / c / h, fill).
"""
import sys
from explore import FINAL

S = 0.1                                            # 1000-unit grid -> a 96.5 x 100 pt page
W, H = FINAL["size"]

def rgb(hexv): return " ".join(f"{int(hexv[i:i + 2], 16) / 255:.4f}" for i in (1, 3, 5))

def stream(cols):
    ops = []
    for _, segs, role in FINAL["parts"]:
        ops.append(f"{rgb(cols[role])} rg")
        for op, pts in segs:
            p = " ".join(f"{x * S:.3f} {(H - y) * S:.3f}" for x, y in pts)   # PDF is y-up
            ops.append({"M": f"{p} m", "L": f"{p} l", "C": f"{p} c", "Z": "h"}[op])
        ops.append("f")
    return "\n".join(ops).encode()

def pdf(path, cols):
    body = stream(cols)
    objs = [b"<< /Type /Catalog /Pages 2 0 R >>",
            b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {W * S:.3f} {H * S:.3f}] /Contents 4 0 R /Resources << >> >>".encode(),
            b"<< /Length %d >>\nstream\n" % len(body) + body + b"\nendstream"]
    out, offs = b"%PDF-1.4\n", []
    for i, o in enumerate(objs, 1):
        offs.append(len(out)); out += b"%d 0 obj\n" % i + o + b"\nendobj\n"
    x = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1) + b"".join(b"%010d 00000 n \n" % o for o in offs)
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, x)
    open(path, "wb").write(out)

d = sys.argv[1] if len(sys.argv) > 1 else "."
pdf(f"{d}/logomark.pdf", {"struct": "#00401C", "accent": "#78C000"})
pdf(f"{d}/logomark-dark.pdf", {"struct": "#FFFFFF", "accent": "#78C000"})
print("wrote", d)
