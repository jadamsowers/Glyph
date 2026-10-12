import AppKit
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
        didSet { if options != oldValue { scheduleRun() } }
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
        let old = effectiveZoom, new = max(0.05, min(64, z))
        let k = new / old
        pan = CGSize(width: anchor.x - (anchor.x - pan.width) * k, height: anchor.y - (anchor.y - pan.height) * k)
        zoom = new
    }
    func zoomIn() { setZoom(effectiveZoom * 1.5) }
    func zoomOut() { setZoom(effectiveZoom / 1.5) }
    func zoomToActualSize() { setZoom(1) }
    func zoomToFit() { zoom = nil; pan = .zero }

    private var runTask: Task<Void, Never>?
    private var sourceURL: URL?
    private var pastedImage: CGImage?

    var result: VectorResult? { state?.result }

    /// Flips, rotations and borders change the frame, so a wipe against the original no longer lines up.
    var isReoriented: Bool { options.flipHorizontal || options.flipVertical || options.rotation % 360 != 0 || options.border > 0 }

    // MARK: Loading

    func open(_ url: URL) {
        sourceURL = url
        pastedImage = nil
        zoomToFit()
        reload()
    }

    func paste() {
        guard let image = NSImage(pasteboard: .general),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { errorMessage = "The clipboard doesn't contain an image."; return }
        sourceURL = nil
        pastedImage = cg
        zoomToFit()
        reload()
    }

    /// Re-decodes the source — needed when settings that shape the input change (size limits,
    /// exact pixels).
    func reload() {
        do {
            let cg: CGImage
            if let url = sourceURL {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                cg = try InputImage.orientedImage(contentsOf: url)
                sourceName = url.deletingPathExtension().lastPathComponent
            } else if let pastedImage {
                cg = pastedImage
                sourceName = "Pasted Image"
            } else { return }
            errorMessage = nil
            original = cg
            input = InputImage(cgImage: cg, maxDimension: options.advanced.maxProcessingDimension, minDimension: minDimension)
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

    private var loadedLimits: (Int, Int, Bool?)?

    private func scheduleRun() {
        runTask?.cancel()
        runTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            // Size limits and exact-pixel mode shape the input itself.
            let limits = (options.advanced.maxProcessingDimension, options.advanced.minProcessingDimension, options.exactPixels)
            if let loaded = loadedLimits, loaded != limits { loadedLimits = limits; reload() } else { loadedLimits = limits; run() }
        }
    }

    private var generation = 0

    private func run() {
        guard let input else { return }
        runTask?.cancel()
        loadedLimits = (options.advanced.maxProcessingDimension, options.advanced.minProcessingDimension, options.exactPixels)
        generation += 1
        let gen = generation, previous = state, options = options
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
        if let finished { state = finished; vector = prepared }
        if let error { errorMessage = error.localizedDescription }
    }

    func resetToAuto() {
        options = Options()
    }

    // MARK: Export

    func saveSVG() {
        guard let svg = result?.svg else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.svg]
        panel.nameFieldStringValue = (sourceName.isEmpty ? "Glyph" : sourceName) + ".svg"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try svg.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copySVG() {
        guard let svg = result?.svg else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(svg, forType: .string)
    }
}
