// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import Foundation

/// Per-project settings stored in `.ipadtex.json` at the project root.
struct ProjectSettings: Codable, Equatable {
    var mainFile: String?
    var outputDir: String = "build"
    var autoBuild: Bool = true
    var activeRecipe: String?
    var recipes: [BuildRecipe] = []

    init() {}

    /// Tolerant decoding: older files (or hand-edited ones) may lack newer keys.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        mainFile = try c.decodeIfPresent(String.self, forKey: .mainFile)
        outputDir = try c.decodeIfPresent(String.self, forKey: .outputDir) ?? "build"
        autoBuild = try c.decodeIfPresent(Bool.self, forKey: .autoBuild) ?? true
        activeRecipe = try c.decodeIfPresent(String.self, forKey: .activeRecipe)
        recipes = (try? c.decodeIfPresent([BuildRecipe].self, forKey: .recipes)) ?? []
    }

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
