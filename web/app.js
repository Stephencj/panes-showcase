// Panes Web: the phone app's tabs in a desktop browser. Each tab has its own
// WebSocket to a machine's agent, carrying the same frames as the phone's TCP
// connection (see docs/WEB.md and Shared/Wire.swift).
import {
  FrameType, WIRE_VERSION, encodeControl, encodeFrame, parseFrames, decodeControl,
  parseVideoFormat, parseVideoFrame, parseAudioFormat, parseAudioFrame,
  avcCodecString, avcC, aacConfig, aspectFit, normalized, clampedNormalized,
  keyEvent, modsFor, isPasteShortcut, newSessionName,
} from './wire.js';

const $ = (id) => document.getElementById(id);
const utf8 = new TextEncoder();
const isMac = /Mac|iPhone|iPad/.test(navigator.userAgentData?.platform || navigator.platform || '');

// MARK: storage (can be missing or throw in private windows; nothing depends on it)

function load(key, fallback) {
  try {
    const v = localStorage.getItem(key);
    return v === null ? fallback : JSON.parse(v);
  } catch {
    return fallback;
  }
}

function save(key, value) {
  try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* not kept, that's fine */ }
}

// MARK: connection

/// One WebSocket to a machine's agent. Events: ready, control, format, frame,
/// terminal, audioFormat, audio, failed.
class Link {
  constructor(machine, onEvent) {
    this.machine = machine;
    this.onEvent = onEvent;
    this.closed = false;
    this.opened = false;
  }

  connect() {
    let ws;
    try {
      ws = new WebSocket(this.machine.web.replace(/^http/, 'ws').replace(/\/$/, '') + '/ws');
    } catch (e) {
      queueMicrotask(() => this.lost(`Couldn't reach ${this.machine.name}.`));
      return;
    }
    ws.binaryType = 'arraybuffer';
    this.ws = ws;
    ws.onopen = () => {
      if (this.ws !== ws) return;
      this.opened = true;
      this.onEvent({ type: 'ready' });
    };
    ws.onmessage = (m) => {
      if (this.ws !== ws || !(m.data instanceof ArrayBuffer)) return;
      let frames;
      try {
        frames = parseFrames(m.data);
      } catch (e) {
        console.warn('panes: bad frame', e);
        ws.close();
        return;
      }
      for (const f of frames) this.dispatch(f);
    };
    ws.onclose = () => {
      if (this.ws !== ws) return;
      this.lost(this.opened ? 'Connection lost.' : `Couldn't reach ${this.machine.name}.`);
    };
  }

  dispatch(f) {
    switch (f.type) {
      case FrameType.control: {
        let msg;
        try { msg = decodeControl(f.payload); } catch { return; }
        this.onEvent({ type: 'control', msg });
        break;
      }
      case FrameType.videoFormat: {
        const sets = parseVideoFormat(f.payload);
        if (sets) this.onEvent({ type: 'format', sets });
        break;
      }
      case FrameType.videoFrame: {
        const v = parseVideoFrame(f.payload);
        if (v) this.onEvent({ type: 'frame', ...v });
        break;
      }
      case FrameType.terminal:
        this.onEvent({ type: 'terminal', bytes: f.payload });
        break;
      case FrameType.audioFormat: {
        const a = parseAudioFormat(f.payload);
        if (a) this.onEvent({ type: 'audioFormat', format: a });
        break;
      }
      case FrameType.audioFrame: {
        const a = parseAudioFrame(f.payload);
        if (a) this.onEvent({ type: 'audio', ...a });
        break;
      }
    }
  }

  send(msg) { this.sendBytes(encodeControl(msg)); }

  sendRaw(type, payload) { this.sendBytes(encodeFrame(type, payload)); }

  sendBytes(bytes) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) this.ws.send(bytes);
  }

  close() {
    this.closed = true;
    const ws = this.ws;
    this.ws = null;
    if (ws) try { ws.close(); } catch { /* already gone */ }
  }

  lost(why) {
    this.ws = null;
    if (!this.closed) this.onEvent({ type: 'failed', why });
  }
}

// MARK: sound

/// One AudioContext for the page. Browsers only let it start after a click or
/// key press, so it's resumed on the first one.
let audioContext = null;
function sharedAudioContext() {
  if (!audioContext && window.AudioContext) {
    try { audioContext = new AudioContext({ latencyHint: 'interactive' }); } catch { audioContext = null; }
  }
  return audioContext;
}
for (const ev of ['pointerdown', 'keydown']) {
  document.addEventListener(ev, () => {
    const ctx = sharedAudioContext();
    if (ctx && ctx.state === 'suspended') ctx.resume().catch(() => {});
  }, { capture: true });
}

