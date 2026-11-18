#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 TexPad contributors
"""Copy TeX files named in a miss log (lines 'fmt/name') from the local TeX Live
into ./texlive (flat dir). Usage: fetch_tex_files.py MISSES.txt [--out texlive]"""
import subprocess, shutil, sys, os

misses = sys.argv[1]
out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else "texlive"
os.makedirs(out, exist_ok=True)
EXTS = ["", ".tfm", ".pfb", ".vf", ".map", ".enc", ".tex", ".sty", ".cls", ".def", ".cfg", ".clo", ".fd", ".code.tex"]

def find(name):
    for e in EXTS:
        r = subprocess.run(["kpsewhich", name + e], capture_output=True, text=True).stdout.strip()
        if r and os.path.isfile(r):
            return r
    return None

found = notfound = 0
for line in sorted(set(open(misses).read().split())):
    name = line.split("/", 1)[1] if "/" in line else line
    if name.endswith(":") or any(os.path.exists(os.path.join(out, name + e)) for e in EXTS):
        continue
    src = find(name)
    if src:
        shutil.copy(src, os.path.join(out, os.path.basename(src))); found += 1
    else:
        print("NOT FOUND:", line); notfound += 1
print(f"copied {found}, not found {notfound}")
