// Panes Web: the phone app's tabs in a desktop browser, laid out like a
// browser's (docs/UI.md, direction A). Each tab has its own WebSocket to a
// machine's agent, carrying the same frames as the phone's TCP connection
// (see docs/WEB.md and Shared/Wire.swift).
import {
  FrameType, WIRE_VERSION, encodeControl, encodeFrame, parseFrames, decodeControl,
  parseVideoFormat, parseVideoFrame, parseAudioFormat, parseAudioFrame,
  avcCodecString, avcC, aacConfig, aspectFit, normalized, clampedNormalized,
  keyEvent, modsFor, isPasteShortcut, newSessionName,
} from './wire.js';

const $ = (id) => document.getElementById(id);
const utf8 = new TextEncoder();
// userAgentData says "macOS", navigator.platform "MacIntel".
const isMac = /mac|iphone|ipad/i.test(navigator.userAgentData?.platform || navigator.platform || '');

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

  /// The tab as other devices see it (a TabRef in docs/UI.md).
  ref() {
    const k = this.kind;
    return {
      machine: this.machine.name,
      kind: k.type,
      app: this.appName,
      title: this.title || undefined,
      windowID: k.type === 'window' && k.window.id ? k.window.id : undefined,
      session: k.session,
      // A Mac window carries its app's bundle id, so a later visit can start the app.
      appID: k.type === 'app' ? k.app.id : k.type === 'window' ? k.window.bundleID || undefined : undefined,
    };
  }

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
    // Hidden, not removed: the element keeps its size and its last picture.
    this.el.classList.toggle('active', on);
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
      if (!k.window.id && k.window.bundleID) {
        // A Mac app that may not be running: the agent starts it and streams its window.
        this.link.send({ op: 'openApp', app: k.window.bundleID, viewport, zoom: 1.0, audio: this.audioOn });
      } else {
        this.link.send({ op: 'open', windowID: k.window.id, viewport, zoom: 1.0, audio: this.audioOn });
      }
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
        // A started app's window: from now on (reconnects, other devices) it's that window.
        if (msg.windowID && this.kind.type === 'window' && !this.kind.window.id) {
          this.kind.window.id = msg.windowID;
          if (msg.title) this.kind.window.title = msg.title;
          this.store.persist();
        }
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
    if (!c || !this.el.isConnected) return;
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
      fontFamily: '"JetBrains Mono", ui-monospace, "SF Mono", Menlo, Consolas, "DejaVu Sans Mono", monospace',
      fontSize: 13,
      scrollback: 5000,
      theme: {
        background: '#000000',
        foreground: '#F2F3F5',
        cursor: '#F2F3F5',
        selectionBackground: 'rgba(138, 184, 255, 0.35)',
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
    this.term.onTitleChange((t) => {
      if (!t) return;
      this.title = t;
      this.store.render();
    });
  }

  fitTerminal() {
    if (!this.fitAddon || !this.el.isConnected) return;
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

// MARK: machines

const NO_COLOR = '#A3A8B3';

/// The machine's colour from machines.json (docs/UI.md), or grey.
function colorOf(machine) {
  const c = machine?.color;
  return typeof c === 'string' && /^#[0-9a-f]{3}([0-9a-f]{3})?$/i.test(c) ? c : NO_COLOR;
}

function el(tag, cls, text) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text !== undefined) n.textContent = text;
  return n;
}

function dot(machine) {
  const d = el('span', 'dot');
  d.style.setProperty('--machine', colorOf(machine));
  d.setAttribute('aria-hidden', 'true');
  return d;
}

/// A short-lived connection: hello, then `start(link, features, finish)` asks
/// what it needs and `control(msg, finish)` reads the answers. Resolves with
/// what finish() is given, or {failed} if the machine can't be reached in time.
function ask(machine, { start, control = () => {}, timeout = 8000 }) {
  return new Promise((resolve) => {
    let over = false;
    let timer = null;
    const link = new Link(machine, (e) => {
      if (over) return;
      if (e.type === 'ready') {
        link.send({ op: 'hello', version: WIRE_VERSION });
      } else if (e.type === 'control') {
        // Older agents didn't list features; they only did windows.
        if (e.msg.op === 'hello') start(link, e.msg.features || ['windows'], finish);
        else control(e.msg, finish);
      } else if (e.type === 'failed') {
        finish({ failed: true, why: e.why });
      }
    });
    function finish(result) {
      if (over) return;
      over = true;
      clearTimeout(timer);
      link.close();
      resolve(result);
    }
    timer = setTimeout(() => finish({ failed: true, why: 'timeout' }), timeout);
    link.connect();
  });
}

