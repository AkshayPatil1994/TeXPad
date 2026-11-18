// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import XCTest
@testable import TexPad

/// Scripted executor: returns the queued result for each call and records the requests.
@MainActor
final class FakeExecutor: StepExecutor {
    var script: [StepResult]
    private(set) var requests: [StepRequest] = []
    init(_ script: [StepResult]) { self.script = script }
    func execute(_ request: StepRequest) async throws -> StepResult {
        requests.append(request)
        let r = script.isEmpty ? StepResult(ok: true, log: "", pdf: request.produce ? Data([1]) : nil, ms: 1) : script.removeFirst()
        if request.produce, r.ok, r.pdf == nil { return StepResult(ok: true, log: r.log, pdf: Data([9]), ms: r.ms) }
        return r
    }
}

@MainActor
final class RecipeTests: XCTestCase {
    private func ok(_ log: String = "") -> StepResult { StepResult(ok: true, log: log, pdf: nil, ms: 5) }
    private func fail(_ log: String = "! Undefined control sequence.") -> StepResult { StepResult(ok: false, log: log, pdf: nil, ms: 5) }

    func testExplicitRecipeRunsAllStepsAndProducesOnlyOnLastLatex() async throws {
        let fake = FakeExecutor([])
        let out = try await RecipeRunner(executor: fake).run(.pdflatexBibtex, main: "main.tex")
        XCTAssertEqual(fake.requests.map(\.tool), [.pdflatex, .bibtex, .pdflatex, .pdflatex])
        XCTAssertEqual(fake.requests.map(\.produce), [false, false, false, true])
        XCTAssertTrue(out.ok)
        XCTAssertNotNil(out.pdf)
        XCTAssertEqual(out.latexRuns, 3)
    }

    func testAutoSkipsBibtexWithoutCitationsAndStopsAfterOnePass() async throws {
        let fake = FakeExecutor([ok("(main.tex)\nOutput written")])
        let out = try await RecipeRunner(executor: fake).run(.pdflatexAuto, main: "main.tex")
        XCTAssertEqual(fake.requests.map(\.tool), [.pdflatex])
        XCTAssertTrue(out.ok)
    }

    func testAutoRunsBibtexWhenBblMissingThenReruns() async throws {
        let fake = FakeExecutor([
            ok("LaTeX Warning: Citation `k' on page 1 undefined on input line 3.\nNo file main.bbl."),
            ok("Warning--I didn't find a database entry"),                       // bibtex
            ok("LaTeX Warning: Label(s) may have changed. Rerun to get cross-references right."),
            ok("all good"),
        ])
        let out = try await RecipeRunner(executor: fake).run(.pdflatexAuto, main: "main.tex")
        XCTAssertEqual(fake.requests.map(\.tool), [.pdflatex, .bibtex, .pdflatex, .pdflatex])
        XCTAssertTrue(out.ok)
    }

    func testBibtexAlwaysTriggersAFollowUpPass() async throws {
        // The first log says nothing about "Rerun", but BibTeX just wrote a .bbl nobody has read yet.
        let fake = FakeExecutor([ok("No file main.bbl."), ok(), ok("done")])
        _ = try await RecipeRunner(executor: fake).run(.pdflatexAuto, main: "main.tex")
        XCTAssertEqual(fake.requests.map(\.tool), [.pdflatex, .bibtex, .pdflatex])
    }

    func testRerunIsCapped() async throws {
        let again = ok("Rerun to get cross-references right.")
        let fake = FakeExecutor([again, again, again, again, again, again])
        _ = try await RecipeRunner(executor: fake).run(.pdflatexAuto, main: "main.tex")
        XCTAssertEqual(fake.requests.filter { $0.tool == .pdflatex }.count, 1 + RecipeRunner.maxReruns)
    }

    func testFailureStopsTheRecipe() async throws {
        let fake = FakeExecutor([ok(), ok(), fail()])      // pdflatex, bibtex, then the second pdflatex fails
        let out = try await RecipeRunner(executor: fake).run(.pdflatexBibtex, main: "main.tex")
        XCTAssertEqual(fake.requests.count, 3)
        XCTAssertFalse(out.ok)
        XCTAssertNil(out.pdf)
    }