/// How far behind live sound plays: enough for network jitter, not enough to notice.
const AUDIO_LEAD = 0.15;
/// Further behind than this (on top of the lead) and it skips ahead to live.
const AUDIO_MAX_BEHIND = 0.5;

/// A window tab's AAC stream, decoded with WebCodecs and scheduled on the shared AudioContext.
class AudioPlayer {
  constructor() {
    this.decoder = null;
    this.base = null;
    this.sources = new Set();
    this.enabled = true;
    // Counts, for tests and the console.
    this.decoded = 0;
    this.scheduled = 0;
    this.peak = 0;
  }

  setFormat(f) {
    this.close();
    if (!window.AudioDecoder) return;
    const config = {
      codec: 'mp4a.40.2',
      sampleRate: f.sampleRate,
      numberOfChannels: f.channels,
      description: aacConfig(f.sampleRate, f.channels),
    };
    const d = new AudioDecoder({
      output: (data) => this.schedule(data),
      error: (e) => {
        console.warn('panes: audio decoder failed', e);
        if (this.decoder === d) this.decoder = null;
      },
    });
    try {
      d.configure(config);
      this.decoder = d;
    } catch (e) {
      console.warn('panes: audio format not supported', e);
    }
  }

  play(pts, packet) {
    const d = this.decoder;
    if (!this.enabled || !d || d.state !== 'configured') return;
    try {
      d.decode(new EncodedAudioChunk({ type: 'key', timestamp: pts, data: packet }));
    } catch (e) {
      console.warn('panes: audio decode failed', e);
    }
  }

  schedule(data) {
    this.decoded++;
    const ctx = sharedAudioContext();
    if (!this.enabled || !ctx || ctx.state !== 'running') { data.close(); return; }
    const frames = data.numberOfFrames;
    const buffer = ctx.createBuffer(data.numberOfChannels, frames, data.sampleRate);
    const plane = new Float32Array(frames);
    for (let c = 0; c < data.numberOfChannels; c++) {
      data.copyTo(plane, { planeIndex: c, format: 'f32-planar' });
      buffer.copyToChannel(plane, c);
      if (c === 0) for (let i = 0; i < frames; i += 8) this.peak = Math.max(this.peak, Math.abs(plane[i]));
    }
    const t = data.timestamp / 1e6;
    data.close();
    const now = ctx.currentTime;
    if (this.base === null) this.base = now + AUDIO_LEAD - t;
    let at = this.base + t;
    if (now - at > AUDIO_MAX_BEHIND) {
      // Far behind (a stall): drop this one and start again from the next.
      this.base = null;
      return;
    }
    if (at < now || at > now + AUDIO_LEAD + AUDIO_MAX_BEHIND) {
      // A little late, or drifted too far behind live: line back up at the lead.
      if (at > now) this.stopSources();
      this.base = now + AUDIO_LEAD - t;
      at = now + AUDIO_LEAD;
    }
    const src = ctx.createBufferSource();
    src.buffer = buffer;
    src.connect(ctx.destination);
    src.onended = () => this.sources.delete(src);
    this.sources.add(src);
    src.start(at);
    this.scheduled++;
  }

  stopSources() {
    for (const s of this.sources) try { s.stop(); } catch { /* not started */ }
    this.sources.clear();
  }

  /// Silences it and starts timing afresh (a new format, a paused tab).
  stop() {
    this.stopSources();
    this.base = null;
  }

  close() {
    this.stop();
    if (this.decoder && this.decoder.state !== 'closed') try { this.decoder.close(); } catch { /* closed */ }
    this.decoder = null;
  }
}

// MARK: tabs

const MOVE_INTERVAL = 1000 / 30;
const DRAG_SLOP = 3;
const RETRY_MAX = 30;

