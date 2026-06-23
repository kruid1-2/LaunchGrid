#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="LaunchGrid"
BUNDLE_ID="com.launchgrid.app"
MIN_SYSTEM_VERSION="13.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/DerivedData"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

build_app() {
  cd "$ROOT_DIR"
  export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-module-cache"
  xcodebuild \
    -project "$ROOT_DIR/LaunchGrid.xcodeproj" \
    -scheme "$APP_NAME" \
    -destination "platform=macOS" \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    build
}

stage_bundle() {
  local build_binary="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"

  if [[ ! -d "$build_binary" ]]; then
    echo "Built binary not found at $build_binary" >&2
    exit 1
  fi

  rm -rf "$APP_BUNDLE"
  mkdir -p "$DIST_DIR"
  ditto --noextattr --noqtn "$build_binary" "$APP_BUNDLE"
  xattr -cr "$APP_BUNDLE"
  codesign --force --sign - "$APP_BUNDLE" >/dev/null
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

wait_for_app() {
  for _ in {1..40}; do
    if [[ "$(osascript -e "application id \"$BUNDLE_ID\" is running")" == "true" ]]; then
      return 0
    fi
    sleep 0.25
  done

  echo "$APP_NAME did not report as running after launch" >&2
  return 1
}

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
build_app
stage_bundle

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    wait_for_app
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
