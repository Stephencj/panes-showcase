#!/bin/bash
# Installs the Panes agent for the current user as a systemd user service.
# Run on the Linux box from this folder:  bash install.sh
set -euo pipefail
cd "$(dirname "$0")"
python3 -m unittest -q test_panes_agent.py
mkdir -p ~/.local/share/panes ~/.config/systemd/user
install -m 0644 panes_agent.py ~/.local/share/panes/panes_agent.py
install -m 0644 panes-agent.service ~/.config/systemd/user/panes-agent.service
# Xpra's browser client, for app tabs, when it was shipped alongside.
if [[ -f xpra-html5/index.html ]]; then
    rm -rf ~/.local/share/panes/xpra-html5
    cp -R xpra-html5 ~/.local/share/panes/xpra-html5
fi
# Panes Web's browser client (and machines.json), when it was shipped alongside.
if [[ -f web/index.html ]]; then
    rm -rf ~/.local/share/panes/web
    cp -R web ~/.local/share/panes/web
fi
systemctl --user daemon-reload
systemctl --user enable --now panes-agent.service
systemctl --user restart panes-agent.service
sleep 1
systemctl --user --no-pager --lines=3 status panes-agent.service
echo
echo "To keep it running when you're logged out: sudo loginctl enable-linger $USER"
echo "If a firewall blocks it, allow TCP 7890 on the tailscale0 interface only."
echo
# Panes Web: the agent serves http://127.0.0.1:7891 (loopback only); Tailscale
# publishes it to the tailnet as HTTPS on 7443 with a real certificate.
if command -v tailscale >/dev/null 2>&1; then
    serve=$(tailscale serve status --json 2>/dev/null || true)
    limit=()   # tailscale serve can sit waiting for Serve to be enabled on the tailnet
    command -v timeout >/dev/null 2>&1 && limit=(timeout 30)
    web=$(tailscale status --json 2>/dev/null | python3 -c \
        'import json,sys; print("https://" + json.load(sys.stdin)["Self"]["DNSName"].rstrip(".") + ":7443")' 2>/dev/null \
        || echo "https://<this machine>:7443")
    if grep -q '"7443"' <<<"$serve"; then
        if grep -q '127.0.0.1:7891' <<<"$serve"; then
            echo "Panes Web: tailscale serve already publishes $web -> http://127.0.0.1:7891 (left as is)."
        else
            echo "Panes Web: tailscale serve already uses 7443 for something else; left as is."
            echo "  Panes Web needs: tailscale serve --bg --https=7443 http://127.0.0.1:7891"
        fi
    elif ${limit[@]+"${limit[@]}"} tailscale serve --bg --https=7443 http://127.0.0.1:7891; then
        echo "Panes Web: set up tailscale serve, $web -> http://127.0.0.1:7891"
    else
        echo "Panes Web: couldn't set up tailscale serve (not permitted, or Serve/HTTPS not enabled on the tailnet)."
        echo "  Either let this user manage it:  sudo tailscale set --operator=$USER   and rerun install.sh,"
        echo "  or run it once yourself:         sudo tailscale serve --bg --https=7443 http://127.0.0.1:7891"
    fi
else
    echo "Panes Web: tailscale isn't installed, so it's only at http://127.0.0.1:7891 on this machine."
fi
