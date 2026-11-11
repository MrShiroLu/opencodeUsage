#!/usr/bin/env bash
# Builds, installs and launches OpenCode Meter.
# On a fresh machine the welcome screen ("Get started") greets you automatically.
set -euo pipefail

cd "$(dirname "$0")"

# --- settings from .env (if present) ------------------------------------------
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

APP_NAME="${APP_NAME:-OpenCodeMeter}"
BUNDLE_ID="${BUNDLE_ID:-dev.local.opencode-meter}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
export APP_NAME BUNDLE_ID

FRESH=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --fresh) FRESH=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --help|-h)
      cat <<EOF
Usage: ./run.sh [options]

  --fresh   Reset onboarding, so the "Get started" screen appears again
  --yes, -y Accept defaults without asking

Settings are read from .env next to this script (see .env.example).
EOF
      exit 0
      ;;
  esac
done

step() { printf '\n\033[0;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m  ✓\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

ask() {
  local prompt="$1" default="$2" reply
  if [[ "$ASSUME_YES" == "1" || ! -t 0 ]]; then
    printf '%s\n' "$default"
    return
  fi
  read -r -p "$prompt" reply || reply="$default"
  printf '%s\n' "${reply:-$default}"
}

# --- 0. prerequisites ---------------------------------------------------------
step "Checking prerequisites"
command -v swiftc >/dev/null 2>&1 || die "Swift toolchain missing. Run: xcode-select --install"
ok "Swift toolchain: $(swiftc --version 2>/dev/null | head -1 | cut -c1-50)"

if command -v opencode >/dev/null 2>&1; then
  ok "OpenCode CLI: $(command -v opencode)"
else
  printf '\033[0;33m  !\033[0m OpenCode CLI not found — the app installs anyway and tells you in the welcome screen.\n'
fi

# --- 1. build -----------------------------------------------------------------
step "Building $APP_NAME"
./build.sh
ok "Built build/$APP_NAME.app"

# --- 2. install ---------------------------------------------------------------
step "Installing"
answer="$(ask "Install to $INSTALL_DIR? [Y/n] " "Y")"
if [[ "$answer" =~ ^[nN]$ ]]; then
  INSTALL_DIR="$(ask "Install directory: " "$HOME/Applications")"
fi

mkdir -p "$INSTALL_DIR"
TARGET="$INSTALL_DIR/$APP_NAME.app"
pkill -f "$TARGET/Contents/MacOS/$APP_NAME" 2>/dev/null || true
rm -rf "$TARGET"
cp -R "build/$APP_NAME.app" "$TARGET"
ok "Installed $TARGET"

# --- 3. start at login ---------------------------------------------------------
step "Start at login"
answer="$(ask "Launch $APP_NAME when you log in? [y/N] " "N")"
if [[ "$answer" =~ ^[yY]$ ]]; then
  ./Support/install-login-item.sh "$TARGET"
else
  ok "Skipped — you can add it later with ./Support/install-login-item.sh"
fi

# --- 4. onboarding reset (optional) --------------------------------------------
if [[ "$FRESH" == "1" ]]; then
  defaults delete "$BUNDLE_ID" 2>/dev/null || true
  ok "Onboarding reset — the welcome screen will appear"
fi

# --- 5. launch ------------------------------------------------------------------
step "Launching"
open "$TARGET"
ok "$APP_NAME is now in your menu bar"

if [[ "$FRESH" == "1" ]]; then
  printf '\n\033[0;32mDone!\033[0m Click the menu bar icon — the "Get started" screen is waiting.\n'
else
  printf '\n\033[0;32mDone!\033[0m First time? Click the menu bar icon to meet the "Get started" screen.\n'
fi
