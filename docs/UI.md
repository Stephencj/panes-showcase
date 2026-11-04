# Panes UI: flow between apps and machines

The phone app and Panes Web share one design, picked from the mockups
(direction A, "Safari-style": https://claude.ai/artifact/Sc6KLBfqcmq64FnGoGRnGy).
Both follow this page, so moving between devices feels the same.

## Machine colours

Every machine has a colour (`color` in `Shared/machines.json`): Mac mini
`#5B9BFF`, linux-box `#F2A33A`. Wherever a tab, app or machine appears it
carries a dot (or a tinted tile) in that colour. A machine without one gets
`#A3A8B3`.

Ground `#0B0C0E`, surfaces `#16181C` / `#1C1E23`, raised `#262930`, text
`#F2F3F5`, secondary text `#A3A8B3`, links and Done `#8AB8FF`. Inter for UI,
JetBrains Mono for terminals (system fonts on the phone).

## Phone

### Tab view (the default)

- The tab's app fills the screen. A floating bar sits above the bottom edge;
  the app is laid out above the bar, so nothing it shows is hidden behind it
  (fitted windows get that height as their viewport).
- The bar: a round **keyboard** button, the **pill**, a round **search**
  button. The pill shows the machine-colour dot, the app's name and the
  machine's name, with ‹ › arrows at its ends.
- Above the pill, one small dot per tab in its machine's colour; the current
  tab's dot is wider.
- **Swipe the pill left or right** (or tap ‹ ›) for the next or previous tab.
  The tab slides in. Tabs stay connected while in the background (video
  paused), so a switch shows the last picture at once and goes live within a
  moment: no blank screen, no spinner unless it's really reconnecting.
- **Tap the pill, or swipe it up**: the tab grid.
- While the keyboard is up the bar rides above it.

### Tab grid

- Title "N tabs", Done at the top right.
- One section per machine (dot + name), a two-column grid of previews.
  - Window tabs: a JPEG the agent sends on request (`snapshot`, below).
  - Terminal and app tabs: a snapshot of the tab's own view.
  - The current tab has a ring in its machine's colour.
  - Under each: app name, title, a **send** button (open on another device)
    and a **close** button.
- A section **On your other devices**: one card per other device that has
  checked in (its name), listing its open tabs with **Open here** (or
  **Switch** if this device already has it).
- A search bar pinned at the bottom: "Open an app on any machine".

### Search

- One field searching every machine at once. Typing filters by app, window
  title and machine name.
- Empty field: **Recent** (the last 8 things opened here), then one section
  per machine listing everything it offers: its windows (Mac), **New
  terminal**, and its apps (Linux).
- Each row: a tile tinted in the machine's colour with the app's first
  letter, the app, "machine · window title", and **Open** or **Switch to**.
- Picking a row opens it as a new tab (or switches to it if already open)
  and returns to the tab view.
- Machines answer as they can; a machine that's off shows "Can't reach
  <machine>" in its section instead of blocking the rest.

### Send to another device

- A sheet: "Open “<app>” on another device", "It shows up in Panes there and
  stays open here." One row per other device. Picking one sends it and shows
  a short notice: "Sent. <app> is waiting in Panes on <device>."
- A tab that arrives on this device is added to the end of the tab list
  (without taking over the screen), with a notice "<app> arrived from
  <device>", tappable to switch to it.

### Settings

Reachable from the tab grid (a gear button by the title): this device's
name (default "iPhone"), "Fit windows to the phone", "Play the app's sound".

## Panes Web (and the desktop apps that wrap it)

- A top bar of tabs, like a browser's: dot, app name, machine name, close.
  The current tab is raised with a bottom line in its machine's colour. A **+**
  button, then on the right a search box "Open an app on any machine ⌘K" and
  an **Other devices** button.
- **⌘K** (Ctrl+K off the Mac) or the search box opens a centred command
  palette: the same search, same sections, arrow keys + Enter, Esc closes.
- **Other devices** opens a panel: the tabs on other devices (Open here /
  Switch), and "Send <current app> to" with one row per device.
- Ctrl+Tab / Ctrl+Shift+Tab (and ⌘⇧] / ⌘⇧[ on the Mac) move between tabs.
  Keys for the app itself still go to the app.
- The tab's app fills the rest of the window.
- The web client must be installable as a web app (manifest + icons) so it
  can be its own window on each OS; a native wrapper can come later.

## Tabs on other devices: protocol

Each phone or browser is a **device** with an id it makes up once (letters,
digits, `-`, `_`, at most 64) and keeps, a name, and a kind (`phone` or
`browser`). Every agent keeps a small book of devices (`devices.json`, mode
0600, in `~/Library/Application Support/Panes` or `~/.local/share/panes`).

A device reports to **every** machine in machines.json, so nothing is lost
when one is off. It reports when it starts, when its tabs change, when it
comes back to the foreground, and every 15 s while in use. It reads the
device list from every machine and merges by id, keeping the newest `seen`.

These go over any connection (a short-lived one is fine), after `hello`.
Agents that support them list `"devices"` in hello's features.

| Client sends | Agent answers |
|---|---|
| `{"op":"device","device":{"id","name","kind","tabs":[TabRef]}}` | `{"op":"inbox","sent":[SentTab]}`: tabs sent to it, now removed |
| `{"op":"devices","device":{"id"}}` | `{"op":"devices","devices":[DeviceInfo]}`: everyone but the asker, newest first |
| `{"op":"send","to":"<device id>","name":"<sender's name>","tab":TabRef}` | nothing, or `error` if that device never checked in here |
| `{"op":"forget","device":{"id"}}` | nothing; the device and its inbox are dropped |

- **TabRef** `{"machine","kind","app","title"?,"windowID"?,"session"?,"appID"?}`:
  `machine` is the name in machines.json; `kind` is `window`, `terminal` or
  `app`. Opening one elsewhere uses the same window, the same tmux session or
  the same Xpra session, so both devices see the same thing (an Xpra session
  moves to the newest viewer).
- **DeviceInfo** `{"id","name","kind","tabs","seen"}`, `seen` in seconds
  since 1970, filled in by the agent.
- **SentTab** `{"id","from","tab","at"}`. The same send can arrive from more
  than one machine (a device sends to every machine it can reach); clients
  drop repeats by matching `from` + the tab.
- Limits: 20 devices, 60 tabs each, 20 waiting sends each; devices unseen for
  30 days and sends unclaimed for 7 days are dropped.

### Window previews

On a window tab's connection, `{"op":"snapshot","width":400}` gets back a
frame of type **7** (snapshot) holding a JPEG of the window at that width
(at most 1200). Agents that support it list `"snapshot"` in hello's features.
Browsers don't need it: they draw their own decoded frames.

### Testing

`panes-probe --devices 1 [--host H --port P]` makes up two devices, sends a
tab from one to the other, checks it arrives once and the list is right,
then forgets both. `panes-probe --title T --snapshot out.jpg` checks a
preview. Agents take `PANES_PORT`, `PANES_WEB_PORT` and `PANES_STATE_DIR` so
a test build runs beside the installed one.
