#!/bin/bash
# Builds Panes Agent and runs it at login (launchd), from ~/Applications so
# macOS keeps its Screen Recording and Accessibility permissions across updates.
#
#   scripts/install-agent.sh            # refuses unless HEAD contains origin/main
#   scripts/install-agent.sh --branch   # allow a branch under test (still must contain main)
#   scripts/install-agent.sh --uninstall
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL=com.stephencjuliano.panes.agent
APP="$HOME/Applications/Panes Agent.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/panes-agent.log"
DOMAIN="gui/$(id -u)"

if [[ "${1:-}" == "--uninstall" ]]; then
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Stopped and removed the launch agent (the app stays in ~/Applications)."
    exit 0
fi

git fetch -q origin 2>/dev/null || true
if git rev-parse -q --verify origin/main >/dev/null; then
    git merge-base --is-ancestor origin/main HEAD || { echo "HEAD doesn't contain origin/main; merge main first." >&2; exit 1; }
    branch=$(git rev-parse --abbrev-ref HEAD)
    if [[ "$branch" != "main" && "${1:-}" != "--branch" ]]; then
        echo "On branch $branch; pass --branch to install it for testing." >&2
        exit 1
    fi
fi

xcodegen -q
xcodebuild -project Panes.xcodeproj -scheme PanesAgent -configuration Release \
    -destination 'platform=macOS' -derivedDataPath build/release build -quiet
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
rm -rf "$APP"
ditto "build/release/Build/Products/Release/Panes Agent.app" "$APP"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/Panes Agent</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardOutPath</key><string>$LOG</string>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
launchctl bootstrap "$DOMAIN" "$PLIST"

# Panes Web: publish the agent's local web server on the tailnet over HTTPS
# (browsers need HTTPS for video decoding). Other serve entries are left alone.
if ! tailscale serve status 2>/dev/null | grep -q ':7443'; then
    tailscale serve --bg --https=7443 http://127.0.0.1:7891 >/dev/null && echo "Panes Web: https on port 7443 via tailscale serve"
fi
sleep 2
tail -3 "$LOG"
