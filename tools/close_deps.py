#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 TexPad contributors
"""Dependency closure for ./texlive: scan bundled .sty/.cls/.def/.cfg files for packages they load
(\\RequirePackage, \\usepackage, \\LoadClass, \\documentclass, \\input, \\InputIfFileExists) and copy any
that are missing from the local TeX Live, until nothing new is found."""
import os, re, shutil, subprocess, sys

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "texlive")
PKG = re.compile(r"\\(?:RequirePackage|usepackage|RequirePackageWithOptions|PassOptionsToPackage)\s*(?:\[[^\]]*\])?\s*\{([^}]+)\}")
CLS = re.compile(r"\\(?:LoadClass|LoadClassWithOptions|documentclass)\s*(?:\[[^\]]*\])?\s*\{([^}]+)\}")
INP = re.compile(r"\\(?:input|InputIfFileExists|@input)\s*\{?\s*([A-Za-z0-9_.\-]+)\}?")
SCAN_EXT = (".sty", ".cls", ".def", ".cfg", ".clo", ".fd")

def have(name):
    return any(os.path.exists(os.path.join(OUT, name + e)) for e in ("", ".sty", ".cls", ".tex", ".def", ".cfg", ".clo"))

def candidates(text):
    out = set()
    for m in PKG.finditer(text):
        for n in m.group(1).split(","):
            n = n.strip()
            if n and "#" not in n and "\\" not in n: out.add(n + ".sty")
    for m in CLS.finditer(text):
        n = m.group(1).strip()
        if n and "#" not in n and "\\" not in n: out.add(n + ".cls")
    for m in INP.finditer(text):
        n = m.group(1).strip()
        if n and "#" not in n and not n.startswith("\\"): out.add(n if "." in n else n + ".tex")
    return out

def kpse(names):
    names = sorted(names)
    found = {}
    for i in range(0, len(names), 200):
        chunk = names[i:i + 200]
        r = subprocess.run(["kpsewhich"] + chunk, capture_output=True, text=True).stdout.split("\n")
        for p in r:
            if p and os.path.isfile(p): found[os.path.basename(p)] = p
    return found

scanned = set()
total = 0
for rnd in range(8):
    todo = set()
    for f in os.listdir(OUT):
        if f in scanned or not f.endswith(SCAN_EXT): continue
        scanned.add(f)
        try: text = open(os.path.join(OUT, f), encoding="utf-8", errors="ignore").read()
        except OSError: continue
        for c in candidates(text):
            if not os.path.exists(os.path.join(OUT, c)) and not have(os.path.splitext(c)[0]) : todo.add(c)
    if not todo: break
    found = kpse(todo)
    n = 0
    for base, p in found.items():
        dst = os.path.join(OUT, base)
        if not os.path.exists(dst): shutil.copy(p, dst); n += 1
    total += n
    print(f"round {rnd + 1}: requested {len(todo)}, copied {n}")
    if n == 0: break
print(f"closure added {total} files")
