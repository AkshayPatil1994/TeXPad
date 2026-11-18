# Security

## Threat model

TexPad opens LaTeX projects you may not have written (downloaded templates, a collaborator's thesis, a zip from the internet).
A hostile project must not be able to read or write anything outside itself, run code outside the TeX sandbox, or lock up the device.

| Boundary | What protects it |
|---|---|
| TeX engine → files | The engine is WebAssembly in a `WKWebView` with a non-persistent data store. It can only ask the app for files by *name* through the `tex://` scheme handler. `PathSafety.isSafeTeXName` rejects separators, `..`, `%` and control characters, and every resolved path must stay inside the bundle / cache / `TeXExtras` folder (symlinks resolved). |
| Fonts | `/tl/fontfile/<name>` only returns files that `FontIndex` enumerated in the bundled `fonts/` or `TeXExtras/` folders (dictionary lookup, never a path join). |
| TeX engine → network | None. (The TeX engine and editor web views have no network access; git is separate, below.) The pages carry a Content-Security-Policy (`default-src 'none'`, `connect-src tex:`) and the web views refuse to navigate to anything but `tex://`. |
| Project files → app | Every project-relative path (from TeX logs, web-view messages, drag-and-drop payloads, `.ipadtex.json`, user-typed names) is validated by `PathSafety` and resolved against the project root. Symlinks are never followed or listed. `outputDir` / `mainFile` from `.ipadtex.json` are sanitised on load. |
| Build output → UI | Logs are size-capped (2 MB) and per-line capped before parsing; at most 500 diagnostics are produced. PDF link annotations other than `http`, `https`, `mailto` and in-document links are removed before display. |
| Git (the only network code) | Written in Swift, not in the web views. libgit2 is built from source (pinned commit) **without** TLS/SSH; HTTPS goes through `URLSession` so iOS does TLS 1.3 and certificate validation. Only `https://` remotes without embedded credentials are accepted (`GitURL`). Personal access tokens live in the Keychain (`…ThisDeviceOnly`), are sent only as an `Authorization` header to the host they were saved for, never put in URLs or `.git/config`, and never logged. Redirects are followed only within the same host over https. Clones start with `core.symlinks=false`; libgit2 doesn't run hooks; checkouts use the safe strategy and every path libgit2 reports is validated with `PathSafety` before TexPad touches it. |
| Runaway documents | A 120 s watchdog throws away and restarts the engine web view (infinite macro loops, out-of-memory kills). |
| Debug hooks | Environment-variable hooks (`TEXPAD_*`, `IPADTEX_*`) and the debug JS evaluator are compiled out of Release builds. |

## Known limitations (accepted or open)

- **Search/replace regexes** are user-supplied and run on the main thread; a pathological pattern can freeze the UI until it finishes.
- **No resource limit inside the engine** beyond the watchdog: a document can use lots of CPU/RAM for up to 120 s.
- **Vendored engine** (`TexPad/web/swiftlatexpdftex.*`) is a 2022 prebuilt binary; see `docs/ENGINE_PROVENANCE.md`. Rebuild it from source before a public release if you want a verifiable chain.
- **TeXExtras** files you copy in are trusted like any package: a malicious `.sty` can do anything TeX can (still inside the sandbox above).
- Free-Apple-ID builds expire after 7 days; that's an iOS signing rule, not a security feature of the app.

## Reporting a vulnerability

Open a private security advisory on the GitHub repository (or email the maintainer) rather than a public issue. Please include a minimal project that reproduces the problem.

## Regression tests

`TexPadTests/SecurityTests.swift` covers path validation, symlink escapes, the encoded-`..` traversal that once let a document read other files in the app sandbox, log-parser limits, the watchdog and PDF link sanitising.
