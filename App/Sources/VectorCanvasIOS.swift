#if os(iOS)
import SwiftUI
import UIKit
import VectorEngine

/// The live canvas on iPhone and iPad: draws through `CanvasRenderer`, with touch input:
/// - pinch zooms around the pinch;
/// - a drag that starts on the compare divider moves it; any other drag pans;
/// - double-tap toggles between fitting the view and actual size.
/// Curve editing is Mac-only, so there's no edit input here.
struct VectorCanvas: UIViewRepresentable {
    @Environment(AppModel.self) private var model
    var dark: Bool

    func makeUIView(context: Context) -> CanvasUIView {
        let view = CanvasUIView()
        view.model = model
        return view
    }

    func updateUIView(_ view: CanvasUIView, context: Context) {
        // Reading these here makes SwiftUI call back whenever they change.
        view.vector = model.vector
        view.original = model.isReoriented ? nil : model.original
        view.outputSize = CGSize(width: model.result?.width ?? 1, height: model.result?.height ?? 1)
        view.zoom = model.zoom
        view.pan = model.pan
        view.split = model.split
        view.dark = dark
        view.setNeedsDisplay()
        view.reportFitScale()
    }
}

final class CanvasUIView: UIView, UIGestureRecognizerDelegate {
    weak var model: AppModel?
    var vector: ShapeRenderer.Prepared?
    var original: CGImage?
    var outputSize = CGSize(width: 1, height: 1)
    var zoom: Double?
    var pan = CGSize.zero
    var split = 0.5
    var dark = false

    /// How close (points) to the divider a drag must start to move it.
    private let dividerSlop: CGFloat = 22
    private enum DragMode { case divider, pan(start: CGSize) }
    private var dragMode: DragMode?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .redraw
        isOpaque = true
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched))
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged))
        drag.maximumNumberOfTouches = 2
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        doubleTap.numberOfTapsRequired = 2
        for g in [pinch, drag, doubleTap] as [UIGestureRecognizer] {
            g.delegate = self
            addGestureRecognizer(g)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var renderer: CanvasRenderer {
        CanvasRenderer(bounds: bounds, vector: vector, original: original, outputSize: outputSize, zoom: zoom, pan: pan,
                       split: split, dark: dark, accent: tintColor.cgColor)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportFitScale()
        setNeedsDisplay()
    }

    /// Tells the model the fit zoom (for the zoom readout and steps), outside any view update.
    func reportFitScale() {
        let fit = renderer.fitScale
        DispatchQueue.main.async { [weak self] in
            if let model = self?.model, model.fitScale != fit { model.fitScale = fit }
        }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        renderer.draw(in: ctx)
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        setNeedsDisplay()
    }

    // MARK: Input

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Pinch and a two-finger pan run together; the double tap stands alone.
        !(g is UITapGestureRecognizer || other is UITapGestureRecognizer)
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        guard let model, vector != nil, g.state == .changed else { return }
        let p = g.location(in: self), c = renderer.center
        model.setZoom(model.effectiveZoom * g.scale, anchor: CGPoint(x: p.x - c.x, y: p.y - c.y))
        g.scale = 1
    }

    @objc private func dragged(_ g: UIPanGestureRecognizer) {
        guard let model, vector != nil else { return }
        switch g.state {
        case .began:
            let start = g.location(in: self)
            let onDivider = original != nil && g.numberOfTouches == 1 && abs(start.x - bounds.width * split) <= dividerSlop
            dragMode = onDivider ? .divider : .pan(start: model.pan)
        case .changed:
            switch dragMode {
            case .divider:
                guard bounds.width > 0 else { return }
                model.split = max(0, min(1, g.location(in: self).x / bounds.width))
            case .pan(let start):
                let t = g.translation(in: self)
                model.pan = CGSize(width: start.width + t.x, height: start.height + t.y)
            case nil:
                break
            }
        default:
            dragMode = nil
        }
    }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        guard let model, vector != nil else { return }
        model.zoom == nil ? model.zoomToActualSize() : model.zoomToFit()
    }
}
#endif
