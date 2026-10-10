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
    <key>NSCalendarsUsageDescription</key>
    <string>Sidebrief accesses your calendar to detect upcoming meetings, link meeting titles, and identify attendees.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Sidebrief accesses your calendar to detect upcoming meetings, link meeting titles, and identify attendees.</string>
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

# 5. Codesign with Persistent Code Signing Identity and Entitlements
if command -v codesign &> /dev/null; then
    SIGN_IDENTITY="Sidebrief Development"

    # Check if a valid codesigning identity exists
    if ! security find-identity -p codesigning -v | grep -q "\"$SIGN_IDENTITY\""; then
        # Check if another valid developer identity exists
        DEV_ID=$(security find-identity -p codesigning -v | grep -o '\"[^\"]*\"' | head -n 1 | tr -d '\"' || true)
        if [ -n "$DEV_ID" ]; then
            SIGN_IDENTITY="$DEV_ID"
        else
            echo "--> Creating local persistent 'Sidebrief Development' certificate for stable TCC permissions..."
            CERT_CONF=$(mktemp /tmp/sidebrief_cert_conf.XXXXXX)
            cat << 'EOF_CONF' > "$CERT_CONF"
[ req ]
default_bits        = 2048
default_md          = sha256
distinguished_name  = req_distinguished_name
prompt              = no
x509_extensions     = v3_codesign

[ req_distinguished_name ]
CN = Sidebrief Development

[ v3_codesign ]
keyUsage            = critical, digitalSignature
extendedKeyUsage    = critical, codeSigning
EOF_CONF
            KEY_FILE=$(mktemp /tmp/sidebrief_key.XXXXXX)
            CERT_FILE=$(mktemp /tmp/sidebrief_cert.XXXXXX)
            P12_FILE=$(mktemp /tmp/sidebrief_p12.XXXXXX)
            openssl req -x509 -new -nodes -keyout "$KEY_FILE" -out "$CERT_FILE" -days 3650 -config "$CERT_CONF" 2>/dev/null
            openssl pkcs12 -export -legacy -out "$P12_FILE" -inkey "$KEY_FILE" -in "$CERT_FILE" -passout pass:sidebrief 2>/dev/null
            security import "$P12_FILE" -k ~/Library/Keychains/login.keychain-db -P sidebrief -T /usr/bin/codesign 2>/dev/null || true
            security add-trusted-cert -r trustRoot -p codeSign "$CERT_FILE" 2>/dev/null || true
            rm -f "$CERT_CONF" "$KEY_FILE" "$CERT_FILE" "$P12_FILE"
        fi
    fi

    echo "--> Signing bundle with identity: '$SIGN_IDENTITY' and entitlements..."
    codesign --force --deep --sign "$SIGN_IDENTITY" --entitlements "$ROOT_DIR/Sidebrief.entitlements" "$APP_BUNDLE" || {
        echo "--> Fallback: Signing ad-hoc..."
        codesign --force --deep --sign - --entitlements "$ROOT_DIR/Sidebrief.entitlements" "$APP_BUNDLE"
    }

    # Clear quarantine and provenance attributes
    xattr -cr "$APP_BUNDLE" 2>/dev/null || true

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
xattr -cr /Applications/Sidebrief.app 2>/dev/null || true

if [ -f "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister" ]; then
    echo "--> Refreshing LaunchServices register..."
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Sidebrief.app || true
fi

echo "=== Package & Install Complete: /Applications/Sidebrief.app ==="
