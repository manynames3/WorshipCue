import Foundation
import PencilKit
import WorshipCueLocal

/// This object belongs to the stand, never a recycled page view or system pasteboard.
@MainActor public final class SelectedInkClipboard {
    public struct Selection {
        public let source: InkAddress
        public let geometry: PageGeometry
        public let drawing: PKDrawing
        public let bounds: CGRect
    }
    public private(set) var selection: Selection?

    public init() {}

    @discardableResult public func copy(from drawing: PKDrawing, address: InkAddress,
                                geometry: PageGeometry, rectangle: CGRect) -> Int {
        let strokes = drawing.strokes.filter { $0.renderBounds.intersects(rectangle) }
        guard !strokes.isEmpty else { selection = nil; return 0 }
        let clone = PKDrawing(strokes: strokes)
        selection = Selection(source: address, geometry: geometry, drawing: clone, bounds: clone.bounds)
        return strokes.count
    }

    public func placed(at center: CGPoint, scale: CGFloat) -> PKDrawing? {
        guard let selection, scale.isFinite, scale > 0 else { return nil }
        let b = selection.bounds
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                          tx: center.x - b.midX * scale,
                                          ty: center.y - b.midY * scale)
        return selection.drawing.transformed(using: transform)
    }
}

