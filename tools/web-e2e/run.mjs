// End-to-end test of Panes Web against REAL agents running beside the
// installed ones: a Mac agent built from this checkout and the Linux agent
// (linux/panes_agent.py, run here on this Mac), each on side ports with its
// own state folder. The page is served by tools/web_bridge.py (dev only),
// which carries /ws to each agent's TCP port.
//
//   xcodebuild build -project Panes.xcodeproj -scheme PanesAgent -destination 'platform=macOS' -derivedDataPath <dd>
//   cd tools/web-e2e && npm install
//   PANES_E2E_AGENT_APP="<dd>/Build/Products/Debug/Panes Agent.app" node run.mjs [--headed]
//
// Without PANES_E2E_AGENT_APP it expects a side Mac agent already listening on
// PANES_E2E_MAC_PORT (default 17890). Ports: PANES_E2E_MAC_PORT/_MAC_WEB
// (17890/17891) and PANES_E2E_LINUX_PORT/_LINUX_WEB (17990/17991).
//
// It only streams windows it makes itself (tone_window.swift), and the page
// only ever sees those: the window lists coming back are filtered to the test's
// own windows before the page gets them. It never scripts other apps.
// Screenshots go to tools/web-e2e/shots/.
import { chromium } from 'playwright';
import { spawn, execFileSync } from 'node:child_process';
import { mkdirSync, rmSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import net from 'node:net';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..');
const shots = join(here, 'shots');
const headed = process.argv.includes('--headed');
const PROBE = 'panes-web-probe';
const env = process.env;
const MAC_PORT = Number(env.PANES_E2E_MAC_PORT || 17890);
const MAC_WEB = Number(env.PANES_E2E_MAC_WEB || 17891);
const LINUX_PORT = Number(env.PANES_E2E_LINUX_PORT || 17990);
const LINUX_WEB = Number(env.PANES_E2E_LINUX_WEB || 17991);
const TMUX = ['/opt/homebrew/bin/tmux', '/usr/local/bin/tmux', '/usr/bin/tmux'].find((p) => {
  try { execFileSync('test', ['-x', p]); return true; } catch { return false; }
});

const procs = new Set();
let bridge = null;
let browser = null;
let failures = 0;
const results = [];
const madeSessions = new Set();

function check(name, ok, detail = '') {
  results.push({ name, ok });
  if (!ok) failures++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  — ' + detail : ''}`);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function until(what, fn, timeout = 15000, every = 200) {
  const t0 = Date.now();
  let last;
  while (Date.now() - t0 < timeout) {
    try {
      last = await fn();
      if (last) return last;
    } catch (e) {
      last = e;
    }
    await sleep(every);
  }
  throw new Error(`timed out waiting for ${what} (last: ${last})`);
}

function tmuxSessions() {
  if (!TMUX) return [];
  try { return execFileSync(TMUX, ['ls', '-F', '#{session_name}'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).split('\n'); } catch { return []; }
}

function freePort() {
  return new Promise((resolve) => {
    const s = net.createServer();
    s.listen(0, '127.0.0.1', () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });
}

function portOpen(port) {
  return new Promise((resolve) => {
    const s = net.connect(port, '127.0.0.1');
    s.once('connect', () => { s.destroy(); resolve(true); });
    s.once('error', () => resolve(false));
  });
}

function track(p, tag) {
  procs.add(p);
  p.on('exit', () => procs.delete(p));
  p.stdout?.on('data', (d) => { if (env.PANES_E2E_LOG) process.stdout.write(`  [${tag}] ${d}`); });
  p.stderr?.on('data', (d) => { if (env.PANES_E2E_LOG) process.stdout.write(`  [${tag}] ${d}`); });
  return p;
}

function startBridge(port, agentPort, name, extra = []) {
  const p = spawn('python3', [join(root, 'tools', 'web_bridge.py'), '--port', String(port), '--agent', `127.0.0.1:${agentPort}`, '--name', name, ...extra], { stdio: ['ignore', 'pipe', 'pipe'] });
  return track(p, 'bridge ' + name);
}

async function waitForHTTP(url) {
  await until(url, async () => (await fetch(url)).ok, 15000);
}

function stop(p) {
  if (p && p.exitCode === null && p.signalCode === null) p.kill('SIGTERM');
}

async function shot(page, name) {
  const path = join(shots, name + '.png');
  await page.screenshot({ path });
  console.log('      shot:', path);
}

/// One of the test's own windows: a quiet tone and a text field it echoes.
class ToneWindow {
  constructor(bin, title, { silent = false, seconds = 600 } = {}) {
    this.title = title;
    this.text = '';
    this.proc = track(spawn(bin, [title, String(seconds), ...(silent ? ['silent'] : [])], { stdio: ['ignore', 'pipe', 'ignore'] }), 'window');
    let buf = '';
    this.proc.stdout.on('data', (d) => {
      buf += d;
      let i;
      while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i);
        buf = buf.slice(i + 1);
        if (line.startsWith('TEXT ')) try { this.text = JSON.parse(line.slice(5))[0]; } catch { /* partial */ }
      }
    });
  }
  close() { stop(this.proc); }
}

/// Fraction of sampled canvas pixels that aren't black, in tab `i` (default: current).
async function canvasLit(page, i = null) {
  return page.evaluate((i) => {
    const t = i === null ? window.panes.store.current : window.panes.store.tabs[i];
    const c = t.canvas;
    if (!c.width || !c.height) return 0;
    const d = t.ctx.getImageData(0, 0, c.width, c.height).data;
    let lit = 0, n = 0;
    for (let k = 0; k < d.length; k += 4 * 97) {
      n++;
      if (d[k] + d[k + 1] + d[k + 2] > 30) lit++;
    }
    return lit / n;
  }, i);
}

async function termText(page, index) {
  return page.evaluate((i) => {
    const t = window.panes.store.tabs[i];
    const b = t.term.buffer.active;
    const lines = [];
    for (let y = 0; y < b.length; y++) lines.push(b.getLine(y).translateToString(true));
    return lines.join('\n');
  }, index);
}

const tabInfo = (page) => page.evaluate(() => window.panes.store.tabs.map((t) => ({
  kind: t.kind.type, status: t.status, session: t.kind.session, frames: t.framesDecoded, why: t.why,
  active: t.active, audio: !!t.audio, audioDecoder: t.audio?.decoder?.state, machine: t.machine.name, app: t.appName,
  title: t.title,
})));

const sentSince = (page, n, op) => page.evaluate(([n, op]) => window.__sent.slice(n).filter((m) => !op || m.op === op), [n, op]);
const sentCount = (page) => page.evaluate(() => window.__sent.length);

/// A made-up app for the Linux agent's list: the Linux agent runs on this Mac,
/// where there's no Xpra, so it has no apps of its own.
const FAKE_APP = { id: 'org.example.Calculator', name: 'Calculator' };
let linuxWeb = null;

/// Agent → page: the window list is cut down to the test's own windows, so
/// nothing of the user's is ever shown, opened or screenshotted. The Linux
/// agent also gets FAKE_APP, to check the palette's app rows and app tabs.
function onlyProbeWindows(data, url = '') {
  const b = Buffer.isBuffer(data) ? data : Buffer.from(data);
  if (b[0] !== 1) return data;
  let msg;
  try { msg = JSON.parse(b.subarray(5).toString('utf8')); } catch { return data; }
  const linux = linuxWeb && url.startsWith(linuxWeb.replace('http', 'ws'));
  if (linux && msg.op === 'hello' && !msg.features.includes('apps')) msg.features.push('apps');
  else if (linux && msg.op === 'apps') msg.apps = [...(msg.apps || []), FAKE_APP];
  else if (msg.op === 'windows') msg.windows = (msg.windows || []).filter((w) => (w.title || '').startsWith(PROBE));
  else return data;
  const json = Buffer.from(JSON.stringify(msg));
  const out = Buffer.alloc(5 + json.length);
  out[0] = 1;
  out.writeUInt32BE(json.length, 1);
  json.copy(out, 5);
  return out;
}

async function newContext(machines) {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  await context.route('**/machines.json', (r) => r.fulfill({ contentType: 'application/json', body: JSON.stringify(machines) }));
  await context.routeWebSocket(/\/ws$/, (ws) => {
    const server = ws.connectToServer();
    server.onMessage((m) => ws.send(onlyProbeWindows(m, ws.url())));
    ws.onMessage((m) => server.send(m));
  });
  // Records every control message the page sends, to check what went out.
  await context.addInitScript(() => {
    window.__sent = [];
    const send = WebSocket.prototype.send;
    WebSocket.prototype.send = function (data) {
      try {
        const b = new Uint8Array(data.buffer ? data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) : data);
        if (b[0] === 1) window.__sent.push(JSON.parse(new TextDecoder().decode(b.subarray(5))));
      } catch { /* not ours */ }
      return send.call(this, data);
    };
  });
  return context;
}

