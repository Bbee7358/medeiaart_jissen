#!/bin/zsh
set -euo pipefail

LABEL="com.mediaart.brain-touch-server"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NODE_BIN="${BRAIN_TOUCH_NODE:-$(command -v node)}"
ESBUILD_BIN="$PROJECT_DIR/node_modules/.bin/esbuild"
AGENT_DIR="$HOME/Library/LaunchAgents"
RUNTIME_DIR="$HOME/Library/Application Support/BrainTouchServer"
LOG_DIR="$HOME/Library/Logs/BrainTouch"
EVENT_LOG_DIR="$LOG_DIR/events"
PLIST_PATH="$AGENT_DIR/$LABEL.plist"
DOMAIN="gui/$UID"

if [[ ! -x "$NODE_BIN" ]]; then
  print -u2 "node was not found. Run npm install after installing Node.js."
  exit 1
fi

if [[ ! -x "$ESBUILD_BIN" ]]; then
  print -u2 "esbuild was not found. Run npm install in $PROJECT_DIR first."
  exit 1
fi

mkdir -p "$AGENT_DIR" "$RUNTIME_DIR" "$LOG_DIR" "$EVENT_LOG_DIR" "$PROJECT_DIR/dist-server"

"$ESBUILD_BIN" "$PROJECT_DIR/server/index.ts" \
  --bundle \
  --platform=node \
  --format=esm \
  --target=node22 \
  --banner:js="import { createRequire } from 'node:module'; const require = createRequire(import.meta.url);" \
  --outfile="$PROJECT_DIR/dist-server/server.mjs"
cp "$PROJECT_DIR/dist-server/server.mjs" "$RUNTIME_DIR/server.mjs"
cp "$PROJECT_DIR/../shared/touch-event.schema.json" "$RUNTIME_DIR/touch-event.schema.json"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE_BIN</string>
    <string>$RUNTIME_DIR/server.mjs</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$RUNTIME_DIR</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>BRAIN_TOUCH_SCHEMA_PATH</key>
    <string>$RUNTIME_DIR/touch-event.schema.json</string>
    <key>BRAIN_TOUCH_LOGS_DIR</key>
    <string>$EVENT_LOG_DIR</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>5</integer>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/server.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/server.err.log</string>
</dict>
</plist>
EOF

plutil -lint "$PLIST_PATH"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

for attempt in {1..5}; do
  if launchctl bootstrap "$DOMAIN" "$PLIST_PATH"; then
    break
  fi

  if [[ "$attempt" -eq 5 ]]; then
    print -u2 "Failed to register $LABEL after $attempt attempts."
    exit 1
  fi

  sleep 1
done

launchctl kickstart -k "$DOMAIN/$LABEL"

print "Brain Touch server service installed: $DOMAIN/$LABEL"
print "Health: http://127.0.0.1:8787/health"