/// One tab: a window, terminal or app on a machine, over its own connection.
/// kind is {type: 'window', window}, {type: 'terminal', session} or {type: 'app', app, session}.
class PaneTab {
  constructor(store, machine, kind, opts = {}) {
    this.store = store;
    this.machine = machine;
    this.kind = kind;
    this.fit = opts.fit ?? true;
    this.audioOn = opts.audio ?? true;
    this.id = crypto.randomUUID ? crypto.randomUUID() : String(Math.random());
    this.status = 'connecting';
    this.why = '';
    this.notice = null;
    this.active = false;
    this.attempt = 0;
    this.retryTimer = null;
    /// Set once the agent says the window closed or the shell exited: retrying won't help.
    this.final = false;
    this.framesDecoded = 0;

    switch (kind.type) {
      case 'window':
        this.title = kind.window.title;
        this.windowSize = { width: kind.window.width, height: kind.window.height };
        break;
      case 'terminal':
        this.title = 'Terminal';
        break;
      case 'app':
        this.title = kind.app.name;
        break;
    }

    this.el = document.createElement('div');
    this.el.className = 'pane';
    this.el.hidden = true;
    this.el.dataset.kind = kind.type;
    $('stage').appendChild(this.el);
    if (kind.type === 'window') this.buildWindow();
    if (kind.type === 'terminal') this.buildTerminal();
    if (kind.type === 'app') this.buildApp();
    this.buildOverlay();
    new ResizeObserver(() => this.layout()).observe(this.el);
  }

  get appName() {
    switch (this.kind.type) {
      case 'window': return this.kind.window.app;
      case 'terminal': return 'Terminal';
      default: return this.kind.app.name;
    }
  }

  get session() { return this.kind.session; }

  /// What's remembered across reloads.
  toJSON() {
    const k = this.kind;
    return {
      machine: this.machine.name,
      kind: k.type,
      window: k.type === 'window' ? k.window : undefined,
      app: k.type === 'app' ? k.app : undefined,
      session: k.session,
      fit: this.fit,
      audio: this.audioOn,
    };
  }

  // MARK: connection

  connect() {
    clearTimeout(this.retryTimer);
    this.link?.close();
    this.setStatus('connecting');
    this.waitingForKeyframe = true;
    const link = new Link(this.machine, (e) => { if (this.link === link) this.handle(e); });
    this.link = link;
    link.connect();
  }

  reconnect() {
    this.final = false;
    this.attempt = 0;
    this.connect();
  }

  /// Closing a terminal or app tab ends its session on the machine (a dropped
  /// connection doesn't, so programs survive a reload).
  end() {
    if (this.kind.type !== 'window') this.link?.send({ op: 'end', name: this.session });
  }

  close() {
    clearTimeout(this.retryTimer);
    this.link?.close();
    this.link = null;
    this.status = 'closed';
    this.audio?.close();
    if (this.decoder && this.decoder.state !== 'closed') try { this.decoder.close(); } catch { /* closed */ }
    this.frame?.close();
    this.frame = null;
    this.term?.dispose();
    this.el.remove();
  }

  /// Background tabs stop their video (the connection stays) so only the
  /// tab on screen uses bandwidth, and only it plays sound.
  setActive(on) {
    if (on === this.active) return;
    this.active = on;
    this.el.hidden = !on;
    if (this.kind.type === 'window') {
      this.link?.send({ op: on ? 'resume' : 'pause' });
      if (this.audio) {
        this.audio.enabled = on;
        this.audio.stop();
      }
    }
    if (on) {
      this.layout();
      requestAnimationFrame(() => this.focus());
    }
  }

  focus() {
    if (this.canvas) this.canvas.focus({ preventScroll: true });
    if (this.term) this.term.focus();
  }

  send(event) { this.link?.send({ op: 'input', event }); }

  handle(e) {
    switch (e.type) {
      case 'ready':
        this.link.send({ op: 'hello', version: WIRE_VERSION });
        this.sendOpen();
        break;
      case 'control':
        this.control(e.msg);
        break;
      case 'format':
        this.setVideoFormat(e.sets);
        break;
      case 'frame':
        this.decodeFrame(e);
        break;
      case 'terminal':
        this.term?.write(e.bytes);
        break;
      case 'audioFormat':
        if (!this.audio) this.audio = new AudioPlayer();
        this.audio.enabled = this.active;
        this.audio.setFormat(e.format);
        break;
      case 'audio':
        if (this.active) this.audio?.play(e.pts, e.packet);
        break;
      case 'failed':
        this.failed(e.why);
        break;
    }
  }

  sendOpen() {
    const k = this.kind;
    if (k.type === 'window') {
      const stage = $('stage');
      const viewport = this.fit ? { width: stage.clientWidth, height: stage.clientHeight } : undefined;
      this.link.send({ op: 'open', windowID: k.window.id, viewport, zoom: 1.0, audio: this.audioOn });
      if (!this.active) this.link.send({ op: 'pause' });
    } else if (k.type === 'terminal') {
      this.fitTerminal();
      this.link.send({ op: 'terminal', name: k.session, cols: this.term.cols, rows: this.term.rows });
    } else {
      this.link.send({ op: 'launch', app: k.app.id, name: k.session });
    }
  }

