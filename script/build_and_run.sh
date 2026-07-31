#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="OpenSCQ30"
EXECUTABLE_NAME="openscq30-gui"
OUTPUT_DIR="$ROOT_DIR/build-output"
APP_DIR="$OUTPUT_DIR/$APP_NAME.app"
ARCHIVE_PATH="$OUTPUT_DIR/OpenSCQ30-macOS.zip"
PROFILE="${OPENSCQ30_BUILD_PROFILE:-debug}"

case "$PROFILE" in
    debug)
        CARGO_PROFILE_ARG=""
        BINARY_DIR="debug"
        ;;
    release)
        CARGO_PROFILE_ARG="--release"
        BINARY_DIR="release"
        ;;
    *)
        echo "OPENSCQ30_BUILD_PROFILE must be 'debug' or 'release'" >&2
        exit 2
        ;;
esac

pkill -x "$EXECUTABLE_NAME" 2>/dev/null || true

cd "$ROOT_DIR"
if [[ -n "$CARGO_PROFILE_ARG" ]]; then
    cargo build -p openscq30-gui --features bundled-dependencies "$CARGO_PROFILE_ARG"
else
    cargo build -p openscq30-gui --features bundled-dependencies
fi

BINARY_PATH="${CARGO_TARGET_DIR:-$ROOT_DIR/target}/$BINARY_DIR/$EXECUTABLE_NAME"
if [[ ! -x "$BINARY_PATH" ]]; then
    echo "Built executable was not found at $BINARY_PATH" >&2
    exit 1
fi

if [[ -e "$APP_DIR" ]]; then
    find "$APP_DIR" -depth -delete
fi
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY_PATH" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
cp "$ROOT_DIR/packaging/macos/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/packaging/macos/OpenSCQ30.icns" "$APP_DIR/Contents/Resources/OpenSCQ30.icns"

VERSION="$(awk -F '"' '/^version = "/ { print $2; exit }' "$ROOT_DIR/Cargo.toml")"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_DIR/Contents/Info.plist"
xattr -d com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
codesign --force --sign - "$APP_DIR" >/dev/null
if [[ -f "$ARCHIVE_PATH" ]]; then
    unlink "$ARCHIVE_PATH"
fi
ditto -c -k --keepParent "$APP_DIR" "$ARCHIVE_PATH"

case "$MODE" in
    run)
        open -n "$APP_DIR"
        ;;
    --debug)
        exec lldb -- "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
        ;;
    --logs)
        open -n "$APP_DIR"
        exec log stream --style compact --level debug \
            --predicate "process == '$EXECUTABLE_NAME'"
        ;;
    --telemetry)
        open -n "$APP_DIR"
        exec log stream --style ndjson --level debug \
            --predicate "process == '$EXECUTABLE_NAME'"
        ;;
    --verify)
        open -n "$APP_DIR"
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            if pgrep -x "$EXECUTABLE_NAME" >/dev/null; then
                echo "$APP_NAME launched successfully: $APP_DIR"
                exit 0
            fi
            sleep 0.5
        done
        echo "$APP_NAME did not stay running" >&2
        exit 1
        ;;
    *)
        echo "Usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
        exit 2
        ;;
esac
