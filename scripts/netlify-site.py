#!/usr/bin/env python3
# Builds the Netlify variant of the site: docs/ copied to a build dir
# with the Zoho Schools / Raj San / reading-class phrasing generalized
# for a public audience. GitHub Pages keeps the personal story; this
# keeps the two hosts structurally identical (one source, one transform)
# so layout fixes never have to be made twice.
#
# Usage: python3 scripts/netlify-site.py <output-dir>
import re
import shutil
import sys
from pathlib import Path

REPLACEMENTS = [
    # (regex-with-flexible-whitespace, replacement)
    (r"Built for a morning reading class at Zoho Schools",
     "Built for teachers who run classes over Zoom"),
    (r"the reading doc, the meeting, the chat",
     "the lesson, the meeting, the chat"),
    (r"Today's reading", "Today's lesson"),
    (r"Page 42 today\?", "Shall we begin?"),
    (r"Page 42 ✓", "Starting now ✓"),
    (r"Students see the book <em>and</em> you\.",
     "Students see the screen <em>and</em> you."),
    (r"Chat beside the book", "Chat beside the lesson"),
    (r"Every morning at Zoho Schools, <strong>Raj San</strong> runs a reading class over\s+Zoom\.",
     "Every morning, a teacher runs a class over Zoom."),
    (r"the students should see the <em>book</em>,\s+full\s+screen",
     "the students should see the <em>material</em>, full screen"),
    (r"Drag the reading doc left, Zoom to its corner",
     "Drag the lesson left, Zoom to its corner"),
    (r"Mornings are for reading,<br>not window management\.",
     "Mornings are for teaching,<br>not window management."),
    (r"Greenroom &mdash; built for the morning readers at Zoho Schools\.|Greenroom — built for the morning readers at Zoho Schools\.",
     "Greenroom — built for morning classes everywhere."),
]

FORBIDDEN = ["Zoho Schools", "Raj San", "reading class", "Page 42", "the book"]


def main() -> None:
    out = Path(sys.argv[1])
    docs = Path(__file__).resolve().parent.parent / "docs"
    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(docs, out)

    index = out / "index.html"
    html = index.read_text()
    for pattern, replacement in REPLACEMENTS:
        html, count = re.subn(pattern, replacement, html)
        if count == 0:
            print(f"WARNING: no match for {pattern!r} - source copy changed?", file=sys.stderr)

    leftovers = [phrase for phrase in FORBIDDEN if phrase in html]
    if leftovers:
        sys.exit(f"ERROR: forbidden phrases survived the transform: {leftovers}")

    index.write_text(html)
    print(f"netlify variant written to {out} (all replacements applied, none of {FORBIDDEN} remain)")


if __name__ == "__main__":
    main()
