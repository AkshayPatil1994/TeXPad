// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import Foundation

/// Validation for every path that comes from somewhere we don't control: TeX logs, web-view messages,
/// drag-and-drop payloads, `.ipadtex.json` inside a downloaded project, and file names requested by the TeX engine.
enum PathSafety {
    /// A single file or folder name: no separators, no "." / "..", no control characters.
    static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 255, name != ".", name != ".." else { return false }
        return !name.unicodeScalars.contains { $0 == "/" || $0 == "\\" || $0.value < 0x20 || $0.value == 0x7f }
    }

    /// A project-relative path ("a/b/c.tex"): every component is a safe name, not absolute.
    static func isSafeRelative(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), path.utf8.count <= 1024 else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { isSafeName(String($0)) }
    }

    /// Resolves `relative` under `root`; nil unless the result stays inside `root` (symlinks resolved).
    static func resolve(_ relative: String, in root: URL) -> URL? {
        guard isSafeRelative(relative) else { return nil }
        let candidate = root.appendingPathComponent(relative)
        return isInside(candidate, base: root) ? candidate : nil
    }

    static func isInside(_ url: URL, base: URL) -> Bool {
        let b = base.resolvingSymlinksInPath().standardizedFileURL.path
        let u = url.resolvingSymlinksInPath().standardizedFileURL.path
        return u == b || u.hasPrefix(b.hasSuffix("/") ? b : b + "/")
    }

    /// File names kpathsea asks for ("cmr10", "article.cls"). The engine can be tricked by a hostile document into
    /// requesting names with encoded separators ("..%2f..%2fsecret"), so reject anything that isn't a plain name.
    static func isSafeTeXName(_ name: String) -> Bool {
        isSafeName(name) && !name.contains("%")
    }
}
