#!/bin/zsh
# Usage:
#   ./build.sh            build "build/Clipboard History.app"
#   ./build.sh install    build, copy to /Applications, and launch
#
# Set CODESIGN_IDENTITY to a real signing identity to keep the Accessibility grant across rebuilds.
# With the default ad-hoc signature, macOS treats every rebuild as a new app.
set -euo pipefail
cd "$(dirname "$0")"

NAME="Clipboard History"
APP="build/$NAME.app"
EXECUTABLE=ClipboardHistory
BUNDLE_ID=com.sandipchitale.clipboard-history

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# A universal binary: compiled for Apple silicon and Intel, then merged.
ARCH_DIR=build/arch
rm -rf "$ARCH_DIR"
mkdir -p "$ARCH_DIR"
for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$arch-apple-macos26.0" \
        Sources/*.swift \
        -o "$ARCH_DIR/$EXECUTABLE-$arch"
done
lipo -create "$ARCH_DIR/$EXECUTABLE-arm64" "$ARCH_DIR/$EXECUTABLE-x86_64" -output "$APP/Contents/MacOS/$EXECUTABLE"

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "${CODESIGN_IDENTITY:--}" --identifier "$BUNDLE_ID" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    # The Accessibility grant is tied to the code signature. If it changed (always, with ad-hoc signing),
    # the old grant is stale. Clear it so macOS asks again.
    requirement() { codesign -d -r- "$1" 2>/dev/null | sed -n 's/^designated => //p' }
    old_req=$(requirement "/Applications/$NAME.app" || true)
    new_req=$(requirement "$APP")
    pkill -x "$EXECUTABLE" 2>/dev/null && sleep 0.5 || true
    rm -rf "/Applications/$NAME.app"
    cp -R "$APP" /Applications/
    if [[ -z "${CODESIGN_IDENTITY:-}" || ( -n "$old_req" && "$old_req" != "$new_req" ) ]]; then
        tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
        echo "Signature changed: grant Accessibility again."
    fi
    open "/Applications/$NAME.app"
    echo "Installed and launched /Applications/$NAME.app"
fi
