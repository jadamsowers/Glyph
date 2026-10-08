import ArgumentParser
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VectorEngine

@main
struct VectorizeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "vectorize", abstract: "Convert a bitmap image into an SVG.")

    enum ModeChoice: String, ExpressibleByArgument, CaseIterable { case auto, logo, photo }
    enum TraceChoice: String, ExpressibleByArgument, CaseIterable { case auto, shared, stacked }
    enum SwitchChoice: String, ExpressibleByArgument, CaseIterable { case auto, on, off }

    @Argument(help: "Input image (PNG, JPEG, HEIC, TIFF, …).") var input: String
    @Option(name: .shortAndLong, help: "Output SVG path (default: the input name with .svg).") var output: String?
    @Option(help: "Pipeline: auto, logo or photo.") var mode: ModeChoice = .auto
    @Option(help: "Tracing: auto, shared or stacked.") var trace: TraceChoice = .auto
    @Option(help: "Trace exactly along pixel edges: auto (on for pixel art), on or off.") var pixels: SwitchChoice = .auto
    @Option(help: "Number of colors.") var colors: Int?
    @Option(help: "Detail 0–1 (higher keeps more nodes).") var detail: Double?
    @Option(help: "Smoothness 0–1 (higher rounds more corners).") var smoothness: Double?
    @Option(help: "Merge regions smaller than this many pixels.") var speck: Int?
    @Option(help: "Longest side used for processing, in pixels.") var maxSize: Int = 2000
    @Option(help: "Upscale images whose long side is below this before tracing (0 = never).") var minSize: Int = 256
    @Option(help: "Write a PNG picture of every pipeline stage into this directory.") var stages: String?
    @Flag(name: .shortAndLong, help: "Print stage timings, analysis and stats.") var verbose = false

    func run() throws {
        let inURL = URL(fileURLWithPath: input)
        let outURL = output.map { URL(fileURLWithPath: $0) } ?? inURL.deletingPathExtension().appendingPathExtension("svg")

        var options = Options(kind: ImageKind(rawValue: mode.rawValue), colorCount: colors, detail: detail,
                              smoothness: smoothness, speckSize: speck)
        options.tracing = switch trace {
        case .auto: nil
        case .shared: .sharedEdges
        case .stacked: .stacked
        }
        options.exactPixels = switch pixels {
        case .auto: nil
        case .on: true
        case .off: false
        }
        options.advanced.maxProcessingDimension = maxSize
        options.advanced.minProcessingDimension = minSize

        // Exact pixel tracing wants the original pixels, never an upscaled blur of them.
        let image = try InputImage.load(contentsOf: inURL, maxDimension: maxSize, minDimension: pixels == .on ? 0 : minSize)
        let state = try Pipeline.run(input: image, options: options) { event in
            guard verbose else { return }
            let c = event.duration.components
            let ms = Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
            let line = event.stage.title.padding(toLength: 10, withPad: " ", startingAt: 0) + String(format: "%8.1f ms\n", ms)
            FileHandle.standardError.write(Data(line.utf8))
        }
        guard let result = state.result else { throw ExitCode.failure }
        try result.svg.write(to: outURL, atomically: true, encoding: .utf8)

        if let stages {
            let dir = URL(fileURLWithPath: stages)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let longSide = Double(max(image.bitmap.width, image.bitmap.height))
            let scale = max(1, min(8, (1024 / longSide).rounded(.down)))
            for stage in Stage.allCases {
                guard let picture = StageRenderer.image(for: stage, in: state, scale: scale) else { continue }
                let name = String(format: "%02d", stage.rawValue) + "-" + stage.slug + ".png"
                try writePNG(picture, to: dir.appendingPathComponent(name))
            }
        }

        if verbose, let a = state.analysis, let r = state.resolved {
            print("kind: \(r.kind.rawValue) (detected \(a.kind.rawValue): \(a.significantColors) colors, gradient \(String(format: "%.2f", a.gradientFraction)))")
            print("tracing: \(r.output.tracing.rawValue), palette: \(state.quantized?.palette.count ?? 0) colors, processed at \(image.bitmap.width)×\(image.bitmap.height)")
            print("paths: \(result.stats.pathCount), segments: \(result.stats.segmentCount), bytes: \(result.stats.byteCount)")
        }
        print(outURL.path)
    }

    func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
    }
}