/// What one machine offers: its windows (a Mac), terminals, its apps (Linux).
function catalogOf(machine) {
  const got = { windows: [], apps: [], features: [], problem: null };
  let waiting = 0;
  return ask(machine, {
    start(link, features, finish) {
      got.features = features;
      if (features.includes('windows')) { waiting++; link.send({ op: 'list' }); }
      if (features.includes('apps')) { waiting++; link.send({ op: 'apps' }); }
      if (!waiting) finish(got);
    },
    control(msg, finish) {
      if (msg.op === 'windows') got.windows = msg.windows || [];
      else if (msg.op === 'apps') got.apps = msg.apps || [];
      else if (msg.op === 'error') {
        got.problem = msg.error || 'Something went wrong.';
        // A failed list is its answer; other errors (permissions) come on top of one.
        if (!/list windows/i.test(got.problem)) return;
      } else return;
      if (--waiting <= 0) finish(got);
    },
  });
}

// MARK: store

/// Same tab? Windows by id, terminals and apps by session (docs/UI.md: opening
/// one elsewhere uses the same window or session).
function sameRef(a, b) {
  if (a.machine !== b.machine || a.kind !== b.kind) return false;
  if (a.kind === 'window') return a.windowID != null && a.windowID === b.windowID;
  if (a.session || b.session) return a.session === b.session;
  return a.appID === b.appID;
}

class Store {
  constructor(machines) {
    this.machines = machines;
    this.tabs = [];
    this.selected = null;
    this.onChange = () => {};
  }

  get current() { return this.tabs.find((t) => t.id === this.selected) || null; }

  machineNamed(name) { return this.machines.find((m) => m.name === name) || null; }

  options() { return { fit: load('panes.fit', true), audio: load('panes.audio', true) }; }

  openWindow(window, machine, opts = this.options(), how) { return this.add(new PaneTab(this, machine, { type: 'window', window }, opts), how); }

  openTerminal(machine, session = newSessionName(), how) { return this.add(new PaneTab(this, machine, { type: 'terminal', session }), how); }

  openApp(app, machine, session = newSessionName(), how) { return this.add(new PaneTab(this, machine, { type: 'app', app, session }), how); }

  /// The open tab matching a TabRef, if any.
  find(ref) { return this.tabs.find((t) => sameRef(t.ref(), ref)) || null; }

  /// Opens a TabRef (from another device, or Recent) as a tab, or switches to it.
  openRef(ref, { select = true } = {}) {
    const open = this.find(ref);
    if (open) {
      if (select) this.select(open.id);
      return open;
    }
    const machine = this.machineNamed(ref.machine);
    if (!machine) return null;
    const how = { select };
    if (ref.kind === 'window' && ref.windowID != null) {
      return this.openWindow({ id: ref.windowID, app: ref.app, title: ref.title || '', bundleID: ref.appID }, machine, this.options(), how);
    }
    if (ref.kind === 'window' && ref.appID) {
      return this.openWindow({ id: 0, app: ref.app, title: ref.app, bundleID: ref.appID }, machine, this.options(), how);
    }
    if (ref.kind === 'terminal') return this.openTerminal(machine, ref.session || newSessionName(), how);
    if (ref.kind === 'app' && ref.appID) return this.openApp({ id: ref.appID, name: ref.app }, machine, ref.session || newSessionName(), how);
    return null;
  }

  add(tab, { select = true } = {}) {
    this.tabs.push(tab);
    if (select) this.select(tab.id);
    else this.render();
    tab.connect();
    this.persist();
    return tab;
  }

  select(id) {
    this.selected = id;
    for (const t of this.tabs) t.setActive(t.id === id && !document.hidden);
    this.render();
    this.persist();
    $('tabs').querySelector('[aria-selected="true"]')?.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  }

  /// Set by start(): whether another device lists this tab as open.
  sharedElsewhere() { return false; }

  /// The next (+1) or previous (-1) tab, round the ends.
  step(by) {
    if (this.tabs.length < 2) return;
    const i = this.tabs.findIndex((t) => t.id === this.selected);
    this.select(this.tabs[(i + by + this.tabs.length) % this.tabs.length].id);
  }

  close(tab) {
    // A terminal or app another device still has open keeps running for it.
    if (!this.sharedElsewhere(tab.ref())) tab.end();
    // Give the "end" a moment to go out before the socket closes.
    setTimeout(() => tab.close(), 300);
    tab.el.classList.remove('active');
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
    const sig = JSON.stringify(this.tabs.map((t) => t.ref()));
    if (sig !== this.lastSig) {
      this.lastSig = sig;
      this.onChange();
    }
  }

