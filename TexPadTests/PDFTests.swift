// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import XCTest
import PDFKit
@testable import TexPad

@MainActor
final class PDFTests: XCTestCase {
    func testViewMemoryRoundTripPerProject() {
        let key = "unit-test-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "pdfview.v1." + key) }
        XCTAssertNil(PDFViewMemory.load(key))
        let m = PDFViewMemory(page: 3, x: 12.5, y: 700, scale: 1.75, autoScales: false, layout: .twoUp)
        m.save(key)
        XCTAssertEqual(PDFViewMemory.load(key), m)
        XCTAssertNil(PDFViewMemory.load(key + "-other"))
    }

    func testLayoutsMapToDisplayModes() {
        XCTAssertEqual(PDFLayout.continuous.displayMode, .singlePageContinuous)
        XCTAssertEqual(PDFLayout.single.displayMode, .singlePage)
        XCTAssertEqual(PDFLayout.twoUp.displayMode, .twoUpContinuous)
        XCTAssertEqual(PDFLayout.allCases.count, 3)
    }

    func testControllerNavigationAndOutline() throws {
        // Two-page PDF with an outline entry for page 2.
        let doc = PDFDocument()
        doc.insert(PDFPage(), at: 0); doc.insert(PDFPage(), at: 1)
        let root = PDFOutline(), item = PDFOutline()
        item.label = "Second"; item.destination = PDFDestination(page: doc.page(at: 1)!, at: .zero)
        root.insertChild(item, at: 0); doc.outlineRoot = root

        let view = PDFView(); view.document = doc
        let c = PDFController(); c.attach(view)
        c.refresh(); c.rebuildOutline()
        XCTAssertEqual(c.pageCount, 2)
        XCTAssertEqual(c.outline.map(\.label), ["Second"])
        c.goTo(page: 2); c.refresh()
        XCTAssertEqual(c.currentPage, 2)
        c.goTo(page: 99)                       // out of range: ignored
        c.refresh()
        XCTAssertEqual(c.currentPage, 2)
        c.setLayout(.single)
        XCTAssertEqual(view.displayMode, .singlePage)
    }

    func testPDFFileDocumentKeepsBytes() throws {
        let d = PDFFileDocument(data: Data([1, 2, 3]))
        XCTAssertEqual(d.data, Data([1, 2, 3]))
        XCTAssertEqual(PDFFileDocument.readableContentTypes.count, 1)
    }
}
