# Panes

App windows from your machines, in tabs on your phone. Each tab streams one
real window (Xcode, a DAW, anything) from a machine on the tailnet, and your
taps and typing go back into it.

- `iOS/`: the phone app (tabs, window picker, touch and keyboard input).
- `Agent/`: Panes Agent, which runs on each Mac. It lists windows,
  captures one per connection with ScreenCaptureKit, encodes H.264 on the
  hardware encoder, and plays input back with CGEvent and Accessibility.
- `Shared/`: the wire format, geometry and key names both sides use.
- `Probe/`: `panes-probe`, an end-to-end check of a running agent.

## Wire

TCP port 7890, one connection per tab. Frames are `[type u8][len u32][payload]`:
JSON control messages, H.264 parameter sets, and AVCC video frames. See
`Shared/Wire.swift`. Background tabs are paused, and a slow link skips frames
instead of queueing them.

## Who can connect

Only this Mac itself, or devices on the tailnet owned by the same Tailscale
user (checked with `tailscale whois`). Machines on the home Wi-Fi that aren't
on the tailnet are refused.

## Mac setup

    scripts/install-agent.sh

This builds the agent into `~/Applications/Panes Agent.app` and runs it at
login. The first time, allow **Panes Agent** in System Settings → Privacy &
Security → **Screen Recording** and **Accessibility**. Logs go to
`~/Library/Logs/panes-agent.log`.

## Linux setup

Copy `linux/` to the box and run `bash install.sh` there. It installs a systemd
user service listening on 7890 with the same access rule (tailnet devices of
the same owner). Terminal tabs need nothing else; tmux makes them persistent.

## Tests

    xcodegen && xcodebuild -scheme PanesAgent -destination 'platform=macOS' test

Unit tests cover framing, geometry, key names and a real hardware-encoded
frame through the wire. With the agent running:

    build/dd/Build/Products/Debug/panes-probe --title "Untitled" --fit 393x700 --type hello

This opens the matching window, decodes the first frame, types into it, and
checks that new frames follow.
