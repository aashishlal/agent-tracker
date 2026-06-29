#!/bin/bash
# Converts Icons/App-icon.png to AppIcon.icns using sips and iconutil.

set -e

ICON_PNG="Icons/App-icon.png"
ICONSET_DIR="AppIcon.iconset"
OUT_ICNS="AppIcon.icns"

if [ ! -f "$ICON_PNG" ]; then
    echo "App-icon.png not found at $ICON_PNG, skipping icon compilation"
    exit 0
fi

echo "Generating .iconset from $ICON_PNG..."
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

# Resizing to standard macOS icon sizes
sips -z 16 16     "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16.png" > /dev/null
sips -z 32 32     "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" > /dev/null
sips -z 32 32     "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32.png" > /dev/null
sips -z 64 64     "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" > /dev/null
sips -z 128 128   "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128.png" > /dev/null
sips -z 256 256   "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" > /dev/null
sips -z 256 256   "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256.png" > /dev/null
sips -z 512 512   "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" > /dev/null
sips -z 512 512   "$ICON_PNG" --out "$ICONSET_DIR/icon_512x512.png" > /dev/null

# Compile iconset to icns
echo "Compiling to $OUT_ICNS..."
iconutil -c icns "$ICONSET_DIR" -o "$OUT_ICNS"

# Cleanup iconset folder
rm -rf "$ICONSET_DIR"
echo "Icon created successfully!"
