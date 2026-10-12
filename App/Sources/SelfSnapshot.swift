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
        var steps: [(String, () -> Void)] = [
            ("fit", { model.zoomToFit() }),
            ("actual", { model.zoomToActualSize() }),
            ("zoom400", { model.setZoom(4); model.pan = CGSize(width: 300, height: 200) }),
        ]
        // With GLYPH_SNAPSHOT_EDIT set: select the longest boundary, drag its middle anchor, then undo.
        if env["GLYPH_SNAPSHOT_EDIT"] != nil {
            steps += [
                ("edit-select", {
                    model.zoomToFit()
                    model.beginEditing()
                    guard let curves = model.editor?.curves else { return }
                    model.selectedChain = curves.indices.max { curves[$0].segments.count < curves[$1].segments.count }
                }),
                ("edit-drag", {
                    guard let c = model.selectedChain, let n = model.editor?.anchors(of: c).count else { return }
                    model.beginDrag(.anchor(chain: c, index: n / 2), breakSmooth: false)
                    model.dragCurves(by: Vec2(60, 40))
                    model.endDrag()
                }),
                ("edit-undo", {
                    let info = "undoManager \(true) canUndo \(model.undoManager.canUndo) hasEdits \(model.hasEdits)"
                    model.undoManager.undo()
                    try? (info + " after \(model.hasEdits)").write(toFile: out + "-edit.txt", atomically: true, encoding: .utf8)
                }),
            ]
        }
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