  control(msg) {
    switch (msg.op) {
      case 'opened':
        this.live();
        if (msg.title) this.title = msg.title;
        if (msg.width && msg.height) this.windowSize = { width: msg.width, height: msg.height };
        this.store.render();
        break;
      case 'terminalOpened':
        this.live();
        break;
      case 'launched':
        this.live();
        if (msg.url) this.showApp(msg.url);
        break;
      case 'resized':
        if (msg.width && msg.height) this.windowSize = { width: msg.width, height: msg.height };
        this.draw();
        break;
      case 'exited':
        this.final = true;
        this.setStatus('failed', 'The shell exited.');
        break;
      case 'closed':
        this.final = true;
        this.setStatus('failed', 'The window was closed on the Mac.');
        break;
      case 'error':
        this.showNotice(msg.error || 'Something went wrong.');
        break;
    }
  }

  live() {
    this.attempt = 0;
    this.setStatus('live');
  }

  /// A dropped connection retries on its own, backing off, and reattaches to
  /// the same window or session.
  failed(why) {
    if (this.status === 'closed') return;
    if (this.final) return this.setStatus('failed', why);
    const delay = Math.min(RETRY_MAX, 2 ** this.attempt);
    this.attempt++;
    this.setStatus('failed', `${why} Trying again in ${delay} s…`);
    clearTimeout(this.retryTimer);
    this.retryTimer = setTimeout(() => this.connect(), delay * 1000);
  }

  setStatus(status, why = '') {
    this.status = status;
    this.why = why;
    this.updateOverlay();
    this.store.render();
  }

  // MARK: overlay and notice

  buildOverlay() {
    this.overlay = document.createElement('div');
    this.overlay.className = 'overlay';
    this.el.appendChild(this.overlay);
    this.noticeEl = document.createElement('div');
    this.noticeEl.className = 'notice';
    this.noticeEl.hidden = true;
    this.noticeEl.setAttribute('role', 'status');
    const text = document.createElement('span');
    const x = document.createElement('button');
    x.textContent = '✕';
    x.title = 'Dismiss';
    x.onclick = () => { this.noticeEl.hidden = true; };
    this.noticeEl.append(text, x);
    this.el.appendChild(this.noticeEl);
    this.updateOverlay();
  }

  showNotice(text) {
    this.noticeEl.firstChild.textContent = text;
    this.noticeEl.hidden = false;
  }

  updateOverlay() {
    const o = this.overlay;
    if (!o) return;
    o.replaceChildren();
    if (this.status === 'connecting') {
      const spin = document.createElement('div');
      spin.className = 'spinner';
      const label = document.createElement('div');
      label.textContent = `Connecting to ${this.machine.name}…`;
      o.append(spin, label);
      o.hidden = false;
    } else if (this.status === 'failed') {
      const label = document.createElement('div');
      label.textContent = this.why;
      const b = document.createElement('button');
      b.className = 'primary';
      b.textContent = 'Reconnect';
      b.onclick = () => this.reconnect();
      o.append(label, b);
      o.hidden = false;
    } else {
      o.hidden = true;
    }
  }

  layout() {
    if (this.el.hidden) return;
    if (this.canvas) this.draw();
    if (this.term) this.fitTerminal();
  }

  // MARK: window tabs

  buildWindow() {
    const c = document.createElement('canvas');
    c.tabIndex = 0;
    c.setAttribute('aria-label', `${this.kind.window.app}: ${this.kind.window.title}`);
    this.canvas = c;
    this.ctx = c.getContext('2d', { alpha: false });
    this.el.appendChild(c);
    this.wireMouse(c);
    c.addEventListener('keydown', (e) => this.keyDown(e));
    if (!window.VideoDecoder) {
      queueMicrotask(() => this.showNotice("This browser can't decode the video. Panes Web needs WebCodecs (a recent Chrome, Edge or Safari, over HTTPS)."));
    }
  }

  setVideoFormat(sets) {
    const codec = avcCodecString(sets);
    const description = avcC(sets);
    if (!codec || !description) return console.warn('panes: no SPS in video format');
    this.videoConfig = { codec, description, optimizeForLatency: true, hardwareAcceleration: 'no-preference' };
    this.resetDecoder();
  }

