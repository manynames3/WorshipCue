import UIKit
import PDFKit
import PencilKit
import WorshipCueLocal

@MainActor final class PersonalCanvas: PKCanvasView {
    private let personalHistory = UndoManager()
    override var undoManager: UndoManager? { personalHistory }
}

@MainActor final class PageInkView: UIView {
    let address: InkAddress
    let geometry: PageGeometry
    let personal = PersonalCanvas()
    let team = UIImageView()
    let transfer = TransferOverlay()
    weak var pdfView: PDFView?
    weak var page: PDFPage?
    var fingerTesting = false
    var applyingDrawing = false
    var generation: Int64 = 0
    var lastCapturedArchive = Data()
    var ready = false
    var onProgrammaticChange: (() -> Void)?

    init(address: InkAddress, geometry: PageGeometry, pdfView: PDFView, page: PDFPage) {
        self.address = address; self.geometry = geometry
        self.pdfView = pdfView; self.page = page
        super.init(frame: .zero)
        // PDF paper stays white in Dark Mode; PencilKit must not invert its ink.
        overrideUserInterfaceStyle = .light
        backgroundColor = .clear
        team.isUserInteractionEnabled = false
        personal.backgroundColor = .clear; personal.isOpaque = false
        personal.isScrollEnabled = false; personal.drawingPolicy = .pencilOnly
        personal.isUserInteractionEnabled = false
        personal.contentSize = CGSize(width: geometry.width, height: geometry.height)
        personal.accessibilityLabel = String(localized: "개인 메모 캔버스")
        personal.isAccessibilityElement = true
        personal.accessibilityIdentifier = "personalInkCanvas"
        personal.accessibilityValue = String(localized: "개인 메모 \(0)획")
        for child in [team, personal, transfer] {
            child.bounds = CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height)
            child.layer.anchorPoint = .zero; child.layer.position = .zero
            addSubview(child)
        }
        team.accessibilityLabel = String(localized: "팀 메모 읽기 전용 예시")
        team.isAccessibilityElement = true; team.accessibilityIdentifier = "teamInkLayer"
        team.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        alignToPDF()
    }

    /// Sample PDFKit's documented conversions in this overlay's coordinate space.
    /// PDFKit already rotates overlays: this affine map compensates, never guesses it.
    func alignToPDF() {
        guard let pdfView, let page, window != nil, bounds.width > 0 else { return }
        func mapped(_ x: Double, _ y: Double) -> CGPoint {
            let p = geometry.pdfPoint(x: x, y: y)
            let viewPoint = pdfView.convert(CGPoint(x: p.x, y: p.y), from: page)
            return convert(viewPoint, from: pdfView)
        }
        let origin = mapped(0, 0), x = mapped(geometry.width, 0), y = mapped(0, geometry.height)
        let transform = CGAffineTransform(a: (x.x - origin.x) / geometry.width,
                                         b: (x.y - origin.y) / geometry.width,
                                         c: (y.x - origin.x) / geometry.height,
                                         d: (y.y - origin.y) / geometry.height,
                                         tx: origin.x, ty: origin.y)
        for child in [team, personal, transfer] { child.transform = transform }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard ready else { return nil }
        if transfer.mode != .inactive { return super.hitTest(point, with: event) }
        let pencil = event?.allTouches?.contains(where: { $0.type == .pencil }) == true
        guard fingerTesting || pencil || event?.allTouches?.isEmpty != false else { return nil } // Fingers pan/zoom the PDF.
        return super.hitTest(point, with: event)
    }

    func restore(_ drawing: PKDrawing, generation: Int64) {
        applyingDrawing = true; personal.drawing = drawing
        personal.undoManager?.removeAllActions()
        self.generation = generation
        lastCapturedArchive = drawing.dataRepresentation()
        applyingDrawing = false; ready = true; personal.isUserInteractionEnabled = true
        updateAccessibility()
    }

    func updateAccessibility() {
        personal.accessibilityValue = String(localized: "개인 메모 \(personal.drawing.strokes.count)획")
    }

    func replaceWithUndo(_ drawing: PKDrawing) {
        let previous = personal.drawing
        let manager = personal.undoManager
        manager?.beginUndoGrouping()
        manager?.registerUndo(withTarget: self) { target in target.replaceWithUndo(previous) }
        personal.undoManager?.setActionName(String(localized: "메모 붙여넣기"))
        applyingDrawing = true
        personal.drawing = drawing
        applyingDrawing = false
        manager?.endUndoGrouping()
        onProgrammaticChange?()
    }
}
