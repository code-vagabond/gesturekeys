#!/bin/zsh
# Build gesturekeys in place and (re)load the launchd agent.
set -euo pipefail
cd "$(dirname "$0")"

APP="$PWD/GestureKeys.app"
BIN="$APP/Contents/MacOS/gesturekeys"
LABEL="com.linh.gesturekeys"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# macOS only lists .app bundles (not bare binaries) under Accessibility.
mkdir -p "$APP/Contents/MacOS"
swiftc -O -import-objc-header MultitouchSupport.h main.swift Config.swift -o "$BIN"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>GestureKeys</string>
  <key>CFBundleExecutable</key><string>gesturekeys</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
# Sign with a real identity so the Accessibility grant survives rebuilds
# (ad-hoc signatures change on every build and macOS drops the grant).
IDENTITY="${CODESIGN_IDENTITY:-Apple Development}"
if ! security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
  echo "No code-signing certificate matching '$IDENTITY'." >&2
  echo "Create one (see README → Requirements), then run: CODESIGN_IDENTITY=\"<name>\" ./install.sh" >&2
  exit 1
fi
codesign --force --sign "$IDENTITY" --identifier "$LABEL" "$APP"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string><string>run</string>${DEBUG:+<string>--debug</string>}</array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/gesturekeys.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/gesturekeys.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
mkdir -p "$HOME/.local/bin" && ln -sf "$BIN" "$HOME/.local/bin/gesturekeys"
echo "installed → $BIN (logs: ~/Library/Logs/gesturekeys.log)"