  restore() {
    const saved = load('panes.tabs', null);
    if (!saved || !Array.isArray(saved.tabs)) return;
    for (const s of saved.tabs) {
      const machine = this.machineNamed(s.machine);
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

  /// A tab in the bar: dot, app, machine, close. The current one is raised
  /// with a line in its machine's colour.
  chip(tab) {
    const chip = el('div', 'tab');
    chip.setAttribute('role', 'tab');
    chip.setAttribute('aria-selected', String(tab.id === this.selected));
    chip.dataset.status = tab.status;
    chip.dataset.id = tab.id;
    chip.style.setProperty('--machine', colorOf(tab.machine));
    const state = tab.status === 'live' ? '' : tab.status === 'connecting' ? ' (connecting)' : tab.status === 'failed' ? ` (${tab.why})` : '';
    chip.title = `${tab.title || tab.appName} — ${tab.machine.name}${state}`;
    const open = el('button', 'open');
    open.onclick = () => this.select(tab.id);
    open.append(dot(tab.machine), el('span', 'app', tab.appName), el('span', 'machine', tab.machine.name));
    const x = el('button', 'x');
    x.setAttribute('aria-label', `Close ${tab.appName}`);
    x.innerHTML = '<svg aria-hidden="true" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M6 6l12 12M18 6L6 18"/></svg>';
    x.onclick = (e) => {
      e.stopPropagation();
      this.close(tab);
    };
    chip.append(open, x);
    return chip;
  }
}

// MARK: recent

const RECENT_MAX = 8;

/// The last things opened here, newest first, as TabRefs (terminals without
/// their session: picking one again opens a new terminal).
const Recent = {
  list() {
    const r = load('panes.recent', []);
    return Array.isArray(r) ? r.filter((x) => x && x.machine && x.kind && x.app) : [];
  },
  remember(ref) {
    const entry = { machine: ref.machine, kind: ref.kind, app: ref.app, title: ref.title, windowID: ref.windowID, appID: ref.appID };
    const key = (x) => [x.machine, x.kind, x.windowID ?? '', x.appID ?? ''].join('|');
    const list = [entry, ...this.list().filter((x) => key(x) !== key(entry))].slice(0, RECENT_MAX);
    save('panes.recent', list);
  },
};

// MARK: toast

const Toast = {
  show(text, onClick = null, ms = 4000) {
    const t = $('toast');
    t.textContent = text;
    t.hidden = false;
    t.classList.toggle('clickable', !!onClick);
    t.onclick = onClick ? () => { t.hidden = true; onClick(); } : null;
    t.tabIndex = onClick ? 0 : -1;
    t.onkeydown = onClick ? (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); t.onclick(); } } : null;
    clearTimeout(this.timer);
    this.timer = setTimeout(() => { t.hidden = true; }, ms);
  },
};

// MARK: palette

/// The command palette: one search over every machine at once (docs/UI.md, Search).
const APPS_SHOWN = 8;

class Palette {
  constructor(store, machines) {
    this.store = store;
    this.machines = machines;
    /// machine name → {loading, failed, windows, apps, features, problem}
    this.state = new Map();
    /// Machines whose full app list is showing.
    this.expanded = new Set();
    this.rows = [];
    this.selectedKey = null;
    this.generation = 0;
    const q = $('query');
    q.addEventListener('input', () => {
      this.selectedKey = null;
      this.moved = false;
      this.render();
    });
    q.addEventListener('keydown', (e) => this.key(e));
    $('palette').addEventListener('mousedown', (e) => { if (e.target === $('palette')) this.hide(); });
  }

  get open() { return !$('palette').hidden; }

  show() {
    if (this.open) return $('query').focus();
    $('palette').hidden = false;
    $('query').value = '';
    this.selectedKey = null;
    this.moved = false;
    this.load();
    $('query').focus();
  }

  hide() {
    if (!this.open) return;
    $('palette').hidden = true;
    this.generation++;
    this.store.current?.focus();
  }

  /// Asks every machine at once; each section fills in as its machine answers.
  load() {
    const gen = ++this.generation;
    for (const m of this.machines) {
      const before = this.state.get(m.name);
      // What it said last time stays up while it's asked again.
      this.state.set(m.name, { ...(before || { windows: [], apps: [], features: [] }), loading: true, failed: false });
      catalogOf(m).then((got) => {
        if (gen !== this.generation) return;
        this.state.set(m.name, got.failed
          ? { windows: [], apps: [], features: [], loading: false, failed: true }
          : { ...got, loading: false, failed: false });
        this.render();
      });
    }
    this.render();
  }

