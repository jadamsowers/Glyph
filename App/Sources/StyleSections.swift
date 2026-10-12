import SwiftUI
import VectorEngine

/// What kind of SVG to make.
enum OutputStyle: String, CaseIterable, Identifiable {
    case color = "Color", blackAndWhite = "Black & White", centerline = "Centerline", halftone = "Halftone"
    var id: Self { self }

    init(_ o: Options) {
        if o.halftone != nil { self = .halftone }
        else if o.centerline { self = .centerline }
        else if o.monochrome != nil { self = .blackAndWhite }
        else { self = .color }
    }

    /// Switches style, keeping ink/background settings where they carry over.
    func apply(to o: inout Options) {
        let mono = o.monochrome ?? Monochrome(ink: o.halftone?.ink ?? RGBA(0, 0, 0), background: o.halftone?.background)
        switch self {
        case .color: o.monochrome = nil; o.centerline = false; o.halftone = nil
        case .blackAndWhite: o.monochrome = mono; o.centerline = false; o.halftone = nil
        case .centerline: o.monochrome = mono; o.centerline = true; o.halftone = nil
        case .halftone:
            o.halftone = o.halftone ?? Halftone(ink: mono.ink, background: mono.background)
            o.monochrome = nil; o.centerline = false
        }
    }
}

struct StyleSection: View {
    @Binding var options: Options

