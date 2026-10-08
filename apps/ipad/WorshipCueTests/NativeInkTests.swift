import XCTest
import PencilKit
import PDFKit
import SQLite3
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
