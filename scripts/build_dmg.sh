#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/Sidebrief.app"
DMG_PATH="$DIST_DIR/Sidebrief.dmg"
STAGING_DIR="$DIST_DIR/dmg_staging"

echo "=== Building Sidebrief DMG Installer ==="

# 1. Package fresh app bundle
echo "--> Running package_app.sh..."
"$ROOT_DIR/scripts/package_app.sh"

# 2. Prepare staging directory
echo "--> Preparing DMG staging directory..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

echo "--> Copying Sidebrief.app to staging..."
cp -R "$APP_BUNDLE" "$STAGING_DIR/Sidebrief.app"

echo "--> Creating Applications drag-and-drop symlink..."
ln -s /Applications "$STAGING_DIR/Applications"

# 3. Create temporary writable DMG to configure Finder presentation
echo "--> Creating temporary writable DMG..."
TEMP_DMG="$DIST_DIR/temp.dmg"
rm -f "$TEMP_DMG" "$DMG_PATH"

hdiutil create -volname "Sidebrief" \
               -srcfolder "$STAGING_DIR" \
               -ov \
               -format UDRW \
               "$TEMP_DMG"

# 4. Mount DMG and configure Finder window size, icon positions, and appearance
echo "--> Mounting temporary DMG to customize Finder layout..."
MOUNT_OUTPUT=$(hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG")
MOUNT_DEV=$(echo "$MOUNT_OUTPUT" | grep '^/dev/' | head -n 1 | awk '{print $1}')
MOUNT_POINT="/Volumes/Sidebrief"

echo "--> Applying Finder layout styling (700x440 spacious bounds, 120pt icons)..."
osascript -e "
tell application \"Finder\"
    tell disk \"Sidebrief\"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {160, 140, 860, 580}
        set theViewOptions to the icon view options of container window
        set icon size of theViewOptions to 120
        set arrangement of theViewOptions to not arranged
        set position of item \"Sidebrief.app\" of container window to {190, 240}
        set position of item \"Applications\" of container window to {510, 240}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
" || echo "Note: Finder layout customization via osascript had non-fatal notice."

# Ensure changes are flushed to disk
sync
sleep 1

echo "--> Detaching temporary DMG..."
hdiutil detach "$MOUNT_DEV" -force || hdiutil detach "$MOUNT_POINT" -force || true

# 5. Convert to compressed UDZO DMG
echo "--> Compressing to final UDZO DMG at $DMG_PATH..."
hdiutil convert "$TEMP_DMG" \
                -format UDZO \
                -imagekey zlib-level=9 \
                -ov \
                -o "$DMG_PATH"

rm -f "$TEMP_DMG"
rm -rf "$STAGING_DIR"

# 5. Distribute to backend and website download folders
echo "--> Copying DMG to public download directories..."
mkdir -p "$ROOT_DIR/backend/public/downloads"
mkdir -p "$ROOT_DIR/website/downloads"

cp "$DMG_PATH" "$ROOT_DIR/backend/public/downloads/Sidebrief.dmg"
cp "$DMG_PATH" "$ROOT_DIR/website/downloads/Sidebrief.dmg"

# 6. Verify and output stats
DMG_SIZE="$(du -h "$DMG_PATH" | cut -f1)"
DMG_SHA="$(shasum -a 256 "$DMG_PATH" | cut -d' ' -f1)"

echo "=== DMG Build Successful ==="
echo "Path:   $DMG_PATH"
echo "Size:   $DMG_SIZE"
echo "SHA256: $DMG_SHA"
echo "Public: $ROOT_DIR/backend/public/downloads/Sidebrief.dmg"