    var body: some View {
        Section("Style") {
            Picker("Output", selection: Binding(get: { OutputStyle(options) }, set: { $0.apply(to: &options) })) {
                ForEach(OutputStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
        }
    }
}

/// Threshold, ink and paper for black-and-white and centerline output.
struct MonochromeSection: View {
    @Binding var mono: Monochrome
    @Binding var border: Int

    var body: some View {
        Section("Ink") {
            AutoSlider(title: "Threshold", value: $mono.threshold, auto: 0.5, range: 0...1, step: 0.01, format: "%.2f")
                .help("Brightness below which a pixel is ink. Auto picks the best split for the image.")
            Toggle("Trace light pixels", isOn: $mono.invert)
            ColorPicker("Ink", selection: $mono.ink.color, supportsOpacity: false)
            OptionalColor(title: "Background", color: $mono.background)
            Picker("Diagonal touches", selection: $mono.turnPolicy) {
                Text("Minority").tag(TurnPolicy.minority)
                Text("Connect ink").tag(TurnPolicy.connectInk)
                Text("Separate ink").tag(TurnPolicy.separateInk)
            }
            .help("How ink pixels touching only at a corner are resolved")
            Stepper("Border: \(border) px", value: $border, in: 0...100)
        }
    }
}

struct HalftoneSection: View {
    @Binding var halftone: Halftone

    var body: some View {
        Section("Halftone") {
            Picker("Shape", selection: $halftone.shape) {
                Text("Dots").tag(Halftone.Shape.dot)
                Text("Lines").tag(Halftone.Shape.line)
            }
            .pickerStyle(.segmented)
            LabeledSlider(title: "Cell size", value: $halftone.cellSize, range: 2...40, step: 0.5, format: "%.1f px")
            LabeledSlider(title: "Angle", value: $halftone.angle, range: 0...90, step: 1, format: "%.0f°")
            ColorPicker("Ink", selection: $halftone.ink.color, supportsOpacity: false)
            OptionalColor(title: "Background", color: $halftone.background)
        }
    }
}

/// Background removal before tracing: off, or a method with its settings and what it did.
struct BackgroundSection: View {
    @Binding var removal: BackgroundRemoval?
    var outcome: BackgroundOutcome?

    var body: some View {
        Section("Background") {
            Toggle("Remove background", isOn: Binding(get: { removal != nil }, set: { removal = $0 ? (removal ?? BackgroundRemoval()) : nil }))
            if removal != nil {
                let r = $removal.or(BackgroundRemoval())
                Picker("Method", selection: r.method) {
                    Text("Auto").tag(BackgroundRemoval.Method.auto)
                    Text("Solid colour").tag(BackgroundRemoval.Method.solid)
                    Text("Subject").tag(BackgroundRemoval.Method.subject)
                }
                .help("Solid colour clears the colour around the edge; Subject uses Apple's subject detection (best for photos). Auto picks by image type.")
                if r.wrappedValue.method != .subject {
                    LabeledSlider(title: "Tolerance", value: r.tolerance, range: 0...40, step: 1, format: "%.0f")
                        .help("How different (ΔE) a pixel may be from the background colour and still be removed")
                    Toggle("Remove enclosed areas", isOn: r.removeEnclosed)
                        .help("Also clear background-coloured areas that don't touch the edge, like the inside of an O")
                }
                if let outcome {
                    Text(outcome.summary).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct AdjustSection: View {
    @Binding var adjust: Adjustments
    @Binding var denoise: Int

    var body: some View {
        Section {
            DisclosureGroup("Adjust") {
                LabeledSlider(title: "Brightness", value: $adjust.brightness, range: -1...1, step: 0.01, format: "%+.2f")
                LabeledSlider(title: "Contrast", value: $adjust.contrast, range: 0...3, step: 0.01, format: "%.2f")
                LabeledSlider(title: "Saturation", value: $adjust.saturation, range: 0...3, step: 0.01, format: "%.2f")
                LabeledSlider(title: "Gamma", value: $adjust.gamma, range: 0.2...5, step: 0.01, format: "%.2f")
                Toggle("Invert", isOn: $adjust.invert)
                Stepper("Denoise: \(denoise == 0 ? "off" : "\(denoise) px")", value: $denoise, in: 0...3)
                    .help("Median filter for JPEG and scan noise")
                Button("Reset adjustments") { adjust = Adjustments(); denoise = 0 }
                    .disabled(adjust.isIdentity && denoise == 0)
            }
        }
    }
}

struct OutputTransformSection: View {
    @Binding var options: Options

    var body: some View {
        Section("Orientation & size") {
            HStack {
                Toggle(isOn: $options.flipHorizontal) { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    .toggleStyle(.button).help("Flip horizontally")
                Toggle(isOn: $options.flipVertical) { Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                    .toggleStyle(.button).help("Flip vertically")
                Spacer()
                Button { options.rotation = (options.rotation + 270) % 360 } label: { Image(systemName: "rotate.left") }
                    .help("Rotate counter-clockwise")
                Button { options.rotation = (options.rotation + 90) % 360 } label: { Image(systemName: "rotate.right") }
                    .help("Rotate clockwise")
                Text("\(options.rotation)°").monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
            }
            Picker("Physical size", selection: $options.dpi) {
                Text("Pixels").tag(Double?.none)
                ForEach([72.0, 150, 300, 450, 600], id: \.self) { Text("\(Int($0)) dpi").tag(Double?.some($0)) }
            }
        }
    }
}

/// A plain (non-optional) slider with a value readout; snaps to `step` without tick marks.
struct LabeledSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value }, set: { value = min(range.upperBound, max(range.lowerBound, ($0 / step).rounded() * step)) }),
                   in: range)
        }
    }
}

/// A color that can be switched off (nil = transparent).
struct OptionalColor: View {
    var title: String
    @Binding var color: RGBA?

    var body: some View {
        HStack {
            Toggle(title, isOn: Binding(get: { color != nil }, set: { color = $0 ? (color ?? RGBA(255, 255, 255)) : nil }))
            if color != nil {
                ColorPicker("", selection: $color.or(RGBA(255, 255, 255)).color, supportsOpacity: false)
                    .labelsHidden()
            }
        }
    }
}

extension RGBA {
    /// sRGB SwiftUI color, settable from a color picker.
    var color: Color {
        get { Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }
        set { self = RGBA(newValue) }
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(UInt8((ns.redComponent * 255).rounded()), UInt8((ns.greenComponent * 255).rounded()),
                  UInt8((ns.blueComponent * 255).rounded()))
    }
}

extension Binding {
    /// A binding to an optional's value that reads `fallback` while it is nil (instead of
    /// force-unwrapping), so a view that outlives its value for one update can't crash.
    func or<T>(_ fallback: T) -> Binding<T> where Value == T? {
        Binding<T>(get: { wrappedValue ?? fallback }, set: { wrappedValue = $0 })
    }
}
