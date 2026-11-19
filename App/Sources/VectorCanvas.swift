import AppKit
import SwiftUI
import VectorEngine

/// The live canvas: draws the vector's paths directly (crisp at any zoom), with a wipe against the
/// original, a checkerboard backdrop, and pan/zoom input:
/// - two-finger scroll pans; ⌘-scroll and pinch zoom around the pointer;
/// - dragging moves the compare divider, or pans while Space is held;
/// - in curve-editing mode the wipe is off: clicking a boundary selects it, and dragging its
///   anchors and handles edits it (⌥ breaks a smooth anchor's handles apart).
struct VectorCanvas: NSViewRepresentable {
    @Environment(AppModel.self) private var model
    var dark: Bool

    func makeNSView(context: Context) -> CanvasNSView {
        let view = CanvasNSView()
        view.model = model
        return view
    }

    func updateNSView(_ view: CanvasNSView, context: Context) {
        // Reading these here makes SwiftUI call back whenever they change.
        view.vector = model.vector
        view.original = model.isReoriented ? nil : model.original
        view.outputSize = CGSize(width: model.result?.width ?? 1, height: model.result?.height ?? 1)
        view.zoom = model.zoom
        view.pan = model.pan
        view.split = model.split
        view.dark = dark
        view.editor = model.isEditing ? model.editor : nil
        view.selectedChain = model.selectedChain
        view.curveTransform = model.state?.outputTransform ?? .identity
        view.window?.invalidateCursorRects(for: view)
        view.needsDisplay = true
        view.reportFitScale()
    }

    static func dismantleNSView(_ view: CanvasNSView, coordinator: ()) { view.stopMonitoring() }
}

final class CanvasNSView: NSView {
    weak var model: AppModel?
    var vector: ShapeRenderer.Prepared?
    var original: CGImage?
    var outputSize = CGSize(width: 1, height: 1)
    var zoom: Double?
    var pan = CGSize.zero
    var split = 0.5
    var dark = false
    /// Set while editing curves.
    var editor: CurveEditor?
    var selectedChain: Int?
    /// Curve coordinates → output units.
    var curveTransform = CGAffineTransform.identity

    private var hoveredChain: Int? { didSet { if hoveredChain != oldValue { needsDisplay = true } } }
    /// The view point and target where a curve drag started.
    private var curveDrag: (start: CGPoint, target: CurveEditor.Target)?
    private var editing: Bool { editor != nil }

    private var spaceHeld = false { didSet { window?.invalidateCursorRects(for: self) } }
    private var panning: (start: CGPoint, pan: CGSize)?
    private var keyMonitor: Any?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Geometry and drawing

    /// The shared drawing for the current state (see `CanvasRenderer`).
    private var renderer: CanvasRenderer {
        CanvasRenderer(bounds: bounds, vector: vector, original: original, outputSize: outputSize, zoom: zoom, pan: pan,
                       split: split, dark: dark, accent: NSColor.controlAccentColor.cgColor, editor: editor,
                       selectedChain: selectedChain, hoveredChain: hoveredChain, curveTransform: curveTransform)
    }
    var fitScale: Double { renderer.fitScale }
    private var center: CGPoint { renderer.center }
    /// Curve coordinates → view.
    private var viewTransform: CGAffineTransform { renderer.viewTransform }

    override func layout() {
        super.layout()
        reportFitScale()
    }

    /// Tells the model the fit zoom (for the zoom readout and steps), outside any view update.
    func reportFitScale() {
        let fit = fitScale
        DispatchQueue.main.async { [weak self] in
            if let model = self?.model, model.fitScale != fit { model.fitScale = fit }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        renderer.draw(in: ctx)
    }

    // MARK: Cursor

    override func resetCursorRects() {
        if spaceHeld || panning != nil {
            addCursorRect(bounds, cursor: panning != nil ? .closedHand : .openHand)
        } else if editing {
            addCursorRect(bounds, cursor: .arrow)
        } else if original != nil {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }
    }

    // MARK: Input

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        // Space pans while held. Watched app-wide (the canvas rarely has focus) but only swallowed
        // when the pointer is over the canvas and no text field is being edited.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, event.keyCode == 49, event.window === self.window,
                  !(self.window?.firstResponder is NSText) else { return event }
            let pointer = self.convert(event.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
            if event.type == .keyUp { self.spaceHeld = false; return self.bounds.contains(pointer) ? nil : event }
            guard self.bounds.contains(pointer) else { return event }
            self.spaceHeld = true
            return nil
        }
    }

    func stopMonitoring() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if spaceHeld {
            panning = (p, pan)
            window?.invalidateCursorRects(for: self)
        } else if let editor, let model {
            // Grab a point of the selected boundary, else select the boundary under the pointer.
            if let chain = selectedChain, let target = editor.target(near: p, in: chain, tolerance: 6, transform: viewTransform) {
                curveDrag = (p, target)
                model.beginDrag(target, breakSmooth: event.modifierFlags.contains(.option))
            } else {
                model.selectedChain = editor.chain(near: p, tolerance: 5, transform: viewTransform)
            }
        } else {
            moveDivider(to: p)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let editor, !spaceHeld else { hoveredChain = nil; return }
        hoveredChain = editor.chain(near: convert(event.locationInWindow, from: nil), tolerance: 5, transform: viewTransform)
    }

    override func mouseExited(with event: NSEvent) { hoveredChain = nil }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let panning {
            model?.pan = CGSize(width: panning.pan.width + p.x - panning.start.x, height: panning.pan.height + p.y - panning.start.y)
        } else if let curveDrag {
            // A view-space offset in curve coordinates: the inverse transform without translation.
            var inverse = viewTransform.inverted()
            inverse.tx = 0; inverse.ty = 0
            let d = CGPoint(x: p.x - curveDrag.start.x, y: p.y - curveDrag.start.y).applying(inverse)
            model?.dragCurves(by: Vec2(d.x, d.y))
        } else if !spaceHeld && !editing {
            moveDivider(to: p)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if curveDrag != nil { curveDrag = nil; model?.endDrag() }
        panning = nil
        window?.invalidateCursorRects(for: self)
    }

    private func moveDivider(to p: CGPoint) {
        guard original != nil, bounds.width > 0 else { return }
        model?.split = max(0, min(1, p.x / bounds.width))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let model, vector != nil else { return }
        if event.modifierFlags.contains(.command) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
            zoom(by: exp(delta * 0.01), at: convert(event.locationInWindow, from: nil))
        } else {
            let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            model.pan = CGSize(width: model.pan.width + event.scrollingDeltaX * k, height: model.pan.height + event.scrollingDeltaY * k)
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil))
    }

    private func zoom(by factor: Double, at p: CGPoint) {
        guard let model else { return }
        model.setZoom(model.effectiveZoom * factor, anchor: CGPoint(x: p.x - center.x, y: p.y - center.y))
    }
}
