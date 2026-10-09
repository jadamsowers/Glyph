# Glyph

A macOS app (and command-line tool) that turns bitmap images into clean, compact SVGs.

- **Logos, icons and UI** are traced with shared edges (no gaps between shapes), straight lines kept straight, sharp corners kept sharp, and smooth curves fitted with as few Bézier segments as possible.
- **Photos** are posterized into smooth stacked regions.
- **Pixel art** is detected and traced exactly along pixel edges.
- **Small images** (under 256 px) are smoothly upscaled first, so anti-aliased edges trace with sub-pixel accuracy.
- **Black-and-white** mode (ink on transparent, potrace-style), **centerline** tracing for line art (single stroked paths), **vector halftone** (dot or line screens), tone **adjustments** and median denoise, lossless **flip/rotate/DPI**, contrast-aware **perceptual simplification**, and **display-size** optimization.

## Layout

| Path | What |
|---|---|
| `Sources/VectorEngine` | The tracing engine (Swift package, no dependencies) |
| `Sources/vectorize` | Command-line tool |
| `App/` | SwiftUI app (`project.yml` → XcodeGen → `Glyph.xcodeproj`) |
| `Tests/VectorEngineTests` | swift-testing suite |
| `scripts/` | Sample-image and app-icon generators |
| `docs/` | Design spec and implementation plan |

## Build

Requires Xcode (Swift 6) on macOS 14+.

```bash
swift test                      # engine tests
swift build -c release          # CLI at .build/release/vectorize
cd App && xcodegen generate     # (brew install xcodegen) then open Glyph.xcodeproj
```

## CLI

```bash
vectorize logo.png -o logo.svg --verbose
vectorize photo.jpg --simplify 0.5 --display-size 256
vectorize scan.png --mono --threshold 0.55 --turn-policy minority
vectorize portrait.jpg --halftone 6 --halftone-angle 45
vectorize sketch.png --centerline --ink '#1a1a1a'
vectorize logo.png --rotate 90 --flip horizontal --dpi 300
vectorize --help
```