  /// Every row, in sections: Recent (empty search only), then one per machine.
  sections() {
    const query = $('query').value.trim().toLowerCase();
    const terms = query.split(/\s+/).filter(Boolean);
    const matches = (...fields) => {
      const hay = fields.filter(Boolean).join(' ').toLowerCase();
      return terms.every((t) => hay.includes(t));
    };
    const sections = [];
    const opened = (ref) => !!this.store.find(ref);

    if (!terms.length) {
      const rows = [];
      for (const r of Recent.list()) {
        const machine = this.store.machineNamed(r.machine);
        if (!machine) continue;
        const st = this.state.get(machine.name);
        let ref = r;
        if (r.kind === 'window') {
          // A window that's gone isn't offered; one still there uses its live title.
          const live = st && !st.loading && !st.failed ? st.windows.find((w) => w.id === r.windowID) : null;
          if (live) ref = { ...r, title: live.title, app: live.app };
          // A window that's gone: start its app again if we know it, else skip it.
          else if (st && !st.loading && !st.failed) {
            if (!r.appID) continue;
            ref = { machine: r.machine, kind: 'window', app: r.app, appID: r.appID };
          }
        }
        rows.push(this.refRow(machine, ref, 'recent'));
      }
      if (rows.length) sections.push({ title: 'Recent', rows });
    }

    for (const m of this.machines) {
      const st = this.state.get(m.name) || { windows: [], apps: [], features: [], loading: true };
      const rows = [];
      const windows = [...st.windows].sort((a, b) => (a.app || '').localeCompare(b.app || '', undefined, { sensitivity: 'base' })
        || (a.title || '').localeCompare(b.title || ''));
      for (const w of windows) {
        if (!matches(w.app, w.title, m.name)) continue;
        const ref = { machine: m.name, kind: 'window', app: w.app, title: w.title, windowID: w.id };
        rows.push({
          key: `${m.name}|window|${w.id}`, machine: m, app: w.app || 'Window', sub: `${m.name} · ${w.title || '(untitled)'}`,
          action: opened(ref) ? 'Switch to' : 'Open', ref,
          go: () => {
            const t = this.store.find(ref);
            if (t) this.store.select(t.id);
            else this.store.openWindow(w, m);
            Recent.remember(ref);
          },
        });
      }
      if (st.features.includes('terminal') && matches('New terminal', 'Terminal', 'tmux', m.name)) {
        rows.push({
          key: `${m.name}|terminal`, machine: m, app: 'New terminal', letter: 'T', sub: `${m.name} · tmux`, action: 'Open',
          go: () => {
            const t = this.store.openTerminal(m);
            Recent.remember(t.ref());
          },
        });
      }
      const mac = st.features.includes('windows');
      // With nothing typed, a machine shows its first few apps until "All N apps" is picked.
      const collapsed = !terms.length && !this.expanded.has(m.name) && st.apps.length > APPS_SHOWN;
      for (const a of collapsed ? st.apps.slice(0, APPS_SHOWN) : st.apps) {
        if (!matches(a.name, m.name)) continue;
        if (mac) {
          // Any installed Mac app, running or not: the agent starts it if needed.
          const ref = { machine: m.name, kind: 'window', app: a.name, appID: a.id };
          rows.push({
            key: `${m.name}|macapp|${a.id}`, machine: m, app: a.name, sub: `${m.name} · app`, action: 'Open', ref,
            go: () => {
              this.store.openWindow({ id: 0, app: a.name, title: a.name, bundleID: a.id }, m);
              Recent.remember(ref);
            },
          });
          continue;
        }
        const ref = { machine: m.name, kind: 'app', app: a.name, appID: a.id };
        const open = this.store.tabs.find((t) => t.machine === m && t.kind.type === 'app' && t.kind.app.id === a.id);
        rows.push({
          key: `${m.name}|app|${a.id}`, machine: m, app: a.name, sub: m.name, action: open ? 'Switch to' : 'Open', ref,
          go: () => {
            const t = this.store.tabs.find((x) => x.machine === m && x.kind.type === 'app' && x.kind.app.id === a.id);
            if (t) this.store.select(t.id);
            else this.store.openApp(a, m);
            Recent.remember(ref);
          },
        });
      }
      if (collapsed) {
        rows.push({
          key: `${m.name}|allapps`, machine: m, app: `All ${st.apps.length} apps`, letter: '…', sub: m.name, action: 'Show', more: true,
          go: () => { this.expanded.add(m.name); this.render(); },
        });
      }
      let status = null;
      if (st.failed) status = { problem: true, text: `Can't reach ${m.name}` };
      else if (st.loading && !rows.length) status = { loading: true, text: `Asking ${m.name}…` };
      else if (st.problem) status = { problem: true, text: st.problem };
      // While searching, machines with nothing to show stay out of the way.
      if (terms.length && !rows.length && !st.failed) continue;
      sections.push({ title: m.name, machine: m, rows, status });
    }
    return sections;
  }

  /// A Recent row: opens the same thing again (a window by id, an app, a new terminal).
  refRow(machine, ref, prefix) {
    const opened = ref.kind === 'terminal' ? null : this.store.find(ref)
      || (ref.kind === 'app' ? this.store.tabs.find((t) => t.machine === machine && t.kind.type === 'app' && t.kind.app.id === ref.appID) : null);
    const label = ref.kind === 'terminal' ? 'Terminal' : ref.app;
    const sub = ref.kind === 'terminal' ? `${machine.name} · tmux` : ref.title && ref.title !== ref.app ? `${machine.name} · ${ref.title}` : machine.name;
    return {
      key: `${prefix}|${machine.name}|${ref.kind}|${ref.windowID ?? ''}|${ref.appID ?? ''}`,
      machine, app: label, sub, action: opened ? 'Switch to' : 'Open', ref,
      go: () => {
        if (opened) this.store.select(opened.id);
        else if (ref.kind === 'terminal') this.store.openTerminal(machine);
        else this.store.openRef({ ...ref, session: undefined });
        Recent.remember(ref);
      },
    };
  }

