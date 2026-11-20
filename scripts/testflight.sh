#!/bin/bash
# Archives Glyph for the App Store (Mac, iPhone and iPad) and uploads it to App Store Connect for
# TestFlight. Usage: scripts/testflight.sh [macos|ios|both]   (default: both)
# Signs with the paid team below, either through the Apple ID signed in to Xcode or an App Store
# Connect API key: set ASC_KEY_ID and ASC_ISSUER_ID (and ASC_KEY_PATH if the key isn't at
# ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8). See docs/testflight.md.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
platforms=${1:-both}

# The project itself stays ad-hoc signed so CI and GitHub releases build without an Apple account;
# only this script signs with the team.
team=9247LFQ5JV

auth=()
if [[ -n "${ASC_KEY_ID:-}" ]]; then
    key=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}
    if [[ -z "${ASC_ISSUER_ID:-}" || ! -f "$key" ]]; then
        echo "ASC_KEY_ID needs ASC_ISSUER_ID and the key file ($key)." >&2
        exit 1
    fi
    auth=(-authenticationKeyPath "$key" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

# A timestamp build number is always newer than the last upload, with nothing to commit.
build=$(date +%Y%m%d.%H%M)
out="$root/App/build/testflight/$build"
mkdir -p "$out"
cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>upload</string>
	<key>signingStyle</key><string>automatic</string>
	<key>teamID</key><string>$team</string>
	<key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

(cd "$root/App" && xcodegen generate --quiet)

upload() {
    local name=$1 destination=$2
    echo "==> Glyph for $name, build $build"
    xcodebuild archive -project "$root/App/Glyph.xcodeproj" -scheme Glyph -configuration Release \
        -destination "$destination" -archivePath "$out/$name.xcarchive" \
        CURRENT_PROJECT_VERSION="$build" DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic \
        CODE_SIGN_IDENTITY="Apple Development" -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} -quiet
    # Export spawns `rsync` from PATH; Homebrew's rsync 3.x rejects Apple's -E flag ("Copy failed").
    PATH="/usr/bin:$PATH" xcodebuild -exportArchive -archivePath "$out/$name.xcarchive" \
        -exportOptionsPlist "$out/ExportOptions.plist" -exportPath "$out/$name" \
        -allowProvisioningUpdates ${auth[@]+"${auth[@]}"}
}

case "$platforms" in
    macos) upload macOS 'generic/platform=macOS' ;;
    ios) upload iOS 'generic/platform=iOS' ;;
    both) upload macOS 'generic/platform=macOS'; upload iOS 'generic/platform=iOS' ;;
    *) echo "usage: $0 [macos|ios|both]" >&2; exit 2 ;;
esac
echo "Uploaded build $build. It appears in App Store Connect › TestFlight once processing finishes (usually 5–15 min)."
