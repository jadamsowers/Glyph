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
| 5 | Polygon | Corner detection + optimal polygon approximation (potrace-inspired: straight-path detection, penalty-minimizing polygon) on each chain/loop. Junction vertices and image-border corners are fixed | same, looser tolerance | Polygons with vertex dots |
| 6 | Curves | Detect corners by angle threshold (`cornerThreshold`); fit cubic Béziers to smooth runs (alpha-based smoothing as in potrace, optional curve optimization merging segments within `curveTolerance`) | same | Curves with control handles |
| 7 | SVG | One `<path>` per region (shared mode: region outline assembled from shared edge chains, reversing as needed; holes via `fill-rule="evenodd"`). Relative commands, coordinates rounded to `precision` decimals. Stacked mode: paths sorted by area descending; each region emitted as its outer boundary only (see notes) | same | Final render + byte/path/node counts |

Notes:
- All tracing is implemented in original Swift code. Potrace is used only as a source of published ideas, not code.
- Stacked mode avoids seams by emitting each region as its outer boundary only — holes are not cut out, because the regions occupying them are smaller and therefore painted later on top. Shapes are emitted largest-area-first. (A hole containing a region that is *larger* than the enclosing one cannot occur, since the enclosing region's outer boundary area exceeds it.)
- Large images: downscaled to `maxProcessingDimension` (default 2000 px long side) for processing; SVG `viewBox` uses original dimensions via scaling of output coordinates.
- Transparency: fully transparent pixels form a "background" label that is never emitted; alpha < threshold treated as transparent.

### Classification heuristic (stage 0)
- `distinctColors`: colors (after 5-bit-per-channel bucketing) covering ≥ 0.1% of pixels.
- `gradientFraction`: fraction of pixels with small-but-nonzero local gradient (smooth shading).
- Logo if `distinctColors ≤ 32` and `gradientFraction < 0.25`; else Photo. Thresholds live in Options.Advanced.
- Default color count = number of significant colors (logo, clamped 2…32) or 16 (photo).

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

## 9. Error handling

- Unreadable/unsupported file → inline error in app; CLI exits 1 with message.
- Degenerate inputs (1×1, single color, fully transparent) → valid SVG (single rect path or empty).
- Engine never crashes on input; internal invariants checked with `assert` in debug.
