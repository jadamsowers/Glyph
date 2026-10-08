import SwiftUI
import VectorEngine

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                if let analysis = model.state?.analysis {
                    HStack {
                        Label(analysis.kind == .logo ? "Logo" : "Photo",
                              systemImage: analysis.kind == .logo ? "seal" : "photo")
                            .font(.headline)
                        Spacer()
                        Text("\(analysis.significantColors) colors").foregroundStyle(.secondary)
                    }
                    PaletteStrip(colors: model.state?.quantized?.palette ?? analysis.palette)
                } else {
                    Text("No image").foregroundStyle(.secondary)
                }
            } header: { Text("Detected") }

            Section("Pipeline") {
                Picker("Image type", selection: $model.options.kind) {
                    Text("Auto").tag(ImageKind?.none)
                    Text("Logo").tag(ImageKind?.some(.logo))
                    Text("Photo").tag(ImageKind?.some(.photo))
                }
                Picker("Tracing", selection: $model.options.tracing) {
                    Text("Auto").tag(TracingMode?.none)
                    Text("Shared edges").tag(TracingMode?.some(.sharedEdges))
                    Text("Stacked").tag(TracingMode?.some(.stacked))
                }
            }

            Section("Shape") {
                AutoSlider(title: "Colors", value: $model.options.colorCount.asDouble,
                           auto: Double(model.state?.resolved?.quantize.colorCount ?? 8), range: 2...64, step: 1, format: "%.0f")
                AutoSlider(title: "Detail", value: $model.options.detail,
                           auto: autoDetail, range: 0...1, step: 0.05, format: "%.2f")
                AutoSlider(title: "Smoothness", value: $model.options.smoothness,
                           auto: autoSmoothness, range: 0...1, step: 0.05, format: "%.2f")
                AutoSlider(title: "Speck size", value: $model.options.speckSize.asDouble,
                           auto: Double(model.state?.resolved?.segment.speckSize ?? 4), range: 0...200, step: 1, format: "%.0f px")
            }

            Section {
                DisclosureGroup("Advanced") {
                    AdvancedOptionsView(advanced: $model.options.advanced, resolved: model.state?.resolved)
                }
                Button("Reset to Auto") { model.resetToAuto() }
                    .disabled(model.options == Options())
            }

            if let result = model.result {
                Section("Output") {
                    LabeledContent("Paths", value: "\(result.stats.pathCount)")
                    LabeledContent("Segments", value: "\(result.stats.segmentCount)")
                    LabeledContent("SVG size", value: ByteCountFormatter.string(fromByteCount: Int64(result.stats.byteCount), countStyle: .file))
                    HStack {
                        Button("Save SVG…") { model.saveSVG() }
                        Button("Copy") { model.copySVG() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .overlay(alignment: .top) {
            if model.isRunning { ProgressView().progressViewStyle(.linear).padding(.horizontal) }
        }
    }

    // The UI's detail/smoothness defaults mirror Options.resolved's per-kind defaults.
    private var isLogo: Bool { (model.state?.resolved?.kind ?? .logo) == .logo }
    private var autoDetail: Double { isLogo ? 0.6 : 0.3 }
    private var autoSmoothness: Double { isLogo ? 0.5 : 0.6 }
}

/// A slider bound to an optional value: nil means "auto" (shows the auto value, dimmed).
struct AutoSlider: View {
    var title: String
    @Binding var value: Double?
    var auto: Double
    var range: ClosedRange<Double>
    var step: Double
    var format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                if value != nil {
                    Button("Auto") { value = nil }.buttonStyle(.link).font(.caption)
                }
                Text(String(format: format, value ?? auto))
                    .monospacedDigit()
                    .foregroundStyle(value == nil ? .secondary : .primary)
            }
            Slider(value: Binding(get: { value ?? auto }, set: { value = $0 }), in: range, step: step)
                .opacity(value == nil ? 0.6 : 1)
        }
    }
}

struct PaletteStrip: View {
    var colors: [RGBA]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(colors.prefix(32).enumerated()), id: \.offset) { _, c in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(.sRGB, red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255))
                    .frame(height: 16)
            }
        }
    }
}

struct AdvancedOptionsView: View {
    @Binding var advanced: AdvancedOptions
    var resolved: ResolvedOptions?

    var body: some View {
        Group {
            Stepper("Max size (next open): \(advanced.maxProcessingDimension) px", value: $advanced.maxProcessingDimension, in: 256...8000, step: 256)
            Stepper("Logo max colors: \(advanced.logoMaxColors)", value: $advanced.logoMaxColors, in: 2...128)
            row("Logo max gradient", $advanced.logoMaxGradientFraction, 0...1)
            row("Logo max edge share", $advanced.logoMaxEdgeFraction, 0...1)
            row("Color merge distance", $advanced.colorMergeDistance, 1...40)
            row("Min color share", $advanced.minColorShare, 0...0.05)
            row("Blend slack", $advanced.blendSlack, 0...0.5)
            row("Blend keep share", $advanced.blendKeepShare, 0...0.2)
            Picker("Pre-filter", selection: $advanced.prefilter) {
                Text("Auto").tag(Bool?.none)
                Text("On").tag(Bool?.some(true))
                Text("Off").tag(Bool?.some(false))
            }
            Stepper("Pre-filter radius: \(advanced.prefilterRadius)", value: $advanced.prefilterRadius, in: 1...6)
            row("Pre-filter color σ", $advanced.prefilterSigmaColor, 4...80)
            Stepper("k-means iterations: \(advanced.kmeansIterations)", value: $advanced.kmeansIterations, in: 1...50)
            optionalRow("Polygon tolerance", $advanced.polygonTolerance, resolved?.polygon.tolerance, 0.1...4)
            optionalRow("Corner angle", $advanced.cornerAngle, resolved?.polygon.cornerAngle, 10...170)
            Stepper("Corner run length: \(advanced.cornerRunLength)", value: $advanced.cornerRunLength, in: 1...8)
            row("Straight tolerance", $advanced.straightTolerance, 0.1...3)
            optionalRow("Curve tolerance", $advanced.curveTolerance, resolved?.curve.tolerance, 0.1...4)
            Stepper("Precision: \(advanced.precision) decimals", value: $advanced.precision, in: 0...4)
        }
        .font(.callout)
    }

    private func row(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        AutoSlider(title: title, value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0 ?? value.wrappedValue }),
                   auto: value.wrappedValue, range: range, step: (range.upperBound - range.lowerBound) / 100, format: "%.3g")
    }

    private func optionalRow(_ title: String, _ value: Binding<Double?>, _ auto: Double?, _ range: ClosedRange<Double>) -> some View {
        AutoSlider(title: title, value: value, auto: auto ?? range.lowerBound,
                   range: range, step: (range.upperBound - range.lowerBound) / 100, format: "%.3g")
    }
}

extension Optional where Wrapped == Int {
    /// Bridges an optional Int option to an optional Double slider value.
    var asDouble: Double? {
        get { self.map(Double.init) }
        set { self = newValue.map { Int($0.rounded()) } }
    }
}
