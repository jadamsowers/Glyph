# Glyph for iPhone and iPad — design

## Intent

Glyph is a native Mac app that turns bitmaps into clean SVGs. The owner wants it on iPhone and iPad too, shipped through the same TestFlight setup and the same App Store record. That record is "Glyph Vectorizer", bundle `co.jadam.glyph`, and it already lists both iOS and macOS. The owner confirmed this direction:

- **iPhone first.** Pick a photo from the library or take one with the camera. Choose a style and see the trace full-screen. Adjust settings in a sheet. Send the SVG out through the share sheet or Save to Files.
- **iPad.** The image and the inspector sit side by side, close to the Mac layout.
- **One app target** builds for both Mac and iOS, the way `~/Development/ottocue` does. One `scripts/testflight.sh` run uploads both.
- **Curve editing stays on the Mac** in this first iOS version.

## Goals

- The same tracing engine and the same settings as the Mac, with the same results for the same image and options.
- Images can come from:
  - Photos (PhotosPicker)
  - the camera
  - Files
  - paste
  - drag and drop on iPad
- The trace shows with the same compare wipe against the original as on the Mac. It pans and zooms with touch.
- The SVG goes out through the share sheet, Save to Files, and Copy.
- TestFlight builds go out for iOS alongside the Mac.

## Non-goals

- Curve editing on iOS. The engine and model support it, but the touch UI doesn't, so the Edit Curves controls are hidden.
- Mac Catalyst. The Mac app stays native AppKit and SwiftUI.
- Any change to the Mac app's behavior or look.
- iOS artifacts on GitHub releases. iOS ships only through TestFlight and the App Store.
- The `vectorize` CLI on iOS.

## Anti-goals

Any of these counts as a failure, even if the iOS app works:

- The Mac app regresses, including CI and the ad-hoc GitHub release build.
- iOS traces differ from Mac traces for the same input and options.
- The iOS app crashes or is killed for memory on a full-resolution iPhone photo (24–48 MP) at default settings. Raising Max size toward 8000 or turning on High detail is best effort on iOS, the same as a slower Mac. The iOS build carries the `com.apple.developer.kernel.increased-memory-limit` entitlement to give those cases headroom. *(Builder check, my call: clamping the iOS settings would break "the same settings as the Mac".)*

"Same trace" means the same engine code and the same options, with no iOS-only engine changes and nothing resampled differently on its way into the tracer. Byte-identical SVGs aren't required where Apple frameworks may differ by hardware. Vision subject lifting is the main case. It's checked by eye. *(Builder check, my call.)*

## Constraints

- **Deployment targets.** iOS 17.0, because `@Observable`, `.inspector` and Vision subject lifting all need it. macOS stays at 14.0.
- **Engine build.** `VectorEngine` already builds for iOS unchanged; this was verified with `xcodebuild -scheme VectorEngine -destination generic/platform=iOS`. `Package.swift` only needs `.iOS(.v17)` added to `platforms`.
- **Signing.** The project stays ad-hoc signed for macOS, as `docs/testflight.md` explains. iOS builds in CI must use `CODE_SIGNING_ALLOWED=NO`. Only `scripts/testflight.sh` signs with team `9247LFQ5JV`.
- **Icon.** The iOS App Store rejects icons with transparency. The current icon is the macOS squircle with a transparent margin and shadow (`hasAlpha: yes`), so iOS needs its own full-bleed, opaque 1024 px icon.
- **Visual checks.** The owner judges results visually. iOS changes are checked with simulator screenshots on iPhone and iPad, in addition to building.
- **Fixtures.** Never commit the owner's own images. Use synthetic fixtures.

## Approaches

1. **One multiplatform target (chosen).** `App/project.yml` gets `supportedDestinations: [macOS, iOS]` on the existing `Glyph` target, as in OttoCue. Shared SwiftUI views and `AppModel` compile for both. The few platform-specific pieces are separate files or `#if os(...)` blocks. One scheme, one archive per platform, and one TestFlight script.
2. **A separate `GlyphiOS` target sharing source files.** This gives cleaner separation, but means two targets' settings, two schemes and two Info.plist setups to keep in sync. Nothing in the app needs that separation.
3. **Mac Catalyst or "Designed for iPad" on the Mac.** This would replace a good native Mac app with an iPad port. Rejected.

## Design

### Project and build

