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
    enum PolicyChoice: String, ExpressibleByArgument, CaseIterable { case minority, ink, paper }
    enum FlipChoice: String, ExpressibleByArgument, CaseIterable { case none, horizontal, vertical, both }
    enum HalftoneShape: String, ExpressibleByArgument, CaseIterable { case dot, line }

    @Argument(help: "Input image (PNG, JPEG, HEIC, TIFF, …).") var input: String
    @Option(name: .shortAndLong, help: "Output SVG path (default: the input name with .svg).") var output: String?
    @Option(help: "Pipeline: auto, logo or photo.") var mode: ModeChoice = .auto
    @Option(help: "Tracing: auto, shared or stacked.") var trace: TraceChoice = .auto
    @Option(help: "Trace exactly along pixel edges: auto (on for pixel art), on or off.") var pixels: SwitchChoice = .auto
    @Option(help: "Number of colors.") var colors: Int?
    @Option(help: "Detail 0–1 (higher keeps more nodes).") var detail: Double?
    @Option(help: "Smoothness 0–1 (higher rounds more corners).") var smoothness: Double?
    @Option(help: "Merge regions smaller than this many pixels.") var speck: Int?
    @Option(help: "Perceptual simplification 0–1 (merge segments while the visible change stays small).") var simplify: Double?
    @Option(help: "Long side (px) the SVG will be shown at; drops detail invisible at that size.") var displaySize: Int?
    @Option(help: "Longest side used for processing, in pixels.") var maxSize: Int = 2000
    @Option(help: "Upscale images whose long side is below this before tracing (0 = never).") var minSize: Int = 256
    @Option(help: "Write a PNG picture of every pipeline stage into this directory.") var stages: String?
    // Black and white
    @Flag(help: "Black-and-white: trace dark pixels as one ink color on transparent.") var mono = false
    @Option(help: "Black-and-white brightness threshold 0–1 (default: automatic).") var threshold: Double?
    @Flag(help: "Black-and-white: trace light pixels instead of dark ones.") var invertInk = false
    @Option(help: "Ink color, as #rrggbb.") var ink: String?
    @Option(help: "Background fill, as #rrggbb (default: transparent).") var background: String?
    @Option(help: "Diagonal pixel touches: minority, ink (connect) or paper (separate).") var turnPolicy: PolicyChoice = .minority
    @Option(help: "Transparent margin added around the image, in pixels.") var border: Int = 0
    // Adjust
    @Option(help: "Brightness −1…1.") var brightness: Double = 0
    @Option(help: "Contrast 0…3 (1 = unchanged).") var contrast: Double = 1
    @Option(help: "Saturation 0…3 (1 = unchanged).") var saturation: Double = 1
    @Option(help: "Gamma 0.2…5 (1 = unchanged).") var gamma: Double = 1
    @Flag(help: "Invert colors before tracing.") var invert = false
    @Option(help: "Median denoise radius 0–3 (for JPEG and scan noise).") var denoise: Int = 0
    // Output
    @Option(help: "Flip the output: none, horizontal, vertical or both.") var flip: FlipChoice = .none
    @Option(help: "Rotate the output clockwise by 0, 90, 180 or 270 degrees.") var rotate: Int = 0
    @Option(help: "Physical size: pixels per inch (sets width/height in inches).") var dpi: Double?
    @Flag(help: "Line art: trace single stroked centerlines instead of filled outlines (implies --mono).") var centerline = false
    @Option(help: "Vector halftone with this cell size in pixels, instead of tracing.") var halftone: Double?
    @Option(help: "Halftone screen angle in degrees.") var halftoneAngle: Double = 45
    @Option(help: "Halftone shape: dot or line.") var halftoneShape: HalftoneShape = .dot
    @Flag(name: .shortAndLong, help: "Print stage timings, analysis and stats.") var verbose = false

    /// Parses #rrggbb.
    func color(_ hex: String?) throws -> RGBA? {
        guard let hex else { return nil }
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let v = UInt32(digits, radix: 16) else { throw ValidationError("Colors are #rrggbb, got \(hex)") }
        return RGBA(UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff))
    }

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
        options.simplify = simplify
        options.displaySize = displaySize
        let inkColor = try color(ink) ?? RGBA(0, 0, 0), backgroundColor = try color(background)
        if mono {
            let policy: TurnPolicy = switch turnPolicy {
            case .minority: .minority
            case .ink: .connectInk
            case .paper: .separateInk
            }
            options.monochrome = Monochrome(threshold: threshold, invert: invertInk, ink: inkColor, background: backgroundColor, turnPolicy: policy)
        }
        options.centerline = centerline
        if centerline && options.monochrome == nil {
            options.monochrome = Monochrome(threshold: threshold, invert: invertInk, ink: inkColor, background: backgroundColor)
        }
        if let halftone {
            options.halftone = Halftone(cellSize: halftone, angle: halftoneAngle, shape: halftoneShape == .dot ? .dot : .line,
                                        ink: inkColor, background: backgroundColor)
        }
        options.border = border
        options.adjust = Adjustments(brightness: brightness, contrast: contrast, saturation: saturation, gamma: gamma, invert: invert)
        options.denoise = denoise
        options.flipHorizontal = flip == .horizontal || flip == .both
        options.flipVertical = flip == .vertical || flip == .both
        options.rotation = rotate
        options.dpi = dpi
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
            print("paths: \(result.stats.pathCount), segments: \(result.stats.segmentCount), bytes: \(result.stats.byteCount), visible difference: \(result.stats.visibleDifference.isNaN ? "n/a" : String(format: "%.1f%%", result.stats.visibleDifference * 100))")
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
