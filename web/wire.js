// The wire format, keys and geometry, ported from Shared/Wire.swift,
// Shared/Keys.swift and Shared/Geometry.swift. No DOM here, so it also
// runs under Node for the codec tests.

// Every message is [type: u8][length: u32 big-endian][payload].
export const FrameType = {
  control: 1,
  videoFormat: 2,
  videoFrame: 3,
  terminal: 4,
  audioFormat: 5,
  audioFrame: 6,
};

export const WIRE_VERSION = 1;
// Anything bigger is a corrupt stream, not a frame.
export const MAX_PAYLOAD = 32 * 1024 * 1024;

const utf8 = new TextEncoder();
const utf8Decoder = new TextDecoder();

export function encodeFrame(type, payload) {
  const out = new Uint8Array(5 + payload.length);
  out[0] = type;
  new DataView(out.buffer).setUint32(1, payload.length, false);
  out.set(payload, 5);
  return out;
}

// Swift's JSONEncoder leaves nil fields out, so undefined/null fields are dropped.
export function encodeControl(msg) {
  const clean = {};
  for (const [k, v] of Object.entries(msg)) if (v !== undefined && v !== null) clean[k] = v;
  return encodeFrame(FrameType.control, utf8.encode(JSON.stringify(clean)));
}

export function encodeTerminal(bytes) {
  return encodeFrame(FrameType.terminal, bytes);
}

/// Splits bytes into whole frames. A WebSocket message is normally exactly
/// one frame, but this also copes with several, like FrameReader does.
export function parseFrames(buffer) {
  const bytes = buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer);
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const frames = [];
  let i = 0;
  while (bytes.length - i >= 5) {
    const type = bytes[i];
    if (type < 1 || type > 6) throw new Error(`unknown frame type ${type}`);
    const len = view.getUint32(i + 1, false);
    if (len > MAX_PAYLOAD) throw new Error(`frame too large (${len})`);
    if (bytes.length - i - 5 < len) throw new Error('truncated frame');
    frames.push({ type, payload: bytes.subarray(i + 5, i + 5 + len) });
    i += 5 + len;
  }
  return frames;
}

export function decodeControl(payload) {
  return JSON.parse(utf8Decoder.decode(payload));
}

// [count: u8] then [len: u16][bytes] for each parameter set.
export function parseVideoFormat(p) {
  if (p.length < 1) return null;
  const count = p[0];
  const sets = [];
  let i = 1;
  for (let n = 0; n < count; n++) {
    if (i + 2 > p.length) return null;
    const len = (p[i] << 8) | p[i + 1];
    i += 2;
    if (i + len > p.length) return null;
    sets.push(p.slice(i, i + len));
    i += len;
  }
  return sets;
}

export function encodeVideoFormat(sets) {
  const total = 1 + sets.reduce((s, x) => s + 2 + x.length, 0);
  const p = new Uint8Array(total);
  p[0] = sets.length;
  let i = 1;
  for (const s of sets) {
    p[i] = s.length >> 8;
    p[i + 1] = s.length & 0xff;
    p.set(s, i + 2);
    i += 2 + s.length;
  }
  return encodeFrame(FrameType.videoFormat, p);
}

// Microsecond timestamps fit a double exactly for the next few centuries.
function u64(view, at) {
  return Number(view.getBigUint64(at, false));
}

function viewOf(p) {
  return new DataView(p.buffer, p.byteOffset, p.byteLength);
}

// [flags: u8][pts: u64 µs][AVCC data]; flags bit 0 marks a keyframe.
export function parseVideoFrame(p) {
  if (p.length < 9) return null;
  return { keyframe: (p[0] & 1) === 1, pts: u64(viewOf(p), 1), avcc: p.subarray(9) };
}

export function encodeVideoFrame(keyframe, pts, avcc) {
  const p = new Uint8Array(9 + avcc.length);
  p[0] = keyframe ? 1 : 0;
  viewOf(p).setBigUint64(1, BigInt(pts), false);
  p.set(avcc, 9);
  return encodeFrame(FrameType.videoFrame, p);
}

