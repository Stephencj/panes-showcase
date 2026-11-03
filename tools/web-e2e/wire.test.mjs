// Byte-level checks of web/wire.js against the layouts in Shared/Wire.swift.
// Run: node tools/web-e2e/wire.test.mjs
import assert from 'node:assert/strict';
import * as W from '../../web/wire.js';

const hex = (b) => Buffer.from(b).toString('hex');
let passed = 0;
function test(name, fn) {
  fn();
  passed++;
  console.log('ok  ', name);
}

test('frame header is [type][u32 BE length]', () => {
  assert.equal(hex(W.encodeFrame(4, new Uint8Array([0x61, 0x62]))), '04000000026162');
});

test('control frames are JSON with nil fields left out', () => {
  const f = W.parseFrames(W.encodeControl({ op: 'open', windowID: 42, viewport: { width: 800, height: 600 }, zoom: 1.0, audio: true, app: undefined }));
  assert.equal(f.length, 1);
  assert.equal(f[0].type, 1);
  assert.deepEqual(W.decodeControl(f[0].payload), { op: 'open', windowID: 42, viewport: { width: 800, height: 600 }, zoom: 1, audio: true });
});

test('several frames in one buffer, and bad input', () => {
  const a = W.encodeFrame(4, new Uint8Array([1]));
  const b = W.encodeFrame(1, new TextEncoder().encode('{"op":"x"}'));
  const both = new Uint8Array([...a, ...b]);
  const f = W.parseFrames(both.buffer);
  assert.deepEqual(f.map((x) => x.type), [4, 1]);
  assert.throws(() => W.parseFrames(new Uint8Array([9, 0, 0, 0, 0])));
  assert.throws(() => W.parseFrames(new Uint8Array([1, 0, 0, 0, 5, 1])));
});

test('videoFormat: [count][u16 len][bytes]...', () => {
  const sps = new Uint8Array([0x67, 0x64, 0x00, 0x1f, 0xac]);
  const pps = new Uint8Array([0x68, 0xee, 0x3c, 0x80]);
  const frame = W.encodeVideoFormat([sps, pps]);
  assert.equal(hex(frame), '02' + '0000000e' + '02' + '0005' + '6764001fac' + '0004' + '68ee3c80');
  const sets = W.parseVideoFormat(W.parseFrames(frame)[0].payload);
  assert.deepEqual(sets.map(hex), [hex(sps), hex(pps)]);
  assert.equal(W.parseVideoFormat(new Uint8Array([2, 0, 5, 1])), null);
});

test('avcC and codec string from SPS/PPS', () => {
  const sps = new Uint8Array([0x67, 0x64, 0x00, 0x1f, 0xac]);
  const pps = new Uint8Array([0x68, 0xee, 0x3c, 0x80]);
  assert.equal(W.avcCodecString([sps, pps]), 'avc1.64001f');
  // PPS first still finds the SPS.
  assert.equal(W.avcCodecString([pps, sps]), 'avc1.64001f');
  assert.equal(hex(W.avcC([sps, pps])), '0164001fffe1' + '0005' + '6764001fac' + '01' + '0004' + '68ee3c80');
  assert.equal(W.avcC([pps]), null);
});

test('videoFrame: [flags][u64 BE pts][avcc]', () => {
  const avcc = new Uint8Array([0, 0, 0, 1, 0x65]);
  const frame = W.encodeVideoFrame(true, 1234567890123, avcc);
  assert.equal(hex(frame.subarray(5, 14)), '01' + '0000011f71fb04cb');
  const v = W.parseVideoFrame(W.parseFrames(frame)[0].payload);
  assert.equal(v.keyframe, true);
  assert.equal(v.pts, 1234567890123);
  assert.equal(hex(v.avcc), hex(avcc));
  assert.equal(W.parseVideoFrame(new Uint8Array(8)), null);
});

test('audioFormat: [f64 rate][u32 channels][u32 frames][cookie]', () => {
  const frame = W.encodeAudioFormat({ sampleRate: 48000, channels: 2, framesPerPacket: 1024, cookie: new Uint8Array([7, 8]) });
  assert.equal(hex(frame.subarray(5)), '40e7700000000000' + '00000002' + '00000400' + '0708');
  const a = W.parseAudioFormat(W.parseFrames(frame)[0].payload);
  assert.equal(a.sampleRate, 48000);
  assert.equal(a.channels, 2);
  assert.equal(a.framesPerPacket, 1024);
  assert.equal(hex(a.cookie), '0708');
  assert.equal(W.parseAudioFormat(new Uint8Array(15)), null);
});

