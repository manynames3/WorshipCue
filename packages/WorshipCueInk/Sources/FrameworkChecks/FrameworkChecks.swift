import Foundation
import WorshipCueInk
import WorshipCueLocal
#if os(macOS)
import AppKit
import PDFKit
import PencilKit

struct Failure: Error { let message: String }
func require(_ value: Bool, _ message: String) throws {
    guard value else { throw Failure(message: message) }
}

@main struct FrameworkChecks {
    @MainActor static func main() async {
        do { try await runChecks() }
        catch { print("FAIL framework checks: \(error)"); exit(1) }
    }

    @MainActor static func runChecks() async throws {
        guard CommandLine.arguments.count == 2 else { throw Failure(message: "Pass handoff root directory") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: temporary) } catch { print("cleanup failed") } }
        let address = try InkAddress(churchID: UUID(), ownerID: UUID(), versionID: UUID(), pageIndex: 0)
        let geometry = try PageGeometry(cropX: 20, cropY: 28, cropWidth: 572, cropHeight: 740, rotation: 90)
        let points = (0...40).map { index -> PKStrokePoint in
            let angle = CGFloat(index) / 40 * .pi * 2
            return PKStrokePoint(location: CGPoint(x: 200 + cos(angle) * 65, y: 220 + sin(angle) * 25),
                                 timeOffset: Double(index) * 0.01, size: CGSize(width: 3, height: 3),
                                 opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let one = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .systemBlue),
                                              path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)))])
        let second = one.transformed(using: CGAffineTransform(translationX: 0, y: 200))
        let source = PKDrawing(strokes: one.strokes + second.strokes)
        let originalBytes = source.dataRepresentation()
        let databaseURL = temporary.appendingPathComponent("ink.sqlite")
        let store = try LocalInkStore(url: databaseURL)
        let snapshot = InkSnapshot(address: address, geometry: geometry, generation: 1, archive: originalBytes)
        try await store.save(snapshot)
        let reopened = try LocalInkStore(url: databaseURL)
        guard let saved = try await reopened.load(address) else { throw Failure(message: "missing saved drawing") }
        let recovered = try PKDrawing(data: saved.archive)
        try require(saved == snapshot && recovered.strokes.count == 2 && recovered.bounds == source.bounds, "native archive recovery")
        print("PASS real macOS PencilKit archive -> production SQLite store -> reopen -> PKDrawing decode")

        let clipboard = SelectedInkClipboard()
        try require(clipboard.copy(from: source, address: address, geometry: geometry, rectangle: one.bounds) == 1,
                    "only selected stroke copied")
        guard let pasted = clipboard.placed(at: CGPoint(x: 300, y: 400), scale: 0.5) else { throw Failure(message: "paste missing") }
        try require(pasted.strokes.count == 1, "clipboard subset")
        try require(abs(pasted.bounds.midX - 300) <= 2 && abs(pasted.bounds.midY - 400) <= 2, "manual placement")
        // PencilKit rounds rendered bounds to whole points. Test the actual stroke
        // coordinates/affine scale, then bound the rendered-box rounding independently.
        let expectedTransform = CGAffineTransform(a: 0.5, b: 0, c: 0, d: 0.5,
                                                 tx: 300 - one.bounds.midX * 0.5,
                                                 ty: 400 - one.bounds.midY * 0.5)
        let before = one.strokes[0], after = pasted.strokes[0]
        try require(before.path.count == after.path.count, "stroke point count")
        for index in 0..<before.path.count {
            let expected = before.path[index].location.applying(before.transform).applying(expectedTransform)
            let actual = after.path[index].location.applying(after.transform)
            try require(abs(actual.x - expected.x) < 0.001 && abs(actual.y - expected.y) < 0.001,
                        "uniform canonical stroke coordinates")
        }
        let box = one.bounds.applying(expectedTransform)
        try require(abs(pasted.bounds.minX - box.minX) <= 1 && abs(pasted.bounds.minY - box.minY) <= 1 &&
                    abs(pasted.bounds.maxX - box.maxX) <= 1 && abs(pasted.bounds.maxY - box.maxY) <= 1,
                    "rendered bounds rounding tolerance")
        print("MEASURE source rendered bounds \(one.bounds), scaled rendered bounds \(pasted.bounds); uniform path points verified")
        try require(source.dataRepresentation() == originalBytes, "source mutated")
        try require(clipboard.selection?.source == address && clipboard.selection?.geometry == geometry, "clipboard identity")
        print("PASS production selected-stroke clipboard subset, immutable source, uniform manual placement")

        let url = root.appendingPathComponent("fixtures/pdfs/geometry_rotations.pdf")
        guard let document = PDFDocument(url: url), document.pageCount == 4 else { throw Failure(message: "PDF fixture") }
        for index in 0..<4 {
            guard let page = document.page(at: index), let native = page.pageRef else { throw Failure(message: "PDF page") }
            let crop = native.getBoxRect(.cropBox)
            try require(crop == CGRect(x: 20, y: 28, width: 572, height: 740), "native CropBox")
            try require(page.rotation == index * 90, "native PDF rotation")
            let g = try PageGeometry(cropX: crop.minX, cropY: crop.minY, cropWidth: crop.width,
                                     cropHeight: crop.height, rotation: page.rotation)
            let point = g.canonicalPoint(pdfX: 117, pdfY: 204)
            let back = g.pdfPoint(x: point.x, y: point.y)
            try require(back.x == 117 && back.y == 204, "canonical native geometry")
        }
        print("PASS macOS PDFKit fixture opening + native CropBox/rotation metadata")
        let corrupt = PDFDocument(url: root.appendingPathComponent("fixtures/pdfs/corrupt_negative.pdf"))
        try require(corrupt == nil || corrupt?.pageCount == 0, "corrupt PDF parsed")
        print("PASS native PDFKit rejects corrupt fixture")
        print("4 framework check groups passed on macOS; iPad adapter/device interaction NOT VERIFIED")
    }
}
#else
@main struct FrameworkChecks {
    static func main() { fatalError("FrameworkChecks runs on macOS only; use iPad native integration tests on iOS") }
}
#endif