  render() {
    if (!this.open) return;
    const sections = this.sections();
    this.rows = sections.flatMap((s) => s.rows);
    // Until the arrow keys or the mouse pick one, the first row is the one Enter opens,
    // even as machines answer and rows arrive above it.
    if (!this.moved || !this.rows.some((r) => r.key === this.selectedKey)) {
      this.selectedKey = this.rows[0]?.key ?? null;
      this.moved = false;
    }
    const out = [];
    for (const s of sections) {
      const group = el('div', 'section');
      group.setAttribute('role', 'group');
      const head = el('div', 'heading');
      if (s.machine) head.append(dot(s.machine));
      head.append(el('span', 'text', s.title));
      group.append(head);
      group.setAttribute('aria-label', s.title);
      if (s.machine) group.dataset.machine = s.machine.name;
      else group.dataset.section = 'recent';
      for (const r of s.rows) group.append(this.rowEl(r));
      if (s.status) {
        const line = el('div', 'status-line' + (s.status.problem ? ' problem' : ''));
        if (s.status.loading) line.append(el('span', 'spinner'));
        line.append(el('span', null, s.status.text));
        group.append(line);
      }
      out.push(group);
    }
    if (!this.rows.length && $('query').value.trim() && ![...this.state.values()].some((s) => s.loading)) {
      out.push(el('div', 'nothing', 'Nothing on your machines matches that.'));
    }
    $('results').replaceChildren(...out);
    this.markSelected();
  }

  rowEl(r) {
    const b = el('button', 'result');
    b.setAttribute('role', 'option');
    b.dataset.key = r.key;
    b.dataset.machine = r.machine.name;
    b.style.setProperty('--machine', colorOf(r.machine));
    const tile = el('span', 'tile', (r.letter || r.app || '?').charAt(0).toUpperCase());
    tile.setAttribute('aria-hidden', 'true');
    b.append(tile, el('span', 'app', r.app), el('span', 'sub', r.sub), el('span', 'action', r.action));
    b.onmousemove = () => {
      if (this.selectedKey === r.key) return;
      this.selectedKey = r.key;
      this.moved = true;
      this.markSelected(false);
    };
    b.onclick = () => this.pick(r);
    return b;
  }

  markSelected(scroll = true) {
    for (const b of $('results').querySelectorAll('.result')) {
      const on = b.dataset.key === this.selectedKey;
      b.setAttribute('aria-selected', String(on));
      if (on) {
        b.id = 'palette-selected';
        if (scroll) b.scrollIntoView({ block: 'nearest' });
      } else if (b.id) b.removeAttribute('id');
    }
    $('query').setAttribute('aria-activedescendant', this.selectedKey ? 'palette-selected' : '');
  }

  pick(r) {
    // "All N apps" grows the list in place; everything else opens something.
    if (!r.more) this.hide();
    r.go();
  }

  key(e) {
    const i = this.rows.findIndex((r) => r.key === this.selectedKey);
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      if (!this.rows.length) return;
      const by = e.key === 'ArrowDown' ? 1 : -1;
      const next = i < 0 ? 0 : (i + by + this.rows.length) % this.rows.length;
      this.selectedKey = this.rows[next].key;
      this.moved = true;
      this.markSelected();
    } else if (e.key === 'Enter') {
      e.preventDefault();
      if (i >= 0) this.pick(this.rows[i]);
    } else if (e.key === 'Escape') {
      e.preventDefault();
      this.hide();
    }
  }
}

// MARK: this device

/// "Chrome on macOS", like the phone's "iPhone".
function defaultDeviceName() {
  const ua = navigator.userAgent;
  const browser = /Edg\//.test(ua) ? 'Edge' : /Firefox\//.test(ua) ? 'Firefox' : /OPR\//.test(ua) ? 'Opera'
    : /Chrome\//.test(ua) ? 'Chrome' : /Safari\//.test(ua) ? 'Safari' : 'Browser';
  const os = /iPhone|iPad/.test(ua) ? 'iOS' : /Android/.test(ua) ? 'Android' : /Mac OS X|Macintosh/.test(ua) ? 'macOS'
    : /Windows/.test(ua) ? 'Windows' : /CrOS/.test(ua) ? 'ChromeOS' : /Linux/.test(ua) ? 'Linux' : '';
  return os ? `${browser} on ${os}` : browser;
}

