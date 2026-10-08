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
        let attachment = XCTAttachment(screenshot: app.screenshot())
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
        choose("song_A_v2_G"); assertCount(0)
        app.buttons["nextPage"].tap(); assertCount(0)
        tool("tool.paste")
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
