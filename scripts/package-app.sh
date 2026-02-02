#!/bin/bash
set -e

# Configuration
APP_NAME="Time Tracker"
BUNDLE_ID="com.timetracker.app"
VERSION="1.0.0"

# Paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/dist"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "=== Building Time Tracker App Bundle ==="
echo ""

# Step 1: Build the binary
echo "Step 1: Building binary..."
cd "$PROJECT_DIR"
zig build

echo "Step 2: Creating app bundle structure..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Step 3: Copy Info.plist
echo "Step 3: Copying Info.plist..."
cp "$PROJECT_DIR/bundle/Info.plist" "$APP_BUNDLE/Contents/"

# Step 4: Copy binary
echo "Step 4: Copying binary..."
cp "$PROJECT_DIR/zig-out/bin/time_tracker" "$APP_BUNDLE/Contents/MacOS/TimeTracker"

# Step 5: Create a wrapper script that launches the daemon
echo "Step 5: Creating launcher..."
cat > "$APP_BUNDLE/Contents/MacOS/TimeTrackerLauncher" << 'EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/TimeTracker" daemon
EOF
chmod +x "$APP_BUNDLE/Contents/MacOS/TimeTrackerLauncher"

# Update Info.plist to use the launcher
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable TimeTrackerLauncher" "$APP_BUNDLE/Contents/Info.plist"

# Step 6: Create a simple icon (optional - using system icon)
echo "Step 6: Setting up icon..."
# We'll create a simple icon using a system icon
# For now, skip custom icon - the app will use a generic icon

# Step 7: Create PkgInfo
echo "Step 7: Creating PkgInfo..."
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Step 8: Create a zip for distribution
echo "Step 8: Creating distribution zip..."
cd "$BUILD_DIR"
rm -f "TimeTracker-$VERSION.zip"
zip -r "TimeTracker-$VERSION.zip" "$APP_NAME.app"

echo ""
echo "=== Build Complete ==="
echo ""
echo "App bundle: $APP_BUNDLE"
echo "Distribution zip: $BUILD_DIR/TimeTracker-$VERSION.zip"
echo ""
echo "To install:"
echo "  1. Unzip TimeTracker-$VERSION.zip"
echo "  2. Drag 'Time Tracker.app' to /Applications"
echo "  3. Right-click the app and select 'Open' (first time only, to bypass Gatekeeper)"
echo "  4. Grant Accessibility permission in System Settings > Privacy & Security"
echo ""
echo "The app runs as a menu bar item (clock icon in the menu bar)."
