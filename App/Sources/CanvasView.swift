import SwiftUI
import VectorEngine

/// Shows the finished vector, drawn live (crisp at any zoom) by `VectorCanvas`, with a draggable
/// wipe against the original (vector left, original right) unless the output was reoriented.
struct CanvasView: View {
    @Environment(AppModel.self) private var model
    /// Canvas backdrop, independent of the system appearance (persisted per user).
    @AppStorage("canvasDarkBackground") private var darkBackground = false

    var body: some View {
        ZStack {
            VectorCanvas(dark: darkBackground)
            if model.vector == nil { ProgressView("Tracing…") }
        }
        .clipped()
        .overlay(alignment: .topLeading) {
            if comparing { CompareLabel(text: "Vector").padding(14).opacity(model.split > 0.12 ? 1 : 0) }
        }
        .overlay(alignment: .bottomTrailing) { zoomControls.padding(10) }
        .overlay(alignment: .bottomLeading) { editControls.padding(10) }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                if comparing { CompareLabel(text: "Original").opacity(model.split < 0.8 ? 1 : 0) }
                if model.isRunning && model.vector != nil { ProgressView().controlSize(.small) }
                backgroundToggle
            }
            .padding(10)
        }
    }

    private var comparing: Bool { model.vector != nil && model.original != nil && !model.isReoriented && !model.isEditing }

    @ViewBuilder private var editControls: some View {
        if model.isEditing {
            HStack(spacing: 10) {
                Text(model.selectedChain == nil ? "Click a boundary to edit it" : "Drag points and handles · ⌥ breaks smooth handles")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Revert Edits") { model.revertEdits() }
                    .disabled(!model.hasEdits)
                Button("Done") { model.endEditing() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.cancelAction)
                    .help("Finish editing (⌘E or Esc)")
            }
            .padding(6)
            .background(.regularMaterial, in: .rect(cornerRadius: 6))
        } else if model.vector != nil {
            HStack(spacing: 6) {
                Button { model.beginEditing() } label: { Label("Edit Curves", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                    .disabled(!model.canEditCurves)
                    .help(model.state?.isCurveEditable == false ? "Halftone and centerline output can't be edited" : "Edit Curves (⌘E)")
                if model.hasEdits {
                    Divider().frame(height: 16)
                    Text("Edited").font(.callout).foregroundStyle(.secondary)
                    Button("Revert") { model.revertEdits() }
                        .help("Restore the curves as traced")
                }
            }
            .buttonStyle(.borderless)
            .padding(6)
            .background(.regularMaterial, in: .rect(cornerRadius: 6))
        }
    }

    private var backgroundToggle: some View {
        Button { darkBackground.toggle() } label: {
            Image(systemName: darkBackground ? "sun.max" : "moon")
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless)
        .padding(6)
        .background(.regularMaterial, in: .rect(cornerRadius: 6))
        .help((darkBackground ? "Use a light background" : "Use a dark background") + " (⇧⌘D)")
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button { model.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom Out (⌘−)")
            // Click toggles between fitting the window and actual size.
            Button { model.zoom == nil ? model.zoomToActualSize() : model.zoomToFit() } label: {
                Text(model.zoom == nil ? "Fit" : "\(Int((model.effectiveZoom * 100).rounded()))%").monospacedDigit().frame(minWidth: 44)
            }
            .help(model.zoom == nil ? "Actual Size (⌘0)" : "Zoom to Fit (⌘9)")
            Button { model.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom In (⌘=)")
        }
        .buttonStyle(.borderless)
        .padding(6)
        .background(.regularMaterial, in: .rect(cornerRadius: 6))
    }
}


struct CompareLabel: View {
    var text: String
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 3)
            .background(.regularMaterial, in: .capsule)
    }
}


