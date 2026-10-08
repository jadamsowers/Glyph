import SwiftUI
import UniformTypeIdentifiers

@main
struct VectorizerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Vectorizer", id: "main") {
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
            CommandGroup(replacing: .pasteboard) {
                Button("Copy SVG") { model.copySVG() }
                    .keyboardShortcut("c")
                    .disabled(model.result == nil)
                Button("Paste Image") { model.paste() }
                    .keyboardShortcut("v")
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