- **`App/project.yml`**
  - Add `supportedDestinations: [macOS, iOS]` and `deploymentTarget.iOS: "17.0"`.
  - Keep the sandbox entitlements for macOS only: `CODE_SIGN_ENTITLEMENTS[sdk=macosx*]: Glyph.entitlements`, as in OttoCue.
  - Add `[sdk=iphoneos*]: Glyph-iOS.entitlements`, holding only `com.apple.developer.kernel.increased-memory-limit`. The App ID may need that capability turned on; Xcode's automatic signing does that during the TestFlight run.
  - Add iOS Info.plist keys through `INFOPLIST_KEY_*` settings, which work with `GENERATE_INFOPLIST_FILE`:
    - `NSCameraUsageDescription`
    - `UILaunchScreen_Generation`
    - all four orientations on iPad and portrait plus landscape on iPhone
    - `UISupportsDocumentBrowser` / `LSSupportsOpeningDocumentsInPlace` set to `NO`, because Glyph isn't a document-based app on iOS
  - Exclude `SelfSnapshot.swift` and `VectorCanvas.swift` (AppKit) from the iOS build, and add their iOS counterparts. Use xcodegen per-file `platformFilters` or `destinationFilters`.
- **`Package.swift`**: add `.iOS(.v17)`.
- **App icon**
  - Add an iOS app icon: a single 1024 px "universal / iOS" entry in the same `AppIcon` set, generated by `scripts/make-icon.swift` as a full-bleed opaque variant of the same artwork (the disc on the background color, with no squircle or shadow).
  - Keep the Mac entries unchanged.
- **CI** (`.github/workflows/ci.yml`): add an iOS build step, `-destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`. The release workflow is unchanged.
- **`scripts/testflight.sh`**
  - Take `[macos|ios|both]`, defaulting to `both`, like OttoCue.
  - The iOS archive uses `-destination 'generic/platform=iOS'`.
  - Both platforms share one timestamp build number per run.
  - Update `docs/testflight.md` to match.

### Shared canvas drawing

- **What moves.** `CanvasNSView`'s drawing is plain CoreGraphics: the checkerboard, the vector, the wipe against the original, and the divider. Move it into a platform-neutral `CanvasRenderer` struct. Its inputs are bounds, vector, original, output size, zoom, pan, split, dark, and edit overlay state. It exposes `fitScale`, `origin` and `draw(in:)`.
- **What stays.** The Mac `CanvasNSView` keeps all its input handling and calls the renderer. Drawing output must be pixel-identical on the Mac, so check it with the existing `GLYPH_SNAPSHOT_*` self-snapshot before and after.
- **Accent color.** `NSColor.controlAccentColor` becomes a value the host passes in: `NSColor.controlAccentColor` on the Mac, `UIColor.tintColor` on iOS.

### iOS canvas (`VectorCanvasIOS.swift`)

A `UIViewRepresentable` hosting a `UIView` that draws with `CanvasRenderer` and reports `fitScale` to the model, the same way the Mac canvas does.

| Touch | Effect |
|---|---|
| Pinch | Zooms around the pinch center (`model.setZoom(_:anchor:)`). |
| One-finger drag that starts within about 22 pt of the divider | Moves the compare divider. |
| Any other one-finger drag, or a two-finger drag | Pans (`model.pan`). |
| Double-tap | Toggles between fit and actual size, like the Mac's zoom readout button. |

No hover, no cursors and no curve-edit input. `CanvasView`'s overlays are shared:
- The zoom controls stay.
- The background toggle stays.
- The edit controls are hidden on iOS (`#if os(macOS)`).

### iOS layout (`ContentView`)

Use `NavigationStack` with the canvas, or the empty state, as the main view, and `InspectorView` attached with `.inspector(isPresented:)`.
- **iPad (regular width).** The inspector is a trailing column, open by default.
- **iPhone (compact width).** The inspector is a sheet, which SwiftUI picks automatically for `.inspector`. It uses medium and large detents, so the trace stays visible above it at medium.
- **Toolbar.**
  - **Open:** a menu with Photo Library (PhotosPicker), Take Photo (camera), Choose File (`fileImporter`) and Paste.
  - **Style:** a quick menu over the `OutputStyle` cases, mirroring the Mac's Trace menu.
  - **Inspector:** shows and hides it.
  - **Share / export:** a menu with Share… (ShareLink), Save to Files… (`fileExporter`) and Copy SVG.
  - The title is the source name.