  /// A new decoder for the current format. Nothing decodes until the next keyframe.
  resetDecoder() {
    if (this.decoder && this.decoder.state !== 'closed') try { this.decoder.close(); } catch { /* closed */ }
    this.decoder = null;
    this.waitingForKeyframe = true;
    if (!this.videoConfig || !window.VideoDecoder) return;
    const d = new VideoDecoder({
      output: (frame) => this.showFrame(frame),
      error: (e) => {
        console.warn('panes: video decoder failed', e);
        if (this.decoder === d) this.decoderFailed();
      },
    });
    try {
      d.configure(this.videoConfig);
      this.decoder = d;
    } catch (e) {
      console.warn('panes: video format not supported', e);
      this.showNotice(`This browser can't decode this video (${this.videoConfig.codec}).`);
    }
  }

  /// Starts again from a fresh keyframe, which the agent sends when asked.
  decoderFailed() {
    this.resetDecoder();
    this.link?.send({ op: 'keyframe' });
  }

  decodeFrame(f) {
    const d = this.decoder;
    if (!d || d.state !== 'configured') return;
    if (this.waitingForKeyframe && !f.keyframe) return;
    this.waitingForKeyframe = false;
    try {
      d.decode(new EncodedVideoChunk({ type: f.keyframe ? 'key' : 'delta', timestamp: f.pts, data: f.avcc }));
    } catch (e) {
      console.warn('panes: decode failed', e);
      this.decoderFailed();
    }
  }

  /// Keeps only the newest frame (for redrawing on resize); the one before is closed at once.
  showFrame(frame) {
    this.frame?.close();
    this.frame = frame;
    this.framesDecoded++;
    if (!this.drawPending) {
      this.drawPending = true;
      requestAnimationFrame(() => {
        this.drawPending = false;
        this.draw();
      });
    }
  }

  /// Where the video sits in the canvas, in CSS px (letterboxed to the window's shape).
  get videoRect() {
    const w = this.canvas.clientWidth;
    const h = this.canvas.clientHeight;
    const content = this.frame
      ? { width: this.frame.displayWidth, height: this.frame.displayHeight }
      : this.windowSize || { width: w, height: h };
    return aspectFit(content, { x: 0, y: 0, width: w, height: h });
  }

  draw() {
    const c = this.canvas;
    if (!c || this.el.hidden) return;
    const dpr = window.devicePixelRatio || 1;
    const w = Math.round(c.clientWidth * dpr);
    const h = Math.round(c.clientHeight * dpr);
    if (c.width !== w || c.height !== h) {
      c.width = w;
      c.height = h;
    }
    this.ctx.fillStyle = '#000';
    this.ctx.fillRect(0, 0, w, h);
    if (!this.frame) return;
    const r = this.videoRect;
    this.ctx.imageSmoothingQuality = 'high';
    this.ctx.drawImage(this.frame, r.x * dpr, r.y * dpr, r.width * dpr, r.height * dpr);
  }

  point(e) {
    const b = this.canvas.getBoundingClientRect();
    return { x: e.clientX - b.left, y: e.clientY - b.top };
  }

  /// Mouse to Mac input: a press that doesn't move is a click (the browser
  /// counts double-clicks), one that moves is a drag; hovering moves the pointer.
  wireMouse(c) {
    let press = null;
    let lastMove = 0;

    c.addEventListener('mousedown', (e) => {
      if (e.button !== 0) return;
      e.preventDefault();
      c.focus({ preventScroll: true });
      press = { start: this.point(e), moved: false, mods: modsFor(e, isMac) };
      const move = (ev) => {
        const p = this.point(ev);
        if (!press.moved) {
          if (Math.hypot(p.x - press.start.x, p.y - press.start.y) <= DRAG_SLOP) return;
          press.moved = true;
          const s = clampedNormalized(press.start, this.videoRect);
          this.send({ kind: 'down', x: s.x, y: s.y, mods: press.mods });
        }
        const n = clampedNormalized(p, this.videoRect);
        this.send({ kind: 'drag', x: n.x, y: n.y });
      };
      const up = (ev) => {
        window.removeEventListener('mousemove', move, true);
        window.removeEventListener('mouseup', up, true);
        const p = this.point(ev);
        if (press.moved) {
          const n = clampedNormalized(p, this.videoRect);
          this.send({ kind: 'up', x: n.x, y: n.y });
        } else {
          const n = normalized(p, this.videoRect);
          if (n) this.send({ kind: 'click', x: n.x, y: n.y, clicks: Math.max(1, ev.detail || 1), mods: press.mods });
        }
        press = null;
      };
      window.addEventListener('mousemove', move, true);
      window.addEventListener('mouseup', up, true);
    });

    c.addEventListener('mousemove', (e) => {
      if (press || e.buttons) return;
      const now = performance.now();
      if (now - lastMove < MOVE_INTERVAL) return;
      const n = normalized(this.point(e), this.videoRect);
      if (!n) return;
      lastMove = now;
      this.send({ kind: 'move', x: n.x, y: n.y });
    });

    c.addEventListener('contextmenu', (e) => {
      e.preventDefault();
      c.focus({ preventScroll: true });
      const n = normalized(this.point(e), this.videoRect);
      if (n) this.send({ kind: 'rightClick', x: n.x, y: n.y, mods: modsFor(e, isMac) });
    });

    // Same as the phone's two-finger drag: content follows, so a wheel turned
    // down (positive deltaY, like a finger moving up) sends a negative dy.
    c.addEventListener('wheel', (e) => {
      e.preventDefault();
      const r = this.videoRect;
      if (!(r.width > 0)) return;
      const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? r.height : 1;
      const at = clampedNormalized(this.point(e), r);
      this.send({ kind: 'scroll', x: at.x, y: at.y, dx: (-e.deltaX * unit) / r.width, dy: (-e.deltaY * unit) / r.height });
    }, { passive: false });
  }

