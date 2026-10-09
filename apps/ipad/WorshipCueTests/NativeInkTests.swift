import XCTest
import PencilKit
import PDFKit
import SQLite3
import CryptoKit
import WorshipCueCore
import WorshipCueLocal
@testable import WorshipCue

@MainActor final class NativeInkTests: XCTestCase {
    private func assertSameInk(_ actual: PKDrawing, _ expected: PKDrawing,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.bounds, expected.bounds, file: file, line: line)
        XCTAssertEqual(actual.strokes.count, expected.strokes.count, file: file, line: line)
        for (a, e) in zip(actual.strokes, expected.strokes) {
            XCTAssertEqual(a.ink.inkType, e.ink.inkType, file: file, line: line)
            XCTAssertEqual(a.ink.color, e.ink.color, file: file, line: line)
            XCTAssertEqual(a.transform, e.transform, file: file, line: line)
            XCTAssertEqual(a.mask, e.mask, file: file, line: line)
            XCTAssertEqual(a.maskedPathRanges, e.maskedPathRanges, file: file, line: line)
            XCTAssertEqual(a.randomSeed, e.randomSeed, file: file, line: line)
            XCTAssertEqual(a.path.creationDate, e.path.creationDate, file: file, line: line)
            XCTAssertEqual(a.path.count, e.path.count, file: file, line: line)
            for (ap, ep) in zip(a.path, e.path) {
                XCTAssertEqual(ap.location, ep.location, file: file, line: line)
                XCTAssertEqual(ap.size, ep.size, file: file, line: line)
                XCTAssertEqual(ap.timeOffset, ep.timeOffset, file: file, line: line)
                XCTAssertEqual(ap.opacity, ep.opacity, file: file, line: line)
                XCTAssertEqual(ap.force, ep.force, file: file, line: line)
                XCTAssertEqual(ap.azimuth, ep.azimuth, file: file, line: line)
                XCTAssertEqual(ap.altitude, ep.altitude, file: file, line: line)
            }
        }
    }

    private func waitUntilReady(_ overlay: PageInkView) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !overlay.ready, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(overlay.ready, "Native restore did not finish within 5 seconds")
        if !overlay.ready { throw InkStoreError.invalidRecord }
    }

    private func testStand() async throws -> (MusicStand, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stand = MusicStand(applicationSupport: root)
        addTeardownBlock { @MainActor [weak stand] in
            let deadline = ContinuousClock().now.advanced(by: .seconds(5))
            while stand != nil, ContinuousClock().now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNil(stand)
            if stand == nil { try FileManager.default.removeItem(at: root) }
        }
        await stand.start()
        XCTAssertNil(stand.error)
        return (stand, root)
    }

    private func readyOverlay(_ stand: MusicStand) async throws -> PageInkView {
        let page = try XCTUnwrap(stand.pdfView.document?.page(at: stand.pageIndex))
        let overlay = try XCTUnwrap(stand.pdfView(stand.pdfView, overlayViewFor: page) as? PageInkView)
        try await waitUntilReady(overlay)
        return overlay
    }

    /// Opt-in local evidence. Real charts are staged in Documents, never bundled
    /// or committed. The regular user's vault, ink and bookmarks stay untouched.
    func testPrivatePDFPairPreservesAnnotationsAndManualTransferAcrossDifferentGeometry() async throws {
        guard let value = ProcessInfo.processInfo.environment["WORSHIPCUE_PRIVATE_PDF_RUN"],
              let run = UUID(uuidString: value) else {
            throw XCTSkip("Private PDF pair not supplied; run scripts/test_private_pdf_pair.py locally")
        }
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let inputs = documents.appendingPathComponent("WorshipCuePrivateTests").appendingPathComponent(run.uuidString)
        func assertArchivedInk(_ actual: PKDrawing, _ expected: PKDrawing) throws {
            // Both a cached in-memory drawing and a cold archive are valid.
            // Compare their native archive semantics at native float precision.
            assertSameInk(try PKDrawing(data: actual.dataRepresentation()),
                          try PKDrawing(data: expected.dataRepresentation()))
        }
        let (stand, root) = try await testStand()
        let uiRoot = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            .appendingPathComponent("WorshipCueUITests").appendingPathComponent(run.uuidString)
        let uiVault = try DocumentVault(root: uiRoot.appendingPathComponent("pdfs"))
        XCTAssertTrue(uiVault.charts.isEmpty, "Each private run requires a fresh isolated store")
        var imported: [LocalChart] = []
        var originals: [Data] = []
        let song = LibrarySong(title: "Private arrangement pair")
        let renders = inputs.appendingPathComponent("PDFKitRenders")
        try FileManager.default.createDirectory(at: renders, withIntermediateDirectories: true)
        for label in ["A", "B"] {
            let source = inputs.appendingPathComponent("arrangement-\(label).pdf")
            let original = try Data(contentsOf: source)
            originals.append(original)
            let sourceDocument = try XCTUnwrap(PDFDocument(data: original))
            let didImport = await stand.importChart(source, song: song, label: "Private arrangement \(label)", writtenKey: nil)
            XCTAssertTrue(didImport)
            XCTAssertNil(stand.error)
            let chart = try XCTUnwrap(stand.charts.first { $0.name == "Private arrangement \(label)" })
            await stand.choose(chart)
            imported.append(chart)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("pdfs").appendingPathComponent(chart.filename)), original)
            let document = try XCTUnwrap(stand.pdfView.document)
            XCTAssertEqual(document.pageCount, sourceDocument.pageCount)
            XCTAssertGreaterThan(document.pageCount, 1)
            XCTAssertGreaterThan(sourceDocument.page(at: 0)?.annotations.count ?? 0, 0,
                                 "This optional pair must exercise embedded arranger annotations")
            for index in 0..<document.pageCount {
                let page = try XCTUnwrap(document.page(at: index))
                let originalPage = try XCTUnwrap(sourceDocument.page(at: index))
                XCTAssertEqual(page.annotations.count, originalPage.annotations.count)
                XCTAssertEqual(try page.canonicalGeometry(), try originalPage.canonicalGeometry())
                let image = page.thumbnail(of: CGSize(width: 850, height: 1100), for: .cropBox)
                let png = try XCTUnwrap(image.pngData())
                XCTAssertGreaterThan(png.count, 1_000)
                try png.write(to: renders.appendingPathComponent("arrangement-\(label)-\(index + 1).png"))
            }
            // Seed the UI run using the actual native importer and pristine PDFs.
            _ = try uiVault.importPDF(source, name: "Private arrangement \(label)", song: song)
        }
        XCTAssertNotEqual(imported[0].id, imported[1].id)
        XCTAssertNotEqual(imported[0].sha256, imported[1].sha256)
        XCTAssertEqual(stand.library.versions(for: song.id).map(\.number).sorted(), [1, 2])
        let preferred = try XCTUnwrap(stand.library.versions.first { $0.id == imported[0].id })
        stand.prefer(preferred)
        await stand.choose(imported[0])
        let sourceOverlay = try await readyOverlay(stand)
        let first = MusicStand.sampleTeamDrawing()
        let second = first.transformed(using: CGAffineTransform(translationX: 0, y: 140))
        let sourceInk = PKDrawing(strokes: first.strokes + second.strokes)
        sourceOverlay.replaceWithUndo(sourceInk)
        try await stand.flush()
        stand.beginSelection()
        sourceOverlay.transfer.selection = first.bounds.insetBy(dx: -5, dy: -5)
        sourceOverlay.transfer.onChange?()
        XCTAssertEqual(stand.selectionCount, 1)
        stand.copySelection()
        await stand.choose(imported[1])
        XCTAssertEqual(stand.library.preferences[song.id], imported[0].id, "Opening the other arrangement must not replace the preference")
        let target = try await readyOverlay(stand)
        XCTAssertNotEqual(sourceOverlay.geometry, target.geometry)
        XCTAssertEqual(target.personal.drawing.strokes.count, 0)
        stand.beginPaste()
        target.transfer.centerPoint = CGPoint(x: target.geometry.width * 0.55, y: target.geometry.height * 0.82)
        target.transfer.scale = 1.25
        target.transfer.onChange?()
        let expectedPaste = try XCTUnwrap(target.transfer.preview)
        stand.cancelTransfer()
        XCTAssertEqual(target.personal.drawing.strokes.count, 0)
        stand.beginPaste()
        target.transfer.centerPoint = CGPoint(x: target.geometry.width * 0.55, y: target.geometry.height * 0.82)
        target.transfer.scale = 1.25
        target.transfer.onChange?()
        stand.commitPaste()
        try assertArchivedInk(target.personal.drawing, expectedPaste)
        stand.undo(); XCTAssertEqual(target.personal.drawing.strokes.count, 0)
        stand.redo(); try assertArchivedInk(target.personal.drawing, expectedPaste)
        try await stand.flush()
        await stand.turnPage(1)
        let nextPage = try await readyOverlay(stand)
        XCTAssertEqual(nextPage.personal.drawing.strokes.count, 0)
        await stand.turnPage(-1)
        try assertArchivedInk(try await readyOverlay(stand).personal.drawing, expectedPaste)
        await stand.choose(imported[0])
        try assertArchivedInk(try await readyOverlay(stand).personal.drawing, sourceInk)
        await stand.choose(imported[1])
        let reopened = MusicStand(applicationSupport: root)
        await reopened.start()
        XCTAssertNil(reopened.error)
        XCTAssertEqual(reopened.current?.id, imported[1].id)
        try assertArchivedInk(try await readyOverlay(reopened).personal.drawing, expectedPaste)
        let sourceOnlyResult = await reopened.exportPDF(includePersonal: false)
        let sourceOnlyURL = try XCTUnwrap(sourceOnlyResult)
        let sourceOnly = try XCTUnwrap(PDFDocument(url: sourceOnlyURL))
        let targetOriginal = try XCTUnwrap(PDFDocument(data: originals[1]))
        for index in 0..<targetOriginal.pageCount {
            try assertPDFRenderMatches(try XCTUnwrap(targetOriginal.page(at: index)), try XCTUnwrap(sourceOnly.page(at: index)))
        }
        for (index, chart) in imported.enumerated() {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("pdfs").appendingPathComponent(chart.filename)), originals[index])
        }
    }

    func testV2ReadOnlyPreviewsKeepChartBookmarkPreferenceAndExactInk() async throws {
        let (stand, root) = try await testStand()
        let overlay = try await readyOverlay(stand)
        let original = try XCTUnwrap(stand.current)
        let bytes = try Data(contentsOf: root.appendingPathComponent("pdfs").appendingPathComponent(original.filename))
        overlay.personal.drawing = MusicStand.sampleTeamDrawing()
        stand.canvasViewDrawingDidChange(overlay.personal)
        try await stand.flush()
        let store = try LocalInkStore(url: root.appendingPathComponent("personal.sqlite"))
        let before = try await store.load(overlay.address)
        let other = try XCTUnwrap(stand.library.versions.first { $0.number == 2 && $0.songID == stand.currentLibraryVersion?.songID })
        XCTAssertTrue(stand.prefer(other))
        await stand.turnPage(1)
        let document = try XCTUnwrap(stand.pdfView.document)
        let preferences = stand.library.preferences
        for version in stand.library.versions(for: other.songID) {
            let thumbnail = try XCTUnwrap(stand.chartThumbnail(version.id))
            XCTAssertLessThanOrEqual(thumbnail.size.width, 160)
            XCTAssertLessThanOrEqual(thumbnail.size.height, 160)
        }
        XCTAssertNil(stand.chartThumbnail(original.id, page: 999))
        XCTAssertNil(stand.chartThumbnail(UUID()))
        let otherChart = try XCTUnwrap(stand.charts.first { $0.id == other.id })
        try Data("invalid synthetic PDF".utf8).write(to: root.appendingPathComponent("pdfs").appendingPathComponent(otherChart.filename))
        XCTAssertNil(stand.chartThumbnail(other.id), "A corrupt preview is unavailable, never substituted")
        XCTAssertTrue(stand.pdfView.document === document)
        XCTAssertEqual(stand.current?.id, original.id)
        XCTAssertEqual(stand.pageIndex, 1)
        XCTAssertEqual(stand.library.preferences, preferences)
        XCTAssertNil(stand.error)
        let after = try await store.load(overlay.address)
        XCTAssertEqual(before, after)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("pdfs").appendingPathComponent(original.filename)), bytes)
    }

    func testM1LegacyMigrationPreservesPDFAndExactExistingInk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pdfs = root.appendingPathComponent("pdfs")
        try FileManager.default.createDirectory(at: pdfs, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let source = try XCTUnwrap(Bundle.main.url(forResource: "song_A_v1_G", withExtension: "pdf", subdirectory: "pdfs"))
        let bytes = try Data(contentsOf: source), id = UUID()
        let chart = LocalChart(id: id, name: "Legacy chart", filename: "\(id.uuidString).pdf",
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), bytes: bytes.count)
        let index = try JSONEncoder().encode([chart])
        try bytes.write(to: pdfs.appendingPathComponent(chart.filename)); try index.write(to: pdfs.appendingPathComponent("index.json"))
        let page = try XCTUnwrap(PDFDocument(data: bytes)?.page(at: 0))
        let address = try InkAddress(churchID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            ownerID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, versionID: id, pageIndex: 0)
        let original = MusicStand.sampleTeamDrawing().dataRepresentation()
        let store = try LocalInkStore(url: root.appendingPathComponent("personal.sqlite"))
        try await store.save(InkSnapshot(address: address, geometry: page.canonicalGeometry(), generation: 1, archive: original))
        let stand = MusicStand(applicationSupport: root); await stand.start()
        XCTAssertNil(stand.error); XCTAssertEqual(stand.current?.id, id)
        assertSameInk(try await readyOverlay(stand).personal.drawing, try PKDrawing(data: original))
        XCTAssertEqual(try Data(contentsOf: pdfs.appendingPathComponent(chart.filename)), bytes)
        XCTAssertEqual(try Data(contentsOf: pdfs.appendingPathComponent("index.json")), index)
        XCTAssertEqual(try DocumentVault(root: pdfs).charts.count, 6)
        XCTAssertEqual(stand.library.versions.first?.id, id)
        XCTAssertEqual(stand.library.assets.first?.pages?.count, 2)
    }

    func testM1VersionPreferenceBookmarkAndImportDoNotAutomaticallyNavigateOrMerge() async throws {
        let (stand, root) = try await testStand()
        let first = try XCTUnwrap(stand.library.versions.first { $0.number == 1 && $0.writtenKey == "G" })
        let second = try XCTUnwrap(stand.library.versions.first { $0.songID == first.songID && $0.number == 2 })
        let third = try XCTUnwrap(stand.library.versions.first { $0.songID == first.songID && $0.number == 3 })
        XCTAssertTrue(stand.prefer(second)); XCTAssertEqual(stand.current?.id, first.id)
        let opened = await stand.openVersion(third.id); XCTAssertTrue(opened)
        await stand.turnPage(1)
        (try await readyOverlay(stand)).replaceWithUndo(MusicStand.sampleTeamDrawing()); try await stand.flush()
        _ = await stand.openVersion(first.id); XCTAssertEqual(stand.pageIndex, 0)
        let emptyOverlay = try await readyOverlay(stand); XCTAssertTrue(emptyOverlay.personal.drawing.strokes.isEmpty)
        _ = await stand.openVersion(third.id); XCTAssertEqual(stand.pageIndex, 1)
        let restoredOverlay = try await readyOverlay(stand); XCTAssertEqual(restoredOverlay.personal.drawing.strokes.count, 1)
        XCTAssertEqual(stand.library.preferences[first.songID], second.id)
        let source = try XCTUnwrap(Bundle.main.url(forResource: "song_A_v1_G", withExtension: "pdf", subdirectory: "pdfs"))
        let song = try XCTUnwrap(stand.library.songs.first { $0.id == first.songID })
        let imported = await stand.importChart(source, song: song, label: "Explicit fourth version", writtenKey: "G")
        XCTAssertTrue(imported); XCTAssertEqual(stand.library.versions(for: song.id).first?.number, 4)
        XCTAssertEqual(stand.current?.id, third.id); XCTAssertEqual(stand.pageIndex, 1)
        XCTAssertEqual(stand.library.preferences[first.songID], second.id)
        let set = try XCTUnwrap(stand.saveSetlist(LocalSetlist(title: "로컬 준비 검사", items: [
            SetlistItem(songID: song.id, versionID: first.id, performanceKey: "G"),
            SetlistItem(songID: song.id, versionID: third.id, performanceKey: "A", section: .standby)])))
        await stand.prepare(set)
        XCTAssertTrue(stand.preparationReport?.contains("3개 악보") == true)
        let preferredChart = try XCTUnwrap(stand.charts.first { $0.id == second.id })
        try Data([0]).write(to: root.appendingPathComponent("pdfs").appendingPathComponent(preferredChart.filename))
        let readable = stand.pdfView.document
        await stand.prepare(set)
        XCTAssertTrue(stand.preparationReport?.contains("2 / 3") == true)
        XCTAssertTrue(stand.pdfView.document === readable)
        XCTAssertEqual(stand.current?.id, third.id); XCTAssertEqual(stand.pageIndex, 1)
        XCTAssertEqual(restoredOverlay.personal.drawing.strokes.count, 1)
    }

    func testM1PacketSlicesKeepArrangerAnnotationsAndRollbackInvalidBatch() async throws {
        let (stand, root) = try await testStand()
        let originalCurrent = stand.current?.id
        let source = try XCTUnwrap(Bundle.main.url(forResource: "weekly_packet", withExtension: "pdf", subdirectory: "pdfs"))
        let document = try XCTUnwrap(PDFDocument(url: source))
        let annotation = PDFAnnotation(bounds: CGRect(x: 40, y: 60, width: 150, height: 35), forType: .freeText, withProperties: nil)
        annotation.contents = "M1 synthetic arranger mark"; annotation.font = .systemFont(ofSize: 14); annotation.fontColor = .red
        try XCTUnwrap(document.page(at: 0)).addAnnotation(annotation)
        let input = root.appendingPathComponent("packet-with-annotation.pdf")
        let bytes = try XCTUnwrap(document.dataRepresentation()); try bytes.write(to: input)
        let song = LibrarySong(title: "주간 원본")
        let imported = await stand.importChart(input, song: song, label: "Weekly annotated packet", writtenKey: nil)
        XCTAssertTrue(imported)
        let chart = try XCTUnwrap(stand.charts.first { $0.name == "Weekly annotated packet" })
        let before = stand.charts.count
        let pdfs = root.appendingPathComponent("pdfs")
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: pdfs.path).filter { $0.hasSuffix(".pdf") }.sorted()
        let invalid = [PacketSlice(song: LibrarySong(title: "첫 곡"), firstPage: 1, lastPage: 1, writtenKey: "G", label: "first"),
            PacketSlice(song: LibrarySong(title: "둘째 곡"), firstPage: 2, lastPage: 2, writtenKey: "H", label: "invalid")]
        let failed = await stand.splitPacket(chart.id, slices: invalid)
        XCTAssertFalse(failed); XCTAssertEqual(stand.charts.count, before); stand.error = nil
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: pdfs.path).filter { $0.hasSuffix(".pdf") }.sorted(), filesBefore)
        let valid = [PacketSlice(song: LibrarySong(title: "첫 곡"), firstPage: 1, lastPage: 1, writtenKey: "G", label: "first"),
            PacketSlice(song: LibrarySong(title: "둘째 곡"), firstPage: 2, lastPage: document.pageCount, writtenKey: "A", label: "second")]
        let succeeded = await stand.splitPacket(chart.id, slices: valid)
        XCTAssertTrue(succeeded); XCTAssertEqual(stand.current?.id, originalCurrent)
        let vault = try DocumentVault(root: pdfs)
        let first = try XCTUnwrap(vault.charts.first { $0.name == "first" })
        let firstDocument = try vault.open(first)
        XCTAssertEqual(firstDocument.pageCount, 1)
        XCTAssertEqual(firstDocument.page(at: 0)?.annotations.count, document.page(at: 0)?.annotations.count)
        XCTAssertGreaterThan(firstDocument.page(at: 0)?.annotations.count ?? 0, 0)
        let second = try XCTUnwrap(vault.charts.first { $0.name == "second" })
        XCTAssertEqual(try vault.open(second).pageCount, document.pageCount - 1)
        XCTAssertEqual(try Data(contentsOf: pdfs.appendingPathComponent(chart.filename)), bytes)
        XCTAssertEqual(stand.library.versions.first { $0.id == first.id }?.sourceFirstPage, 1)
        let exported = root.appendingPathComponent("arranger-fallback.pdf")
        try PDFExporter.write(firstDocument, drawings: [:], to: exported)
        let fallback = try XCTUnwrap(PDFDocument(url: exported)?.page(at: 0))
        try assertPDFRenderMatches(try XCTUnwrap(firstDocument.page(at: 0)), fallback)
    }

    private func assertPDFRenderMatches(_ source: PDFPage, _ exported: PDFPage,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let original = source.thumbnail(of: CGSize(width: 320, height: 320), for: .cropBox)
        let fallback = exported.thumbnail(of: CGSize(width: 320, height: 320), for: .cropBox)
        XCTAssertEqual(original.size, fallback.size, file: file, line: line)
        let a = try XCTUnwrap(original.cgImage), b = try XCTUnwrap(fallback.cgImage)
        func pixels(_ image: CGImage) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return bytes
        }
        let ap = try pixels(a), bp = try pixels(b)
        guard ap.count == bp.count else { XCTFail("Export changed visible page size", file: file, line: line); return }
        let meanError = Double(zip(ap, bp).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(ap.count)
        XCTAssertLessThan(meanError, 5, "Export must preserve rotated/CropBox content and arranger annotations", file: file, line: line)
        let attachment = XCTAttachment(image: fallback); attachment.name = "M1 export rotation \(source.rotation)"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testM1FallbackExportMatchesRotationsAndExcludesUnselectedInk() async throws {
        let (stand, root) = try await testStand()
        let chart = try XCTUnwrap(stand.charts.first { $0.name == "geometry_rotations" }); await stand.choose(chart)
        let overlay = try await readyOverlay(stand)
        overlay.replaceWithUndo(MusicStand.sampleTeamDrawing()); try await stand.flush()
        let source = try XCTUnwrap(stand.pdfView.document)
        let original = try Data(contentsOf: root.appendingPathComponent("pdfs").appendingPathComponent(chart.filename))
        let plainResult = await stand.exportPDF(includePersonal: false)
        let plainURL = try XCTUnwrap(plainResult)
        let plain = try XCTUnwrap(PDFDocument(url: plainURL)); XCTAssertEqual(plain.pageCount, source.pageCount)
        for index in 0..<source.pageCount { try assertPDFRenderMatches(try XCTUnwrap(source.page(at: index)), try XCTUnwrap(plain.page(at: index))) }
        let inkResult = await stand.exportPDF(includePersonal: true)
        let inkURL = try XCTUnwrap(inkResult)
        XCTAssertNotEqual(try Data(contentsOf: plainURL), try Data(contentsOf: inkURL))
        let inkPage = try XCTUnwrap(PDFDocument(url: inkURL)?.page(at: 0))
        let plainImage = try XCTUnwrap(plain.page(at: 0)?.thumbnail(of: CGSize(width: 600, height: 600), for: .cropBox).cgImage)
        let inkImage = try XCTUnwrap(inkPage.thumbnail(of: CGSize(width: 600, height: 600), for: .cropBox).cgImage)
        func pixels(_ image: CGImage) throws -> [UInt8] {
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            try data.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return data
        }
        let a = try pixels(plainImage), b = try pixels(inkImage)
        XCTAssertEqual(a.count, b.count)
        if a.count == b.count {
            let newRedPixels = stride(from: 0, to: a.count, by: 4).filter {
                b[$0] > 150 && Int(b[$0]) > Int(b[$0 + 1]) + 40 && Int(b[$0]) > Int(b[$0 + 2]) + 40 &&
                abs(Int(a[$0 + 1]) - Int(b[$0 + 1])) > 25
            }.count
            XCTAssertGreaterThan(newRedPixels, 20, "Personal ink must be visibly rendered; different PDF bytes alone are insufficient")
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("pdfs").appendingPathComponent(chart.filename)), original)
        XCTAssertEqual(stand.current?.id, chart.id); XCTAssertEqual(stand.pageIndex, 0)
        XCTAssertEqual(overlay.personal.drawing.strokes.count, 1)
        XCTAssertThrowsError(try PDFExporter.write(source, drawings: [:], to: plainURL))
    }

    func testToolColorsStayFixedAndRememberIndependentChoicesAcrossPagesAndRelaunch() async throws {
        let (stand, root) = try await testStand()
        let prefix = "m0.test.\(root.lastPathComponent)"
        defer {
            UserDefaults.standard.removeObject(forKey: "\(prefix).penColor")
            UserDefaults.standard.removeObject(forKey: "\(prefix).markerColor")
        }
        let first = try await readyOverlay(stand)
        XCTAssertEqual(stand.penColor, .black)
        XCTAssertEqual(stand.markerColor, .yellow)
        let existing = MusicStand.sampleTeamDrawing()
        first.replaceWithUndo(existing)
        try await stand.flush()
        for color in InkColor.allCases {
            stand.setInkColor(color)
            let tool = try XCTUnwrap(first.personal.tool as? PKInkingTool)
            XCTAssertEqual(tool.inkType, .pen)
            XCTAssertEqual(tool.color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)), color.uiColor)
            XCTAssertEqual(tool.color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)), color.uiColor)
            assertSameInk(first.personal.drawing, existing)
        }
        stand.setInkColor(.blue)
        stand.setTool(1); stand.setInkColor(.pink)
        XCTAssertEqual((first.personal.tool as? PKInkingTool)?.inkType, .marker)
        XCTAssertEqual((first.personal.tool as? PKInkingTool)?.color, InkColor.pink.uiColor)
        stand.setTool(2); stand.setInkColor(.red)
        XCTAssertTrue(first.personal.tool is PKEraserTool)
        XCTAssertEqual(stand.penColor, .blue); XCTAssertEqual(stand.markerColor, .pink)
        stand.setTool(0)
        await stand.turnPage(1)
        let next = try await readyOverlay(stand)
        XCTAssertEqual((next.personal.tool as? PKInkingTool)?.color, InkColor.blue.uiColor)
        let relaunched = MusicStand(applicationSupport: root)
        await relaunched.start()
        let restored = try await readyOverlay(relaunched)
        XCTAssertEqual(relaunched.penColor, .blue); XCTAssertEqual(relaunched.markerColor, .pink)
        XCTAssertEqual((restored.personal.tool as? PKInkingTool)?.color, InkColor.blue.uiColor)
        relaunched.setTool(1)
        XCTAssertEqual((restored.personal.tool as? PKInkingTool)?.color, InkColor.pink.uiColor)
    }

    func testVaultImportsImmutableVersionsAndRejectsInvalidAssets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vault = try DocumentVault(root: root.appendingPathComponent("pdfs"))
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try XCTUnwrap(Bundle.main.url(forResource: "song_A_v1_G", withExtension: "pdf", subdirectory: "pdfs"))
        let first = try vault.importPDF(source, name: "First import")
        let bytes = try Data(contentsOf: root.appendingPathComponent("pdfs").appendingPathComponent(first.filename))
        let second = try vault.importPDF(source, name: "Separate version")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.sha256, second.sha256)
        XCTAssertEqual(try Data(contentsOf: vault.root.appendingPathComponent(first.filename)), bytes)
        XCTAssertEqual(try DocumentVault(root: vault.root).charts.count, 2)
        let invalid = root.appendingPathComponent("invalid.pdf")
        try Data("invalid synthetic PDF".utf8).write(to: invalid)
        XCTAssertThrowsError(try vault.importPDF(invalid, name: "Corrupt"))
        let oversized = root.appendingPathComponent("oversized.pdf")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: 100 * 1024 * 1024 + 1); try handle.close()
        XCTAssertThrowsError(try vault.importPDF(oversized, name: "Too large"))
        let manyPages = root.appendingPathComponent("too-many-pages.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
            .pdfData { context in for _ in 0..<201 { context.beginPage() } }.write(to: manyPages)
        XCTAssertThrowsError(try vault.importPDF(manyPages, name: "Too many pages"))
        XCTAssertEqual(vault.charts.count, 2)
        try Data([1, 2, 3]).write(to: vault.root.appendingPathComponent(second.filename))
        XCTAssertThrowsError(try vault.open(second))
        XCTAssertEqual(try vault.open(first).pageCount, 2)
    }

    func testFailedImportPreservesReadableChartAndCommittedInk() async throws {
        let (stand, root) = try await testStand()
        let overlay = try await readyOverlay(stand)
        overlay.replaceWithUndo(MusicStand.sampleTeamDrawing())
        try await stand.flush()
        let expected = overlay.personal.drawing.dataRepresentation()
        let version = stand.current?.id, document = stand.pdfView.document
        let invalid = root.appendingPathComponent("bad-import.pdf")
        try Data("invalid synthetic PDF".utf8).write(to: invalid)
        await stand.importFile(invalid)
        XCTAssertEqual(stand.current?.id, version)
        XCTAssertTrue(stand.pdfView.document === document)
        XCTAssertEqual(stand.charts.count, 5)
        XCTAssertNotNil(stand.error)
        XCTAssertTrue(overlay.personal.isUserInteractionEnabled)
        let store = try LocalInkStore(url: root.appendingPathComponent("personal.sqlite"))
        let durable = try await store.load(overlay.address)
        XCTAssertEqual(durable?.archive, expected)
        stand.error = nil // The user dismisses the invalid-import alert before retrying.
        let valid = try XCTUnwrap(Bundle.main.url(forResource: "song_A_v2_G", withExtension: "pdf", subdirectory: "pdfs"))
        let oldIDs = Set(stand.charts.map(\.id))
        await stand.importFile(valid)
        XCTAssertNil(stand.error)
        XCTAssertEqual(stand.charts.count, 6)
        let imported = try XCTUnwrap(stand.current)
        XCTAssertFalse(oldIDs.contains(imported.id))
        XCTAssertEqual(imported.name, "song_A_v2_G")
        XCTAssertEqual(stand.pageIndex, 0)
        let sourceAfterImport = try await store.load(overlay.address)
        XCTAssertEqual(sourceAfterImport?.archive, expected)
        let reopened = MusicStand(applicationSupport: root)
        await reopened.start()
        XCTAssertEqual(reopened.charts.count, 6)
        XCTAssertEqual(reopened.current?.id, imported.id)
        XCTAssertEqual(reopened.pageIndex, 0)
    }

    func testColdReaderRestoresSavedVersionPageAndExactInk() async throws {
        let (stand, root) = try await testStand()
        let version = try XCTUnwrap(stand.charts.first { $0.name == "song_A_v2_G" })
        await stand.choose(version); await stand.turnPage(1)
        let overlay = try await readyOverlay(stand)
        overlay.replaceWithUndo(MusicStand.sampleTeamDrawing())
        try await stand.flush()
        let bytes = overlay.personal.drawing.dataRepresentation()
        let reopened = MusicStand(applicationSupport: root)
        await reopened.start()
        XCTAssertNil(reopened.error)
        XCTAssertEqual(reopened.current?.id, version.id)
        XCTAssertEqual(reopened.pageIndex, 1)
        let restored = try await readyOverlay(reopened)
        assertSameInk(restored.personal.drawing, try PKDrawing(data: bytes))
        XCTAssertEqual(restored.address, overlay.address)
    }

    func testPDFImportFailurePreservesSavedReaderAndDoesNotOfferSaveRecovery() async throws {
        let (stand, root) = try await testStand()
        let chart = try XCTUnwrap(stand.current)
        let document = try XCTUnwrap(stand.pdfView.document)
        let before = stand.charts.map(\.id)
        let source = root.appendingPathComponent("invalid-input.pdf")
        try Data("Not a PDF".utf8).write(to: source)
        await stand.importFile(source)
        XCTAssertNotNil(stand.error)
        XCTAssertFalse(stand.needsSaveRecovery, "A failed import must not suggest retrying an unrelated ink save")
        XCTAssertEqual(stand.current?.id, chart.id)
        XCTAssertTrue(stand.pdfView.document === document)
        XCTAssertEqual(stand.charts.map(\.id), before)
        XCTAssertEqual(stand.status, "기기에 저장됨")
    }

    func testCachedPDFRepairRequiresIdenticalReceiptAndRetainsDamagedCopy() async throws {
        let (stand, root) = try await testStand()
        let version = try XCTUnwrap(stand.currentLibraryVersion)
        let song = try XCTUnwrap(stand.library.songs.first { $0.id == version.songID })
        let asset = try XCTUnwrap(stand.library.assets.first { $0.id == version.assetID })
        let pages = try XCTUnwrap(asset.pages)
        let folder = root.appendingPathComponent("pdfs")
        let target = folder.appendingPathComponent(asset.filename)
        let original = try Data(contentsOf: target)
        let vault = try DocumentVault(root: folder)
        let damaged = Data("Damaged downloaded copy".utf8)
        try damaged.write(to: target, options: .atomic)
        try vault.cachePublished(original, song: song, version: version, sha256: asset.sha256, bytes: asset.bytes, pages: pages)
        XCTAssertEqual(try vault.sourceBytes(version.id), original)
        let recovery = folder.appendingPathComponent("RecoveryCopies")
        let retained = try FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil)
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(retained.first)), damaged)
        XCTAssertEqual(try vault.library.snapshot(), stand.library)

        try damaged.write(to: target, options: .atomic)
        let changed = LibraryVersion(id: version.id, songID: version.songID, number: version.number,
                                     assetID: version.assetID, label: "Altered receipt", writtenKey: version.writtenKey)
        XCTAssertThrowsError(try vault.cachePublished(original, song: song, version: changed,
                                                     sha256: asset.sha256, bytes: asset.bytes, pages: pages))
        XCTAssertEqual(try Data(contentsOf: target), damaged)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil).count, 1)
    }

    func testStorageFailureBlocksNavigationRetainsInkAndRetries() async throws {
        let (stand, root) = try await testStand()
        let v1 = try XCTUnwrap(stand.current)
        let v2 = try XCTUnwrap(stand.charts.first { $0.name == "song_A_v2_G" })
        let overlay = try await readyOverlay(stand)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("personal.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TRIGGER m0_test_fault BEFORE INSERT ON personal_ink BEGIN SELECT RAISE(ABORT, 'synthetic storage fault'); END", nil, nil, nil), SQLITE_OK)
        overlay.replaceWithUndo(MusicStand.sampleTeamDrawing())
        let bytes = overlay.personal.drawing.dataRepresentation()
        await stand.choose(v2)
        XCTAssertEqual(stand.current?.id, v1.id)
        XCTAssertNotNil(stand.error)
        XCTAssertTrue(stand.needsSaveRecovery)
        XCTAssertNotEqual(stand.status, "기기에 저장됨")
        XCTAssertEqual(overlay.personal.drawing.dataRepresentation(), bytes)
        let store = try LocalInkStore(url: root.appendingPathComponent("personal.sqlite"))
        let failed = try await store.load(overlay.address)
        XCTAssertNil(failed)
        let outbox = try await store.pendingRevisionCount()
        XCTAssertEqual(outbox, 0)
        XCTAssertEqual(sqlite3_exec(database, "DROP TRIGGER m0_test_fault", nil, nil, nil), SQLITE_OK)
        await stand.retrySave()
        XCTAssertNil(stand.error)
        XCTAssertFalse(stand.needsSaveRecovery)
        XCTAssertEqual(stand.status, "기기에 저장됨")
        let saved = try await store.load(overlay.address)
        XCTAssertEqual(saved?.archive, bytes)
        await stand.choose(v2)
        XCTAssertEqual(stand.current?.id, v2.id)
    }

    func testActiveStrokeBlocksPageAndVersionUntilPenUp() async throws {
        let (stand, root) = try await testStand()
        let version = try XCTUnwrap(stand.current)
        let other = try XCTUnwrap(stand.charts.first { $0.name == "song_A_v2_G" })
        let overlay = try await readyOverlay(stand)
        stand.canvasViewDidBeginUsingTool(overlay.personal)
        overlay.replaceWithUndo(MusicStand.sampleTeamDrawing())
        await stand.choose(other)
        XCTAssertEqual(stand.current?.id, version.id)
        await stand.turnPage(1)
        XCTAssertEqual(stand.pageIndex, 0)
        let store = try LocalInkStore(url: root.appendingPathComponent("personal.sqlite"))
        let duringStroke = try await store.load(overlay.address)
        XCTAssertNil(duringStroke)
        stand.canvasViewDidEndUsingTool(overlay.personal)
        await stand.retrySave()
        XCTAssertNil(stand.error)
        await stand.turnPage(1)
        XCTAssertEqual(stand.pageIndex, 1)
        let blank = try await readyOverlay(stand)
        XCTAssertEqual(blank.personal.drawing.strokes.count, 0)
        await stand.turnPage(-1)
        let restored = try await readyOverlay(stand)
        XCTAssertEqual(restored.personal.drawing.strokes.count, 1)
    }

    func testLateDrawingCallbackAfterPenUpIsAutomaticallyCommitted() async throws {
        let (stand, root) = try await testStand()
        let overlay = try await readyOverlay(stand)
        let reader = try LocalInkStore(url: root.appendingPathComponent("personal.sqlite"))
        func committed(_ archive: Data) async throws -> Bool {
            let deadline = ContinuousClock().now.advanced(by: .seconds(2))
            while ContinuousClock().now < deadline {
                if try await reader.load(overlay.address)?.archive == archive { return true }
                try await Task.sleep(for: .milliseconds(10))
            }
            return false
        }

        stand.canvasViewDidBeginUsingTool(overlay.personal)
        overlay.personal.drawing = MusicStand.sampleTeamDrawing()
        stand.canvasViewDrawingDidChange(overlay.personal)
        stand.canvasViewDidEndUsingTool(overlay.personal)
        let initialArchive = overlay.lastCapturedArchive
        let firstCommitted = try await committed(initialArchive)
        XCTAssertTrue(firstCommitted)
        // PencilKit can finalize points after pen-up. Deliver that callback
        // after the earlier debounce has already committed, without a flush.
        overlay.personal.drawing = PKDrawing(strokes: overlay.personal.drawing.strokes + MusicStand.sampleTeamDrawing().strokes)
        stand.canvasViewDrawingDidChange(overlay.personal)
        let finalArchive = overlay.lastCapturedArchive
        XCTAssertNotEqual(finalArchive, initialArchive)
        let finalCommitted = try await committed(finalArchive)
        XCTAssertTrue(finalCommitted, "A late drawing callback must schedule its own durable save")
        XCTAssertEqual(stand.status, String(localized: "기기에 저장됨"))
    }

    func testCorruptInkDisablesWritingUntilDurableRestoreIsRepaired() async throws {
        let (stand, root) = try await testStand()
        let original = try await readyOverlay(stand)
        let v2 = try XCTUnwrap(stand.charts.first { $0.name == "song_A_v2_G" })
        let source = try XCTUnwrap(Bundle.main.url(forResource: "song_A_v2_G", withExtension: "pdf", subdirectory: "pdfs"))
        let geometry = try XCTUnwrap(PDFDocument(url: source)?.page(at: 0)).canonicalGeometry()
        let address = try InkAddress(churchID: original.address.churchID, ownerID: original.address.ownerID,
                                     versionID: v2.id, pageIndex: 0)
        let store = try LocalInkStore(url: root.appendingPathComponent("personal.sqlite"))
        try await store.save(InkSnapshot(address: address, geometry: geometry, generation: 1,
                                        archive: Data("invalid synthetic ink".utf8)))
        await stand.choose(v2)
        let page = try XCTUnwrap(stand.pdfView.document?.page(at: 0))
        let overlay = try XCTUnwrap(stand.pdfView(stand.pdfView, overlayViewFor: page) as? PageInkView)
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while stand.error == nil, ContinuousClock().now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(stand.error)
        XCTAssertFalse(overlay.ready)
        XCTAssertFalse(overlay.personal.isUserInteractionEnabled)
        XCTAssertNil(stand.currentOverlay)
        await stand.retrySave()
        XCTAssertFalse(overlay.ready)
        let replacement = MusicStand.sampleTeamDrawing()
        let replacementBytes = replacement.dataRepresentation()
        try await store.save(InkSnapshot(address: address, geometry: geometry, generation: 2,
                                        archive: replacementBytes))
        await stand.retrySave()
        XCTAssertNil(stand.error)
        XCTAssertTrue(overlay.ready)
        XCTAssertTrue(overlay.personal.isUserInteractionEnabled)
        let repaired = try await store.load(address)
        XCTAssertEqual(repaired?.archive, replacementBytes)
        assertSameInk(overlay.personal.drawing, try PKDrawing(data: replacementBytes))
    }

    func testFingerDrawingHitTestsTheDisplayedPDFKitOverlay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stand = MusicStand(applicationSupport: root)
        addTeardownBlock { @MainActor [weak stand] in
            let deadline = ContinuousClock().now.advanced(by: .seconds(5))
            while stand != nil, ContinuousClock().now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            // Let restore tasks/database ownership end before removing test files.
            XCTAssertNil(stand)
            if stand == nil { try FileManager.default.removeItem(at: root) }
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 768, height: 1024))
        let controller = UIViewController()
        controller.view = stand.pdfView
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; controller.view = nil }
        await stand.start()
        stand.setFingerTesting(true)
        stand.setTool(1)
        stand.pdfView.layoutDocumentView()
        stand.pdfView.layoutIfNeeded()

        func displayedOverlay(in view: UIView) -> PageInkView? {
            if let overlay = view as? PageInkView { return overlay }
            return view.subviews.lazy.compactMap { displayedOverlay(in: $0) }.first
        }
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while displayedOverlay(in: stand.pdfView) == nil, ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        // Use the actual overlay installed by PDFKit, not a manually added canvas.
        let overlay = try XCTUnwrap(displayedOverlay(in: stand.pdfView))
        try await waitUntilReady(overlay)
        // Check the real PDFKit-installed hierarchy. A detached UIView's trait
        // collection does not resolve its appearance override on iPadOS 17.
        XCTAssertEqual(overlay.personal.traitCollection.userInterfaceStyle, .light)
        XCTAssertEqual(overlay.personal.drawingPolicy, .anyInput)
        XCTAssertTrue(overlay.personal.isUserInteractionEnabled)
        XCTAssertEqual((overlay.personal.tool as? PKInkingTool)?.inkType, .marker)
        let point = overlay.personal.convert(CGPoint(x: 100, y: 100), to: stand.pdfView)
        let hit = stand.pdfView.hitTest(point, with: nil)
        XCTAssertTrue(hit === overlay.personal || hit?.isDescendant(of: overlay.personal) == true,
                      "PDFKit must route drawing hits to the displayed personal canvas")
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent { stand.setTool(0) }
        let pen = try XCTUnwrap(overlay.personal.tool as? PKInkingTool)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        XCTAssertTrue(pen.color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
            .getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        XCTAssertEqual(red, 0, accuracy: 0.001)
        XCTAssertEqual(green, 0, accuracy: 0.001)
        XCTAssertEqual(blue, 0, accuracy: 0.001)
        XCTAssertEqual(alpha, 1, accuracy: 0.001)
        XCTAssertEqual(stand.selectedToolKind, 0)
        stand.setFingerTesting(false)
        XCTAssertEqual(overlay.personal.drawingPolicy, .pencilOnly)
    }

    func testRealPencilKitArchiveSurvivesStoreReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("ink.sqlite")
        let address = try InkAddress(churchID: UUID(), ownerID: UUID(), versionID: UUID(), pageIndex: 2)
        let geometry = try PageGeometry(cropX: 20, cropY: 28, cropWidth: 572, cropHeight: 740, rotation: 90)
        let drawing = MusicStand.sampleTeamDrawing()
        let snapshot = InkSnapshot(address: address, geometry: geometry, generation: 1, archive: drawing.dataRepresentation())
        let store = try LocalInkStore(url: url)
        try await store.save(snapshot)
        let reopened = try LocalInkStore(url: url)
        let saved = try await reopened.load(address)
        XCTAssertEqual(saved, snapshot)
        let recovered = try PKDrawing(data: XCTUnwrap(saved?.archive))
        XCTAssertEqual(recovered.strokes.count, drawing.strokes.count)
        XCTAssertEqual(recovered.bounds, drawing.bounds)
    }

    func testSelectedClipboardSurvivesSourceClosureAndPreservesAspectRatio() throws {
        let clipboard = InkClipboard()
        let first = MusicStand.sampleTeamDrawing()
        let address = try InkAddress(churchID: UUID(), ownerID: UUID(), versionID: UUID(), pageIndex: 0)
        let geometry = try PageGeometry(cropX: 0, cropY: 0, cropWidth: 612, cropHeight: 792, rotation: 0)
        weak var releasedSource: PageInkView?
        var originalBytes = Data()
        autoreleasepool {
            let sourceView = PageInkView(address: address, geometry: geometry, pdfView: PDFView(), page: PDFPage())
            releasedSource = sourceView
            let other = first.transformed(using: CGAffineTransform(translationX: 0, y: 200))
            let original = PKDrawing(strokes: first.strokes + other.strokes)
            sourceView.restore(original, generation: 1)
            originalBytes = sourceView.personal.drawing.dataRepresentation()
            XCTAssertEqual(clipboard.copy(from: original, address: address, geometry: geometry, rectangle: first.bounds), 1)
            XCTAssertEqual(sourceView.personal.drawing.dataRepresentation(), originalBytes)
        }
        XCTAssertNil(releasedSource)
        let placed = try XCTUnwrap(clipboard.placed(at: CGPoint(x: 300, y: 400), scale: 0.5))
        XCTAssertEqual(placed.strokes.count, 1)
        XCTAssertEqual(placed.bounds.midX, 300, accuracy: 2)
        XCTAssertEqual(placed.bounds.midY, 400, accuracy: 2)
        let expectedTransform = CGAffineTransform(a: 0.5, b: 0, c: 0, d: 0.5,
                                                 tx: 300 - first.bounds.midX * 0.5, ty: 400 - first.bounds.midY * 0.5)
        for index in 0..<first.strokes[0].path.count {
            let expected = first.strokes[0].path[index].location.applying(first.strokes[0].transform).applying(expectedTransform)
            let actual = placed.strokes[0].path[index].location.applying(placed.strokes[0].transform)
            XCTAssertEqual(actual.x, expected.x, accuracy: 0.001)
            XCTAssertEqual(actual.y, expected.y, accuracy: 0.001)
        }
        let rendered = first.bounds.applying(expectedTransform)
        XCTAssertEqual(placed.bounds.minX, rendered.minX, accuracy: 1)
        XCTAssertEqual(placed.bounds.minY, rendered.minY, accuracy: 1)
        XCTAssertEqual(placed.bounds.maxX, rendered.maxX, accuracy: 1)
        XCTAssertEqual(placed.bounds.maxY, rendered.maxY, accuracy: 1)
        XCTAssertEqual(clipboard.selection?.source, address)
    }

    func testNativeSaveBoundaryAcrossVersionSwitchAndOverlayRecreation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stand = MusicStand(applicationSupport: root)
        await stand.start()
        let v1 = try XCTUnwrap(stand.current)
        let v2 = try XCTUnwrap(stand.charts.first { $0.name == "song_A_v2_G" })
        let page = try XCTUnwrap(stand.pdfView.document?.page(at: 0))
        let original = try XCTUnwrap(stand.pdfView(stand.pdfView, overlayViewFor: page) as? PageInkView)
        try await waitUntilReady(original)
        original.replaceWithUndo(MusicStand.sampleTeamDrawing())
        let bytes = original.personal.drawing.dataRepresentation()
        let capturedAddress = original.address
        await stand.choose(v2) // Awaits local commit before document/overlay replacement.
        XCTAssertEqual(stand.current?.id, v2.id)
        let store = try LocalInkStore(url: root.appendingPathComponent("personal.sqlite"))
        let saved = try await store.load(capturedAddress)
        XCTAssertEqual(saved?.archive, bytes)
        let v2Address = try InkAddress(churchID: capturedAddress.churchID, ownerID: capturedAddress.ownerID,
                                      versionID: v2.id, pageIndex: 0)
        let destination = try await store.load(v2Address)
        XCTAssertNil(destination)
        await stand.choose(v1)
        let restoredPage = try XCTUnwrap(stand.pdfView.document?.page(at: 0))
        let restored = try XCTUnwrap(stand.pdfView(stand.pdfView, overlayViewFor: restoredPage) as? PageInkView)
        try await waitUntilReady(restored)
        // SQLite must retain the exact archive (asserted above). PencilKit may
        // re-encode an unchanged drawing when attaching it to a new canvas.
        // Verify every recovered stroke/point attribute instead of archive encoding.
        let decoded = try PKDrawing(data: bytes)
        assertSameInk(restored.personal.drawing, decoded)
    }

    func testPasteUndoLeavesTeamAndEarlierPersonalInkUnchanged() throws {
        let geometry = try PageGeometry(cropX: 0, cropY: 0, cropWidth: 612, cropHeight: 792, rotation: 0)
        let address = try InkAddress(churchID: UUID(), ownerID: UUID(), versionID: UUID(), pageIndex: 0)
        let overlay = PageInkView(address: address, geometry: geometry, pdfView: PDFView(), page: PDFPage())
        let previous = MusicStand.sampleTeamDrawing()
        overlay.restore(previous, generation: 1)
        let teamImage = previous.image(from: overlay.team.bounds, scale: 1)
        overlay.team.image = teamImage
        let pasted = previous.transformed(using: CGAffineTransform(translationX: 100, y: 100))
        overlay.replaceWithUndo(PKDrawing(strokes: previous.strokes + pasted.strokes))
        XCTAssertEqual(overlay.personal.drawing.strokes.count, 2)
        let undoManager = try XCTUnwrap(overlay.personal.undoManager)
        undoManager.undo()
        XCTAssertEqual(overlay.personal.drawing.dataRepresentation(), previous.dataRepresentation())
        XCTAssertTrue(overlay.team.image === teamImage)
        undoManager.redo()
        XCTAssertEqual(overlay.personal.drawing.strokes.count, 2)
    }

    func testFixturePDFKitConversionsAndCanonicalCanvasAlignment() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "geometry_rotations", withExtension: "pdf", subdirectory: "pdfs"))
        let document = try XCTUnwrap(PDFDocument(url: url))
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 900, height: 1100))
        let window = UIWindow(frame: view.frame)
        let controller = UIViewController(); controller.view = view
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        view.document = document; view.displayBox = .cropBox; view.displayMode = .singlePage
        for index in 0..<4 {
            let page = try XCTUnwrap(document.page(at: index))
            let geometry = try page.canonicalGeometry()
            let address = try InkAddress(churchID: UUID(), ownerID: UUID(), versionID: UUID(), pageIndex: index)
            view.go(to: page)
            for scale in [1.0, 2.0, 4.0] {
                view.scaleFactor = scale; view.layoutDocumentView(); view.layoutIfNeeded()
                let overlay = PageInkView(address: address, geometry: geometry, pdfView: view, page: page)
                // Exercise the affine adapter in a view with independent rotation/translation.
                overlay.frame = view.bounds; view.addSubview(overlay)
                overlay.transform = CGAffineTransform(rotationAngle: CGFloat(index) * .pi / 2)
                overlay.alignToPDF()
                let native = CGPoint(x: geometry.cropX + 97, y: geometry.cropY + 176)
                let canonical = geometry.canonicalPoint(pdfX: native.x, pdfY: native.y)
                let expected = view.convert(native, from: page)
                let actual = overlay.personal.convert(CGPoint(x: canonical.x, y: canonical.y), to: view)
                XCTAssertEqual(actual.x, expected.x, accuracy: 2 * scale)
                XCTAssertEqual(actual.y, expected.y, accuracy: 2 * scale)
                let recovered = view.convert(expected, to: page)
                XCTAssertEqual(recovered.x, native.x, accuracy: 2)
                XCTAssertEqual(recovered.y, native.y, accuracy: 2)
                overlay.removeFromSuperview()
            }
        }
    }
}
