import AppKit
import VectorEngine

/// Development aid: with GLYPH_SNAPSHOT_IMAGE and GLYPH_SNAPSHOT_OUT set, opens the image, waits for
/// the trace, and writes PNGs of the window at fit, actual size and 400% (panned off-center), so
/// the canvas can be checked without screen recording. Does nothing otherwise.
enum SelfSnapshot {
    @MainActor
    static func runIfRequested(_ model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        guard let image = env["GLYPH_SNAPSHOT_IMAGE"], let out = env["GLYPH_SNAPSHOT_OUT"] else { return }
        model.open(URL(fileURLWithPath: image))
        while model.vector == nil || model.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        let steps: [(String, () -> Void)] = [
            ("fit", { model.zoomToFit() }),
            ("actual", { model.zoomToActualSize() }),
            ("zoom400", { model.setZoom(4); model.pan = CGSize(width: 300, height: 200) }),
        ]
        for (name, step) in steps {
            step()
            try? await Task.sleep(for: .milliseconds(400))
            guard let view = NSApp.windows.first(where: \.isVisible)?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)-\(name).png"))
        }
        NSApp.terminate(nil)
    }
}