  keyDown(e) {
    // Paste is left to the browser, so the paste event brings this computer's clipboard.
    if (isPasteShortcut(e, isMac)) return;
    const ev = keyEvent(e, isMac);
    if (!ev) return;
    e.preventDefault();
    this.send(ev);
  }

  paste(e) {
    const text = e.clipboardData?.getData('text/plain');
    e.preventDefault();
    if (text) this.send({ kind: 'text', text });
    else this.send({ kind: 'key', key: 'v', mods: ['cmd'] });
  }

  // MARK: terminal tabs

  buildTerminal() {
    const box = document.createElement('div');
    box.className = 'term';
    this.el.appendChild(box);
    this.term = new window.Terminal({
      cursorBlink: true,
      fontFamily: 'ui-monospace, "SF Mono", Menlo, Consolas, "DejaVu Sans Mono", monospace',
      fontSize: 13,
      scrollback: 5000,
      theme: {
        background: '#000000',
        foreground: '#e5e5ea',
        cursor: '#e5e5ea',
        selectionBackground: 'rgba(10, 132, 255, 0.4)',
      },
    });
    this.fitAddon = new window.FitAddon.FitAddon();
    this.term.loadAddon(this.fitAddon);
    this.term.open(box);
    this.term.onData((s) => this.link?.sendRaw(FrameType.terminal, utf8.encode(s)));
    this.term.onBinary((s) => this.link?.sendRaw(FrameType.terminal, Uint8Array.from(s, (ch) => ch.charCodeAt(0) & 0xff)));
    this.term.onResize(({ cols, rows }) => {
      if (this.status === 'live') this.link?.send({ op: 'resize', cols, rows });
    });
    this.term.onTitleChange((t) => { if (t) this.title = t; });
  }

  fitTerminal() {
    if (this.el.hidden || !this.fitAddon) return;
    try { this.fitAddon.fit(); } catch { /* not laid out yet */ }
  }

  // MARK: app tabs

  buildApp() {
    this.frameEl = document.createElement('iframe');
    this.frameEl.allow = 'clipboard-read; clipboard-write; autoplay';
    this.frameEl.title = this.kind.app.name;
    this.el.appendChild(this.frameEl);
  }

  /// The agent's url is relative (/xpra/<session>/…); it's served from the machine's web address.
  showApp(url) {
    const full = new URL(url, this.machine.web).href;
    // Same session as before (a reconnect) keeps the page as it is.
    if (full === this.appURL) return;
    this.appURL = full;
    this.frameEl.src = full;
  }
}

// MARK: store

class Store {
  constructor() {
    this.tabs = [];
    this.selected = null;
  }

  get current() { return this.tabs.find((t) => t.id === this.selected) || null; }

  openWindow(window, machine, opts) { this.add(new PaneTab(this, machine, { type: 'window', window }, opts)); }

  openTerminal(machine) { this.add(new PaneTab(this, machine, { type: 'terminal', session: newSessionName() })); }

  openApp(app, machine) { this.add(new PaneTab(this, machine, { type: 'app', app, session: newSessionName() })); }

  add(tab, { select = true } = {}) {
    this.tabs.push(tab);
    if (select) this.select(tab.id);
    tab.connect();
    this.persist();
  }

  select(id) {
    this.selected = id;
    for (const t of this.tabs) t.setActive(t.id === id && !document.hidden);
    this.render();
    this.persist();
  }

  close(tab) {
    tab.end();
    // Give the "end" a moment to go out before the socket closes.
    setTimeout(() => tab.close(), 300);
    tab.el.hidden = true;
    this.tabs = this.tabs.filter((t) => t !== tab);
    if (this.selected === tab.id) this.selected = this.tabs.at(-1)?.id ?? null;
    if (this.selected) this.select(this.selected);
    this.render();
    this.persist();
  }

