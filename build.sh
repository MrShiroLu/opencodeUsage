#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Optional overrides from .env
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

APP_NAME="${APP_NAME:-OpenCodeMeter}"
BUNDLE_ID="${BUNDLE_ID:-dev.local.opencode-meter}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
APP_DIR="build/${APP_NAME}.app"
ARCH="$(uname -m)"

echo "==> compiling (${ARCH})"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

swiftc \
  -O -wmo \
  -swift-version 5 \
  -target "${ARCH}-apple-macosx14.0" \
  -o "$APP_DIR/Contents/MacOS/${APP_NAME}" \
  main.swift

cp Info.plist "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ${APP_NAME}" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

echo "==> signing (${SIGNING_IDENTITY})"
codesign --force --sign "${SIGNING_IDENTITY}" "$APP_DIR" >/dev/null 2>&1

echo "==> done: $APP_DIR"
