import AppKit
import ImageIO
import UniformTypeIdentifiers
import Observation
import VectorEngine

/// Holds the open image, the current options and the latest pipeline state, and re-runs the
/// pipeline (reusing unchanged stages) whenever the options change.
@MainActor
@Observable
final class AppModel {
    private(set) var input: InputImage?
    private(set) var sourceName = ""
    private(set) var original: CGImage?
    private(set) var state: PipelineState?
    /// Stages finished in the current run, in order; drives the timeline's "lighting up".
    private(set) var completed: [Stage] = []
    private(set) var isRunning = false
    /// A rendered picture per finished stage (rendered off the main thread).
    private(set) var pictures: [Stage: CGImage] = [:]
    var errorMessage: String?

    /// The stage shown on the canvas; nil follows the newest finished stage.
    var selectedStage: Stage?
    private(set) var isReplaying = false

    var options = Options() {
        didSet { if options != oldValue { scheduleRun() } }
    }

    private var runTask: Task<Void, Never>?
    private var replayTask: Task<Void, Never>?

    var displayedStage: Stage? { selectedStage ?? completed.last }
    var result: VectorResult? { state?.result }

    // MARK: Loading

    func open(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let image = try InputImage.load(contentsOf: url, maxDimension: options.advanced.maxProcessingDimension,
                                            minDimension: options.advanced.minProcessingDimension)
            load(image, name: url.deletingPathExtension().lastPathComponent,
                 original: CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func paste() {
        guard let image = NSImage(pasteboard: .general),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { errorMessage = "The clipboard doesn't contain an image."; return }
        load(InputImage(cgImage: cg, maxDimension: options.advanced.maxProcessingDimension,
                        minDimension: options.advanced.minProcessingDimension), name: "Pasted Image", original: cg)
    }

    private func load(_ image: InputImage, name: String, original: CGImage?) {
        errorMessage = nil
        input = image
        sourceName = name
        self.original = original ?? image.bitmap.makeCGImage()
        state = nil
        pictures = [:]
        selectedStage = nil
        run()
    }

    // MARK: Running

    private func scheduleRun() {
        runTask?.cancel()
        runTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.run()
        }
    }

    private var generation = 0

    private func run() {
        guard let input else { return }
        runTask?.cancel()
        generation += 1
        let gen = generation, previous = state, options = options, oldPictures = pictures
        let longSide = Double(max(input.bitmap.width, input.bitmap.height))
        let scale = max(1, min(4, (1600 / longSide).rounded(.down)))
        completed = []
        isRunning = true
        runTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                for try await event in Pipeline.stream(input: input, options: options, reusing: previous) {
                    let picture = event.reused && oldPictures[event.stage] != nil
                        ? oldPictures[event.stage]
                        : StageRenderer.image(for: event.stage, in: event.state, scale: scale)
                    try Task.checkCancellation()
                    await self?.publish(event, picture: picture, generation: gen)
                }
                await self?.finish(generation: gen, error: nil)
            } catch is CancellationError {
            } catch {
                await self?.finish(generation: gen, error: error)
            }
        }
    }

    private func publish(_ event: StageEvent, picture: CGImage?, generation gen: Int) {
        guard gen == generation else { return }
        state = event.state
        pictures[event.stage] = picture
        completed.append(event.stage)
    }

    private func finish(generation gen: Int, error: Error?) {
        guard gen == generation else { return }
        isRunning = false
        if let error { errorMessage = error.localizedDescription }
    }

    func resetToAuto() {
        options = Options()
    }

    // MARK: Replay

    func replay() {
        replayTask?.cancel()
        guard !completed.isEmpty else { return }
        isReplaying = true
        replayTask = Task { [weak self] in
            for stage in Stage.allCases {
                guard let self, !Task.isCancelled else { return }
                self.selectedStage = stage
                try? await Task.sleep(for: .milliseconds(stage == .svg ? 0 : 700))
            }
            self?.selectedStage = nil
            self?.isReplaying = false
        }
    }

    func stopReplay() {
        replayTask?.cancel()
        isReplaying = false
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
