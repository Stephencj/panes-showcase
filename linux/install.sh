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
systemctl --user daemon-reload
systemctl --user enable --now panes-agent.service
systemctl --user restart panes-agent.service
sleep 1
systemctl --user --no-pager --lines=3 status panes-agent.service
echo
echo "To keep it running when you're logged out: sudo loginctl enable-linger $USER"
echo "If a firewall blocks it, allow TCP 7890 on the tailscale0 interface only."
