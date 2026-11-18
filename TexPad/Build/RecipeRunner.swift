// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import Foundation

struct StepRequest {
    var tool: BuildTool          // .pdflatex or .bibtex (never .rerun)
    var engine: EngineKind
    var main: String
    var produce: Bool            // LaTeX only: return the PDF
}

struct StepResult {
    var ok: Bool
    var log: String
    var pdf: Data?
    var ms: Int
}

/// Runs a single step. The real implementation talks to the WASM engine; tests use a fake.
@MainActor
protocol StepExecutor {
    func execute(_ request: StepRequest) async throws -> StepResult
}

struct RecipeOutcome {
    struct Entry { var tool: BuildTool; var log: String; var ok: Bool; var ms: Int }
    var ok: Bool
    var pdf: Data?
    var entries: [Entry] = []
    var latexRuns: Int { entries.filter { $0.tool.isLatex }.count }
    var totalMs: Int { entries.reduce(0) { $0 + $1.ms } }
    /// Logs of all steps with headers, for the Build Log panel.
    var combinedLog: String {
        entries.enumerated().map { "=== Step \($0.offset + 1): \($0.element.tool.title) (\($0.element.ms) ms) ===\n\($0.element.log)" }.joined(separator: "\n")
    }
}

/// Executes a `BuildRecipe` step by step: ordering, "only if needed" BibTeX, rerun loop, stop on failure.
@MainActor
struct RecipeRunner {
    static let maxReruns = 3
    static let maxTotalSteps = 20

    var executor: StepExecutor
    var onStep: (_ index: Int, _ total: Int, _ tool: BuildTool) -> Void = { _, _, _ in }

    func run(_ recipe: BuildRecipe, main: String) async throws -> RecipeOutcome {
        var outcome = RecipeOutcome(ok: true, pdf: nil)
        var lastLatex: BuildStep?
        var lastLatexLog = ""
        var bibtexSinceLatex = false   // BibTeX produced a new .bbl that no LaTeX pass has read yet
        let steps = recipe.steps
        let total = steps.count

        for (i, step) in steps.enumerated() {
            if outcome.entries.count >= Self.maxTotalSteps { break }
            onStep(i + 1, total, step.tool)

            switch step.tool {
            case .pdflatex, .xelatex:
                // Produce the PDF only on the final LaTeX pass (or when a rerun step follows and will refresh it anyway).
                let laterLatex = steps[(i + 1)...].contains { $0.tool.isLatex }
                let followedByRerun = i + 1 < total && steps[i + 1].tool == .rerun
                let produce = !laterLatex || followedByRerun
                let r = try await executor.execute(StepRequest(tool: step.tool, engine: step.tool.engine ?? .pdftex, main: main, produce: produce))
                outcome.entries.append(.init(tool: step.tool, log: r.log, ok: r.ok, ms: r.ms))
                lastLatex = step; lastLatexLog = r.log; bibtexSinceLatex = false
                if !r.ok { outcome.ok = false; return outcome }
                if produce { outcome.pdf = r.pdf }

            case .bibtex:
                if step.onlyIfNeeded && !Self.bibliographyNeeded(lastLatexLog) { continue }
                let r = try await executor.execute(StepRequest(tool: .bibtex, engine: lastLatex?.tool.engine ?? .pdftex, main: main, produce: false))
                // BibTeX failing (e.g. no \\bibdata) shouldn't abort the build: the next LaTeX pass reports undefined citations.
                outcome.entries.append(.init(tool: .bibtex, log: r.log, ok: r.ok, ms: r.ms))
                if r.ok { bibtexSinceLatex = true }

            case .rerun:
                guard let latex = lastLatex else { continue }
                var n = 0
                // After BibTeX the bibliography only appears once LaTeX has run again, whatever the previous log said.
                while bibtexSinceLatex || Self.rerunNeeded(lastLatexLog), n < Self.maxReruns, outcome.entries.count < Self.maxTotalSteps {
                    n += 1
                    bibtexSinceLatex = false
                    let r = try await executor.execute(StepRequest(tool: latex.tool, engine: latex.tool.engine ?? .pdftex, main: main, produce: true))
                    outcome.entries.append(.init(tool: latex.tool, log: r.log, ok: r.ok, ms: r.ms))
                    lastLatexLog = r.log
                    if !r.ok { outcome.ok = false; return outcome }
                    outcome.pdf = r.pdf
                }
            }
        }
        outcome.ok = outcome.pdf != nil
        return outcome
    }

    // MARK: log heuristics

    static func rerunNeeded(_ log: String) -> Bool {
        log.contains("Rerun to get") || log.contains("Label(s) may have changed") || log.contains("Please (re)run")
            || log.range(of: #"Package rerunfilecheck Warning: File `[^']*' has changed"#, options: .regularExpression) != nil
    }

    static func bibliographyNeeded(_ log: String) -> Bool {
        log.range(of: #"No file [^\n]*\.bbl"#, options: .regularExpression) != nil
            || log.range(of: #"Citation `[^']*' on page \d+ undefined"#, options: .regularExpression) != nil
            || log.contains("There were undefined citations")
    }
}
