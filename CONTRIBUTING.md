# Contributing

Thanks for helping! TexPad is AGPL-3.0; by contributing you agree your changes are released under the same license.

## Setup
1. `brew install xcodegen` (and Node 20+ if you touch the editor).
2. `tools/seed_texlive.sh && python3 tools/seed_texlive_extra.py && python3 tools/close_deps.py` — builds the bundled TeX tree from a local TeX Live (needed to *run* builds, not to run the unit tests).
3. `tools/build-libgit2.sh` (needs `brew install cmake`) builds libgit2 into `Vendor/` — required to compile.
4. `cp Config/Local.xcconfig.example Config/Local.xcconfig` and put your own Team ID in it. Change the bundle id in `project.yml` if you need to.
5. `xcodegen generate && open TexPad.xcodeproj`.

## Guidelines
- Never edit `TexPad.xcodeproj` directly; change `project.yml`.
- Anything that touches paths or files must go through `PathSafety` and get a test in `TexPadTests/SecurityTests.swift` (see `SECURITY.md`).
- Editor changes: edit `editor-src/src`, run `node build.mjs`, commit the regenerated `TexPad/web/editor/editor.bundle.js`.
- Run the unit tests and `tools/autotest.sh Samples/Thesis` before opening a PR.
- Add the SPDX header (`AGPL-3.0-only`) to new source files.
