#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 TexPad contributors
"""Adds a broad, manuscript-oriented set of packages and fonts to ./texlive (flat dir, first copy wins).

Run after seed_texlive.sh. Uses the local TeX Live (kpsewhich -var-value TEXMFDIST).
"""
import os, re, shutil, subprocess, sys

D = subprocess.check_output(["kpsewhich", "-var-value", "TEXMFDIST"]).decode().strip()
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "texlive")
os.makedirs(OUT, exist_ok=True)

TEXT_EXT = {".sty", ".cls", ".clo", ".def", ".cfg", ".fd", ".ltx", ".tex", ".txt", ".dat", ".bst", ".cbx", ".bbx", ".lbx",
            ".code", ".ini", ".map", ".enc", ".pro", ".mst", ".ist", ".sfd", ".cmap"}
FONT_EXT = {".tfm", ".vf", ".pfb", ".enc", ".map", ".ofm", ".ovf"}

# Package directories (under tex/latex and tex/generic) commonly used by manuscripts. Missing names are ignored.
ALLOW = set("""
base amsmath amsfonts amscls graphics graphics-cfg graphics-def geometry hyperref tools xcolor url etoolbox kvoptions kvsetkeys ltxcmds
pdftexcmds infwarerr iftex atbegshi atveryend auxhook bigintcalc bitset etexcmds gettitlestring hycolor intcalc kvdefinekeys
letltxmacro pdfescape refcount rerunfilecheck stringenc uniquecounter hobsub latexconfig l3kernel l3backend l3packages l3experimental
babel babel-english lm cm-super booktabs enumitem float caption subcaption subfig fancyhdr listings parskip setspace microtype titlesec
natbib cleveref mathtools tcolorbox siunitx multirow xparse bm oberdiek psnfss soul ulem algorithm2e algorithms algorithmicx
mhchem lipsum pdfpages rotating makecell thmtools mdframed framed fancyvrb xspace comment appendix hyphenat nowidow lastpage
changepage adjustbox collectbox ifoddpage chngcntr titling abstract authblk cite wrapfig sidecap placeins epstopdf-pkg grffile todonotes
xargs paralist tocloft tocbibind nomencl glossaries glossaries-extra mfirstuc xfor datatool substr textcase varioref bookmark doi
ragged2e fullpage savetrees anyfontsize dsfont bbm upgreek cases nicefrac units physics esint braket cancel empheq mathrsfs
stmaryrd tensor leftidx extarrows xfrac pgf pgfplots circuitikz standalone import subfiles preprint ieeetran acmart elsarticle revtex
llncs svjour memoir koma-script beamer apacite achemso biblatex biblatex-apa biblatex-ieee biblatex-nature biblatex-chicago
biblatex-numeric biblatex-authoryear biblatex-trad biblatex-science csquotes xkeyval pgfopts ifmtarg ifthenx multicol array longtable
tabularx ltablex colortbl dcolumn diagbox hhline supertabular threeparttable threeparttablex tabu arydshln rotfloat endfloat
lscape pdflscape newfloat trimspace relsize xstring environ trimclip eso-pic everypage background zref hyperxmp xmpincl pdfx
pdfcomment lmodern newtx newpx newtxtt txfonts pxfonts kpfonts libertine libertinus mathpazo fourier mathdesign stix stix2
tex-gyre tgheros tgpagella tgtermes tgcursor gensymb marvosym wasysym eucal eufrak bbding cmap mathcomp stackengine scalerel
tikz-cd tikz-qtree tikz-feynman pgf-pie pgfgantt tikzmark tikzpagenodes forest chemfig chemmacros tikzscale overpic pict2e
floatrow flafter fncychap sectsty titletoc tocvsec2 multibib bibtopic chapterbib bibunits perpage footmisc footnotehyper
endnotes manyfoot bigfoot parnotes lineno linegoal mparhack marginnote snotez changes trackchanges fixme hanging
widows-and-orphans nopageno emptypage pagecolor vmargin lettrine cuted flushend stfloats balance paracol indentfirst mdwtools
shortlst tasks exam siunitx sistyle fontaxes inconsolata fontinst amsrefs ntheorem aliascnt cmbright sansmath mathastext
newunicodechar substitutefont ccicons academicons fontawesome fontawesome5 ellipsis microtype ms mwe blindtext fp pgfkeys
els-cas-templates sttools ieeetran catchfile gettitlestring filehook currfile letltxmacro expl3 xpatch regexpatch tabto fancyref cprotect shellesc
""".split())
MAX_DIR = 10**9

