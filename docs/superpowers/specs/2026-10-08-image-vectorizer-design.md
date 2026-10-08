# Image Vectorizer — Design Spec

Date: 2026-10-08
Status: Draft for review

## 1. Purpose

A native macOS app (plus a CLI sharing the same engine) that converts a bitmap image into an SVG.
Primary use: logos, icons, flat illustrations. Secondary: photos (stylized/posterized output).

Success criteria:
- Output is visually faithful to the source (re-rasterized SVG closely matches the quantized bitmap).
- SVG stays simple: few paths, few nodes, compact path data. No hairline gaps between shapes.
- Every refinement stage of the algorithm is viewable in the app as a visual detail, and animatable.
- Personal use now; App-Store-friendly later (sandbox-safe, no external binaries, no GPL code).

## 2. Scope

In scope:
- Swift package `VectorEngine` (library), `vectorize` CLI executable, SwiftUI macOS app.
- Automatic image classification (logo vs photo) choosing pipeline + default parameters, user-overridable.
- Two tracing modes: **Shared edges** (planar map) and **Stacked** (overlapping layers), auto-chosen, user-switchable.
- Stage viewer with replay animation.

Out of scope (YAGNI): gradients in SVG output, batch processing in the app, editing paths in-app,
App Store submission itself, iOS.

## 3. Engine pipeline

Each stage returns an immutable value retained for display.

| # | Stage | Logo pipeline | Photo pipeline | Visualization |
|---|---|---|---|---|
| 0 | Analyze | Count distinct colors (after ignoring low-frequency anti-alias colors), edge sharpness, gradient fraction → `ImageKind` + default `Options` | same | Color histogram + verdict |
| 1 | Pre-filter | None (optional light median denoise) | Edge-preserving bilateral smoothing | Filtered bitmap |
| 2 | Quantize | Dominant-color palette clustering in CIELAB; anti-aliased pixels snapped to nearest palette color | k-means (k-means++ init) in CIELAB, k = color count | Posterized bitmap + swatches |
| 3 | Segment | Connected-component labeling (4-connectivity); regions smaller than `speckSize` px merged into most similar adjacent region (by Lab distance), iterated | same | Regions in random false colors |
| 4 | Contours | Pixel-edge boundaries. Shared mode: planar edge graph (each boundary between two regions — or region and image border — is one chain between junction vertices). Stacked mode: one outer loop (+ holes) per region | same | Staircase outlines |
| 5 | Polygon | Per chain: dense points = midpoint of every straight staircase run, plus turn vertices between two runs ≥ `cornerRunLength` (true corners); Douglas–Peucker with `polygonTolerance` (endpoints pinned); short anti-aliasing bevels (< 8 px between much longer edges) are rebuilt into sharp corners; a vertex is a corner if its turn ≥ `cornerAngle` and at least one adjacent edge is straight (bulge ≤ max(`straightTolerance`, 5% of its length)), or its turn ≥ 150° | same, looser tolerance | Polygons with vertex dots (corners vs smooth) |
| 6 | Curves | Between consecutive corners: a straight line if the dense points stay within `straightTolerance`, otherwise least-squares cubic Bézier fitting (Schneider) to the dense points within `curveTolerance`. Corner-free closed loops are split at two smooth joins with continuous tangents | same | Curves with control handles |
| 7 | SVG | Shared mode: one `<path>` per color (same-colored regions merged; outlines assembled from shared edge chains, reversing as needed; holes via `fill-rule="evenodd"`). Relative commands, coordinates rounded to `precision` decimals. Stacked mode: one `<path>` per region, outer boundary only, sorted by outer-boundary area descending (see notes) | same | Final render + byte/path/node counts |