// [sampleRate: f64][channels: u32][framesPerPacket: u32][magic cookie]
export function parseAudioFormat(p) {
  if (p.length < 16) return null;
  const v = viewOf(p);
  return {
    sampleRate: v.getFloat64(0, false),
    channels: v.getUint32(8, false),
    framesPerPacket: v.getUint32(12, false),
    cookie: p.slice(16),
  };
}

export function encodeAudioFormat(f) {
  const cookie = f.cookie || new Uint8Array(0);
  const p = new Uint8Array(16 + cookie.length);
  const v = viewOf(p);
  v.setFloat64(0, f.sampleRate, false);
  v.setUint32(8, f.channels, false);
  v.setUint32(12, f.framesPerPacket, false);
  p.set(cookie, 16);
  return encodeFrame(FrameType.audioFormat, p);
}

// [pts: u64 µs][one AAC packet]
export function parseAudioFrame(p) {
  if (p.length <= 8) return null;
  return { pts: u64(viewOf(p), 0), packet: p.subarray(8) };
}

export function encodeAudioFrame(pts, packet) {
  const p = new Uint8Array(8 + packet.length);
  viewOf(p).setBigUint64(0, BigInt(pts), false);
  p.set(packet, 8);
  return encodeFrame(FrameType.audioFrame, p);
}

// MARK: H.264

const hex2 = (b) => b.toString(16).padStart(2, '0');

/// The parameter sets sorted into SPS (NAL type 7) and PPS (NAL type 8).
function splitSets(sets) {
  return {
    sps: sets.filter((s) => (s[0] & 0x1f) === 7),
    pps: sets.filter((s) => (s[0] & 0x1f) === 8),
  };
}

/// `avc1.` plus the SPS's profile, constraint and level bytes.
export function avcCodecString(sets) {
  const { sps } = splitSets(sets);
  if (!sps.length || sps[0].length < 4) return null;
  return 'avc1.' + hex2(sps[0][1]) + hex2(sps[0][2]) + hex2(sps[0][3]);
}

/// An AVCDecoderConfigurationRecord, which VideoDecoder takes as its description
/// so the frames can stay in the length-prefixed form the agent sends.
export function avcC(sets) {
  const { sps, pps } = splitSets(sets);
  if (!sps.length || sps[0].length < 4) return null;
  const parts = [1, sps[0][1], sps[0][2], sps[0][3], 0xff, 0xe0 | sps.length];
  for (const s of sps) parts.push(s.length >> 8, s.length & 0xff, ...s);
  parts.push(pps.length);
  for (const s of pps) parts.push(s.length >> 8, s.length & 0xff, ...s);
  return new Uint8Array(parts);
}

// MARK: AAC

const AAC_RATES = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350];

/// The 2-byte AudioSpecificConfig for AAC-LC: object type 2, the sample rate's
/// index in the standard table, and the channel count. Built here rather
/// than taken from Apple's magic cookie, which browsers don't read.
export function aacConfig(sampleRate, channels) {
  let index = AAC_RATES.indexOf(Math.round(sampleRate));
  if (index < 0) index = 3; // 48 kHz, what the agent sends
  const objectType = 2;
  return new Uint8Array([(objectType << 3) | (index >> 1), ((index & 1) << 7) | ((channels & 0xf) << 3)]);
}

// MARK: geometry

/// Where an aspect-fit video of `content` size sits inside `bounds`.
export function aspectFit(content, bounds) {
  if (!(content.width > 0 && content.height > 0)) return { ...bounds };
  const scale = Math.min(bounds.width / content.width, bounds.height / content.height);
  const width = content.width * scale;
  const height = content.height * scale;
  return {
    x: bounds.x + bounds.width / 2 - width / 2,
    y: bounds.y + bounds.height / 2 - height / 2,
    width,
    height,
  };
}

/// A point as 0...1 across the video, or null outside it.
export function normalized(p, rect) {
  if (!(rect.width > 0 && rect.height > 0)) return null;
  if (p.x < rect.x || p.y < rect.y || p.x > rect.x + rect.width || p.y > rect.y + rect.height) return null;
  return { x: (p.x - rect.x) / rect.width, y: (p.y - rect.y) / rect.height };
}

