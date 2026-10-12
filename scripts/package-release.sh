#!/bin/bash
# Builds release artifacts into dist/: the app (universal, ad-hoc signed) and the vectorize CLI
# (universal). Used by .github/workflows/release.yml; runs the same locally.
# Usage: scripts/package-release.sh 1.0.7
set -euo pipefail

version="${1:?usage: package-release.sh VERSION}"
build="${2:-${version##*.}}"   # build number: defaults to the last version component
root="$(cd "$(dirname "$0")/.." && pwd)"
dist="$root/dist"
rm -rf "$dist" && mkdir -p "$dist"

echo "==> Glyph.app $version ($build)"
xcodebuild -project "$root/App/Glyph.xcodeproj" -scheme Glyph -configuration Release \
    -derivedDataPath "$root/App/build" -destination 'generic/platform=macOS' \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" ONLY_ACTIVE_ARCH=NO \
    -quiet build
app="$root/App/build/Build/Products/Release/Glyph.app"
codesign --verify --deep "$app"
ditto -c -k --keepParent "$app" "$dist/Glyph-$version.zip"

echo "==> vectorize $version"
swift build --package-path "$root" -c release --arch arm64 --arch x86_64 --product vectorize
cli="$(swift build --package-path "$root" -c release --arch arm64 --arch x86_64 --show-bin-path)/vectorize"
zip -j -q "$dist/vectorize-$version-macos.zip" "$cli"

lipo -info "$app/Contents/MacOS/Glyph" "$cli"
ls -lh "$dist"
