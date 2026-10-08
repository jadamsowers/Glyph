import SwiftUI
import VectorEngine

/// Shows the selected stage. On the final SVG stage a draggable divider wipes between the
/// original bitmap (left) and the vector render (right).
struct CanvasView: View {
    @Environment(AppModel.self) private var model
    @State private var zoom: Double = 1
    @State private var split: Double = 0.5
    @GestureState private var pinch: Double = 1
    /// Canvas backdrop, independent of the system appearance (persisted per user).
    @AppStorage("canvasDarkBackground") private var darkBackground = false

    var body: some View {
        GeometryReader { geo in
            let stage = model.displayedStage
            ZStack {
                CheckerboardBackground(dark: darkBackground)
                if let state = model.state, let stage {
                    content(stage: stage, state: state, size: geo.size)
                        .scaleEffect(zoom * pinch)
                        .animation(.easeInOut(duration: 0.35), value: stage)
                } else {
                    ProgressView()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .gesture(MagnifyGesture().updating($pinch) { value, state, _ in state = value.magnification }
                .onEnded { zoom = max(0.25, min(16, zoom * $0.magnification)) })
            .overlay(alignment: .bottomTrailing) { zoomControls.padding(10) }
            .overlay(alignment: .topTrailing) { backgroundToggle.padding(10) }
            .overlay(alignment: .topLeading) {
                if let stage { Text(stage.title).font(.headline).padding(6).background(.regularMaterial, in: .rect(cornerRadius: 6)).padding(10) }
            }
        }
    }

    @ViewBuilder
    private func content(stage: Stage, state: PipelineState, size: CGSize) -> some View {
        let fit = fittedSize(state: state, in: size)
        if stage == .svg, let original = model.original, let vector = model.pictures[.svg] {
            // Vector on the left of the divider, original on the right (labelled), clipped
            // explicitly so the sides can't be confused.
            ZStack(alignment: .leading) {
                Image(decorative: original, scale: 1).resizable().interpolation(.high)
                Image(decorative: vector, scale: 1).resizable().interpolation(.high)
                    .clipShape(LeadingFraction(fraction: split))
                CompareHandle()
                    .offset(x: fit.width * split - 1)
            }
            .frame(width: fit.width, height: fit.height)
            .overlay(alignment: .bottomLeading) { CompareLabel(text: "Vector").padding(8).opacity(split > 0.12 ? 1 : 0) }
            .overlay(alignment: .bottomTrailing) { CompareLabel(text: "Original").padding(8).opacity(split < 0.88 ? 1 : 0) }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { split = max(0, min(1, $0.location.x / fit.width)) })
            .id(stage)
            .transition(.opacity)
        } else if let image = model.pictures[stage] {
            Image(decorative: image, scale: 1).resizable()
                .interpolation(stage <= .segment ? .none : .high)
                .frame(width: fit.width, height: fit.height)
                .id(stage)
                .transition(.opacity)
        }
    }

    private func fittedSize(state: PipelineState, in size: CGSize) -> CGSize {
        let w = Double(state.input.bitmap.width), h = Double(state.input.bitmap.height)
        let s = min((size.width - 40) / w, (size.height - 40) / h)
        return CGSize(width: max(1, w * s), height: max(1, h * s))
    }

    private var backgroundToggle: some View {
        Button { darkBackground.toggle() } label: {
            Image(systemName: darkBackground ? "sun.max" : "moon")
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless)
        .padding(6)
        .background(.regularMaterial, in: .rect(cornerRadius: 6))
        .help(darkBackground ? "Use a light background" : "Use a dark background")
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button { zoom = max(0.25, zoom / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
            Button { zoom = 1 } label: { Text("\(Int(zoom * 100))%").monospacedDigit().frame(minWidth: 44) }
            Button { zoom = min(16, zoom * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
        }
        .buttonStyle(.borderless)
        .padding(6)
        .background(.regularMaterial, in: .rect(cornerRadius: 6))
    }
}

/// The left `fraction` of a rect.
struct LeadingFraction: Shape {
    var fraction: Double
    func path(in rect: CGRect) -> Path { Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width * fraction, height: rect.height)) }
}

struct CompareLabel: View {
    var text: String
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 3)
            .background(.regularMaterial, in: .capsule)
    }
}

/// The wipe divider between vector and original; dragging anywhere on the image moves it.
struct CompareHandle: View {
    var body: some View {
        Rectangle()
            .fill(.white)
            .frame(width: 2)
            .shadow(radius: 2)
            .overlay {
                Image(systemName: "arrow.left.and.right.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white, Color.accentColor)
            }
            .allowsHitTesting(false)
    }
}

/// A checkerboard showing transparency, light or dark regardless of the system appearance.
struct CheckerboardBackground: View {
    var dark: Bool

    var body: some View {
        Canvas { ctx, size in
            let base = dark ? Color(white: 0.13) : Color(white: 0.98)
            let alt = dark ? Color(white: 0.19) : Color(white: 0.88)
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(base))
            let cell: CGFloat = 10
            for y in stride(from: 0, to: size.height, by: cell) {
                for x in stride(from: 0, to: size.width, by: cell) where (Int(x / cell) + Int(y / cell)).isMultiple(of: 2) {
                    ctx.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)), with: .color(alt))
                }
            }
        }
    }
}
