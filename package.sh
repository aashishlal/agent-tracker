#!/bin/bash
# Agent Tracker DMG Packager
# Packages AgentTracker.app into a standard, distributable macOS .dmg installer file.

set -e

APP_NAME="AgentTracker"
APP_DIR="${APP_NAME}.app"
DMG_NAME="${APP_NAME}.dmg"
TEMP_DIR="/tmp/agent_tracker_dmg_source"

echo "=== Packaging ${APP_NAME} into a DMG ==="

# 1. Ensure the app has been built first
if [ ! -d "${APP_DIR}" ]; then
    echo "Error: ${APP_DIR} does not exist. Running build.sh first..."
    ./build.sh
fi

# 2. Set up temporary directory for the DMG contents
echo "Preparing temporary directory..."
rm -rf "${TEMP_DIR}"
mkdir -p "${TEMP_DIR}"

# 3. Copy the application bundle
echo "Copying app bundle..."
cp -R "${APP_DIR}" "${TEMP_DIR}/"

# 4. Create a symlink to the /Applications folder (standard drag-and-drop installer)
echo "Creating Applications folder symlink..."
ln -s /Applications "${TEMP_DIR}/Applications"

# 5. Build the DMG using macOS native hdiutil
echo "Creating DMG image..."
rm -f "${DMG_NAME}"
hdiutil create \
    -volname "Agent Tracker Installer" \
    -srcfolder "${TEMP_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_NAME}"

# 6. Clean up temporary directory
echo "Cleaning up temporary files..."
rm -rf "${TEMP_DIR}"

echo "=== Done! ==="
echo "Your distributable installer is ready at: $(pwd)/${DMG_NAME}"
echo "Users can open this DMG and drag Agent Tracker to their Applications folder."
echo ""
