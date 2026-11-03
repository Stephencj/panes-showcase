# Panes on the web: any app from any machine, on any machine

Each agent also serves **Panes Web**: the same tabs as the phone app (Mac
windows, terminals, Linux apps, from every machine at once) in any desktop
browser. A Linux box can use Mac windows, a Mac can use Linux apps, and so on.

## Why HTTPS through Tailscale

Browsers only allow WebCodecs, used for hardware H.264 and AAC decoding, in
secure contexts. So each agent's web server listens on **127.0.0.1:7891 only**
and is published to the tailnet by Tailscale with a real certificate:

    tailscale serve --bg --https=7443 http://127.0.0.1:7891

The web address is `https://<machine>.tailnet-example.ts.net:7443`, listed in
`Shared/machines.json`, which the phone app and the web client both read.
`http://127.0.0.1:7891` also works in a browser on the machine itself, because
localhost counts as a secure context.

## Who may connect (every HTTP request and WebSocket upgrade)

- **Identity:** Tailscale adds a `Tailscale-User-Login` header to everything
  it proxies.
  - If the header is present, it must equal the machine owner's login: the
    `LoginName` of `Self.UserID` in `tailscale status --json`.
  - If it's absent, the request came straight from a local process. Allow it
    only when the `Host` header is `127.0.0.1:7891` or `localhost:7891`.
  - Anything else gets **403**.
- **Origin** (WebSocket upgrades only): it stops other web pages open in your
  browser from driving your machines. `Origin` must be one of:
  - `https://<anything>.<MagicDNSSuffix>:7443`, where the suffix comes from
    `tailscale status --json` (`MagicDNSSuffix`, here `tailnet-example.ts.net`);
  - `http://127.0.0.1:7891` or `http://localhost:7891`.

  Any other Origin, or a missing one, gets **403**.

## Routes

| Route | What |
|---|---|
| `GET /` and static files | The web client from the agent's `web/` folder: `index.html`, `app.js`, `style.css`, `vendor/…`, plus `machines.json`. |
| `GET /ws` (WebSocket upgrade) | Exactly the TCP protocol on 7890, carried over WebSocket. Each binary message is one whole Wire frame (`[type u8][len u32 BE][payload]`, see `Shared/Wire.swift`). Text messages are ignored. The same Session logic runs behind it. |
| `/xpra/<session>/…` (Linux agent only) | Reverse proxy, HTTP and WebSocket upgrade, to that Xpra session's port on 127.0.0.1. |

**Xpra sessions bind to 127.0.0.1 only.** For an app tab, the `launched`
reply's `url` is a **relative path**:
`/xpra/<session>/index.html?password=…&submit=true&…`. Clients resolve it
against the machine's web address. Xpra's client uses the page's path as its
WebSocket path, so the proxy sees `wss://…:7443/xpra/<session>/`.

## hello

The agent's `hello` reply adds `"web": "https://<Self.DNSName without the trailing dot>:7443"`.

## Web client behaviour (mirrors the phone)

- **Tabs and picker:** a tab strip and a `+` picker. Pick a machine from
  `machines.json`, then a window, **New terminal**, or an app, depending on the
  `features` in `hello`.
- **One connection per tab:** each tab opens its own WebSocket to
  `wss://<machine web host>:7443/ws`. If it drops, the tab reconnects and
  reattaches to the same session name.
- **Window tabs:**
  - `open` with `viewport` = the tab area in CSS px, `zoom: 1.0` and `audio: true`.
  - Video is decoded with WebCodecs `VideoDecoder`. Its description is avcC
    built from the SPS and PPS; the codec string is `avc1.` plus SPS bytes 1–3
    in hex.
  - Input: mouse becomes click (with click count), down/drag/up, rightClick,
    move and scroll, all as 0–1 window coordinates. Keys become `text`, or
    `key` with mods.
  - **On a non-Mac browser, Ctrl becomes Cmd**, so Ctrl+C copies in Mac apps.
  - Audio is decoded with WebCodecs `AudioDecoder` (`mp4a.40.2`, with the
    AudioSpecificConfig built from the sample rate and channel count) and
    played through an AudioContext about 150 ms behind live.
  - Background tabs are paused.
- **Terminal tabs:** xterm.js, vendored. `terminal` with `name` = `panes-` plus
  6 random characters, and `cols`/`rows`. Bytes travel as type-4 frames.
- **App tabs:** an iframe of the machine's web address plus the relative `url`.
- **Closing a tab** sends `end` for terminal and app tabs.