/// Letters, digits, - and _, at most 64 (docs/UI.md). Made once and kept.
function deviceID() {
  const saved = load('panes.device.id', null);
  if (typeof saved === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(saved)) return saved;
  let id;
  if (crypto.randomUUID) id = crypto.randomUUID();
  else {
    const r = new Uint8Array(16);
    crypto.getRandomValues(r);
    id = [...r].map((b) => b.toString(16).padStart(2, '0')).join('');
  }
  save('panes.device.id', id);
  return id;
}

// MARK: other devices

/// Who's asking, for `devices` and `forget`. The protocol only needs the id,
/// but the Mac agent decodes `device` as a whole DeviceInfo and drops the
/// message without name, kind and tabs, so those go too (tabs left empty:
/// these ops don't change what the agent knows of our tabs).
function whoAmI(me) {
  return { id: me.id, name: me.name, kind: me.kind, tabs: [] };
}

const REPORT_EVERY = 15000;
/// The same send arriving from several machines is one send (docs/UI.md).
const REPEAT_WINDOW = 10 * 60;
const ARRIVED_KEEP = 7 * 24 * 3600;

/// Reports this browser's tabs to every machine, reads who else has checked
/// in, picks up tabs sent here, and sends tabs to others (docs/UI.md, protocol).
class Devices {
  constructor(store, machines) {
    this.store = store;
    this.machines = machines;
    this.me = { id: deviceID(), name: load('panes.device.name', null) || defaultDeviceName(), kind: 'browser' };
    /// machine name → the device list it last gave (everyone but us).
    this.lists = new Map();
    /// machine name → the report to it still going (a machine that's slow
    /// to answer never holds up the others).
    this.pending = new Map();
    this.again = new Set();
    this.onChange = () => {};
    this.reports = 0;
  }

  /// Every machine's list merged by id, keeping the newest `seen`, newest first.
  get list() {
    const merged = new Map();
    for (const devices of this.lists.values()) {
      for (const d of devices) {
        if (!d || !d.id || d.id === this.me.id) continue;
        const had = merged.get(d.id);
        if (!had || (d.seen || 0) > (had.seen || 0)) merged.set(d.id, d);
      }
    }
    return [...merged.values()].sort((a, b) => (b.seen || 0) - (a.seen || 0));
  }

  start() {
    this.report();
    this.timer = setInterval(() => { if (!document.hidden) this.report(); }, REPORT_EVERY);
    document.addEventListener('visibilitychange', () => { if (!document.hidden) this.report(); });
  }

  rename(name) {
    const clean = name.trim().slice(0, 60);
    this.me.name = clean || defaultDeviceName();
    save('panes.device.name', clean || null);
    this.report();
  }

  /// Tabs changed: tell the machines soon (several changes in a row go as one).
  changed() {
    clearTimeout(this.soon);
    this.soon = setTimeout(() => this.report(), 400);
  }

  /// To every machine at once: `device` (answered with our inbox), then
  /// `devices` (everyone else). Each machine's answer is used as it comes; one
  /// still going is asked again when it's done. Resolves when all have answered.
  report() {
    return Promise.all(this.machines.map((m) => this.reportTo(m)));
  }

  reportTo(m) {
    if (this.pending.has(m.name)) {
      this.again.add(m.name);
      return this.pending.get(m.name);
    }
    const device = { ...this.me, tabs: this.store.tabs.map((t) => t.ref()).slice(0, 60) };
    let sent = [];
    const p = ask(m, {
      start(link, features, finish) {
        if (!features.includes('devices')) return finish({ skipped: true });
        link.send({ op: 'device', device });
        link.send({ op: 'devices', device: whoAmI(device) });
      },
      control(msg, finish) {
        if (msg.op === 'inbox') sent = msg.sent || [];
        else if (msg.op === 'devices') finish({ sent, devices: msg.devices || [] });
      },
    }).then((r) => {
      if (r.devices) {
        this.lists.set(m.name, r.devices);
        this.reports++;
        this.arrived(r.sent);
        this.onChange();
      }
    }).finally(() => {
      this.pending.delete(m.name);
      if (this.again.delete(m.name)) this.reportTo(m);
    });
    this.pending.set(m.name, p);
    return p;
  }

  /// Tabs sent here. Each machine hands over its own copy, so repeats (same
  /// sender, same tab, sent at about the same time) are dropped.
  arrived(sent) {
    if (!sent.length) return;
    const now = Date.now() / 1000;
    const seen = load('panes.arrived', []).filter((s) => s && now - s.at < ARRIVED_KEEP);
    const key = (s) => s.from + '|' + JSON.stringify([s.tab.machine, s.tab.kind, s.tab.windowID ?? null, s.tab.session ?? null, s.tab.appID ?? null]);
    for (const s of [...sent].sort((a, b) => (a.at || 0) - (b.at || 0))) {
      if (!s || !s.tab || !s.tab.machine) continue;
      const k = key(s);
      if (seen.some((x) => x.key === k && Math.abs(x.at - (s.at || now)) < REPEAT_WINDOW)) continue;
      seen.push({ key: k, at: s.at || now });
      this.receive(s);
    }
    save('panes.arrived', seen.slice(-100));
  }

