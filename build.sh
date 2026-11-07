#!/bin/zsh
# Builds WriteWatch.app next to this script, ad-hoc signed. Needs only the Xcode command-line tools.
set -euo pipefail
cd "${0:A:h}"

swift build -c release --product WriteWatch
swift build -c release --product WriteWatchHelper
BIN=$(swift build -c release --show-bin-path)

APP=WriteWatch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/WriteWatch" "$BIN/WriteWatchHelper" "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>WriteWatch</string>
    <key>CFBundleDisplayName</key><string>WriteWatch</string>
    <key>CFBundleIdentifier</key><string>local.writewatch.app</string>
    <key>CFBundleExecutable</key><string>WriteWatch</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Personal disk-write monitor</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP/Contents/MacOS/WriteWatchHelper"
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
