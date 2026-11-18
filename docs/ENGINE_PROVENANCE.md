# Vendored TeX engine

`TexPad/web/swiftlatexpdftex.wasm` and `TexPad/web/swiftlatexpdftex.js` are the pdfTeX build from the
SwiftLaTeX project, release `v20022022` (`20-02-2022.zip`), https://github.com/SwiftLaTeX/SwiftLaTeX (AGPL-3.0).

| File | SHA-256 | Notes |
|---|---|---|
| `swiftlatexpdftex.wasm` | `154d08cbb298191cefe1bdd9e47a909d60fc7a96fce5f2319bfc6878c5b61cf1` | unmodified |
| `swiftlatexpdftex.js` (upstream) | `019ccf66c2981cc3a371ca8983f8a0f191952e28b5df3c0b41c2e3ed80f9be65` | |
| `swiftlatexpdftex.js` (as shipped) | `7299c7bdce4cfceaca3bd21ed428a0b7df4bf3ce6e56d97374324acf95f3d96d` | two edits, below |
| release zip `20-02-2022.zip` | `cf5535ffe9cdf42f7c4522e96bba4d33db10c418a7ceb24e5d80504be7de7150` | |

## Local modifications to the JS

1. `https://texlive2.swiftlatex.com/` → `tex://app/tl/` (files come from the app bundle, not a remote server).
2. `status===301` → `status===404` (our scheme handler answers 404 for missing files).
3. `compileLaTeXRoutine(opts)`: BibTeX is skipped when `opts.skipBibtex`, and reading the PDF is skipped when `opts.produce === false` (build recipes run LaTeX and BibTeX as separate steps).
4. New `compilebibtex` message (`compileBibtexRoutine`): runs `_compileBibtex()` on its own; status 0 or 1 counts as success.

## Rebuilding from source

Build `pdftex.wasm/` from the SwiftLaTeX repository with Emscripten (see its README), reapply the two edits, update the hashes above.
A source build also lets you enable SyncTeX and drop `haltonerror`, which this prebuilt binary doesn't allow.