  /// Added at the end of the tabs without taking over the screen, with a notice that switches to it.
  receive(s) {
    const tab = this.store.openRef(s.tab, { select: false });
    if (!tab) return;
    Recent.remember(tab.ref());
    Toast.show(`${s.tab.app} arrived from ${s.from}`, () => {
      if (this.store.tabs.includes(tab)) this.store.select(tab.id);
    }, 8000);
  }

  /// Sends a tab to every machine for `to` to pick up. Each send is followed by
  /// a `devices` request, so an error for it (that device never checked in
  /// there) comes back first. True if any machine took it.
  send(to, ref) {
    return new Promise((resolve) => {
      let left = this.machines.length;
      if (!left) return resolve(false);
      for (const m of this.machines) {
        ask(m, {
          start: (link, features, finish) => {
            if (!features.includes('devices')) return finish({ skipped: true });
            link.send({ op: 'send', to: to.id, name: this.me.name, tab: ref });
            link.send({ op: 'devices', device: whoAmI(this.me) });
          },
          control(msg, finish) {
            if (msg.op === 'error') finish({ ok: false });
            else if (msg.op === 'devices') finish({ ok: true });
          },
        }).then((r) => {
          if (r.ok) resolve(true);
          if (--left === 0) resolve(false);
        });
      }
    });
  }

  /// Takes this device off every machine's list (for tests and tidying up).
  forget() {
    return Promise.all(this.machines.map((m) => ask(m, {
      start: (link, features, finish) => {
        if (!features.includes('devices')) return finish({ skipped: true });
        link.send({ op: 'forget', device: whoAmI(this.me) });
        link.send({ op: 'devices', device: whoAmI(this.me) });
      },
      control(msg, finish) { if (msg.op === 'devices') finish({ ok: true }); },
    })));
  }
}

/// The Other devices panel: their tabs (Open here / Switch), and "Send <app> to".
class DevicesPanel {
  constructor(store, devices, settings) {
    this.store = store;
    this.devices = devices;
    this.settings = settings;
    $('devicesButton').onclick = () => (this.open ? this.hide() : this.show());
    $('settingsButton').onclick = () => {
      this.hide();
      settings.show();
    };
    document.addEventListener('mousedown', (e) => {
      if (this.open && !$('devices').contains(e.target) && !$('devicesButton').contains(e.target)) this.hide();
    });
  }

  get open() { return !$('devices').hidden; }

  show() {
    this.settings.hide();
    $('devices').hidden = false;
    $('devicesButton').setAttribute('aria-expanded', 'true');
    this.render();
    this.devices.report();
  }

  hide() {
    if (!this.open) return;
    $('devices').hidden = true;
    $('devicesButton').setAttribute('aria-expanded', 'false');
  }

  render() {
    $('myName').textContent = this.devices.me.name;
    if (!this.open) return;
    const others = this.devices.list;
    const list = [];
    for (const d of others) {
      const card = el('div', 'device');
      card.dataset.device = d.id;
      const head = el('div', 'heading');
      head.append(el('span', 'text', d.name || 'Another device'));
      card.append(head);
      const tabs = (d.tabs || []).filter((t) => t && t.machine && t.kind && t.app);
      for (const ref of tabs) {
        const machine = this.store.machineNamed(ref.machine);
        const row = el('div', 'device-tab');
        row.append(dot(machine));
        const names = el('span', 'names', ref.app + ' ');
        names.append(el('span', 'machine', `· ${ref.machine}`));
        names.title = ref.title ? `${ref.app} — ${ref.title} · ${ref.machine}` : `${ref.app} · ${ref.machine}`;
        row.append(names);
        if (machine) {
          const here = this.store.find(ref);
          const b = el('button', 'pill', here ? 'Switch' : 'Open here');
          b.onclick = () => {
            this.hide();
            const t = this.store.openRef(ref);
            if (t) Recent.remember(t.ref());
          };
          row.append(b);
        }
        card.append(row);
      }
      if (!tabs.length) card.append(el('div', 'quiet', 'No tabs open'));
      list.push(card);
    }
    if (!others.length) {
      list.push(el('div', 'quiet', this.devices.reports
        ? 'No other devices yet. Open Panes on your phone or another computer and its tabs show up here.'
        : 'Looking for your other devices…'));
    }
    $('devicesList').replaceChildren(...list);

    const send = [];
    const cur = this.store.current;
    if (cur && others.length) {
      send.push(el('div', 'divider'));
      const head = el('div', 'heading');
      head.append(el('span', 'text', `Send ${cur.appName} to`));
      send.push(head);
      for (const d of others) {
        const b = el('button', 'menu-row send-to');
        b.dataset.device = d.id;
        b.innerHTML = '<svg aria-hidden="true" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="14" height="11" rx="2"/><path d="M8 19h4M14 13l7-7M15 6h6v6"/></svg>';
        b.append(el('span', null, d.name || 'Another device'));
        b.onclick = async () => {
          this.hide();
          const app = cur.appName;
          const ok = await this.devices.send(d, cur.ref());
          Toast.show(ok ? `Sent. ${app} is waiting in Panes on ${d.name}.` : `Couldn't send ${app} to ${d.name}. Is it still using Panes?`);
        };
        send.push(b);
      }
    }
    $('sendSection').replaceChildren(...send);
  }
}

