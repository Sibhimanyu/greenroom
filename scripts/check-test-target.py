#!/usr/bin/env python3
# Fails when a file under Tests/ names a type whose source file is not in
# GreenroomTests.sources (project.yml). The target is a curated, AppKit-free
# subset of App/, so a forgotten entry otherwise surfaces as a confusing
# "cannot find X in scope" build error.
import re, sys, glob
yml = open("project.yml").read()
block = yml.split("  GreenroomTests:")[1].split("\nschemes:")[0]
listed = set(re.findall(r"- path: (App/\S+\.swift)", block))
decl = re.compile(r"^(?:public |internal |final |private |fileprivate )*(?:struct|enum|class|actor|protocol)\s+([A-Z]\w*)", re.M)
owner = {}
for f in glob.glob("App/**/*.swift", recursive=True):
    for n in decl.findall(open(f, errors="ignore").read()):
        owner.setdefault(n, set()).add(f)
bad = {}
for t in glob.glob("Tests/**/*.swift", recursive=True):
    text = open(t, errors="ignore").read()
    # Names in comments and string literals are not references.
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    text = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', text)
    words = set(re.findall(r"\b[A-Z]\w+\b", text))
    local = set(decl.findall(text))
    for w in words - local:
        files = owner.get(w)
        if files and not (files & listed):
            bad.setdefault(t, set()).add(f"{w} ({sorted(files)[0]})")
for t, ws in sorted(bad.items()):
    print(f"error: {t} uses {', '.join(sorted(ws))}: add the file to GreenroomTests.sources")
sys.exit(1 if bad else 0)