  persist() {
    save('panes.tabs', {
      tabs: this.tabs.map((t) => t.toJSON()),
      selected: this.tabs.findIndex((t) => t.id === this.selected),
    });
  }

  restore(machines) {
    const saved = load('panes.tabs', null);
    if (!saved || !Array.isArray(saved.tabs)) return;
    for (const s of saved.tabs) {
      const machine = machines.find((m) => m.name === s.machine);
      if (!machine) continue;
      let kind = null;
      if (s.kind === 'window' && s.window) kind = { type: 'window', window: s.window };
      if (s.kind === 'terminal' && s.session) kind = { type: 'terminal', session: s.session };
      if (s.kind === 'app' && s.app && s.session) kind = { type: 'app', app: s.app, session: s.session };
      if (kind) this.add(new PaneTab(this, machine, kind, { fit: s.fit, audio: s.audio }), { select: false });
    }
    const pick = this.tabs[saved.selected] || this.tabs.at(-1);
    if (pick) this.select(pick.id);
  }

  render() {
    const strip = $('tabs');
    strip.replaceChildren(...this.tabs.map((t) => this.chip(t)));
    $('empty').hidden = this.tabs.length > 0;
  }

  chip(tab) {
    const chip = document.createElement('div');
    chip.className = 'chip';
    chip.setAttribute('role', 'tab');
    chip.setAttribute('aria-selected', String(tab.id === this.selected));
    chip.dataset.status = tab.status;
    chip.title = `${tab.title} — ${tab.machine.name}`;
    chip.onclick = () => this.select(tab.id);
    const dot = document.createElement('span');
    dot.className = `dot ${tab.status}`;
    const names = document.createElement('span');
    names.className = 'names';
    const app = document.createElement('span');
    app.className = 'app';
    app.textContent = tab.appName;
    const machine = document.createElement('span');
    machine.className = 'machine';
    machine.textContent = tab.machine.name;
    names.append(app, machine);
    const x = document.createElement('button');
    x.className = 'x';
    x.textContent = '✕';
    x.setAttribute('aria-label', `Close ${tab.appName}`);
    x.onclick = (e) => {
      e.stopPropagation();
      this.close(tab);
    };
    chip.append(dot, names, x);
    return chip;
  }
}

// MARK: picker

