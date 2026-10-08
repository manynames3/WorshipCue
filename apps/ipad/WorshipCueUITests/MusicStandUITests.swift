import XCTest
import UIKit

final class MusicStandUITests: XCTestCase {
    private var app: XCUIApplication!
    private var canvas: XCUIElement { app.descendants(matching: .any)["personalInkCanvas"] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-test-store", UUID().uuidString]
        app.launch()
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        assertCount(0)
        app.buttons["손가락 필기"].tap()
    }

    override func tearDownWithError() throws { app.terminate() }

    private func wait(_ element: XCUIElement, predicate: String, argument: Any) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate, argumentArray: [argument]), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }

    private func assertCount(_ count: Int) { wait(canvas, predicate: "value CONTAINS %@", argument: "\(count)획") }
    private func saved() { wait(app.staticTexts["saveStatus"], predicate: "label == %@", argument: "기기에 저장됨") }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func assertVisibleBlackStroke(at y: CGFloat, on element: XCUIElement,
                                          verticalTolerance: CGFloat = 2,
                                          file: StaticString = #filePath, line: UInt = #line) throws {
        try assertVisibleStroke(at: y, on: element, verticalTolerance: verticalTolerance,
                                matches: { r, g, b in r < 80 && g < 80 && b < 80 }, file: file, line: line)
    }
    private func assertVisibleStroke(at y: CGFloat, on element: XCUIElement,
                                     verticalTolerance: CGFloat = 2,
                                     matches: (UInt8, UInt8, UInt8) -> Bool,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let image = try XCTUnwrap(app.screenshot().image.cgImage, file: file, line: line)
        let frame = element.frame
        let scaleX = CGFloat(image.width) / app.frame.width
        let scaleY = CGFloat(image.height) / app.frame.height
        // This fixture has an empty band here. A stored stroke count alone
        // cannot catch PencilKit rendering white ink over the white PDF.
        let region = CGRect(x: (frame.minX + frame.width * 0.36) * scaleX,
                            y: (frame.minY + frame.height * y - verticalTolerance) * scaleY,
                            width: frame.width * 0.28 * scaleX, height: 2 * verticalTolerance * scaleY).integral
        let crop = try XCTUnwrap(image.cropping(to: region), file: file, line: line)
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let inkPixels = pixels.withUnsafeMutableBytes { buffer -> Int in
            guard let context = CGContext(data: buffer.baseAddress, width: crop.width, height: crop.height,
                                          bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            return stride(from: 0, to: buffer.count, by: 4).filter {
                matches(buffer[$0], buffer[$0 + 1], buffer[$0 + 2]) && buffer[$0 + 3] > 200
            }.count
        }
        XCTAssertGreaterThan(inkPixels, crop.width / 2, "Selected ink color must render visibly on white PDF paper", file: file, line: line)
    }
    private func tool(_ identifier: String) {
        let button = app.buttons[identifier]
        reveal(button)
        button.tap()
    }
    private func reveal(_ element: XCUIElement) {
        let strip = app.scrollViews["toolStrip"]
        for _ in 0..<6 {
            // A partly visible Toggle label is hittable while its switch is
            // still outside the viewport. Reveal the whole control first.
            if element.frame.minX >= strip.frame.minX,
               element.frame.maxX <= strip.frame.maxX, element.isHittable { return }
            if element.frame.midX < strip.frame.midX { strip.swipeRight() }
            else { strip.swipeLeft() }
        }
        XCTAssertTrue(element.isHittable)
    }
    private func stroke(at y: CGFloat) {
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: y))
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: y)))
    }
    private func choose(_ name: String) {
        app.buttons["chartChooser"].tap()
        app.buttons[name].tap()
        wait(app.staticTexts["currentChart"], predicate: "label == %@", argument: name)
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
    }

    private func replaceText(_ field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        let value = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count) + text)
    }

    func testM1WorkspaceSearchPreferenceSetlistStandbyAndColdRelaunch() throws {
        let songID = "20000000-0000-0000-0000-000000000001"
        let v2 = "10000000-0000-0000-0000-000000000002"
        let v3 = "10000000-0000-0000-0000-000000000003"
        app.buttons["openWorkspace"].tap()
        app.buttons["라이브러리"].tap()
        let search = app.textFields["librarySearch"]
        search.tap(); search.typeText("ㅇㅅㄱ")
        XCTAssertTrue(app.buttons["song.\(songID)"].waitForExistence(timeout: 10))
        app.buttons["song.\(songID)"].tap()
        app.buttons["toggleFavorite"].tap()
        XCTAssertFalse(app.buttons["saveSong"].exists, "Favoriting must not activate the neighboring edit action")
        app.buttons["preferVersion.2"].tap()
        wait(app.buttons["preferVersion.2"], predicate: "enabled == %@", argument: false)
        app.buttons["editSong"].tap()
        replaceText(app.textFields["songTitle"], with: "주 하나님 지으신 모든 세계")
        let aliases = app.descendants(matching: .any)["songAliases"]
        XCTAssertTrue(aliases.waitForExistence(timeout: 10)); aliases.tap(); aliases.typeText("찬송 연습")
        app.buttons["saveSong"].tap()
        XCTAssertTrue(app.staticTexts["주 하나님 지으신 모든 세계"].waitForExistence(timeout: 10))
        capture("M1 explicit versions and private preferred chart")
        app.buttons["openVersion.3"].tap()
        wait(app.staticTexts["currentChart"], predicate: "label == %@", argument: "song_A_v3_A")
        assertCount(0)
        app.buttons["openWorkspace"].tap()
        app.buttons["newSetlist"].tap()
        replaceText(app.textFields["setlistTitle"], with: "수요 리허설")
        app.buttons["addPlannedSong"].tap()
        app.buttons["addVersion.\(v2)"].tap()
        app.buttons["addStandbySong"].tap()
        app.buttons["addVersion.\(v3)"].tap()
        let firstItem = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "editItem.")).firstMatch
        XCTAssertTrue(firstItem.waitForExistence(timeout: 10)); firstItem.tap()
        replaceText(app.textFields["performanceKey"], with: "Bb")
        app.buttons["applySetlistItem"].tap()
        XCTAssertTrue(app.staticTexts["악보와 연주 키가 다릅니다"].waitForExistence(timeout: 10))
        app.buttons["prepareSetlist"].tap()
        wait(app.staticTexts["preparationReport"], predicate: "label CONTAINS %@", argument: "오프라인 파일 확인 완료")
        capture("M1 planned and standby songs verified locally")
        app.buttons["saveSetlist"].tap()
        XCTAssertTrue(app.staticTexts["수요 리허설"].waitForExistence(timeout: 10))
        app.buttons["closeWorkspace"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        wait(app.staticTexts["currentChart"], predicate: "label == %@", argument: "song_A_v3_A")
        app.buttons["openWorkspace"].tap()
        XCTAssertTrue(app.staticTexts["수요 리허설"].waitForExistence(timeout: 10))
        app.buttons["라이브러리"].tap()
        app.textFields["librarySearch"].tap(); app.textFields["librarySearch"].typeText("ㅈㅎㄴㄴ")
        XCTAssertTrue(app.buttons["song.\(songID)"].waitForExistence(timeout: 10))
        app.buttons["song.\(songID)"].tap()
        XCTAssertFalse(app.buttons["preferVersion.2"].isEnabled)
        capture("M1 cold relaunch retains library and explicit preference")
    }

    func testM1ExportLayerChoiceAndShareSheet() throws {
        tool("tool.pen"); stroke(at: 0.8); assertCount(1); saved()
        app.buttons["openExport"].tap()
        let personal = app.switches["exportPersonalInk"]
        XCTAssertTrue(personal.waitForExistence(timeout: 10)); personal.tap()
        app.buttons["createExport"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 20) || app.buttons["Copy"].exists || app.buttons["Save to Files"].exists,
                      "Export must present the native share sheet with a new PDF")
        capture("M1 source-only PDF fallback share sheet")
    }

    func testM1WeeklyPacketRangesKeepReaderAndCreateIndependentSongs() throws {
        app.buttons["openWorkspace"].tap(); app.buttons["라이브러리"].tap()
        app.textFields["librarySearch"].tap(); app.textFields["librarySearch"].typeText("weekly_packet")
        let source = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "song.", "weekly_packet")).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10)); source.tap()
        app.buttons["악보 작업"].tap(); app.buttons["주간 PDF에서 곡 나누기"].tap()
        replaceText(app.textFields["packetTitle.0"], with: "주간 예시 첫 곡")
        replaceText(app.textFields["packetLast.0"], with: "2")
        replaceText(app.textFields["packetKey.0"], with: "G")
        replaceText(app.textFields["packetLabel.0"], with: "첫 곡 범위")
        app.buttons["addPacketRange"].tap()
        replaceText(app.textFields["packetTitle.1"], with: "주간 예시 둘째 곡")
        replaceText(app.textFields["packetFirst.1"], with: "3")
        replaceText(app.textFields["packetLast.1"], with: "5")
        replaceText(app.textFields["packetKey.1"], with: "A")
        replaceText(app.textFields["packetLabel.1"], with: "둘째 곡 범위")
        app.buttons["importPacketRanges"].tap()
        XCTAssertTrue(app.buttons["openVersion.1"].waitForExistence(timeout: 15))
        app.buttons["닫기"].tap()
        replaceText(app.textFields["librarySearch"], with: "주간 예시")
        let derived = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "song.", "주간 예시"))
        XCTAssertEqual(derived.count, 2)
        app.buttons["closeWorkspace"].tap()
        XCTAssertEqual(app.staticTexts["currentChart"].label, "song_A_v1_G", "Import must not navigate or move notes")
        choose("첫 곡 범위"); XCTAssertEqual(app.staticTexts["pagePosition"].label, "현재 페이지 1, 전체 2")
        assertCount(0)
        choose("둘째 곡 범위"); XCTAssertEqual(app.staticTexts["pagePosition"].label, "현재 페이지 1, 전체 3")
        choose("weekly_packet"); XCTAssertEqual(app.staticTexts["pagePosition"].label, "현재 페이지 1, 전체 5")
        saved(); app.terminate(); app.launch()
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        choose("첫 곡 범위"); XCTAssertEqual(app.staticTexts["pagePosition"].label, "현재 페이지 1, 전체 2")
        capture("M1 manually extracted weekly packet retained after relaunch")
    }

    func testM1SetlistRepeatAndCloneKeepOriginalOccurrencesAndKeys() throws {
        let v1 = "10000000-0000-0000-0000-000000000001", v2 = "10000000-0000-0000-0000-000000000002"
        app.buttons["openWorkspace"].tap(); app.buttons["newSetlist"].tap()
        replaceText(app.textFields["setlistTitle"], with: "주일 원본")
        app.buttons["addPlannedSong"].tap(); app.buttons["addVersion.\(v1)"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "itemActions.")).firstMatch.tap()
        app.buttons["같은 곡 한 번 더 추가"].tap()
        app.buttons["addStandbySong"].tap(); app.buttons["addVersion.\(v2)"].tap()
        app.buttons["saveSetlist"].tap()
        let original = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "setlist.", "주일 원본")).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 10)); original.tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "editItem."))
        let originalIDs = Set(rows.allElementsBoundByIndex.map(\.identifier))
        XCTAssertEqual(originalIDs.count, 3)
        app.buttons["setlistActions"].tap(); app.buttons["cloneSetlist"].tap()
        XCTAssertEqual(app.textFields["setlistTitle"].value as? String, "주일 원본 복사")
        let cloneIDs = Set(rows.allElementsBoundByIndex.map(\.identifier))
        XCTAssertEqual(cloneIDs.count, 3); XCTAssertTrue(originalIDs.isDisjoint(with: cloneIDs))
        replaceText(app.textFields["setlistTitle"], with: "다음 주")
        rows.firstMatch.tap(); replaceText(app.textFields["performanceKey"], with: "Bb"); app.buttons["applySetlistItem"].tap()
        app.buttons["saveSetlist"].tap()
        XCTAssertTrue(app.staticTexts["다음 주"].waitForExistence(timeout: 10))
        original.tap()
        XCTAssertEqual(app.textFields["setlistTitle"].value as? String, "주일 원본")
        XCTAssertEqual(Set(rows.allElementsBoundByIndex.map(\.identifier)), originalIDs)
        XCTAssertFalse(app.staticTexts["악보와 연주 키가 다릅니다"].exists, "Editing the clone must not change the original keys")
        capture("M1 original setlist preserved after clone edits")
    }

    func testPrivatePDFPairFingerInkSelectedTransferAndColdRelaunch() throws {
        guard let value = ProcessInfo.processInfo.environment["WORSHIPCUE_PRIVATE_PDF_RUN"],
              let run = UUID(uuidString: value) else {
            throw XCTSkip("Private PDF pair not supplied; run scripts/test_private_pdf_pair.py locally")
        }
        app.terminate()
        app.launchArguments = ["--ui-test-store", run.uuidString]
        app.launch()
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        app.buttons["손가락 필기"].tap()
        choose("Private arrangement A")
        for _ in 0..<3 { app.buttons["nextPage"].tap() }
        XCTAssertEqual(app.staticTexts["pagePosition"].label, "현재 페이지 4, 전체 4")
        assertCount(0)
        tool("tool.pen")
        let picker = app.buttons["inkColorPicker"]
        picker.tap(); app.buttons["inkColor.blue"].tap()
        stroke(at: 0.86); assertCount(1)
        try assertVisibleStroke(at: 0.86, on: canvas, matches: { r, g, b in b > 150 && r < 100 && g < 150 })
        tool("tool.marker")
        picker.tap(); app.buttons["inkColor.pink"].tap()
        stroke(at: 0.93); assertCount(2)
        try assertVisibleStroke(at: 0.93, on: canvas, verticalTolerance: 4,
                               matches: { r, g, b in Int(r) > Int(g) + 25 && Int(b) > Int(g) + 10 })
        capture("PRIVATE chart A with personal ink")
        saved()
        tool("tool.select")
        let transfer = app.descendants(matching: .any)["noteTransferCanvas"]
        transfer.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.82))
            .press(forDuration: 0.05, thenDragTo: transfer.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.89)))
        wait(app.buttons["copySelection"], predicate: "label CONTAINS %@", argument: "(1)")
        app.buttons["copySelection"].tap()
        choose("Private arrangement B"); assertCount(0)
        for _ in 0..<3 { app.buttons["nextPage"].tap() }
        assertCount(0)
        tool("tool.paste")
        app.buttons["cancelTransfer"].tap(); assertCount(0)
        tool("tool.paste")
        transfer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: transfer.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.85)))
        app.buttons["scaleDown"].tap(); app.buttons["scaleUp"].tap()
        // B uses much larger document coordinates. Enlarge deliberately in
        // the preview; native point sizes must not silently auto-align.
        for _ in 0..<4 { app.buttons["scaleUp"].tap() }
        capture("PRIVATE manual note placement across different page geometry")
        app.buttons["commitPaste"].tap(); assertCount(1)
        try assertVisibleStroke(at: 0.85, on: canvas, verticalTolerance: canvas.frame.height * 0.08,
                               matches: { r, g, b in b > 150 && r < 100 && g < 150 })
        tool("tool.undo"); assertCount(0)
        tool("tool.redo"); assertCount(1)
        saved()
        choose("Private arrangement A"); assertCount(0)
        for _ in 0..<3 { app.buttons["nextPage"].tap() }
        assertCount(2)
        choose("Private arrangement B"); assertCount(0)
        for _ in 0..<3 { app.buttons["nextPage"].tap() }
        assertCount(1)
        app.terminate(); app.launch()
        XCTAssertTrue(canvas.waitForExistence(timeout: 15)); assertCount(1)
        XCTAssertEqual(app.staticTexts["currentChart"].label, "Private arrangement B")
        XCTAssertEqual(app.staticTexts["pagePosition"].label, "현재 페이지 4, 전체 4")
        try assertVisibleStroke(at: 0.85, on: canvas, verticalTolerance: canvas.frame.height * 0.08,
                               matches: { r, g, b in b > 150 && r < 100 && g < 150 })
        capture("PRIVATE restored target chart and personal ink")
    }

    func testDrawingToolsSaveAndColdRelaunch() throws {
        tool("tool.pen"); stroke(at: 0.45); assertCount(1)
        capture("Black pen visibility")
        try assertVisibleBlackStroke(at: 0.45, on: canvas)
        tool("tool.marker"); stroke(at: 0.65); assertCount(2)
        capture("Synthetic pen and highlighter")
        tool("tool.eraser"); stroke(at: 0.45); assertCount(1)
        tool("tool.undo"); assertCount(2)
        tool("tool.redo"); assertCount(1)
        saved()
        app.terminate(); app.launch()
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        assertCount(1)
        XCTAssertEqual(app.staticTexts["currentChart"].label, "song_A_v1_G")
        XCTAssertEqual(app.staticTexts["pagePosition"].label, "현재 페이지 1, 전체 2")
    }

    func testCompactColorPickerDismissalRenderedColorsAndRememberedChoices() throws {
        tool("tool.pen")
        let picker = app.buttons["inkColorPicker"]
        picker.tap()
        XCTAssertTrue(app.buttons["inkColor.blue"].waitForExistence(timeout: 5))
        capture("Compact pen color palette")
        app.buttons["closeInkColors"].tap()
        XCTAssertFalse(app.buttons["inkColor.blue"].exists)
        picker.tap()
        // Dismiss by tapping chart paper, away from the anchored popover.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.85)).tap()
        XCTAssertFalse(app.buttons["inkColor.blue"].exists)
        assertCount(0)
        picker.tap(); app.buttons["inkColor.blue"].tap()
        XCTAssertFalse(app.buttons["inkColor.blue"].exists)
        XCTAssertEqual(picker.value as? String, "파랑")
        stroke(at: 0.45); assertCount(1)
        try assertVisibleStroke(at: 0.45, on: canvas, matches: { r, g, b in b > 150 && r < 100 && g < 150 })
        tool("tool.marker")
        XCTAssertEqual(picker.value as? String, "노랑")
        picker.tap(); app.buttons["inkColor.pink"].tap()
        XCTAssertEqual(picker.value as? String, "분홍")
        stroke(at: 0.65); assertCount(2)
        try assertVisibleStroke(at: 0.65, on: canvas, verticalTolerance: 4,
                               matches: { r, g, b in Int(r) > Int(g) + 25 && Int(b) > Int(g) + 10 })
        capture("Blue pen and pink highlighter")
        tool("tool.pen"); XCTAssertEqual(picker.value as? String, "파랑")
        saved(); app.terminate(); app.launch()
        XCTAssertTrue(canvas.waitForExistence(timeout: 15)); assertCount(2)
        XCTAssertEqual(picker.value as? String, "파랑")
        try assertVisibleStroke(at: 0.45, on: canvas, matches: { r, g, b in b > 150 && r < 100 && g < 150 })
        tool("tool.marker"); XCTAssertEqual(picker.value as? String, "분홍")
        try assertVisibleStroke(at: 0.65, on: canvas, verticalTolerance: 4,
                               matches: { r, g, b in Int(r) > Int(g) + 25 && Int(b) > Int(g) + 10 })
    }

    func testSelectedTransferCancelCommitUndoAndVersionPageIsolation() throws {
        tool("tool.pen"); stroke(at: 0.4); stroke(at: 0.7); assertCount(2)
        tool("tool.select")
        let transfer = app.descendants(matching: .any)["noteTransferCanvas"]
        transfer.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.32))
            .press(forDuration: 0.05, thenDragTo: transfer.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.48)))
        wait(app.buttons["copySelection"], predicate: "label CONTAINS %@", argument: "(1)")
        app.buttons["copySelection"].tap()
        tool("tool.transferDestination")
        app.textFields["transferSongSearch"].tap(); app.textFields["transferSongSearch"].typeText("ㅇㅅㄱ")
        app.buttons["transferVersion.10000000-0000-0000-0000-000000000002"].tap()
        let pagePicker = app.steppers["transferDestinationPage"]
        XCTAssertTrue(pagePicker.waitForExistence(timeout: 10))
        pagePicker.buttons.element(boundBy: 1).tap()
        app.buttons["openTransferDestination"].tap()
        wait(app.staticTexts["currentChart"], predicate: "label == %@", argument: "song_A_v2_G")
        assertCount(0)
        XCTAssertTrue(app.buttons["commitPaste"].waitForExistence(timeout: 10))
        app.buttons["scaleDown"].tap(); app.buttons["scaleUp"].tap()
        transfer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: transfer.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)))
        capture("Manual selected-note paste preview")
        // Paste centers in the visible PDF region, which can differ from the
        // full page's midpoint. This fixture's blank band covers either center.
        try assertVisibleBlackStroke(at: 0.6, on: transfer, verticalTolerance: transfer.frame.height * 0.08)
        app.buttons["cancelTransfer"].tap(); assertCount(0)
        tool("tool.paste"); app.buttons["commitPaste"].tap(); assertCount(1)
        tool("tool.undo"); assertCount(0)
        tool("tool.redo"); assertCount(1); saved()
        choose("song_A_v1_G"); assertCount(2)
        choose("song_A_v2_G"); assertCount(0)
        app.buttons["nextPage"].tap(); assertCount(1)
        saved(); app.terminate(); app.launch()
        XCTAssertTrue(canvas.waitForExistence(timeout: 15)); assertCount(1)
        XCTAssertEqual(app.staticTexts["currentChart"].label, "song_A_v2_G")
        XCTAssertEqual(app.staticTexts["pagePosition"].label, "현재 페이지 2, 전체 3")
    }

    func testReadOnlyTeamLayerUsesExactVersionAndPage() {
        let toggle = app.switches["teamSample"]
        reveal(toggle); toggle.tap()
        wait(toggle, predicate: "value == %@", argument: "1")
        XCTAssertFalse(app.images["teamInkLayer"].exists)
        choose("song_A_v2_G")
        XCTAssertTrue(app.images["teamInkLayer"].waitForExistence(timeout: 10))
        tool("tool.pen"); stroke(at: 0.65); assertCount(1)
        tool("tool.eraser"); stroke(at: 0.65); assertCount(0)
        XCTAssertTrue(app.images["teamInkLayer"].exists)
        tool("tool.undo"); assertCount(1)
        XCTAssertTrue(app.images["teamInkLayer"].exists)
        capture("Read-only team layer with personal ink")
        app.buttons["nextPage"].tap(); assertCount(0)
        XCTAssertFalse(app.images["teamInkLayer"].exists)
        app.buttons["previousPage"].tap(); assertCount(1)
        XCTAssertTrue(app.images["teamInkLayer"].waitForExistence(timeout: 10))
        choose("song_A_v3_A"); assertCount(0)
        XCTAssertFalse(app.images["teamInkLayer"].exists)
    }
}