function watch(page, lines) {
  page.on('console', (m) => lines.push(`${m.type()}: ${m.text()}`));
  page.on('pageerror', (e) => lines.push('pageerror: ' + e.message));
}

const paletteRows = (page) => page.evaluate(() => [...document.querySelectorAll('#results .result')].map((b) => ({
  key: b.dataset.key, machine: b.dataset.machine, app: b.querySelector('.app').textContent, sub: b.querySelector('.sub').textContent,
  action: b.querySelector('.action').textContent, selected: b.getAttribute('aria-selected') === 'true',
  section: b.closest('.section')?.querySelector('.heading .text')?.textContent,
})));

async function openPalette(page) {
  await page.keyboard.press('Meta+K');
  await page.locator('#palette:not([hidden])').waitFor({ timeout: 3000 });
}

/// Opens the palette, searches, and picks the first row whose text matches.
async function pick(page, query, match) {
  await openPalette(page);
  await page.fill('#query', query);
  const row = page.locator('#results .result', { hasText: match }).first();
  await row.waitFor({ timeout: 15000 });
  await row.click();
}

async function main() {
  rmSync(shots, { recursive: true, force: true });
  mkdirSync(shots, { recursive: true });
  const scratch = mkdtempSync(join(tmpdir(), 'panes-web-e2e-'));

  // The side agents.
  if (env.PANES_E2E_AGENT_APP) {
    check('Mac side agent port is free', !(await portOpen(MAC_PORT)) && !(await portOpen(MAC_WEB)), `${MAC_PORT}/${MAC_WEB}`);
    const exe = join(env.PANES_E2E_AGENT_APP, 'Contents', 'MacOS', 'Panes Agent');
    mkdirSync(join(scratch, 'mac'), { recursive: true });
    track(spawn(exe, [], {
      stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...env, PANES_PORT: String(MAC_PORT), PANES_WEB_PORT: String(MAC_WEB), PANES_STATE_DIR: join(scratch, 'mac') },
    }), 'mac agent');
  }
  check('Linux side agent port is free', !(await portOpen(LINUX_PORT)) && !(await portOpen(LINUX_WEB)), `${LINUX_PORT}/${LINUX_WEB}`);
  mkdirSync(join(scratch, 'linux'), { recursive: true });
  track(spawn('python3', [join(root, 'linux', 'panes_agent.py')], {
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...env, PANES_PORT: String(LINUX_PORT), PANES_WEB_PORT: String(LINUX_WEB), PANES_STATE_DIR: join(scratch, 'linux'), PANES_WEB_DIR: join(root, 'web') },
  }), 'linux agent');
  await until('Mac side agent', () => portOpen(MAC_PORT), 15000);
  await until('Linux side agent', () => portOpen(LINUX_PORT), 15000);

  // Both agents serve the install manifest and icons with the right types.
  for (const [who, port] of [['Mac', MAC_WEB], ['Linux', LINUX_WEB]]) {
    const base = `http://127.0.0.1:${port}`;
    await waitForHTTP(base + '/index.html');
    const r = await fetch(base + '/manifest.webmanifest');
    const m = r.ok ? await r.json() : {};
    check(`${who} agent serves manifest.webmanifest as application/manifest+json`, r.ok && r.headers.get('content-type') === 'application/manifest+json' && m.name === 'Panes' && m.display === 'standalone', r.headers.get('content-type'));
    const sizes = [];
    for (const icon of m.icons || []) {
      const ir = await fetch(new URL(icon.src, base + '/').href);
      if (ir.ok && ir.headers.get('content-type').startsWith(icon.type)) sizes.push(icon.sizes);
    }
    check(`${who} agent serves the manifest's icons (svg, 192, 512)`, ['any', '192x192', '512x512'].every((s) => sizes.includes(s)), sizes.join(','));
    const f = await fetch(base + '/vendor/fonts/inter-latin-wght-normal.woff2');
    check(`${who} agent serves the fonts as font/woff2`, f.ok && f.headers.get('content-type') === 'font/woff2', f.headers.get('content-type'));
  }

  const port = await freePort();
  const base = `http://127.0.0.1:${port}`;
  const port2 = await freePort();
  const base2 = `http://127.0.0.1:${port2}`;
  bridge = startBridge(port, MAC_PORT, 'Mac test');
  const linuxBridge = startBridge(port2, LINUX_PORT, 'Linux test', ['--allow-origin', base]);
  await waitForHTTP(base + '/machines.json');
  await waitForHTTP(base2 + '/machines.json');
  linuxWeb = base2;
  const MACHINES = [
    { name: 'Mac test', hosts: [], web: base, color: '#5B9BFF' },
    { name: 'Linux test', hosts: [], web: base2, color: '#F2A33A' },
    // Off: its section says so, and nothing waits for it.
    { name: 'Off box', hosts: [], web: 'http://127.0.0.1:59' },
  ];

  // Our own windows.
  const toneBin = join(shots, 'tone_window');
  execFileSync('swiftc', ['-O', join(here, 'tone_window.swift'), '-o', toneBin]);
  const stamp = Date.now().toString(36);
  const winA = new ToneWindow(toneBin, `${PROBE}-a-${stamp}`, { silent: true });
  const winB = new ToneWindow(toneBin, `${PROBE}-b-${stamp}`, { silent: true });
  await sleep(2000);

  browser = await chromium.launch({
    channel: env.PANES_BROWSER_CHANNEL || 'chrome',
    headless: !headed,
    args: ['--autoplay-policy=no-user-gesture-required'],
  });
  const context = await newContext(MACHINES);
  const page = await context.newPage();
  const consoleLines = [];
  watch(page, consoleLines);

  await page.goto(base + '/');
  await page.waitForFunction(() => window.panes);
  check('page loads with an empty state', await page.isVisible('#empty') && (await page.textContent('#empty')).includes('Nothing open'));
  check('WebCodecs is available (secure context)', await page.evaluate(() => isSecureContext && !!window.VideoDecoder && !!window.AudioDecoder));
  check('this browser decodes AAC-LC from our AudioSpecificConfig', await page.evaluate(async () => {
    const r = await AudioDecoder.isConfigSupported({ codec: 'mp4a.40.2', sampleRate: 48000, numberOfChannels: 2, description: new Uint8Array([0x11, 0x90]) });
    return r.supported;
  }));
  check('page links the manifest and icons', await page.evaluate(() => !!document.querySelector('link[rel="manifest"][href="manifest.webmanifest"]') && !!document.querySelector('link[rel="icon"][type="image/svg+xml"]')));
  check('top bar: +, search box with ⌘K, Other devices', await page.isVisible('#add') && (await page.textContent('#search')).includes('Open an app on any machine') && (await page.textContent('#searchKey')) === '⌘K' && (await page.textContent('#devicesButton')).includes('Other devices'));
  check('UI font is Inter (vendored)', await page.evaluate(async () => { await document.fonts.ready; return document.fonts.check('14px Inter') && getComputedStyle(document.body).fontFamily.startsWith('Inter'); }));
  await shot(page, '01-empty');

  // MARK: palette
  await openPalette(page);
  check('⌘K opens the palette with the search focused', await page.evaluate(() => document.activeElement.id === 'query'));
  await until('probe windows listed', async () => (await paletteRows(page)).filter((r) => r.sub.includes(PROBE)).length >= 2, 15000);
  await until('Off box unreachable', async () => (await page.locator('.section[data-machine="Off box"] .status-line.problem').textContent()).includes("Can't reach Off box"), 10000);
  let rows = await paletteRows(page);
  check('palette has a section per machine', await page.evaluate(() => [...document.querySelectorAll('#results .section')].map((s) => s.dataset.machine).filter(Boolean).join(',')) === 'Mac test,Linux test,Off box');
  check("an unreachable machine shows Can't reach <machine> without blocking the rest", rows.some((r) => r.machine === 'Mac test') && rows.some((r) => r.machine === 'Linux test'));
  check('Mac section lists our windows, as app + "machine · title"', rows.filter((r) => r.machine === 'Mac test' && r.sub === `Mac test · ${winA.title}`).length === 1, JSON.stringify(rows.filter((r) => r.machine === 'Mac test').map((r) => r.sub)));
  check('the page only sees the test\'s own windows', rows.filter((r) => r.machine === 'Mac test' && r.key.includes('|window|')).every((r) => r.sub.includes(PROBE)));
  check('each machine offers New terminal', rows.some((r) => r.machine === 'Mac test' && r.app === 'New terminal') && rows.some((r) => r.machine === 'Linux test' && r.app === 'New terminal'));
  check('no Recent section before anything was opened', !(await page.isVisible('.section[data-section="recent"]')));
  const tint = await page.evaluate(() => {
    const t = document.querySelector('#results .result[data-machine="Linux test"] .tile');
    return getComputedStyle(t).color;
  });
  check('rows carry a tile in the machine colour', tint === 'rgb(242, 163, 58)', tint);
  check('the first row is selected', rows[0].selected);
  await shot(page, '02-palette');
  // Filtering by window title, app and machine name.
  await page.fill('#query', `b-${stamp}`);
  rows = await paletteRows(page);
  check('typing filters by window title', rows.length === 1 && rows[0].sub.includes(winB.title), JSON.stringify(rows.map((r) => r.sub)));
  await page.fill('#query', 'linux terminal');
  rows = await paletteRows(page);
  check('typing filters by machine name and app', rows.length === 1 && rows[0].machine === 'Linux test' && rows[0].app === 'New terminal', JSON.stringify(rows));
  await page.fill('#query', 'zzzz-nothing');
  await page.locator('#results .nothing').waitFor({ timeout: 3000 });
  check('no match says so', true);
  await page.keyboard.press('Escape');
  check('Esc closes the palette', await page.isHidden('#palette'));

  // Arrow keys + Enter open a window. This first one unfitted (Fit windows off in Settings), for typing.
  await page.evaluate(() => { localStorage.setItem('panes.fit', 'false'); document.getElementById('fit').checked = false; });
  await page.click('#search');
  check('the search box opens the palette too', await page.isVisible('#palette'));
  await page.fill('#query', PROBE);
  await until('two probe rows', async () => (await paletteRows(page)).length === 2);
  rows = await paletteRows(page);
  const aIndex = rows.findIndex((r) => r.sub.includes(winA.title));
  await page.keyboard.press('ArrowDown');
  await page.keyboard.press('ArrowUp');
  for (let i = 0; i < aIndex; i++) await page.keyboard.press('ArrowDown');
  rows = await paletteRows(page);
  check('arrow keys move the selection', rows[aIndex].selected && rows.filter((r) => r.selected).length === 1);
  await page.keyboard.press('Enter');
  check('Enter opens the selected row and closes the palette', await page.isHidden('#palette'));
  await until('window tab live', async () => (await tabInfo(page))[0]?.status === 'live', 20000);
  await until('decoded frames', async () => (await tabInfo(page))[0].frames > 0, 15000);
  const lit = await until('non-black canvas', async () => { const v = await canvasLit(page); return v > 0.2 ? v : 0; }, 10000);
  check('window tab decodes video onto the canvas', lit > 0.2, `${Math.round(lit * 100)}% of sampled pixels lit, ${(await tabInfo(page))[0].frames} frames`);
  const chip = await page.evaluate(() => {
    const c = document.querySelector('#tabs .tab[aria-selected="true"]');
    return { app: c.querySelector('.app').textContent, machine: c.querySelector('.machine').textContent, line: getComputedStyle(c).borderBottomColor, dot: getComputedStyle(c.querySelector('.dot')).backgroundColor, bg: getComputedStyle(c).backgroundColor };
  });
  check('the tab shows dot, app and machine; current one raised with a line in its machine colour', chip.app === 'tone_window' && chip.machine === 'Mac test' && chip.line === 'rgb(91, 155, 255)' && chip.dot === 'rgb(91, 155, 255)' && chip.bg === 'rgb(38, 41, 48)', JSON.stringify(chip));
  const open1 = (await sentSince(page, 0, 'open'))[0];
  check('open with Fit windows off sends no viewport, zoom 1, audio on', !open1.viewport && open1.zoom === 1 && open1.audio === true, JSON.stringify(open1));
  await page.evaluate(() => localStorage.setItem('panes.fit', 'true'));
  await sleep(800);
  await shot(page, '03-window-tab');

  // Typing: click into the window's text field, then type text, a key press (Backspace).
  const box = await page.locator('.pane.active canvas').boundingBox();
  const vr = await page.evaluate(() => window.panes.store.current.videoRect);
  // The field fills the lower part of our window.
  const fx = box.x + vr.x + vr.width / 2, fy = box.y + vr.y + vr.height * 0.7;
  await page.mouse.click(fx, fy);
  await sleep(500);
  await page.keyboard.type(' typed-from-webX', { delay: 20 });
  await page.keyboard.press('Backspace');
  await sleep(500);
  const inputs = (await sentSince(page, 0, 'input')).map((m) => m.event);
  check('click, text and key events are sent', inputs.some((e) => e.kind === 'click') && inputs.some((e) => e.kind === 'text') && inputs.some((e) => e.kind === 'key' && e.key === 'delete'));
  await until('typed text in our window', async () => winA.text.includes('typed-from-web'), 8000).catch(() => {});
  check('typed text reaches the window', winA.text.includes('typed-from-web'), JSON.stringify(winA.text));
  check('Backspace goes as a key press', !winA.text.includes('typed-from-webX'));

  // Paste: this computer's clipboard goes across as typing.
  await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: base });
  const sentBefore = await sentCount(page);
  await page.evaluate(() => {
    const dt = new DataTransfer();
    dt.setData('text/plain', ' pasted-in');
    document.activeElement.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }));
  });
  await sleep(500);
  const pasted = (await sentSince(page, sentBefore, 'input')).map((m) => m.event);
  check('paste sends the clipboard text as text', pasted.length === 1 && pasted[0].kind === 'text' && pasted[0].text === ' pasted-in', JSON.stringify(pasted));
  await until('pasted text in window', async () => winA.text.includes('pasted-in'), 6000).catch(() => {});
  check('pasted text reaches the window', winA.text.includes('pasted-in'), JSON.stringify(winA.text));

  // Pointer: wheel, drag and hover come out as normalized scroll/down/drag/up/move.
  const mark = await sentCount(page);
  const cx = box.x + box.width / 2, cy = box.y + box.height / 2;
  await page.mouse.move(cx, cy);
  await page.mouse.wheel(0, 120);
  await sleep(200);
  await page.mouse.move(cx - 60, cy - 10);
  await page.mouse.down();
  await page.mouse.move(cx - 30, cy - 5, { steps: 4 });
  await page.mouse.move(cx, cy, { steps: 4 });
  await page.mouse.up();
  const t0 = Date.now();
  for (let i = 0; i < 60; i++) await page.mouse.move(cx + (i % 20), cy + 20 + (i % 7));
  const hoverMs = Date.now() - t0;
  await sleep(300);
  const ptr = (await sentSince(page, mark, 'input')).map((m) => m.event);
  const scroll = ptr.find((e) => e.kind === 'scroll');
  const vr2 = await page.evaluate(() => window.panes.store.current.videoRect);
  check('wheel down sends scroll with dy = -deltaY / video height', scroll && Math.abs(scroll.dy - (-120 / vr2.height)) < 1e-6 && scroll.dx === 0 && scroll.x > 0.4 && scroll.x < 0.6, JSON.stringify(scroll));
  const kinds = ptr.map((e) => e.kind).filter((k) => k !== 'move' && k !== 'scroll');
  check('a moved press is down, drag…, up (not a click)', kinds[0] === 'down' && kinds.at(-1) === 'up' && kinds.includes('drag') && !kinds.includes('click'), kinds.join(','));
  const moves = ptr.filter((e) => e.kind === 'move').length;
  check('hover moves are throttled to about 30/s', moves >= 1 && moves <= Math.ceil(hoverMs / 33) + 3, `${moves} moves in ${hoverMs} ms of 60 mousemoves`);
  check('pointer coordinates are 0…1', ptr.every((e) => e.x >= 0 && e.x <= 1 && e.y >= 0 && e.y <= 1));
  const markR = await sentCount(page);
  await page.mouse.click(fx, fy, { button: 'right' });
  await sleep(600);
  await page.keyboard.press('Escape');
  const right = (await sentSince(page, markR, 'input')).map((m) => m.event);
  check('right button sends rightClick (and the browser menu is suppressed)', right.some((e) => e.kind === 'rightClick') && !right.some((e) => e.kind === 'click'), right.map((e) => e.kind).join(','));
  check('Escape goes to the app as a key press', right.some((e) => e.kind === 'key' && e.key === 'escape'));
  await sleep(300);
  await shot(page, '04-typed');

  // MARK: a terminal on the Linux agent, then a second window
  await pick(page, 'linux terminal', 'New terminal');
  await until('terminal live', async () => (await tabInfo(page))[1]?.status === 'live', 15000);
  const session = (await tabInfo(page))[1].session;
  madeSessions.add(session);
  check('terminal session name is panes-xxxxxx', /^panes-[a-z0-9]{6}$/.test(session), session);
  check('the terminal tab is on the Linux machine', (await tabInfo(page))[1].machine === 'Linux test');
  await sleep(1200);
  await page.keyboard.type('echo PANES_$((6*7))', { delay: 10 });
  await page.keyboard.press('Enter');
  const out = await until('PANES_42', async () => /^PANES_42\s*$/m.test(await termText(page, 1)), 10000);
  check('terminal runs a command (PANES_42 in the xterm buffer)', !!out);
  check('tmux has the session', tmuxSessions().includes(session));
  check('terminal uses JetBrains Mono', await page.evaluate(() => window.panes.store.current.term.options.fontFamily.startsWith('"JetBrains Mono"') && document.fonts.check('13px "JetBrains Mono"')));
  await shot(page, '05-terminal');

  // An app on the Linux machine (FAKE_APP): a row in its section, and a tab that launches it.
  await openPalette(page);
  await until('app row', async () => (await paletteRows(page)).some((r) => r.machine === 'Linux test' && r.app === FAKE_APP.name), 10000).catch(() => {});
  rows = await paletteRows(page);
  const appRow = rows.find((r) => r.machine === 'Linux test' && r.app === FAKE_APP.name);
  const linuxOrder = rows.filter((r) => r.section === 'Linux test').map((r) => r.app);
  check('Linux section lists its apps after New terminal', !!appRow && appRow.sub === 'Linux test' && appRow.action === 'Open' && linuxOrder.join() === `New terminal,${FAKE_APP.name}`, JSON.stringify(linuxOrder));
  const markA = await sentCount(page);
  await page.locator('#results .result', { hasText: FAKE_APP.name }).click();
  const launch = await until('launch', async () => (await sentSince(page, markA, 'launch'))[0], 8000);
  check('picking an app launches it in a new panes- session', launch.app === FAKE_APP.id && /^panes-[a-z0-9]{6}$/.test(launch.name), JSON.stringify(launch));
  check('the app tab shows the app and machine', await page.evaluate(() => { const c = document.querySelector('#tabs .tab[aria-selected="true"]'); return c.querySelector('.app').textContent + '|' + c.querySelector('.machine').textContent; }) === `${FAKE_APP.name}|Linux test`);
  await page.locator('.pane.active .notice:not([hidden])').waitFor({ timeout: 8000 }).catch(() => {});
  check("the agent's answer (no such app here) shows on the tab", (await page.locator('.pane.active .notice').textContent()).includes("isn't available"));
  await page.locator('#tabs .tab[aria-selected="true"] .x').click();
  await sleep(500);
  const endApp = (await sentSince(page, markA, 'end'))[0];
  check('closing an app tab sends end for its session', endApp && endApp.name === launch.name);

  await pick(page, `b-${stamp}`, winB.title);
  await until('second window live', async () => (await tabInfo(page))[2]?.status === 'live', 20000);
  await until('second window frames', async () => (await tabInfo(page))[2].frames > 0, 15000);
  let tabs = await tabInfo(page);
  check('three tabs; only the newest is active', tabs.length === 3 && tabs.map((t) => t.active).join() === 'false,false,true');
  const openB = (await sentSince(page, 0, 'open')).at(-1);
  const stage = await page.evaluate(() => ({ width: document.getElementById('stage').clientWidth, height: document.getElementById('stage').clientHeight }));
  check('with Fit windows on (the default), open sends the tab area as viewport', openB.viewport && openB.viewport.width === stage.width && openB.viewport.height === stage.height && openB.zoom === 1, JSON.stringify(openB.viewport));
  await until('fitted shape', async () => { const s = await page.evaluate(() => window.panes.store.current.windowSize); return s && Math.abs(s.width / s.height - stage.width / stage.height) < 0.02; }, 8000).catch(() => {});
  const fitted = await page.evaluate(() => window.panes.store.current.windowSize);
  check("the fitted window streams at the tab's shape", Math.abs(fitted.width / fitted.height - stage.width / stage.height) < 0.02, `window ${fitted.width}×${fitted.height}`);

  // MARK: switching tabs keeps the others connected, and shows the last frame at once
  await page.evaluate(() => {
    window.__links = window.panes.store.tabs.map((t) => t.link);
    window.__els = window.panes.store.tabs.map((t) => t.el);
    window.__sockets = window.panes.store.tabs.map((t) => t.link.ws);
  });
  const markS = await sentCount(page);
  const frames0 = (await tabInfo(page))[0].frames;
  // Ctrl+Tab from the last tab wraps to the first; the window's last frame is up at once.
  const instant = await page.evaluate(() => new Promise((resolve) => {
    const t = window.panes.store.tabs[0];
    const before = t.framesDecoded;
    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', code: 'Tab', ctrlKey: true, bubbles: true, cancelable: true }));
    // Same task as the switch: no new frame can have been decoded yet.
    const c = t.canvas;
    const d = t.ctx.getImageData(0, 0, c.width, c.height).data;
    let lit = 0, n = 0;
    for (let k = 0; k < d.length; k += 4 * 97) { n++; if (d[k] + d[k + 1] + d[k + 2] > 30) lit++; }
    resolve({ selected: window.panes.store.tabs.indexOf(window.panes.store.current), lit: lit / n, visible: getComputedStyle(t.el).visibility, newFrames: t.framesDecoded - before });
  }));
  check('Ctrl+Tab moves to the next tab (round the end)', instant.selected === 0, JSON.stringify(instant));
  check('a window tab shows its last frame the moment it comes back (no blank)', instant.lit > 0.2 && instant.visible === 'visible' && instant.newFrames === 0, JSON.stringify(instant));
  await until('frames after resume', async () => (await tabInfo(page))[0].frames > frames0, 8000);
  check('the window resumes with new frames', true);
  await page.keyboard.press('Control+Tab');
  check('Ctrl+Tab again: the terminal', (await tabInfo(page))[1].active);
  await page.keyboard.press('Control+Shift+Tab');
  check('Ctrl+Shift+Tab goes back', (await tabInfo(page))[0].active);
  await page.keyboard.press('Meta+Shift+BracketRight');
  check('⌘⇧] next tab', (await tabInfo(page))[1].active);
  await page.keyboard.press('Meta+Shift+BracketLeft');
  check('⌘⇧[ previous tab', (await tabInfo(page))[0].active);
  await page.locator('#tabs .tab').nth(2).locator('.open').click();
  check('clicking a tab switches to it', (await tabInfo(page))[2].active);
  const kept = await page.evaluate(() => window.panes.store.tabs.every((t, i) => t.link === window.__links[i] && t.el === window.__els[i] && t.link.ws === window.__sockets[i] && t.el.isConnected && t.link.ws.readyState === 1));
  check('switching never tears down a tab: same connection, same element, still open', kept);
  const switchOps = await sentSince(page, markS);
  check('switching sends pause/resume, never a new open, terminal or launch', !switchOps.some((m) => ['open', 'terminal', 'launch'].includes(m.op)) && switchOps.some((m) => m.op === 'pause') && switchOps.some((m) => m.op === 'resume'), switchOps.map((m) => m.op).join(','));
  check('tab shortcuts are not passed to the app', !switchOps.some((m) => m.op === 'input' && m.event.kind === 'key' && ['tab', ']', '['].includes(m.event.key)), JSON.stringify(switchOps.filter((m) => m.op === 'input')));
  // In the background a window gets no frames.
  const bg = (await tabInfo(page))[0].frames;
  await sleep(1500);
  check('a background window tab is paused (no frames)', (await tabInfo(page))[0].frames === bg);
  // Keys still go to the app: type into the terminal after switching with the keyboard.
  await page.keyboard.press('Control+Shift+Tab');
  check('back on the terminal', (await tabInfo(page))[1].active);
  await sleep(300);
  await page.keyboard.type('echo SWITCH_$((2+3))', { delay: 10 });
  await page.keyboard.press('Enter');
  check('other keys still reach the app after switching', !!(await until('SWITCH_5', async () => /^SWITCH_5\s*$/m.test(await termText(page, 1)), 8000).catch(() => null)));
  check('the terminal kept its screen across switches', /^PANES_42\s*$/m.test(await termText(page, 1)));

  // ⌘K over a window tab opens the palette instead of going to the Mac.
  await page.locator('#tabs .tab').nth(0).locator('.open').click();
  await page.locator('.pane.active canvas').focus();
  const markK = await sentCount(page);
  await page.keyboard.press('Meta+K');
  check('⌘K over a window tab opens the palette, not the app', await page.isVisible('#palette') && !(await sentSince(page, markK, 'input')).some((m) => m.event.key === 'k'));
  await until('Recent', async () => (await paletteRows(page)).some((r) => r.section === 'Recent'), 5000).catch(() => {});
  rows = await paletteRows(page);
  const recent = rows.filter((r) => r.section === 'Recent');
  check('Recent lists what was opened, newest first, with Switch to for open tabs', recent.length === 4 && recent[0].sub.includes(winB.title) && recent[0].action === 'Switch to' && recent[1].app === FAKE_APP.name && recent[1].action === 'Open' && recent[2].app === 'Terminal' && recent[3].sub.includes(winA.title), JSON.stringify(recent.map((r) => [r.app, r.sub, r.action])));
  check('open windows say Switch to in their machine section too', rows.some((r) => r.section === 'Mac test' && r.sub.includes(winA.title) && r.action === 'Switch to'));
  await shot(page, '06-palette-recent');
  const markP = await sentCount(page);
  await page.locator('#results .section[data-machine="Mac test"] .result', { hasText: winA.title }).click();
  check('picking an open one switches to it, no new tab', (await tabInfo(page)).length === 3 && (await tabInfo(page))[0].active && !(await sentSince(page, markP, 'open')).length);
  check('Recent keeps at most 8', await page.evaluate(() => {
    for (let i = 0; i < 12; i++) window.panes.Recent.remember({ machine: 'Mac test', kind: 'window', app: 'X', title: 'x' + i, windowID: 900000 + i });
    const n = window.panes.Recent.list().length;
    const saved = JSON.parse(localStorage.getItem('panes.recent')).filter((r) => r.windowID < 900000);
    localStorage.setItem('panes.recent', JSON.stringify(saved));
    return n === 8;
  }));

  // MARK: reconnect and reload
  await page.locator('#tabs .tab').nth(0).locator('.open').click();
  stop(bridge);
  await until('window tab failed', async () => (await tabInfo(page))[0].status === 'failed', 8000);
  await sleep(300);
  await shot(page, '06b-connection-lost');
  check('a dropped connection shows Reconnect', await page.isVisible('.pane.active .overlay button'));
  check('…only on that machine\'s tabs', (await tabInfo(page))[1].status === 'live');
  await page.locator('#tabs .tab').nth(1).locator('.open').click();
  bridge = startBridge(port, MAC_PORT, 'Mac test');
  await waitForHTTP(base + '/machines.json');
  await until('window tabs back', async () => (await tabInfo(page)).every((t) => t.status === 'live'), 30000);
  check('tabs reconnect on their own', true);

  await page.reload();
  await page.waitForFunction(() => window.panes && window.panes.store.tabs.length === 3);
  await until('restored tabs live', async () => (await tabInfo(page)).every((t) => t.status === 'live'), 30000);
  tabs = await tabInfo(page);
  check('reload restores all tabs', tabs.map((t) => t.kind).join(',') === 'window,terminal,window' && tabs[1].session === session && tabs[1].active);
  const again = await until('terminal screen after reattach', async () => /PANES_42/.test(await termText(page, 1)), 8000).catch(() => null);
  check('reattached terminal shows the same tmux screen', !!again);

  // MARK: other devices
  await page.locator('#tabs .tab').nth(1).locator('.open').click();
  const contextB = await newContext(MACHINES);
  const pageB = await contextB.newPage();
  const consoleB = [];
  watch(pageB, consoleB);
  await pageB.goto(base + '/');
  await pageB.waitForFunction(() => window.panes);
  const ids = [await page.evaluate(() => window.panes.devices.me), await pageB.evaluate(() => window.panes.devices.me)];
  check('each browser makes up its own device id and keeps it', ids[0].id !== ids[1].id && /^[A-Za-z0-9_-]{1,64}$/.test(ids[0].id) && (await page.evaluate(() => JSON.parse(localStorage.getItem('panes.device.id')))) === ids[0].id);
  check('default device name is like "Chrome on macOS", kind browser', ids[0].name === 'Chrome on macOS' && ids[0].kind === 'browser', ids[0].name);
  // B renames itself in Settings (reached from the Other devices panel).
  await pageB.click('#devicesButton');
  await pageB.click('#settingsButton');
  check('settings popover opens with the name', await pageB.isVisible('#settings') && (await pageB.inputValue('#deviceName')) === 'Chrome on macOS');
  await pageB.fill('#deviceName', 'Test laptop B');
  await pageB.keyboard.press('Enter');
  check('the name is kept', await pageB.isHidden('#settings') && (await pageB.evaluate(() => JSON.parse(localStorage.getItem('panes.device.name')))) === 'Test laptop B');
  // B opens a terminal on the Mac machine.
  await pick(pageB, 'mac terminal', 'New terminal');
  await until('B terminal live', async () => (await tabInfo(pageB))[0]?.status === 'live', 15000);
  const sessionB = (await tabInfo(pageB))[0].session;
  madeSessions.add(sessionB);
  await sleep(800);
  await pageB.keyboard.type('echo FROM_B_$((40+2))', { delay: 10 });
  await pageB.keyboard.press('Enter');
  await until('FROM_B_42', async () => /^FROM_B_42\s*$/m.test(await termText(pageB, 0)), 8000);
  await pageB.evaluate(() => window.panes.devices.report());
  const reportsB = await pageB.evaluate(() => window.__sent.filter((m) => m.op === 'device'));
  const lastB = reportsB.at(-1);
  check('B reports itself to every reachable machine: id, name, kind, tabs as TabRefs', reportsB.length >= 2 && lastB.device.name === 'Test laptop B' && lastB.device.kind === 'browser' && lastB.device.tabs.length === 1
    && lastB.device.tabs[0].machine === 'Mac test' && lastB.device.tabs[0].kind === 'terminal' && lastB.device.tabs[0].session === sessionB, JSON.stringify(lastB));
  // A opens Other devices: B's tab, with Open here.
  await page.click('#devicesButton');
  const card = page.locator(`#devicesList .device[data-device="${ids[1].id}"]`);
  // Opening the panel asks again; B's newest report (its new name and tab) shows when it comes.
  await until('B in A\'s panel', async () => (await card.count()) === 1 && (await card.locator('.heading').textContent()).includes('Test laptop B') && (await card.locator('.device-tab').count()) === 1, 10000).catch(() => {});
  check('Other devices lists B by name with its tab and Open here', (await card.locator('.heading').textContent()).includes('Test laptop B') && (await card.locator('.device-tab').count()) === 1 && (await card.locator('.pill').textContent()) === 'Open here');
  check('Other devices offers "Send <current app> to" B', (await page.textContent('#sendSection')).includes('Send Terminal to') && (await page.locator(`#sendSection .send-to[data-device="${ids[1].id}"]`).count()) === 1);
  await shot(page, '07-other-devices');
  await card.locator('.pill').click();
  await until('A opened B\'s terminal', async () => (await tabInfo(page)).length === 4 && (await tabInfo(page))[3].status === 'live', 15000);
  tabs = await tabInfo(page);
  check('Open here opens the same tmux session here', tabs[3].session === sessionB && tabs[3].machine === 'Mac test' && tabs[3].active);
  check('…showing the same screen', !!(await until('FROM_B on A', async () => /FROM_B_42/.test(await termText(page, 3)), 8000).catch(() => null)));
  await page.click('#devicesButton');
  await until('Switch', async () => (await card.locator('.pill').textContent()) === 'Switch', 5000).catch(() => {});
  check('a tab this device already has says Switch', (await card.locator('.pill').textContent()) === 'Switch');
  await page.keyboard.press('Escape');
  check('Esc closes the panel', await page.isHidden('#devices'));

  // A sends its window B to B. Both machines keep a copy; B shows it once.
  await page.locator('#tabs .tab').nth(2).locator('.open').click();
  await page.click('#devicesButton');
  await page.locator(`#sendSection .send-to[data-device="${ids[1].id}"]`).click();
  await page.locator('#toast:not([hidden])').waitFor({ timeout: 10000 });
  check('sending says Sent. <app> is waiting in Panes on <device>.', (await page.textContent('#toast')) === 'Sent. tone_window is waiting in Panes on Test laptop B.', await page.textContent('#toast'));
  await until('a send to each machine', async () => (await page.evaluate(() => window.__sent.filter((m) => m.op === 'send').length)) === 2, 5000).catch(() => {});
  const sends = await page.evaluate(() => window.__sent.filter((m) => m.op === 'send'));
  check('the send goes to every machine, with the sender\'s name and the TabRef', sends.length === 2 && sends.every((s) => s.to === sends[0].to && s.name === 'Chrome on macOS' && s.tab.kind === 'window' && s.tab.machine === 'Mac test' && s.tab.windowID), JSON.stringify(sends));
  await shot(page, '08-sent');
  await pageB.evaluate(() => {
    window.__arrivals = [];
    const d = window.panes.devices;
    const arrived = d.arrived.bind(d);
    d.arrived = (sent) => { window.__arrivals.push(sent.length); return arrived(sent); };
  });
  const selBefore = await pageB.evaluate(() => window.panes.store.selected);
  await pageB.evaluate(() => window.panes.devices.report());
  await until('arrival on B', async () => (await tabInfo(pageB)).length === 2, 10000);
  const arrivals = await pageB.evaluate(() => window.__arrivals);
  tabs = await tabInfo(pageB);
  check('both machines handed over a copy', arrivals.reduce((a, b) => a + b, 0) === 2, JSON.stringify(arrivals));
  check('…but the tab arrives once, at the end, without taking focus', tabs.length === 2 && tabs[1].kind === 'window' && !tabs[1].active && (await pageB.evaluate(() => window.panes.store.selected)) === selBefore);
  check('notice: <app> arrived from <device>', (await pageB.textContent('#toast')) === 'tone_window arrived from Chrome on macOS', await pageB.textContent('#toast'));
  await shot(pageB, '09-arrived');
  await pageB.click('#toast');
  check('clicking the notice switches to it', (await tabInfo(pageB))[1].active);
  await until('arrived window live', async () => (await tabInfo(pageB))[1].status === 'live' && (await tabInfo(pageB))[1].frames > 0, 15000).catch(() => {});
  check('the arrived window streams on B (same window)', (await tabInfo(pageB))[1].frames > 0 && (await tabInfo(pageB))[1].title === winB.title);
  // Reporting again (both inboxes are empty now) brings nothing new.
  await pageB.evaluate(() => window.panes.devices.report());
  check('no repeat on the next report', (await tabInfo(pageB)).length === 2);
  // Every 15 s while in use.
  const r0 = await pageB.evaluate(() => window.panes.devices.reports);
  await sleep(16000);
  check('reports again every 15 s', (await pageB.evaluate(() => window.panes.devices.reports)) > r0);
  // Coming back to the foreground reports at once.
  const nVis = await pageB.evaluate(() => window.__sent.filter((m) => m.op === 'device').length);
  await pageB.evaluate(() => document.dispatchEvent(new Event('visibilitychange')));
  await until('report on visibility', async () => (await pageB.evaluate(() => window.__sent.filter((m) => m.op === 'device').length)) >= nVis + 2, 3000).catch(() => {});
  check('coming back to the foreground reports to every machine', (await pageB.evaluate(() => window.__sent.filter((m) => m.op === 'device').length)) >= nVis + 2);
  // On a tab change: closing the arrived tab reports at once.
  const nDevice = (await pageB.evaluate(() => window.__sent.filter((m) => m.op === 'device').length));
  await pageB.locator('#tabs .tab').nth(1).locator('.x').click();
  await until('report after tab change', async () => (await pageB.evaluate(() => window.__sent.filter((m) => m.op === 'device').length)) >= nDevice + 2, 5000).catch(() => {});
  const lastReport = await pageB.evaluate(() => window.__sent.filter((m) => m.op === 'device').at(-1).device.tabs.length);
  check('tab changes are reported (to every machine)', (await pageB.evaluate(() => window.__sent.filter((m) => m.op === 'device').length)) >= nDevice + 2 && lastReport === 1);
  // A sees B's new name and tabs; B sees A.
  await pageB.click('#devicesButton');
  await until('A in B\'s panel', async () => (await pageB.locator(`#devicesList .device[data-device="${ids[0].id}"] .device-tab`).count()) === 4, 10000).catch(() => {});
  check('B lists A\'s four tabs, with Switch for the one it has', (await pageB.locator(`#devicesList .device[data-device="${ids[0].id}"] .device-tab`).count()) === 4
    && (await pageB.locator(`#devicesList .device[data-device="${ids[0].id}"] .pill`, { hasText: 'Switch' }).count()) === 1);
  await pageB.setViewportSize({ width: 800, height: 600 });
  await sleep(300);
  await shot(pageB, '10-narrow-other-devices');
  await pageB.keyboard.press('Escape');

  // MARK: narrow window
  await page.setViewportSize({ width: 800, height: 600 });
  await sleep(600);
  await shot(page, '11-narrow-window');
  const fits = await page.evaluate(() => document.getElementById('bar').scrollWidth <= document.getElementById('bar').clientWidth);
  check('at 800 px the bar fits (search box keeps its icon and shortcut)', fits && await page.isVisible('#searchKey') && await page.isHidden('#search .label'));
  await openPalette(page);
  await shot(page, '12-narrow-palette');
  await page.keyboard.press('Escape');
  await page.setViewportSize({ width: 1280, height: 800 });
  await sleep(300);
  await openPalette(page);
  await page.fill('#query', '');
  await sleep(500);
  await shot(page, '13-desktop-palette');
  await page.keyboard.press('Escape');

  // MARK: sound, from a window that plays a tone
  const tone = new ToneWindow(toneBin, `${PROBE}-tone-${stamp}`);
  await sleep(2000);
  await pick(page, `tone-${stamp}`, tone.title);
  await until('sound tab live', async () => (await tabInfo(page)).at(-1)?.status === 'live', 20000);
  const heard = await until('decoded audio', async () => {
    const a = await page.evaluate(() => { const p = window.panes.store.current.audio; return p && { decoded: p.decoded, scheduled: p.scheduled, peak: Math.round(p.peak * 1000) / 1000, state: p.decoder?.state, context: window.panes.audioContext()?.state }; });
    return a && a.scheduled > 20 ? a : null;
  }, 15000).catch((e) => ({ error: e.message }));
  check('app sound is decoded (AAC via AudioDecoder) and scheduled on the AudioContext', heard.scheduled > 20 && heard.peak > 0.005 && heard.context === 'running', JSON.stringify(heard));
  await page.keyboard.press('Control+Shift+Tab');
  const s1 = await page.evaluate(() => window.panes.store.tabs.at(-1).audio.scheduled);
  await sleep(1500);
  const s2 = await page.evaluate(() => window.panes.store.tabs.at(-1).audio.scheduled);
  check('background tab plays no sound', s2 === s1, `${s1} → ${s2}`);

  // MARK: closing tabs ends the terminal sessions
  for (let i = 0; i < 8 && (await page.locator('#tabs .tab').count()) > 0; i++) {
    await page.locator('#tabs .tab .x').first().click();
    await sleep(400);
  }
  check('all tabs closed, empty state back', (await tabInfo(page)).length === 0 && await page.isVisible('#empty'));
  await until('tmux sessions gone', async () => !tmuxSessions().includes(session) && !tmuxSessions().includes(sessionB), 6000).catch(() => {});
  check('closing terminal tabs ends their tmux sessions', !tmuxSessions().includes(session) && !tmuxSessions().includes(sessionB));
  await pageB.locator('#tabs .tab .x').first().click().catch(() => {});

  // Tidy the side agents' device books.
  await page.evaluate(() => window.panes.devices.forget());
  await pageB.evaluate(() => window.panes.devices.forget());
  const left = await page.evaluate(async () => { await window.panes.devices.report(); return window.panes.devices.list.length; });
  check('forget takes a device off every machine', left === 0, String(left));
  await page.evaluate(() => window.panes.devices.forget());

  tone.close();
  winA.close();
  winB.close();
  stop(linuxBridge);
  const ignore = (l) => /ERR_CONNECTION_REFUSED|WebSocket connection|net::ERR/.test(l);
  const errors = [...consoleLines, ...consoleB].filter((l) => /^(error|pageerror)/.test(l) && !ignore(l));
  check('no page errors', errors.length === 0, errors.slice(0, 5).join(' | '));
  if (env.PANES_E2E_LOG) console.log(consoleLines.join('\n'));
  rmSync(scratch, { recursive: true, force: true });
}

async function cleanup() {
  try { if (browser) await browser.close(); } catch { /* gone */ }
  for (const p of [...procs]) stop(p);
  // Only sessions this test made.
  for (const s of madeSessions) {
    if (TMUX && tmuxSessions().includes(s)) try { execFileSync(TMUX, ['kill-session', '-t', s]); } catch { /* gone */ }
  }
  await sleep(800);
  for (const p of [...procs]) if (p.exitCode === null) p.kill('SIGKILL');
}

try {
  await main();
} catch (e) {
  failures++;
  console.log('FAIL  ' + (e.stack || e.message));
} finally {
  await cleanup();
}
console.log(`\n${results.filter((r) => r.ok).length} passed, ${failures} failed`);
process.exit(failures ? 1 : 0);
