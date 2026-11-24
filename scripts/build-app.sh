#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Universal distribution: both MacBook architectures; no install or launch.
swift build -c release --arch arm64 --arch x86_64
binary_dir="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
app="dist/MacTop.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/ThirdParty"
cp resources/Info.plist "$app/Contents/Info.plist"
cp resources/MacTop.icns "$app/Contents/Resources/MacTop.icns"
cp "$binary_dir/MacTop" "$app/Contents/MacOS/MacTop"
scripts/build-helper.sh "$app/Contents/MacOS/spacectl"
cp Vendor/SpacePigeon/LICENSE Vendor/SpacePigeon/LICENSE.yabai Vendor/SpacePigeon/LICENSE.ferry "$app/Contents/Resources/ThirdParty/"
cp Vendor/Spaceballs/LICENSE "$app/Contents/Resources/ThirdParty/LICENSE.Spaceballs"
for executable in MacTop spacectl; do
    for architecture in arm64 x86_64; do
        lipo "$app/Contents/MacOS/$executable" -verify_arch "$architecture"
    done
    codesign --force --sign - "$app/Contents/MacOS/$executable"
done
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" resources/Info.plist)"
archive="dist/MacTop-${version}-universal.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
cp "$archive" dist/MacTop-universal.zip
printf '%s\n' "Created $app, $archive and dist/MacTop-universal.zip (local ad hoc signatures)."