/// The same, clamped to the edge: a drag that leaves the video keeps going.
export function clampedNormalized(p, rect) {
  if (!(rect.width > 0 && rect.height > 0)) return { x: 0, y: 0 };
  const c = (v) => Math.min(Math.max(v, 0), 1);
  return { x: c((p.x - rect.x) / rect.width), y: c((p.y - rect.y) / rect.height) };
}

// MARK: keys

// KeyboardEvent.code → the names in Shared/Keys.swift. Letters and digits are added below.
const CODE_NAMES = {
  Enter: 'return', NumpadEnter: 'return', Tab: 'tab', Space: 'space', Backspace: 'delete',
  Escape: 'escape', Delete: 'forwardDelete', Home: 'home', End: 'end', PageUp: 'pageUp',
  PageDown: 'pageDown', ArrowLeft: 'left', ArrowRight: 'right', ArrowDown: 'down', ArrowUp: 'up',
  Minus: '-', Equal: '=', BracketLeft: '[', BracketRight: ']', Backslash: '\\', Semicolon: ';',
  Quote: "'", Comma: ',', Period: '.', Slash: '/', Backquote: '`',
};
for (let c = 65; c <= 90; c++) CODE_NAMES['Key' + String.fromCharCode(c)] = String.fromCharCode(c + 32);
for (let d = 0; d <= 9; d++) {
  CODE_NAMES['Digit' + d] = String(d);
  CODE_NAMES['Numpad' + d] = String(d);
}
for (let f = 1; f <= 12; f++) CODE_NAMES['F' + f] = 'f' + f;

// Keys that never type a character, so they always go as key presses.
const SPECIAL = new Set(['return', 'tab', 'delete', 'escape', 'forwardDelete', 'home', 'end', 'pageUp',
  'pageDown', 'left', 'right', 'down', 'up', 'f1', 'f2', 'f3', 'f4', 'f5', 'f6', 'f7', 'f8', 'f9',
  'f10', 'f11', 'f12']);

export function keyName(code) {
  return CODE_NAMES[code] || null;
}

/// The Mac modifiers for a browser event. On a Mac browser they match; on
/// anything else Ctrl becomes Cmd, so Ctrl+C copies in Mac apps.
export function modsFor(e, isMac) {
  const mods = [];
  if (isMac) {
    if (e.metaKey) mods.push('cmd');
    if (e.ctrlKey) mods.push('ctrl');
  } else if (e.ctrlKey) {
    mods.push('cmd');
  }
  if (e.altKey) mods.push('opt');
  if (e.shiftKey) mods.push('shift');
  return mods;
}

/// What a keydown should send to a Mac window, or null to leave it to the
/// browser. Plain typing goes as text (works on any Mac layout); special keys
/// and shortcuts go as key presses.
export function keyEvent(e, isMac) {
  if (e.isComposing || ['Shift', 'Control', 'Alt', 'Meta', 'CapsLock', 'Dead'].includes(e.key)) return null;
  // The Windows/Super key belongs to the local desktop, not the Mac.
  if (!isMac && e.metaKey) return null;
  const name = keyName(e.code);
  const mods = modsFor(e, isMac);
  const shortcut = mods.some((m) => m !== 'shift');
  if (name && SPECIAL.has(name)) return { kind: 'key', key: name, mods };
  if (!shortcut && [...e.key].length === 1) return { kind: 'text', text: e.key };
  if (name) return { kind: 'key', key: name, mods };
  return null;
}

/// Cmd+V on a Mac browser, Ctrl+V elsewhere: left to the browser so the
/// paste event can carry this computer's clipboard across.
export function isPasteShortcut(e, isMac) {
  if (e.code !== 'KeyV' || e.altKey) return false;
  return isMac ? e.metaKey && !e.ctrlKey : e.ctrlKey && !e.metaKey;
}

/// panes- plus 6 random [a-z0-9]: only sessions named like this can be ended
/// from a client, so it can never kill a tmux session the user made.
export function newSessionName() {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  const r = new Uint8Array(6);
  crypto.getRandomValues(r);
  return 'panes-' + [...r].map((b) => chars[b % chars.length]).join('');
}
