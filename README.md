# TexPad

A free, offline LaTeX IDE for iPad. It compiles on the device — no server, no network.

- **Engine:** pdfTeX (SwiftLaTeX WebAssembly build) in a hidden `WKWebView`, with a bundled TeX Live subset served through a `tex://` URL scheme.
- **Editor:** CodeMirror 6 (syntax highlighting, folding, bracket matching, LaTeX autocomplete, find/replace, multi-cursor) in a `WKWebView`.
- **UI:** SwiftUI, VS Code-style — activity bar, explorer, tabs, PDF preview, problems panel, command palette (⇧⌘P), quick open (⌘P).

## Features
- Open any folder from Files (security-scoped bookmarks, recent projects), create/rename/move/delete/import files, drag & drop in the explorer.
- Multi-file projects (`\input`, `\include`, images, `.bib`), `% !TEX root = …`, main-file setting (`.ipadtex.json`).
- Build (⌘B) with **selectable build recipes** — pdfLaTeX or XeLaTeX, BibTeX, automatic reruns, or your own step list (Settings → Build recipes). Only changed files are re-sent to the engine; optional build-on-save. `% !TEX program = xelatex` picks XeLaTeX automatically.
- **XeLaTeX** with fontspec, unicode-math and Unicode text, using the bundled Latin Modern, TeX Gyre, Libertinus and STIX Two fonts (iOS system fonts aren't reachable; add your own `.otf/.ttf` to TexPad/TeXExtras).
- Problems panel with click-to-jump, inline squiggles and gutter markers.
- Autocomplete: commands, environments (auto `\end`), `\usepackage`, `\documentclass`, `\cite` (from `.bib`), `\ref`/`\eqref` (from `\label`), `\input`/`\includegraphics`/`\bibliography` paths, math symbols, TikZ libraries.
- Outline, project-wide search/replace, snippet and symbol palette, extra-key bar above the soft keyboard.
- PDF preview with page controls, thumbnails and outline sidebar, fit width/page, single/continuous/two-page layout, dark PDF mode, find in PDF, print, save to Files, and a remembered position per project (the last build's PDF is shown when you reopen a project).
- Best-effort PDF ↔ source jumps (double-tap text in the PDF; "To PDF" button) based on text matching.

## Limitations
- pdfLaTeX, XeLaTeX and BibTeX only (no biber, makeindex, LuaTeX). The engines stop at the first TeX error.
- No SyncTeX (the bundled engine doesn't produce it) — jumps are text-based guesses.
- Only the packages in `texlive/` are available. Put extra `.sty`/`.cls` files in your project folder and they are picked up automatically.
- The root `.tex` file's folder is the working directory; paths are relative to the project root.

## Build from source
Requirements: Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), Node 20+ (only to rebuild the editor), a local TeX Live (only to rebuild the TeX bundle).

```sh
tools/seed_texlive.sh && python3 tools/seed_texlive_extra.py && python3 tools/close_deps.py && python3 tools/seed_fonts.py   # builds ./texlive from your local TeX Live (~350 MB, git-ignored)
cp Config/Local.xcconfig.example Config/Local.xcconfig   # then put your own Team ID in it
(cd editor-src && npm install && node build.mjs)   # rebuilds TexPad/web/editor/editor.bundle.js
xcodegen generate              # creates TexPad.xcodeproj from project.yml
open TexPad.xcodeproj          # set your Team under Signing & Capabilities, then Run
```

Developer scripts (simulator):
- `tools/run-sim.sh [Sample] [seconds] [screenshot.png]` — build, launch, optionally open a bundled sample and screenshot.
- `tools/autotest.sh <project dir> [main.tex]` — headless build of a folder; prints parsed diagnostics. Missing TeX files are copied from your local TeX Live (`tools/fetch_tex_files.py`) so the bundle converges.
- `xcodebuild test -scheme TexPad …` — unit tests (log parser, BibTeX parser, index, search, sync matching).

The first launch builds the LaTeX format file (a few seconds) and caches it.

## License
TexPad is free software under the **GNU Affero General Public License v3.0** (see [LICENSE](LICENSE)). The AGPL covers TexPad's own source and the bundled
SwiftLaTeX engine; if you distribute a modified TexPad (including to users of a hosted or sideloaded build) you must offer them the corresponding source.
Third-party components keep their own licenses — see [THIRD_PARTY.md](THIRD_PARTY.md). Security notes and the threat model are in [SECURITY.md](SECURITY.md).

Distribution note: the AGPL is not compatible with the App Store's terms unless you hold the copyright to all of the AGPL code, so TexPad is meant to be
built from source, sideloaded, or shared through TestFlight / AltStore.

## Contributing
See [CONTRIBUTING.md](CONTRIBUTING.md).
