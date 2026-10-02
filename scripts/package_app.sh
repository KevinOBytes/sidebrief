#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/Sidebrief.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

echo "=== Packaging Sidebrief.app Bundle ==="

# 1. Compile in Release mode
echo "--> Building SidebriefApp in Release mode..."
cd "$ROOT_DIR"
swift build -c release --product SidebriefApp

BIN_PATH="$(swift build -c release --show-bin-path)"
EXECUTABLE="$BIN_PATH/SidebriefApp"

if [ ! -f "$EXECUTABLE" ]; then
    echo "Error: Executable not found at $EXECUTABLE"
    exit 1
fi

# 2. Setup App Bundle Structure
echo "--> Creating bundle directory structure at $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# 3. Copy Binary & Resources
cp "$EXECUTABLE" "$MACOS_DIR/SidebriefApp"
chmod +x "$MACOS_DIR/SidebriefApp"

if [ -f "$ROOT_DIR/macOS/Resources/AppIcon.icns" ]; then
    echo "--> Installing AppIcon.icns..."
    cp "$ROOT_DIR/macOS/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

# 4. Generate Info.plist
cat << 'EOF' > "$CONTENTS/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIdentifier</key>
    <string>com.sidebrief.macos</string>
    <key>CFBundleName</key>
    <string>Sidebrief</string>
    <key>CFBundleDisplayName</key>
    <string>Sidebrief</string>
    <key>CFBundleExecutable</key>
    <string>SidebriefApp</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Sidebrief requires microphone access to record and transcribe your side of meetings with AES-GCM 256-bit encryption.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Sidebrief uses speech recognition to transcribe meeting audio directly on your Mac.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Sidebrief captures system audio via ScreenCaptureKit to transcribe remote participants.</string>
    <key>NSSystemAdministrationUsageDescription</key>
    <string>Sidebrief captures system audio via ScreenCaptureKit to transcribe remote participants.</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.sidebrief.macos</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>sidebrief</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF

# 5. Codesign Ad-Hoc with Entitlements
if command -v codesign &> /dev/null; then
    echo "--> Signing bundle with stable designated requirement and entitlements..."
    codesign --force --deep --sign - -r='designated => identifier "com.sidebrief.macos"' --entitlements "$ROOT_DIR/Sidebrief.entitlements" "$APP_BUNDLE"
    echo "--> Codesign verified:"
    codesign --verify --verbose "$APP_BUNDLE"
    codesign -d -r- "$APP_BUNDLE"
fi

# 6. Install to /Applications
echo "--> Installing to /Applications/Sidebrief.app..."
pkill -f SidebriefApp || true
sleep 0.5
rm -rf /Applications/Sidebrief.app
cp -R "$APP_BUNDLE" /Applications/Sidebrief.app

if [ -f "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister" ]; then
    echo "--> Refreshing LaunchServices register..."
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Sidebrief.app || true
fi

echo "=== Package & Install Complete: /Applications/Sidebrief.app ==="
