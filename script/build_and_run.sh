#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="MarkLook"
BUNDLE_ID="com.example.MarkLook"
CONFIGURATION="${CONFIGURATION:-Debug}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/MarkLook.xcodeproj"
DERIVED_DATA_DIR="$ROOT_DIR/.build/DerivedData"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

case "$MODE" in
    run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
        ;;
    *)
        echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
        exit 2
        ;;
esac

/usr/bin/pkill -x "$APP_NAME" >/dev/null 2>&1 || true

/usr/bin/xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$APP_NAME" \
    -configuration "$CONFIGURATION" \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    build

if [[ ! -x "$APP_BINARY" ]]; then
    echo "built app executable not found: $APP_BINARY" >&2
    exit 1
fi

open_app() {
    /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
    run)
        open_app
        ;;
    --debug|debug)
        exec /usr/bin/xcrun lldb -- "$APP_BINARY"
        ;;
    --logs|logs)
        open_app
        exec /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --telemetry|telemetry)
        open_app
        exec /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
        ;;
    --verify|verify)
        open_app
        for _ in {1..30}; do
            if /usr/bin/pgrep -x "$APP_NAME" >/dev/null; then
                echo "$APP_NAME launched successfully."
                exit 0
            fi
            /bin/sleep 0.1
        done
        echo "$APP_NAME did not remain running." >&2
        exit 1
        ;;
esac
