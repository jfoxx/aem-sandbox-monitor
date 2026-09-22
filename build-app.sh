#!/bin/bash
# Build AEM Monitor as a proper macOS .app bundle
set -euo pipefail

echo "Building AEM Monitor..."
swift build -c release

APP_DIR="AEMMonitor.app/Contents"
mkdir -p "$APP_DIR/MacOS"

# Copy binary
cp .build/release/AEMMonitor "$APP_DIR/MacOS/AEMMonitor"

# Copy Info.plist
cp Sources/AEMMonitor/Info.plist "$APP_DIR/Info.plist"

echo ""
echo "✓ Built AEMMonitor.app"
echo "  Double-click to launch, or: open AEMMonitor.app"
echo "  To install: cp -r AEMMonitor.app /Applications/"
