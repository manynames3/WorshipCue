import UIKit
import PencilKit
import WorshipCueInk

typealias InkClipboard = SelectedInkClipboard

@MainActor final class TransferOverlay: UIView {
    enum Mode { case inactive, select, paste }
    var mode: Mode = .inactive { didSet { isUserInteractionEnabled = mode != .inactive; setNeedsDisplay() } }
    var selection = CGRect.zero
    var preview: PKDrawing?
    var selectedBounds: [CGRect] = []
    var centerPoint = CGPoint.zero
    var scale: CGFloat = 1
    var onChange: (() -> Void)?
    private var start = CGPoint.zero
    private var initialCenter = CGPoint.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; isOpaque = false; isUserInteractionEnabled = false
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
        accessibilityLabel = String(localized: "메모 선택 또는 붙여넣기 위치 이동")
        isAccessibilityElement = true
        accessibilityIdentifier = "noteTransferCanvas"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began {
            start = gesture.location(in: self); initialCenter = centerPoint
        }
        if mode == .select {
            let end = gesture.location(in: self)
            selection = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                               width: abs(start.x - end.x), height: abs(start.y - end.y))
        } else if mode == .paste {
            let delta = gesture.translation(in: self)
            centerPoint = CGPoint(x: initialCenter.x + delta.x, y: initialCenter.y + delta.y)
        }
        onChange?(); setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        if mode == .select {
            context.setFillColor(UIColor.black.withAlphaComponent(0.12).cgColor)
            context.fill(bounds)
        }
        if let preview, mode != .inactive {
            preview.image(from: bounds, scale: 1).draw(in: bounds)
        }
        if mode == .select {
            context.setStrokeColor(UIColor.systemBlue.cgColor)
            context.setFillColor(UIColor.systemBlue.withAlphaComponent(0.12).cgColor)
            context.setLineWidth(2); context.setLineDash(phase: 0, lengths: [6, 4])
            context.fill(selection); context.stroke(selection)
            context.setStrokeColor(UIColor.systemOrange.cgColor)
            for bounds in selectedBounds { context.stroke(bounds.insetBy(dx: -3, dy: -3)) }
        }
    }
}