    func testBibtexFailureDoesNotAbort() async throws {
        let fake = FakeExecutor([ok(), fail("I found no \\bibdata command"), ok(), ok()])
        let out = try await RecipeRunner(executor: fake).run(.pdflatexBibtex, main: "main.tex")
        XCTAssertEqual(fake.requests.count, 4)
        XCTAssertTrue(out.ok)
    }

    func testStepCallbackReportsProgress() async throws {
        let fake = FakeExecutor([])
        var seen: [String] = []
        var runner = RecipeRunner(executor: fake)
        runner.onStep = { i, n, t in seen.append("\(i)/\(n):\(t.rawValue)") }
        _ = try await runner.run(.pdflatexBibtex, main: "main.tex")
        XCTAssertEqual(seen, ["1/4:pdflatex", "2/4:bibtex", "3/4:pdflatex", "4/4:pdflatex"])
    }

    // MARK: model

    func testValidation() {
        XCTAssertNotNil(BuildRecipe.pdflatexAuto.validated())
        XCTAssertNil(BuildRecipe(id: "x", name: "no latex", steps: [BuildStep(.bibtex)]).validated())
        XCTAssertNil(BuildRecipe(id: "x", name: "empty", steps: []).validated())
        XCTAssertNil(BuildRecipe(id: "x", name: "huge", steps: Array(repeating: BuildStep(.pdflatex), count: 13)).validated())
        XCTAssertEqual(BuildRecipe(id: "x", name: String(repeating: "n", count: 200), steps: [BuildStep(.pdflatex)]).validated()?.name.count, 60)
    }

