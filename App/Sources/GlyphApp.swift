import SwiftUI
import UniformTypeIdentifiers
import VectorEngine

@main
struct GlyphApp: App {
    @State private var model = AppModel()
    /// Shared with the canvas's backdrop toggle.
    @AppStorage("canvasDarkBackground") private var darkBackground = false

    var body: some Scene {
        Window("Glyph", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { openPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save SVG…") { model.saveSVG() }
                    .keyboardShortcut("s")
                    .disabled(model.result == nil)
            }
            // Undo goes to curve edits when there are any, else to the focused control (text fields).
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    if model.undoManager.canUndo { model.undoManager.undo() } else { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
                }
                .keyboardShortcut("z")
                Button("Redo") {
                    if model.undoManager.canRedo { model.undoManager.redo() } else { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Copy SVG") { model.copySVG() }
                    .keyboardShortcut("c")
                    .disabled(model.result == nil)
                Button("Paste Image") { model.paste() }
                    .keyboardShortcut("v")
            }
            // Zoom follows Preview: ⌘= / ⌘− step, ⌘0 actual size, ⌘9 fit.
            CommandGroup(before: .toolbar) {
                Button("Actual Size") { model.zoomToActualSize() }
                    .keyboardShortcut("0")
                Button("Zoom to Fit") { model.zoomToFit() }
                    .keyboardShortcut("9")
                Button("Zoom In") { model.zoomIn() }
                    .keyboardShortcut("=")
                Button("Zoom Out") { model.zoomOut() }
                    .keyboardShortcut("-")
                Divider()
                Toggle("Dark Canvas Background", isOn: $darkBackground)
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
            }
            CommandMenu("Trace") {
                ForEach(Array(OutputStyle.allCases.enumerated()), id: \.element) { i, style in
                    Toggle(style.rawValue, isOn: Binding(get: { OutputStyle(model.options) == style },
                                                         set: { if $0 { style.apply(to: &model.options) } }))
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                }
                Divider()
                Toggle("Remove Background", isOn: Binding(get: { model.options.removeBackground != nil },
                                                          set: { model.options.removeBackground = $0 ? BackgroundRemoval() : nil }))
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Divider()
                Toggle("Edit Curves", isOn: Binding(get: { model.isEditing }, set: { _ in model.toggleEditing() }))
                    .keyboardShortcut("e")
                    .disabled(!model.isEditing && !model.canEditCurves)
                Button("Revert Curve Edits") { model.revertEdits() }
                    .disabled(!model.hasEdits)
                Divider()
                Button("Reset to Auto") { model.resetToAuto() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.open(url) }
    }
}
