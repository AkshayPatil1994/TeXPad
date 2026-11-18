#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 TexPad contributors
# Seed ./texlive (flat) with a curated core set from the local TeX Live (TEXMFDIST).
D=$(kpsewhich -var-value TEXMFDIST); OUT="$(dirname "$0")/../texlive"; mkdir -p "$OUT"
pk() { # copy all regular files under given texmf-dist subdirs, flattened
  for p in "$@"; do [ -d "$D/$p" ] && find "$D/$p" -type f \( -name '*.sty' -o -name '*.cls' -o -name '*.clo' -o -name '*.def' -o -name '*.cfg' -o -name '*.fd' -o -name '*.ltx' -o -name '*.tex' -o -name '*.txt' -o -name '*.ini' -o -name '*.sty' -o -name '*.code.tex' -o -name '*.dat' -o -name '*.def' -o -name '*.bst' -o -name '*.tfm' -o -name '*.pfb' -o -name '*.vf' -o -name '*.map' -o -name '*.enc' -o -name '*.pro' \) -exec cp -n {} "$OUT/" \; ; done
}
for p in base amsmath amsfonts amscls graphics graphics-cfg graphics-def geometry hyperref tools xcolor url etoolbox kvoptions kvsetkeys ltxcmds pdftexcmds infwarerr iftex atbegshi atveryend auxhook bigintcalc bitset etexcmds gettitlestring hycolor intcalc kvdefinekeys letltxmacro pdfescape refcount rerunfilecheck stringenc uniquecounter hobsub latexconfig l3kernel l3backend l3packages babel babel-english hyphen-english unicode-data lm cm-super booktabs enumitem float caption fancyhdr listings parskip setspace microtype titlesec natbib cleveref mathtools tcolorbox pgf tikz-cd siunitx multirow xparse bm oberdiek tex-ini-files hyph-utf8 psnfss; do pk tex/latex/$p tex/generic/$p tex/generic/hyph-utf8 tex/plain/$p tex/latex/$p/base; done
pk tex/generic/unicode-data tex/generic/hyphen tex/generic/babel tex/generic/pgf tex/generic/iftex tex/generic/oberdiek tex/generic/config tex/generic/etexcmds tex/generic/ltxcmds tex/generic/bigintcalc tex/generic/atbegshi tex/generic/infwarerr tex/generic/kvdefinekeys tex/generic/kvsetkeys tex/generic/pdfescape tex/generic/pdftexcmds tex/generic/stringenc tex/generic/gettitlestring tex/generic/bitset tex/generic/intcalc tex/generic/uniquecounter tex/generic/hycolor tex/generic/letltxmacro tex/generic/refcount tex/generic/rerunfilecheck tex/generic/atveryend tex/generic/auxhook tex/generic/epstopdf-pkg tex/latex/epstopdf-pkg tex/generic/xcolor tex/generic/booktabs
pk fonts/tfm/jknappen/ec fonts/type1/public/cm-super fonts/enc/dvips/cm-super fonts/enc/dvips/base fonts/tfm/public/cm fonts/tfm/public/amsfonts fonts/tfm/public/lm fonts/tfm/adobe/times fonts/tfm/adobe/helvetic fonts/tfm/adobe/courier fonts/tfm/public/cmextra fonts/tfm/public/latex-fonts fonts/vf/adobe fonts/enc/dvips/lm fonts/type1/public/amsfonts fonts/type1/public/lm fonts/map/pdftex/updmap fonts/type1/urw
# core files outside texmf-dist
T=$(kpsewhich -var-value TEXMFROOT); pk ../texmf-dist/tex/latex/base
for f in pdftexconfig.tex pdflatex.ini latex.ltx texsys.cfg hyphen.cfg language.dat language.def UnicodeData.txt CaseFolding.txt SpecialCasing.txt GraphemeBreakProperty.txt; do p=$(kpsewhich $f) && cp -n "$p" "$OUT/"; done
du -sh "$OUT"; ls "$OUT" | wc -l
cp "$(dirname "$0")/language.dat" "$OUT/language.dat"
