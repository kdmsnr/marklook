#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-open}"
APP_NAME="MarkLook"
BUNDLE_ID="com.example.MarkLook"

case "$MODE" in
    open|--open|run|--run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
        ;;
    *)
        echo "usage: $0 [open|--run|--debug|--logs|--telemetry|--verify]" >&2
        exit 2
        ;;
esac

if [[ -z "${CONFIGURATION:-}" ]]; then
    case "$MODE" in
        open|--open)
            CONFIGURATION="Release"
            ;;
        *)
            CONFIGURATION="Debug"
            ;;
    esac
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/MarkLook.xcodeproj"
DERIVED_DATA_DIR="$ROOT_DIR/.build/DerivedData"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

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

stop_app() {
    /usr/bin/pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

open_app() {
    /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
    open|--open)
        echo "Built $APP_BUNDLE"
        echo "Drag $APP_NAME.app to the Applications folder to install it."
        /usr/bin/open -R "$APP_BUNDLE"
        ;;
    run|--run)
        stop_app
        open_app
        ;;
    --debug|debug)
        stop_app
        exec /usr/bin/xcrun lldb -- "$APP_BINARY"
        ;;
    --logs|logs)
        stop_app
        open_app
        exec /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --telemetry|telemetry)
        stop_app
        open_app
        exec /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
        ;;
    --verify|verify)
        stop_app
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