- **Empty state.** Large "Choose Photo" and "Take Photo" buttons, plus "Choose File" and "Paste". The Mac's "Drop an image / ⌘O / ⌘V" text stays macOS-only.
- **Drag and drop.** `dropDestination` takes images and files, which works on iPad. The Mac keeps the URL drop it has today.

On the Mac, the layout stays exactly as it is today: an `HStack` with a 280 pt inspector and `.commands`.

### Model changes (`AppModel`)

- **Loading.**
  - Add `open(image: CGImage, name: String)` for photos, camera and paste, generalizing today's pasted-image path.
  - Keep `open(_ url:)`. On iOS, `fileImporter` URLs are security-scoped, as they are on the Mac today.
  - PhotosPicker items load as `Data` and decode through `InputImage.orientedImage`, or an equivalent that takes data, so EXIF orientation is respected the same way.
- **Clipboard.** Paste and Copy use `UIPasteboard` on iOS and `NSPasteboard` on macOS, in `#if os` blocks or a small `Clipboard` helper.
- **Save.** `saveSVG()` (`NSSavePanel`) stays macOS-only. iOS exports through the toolbar instead:
  - `ShareLink` and `fileExporter` take an `SVGDocument` that conforms to `Transferable` and `FileDocument`, with UTType `.svg` and the filename `<source>.svg`.
- **Memory.**
  - The tracer's input is decoded exactly as on the Mac: a full decode, then `InputImage`. It's never fed from a downsampled copy.
  - Only the display copy, `original` (kept for the compare wipe), is downsampled on iOS, to at most 4096 px on the long side.
  - Photo, camera and paste sources keep their encoded `Data` for reloads, not a decoded `CGImage`. That keeps memory low between reloads; the transient full decode is about 192 MB at 48 MP.
  - The full decode for each reload isn't a `CGImage` the model holds on to.
  - The tracing input is already capped by `maxProcessingDimension` (2000 by default).
  - The iOS-only entitlements file adds `com.apple.developer.kernel.increased-memory-limit`. *(Builder check, my calls.)*
- **Curve editing on iOS.** `isEditing` can never become true: no control starts it and no shortcut exists. The re-trace confirmation alert can stay shared.

### Other shared views

- `StyleSections.swift` line 205 converts a SwiftUI `Color` to sRGB through `NSColor`. Use `UIColor` on iOS, or `Color.resolve(in:)`, which is available on iOS 17 and macOS 14.
- `.help(...)` tooltips are harmless on iOS and stay.
- Inspector `Form` sections are shared unchanged.

## Verification

- `swift test` passes, and the Mac app builds as it does in CI.
- The iOS app builds for `generic/platform=iOS` with signing off.
- **Mac canvas unchanged:** self-snapshots before and after the `CanvasRenderer` extraction match.
- **iOS simulator screenshots** of a synthetic fixture: empty state, fit, 400% zoom, inspector open, and share menu, on:
  - an iPhone in portrait
  - an iPad in landscape

  Taken with `xcrun simctl io booted screenshot`, launched with `SIMCTL_CHILD_GLYPH_*` environment variables if an iOS self-snapshot hook proves useful.
- **Memory:** a synthetic 8000×6000 image opens at default settings with a peak footprint well under the iPhone limit. Check it on the simulator with `footprint` while building. The simulator doesn't enforce iOS memory limits, so the real check is on the owner's iPhone and iPad, using a build installed through TestFlight. There's no local device signing. Device checks are the last step:
- upload with `scripts/testflight.sh both`;
- the owner installs the builds;
- the owner opens a 48 MP photo at default settings and runs through the toolbar, the inspector and sharing on both devices.
- **Mac vs iOS:** the same synthetic logo fixture, traced with the same options in the Mac app and the iOS simulator, produces SVGs that match, compared with `diff`. Vision subject removal is checked by eye only.
- `scripts/testflight.sh both` uploads, and both builds reach VALID in App Store Connect.

## Left to the builder

- The exact touch thresholds, toolbar icon choices, and whether the style menu lives in the toolbar or at the top of the inspector on iPhone.
- Whether to use xcodegen file filters or `#if os` for the canvas split.
- Copy for the empty state and menus, in the voice of the existing app ("Drop an image", "Tracing…").
