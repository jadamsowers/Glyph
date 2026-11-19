#if os(macOS)
import AppKit
#else
import UIKit
#endif
import ImageIO
import UniformTypeIdentifiers
import Observation
import VectorEngine

/// Holds the open image, the current options and the latest result, and re-runs the pipeline
/// (reusing unchanged stages) whenever the options change. Only the finished vector is shown.
@MainActor
@Observable
final class AppModel {
    private(set) var input: InputImage?
    private(set) var sourceName = ""
    /// The source as opened (EXIF-oriented), for the compare view.
    private(set) var original: CGImage?
    private(set) var state: PipelineState?
    private(set) var isRunning = false
    /// The finished vector's paths, built off the main thread and drawn live by the canvas at any
    /// zoom. The previous one stays visible while a re-run is in progress.
    private(set) var vector: ShapeRenderer.Prepared?
    var errorMessage: String?

    var options = Options() {
        didSet { optionsChanged(from: oldValue) }
    }

    // MARK: Zoom

    /// Canvas zoom in screen points per output pixel (1 = actual size); nil = fit the window.
    private(set) var zoom: Double?
    /// The zoom at which the image fits the canvas; kept current by the canvas.
    var fitScale: Double = 1
    var effectiveZoom: Double { zoom ?? fitScale }
    /// Offset of the image's center from the canvas center (points).
    var pan = CGSize.zero
    /// Compare divider position, as a fraction of the canvas width (vector left, original right).
    var split = 0.5

    /// Zooms keeping `anchor` (an offset from the canvas center, in points) fixed on screen.
    func setZoom(_ z: Double, anchor: CGPoint = .zero) {
        // The floor stays below fit, so huge images (48 MP photos on a phone) can still zoom out.
        let old = effectiveZoom, new = max(min(0.05, fitScale * 0.5), min(64, z))
        let k = new / old
        pan = CGSize(width: anchor.x - (anchor.x - pan.width) * k, height: anchor.y - (anchor.y - pan.height) * k)
        zoom = new
    }
    func zoomIn() { setZoom(effectiveZoom * 1.5) }
    func zoomOut() { setZoom(effectiveZoom / 1.5) }
    func zoomToActualSize() { setZoom(1) }
    func zoomToFit() { zoom = nil; pan = .zero }

    private var runTask: Task<Void, Never>?

    /// Where the open image came from, kept so input-shaping settings can re-decode it. Photos and
    /// pastes keep their encoded data rather than a decoded image, to stay light between reloads.
    private enum Source {
        case file(URL)
        case data(Data, name: String)
        case image(CGImage, name: String)
    }
    private var source: Source?

    var result: VectorResult? { state?.result }

    /// Flips, rotations and borders change the frame, so a wipe against the original no longer lines up.
    var isReoriented: Bool { options.flipHorizontal || options.flipVertical || options.rotation % 360 != 0 || options.border > 0 }

    // MARK: Loading

    func open(_ url: URL) { open(.file(url)) }

    /// Opens an encoded image (PNG, JPEG, HEIC, …), e.g. from Photos, the camera or a drop.
    func open(imageData: Data, name: String) { open(.data(imageData, name: name)) }

    /// Opens an already-decoded, upright image (e.g. from the camera).
    func open(image: CGImage, name: String) { open(.image(image, name: name)) }

    private func open(_ newSource: Source) {
        clearEdits()
        source = newSource
        zoomToFit()
        reload()
    }

    func paste() {
        #if os(macOS)
        guard let image = NSImage(pasteboard: .general),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { errorMessage = "The clipboard doesn't contain an image."; return }
        open(.image(cg, name: "Pasted Image"))
        #else
        // Prefer the encoded data (it keeps EXIF orientation); else draw the image upright.
        let pasteboard = UIPasteboard.general
        if let type = pasteboard.types.first(where: { UTType($0)?.conforms(to: .image) == true }),
           let data = pasteboard.data(forPasteboardType: type) {
            open(.data(data, name: "Pasted Image"))
        } else if let image = pasteboard.image, let cg = Self.upright(image) {
            open(.image(cg, name: "Pasted Image"))
        } else {
            errorMessage = "The clipboard doesn't contain an image."
        }
        #endif
    }

