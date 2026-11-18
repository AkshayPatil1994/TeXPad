# Vendored TeX engines

`TexPad/web/swiftlatex{pdftex,xetex,dvipdfm}.{js,wasm}` come from the SwiftLaTeX project, release `v20022022`
(`20-02-2022.zip`, SHA-256 `cf5535ffe9cdf42f7c4522e96bba4d33db10c418a7ceb24e5d80504be7de7150`),
https://github.com/SwiftLaTeX/SwiftLaTeX (AGPL-3.0).

**Reproduce:** `python3 tools/vendor_engines.py` downloads the pinned release, verifies the zip hash, applies the patches below and prints the hashes.

| File | SHA-256 (as shipped) |
|---|---|
| `swiftlatexpdftex.wasm` | `154d08cbb298191cefe1bdd9e47a909d60fc7a96fce5f2319bfc6878c5b61cf1` (unmodified) |
| `swiftlatexpdftex.js` | `a86d2533be949c11cdaf051aada36dd04464a70ac833d1d5d92b0b93af1e9f2d` |
| `swiftlatexxetex.wasm` | `dd7f4f8fe8b07b64c058683edd0298afa1998cfae461cab71bd2571e27ffb673` (unmodified) |
| `swiftlatexxetex.js` | `417a47f64cff11f1eb453e25230d10805bdb360d2b649d8b3ba87599fc5f0aed` |
| `swiftlatexdvipdfm.wasm` | `1bf8c0d424c87c1548d9d22d29251aa3308506fa6acc29d4f08dcd77ccc1f9b1` (unmodified) |
| `swiftlatexdvipdfm.js` | `c3e30f6611ed95956af31f818583969833356d12737e2c888f6e945fe57f7e7c` |

The `.wasm` binaries are untouched; only the JS worker wrappers are patched.

## Patches to the JS wrappers
All three workers:
1. `https://texlive2.swiftlatex.com/` → `tex://app/tl/` (files come from the app bundle, not a remote server).
2. `status===301` → `status===404` (our scheme handler answers 404 for missing files).

pdfTeX and XeTeX workers:
3. `compileLaTeXRoutine(opts)`: BibTeX is skipped when `opts.skipBibtex`; reading the output is skipped when `opts.produce === false` (build recipes run LaTeX and BibTeX as separate steps).
4. New `compilebibtex` message (`compileBibtexRoutine`): runs `_compileBibtex()` on its own; status 0 or 1 counts as success.

XeTeX and dvipdfmx workers:
5. `preRun` mounts every bundled/extra font as an Emscripten **lazy file** under `/fonts` (list from `tex://app/tl/fontlist.json`, contents from `tex://app/tl/fontfile/<name>`, downloaded on first read). This 2022 XeTeX build opens fonts with `FT_New_Face` on the virtual file system and reads its font inventory from `xetexfontlist.txt`, which the app generates from the font files (`FontIndex.fontListText`).

## Rebuilding from source
Build `xetex.wasm/`, `pdftex.wasm/`, `dvipdfm.wasm/` from the SwiftLaTeX repository with Emscripten (see its README), reapply the patches, update the hashes above.
A source build also lets you enable SyncTeX and drop `haltonerror`, which these prebuilt binaries don't allow.