test('audioFrame: [u64 pts][packet]', () => {
  const frame = W.encodeAudioFrame(21333, new Uint8Array([0xde, 0xad]));
  assert.equal(hex(frame), '06' + '0000000a' + '0000000000005355' + 'dead');
  const a = W.parseAudioFrame(W.parseFrames(frame)[0].payload);
  assert.equal(a.pts, 21333);
  assert.equal(hex(a.packet), 'dead');
  assert.equal(W.parseAudioFrame(new Uint8Array(8)), null);
});

test('AAC-LC AudioSpecificConfig', () => {
  assert.equal(hex(W.aacConfig(48000, 2)), '1190');
  assert.equal(hex(W.aacConfig(44100, 2)), '1210');
  assert.equal(hex(W.aacConfig(48000, 1)), '1188');
});

test('aspect fit and normalized points (Shared/Geometry.swift)', () => {
  const r = W.aspectFit({ width: 200, height: 100 }, { x: 0, y: 0, width: 400, height: 400 });
  assert.deepEqual(r, { x: 0, y: 100, width: 400, height: 200 });
  assert.deepEqual(W.normalized({ x: 100, y: 150 }, r), { x: 0.25, y: 0.25 });
  assert.equal(W.normalized({ x: 100, y: 50 }, r), null);
  assert.deepEqual(W.clampedNormalized({ x: -10, y: 500 }, r), { x: 0, y: 1 });
});

test('keys: text, specials, shortcuts, and Ctrl→Cmd off a Mac', () => {
  const ev = (code, key, m = {}) => ({ code, key, ctrlKey: false, metaKey: false, altKey: false, shiftKey: false, ...m });
  assert.deepEqual(W.keyEvent(ev('KeyA', 'A', { shiftKey: true }), true), { kind: 'text', text: 'A' });
  assert.deepEqual(W.keyEvent(ev('Space', ' '), false), { kind: 'text', text: ' ' });
  assert.deepEqual(W.keyEvent(ev('Enter', 'Enter'), true), { kind: 'key', key: 'return', mods: [] });
  assert.deepEqual(W.keyEvent(ev('ArrowLeft', 'ArrowLeft', { shiftKey: true }), true), { kind: 'key', key: 'left', mods: ['shift'] });
  assert.deepEqual(W.keyEvent(ev('KeyC', 'c', { metaKey: true }), true), { kind: 'key', key: 'c', mods: ['cmd'] });
  assert.deepEqual(W.keyEvent(ev('KeyC', 'c', { ctrlKey: true }), true), { kind: 'key', key: 'c', mods: ['ctrl'] });
  assert.deepEqual(W.keyEvent(ev('KeyC', 'c', { ctrlKey: true }), false), { kind: 'key', key: 'c', mods: ['cmd'] });
  assert.deepEqual(W.keyEvent(ev('KeyE', 'é', { altKey: true }), true), { kind: 'key', key: 'e', mods: ['opt'] });
  assert.deepEqual(W.keyEvent(ev('Backspace', 'Backspace'), false), { kind: 'key', key: 'delete', mods: [] });
  assert.deepEqual(W.keyEvent(ev('F5', 'F5'), false), { kind: 'key', key: 'f5', mods: [] });
  assert.equal(W.keyEvent(ev('ShiftLeft', 'Shift', { shiftKey: true }), true), null);
  assert.equal(W.isPasteShortcut(ev('KeyV', 'v', { metaKey: true }), true), true);
  assert.equal(W.isPasteShortcut(ev('KeyV', 'v', { ctrlKey: true }), false), true);
  assert.equal(W.isPasteShortcut(ev('KeyV', 'v', { ctrlKey: true }), true), false);
});

test('session names are panes- plus 6 of [a-z0-9]', () => {
  for (let i = 0; i < 50; i++) assert.match(W.newSessionName(), /^panes-[a-z0-9]{6}$/);
});

console.log(`\n${passed} passed`);