/// A short-lived connection that asks a machine what it offers, like the phone's WindowList.
class Picker {
  constructor(store, machines) {
    this.store = store;
    this.machines = machines;
    this.state = { windows: [], apps: [], features: [], loading: false, problem: null };
    const select = $('machine');
    for (const m of machines) select.append(new Option(m.name, m.name));
    select.value = load('panes.machine', machines[0]?.name) || machines[0]?.name;
    if (select.selectedIndex < 0) select.selectedIndex = 0;
    select.onchange = () => {
      save('panes.machine', select.value);
      this.load();
    };
    $('fit').checked = load('panes.fit', true);
    $('audio').checked = load('panes.audio', true);
    $('fit').onchange = () => save('panes.fit', $('fit').checked);
    $('audio').onchange = () => save('panes.audio', $('audio').checked);
    $('pickerClose').onclick = () => this.hide();
    $('pickerRefresh').onclick = () => this.load();
    $('picker').addEventListener('click', (e) => { if (e.target === $('picker')) this.hide(); });
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && !$('picker').hidden) this.hide();
    });
  }

  get machine() { return this.machines.find((m) => m.name === $('machine').value) || this.machines[0]; }

  show() {
    $('picker').hidden = false;
    this.load();
  }

  hide() {
    $('picker').hidden = true;
    this.link?.close();
    this.link = null;
    clearTimeout(this.timer);
    this.store.current?.focus();
  }

  load() {
    this.link?.close();
    clearTimeout(this.timer);
    const machine = this.machine;
    if (!machine) {
      this.state = { windows: [], apps: [], features: [], loading: false, problem: 'No machines in machines.json.' };
      return this.render();
    }
    this.state = { windows: [], apps: [], features: [], loading: true, problem: null };
    this.render();
    let waiting = 0;
    const done = () => {
      if (--waiting > 0) return;
      this.state.loading = false;
      clearTimeout(this.timer);
      link.close();
      this.render();
    };
    const link = new Link(machine, (e) => {
      if (this.link !== link) return;
      if (e.type === 'ready') {
        link.send({ op: 'hello', version: WIRE_VERSION });
      } else if (e.type === 'control') {
        const msg = e.msg;
        if (msg.op === 'hello') {
          // Older agents didn't say; they only did windows.
          this.state.features = msg.features || ['windows'];
          if (this.state.features.includes('windows')) { waiting++; link.send({ op: 'list' }); }
          if (this.state.features.includes('apps')) { waiting++; link.send({ op: 'apps' }); }
          if (!waiting) { waiting = 1; done(); }
          this.render();
        } else if (msg.op === 'windows') {
          this.state.windows = msg.windows || [];
          done();
        } else if (msg.op === 'apps') {
          this.state.apps = msg.apps || [];
          done();
        } else if (msg.op === 'error') {
          this.state.problem = msg.error;
          this.render();
        }
      } else if (e.type === 'failed' && this.state.loading) {
        this.state.loading = false;
        this.state.problem = `Couldn't reach ${machine.name}. Is Tailscale on?`;
        this.render();
      }
    });
    this.link = link;
    link.connect();
    this.timer = setTimeout(() => {
      if (this.link !== link || !this.state.loading) return;
      link.close();
      this.state.loading = false;
      this.state.problem = `Couldn't reach ${machine.name}. Is Tailscale on?`;
      this.render();
    }, 8000);
  }

  render() {
    const s = this.state;
    const machine = this.machine;
    const windows = s.features.includes('windows');
    $('windowOptions').hidden = !windows;
    $('fitNote').hidden = !windows;
    const out = [];
    const el = (tag, cls, text) => {
      const n = document.createElement(tag);
      if (cls) n.className = cls;
      if (text !== undefined) n.textContent = text;
      return n;
    };
    const section = (title, rows, footer) => {
      if (title) out.push(el('div', 'section-title', title));
      const g = el('div', 'group');
      g.append(...rows);
      out.push(g);
      if (footer) out.push(el('p', 'footnote', footer));
    };

    if (s.features.includes('terminal')) {
      const b = el('button', 'row', 'New terminal');
      b.dataset.action = 'terminal';
      b.onclick = () => { this.hide(); this.store.openTerminal(machine); };
      section(null, [b], `Runs in tmux on ${machine.name}, so it keeps going when you close the page.`);
    }
    if (s.loading) {
      const l = el('div', 'loading');
      l.append(el('div', 'spinner'), el('span', null, `Asking ${machine.name} what it has open…`));
      out.push(l);
    }
    if (s.problem) out.push(el('p', 'problem', s.problem));
    if (s.apps.length) {
      section('Apps', s.apps.map((a) => {
        const b = el('button', 'row', a.name);
        b.dataset.app = a.id;
        b.onclick = () => { this.hide(); this.store.openApp(a, machine); };
        return b;
      }), `Each app runs in its own session on ${machine.name} and keeps running when you leave.`);
    }
    const groups = new Map();
    for (const w of s.windows) {
      if (!groups.has(w.app)) groups.set(w.app, []);
      groups.get(w.app).push(w);
    }
    const names = [...groups.keys()].sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()));
    for (const app of names) {
      section(app, groups.get(app).map((w) => {
        const b = el('button', 'row window');
        b.dataset.windowId = String(w.id);
        b.append(el('span', 'title', w.title || '(untitled)'), el('span', 'size', `${Math.round(w.width)} × ${Math.round(w.height)}`));
        b.onclick = () => {
          this.hide();
          this.store.openWindow(w, machine, { fit: $('fit').checked, audio: $('audio').checked });
        };
        return b;
      }));
    }
    $('pickerContent').replaceChildren(...out);
  }
}

// MARK: start

async function start() {
  let machines = [];
  try {
    const r = await fetch('machines.json', { cache: 'no-store' });
    machines = (await r.json()).filter((m) => m && m.name && m.web);
  } catch (e) {
    console.warn('panes: no machines.json', e);
  }
  const store = new Store();
  const picker = new Picker(store, machines);
  $('add').onclick = () => picker.show();
  $('emptyOpen').onclick = () => picker.show();

  // Paste brings this computer's clipboard to the focused window tab as typing.
  document.addEventListener('paste', (e) => {
    const t = store.current;
    if (t && t.canvas && document.activeElement === t.canvas) t.paste(e);
  });
  // A hidden browser tab pauses its window stream too, like a background tab.
  document.addEventListener('visibilitychange', () => {
    if (store.selected) store.select(store.selected);
  });

  store.render();
  store.restore(machines);
  // For tests and debugging in the console.
  window.panes = { store, picker, machines, audioContext: () => audioContext };
}

start();
