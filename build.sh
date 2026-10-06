#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
xcrun swiftc -parse-as-library -O Sources/*.swift -o "build/GIFDroplet"
if [[ "${1:-}" == "--compile-only" ]]; then
    echo "Swift compilation complete."
    exit 0
fi
APP="build/视频转GIF.app"
if [[ -e "$APP" ]]; then
    echo "Remove the previous build directory before packaging." >&2
    exit 1
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp -R Resources/. "$APP/Contents/Resources/"
cp "build/GIFDroplet" "$APP/Contents/MacOS/GIFDroplet"
if [[ -n "${APP_RESOURCES:-}" ]]; then
    python3 scripts/copy_dependencies.py "$APP_RESOURCES" "$APP/Contents/Resources"
fi
codesign --force --deep --sign - "$APP"
echo "Built: $APP"
