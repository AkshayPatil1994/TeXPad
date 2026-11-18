// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import Foundation

/// Per-project settings stored in `.ipadtex.json` at the project root.
struct ProjectSettings: Codable, Equatable {
    var mainFile: String?
    var outputDir: String = "build"
    var autoBuild: Bool = true

    static let fileName = ".ipadtex.json"

    static func load(from root: URL) -> ProjectSettings {
        guard let d = try? Data(contentsOf: root.appendingPathComponent(fileName)),
              let s = try? JSONDecoder().decode(ProjectSettings.self, from: d) else { return ProjectSettings() }
        return s
    }

    func save(to root: URL) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(self) { try? d.write(to: root.appendingPathComponent(Self.fileName), options: .atomic) }
    }
}