Notes:
- All tracing is implemented in original Swift code; no third-party tracing code (no potrace/GPL).
- Stacked mode avoids seams by emitting each region as its outer boundary only — holes are not cut out, because the regions occupying them are smaller and therefore painted later on top. Shapes are emitted by outer-boundary area, largest first — not by pixel count: a thin ring around a large disk has fewer pixels than the disk but must be painted before it. (A hole containing a region that is *larger* than the enclosing one cannot occur, since the enclosing region's outer boundary area exceeds it.)
- Large images: downscaled to `maxProcessingDimension` (default 2000 px long side) for processing; SVG `viewBox` uses original dimensions via scaling of output coordinates.
- Transparency: fully transparent pixels form a "background" label that is never emitted; alpha < threshold treated as transparent.

### Classification heuristic (stage 0)
Computed on a nearest-neighbor sample (long side ≤ 256 px):
- `significantColors`: 5-bit-per-channel buckets merged greedily into clusters (Lab distance < 10); clusters with ≥ 0.1% of opaque pixels count, except small ones (< 3%) that look like a mix of two already-chosen colors — RGB path a→c→b at most 1.15× the direct distance — which catches anti-aliasing and JPEG chroma fringes.
- `gradientFraction`: share of pixels whose 3×3 box-averaged color differs from the one 3 px right/below by 2.5–40 (max channel) — above compression noise, below hard edges.
- Logo if `significantColors ≤ 32` and `gradientFraction < 0.25`; else Photo. Thresholds live in AdvancedOptions.
- Default color count = significant colors (logo, clamped 2…32) or 16 (photo).

## 4. API

```swift
public struct Options {
    // Common
    var kind: ImageKind?            // nil = auto
    var tracing: TracingMode?       // nil = auto (logo→.sharedEdges, photo→.stacked)
    var colorCount: Int?            // nil = auto
    var detail: Double              // 0…1, maps to polygon tolerance
    var smoothness: Double          // 0…1, maps to alpha / corner threshold
    var speckSize: Int              // px
    // Advanced
    var advanced: AdvancedOptions   // all thresholds: tolerances, alphamax, curve tolerance,
                                    // precision, max dimension, classifier thresholds, prefilter strength...
}

public enum Stage: Int, CaseIterable { case analyze, prefilter, quantize, segment, contours, polygon, curves, svg }

public struct StageResult { let stage: Stage; let payload: StagePayload; let duration: Duration }

public final class Vectorizer {
    func run(_ image: CGImage, options: Options, from: Stage = .analyze,
             reusing: PipelineCache?) -> AsyncThrowingStream<StageResult, Error>
    func vectorize(_ image: CGImage, options: Options) throws -> VectorResult  // sync, for CLI
}
```

- `PipelineCache` holds prior stage outputs so the app can re-run from the earliest stage affected by a changed option (e.g., smoothness change → restart at `.curves`).
- Cancellation via Swift task cancellation; stages check `Task.isCancelled` between steps.
- `VectorResult`: final path model (`[VectorShape]` with color + `[Subpath]` of lines/cubics), SVG string, stats.
- `StagePayload` provides a `CGImage` rendering for every stage (used by app thumbnails and CLI `--stages`).

## 5. macOS App (SwiftUI)

- Single window. Empty state: drop target; also ⌘O, paste, drag-in. Formats: anything ImageIO decodes.
- Center canvas: zoom/pan; compare slider wiping original ↔ SVG render.
- Bottom stage timeline: 8 thumbnails; click to show that stage on canvas; ▶ Replay animates through stages with crossfades; during processing stages light up as streamed.
- Right inspector:
  - Detected badge ("Logo · 6 colors") + Logo/Photo picker (Auto / Logo / Photo).
  - Tracing mode picker (Auto / Shared edges / Stacked).
  - Sliders: Colors, Detail, Smoothness, Speck size.
  - ▸ Advanced disclosure group: all `AdvancedOptions`, plus "Reset to auto".
  - Stats: paths, nodes, SVG size.
- Debounced (~250 ms) live re-run on changes, from earliest affected stage; prior run cancelled.
- Export: ⌘S Save SVG…, ⌘C copy SVG markup. Preview renders the engine path model via Core Graphics (no WebView).
- Sandbox entitlements: user-selected read/write only.

## 6. CLI

```
vectorize <input> -o <out.svg> [--mode auto|logo|photo] [--trace auto|shared|stacked]
          [--colors N] [--detail 0-1] [--smoothness 0-1] [--speck N]
          [--stages <dir>] [--verbose]
```
- Built with swift-argument-parser (Apache-2.0).
- `--stages` writes `00-analyze.png` … `07-svg.png`.
- `--verbose` prints classification and stats. Non-zero exit with message on unreadable input.

## 7. Project structure

```
Package.swift                 // VectorEngine (library), vectorize (executable), VectorEngineTests
Sources/VectorEngine/         // Analysis, Quantize, Segment, Contours, Polygon, Curves, SVG, Rendering, Pipeline
Sources/vectorize/
Tests/VectorEngineTests/
App/                          // Xcode project for the SwiftUI app, depends on local package
docs/
```
The app's Xcode project is generated by XcodeGen from a checked-in `App/project.yml` (requires `brew install xcodegen`; the generated `.xcodeproj` is also committed so the project opens without it).

## 8. Testing

- Unit tests per stage with synthetic images: two-color circle (2 regions, 1 shared edge chain), checkerboard (junction handling), nested rings (holes), transparent background, gradient (classified photo), flat logo (classified logo).
- Gap-free property: rasterize resulting path model; every pixel's color matches the quantized label map except within ~1 px of boundaries; no uncovered pixels in shared mode.
- Simplicity: node count for a circle stays below a small bound (e.g., ≤ 8 Béziers).
- SVG well-formedness: parse with `XMLParser`.
- CLI smoke test on a sample image.

Tests use swift-testing and require full Xcode (Command Line Tools alone cannot run them).

## 9. Error handling

- Unreadable/unsupported file → inline error in app; CLI exits 1 with message.
- Degenerate inputs (1×1, single color, fully transparent) → valid SVG (single rect path or empty).
- Engine never crashes on input; internal invariants checked with `assert` in debug.

## 10. Delivery

- Plan 1: `VectorEngine` + `vectorize` CLI (fully testable with `swift test`).
- Plan 2: the SwiftUI app, written after Plan 1 lands, against the proven engine API.
