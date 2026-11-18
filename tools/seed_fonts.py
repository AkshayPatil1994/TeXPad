#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 TexPad contributors
"""Copies the OpenType fonts XeLaTeX/fontspec can use offline into ./fonts (flat, git-ignored).

Latin Modern, TeX Gyre (text + math), Libertinus and STIX Two — about 25 MB. iOS system fonts are not reachable
from the sandboxed engine, so anything else must be supplied by the user (project fonts/ folder or TeXExtras/fonts).
"""
import os, shutil, subprocess

D = subprocess.check_output(["kpsewhich", "-var-value", "TEXMFDIST"]).decode().strip()
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "fonts")
os.makedirs(OUT, exist_ok=True)
FAMILIES = ["lm", "lm-math", "tex-gyre", "tex-gyre-math", "libertinus-fonts", "stix2-otf"]
n = 0
for fam in FAMILIES:
    base = os.path.join(D, "fonts", "opentype", "public", fam)
    for r, _, fs in os.walk(base):
        for f in fs:
            if f.lower().endswith((".otf", ".ttf")) and not os.path.exists(os.path.join(OUT, f)):
                shutil.copy(os.path.join(r, f), os.path.join(OUT, f)); n += 1
tot = sum(os.path.getsize(os.path.join(OUT, f)) for f in os.listdir(OUT))
print(f"copied {n} fonts; fonts/ is {tot / 1e6:.1f} MB, {len(os.listdir(OUT))} files")
