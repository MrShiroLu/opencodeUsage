#!/usr/bin/env bash
# Installs a per-user LaunchAgent so OpenCode Meter starts when you log in.
set -euo pipefail

APP="${1:-$HOME/Applications/OpenCodeMeter.app}"
BIN="$APP/Contents/MacOS/OpenCodeMeter"
PLIST="$HOME/Library/LaunchAgents/dev.local.opencode-meter.plist"

if [[ ! -x "$BIN" ]]; then
  echo "Not found: $BIN" >&2
  echo "Build and install first: make install" >&2
  exit 1
fi

mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>dev.local.opencode-meter</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
EOF

echo "Login item written to $PLIST"
echo "It starts on the next login. Remove it with: rm \"$PLIST\""
