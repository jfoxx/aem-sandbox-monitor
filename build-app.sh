#!/bin/bash
# Build AEM Monitor as a proper macOS .app bundle
set -euo pipefail

echo "Building AEM Monitor..."
swift build -c release

APP="AEMMonitor.app"
APP_DIR="$APP/Contents"

# Start from a clean bundle so stale files/signatures never linger.
rm -rf "$APP"
mkdir -p "$APP_DIR/MacOS"

# Copy binary
cp .build/release/AEMMonitor "$APP_DIR/MacOS/AEMMonitor"

# Copy Info.plist
cp Sources/AEMMonitor/Info.plist "$APP_DIR/Info.plist"

# Ad-hoc sign the whole bundle. Without a bundle signature macOS can silently
# refuse notification permission (UNErrorDomain "Notifications are not
# allowed for this application"), even though the app launches fine.
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=1 "$APP"

# Make sure LaunchServices / Notification Center see the current bundle.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" || true

echo ""
echo "Built $APP (ad-hoc signed)"
echo "  Install: pkill -x AEMMonitor; rm -rf /Applications/$APP; cp -R $APP /Applications/"
echo "  Then:    open /Applications/$APP"
