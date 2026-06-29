#!/bin/bash
# Agent Tracker Build & Install Script
# Compiles Swift code, assembles the macOS .app bundle, and runs it.

set -e

APP_NAME="AgentTracker"
APP_DIR="${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MAC_OS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "=== Building ${APP_NAME} ==="

# 1. Compile Swift code
echo "Compiling Swift source..."
swiftc -o "${APP_NAME}" -framework Cocoa AgentTracker.swift

# 2. Create app bundle structure
echo "Creating application bundle..."
mkdir -p "${MAC_OS_DIR}" "${RESOURCES_DIR}"
if [ -f "./build_icon.sh" ]; then
    ./build_icon.sh
fi
if [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns "${RESOURCES_DIR}/"
fi
if [ -d "Icons" ]; then
    cp Icons/*.png "${RESOURCES_DIR}/"
fi

# 3. Move binary
mv "${APP_NAME}" "${MAC_OS_DIR}/${APP_NAME}"

# 4. Copy Info.plist
if [ -f "Info.plist" ]; then
    cp Info.plist "${CONTENTS_DIR}/Info.plist"
else
    echo "Warning: Info.plist not found! Creating default one..."
    cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>com.rooted.${APP_NAME}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>10.13</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
EOF
fi

# 5. Set up default user config if missing
USER_CONFIG="$HOME/.agent-tracker.json"
if [ ! -f "$USER_CONFIG" ]; then
    echo "Creating default configuration at ${USER_CONFIG}..."
    cp agent-tracker.json "$USER_CONFIG"
fi

echo "Build successful: ${APP_DIR} created!"

# 6. Offer to run
echo "To run the app:"
echo "  open ${APP_DIR}"
echo ""
echo "To copy to Applications directory:"
echo "  cp -R ${APP_DIR} /Applications/"
echo ""
