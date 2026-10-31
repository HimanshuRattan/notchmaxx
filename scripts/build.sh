#!/bin/zsh
# Builds Notchmaxx.app into ./build. Usage: scripts/build.sh [debug|release]
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="build/Notchmaxx.app"
BIN="build/Notchmaxx"
SDK="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"

FLAGS=(-swift-version 5 -target "$ARCH-apple-macos14.0" -sdk "$SDK" -lsqlite3 -module-name Notchmaxx)
if [[ "$CONFIG" == "release" ]]; then FLAGS+=(-O); else FLAGS+=(-Onone -g); fi

mkdir -p build
swiftc "${FLAGS[@]}" $(find Sources/Notchmaxx -name '*.swift' | sort) -o "$BIN"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Notchmaxx"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "Built $APP"
