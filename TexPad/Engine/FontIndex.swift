// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import Foundation
import CoreText

/// Maps the font names XeTeX asks for ("Latin Modern Roman", "lmroman10-regular", "TeX Gyre Termes/B") to font files
/// in the bundle and in TeXExtras. Lookups only ever return URLs that were enumerated at scan time, so a hostile
/// document can't use a crafted name to read anything else.
final class FontIndex {
    struct Entry {
        var url: URL
        var family: String
        var bold: Bool
        var italic: Bool
    }

    /// Everything XeTeX's font manager wants to know about one font file.
    struct Record {
        var file: String
        var families: [String], styles: [String], fulls: [String]
        var ps: String, subFamily: String
        var weight: Int, slant: Int
        var bold: Bool, italic: Bool
    }
    private(set) var records: [Record] = []

    private var byName: [String: [Entry]] = [:]      // lower-cased family / full / PostScript / file name -> entries
    private var byFile: [String: URL] = [:]          // lower-cased file name (with and without extension) -> url
    private(set) var count = 0

    init(directories: [URL]) { rescan(directories) }

    static let fontExtensions: Set<String> = ["otf", "ttf"]

    func rescan(_ directories: [URL]) {
        byName = [:]; byFile = [:]; records = []; count = 0
        for dir in directories {
            guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for case let u as URL in en {
                guard Self.fontExtensions.contains(u.pathExtension.lowercased()),
                      let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      v.isRegularFile == true, v.isSymbolicLink != true else { continue }
                add(u)
            }
        }
    }

    private func add(_ url: URL) {
        let file = url.lastPathComponent.lowercased()
        byFile[file] = byFile[file] ?? url
        byFile[(file as NSString).deletingPathExtension] = byFile[(file as NSString).deletingPathExtension] ?? url
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], let d = descs.first else { return }
        let family = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String ?? ""
        let full = CTFontDescriptorCopyAttribute(d, kCTFontDisplayNameAttribute) as? String ?? ""
        let ps = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String ?? ""
        var bold = false, italic = false
        if let traits = CTFontDescriptorCopyAttribute(d, kCTFontTraitsAttribute) as? [CFString: Any],
           let raw = traits[kCTFontSymbolicTrait] as? UInt32 {
            let t = CTFontSymbolicTraits(rawValue: raw)
            bold = t.contains(.traitBold); italic = t.contains(.traitItalic)
        }
        let style = CTFontDescriptorCopyAttribute(d, kCTFontStyleNameAttribute) as? String ?? (bold ? (italic ? "Bold Italic" : "Bold") : (italic ? "Italic" : "Regular"))
        var weight = bold ? 200 : 80
        if let traits = CTFontDescriptorCopyAttribute(d, kCTFontTraitsAttribute) as? [CFString: Any], let w = traits[kCTFontWeightTrait] as? Double {
            switch w { case ..<(-0.5): weight = 40; case ..<(-0.2): weight = 50; case ..<0.1: weight = 80; case ..<0.3: weight = 100
                       case ..<0.5: weight = 180; case ..<0.7: weight = 200; default: weight = 210 }
        }
        records.append(Record(file: url.lastPathComponent, families: [family].filter { !$0.isEmpty }, styles: [style],
                              fulls: [full].filter { !$0.isEmpty }, ps: ps, subFamily: style, weight: weight, slant: italic ? 100 : 0,
                              bold: bold, italic: italic))
        let entry = Entry(url: url, family: family, bold: bold, italic: italic)
        for key in [family, full, ps] where !key.isEmpty { byName[key.lowercased(), default: []].append(entry) }
        count += 1
    }

    /// Resolve a font request. `variant` is XeTeX's style hint ("OT", "B", "I", "BI", "/B" …).
    func resolve(name rawName: String, variant: String) -> URL? {
        var name = rawName.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("[") && name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        let key = name.lowercased()
        let v = variant.uppercased().replacingOccurrences(of: "/", with: "").replacingOccurrences(of: "_", with: "")
        let wantBold = v.contains("B"), wantItalic = v.contains("I")

        if let u = byFile[key] { return u }                                   // a file name, with or without extension
        guard let candidates = byName[key], !candidates.isEmpty else { return nil }
        // exact style first, then regular, then anything
        return (candidates.first { $0.bold == wantBold && $0.italic == wantItalic }
                ?? candidates.first { !$0.bold && !$0.italic }
                ?? candidates.first)?.url
    }

    /// File names for the worker's `/fonts` mount (served at tex://app/tl/fontfile/<name>).
    var fileNames: [String] { Array(Set(records.map(\.file))).sorted() }

    /// `xetexfontlist.txt` in the layout XeTeX's font manager parses (see XeTeXFontMgr_FC::searchForHostPlatformFonts):
    /// per font: id, path, face index, then counted lists of family / style / full names, PostScript name, sub-family,
    /// weight, width, slant, isRegular, isBold, isItalic, and five optical-size fields — one value per line.
    func fontListText() -> String {
        var out = ""
        func lines(_ a: [String]) { out += "\(a.count)\n" + a.map { $0 + "\n" }.joined() }
        for (i, r) in records.enumerated() {
            out += "\(i + 1)\n/fonts/\(r.file)\n0\n"
            lines(r.families); lines(r.styles); lines(r.fulls)
            out += "\(r.ps)\n\(r.subFamily)\n\(r.weight)\n100\n\(r.slant)\n"
            out += "\(!r.bold && !r.italic ? 1 : 0)\n\(r.bold ? 1 : 0)\n\(r.italic ? 1 : 0)\n0\n0\n0\n0\n0\n"
        }
        return out
    }

    /// A font file requested by file name (kpathsea "opentype fonts" / "truetype fonts" lookups).
    func file(named name: String) -> URL? { byFile[name.lowercased()] }
}
