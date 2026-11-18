// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import Foundation

struct FileNode: Identifiable, Hashable {
    var id: String { path }          // project-relative path ("" for root)
    let path: String
    let name: String
    let isDirectory: Bool
    var children: [FileNode]?        // nil for files

    var ext: String { (name as NSString).pathExtension.lowercased() }
    var isText: Bool { !isDirectory && FileKind.isText(ext: ext, name: name) }
    var isImage: Bool { FileKind.imageExts.contains(ext) }
    var isPDF: Bool { ext == "pdf" }
}

enum FileKind {
    static let textExts: Set<String> = ["tex", "sty", "cls", "bib", "bst", "txt", "md", "cfg", "def", "clo", "fd", "ltx", "dtx", "ins",
                                        "csv", "dat", "json", "tikz", "code", "aux", "log", "toc", "bbl", "out", "lof", "lot", "yml", "yaml", "py", "sh", "html", "xml", "svg", "gitignore"]
    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp"]
    static func isText(ext: String, name: String) -> Bool {
        textExts.contains(ext) || (ext.isEmpty && !name.contains(".")) && !name.isEmpty && name.first != "."
            || name.hasPrefix(".") && name != ".DS_Store"
    }
}

enum FileTree {
    static let ignoredNames: Set<String> = [".DS_Store", ".git", ".svn", "node_modules"]

    /// Builds the tree for `root` (folders first, then files, case-insensitive). Hidden files are skipped except `.ipadtex.json`-style config.
    static let maxDepth = 24

    static func scan(root: URL, relative: String = "", showHidden: Bool = false, depth: Int = 0) -> [FileNode] {
        guard depth < maxDepth else { return [] }
        let dir = relative.isEmpty ? root : root.appendingPathComponent(relative)
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                                       options: []) else { return [] }
        var nodes: [FileNode] = []
        for u in items {
            let name = u.lastPathComponent
            if ignoredNames.contains(name) { continue }
            if name.hasPrefix(".") && !showHidden { continue }
            let values = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            // Symlinks could point outside the project (or form loops): don't follow or list them.
            if values?.isSymbolicLink == true { continue }
            let isDir = values?.isDirectory ?? false
            let rel = relative.isEmpty ? name : relative + "/" + name
            nodes.append(FileNode(path: rel, name: name, isDirectory: isDir,
                                  children: isDir ? scan(root: root, relative: rel, showHidden: showHidden, depth: depth + 1) : nil))
        }
        return nodes.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func flatten(_ nodes: [FileNode]) -> [FileNode] {
        nodes.flatMap { [$0] + flatten($0.children ?? []) }
    }
}
