#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="ExitWatch"
APP_DIR="$PROJECT_ROOT/dist/$APP_NAME.app"

cd "$PROJECT_ROOT"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
ICON_BUILD_DIR="$PROJECT_ROOT/.build/exitwatch-icons"
python3 "$PROJECT_ROOT/scripts/generate-icons.py" --output-dir "$ICON_BUILD_DIR"
# Keep the checked-in resources in sync with the generated family so local
# builds, Launchpad and the status item always use the same artwork.
cp "$ICON_BUILD_DIR/ExitWatch.icns" "$PROJECT_ROOT/Resources/ExitWatch.icns"
cp "$ICON_BUILD_DIR/ExitWatchStatus.png" "$PROJECT_ROOT/Resources/ExitWatchStatus.png"
cp "$PROJECT_ROOT/Resources/ExitWatch.icns" "$APP_DIR/Contents/Resources/ExitWatch.icns"
cp "$PROJECT_ROOT/Resources/ExitWatchStatus.png" "$APP_DIR/Contents/Resources/ExitWatchStatus.png"

# Compile the AppIcon asset catalog as well as the legacy .icns file. Launchpad
# on recent macOS versions uses Assets.car when CFBundleIconName is present.
if command -v xcrun >/dev/null 2>&1 && xcrun --find actool >/dev/null 2>&1; then
    ASSET_BUILD_DIR="$PROJECT_ROOT/.build/exitwatch-assets"
    mkdir -p "$ASSET_BUILD_DIR"
    xcrun actool \
        --compile "$ASSET_BUILD_DIR" \
        --app-icon AppIcon \
        --platform macosx \
        --minimum-deployment-target 13.0 \
        --output-partial-info-plist "$ASSET_BUILD_DIR/assetcatalog_generated_info.plist" \
        "$ICON_BUILD_DIR/Assets.xcassets" \
        >/dev/null
    cp "$ASSET_BUILD_DIR/Assets.car" "$APP_DIR/Contents/Resources/Assets.car"
    cp "$ASSET_BUILD_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

# Ad-hoc signing is enough for local development and prevents macOS from
# treating the assembled bundle as a modified executable on every launch.
if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - --timestamp=none "$APP_DIR" >/dev/null
fi

echo "Built $APP_DIR"
