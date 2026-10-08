import SwiftUI
import VectorEngine

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Group {
                    if model.input == nil {
                        EmptyStateView(isTargeted: isDropTargeted)
                    } else {
                        CanvasView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.input != nil {
                    Divider()
                    StageTimelineView()
                }
            }
            Divider()
            InspectorView()
                .frame(width: 280)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .alert("Couldn't vectorize", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct EmptyStateView: View {
    var isTargeted: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text("Drop an image")
                .font(.title2)
            Text("or press ⌘O to open, ⌘V to paste")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? Color.accentColor.opacity(0.08) : .clear)
    }
}