    func testSettingsRoundTripAndTolerantDecoding() throws {
        var s = ProjectSettings()
        s.recipes = [BuildRecipe(id: "custom-1", name: "Mine", steps: [BuildStep(.pdflatex), BuildStep(.bibtex, onlyIfNeeded: true), BuildStep(.rerun)])]
        s.activeRecipe = "custom-1"
        let back = try JSONDecoder().decode(ProjectSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.recipes.first?.steps.map(\.tool), [.pdflatex, .bibtex, .rerun])
        XCTAssertEqual(back.recipes.first?.steps[1].onlyIfNeeded, true)
        XCTAssertEqual(back.activeRecipeResolved.id, "custom-1")

        // an old file without the new keys, and a hostile one with an unknown tool
        let old = try JSONDecoder().decode(ProjectSettings.self, from: Data(#"{"mainFile":"a.tex"}"#.utf8))
        XCTAssertEqual(old.mainFile, "a.tex"); XCTAssertEqual(old.outputDir, "build"); XCTAssertEqual(old.activeRecipeResolved.id, "pdflatex-auto")
        let bad = try JSONDecoder().decode(ProjectSettings.self, from: Data(#"{"recipes":[{"id":"z","name":"z","steps":[{"tool":"rm -rf"}]}],"activeRecipe":"z"}"#.utf8))
        XCTAssertTrue(bad.recipes.isEmpty)
        XCTAssertEqual(bad.activeRecipeResolved.id, "pdflatex-auto")
    }

    func testCustomRecipeCannotShadowBuiltIn() {
        var s = ProjectSettings()
        s.recipes = [BuildRecipe(id: "pdflatex", name: "Evil", steps: [BuildStep(.pdflatex)])]
        XCTAssertEqual(s.allRecipes.filter { $0.id == "pdflatex" }.count, 1)
        XCTAssertEqual(s.allRecipes.first { $0.id == "pdflatex" }?.name, "pdfLaTeX only")
    }

    func testDiagnosticsUseOnlyTheFinalLatexPass() {
        let early = RecipeOutcome.Entry(tool: .pdflatex, log: "LaTeX Warning: Citation `a' on page 1 undefined on input line 3.", ok: true, ms: 1)
        let bib = RecipeOutcome.Entry(tool: .bibtex, log: "Warning--I didn't find a database entry for \"zzz\"", ok: true, ms: 1)
        let final = RecipeOutcome.Entry(tool: .pdflatex, log: "all fine", ok: true, ms: 1)
        let d = Project.diagnostics(from: RecipeOutcome(ok: true, pdf: Data([1]), entries: [early, bib, final]))
        XCTAssertEqual(d.count, 1)
        XCTAssertTrue(d[0].message.hasPrefix("BibTeX:"))
    }
}

@MainActor
final class XeLaTeXRecipeTests: XCTestCase {
    func testMagicProgramComment() {
        XCTAssertEqual(BuildRecipe.magicProgram(in: "% !TEX program = xelatex\n\\documentclass{article}"), "xelatex")
        XCTAssertEqual(BuildRecipe.magicProgram(in: "%!TeX program=XeLaTeX"), "xelatex")
        XCTAssertNil(BuildRecipe.magicProgram(in: String(repeating: "\n", count: 30) + "% !TEX program = xelatex"))   // only the first lines count
        XCTAssertNil(BuildRecipe.magicProgram(in: "no comment here"))
        XCTAssertEqual(BuildRecipe.recipe(forProgram: "xelatex")?.id, "xelatex-auto")
        XCTAssertEqual(BuildRecipe.recipe(forProgram: "pdflatex")?.id, "pdflatex-auto")
        XCTAssertNil(BuildRecipe.recipe(forProgram: "lualatex"))
    }

    func testXeLaTeXRecipeUsesXeTeXEngineAndProducesOnLastPass() async throws {
        let fake = FakeExecutor([])
        let out = try await RecipeRunner(executor: fake).run(.xelatexBibtex, main: "main.tex")
        XCTAssertEqual(fake.requests.map(\.tool), [.xelatex, .bibtex, .xelatex, .xelatex])
        XCTAssertEqual(fake.requests.map(\.engine), [.xetex, .xetex, .xetex, .xetex])
        XCTAssertEqual(fake.requests.map(\.produce), [false, false, false, true])
        XCTAssertTrue(out.ok)
    }

    func testEngineHintForFontspecWithPdfLaTeX() {
        let log = "! Package fontspec Error: The fontspec package requires either XeTeX or LuaTeX."
        XCTAssertNotNil(Project.engineHint(log: log, recipe: .pdflatexAuto))
        XCTAssertNil(Project.engineHint(log: log, recipe: .xelatexAuto))
        XCTAssertNil(Project.engineHint(log: "! Undefined control sequence.", recipe: .pdflatexAuto))
    }
}

final class FontIndexTests: XCTestCase {
    /// Uses the app's bundled OpenType fonts when present (they're git-ignored, so CI skips this).
    func testResolvesFamiliesStylesAndFileNames() throws {
        guard let dir = Bundle.main.url(forResource: "fonts", withExtension: nil) else { throw XCTSkip("no bundled fonts") }
        let idx = FontIndex(directories: [dir])
        try XCTSkipIf(idx.count == 0, "no fonts indexed")
        XCTAssertNotNil(idx.resolve(name: "Latin Modern Roman", variant: "OT"))
        XCTAssertNotNil(idx.resolve(name: "latinmodern-math", variant: ""))
        let bold = idx.resolve(name: "Libertinus Serif", variant: "/B")?.lastPathComponent.lowercased()
        XCTAssertTrue(bold?.contains("bold") == true, "got \(bold ?? "nil")")
        XCTAssertNil(idx.resolve(name: "../../etc/passwd", variant: "OT"))
        XCTAssertNil(idx.resolve(name: "No Such Font", variant: "OT"))
    }

    func testFontListMatchesTheLayoutXeTeXParses() throws {
        guard let dir = Bundle.main.url(forResource: "fonts", withExtension: nil) else { throw XCTSkip("no bundled fonts") }
        let idx = FontIndex(directories: [dir])
        try XCTSkipIf(idx.count == 0, "no fonts indexed")
        // Re-implementation of XeTeXFontMgr_FC::searchForHostPlatformFonts' reader: it must consume the text exactly.
        var lines = idx.fontListText().components(separatedBy: "\n")
        XCTAssertEqual(lines.last, "")
        lines.removeLast()
        var i = 0, fonts = 0
        func next() -> String { defer { i += 1 }; return lines[i] }
        func skipList() { let n = Int(next())!; i += n }
        while i < lines.count {
            XCTAssertEqual(Int(next()), fonts + 1)                 // id
            XCTAssertTrue(next().hasPrefix("/fonts/"))             // path
            XCTAssertEqual(next(), "0")                            // face index
            skipList(); skipList(); skipList()                     // family, style, full names
            i += 2                                                 // PostScript name, sub-family
            i += 6                                                 // weight, width, slant, isReg, isBold, isItalic
            i += 5                                                 // optical size fields
            fonts += 1
        }
        XCTAssertEqual(i, lines.count)
        XCTAssertEqual(fonts, idx.records.count)
    }
}