/// This device's name, and how windows open.
class Settings {
  constructor(devices) {
    this.devices = devices;
    const name = $('deviceName');
    name.addEventListener('change', () => this.devices.rename(name.value));
    name.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        this.hide();
      }
    });
    $('fit').checked = load('panes.fit', true);
    $('audio').checked = load('panes.audio', true);
    $('fit').onchange = () => save('panes.fit', $('fit').checked);
    $('audio').onchange = () => save('panes.audio', $('audio').checked);
    $('settingsDone').onclick = () => this.hide();
    document.addEventListener('mousedown', (e) => {
      if (this.open && !$('settings').contains(e.target)) this.hide();
    });
  }

  get open() { return !$('settings').hidden; }

  show() {
    $('deviceName').value = this.devices.me.name;
    $('deviceName').placeholder = defaultDeviceName();
    $('settings').hidden = false;
    $('deviceName').focus();
    $('deviceName').select();
  }

  hide() {
    if (!this.open) return;
    // A name typed and then closed without Enter or leaving the field still counts.
    if ($('deviceName').value.trim() !== this.devices.me.name) this.devices.rename($('deviceName').value);
    $('settings').hidden = true;
  }
}

// MARK: keys

/// The page's own shortcuts, taken before the app sees them: ⌘K / Ctrl+K for
/// search, Ctrl+Tab and ⌘⇧] / ⌘⇧[ between tabs, Esc out of a popover.
/// Every other key still goes to the app.
function shortcut(e) {
  if (e.isComposing) return null;
  const k = e.code === 'KeyK' || e.key === 'k' || e.key === 'K';
  if (k && !e.shiftKey && !e.altKey && (isMac ? e.metaKey && !e.ctrlKey : e.ctrlKey && !e.metaKey)) return 'search';
  if (e.key === 'Tab' && e.ctrlKey && !e.metaKey && !e.altKey) return e.shiftKey ? 'previous' : 'next';
  if (isMac && e.metaKey && e.shiftKey && !e.ctrlKey && !e.altKey) {
    if (e.code === 'BracketRight' || e.key === '}' || e.key === ']') return 'next';
    if (e.code === 'BracketLeft' || e.key === '{' || e.key === '[') return 'previous';
  }
  return null;
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
  const keyLabel = isMac ? '⌘K' : 'Ctrl K';
  $('searchKey').textContent = keyLabel;
  $('emptyKey').textContent = isMac ? '⌘K' : 'Ctrl+K';
  // Terminals measure their font when they open, so it should be loaded first.
  try {
    await Promise.race([document.fonts.load('13px "JetBrains Mono"'), new Promise((r) => setTimeout(r, 1500))]);
  } catch { /* the fallback font is fine */ }

  const store = new Store(machines);
  const palette = new Palette(store, machines);
  const devices = new Devices(store, machines);
  const settings = new Settings(devices);
  const panel = new DevicesPanel(store, devices, settings);
  store.sharedElsewhere = (ref) => devices.list.some((d) => (d.tabs || []).some((t) => sameRef(t, ref)));
  store.onChange = () => {
    devices.changed();
    panel.render();
  };
  devices.onChange = () => panel.render();

  $('add').onclick = () => palette.show();
  $('search').onclick = () => palette.show();

  window.addEventListener('keydown', (e) => {
    const s = shortcut(e);
    if (s) {
      e.preventDefault();
      e.stopPropagation();
      if (s === 'search') {
        if (palette.open) palette.hide();
        else {
          panel.hide();
          settings.hide();
          palette.show();
        }
      } else if (!palette.open) {
        store.step(s === 'next' ? 1 : -1);
      }
      return;
    }
    if (e.key === 'Escape' && (panel.open || settings.open)) {
      e.preventDefault();
      e.stopPropagation();
      panel.hide();
      settings.hide();
      store.current?.focus();
    }
  }, { capture: true });

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
  store.restore();
  panel.render();
  devices.start();
  // For tests and debugging in the console.
  window.panes = { store, palette, devices, panel, settings, machines, Recent, audioContext: () => audioContext };
}

start();
