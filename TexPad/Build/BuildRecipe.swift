// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import Foundation

/// Tools a recipe can run. Only tools that actually exist in the bundled engines are listed (no biber, makeindex, latexmk, lualatex).
enum BuildTool: String, Codable, CaseIterable, Identifiable {
    case pdflatex
    case xelatex
    case bibtex
    case rerun      // repeat the previous LaTeX step while the log says another run is needed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pdflatex: return "pdfLaTeX"
        case .xelatex: return "XeLaTeX"
        case .bibtex: return "BibTeX"
        case .rerun: return "Rerun if needed"
        }
    }

    var isLatex: Bool { self == .pdflatex || self == .xelatex }

    /// TeX engine this tool runs in (nil for the pseudo-step).
    var engine: EngineKind? {
        switch self { case .pdflatex, .bibtex: return .pdftex; case .xelatex: return .xetex; case .rerun: return nil }
    }
}

enum EngineKind: String, Codable {
    case pdftex, xetex
    var formatFileName: String { self == .pdftex ? "swiftlatexpdftex.fmt" : "swiftlatexxetex.fmt" }
}

struct BuildStep: Codable, Equatable, Identifiable {
    var id = UUID()
    var tool: BuildTool
    /// BibTeX only: skip the step unless the previous LaTeX log shows a missing .bbl or undefined citations.
    var onlyIfNeeded: Bool = false

    enum CodingKeys: String, CodingKey { case tool, onlyIfNeeded }

    init(_ tool: BuildTool, onlyIfNeeded: Bool = false) { self.tool = tool; self.onlyIfNeeded = onlyIfNeeded }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        tool = try c.decode(BuildTool.self, forKey: .tool)
        onlyIfNeeded = try c.decodeIfPresent(Bool.self, forKey: .onlyIfNeeded) ?? false
    }
}

struct BuildRecipe: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var steps: [BuildStep]
    var isBuiltIn: Bool { Self.builtIns.contains { $0.id == id } }

    static let maxSteps = 12
    static let maxNameLength = 60

    static let pdflatexAuto = BuildRecipe(id: "pdflatex-auto", name: "pdfLaTeX (automatic)",
                                          steps: [.init(.pdflatex), .init(.bibtex, onlyIfNeeded: true), .init(.rerun)])
    static let pdflatexOnly = BuildRecipe(id: "pdflatex", name: "pdfLaTeX only", steps: [.init(.pdflatex)])
    static let pdflatexBibtex = BuildRecipe(id: "pdflatex-bibtex", name: "pdfLaTeX → BibTeX → pdfLaTeX ×2",
                                            steps: [.init(.pdflatex), .init(.bibtex), .init(.pdflatex), .init(.pdflatex)])

    static let xelatexAuto = BuildRecipe(id: "xelatex-auto", name: "XeLaTeX (automatic)",
                                         steps: [.init(.xelatex), .init(.bibtex, onlyIfNeeded: true), .init(.rerun)])
    static let xelatexBibtex = BuildRecipe(id: "xelatex-bibtex", name: "XeLaTeX → BibTeX → XeLaTeX ×2",
                                           steps: [.init(.xelatex), .init(.bibtex), .init(.xelatex), .init(.xelatex)])

    static var builtIns: [BuildRecipe] { [pdflatexAuto, pdflatexOnly, pdflatexBibtex, xelatexAuto, xelatexBibtex] }
    static var `default`: BuildRecipe { pdflatexAuto }

    /// `% !TEX program = xelatex` (TeXShop convention) in the first lines of the root file.
    static func magicProgram(in text: String) -> String? {
        for line in text.components(separatedBy: "\n").prefix(20) {
            if let m = LogParser.firstMatch(#"^\s*%\s*!T[eE]X\s+program\s*=\s*([A-Za-z]+)"#, in: line) { return m[1].lowercased() }
        }
        return nil
    }

    /// Built-in recipe for a magic-comment program name; nil for programs TexPad doesn't have (lualatex, latex, ...).
    static func recipe(forProgram p: String) -> BuildRecipe? {
        switch p { case "pdflatex": return .pdflatexAuto; case "xelatex": return .xelatexAuto; default: return nil }
    }

    /// Rejects anything a hand-edited `.ipadtex.json` could use to make builds misbehave.
    func validated() -> BuildRecipe? {
        guard !id.isEmpty, id.utf8.count <= 64, !steps.isEmpty, steps.count <= Self.maxSteps,
              steps.contains(where: { $0.tool.isLatex }) else { return nil }
        var r = self
        r.name = String(name.prefix(Self.maxNameLength))
        if r.name.trimmingCharacters(in: .whitespaces).isEmpty { r.name = "Custom recipe" }
        return r
    }

    static func newCustom(named name: String = "Custom recipe") -> BuildRecipe {
        BuildRecipe(id: "custom-" + UUID().uuidString.prefix(8).lowercased(), name: name,
                    steps: [.init(.pdflatex), .init(.bibtex, onlyIfNeeded: true), .init(.pdflatex), .init(.pdflatex)])
    }
}

extension ProjectSettings {
    /// Built-ins followed by the project's valid custom recipes.
    var allRecipes: [BuildRecipe] {
        BuildRecipe.builtIns + recipes.compactMap { $0.validated() }.filter { r in !BuildRecipe.builtIns.contains { $0.id == r.id } }
    }

    var activeRecipeResolved: BuildRecipe {
        allRecipes.first { $0.id == activeRecipe } ?? .default
    }
}
