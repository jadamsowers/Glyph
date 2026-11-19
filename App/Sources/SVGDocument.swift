import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// A finished SVG, for Save to Files (`fileExporter`) and the share sheet (`ShareLink`).
struct SVGDocument: FileDocument, Transferable {
    static var readableContentTypes: [UTType] { [.svg] }

    var svg: String
    /// File name, with extension, offered when sharing.
    var name: String

    init(svg: String, name: String) {
        self.svg = svg
        self.name = name
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let svg = String(data: data, encoding: .utf8)
        else { throw CocoaError(.fileReadCorruptFile) }
        self.init(svg: svg, name: configuration.file.filename ?? "Glyph.svg")
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(svg.utf8))
    }

    static var transferRepresentation: some TransferRepresentation {
        // A named file, so the share sheet and receiving apps see "<source>.svg".
        FileRepresentation(exportedContentType: .svg) { doc in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(doc.name)
            try Data(doc.svg.utf8).write(to: url)
            return SentTransferredFile(url)
        }
    }
}
