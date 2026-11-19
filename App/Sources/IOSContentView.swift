#if os(iOS)
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import VectorEngine

/// iPhone and iPad layout: the canvas full-screen with a toolbar, and the inspector as a trailing
/// column on iPad (open by default) or a half-height sheet on iPhone.
struct IOSContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showInspector = false
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var showFileExporter = false

    var body: some View {
        NavigationStack {
            Group {
                if model.input == nil {
                    IOSEmptyStateView(choosePhoto: { showPhotoPicker = true }, takePhoto: { showCamera = true },
                                      chooseFile: { showFileImporter = true }, paste: { model.paste() })
                } else {
                    CanvasView()
                }
            }
            .navigationTitle(model.input == nil ? "Glyph" : model.sourceName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .inspector(isPresented: $showInspector) {
                InspectorView()
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { return }
                    model.open(imageData: data, name: "Photo")
                } catch {
                    model.errorMessage = error.localizedDescription
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                showCamera = false
                if let image { model.open(image: image, name: "Photo") }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url): model.open(url)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $showFileExporter, document: model.svgDocument, contentType: .svg,
                      defaultFilename: model.exportName) { result in
            if case .failure(let error) = result { model.errorMessage = error.localizedDescription }
        }
        .dropDestination(for: Data.self) { items, _ in
            guard let data = items.first else { return false }
            model.open(imageData: data, name: "Dropped Image")
            return true
        }
        .onAppear { showInspector = sizeClass == .regular || SelfSnapshot.showsInspector }
        .task { await SelfSnapshot.runIfRequested(model) }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button { showPhotoPicker = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                if CameraPicker.isAvailable {
                    Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") }
                }
                Button { showFileImporter = true } label: { Label("Choose File", systemImage: "folder") }
                Button { model.paste() } label: { Label("Paste Image", systemImage: "doc.on.clipboard") }
            } label: {
                Label("Open", systemImage: "plus")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if model.input != nil {
                @Bindable var model = model
                Menu {
                    Picker("Style", selection: Binding(get: { OutputStyle(model.options) },
                                                       set: { $0.apply(to: &model.options) })) {
                        ForEach(OutputStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Label("Style", systemImage: "paintpalette")
                }
                Menu {
                    if let doc = model.svgDocument {
                        ShareLink(item: doc, preview: SharePreview(doc.name)) { Label("Share…", systemImage: "square.and.arrow.up") }
                    }
                    Button { showFileExporter = true } label: { Label("Save to Files…", systemImage: "folder") }
                    Button { model.copySVG() } label: { Label("Copy SVG", systemImage: "doc.on.doc") }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(model.svgDocument == nil)
                Button { showInspector.toggle() } label: {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
            }
        }
    }
}

struct IOSEmptyStateView: View {
    var choosePhoto: () -> Void
    var takePhoto: () -> Void
    var chooseFile: () -> Void
    var paste: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("Choose an image to trace")
                .font(.title2)
            VStack(spacing: 10) {
                Button(action: choosePhoto) { Label("Choose Photo", systemImage: "photo.on.rectangle").frame(maxWidth: 240) }
                    .buttonStyle(.borderedProminent)
                if CameraPicker.isAvailable {
                    Button(action: takePhoto) { Label("Take Photo", systemImage: "camera").frame(maxWidth: 240) }
                        .buttonStyle(.bordered)
                }
                Button(action: chooseFile) { Label("Choose File", systemImage: "folder").frame(maxWidth: 240) }
                    .buttonStyle(.bordered)
                Button(action: paste) { Label("Paste Image", systemImage: "doc.on.clipboard").frame(maxWidth: 240) }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
