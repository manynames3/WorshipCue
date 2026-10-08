import PDFKit
import PencilKit
import UIKit

/// A new, flattened fallback file. Only the source and this local owner's selected ink are available.
@MainActor enum PDFExporter {
    static func write(_ document: PDFDocument, drawings: [Int: PKDrawing], to output: URL) throws {
        guard document.pageCount > 0, drawings.keys.allSatisfy({ $0 >= 0 && $0 < document.pageCount }),
              !FileManager.default.fileExists(atPath: output.path) else { throw VaultError.invalidPDF }
        let temporary = output.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).pdf")
        do {
            let geometries = try (0..<document.pageCount).map { index in
                guard let page = document.page(at: index) else { throw VaultError.invalidPDF }
                return try page.canonicalGeometry()
            }
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: geometries[0].width, height: geometries[0].height))
            try renderer.writePDF(to: temporary) { rendererContext in
                for (index, geometry) in geometries.enumerated() {
                    autoreleasepool {
                        let bounds = CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height)
                        rendererContext.beginPage(withBounds: bounds, pageInfo: [:])
                        let context = rendererContext.cgContext
                        context.setFillColor(UIColor.white.cgColor); context.fill(bounds)
                        context.saveGState()
                        // PDFKit draws the rotated CropBox and its embedded arranger annotations.
                        // UIKit's renderer uses top-left coordinates; PDF drawing uses bottom-left.
                        context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1)
                        document.page(at: index)?.draw(with: .cropBox, to: context)
                        context.restoreGState()
                        if let ink = drawings[index], !ink.strokes.isEmpty {
                            let area = ink.bounds.insetBy(dx: -2, dy: -2).intersection(bounds)
                            if !area.isNull, !area.isEmpty {
                                let scale = min(2, 4096 / max(area.width, area.height))
                                ink.image(from: area, scale: scale).draw(in: area)
                            }
                        }
                    }
                }
            }
            guard let verified = PDFDocument(url: temporary), verified.pageCount == document.pageCount else { throw VaultError.invalidPDF }
            for (index, geometry) in geometries.enumerated() {
                guard let page = verified.page(at: index), try page.canonicalGeometry().width == geometry.width,
                      try page.canonicalGeometry().height == geometry.height else { throw VaultError.geometry }
            }
            try FileManager.default.moveItem(at: temporary, to: output)
        } catch {
            if FileManager.default.fileExists(atPath: temporary.path) {
                do { try FileManager.default.removeItem(at: temporary) }
                catch { /* The failed export never becomes a source asset. */ }
            }
            throw error
        }
    }
}