    /// Re-decodes the source — needed when settings that shape the input change (size limits,
    /// exact pixels).
    func reload() {
        do {
            let cg: CGImage
            switch source {
            case .file(let url):
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                cg = try InputImage.orientedImage(contentsOf: url)
                sourceName = url.deletingPathExtension().lastPathComponent
            case .data(let data, let name):
                cg = try InputImage.orientedImage(data: data)
                sourceName = name
            case .image(let image, let name):
                cg = image
                sourceName = name
            case nil:
                return
            }
            errorMessage = nil
            #if os(macOS)
            original = cg
            #else
            // Only the compare wipe uses this; tracing below always gets the full decode.
            original = Self.downsampled(cg, maxDimension: 4096)
            #endif
            input = InputImage(cgImage: cg, maxDimension: options.advanced.maxProcessingDimension, minDimension: minDimension,
                               highDetail: options.highDetail && options.exactPixels != true)
            clearEdits()
            state = nil
            vector = nil
            run()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Exact pixel tracing wants the original pixels, never an upscaled blur of them.
    private var minDimension: Int { options.exactPixels == true ? 0 : options.advanced.minProcessingDimension }

    // MARK: Running

    /// The input-shaping settings the current input was decoded with.
    private var loadedLimits: (Int, Int, Bool?, Bool)?
    private var inputLimits: (Int, Int, Bool?, Bool) {
        (options.advanced.maxProcessingDimension, options.advanced.minProcessingDimension, options.exactPixels, options.highDetail)
    }

    private func scheduleRun() {
        runTask?.cancel()
        runTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            // Size limits, exact pixels and high detail shape the input itself.
            let limits = inputLimits
            if let loaded = loadedLimits, loaded != limits { loadedLimits = limits; reload() } else { loadedLimits = limits; run() }
        }
    }

    private var generation = 0

    /// Runs the pipeline on the current input, reusing `previous` (default: the current state).
    private func run(reusing previous: PipelineState? = nil) {
        guard let input else { return }
        runTask?.cancel()
        loadedLimits = inputLimits
        generation += 1
        // Committed curve edits may be ahead of `state` (their SVG run was just canceled).
        var base = previous ?? state
        if let curves = currentCurves, let b = base, b.curves != curves { base = b.replacingCurves(curves) }
        let gen = generation, previous = base, options = options
        isRunning = true
        runTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                var last: PipelineState?
                for try await event in Pipeline.stream(input: input, options: options, reusing: previous) {
                    try Task.checkCancellation()
                    last = event.state
                }
                guard let last, let result = last.result else { return }
                let prepared = ShapeRenderer.Prepared(result.shapes, seamStroke: result.seamStroke)
                try Task.checkCancellation()
                await self?.finish(last, vector: prepared, generation: gen, error: nil)
            } catch is CancellationError {
            } catch {
                await self?.finish(nil, vector: nil, generation: gen, error: error)
            }
        }
    }

    private func finish(_ finished: PipelineState?, vector prepared: ShapeRenderer.Prepared?, generation gen: Int, error: Error?) {
        guard gen == generation else { return }
        isRunning = false
        // A run that re-traced (e.g. one debounced from just before editing began) has new chains:
        // edits indexed by the old ones no longer apply.
        if let finished, let curves = currentCurves, finished.curves != curves { clearEdits() }
        if let finished { state = finished; vector = prepared }
        if let error { errorMessage = error.localizedDescription }
    }

    // MARK: Curve editing

    /// True while the canvas is in curve-editing mode (the inspector is locked meanwhile).
    private(set) var isEditing = false
    /// The curves being edited, with drag state; nil outside edit mode.
    private(set) var editor: CurveEditor?
    /// The chain whose anchors and handles are shown.
    var selectedChain: Int?
    /// The latest curves, edited or not; ahead of `state` while the SVG stage catches up.
    private var currentCurves: [Curve]?
    /// The curves as traced, kept while edits exist so they can be reverted.
    private var tracedCurves: [Curve]?
    private(set) var hasEdits = false
    /// Options waiting for the person to confirm that applying them discards curve edits.
    var pendingOptions: Options?
    /// Curve edits' undo history (the Edit menu sends ⌘Z here first; see `GlyphApp`).
    let undoManager = UndoManager()
    private var activeDrag: CurveEditor.Drag?

    var canEditCurves: Bool { !isRunning && state?.isCurveEditable == true }

    func toggleEditing() { isEditing ? endEditing() : beginEditing() }

    func beginEditing() {
        guard canEditCurves, let curves = currentCurves ?? state?.curves else { return }
        if tracedCurves == nil { tracedCurves = curves }
        currentCurves = curves
        editor = CurveEditor(curves: curves)
        selectedChain = nil
        isEditing = true
    }

    func endEditing() {
        isEditing = false
        editor = nil
        selectedChain = nil
        activeDrag = nil
    }

    func beginDrag(_ target: CurveEditor.Target, breakSmooth: Bool) {
        activeDrag = editor?.beginDrag(target, breakSmooth: breakSmooth)
    }

    /// Moves the dragged point by `delta` (curve coordinates) from where the drag started.
    func dragCurves(by delta: Vec2) {
        guard let drag = activeDrag, editor != nil else { return }
        editor!.update(drag, by: delta)
        showPreview(editor!.curves)
    }

    func endDrag() {
        guard activeDrag != nil, let curves = editor?.curves else { return }
        activeDrag = nil
        commit(curves)
    }

    func revertEdits() {
        guard let traced = tracedCurves, hasEdits else { return }
        commit(traced)
    }

    /// Makes `curves` current: an undoable step that redraws now and re-runs the SVG stage.
    private func commit(_ curves: [Curve]) {
        guard let before = currentCurves ?? state?.curves, curves != before, let state else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.commit(before) }
        }
        undoManager.setActionName("Curve Edit")
        currentCurves = curves
        hasEdits = curves != tracedCurves
        if isEditing { editor = CurveEditor(curves: curves) }
        showPreview(curves)
        run(reusing: state.replacingCurves(curves))
    }

    private func showPreview(_ curves: [Curve]) {
        guard let state, let shapes = state.previewShapes(curves) else { return }
        vector = ShapeRenderer.Prepared(shapes, seamStroke: state.result?.seamStroke ?? 0)
    }

    /// Forgets edits (and their undo steps) without touching the current trace.
    private func clearEdits() {
        endEditing()
        tracedCurves = nil
        currentCurves = nil
        hasEdits = false
        pendingOptions = nil
        undoManager.removeAllActions(withTarget: self)
    }

    /// Settings that re-trace the curves would throw edits away: ask first.
    private var ignoringOptionChange = false
    private func optionsChanged(from old: Options) {
        guard options != old, !ignoringOptionChange else { return }
        if tracedCurves != nil, retraces(with: options) {
            if hasEdits {
                pendingOptions = options
                ignoringOptionChange = true
                options = old
                ignoringOptionChange = false
                return
            }
            clearEdits()
        }
        scheduleRun()
    }

    func discardEditsAndApplyPendingOptions() {
        guard let pending = pendingOptions else { return }
        clearEdits()
        options = pending
    }

    /// Whether running with `o` would recompute the curves (or reload the input).
    private func retraces(with o: Options) -> Bool {
        guard let state, let input else { return true }
        let limits = (o.advanced.maxProcessingDimension, o.advanced.minProcessingDimension, o.exactPixels, o.highDetail)
        if let loaded = loadedLimits, loaded != limits { return true }
        guard let stage = Pipeline.stageToRecompute(after: state, input: input, options: o) else { return false }
        return stage <= .curves
    }

    func resetToAuto() {
        options = Options()
    }

    // MARK: Export

    /// File name for exports: the source's name with an .svg extension.
    var exportName: String { (sourceName.isEmpty ? "Glyph" : sourceName) + ".svg" }

    /// The finished SVG for sharing and Save to Files; nil until a trace is done.
    var svgDocument: SVGDocument? { result.map { SVGDocument(svg: $0.svg, name: exportName) } }

    #if os(macOS)
    func saveSVG() {
        guard let svg = result?.svg else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.svg]
        panel.nameFieldStringValue = exportName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try svg.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    #endif

    func copySVG() {
        guard let svg = result?.svg else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(svg, forType: .string)
        #else
        UIPasteboard.general.string = svg
        #endif
    }

    #if os(iOS)
    /// A copy of `image` no larger than `maxDimension` on its long side (the image itself if it fits).
    private static func downsampled(_ image: CGImage, maxDimension: Int) -> CGImage {
        let long = max(image.width, image.height)
        guard long > maxDimension else { return image }
        let s = Double(maxDimension) / Double(long)
        let w = max(1, Int((Double(image.width) * s).rounded())), h = max(1, Int((Double(image.height) * s).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    /// `image` drawn with its orientation applied.
    nonisolated static func upright(_ image: UIImage) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard   // 8-bit sRGB, not a 16-bit extended-range copy
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }.cgImage
    }
    #endif
}