def has_class(p):
    """Journal / publisher / thesis templates: any package directory that ships a .cls file."""
    for _, _, fs in os.walk(p):
        if any(f.endswith(".cls") for f in fs): return True
    return False

def dir_size(p):
    t = 0
    for r, _, fs in os.walk(p):
        for f in fs:
            if os.path.splitext(f)[1] in TEXT_EXT:
                t += os.path.getsize(os.path.join(r, f))
    return t

added = 0
def copy_flat(src, exts):
    global added
    for r, _, fs in os.walk(src):
        for f in fs:
            if os.path.splitext(f)[1].lower() in exts or (not exts):
                dst = os.path.join(OUT, f)
                if not os.path.exists(dst):
                    shutil.copy(os.path.join(r, f), dst); added += 1

# --- packages --------------------------------------------------------------------------
for base in ("tex/latex", "tex/generic"):
    for d in sorted(os.listdir(os.path.join(D, base))):
        p = os.path.join(D, base, d)
        if not os.path.isdir(p): continue
        if d not in ALLOW and not (base == "tex/latex" and has_class(p) and dir_size(p) <= 2_000_000): continue
        copy_flat(p, TEXT_EXT)

# --- fonts -----------------------------------------------------------------------------
for sub in ("fonts/tfm/adobe", "fonts/tfm/urw", "fonts/tfm/urw35vf", "fonts/vf/adobe", "fonts/vf/urw", "fonts/vf/urw35vf",
            "fonts/type1/urw", "fonts/enc/dvips/base"):
    if os.path.isdir(os.path.join(D, sub)): copy_flat(os.path.join(D, sub), FONT_EXT)

FAMILIES = ["wasy", "stmaryrd", "tipa", "rsfs", "eurosym", "bbm", "bbold", "mathabx", "pxfonts", "txfonts", "newtx", "kpfonts",
            "libertine", "stix", "stix2", "mathpazo", "fourier", "mathdesign", "dsfont", "mnsymbol", "boondox", "tex-gyre", "cmbright",
            "inconsolata", "ccicons", "marvosym", "wasysym", "ifsym", "phaistos", "pigpen", "eufm", "euler", "lm-math", "cm-lgc", "bbding", "fonts-tlwg"]
for kind in ("tfm", "vf", "type1", "enc", "ofm", "ovf"):
    for fam in FAMILIES:
        for pub in ("public", "ams", "jknappen"):
            p = os.path.join(D, "fonts", kind, pub, fam)
            if os.path.isdir(p): copy_flat(p, FONT_EXT)
for sub in ("fonts/enc/dvips",):
    p = os.path.join(D, sub)
    for fam in os.listdir(p) if os.path.isdir(p) else []:
        copy_flat(os.path.join(p, fam), {".enc"})

# BibTeX styles (plainnat, IEEEtran, apalike, ...) live outside tex/
bst = os.path.join(D, "bibtex", "bst")
if os.path.isdir(bst): copy_flat(bst, {".bst"})

print(f"added {added} files")
tot = sum(os.path.getsize(os.path.join(OUT, f)) for f in os.listdir(OUT))
print(f"texlive/ is now {tot/1e6:.0f} MB, {len(os.listdir(OUT))} files")
