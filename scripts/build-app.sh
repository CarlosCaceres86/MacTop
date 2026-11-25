#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

sign_identity="${SIGN_IDENTITY:--}"
sign_options=(--force --sign "$sign_identity")
if [[ "$sign_identity" != "-" ]]; then
    sign_options+=(--options runtime --timestamp)
fi

# Universal distribution: both MacBook architectures; no install or launch.
swift build -c release --arch arm64 --arch x86_64
binary_dir="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
app="dist/MacTop.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/ThirdParty"
cp resources/Info.plist "$app/Contents/Info.plist"
cp resources/MacTop.icns "$app/Contents/Resources/MacTop.icns"
cp LICENSE "$app/Contents/Resources/LICENSE"
cp "$binary_dir/MacTop" "$app/Contents/MacOS/MacTop"
# Remove local build paths from the Mach-O debug map before signing.
strip -S "$app/Contents/MacOS/MacTop"
SIGN_IDENTITY="$sign_identity" SIGN_TIMESTAMP=--timestamp scripts/build-helper.sh "$app/Contents/MacOS/spacectl"
cp Vendor/SpacePigeon/LICENSE Vendor/SpacePigeon/LICENSE.yabai Vendor/SpacePigeon/LICENSE.ferry "$app/Contents/Resources/ThirdParty/"
cp Vendor/Spaceballs/LICENSE "$app/Contents/Resources/ThirdParty/LICENSE.Spaceballs"
for executable in MacTop spacectl; do
    for architecture in arm64 x86_64; do
        lipo "$app/Contents/MacOS/$executable" -verify_arch "$architecture"
    done
done
codesign "${sign_options[@]}" "$app/Contents/MacOS/MacTop"
codesign "${sign_options[@]}" "$app"
codesign --verify --deep --strict "$app"
version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" resources/Info.plist)"
archive="dist/MacTop-${version}-universal.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
cp "$archive" dist/MacTop-universal.zip
printf '%s\n' "Created $app, $archive and dist/MacTop-universal.zip."
if [[ "$sign_identity" = "-" ]]; then
    printf '%s\n' "Local ad hoc signing."
else
    printf '%s\n' "Signed with hardened runtime and a secure timestamp. Notarization is pending."
fi
