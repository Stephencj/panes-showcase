// End-to-end test of Panes Web against the REAL Mac agent on this Mac
// (127.0.0.1:7890), through the dev-only tools/web_bridge.py.
//
//   cd tools/web-e2e && npm install && node run.mjs [--headed]
//
// It makes its own TextEdit document ("panes-web-probe…"), streams it, types
// into it, opens a terminal, and closes everything it made. Screenshots go to
// tools/web-e2e/shots/.
import { chromium } from 'playwright';
import { spawn, execFileSync } from 'node:child_process';
import { mkdirSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import net from 'node:net';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..');
const shots = join(here, 'shots');
const headed = process.argv.includes('--headed');
const DOC = 'panes-web-probe';
const TMUX = ['/opt/homebrew/bin/tmux', '/usr/local/bin/tmux', '/usr/bin/tmux'].find((p) => {
  try { execFileSync('test', ['-x', p]); return true; } catch { return false; }
});

let bridge = null;
let browser = null;
let failures = 0;
let toneProc = null;
let linuxBridge = null;
let legacyAppURL = false;
const results = [];

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

function osa(script) {
  return execFileSync('osascript', ['-e', script], { encoding: 'utf8' }).trim();
}

function tmuxSessions() {
  if (!TMUX) return '';
  try { return execFileSync(TMUX, ['ls', '-F', '#{session_name}'], { encoding: 'utf8' }); } catch { return ''; }
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

function startBridge(port, extra = []) {
  const p = spawn('python3', [join(root, 'tools', 'web_bridge.py'), '--port', String(port), ...extra], { stdio: ['ignore', 'pipe', 'inherit'] });
  p.stdout.on('data', (d) => process.stdout.write('  [bridge] ' + d));
  return p;
}

async function waitForHTTP(url) {
  await until('bridge', async () => (await fetch(url)).ok, 10000);
}

function stopBridge() {
  if (bridge && bridge.exitCode === null) bridge.kill('SIGTERM');
  bridge = null;
}

async function shot(page, name) {
  const path = join(shots, name + '.png');
  await page.screenshot({ path });
  console.log('      shot:', path);
}

/// Fraction of sampled canvas pixels that aren't black.
async function canvasLit(page) {
  return page.evaluate(() => {
    const t = window.panes.store.current;
    const c = t.canvas;
    const d = t.ctx.getImageData(0, 0, c.width, c.height).data;
    let lit = 0, n = 0;
    for (let i = 0; i < d.length; i += 4 * 97) {
      n++;
      if (d[i] + d[i + 1] + d[i + 2] > 30) lit++;
    }
    return lit / n;
  });
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
  active: t.active, audio: !!t.audio, audioDecoder: t.audio?.decoder?.state,
})));

async function main() {
  rmSync(shots, { recursive: true, force: true });
  mkdirSync(shots, { recursive: true });
  const port = await freePort();
  const base = `http://127.0.0.1:${port}`;
  bridge = startBridge(port);
  await waitForHTTP(base + '/machines.json');

  // Our own document, so the test never touches the user's.
  const stamp = Date.now().toString(36);
  const docName = `${DOC}-${stamp}`;
  const fitDoc = `${DOC}-fit-${stamp}`;
  for (const name of [docName, fitDoc]) {
    osa(`tell application "TextEdit" to make new document with properties {name:"${name}", text:"web probe"}`);
  }
  await sleep(1500);

  browser = await chromium.launch({
    channel: process.env.PANES_BROWSER_CHANNEL || 'chrome',
    headless: !headed,
    args: ['--autoplay-policy=no-user-gesture-required'],
  });
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
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
  const page = await context.newPage();
  const consoleLines = [];
  page.on('console', (m) => consoleLines.push(`${m.type()}: ${m.text()}`));
  page.on('pageerror', (e) => consoleLines.push('pageerror: ' + e.message));

  await page.goto(base + '/');
  await page.waitForFunction(() => window.panes);
  check('page loads with an empty state', await page.isVisible('#empty'));
  check('WebCodecs is available (secure context)', await page.evaluate(() => isSecureContext && !!window.VideoDecoder && !!window.AudioDecoder));
  check('this browser decodes AAC-LC from our AudioSpecificConfig', await page.evaluate(async () => {
    const r = await AudioDecoder.isConfigSupported({ codec: 'mp4a.40.2', sampleRate: 48000, numberOfChannels: 2, description: new Uint8Array([0x11, 0x90]) });
    return r.supported;
  }));
  await shot(page, '01-empty');

  // Picker: the bridge's one machine, its windows grouped by app.
  await page.click('#add');
  const row = page.locator('button.row.window', { hasText: docName });
  await row.waitFor({ timeout: 15000 });
  check('picker lists the probe TextEdit window', await row.count() === 1);
  check('picker offers New terminal', await page.isVisible('button[data-action="terminal"]'));
  check('picker shows window options', await page.isVisible('#fit') && await page.isVisible('#audio'));
  await shot(page, '02-picker');

  // Window tab, not fitted: decoded frames on the canvas.
  if (await page.isChecked('#fit')) await page.click('#fit');
  await row.click();
  await until('window tab live', async () => (await tabInfo(page))[0]?.status === 'live', 20000);
  await until('decoded frames', async () => (await tabInfo(page))[0].frames > 0, 15000);
  const lit = await until('non-black canvas', async () => { const v = await canvasLit(page); return v > 0.2 ? v : 0; }, 10000);
  check('window tab decodes video onto the canvas', lit > 0.2, `${Math.round(lit * 100)}% of sampled pixels lit, ${(await tabInfo(page))[0].frames} frames`);
  const open1 = await page.evaluate(() => window.__sent.find((m) => m.op === 'open'));
  check('open without Fit window sends no viewport, zoom 1, audio on', !open1.viewport && open1.zoom === 1 && open1.audio === true, JSON.stringify(open1));
  await sleep(800);
  await shot(page, '03-window-tab');

  // Typing: click into the document, then type text, a key press (Backspace), and Enter.
  const box = await page.locator('.pane:not([hidden]) canvas').boundingBox();
  await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
  await sleep(500);
  await page.keyboard.type(' typed-from-webX', { delay: 20 });
  await page.keyboard.press('Backspace');
  await sleep(1000);
  const inputs = await page.evaluate(() => window.__sent.filter((m) => m.op === 'input').map((m) => m.event));
  console.log('      sent input:', JSON.stringify(inputs).slice(0, 600));
  check('click, text and key events are sent', inputs.some((e) => e.kind === 'click') && inputs.some((e) => e.kind === 'text') && inputs.some((e) => e.kind === 'key' && e.key === 'delete'));
  const text = await until('document text to change', async () => {
    const t = osa(`tell application "TextEdit" to get text of document "${docName}"`);
    return t.includes('typed-from-web') ? t : '';
  }, 8000);
  check('typed text reaches the TextEdit document', text.includes('typed-from-web'), JSON.stringify(text));
  check('Backspace goes as a key press', !text.includes('typed-from-webX'));

  // Paste: this computer's clipboard goes across as typing.
  await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: base });
  await page.evaluate(() => navigator.clipboard.writeText(' pasted-in'));
  const sentBefore = await page.evaluate(() => window.__sent.length);
  await page.keyboard.press('Meta+V');
  await sleep(800);
  let pasted = await page.evaluate((n) => window.__sent.slice(n).filter((m) => m.op === 'input').map((m) => m.event), sentBefore);
  if (!pasted.length) {
    // Headless Chrome may not turn Meta+V into a paste; fire the event the browser would.
    await page.evaluate(() => {
      const dt = new DataTransfer();
      dt.setData('text/plain', ' pasted-in');
      document.activeElement.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }));
    });
    await sleep(500);
    pasted = await page.evaluate((n) => window.__sent.slice(n).filter((m) => m.op === 'input').map((m) => m.event), sentBefore);
    console.log('      (Meta+V produced no paste event headless; dispatched one)');
  }
  check('paste sends the clipboard text as text', pasted.length === 1 && pasted[0].kind === 'text' && pasted[0].text === ' pasted-in', JSON.stringify(pasted));
  const pastedText = await until('pasted text in document', async () => {
    const t = osa(`tell application "TextEdit" to get text of document "${docName}"`);
    return t.includes('pasted-in') ? t : '';
  }, 6000);
  check('pasted text reaches the TextEdit document', !!pastedText, JSON.stringify(pastedText));

  // Pointer: wheel, drag and hover come out as normalized scroll/down/drag/up/move.
  const mark = await page.evaluate(() => window.__sent.length);
  const cx = box.x + box.width / 2, cy = box.y + box.height / 2;
  await page.mouse.move(cx, cy);
  await page.mouse.wheel(0, 120);
  await sleep(200);
  await page.mouse.move(cx - 60, cy - 60);
  await page.mouse.down();
  await page.mouse.move(cx - 30, cy - 50, { steps: 4 });
  await page.mouse.move(cx, cy - 40, { steps: 4 });
  await page.mouse.up();
  const t0 = Date.now();
  for (let i = 0; i < 60; i++) await page.mouse.move(cx + (i % 20), cy + 20 + (i % 7));
  const hoverMs = Date.now() - t0;
  await sleep(300);
  const ptr = await page.evaluate((n) => window.__sent.slice(n).filter((m) => m.op === 'input').map((m) => m.event), mark);
  const scroll = ptr.find((e) => e.kind === 'scroll');
  const vr = await page.evaluate(() => window.panes.store.current.videoRect);
  check('wheel down sends scroll with dy = -deltaY / video height', scroll && Math.abs(scroll.dy - (-120 / vr.height)) < 1e-6 && scroll.dx === 0 && scroll.x > 0.4 && scroll.x < 0.6, JSON.stringify(scroll));
  const kinds = ptr.map((e) => e.kind).filter((k) => k !== 'move' && k !== 'scroll');
  check('a moved press is down, drag…, up (not a click)', kinds[0] === 'down' && kinds.at(-1) === 'up' && kinds.includes('drag') && !kinds.includes('click'), kinds.join(','));
  const moves = ptr.filter((e) => e.kind === 'move').length;
  check('hover moves are throttled to about 30/s', moves >= 1 && moves <= Math.ceil(hoverMs / 33) + 3, `${moves} moves in ${hoverMs} ms of 60 mousemoves`);
  check('pointer coordinates are 0…1', ptr.every((e) => e.x >= 0 && e.x <= 1 && e.y >= 0 && e.y <= 1));
  // Collapse the drag's selection so the right-click menu test can't touch the text.
  await page.keyboard.press('ArrowRight');
  const markR = await page.evaluate(() => window.__sent.length);
  await page.mouse.click(cx, cy + 40, { button: 'right' });
  await sleep(600);
  await page.keyboard.press('Escape');
  const right = await page.evaluate((n) => window.__sent.slice(n).filter((m) => m.op === 'input').map((m) => m.event), markR);
  check('right button sends rightClick (and the browser menu is suppressed)', right.some((e) => e.kind === 'rightClick') && !right.some((e) => e.kind === 'click'), right.map((e) => e.kind).join(','));
  check('Escape goes as a key press', right.some((e) => e.kind === 'key' && e.key === 'escape'));
  await sleep(500);
  await shot(page, '04-typed');

  // Terminal tab.
  await page.click('#add');
  await page.locator('button[data-action="terminal"]').click();
  await until('terminal live', async () => (await tabInfo(page))[1]?.status === 'live', 15000);
  const session = (await tabInfo(page))[1].session;
  check('terminal session name is panes-xxxxxx', /^panes-[a-z0-9]{6}$/.test(session), session);
  await sleep(1500);
  await page.keyboard.type('echo PANES_$((6*7))', { delay: 10 });
  await page.keyboard.press('Enter');
  const out = await until('PANES_42', async () => /^PANES_42\s*$/m.test(await termText(page, 1)), 10000);
  check('terminal runs a command (PANES_42 in the xterm buffer)', !!out);
  check('tmux has the session', tmuxSessions().split('\n').includes(session));
  await shot(page, '05-terminal');

  // Background tab paused, foreground resumed with a fresh keyframe.
  let tabs = await tabInfo(page);
  check('switching tabs deactivates the window tab', tabs[0].active === false && tabs[1].active === true);
  const before = tabs[0].frames;
  await page.locator('.chip').nth(0).click();
  await until('frames after resume', async () => (await tabInfo(page))[0].frames > before, 8000);
  check('window tab resumes with new frames', true);
  await page.locator('.chip').nth(1).click();

  // Reconnect: drop the bridge, see the failed state, bring it back.
  stopBridge();
  await until('terminal failed', async () => (await tabInfo(page))[1].status === 'failed', 8000);
  await sleep(300);
  await shot(page, '06-connection-lost');
  check('a dropped connection shows Reconnect', await page.isVisible('.pane:not([hidden]) .overlay button'));
  bridge = startBridge(port);
  await waitForHTTP(base + '/machines.json');
  await until('terminal back', async () => (await tabInfo(page))[1].status === 'live', 20000);
  check('the tab reconnects on its own to the same session', (await tabInfo(page))[1].session === session);

  // Reload: tabs come back from localStorage and reattach.
  await page.reload();
  await page.waitForFunction(() => window.panes && window.panes.store.tabs.length === 2);
  await until('restored tabs live', async () => (await tabInfo(page)).every((t) => t.status === 'live'), 20000);
  tabs = await tabInfo(page);
  check('reload restores both tabs', tabs.map((t) => t.kind).join(',') === 'window,terminal' && tabs[1].session === session);
  const again = await until('terminal screen after reattach', async () => /PANES_42/.test(await termText(page, 1)), 8000);
  check('reattached terminal shows the same tmux screen', !!again);

  // Phone width.
  await page.setViewportSize({ width: 390, height: 844 });
  await sleep(600);
  await shot(page, '07-phone-terminal');
  await page.locator('.chip').nth(0).click();
  await sleep(1200);
  await shot(page, '08-phone-window');
  await page.click('#add');
  await page.locator('button.row.window').first().waitFor();
  await shot(page, '09-phone-picker');
  await page.click('#pickerClose');
  await page.setViewportSize({ width: 1280, height: 800 });

  // Closing the terminal tab ends its tmux session.
  await page.locator('.chip').nth(1).locator('.x').click();
  await until('tmux session gone', async () => !tmuxSessions().split('\n').includes(session), 6000);
  check('closing the terminal tab ends its tmux session', !tmuxSessions().split('\n').includes(session));
  await page.locator('.chip').nth(0).locator('.x').click();
  await sleep(500);
  check('all tabs closed', (await tabInfo(page)).length === 0 && await page.isVisible('#empty'));

  // Fit window: the window is resized to the tab's shape (viewport = the tab area in CSS px).
  await page.click('#add');
  const fitRow = page.locator('button.row.window', { hasText: fitDoc });
  await fitRow.waitFor({ timeout: 15000 });
  if (!(await page.isChecked('#fit'))) await page.click('#fit');
  await fitRow.click();
  await until('fitted tab live', async () => (await tabInfo(page))[0]?.status === 'live', 20000);
  const lit2 = await until('fitted canvas lit', async () => { const v = await canvasLit(page); return v > 0.2 ? v : 0; }, 10000);
  const open2 = await page.evaluate(() => window.__sent.filter((m) => m.op === 'open').at(-1));
  const stage = await page.evaluate(() => ({ width: document.getElementById('stage').clientWidth, height: document.getElementById('stage').clientHeight }));
  const fitted = await page.evaluate(() => window.panes.store.current.windowSize);
  check('Fit window sends viewport = tab area, zoom 1', open2.viewport && open2.viewport.width === stage.width && open2.viewport.height === stage.height && open2.zoom === 1, JSON.stringify(open2.viewport));
  check('fitted window streams at the tab\'s shape', lit2 > 0.2 && Math.abs(fitted.width / fitted.height - stage.width / stage.height) < 0.02, `window ${fitted.width}×${fitted.height}`);
  await sleep(800);
  await shot(page, '10-fit-window');
  // Typing into a fitted window: reported, not failed (see the agent note in the report).
  const fitBox = await page.locator('.pane:not([hidden]) canvas').boundingBox();
  await page.mouse.click(fitBox.x + fitBox.width / 2, fitBox.y + fitBox.height / 2);
  await sleep(500);
  await page.keyboard.type(' fitted-typing', { delay: 20 });
  await sleep(1500);
  const fitText = osa(`tell application "TextEdit" to get text of document "${fitDoc}"`);
  console.log(`INFO  typing into a FITTED window ${fitText.includes('fitted-typing') ? 'reached' : 'did NOT reach'} TextEdit (${JSON.stringify(fitText)})`);
  await page.locator('.chip').nth(0).locator('.x').click();
  await sleep(500);

  // Sound: a quiet tone from a small window of our own (tone_window.swift), streamed with
  // the window like any app's sound.
  const toneBin = join(shots, 'tone_window');
  execFileSync('swiftc', ['-O', join(here, 'tone_window.swift'), '-o', toneBin]);
  toneProc = spawn(toneBin, [`${DOC}-tone`, '90'], { stdio: 'ignore' });
  await sleep(2000);
  await page.click('#add');
  const toneRow = page.locator('button.row.window', { hasText: `${DOC}-tone` });
  await toneRow.waitFor({ timeout: 15000 });
  if (await page.isChecked('#fit')) await page.click('#fit');
  if (!(await page.isChecked('#audio'))) await page.click('#audio');
  await toneRow.click();
  await until('sound tab live', async () => (await tabInfo(page))[0]?.status === 'live', 20000);
  const heard = await until('decoded audio', async () => {
    const a = await page.evaluate(() => { const p = window.panes.store.current.audio; return p && { decoded: p.decoded, scheduled: p.scheduled, peak: Math.round(p.peak * 1000) / 1000, state: p.decoder?.state, context: window.panes.audioContext()?.state }; });
    return a && a.scheduled > 20 ? a : null;
  }, 15000).catch((e) => ({ error: e.message }));
  check('app sound is decoded (AAC via AudioDecoder) and scheduled on the AudioContext', heard.scheduled > 20 && heard.peak > 0.005 && heard.context === 'running', JSON.stringify(heard));
  await shot(page, '11-app-sound');
  // A background tab stops its sound.
  await page.click('#add');
  await page.locator('button[data-action="terminal"]').click();
  await until('second tab live', async () => (await tabInfo(page))[1]?.status === 'live', 15000);
  const s1 = await page.evaluate(() => window.panes.store.tabs[0].audio.scheduled);
  await sleep(1500);
  const s2 = await page.evaluate(() => window.panes.store.tabs[0].audio.scheduled);
  check('background tab plays no sound', s2 === s1, `${s1} → ${s2}`);
  const termSession = (await tabInfo(page))[1].session;
  await page.locator('.chip').nth(1).locator('.x').click();
  await page.locator('.chip').nth(0).locator('.x').click();
  await until('second terminal ended', async () => !tmuxSessions().split('\n').includes(termSession), 6000);
  toneProc.kill();
  toneProc = null;

  // Optional: a Linux agent (PANES_E2E_LINUX=linux-box:7890) through a second bridge, for
  // the Apps list and app tabs. The bridge doesn't proxy /xpra/, so only the iframe's address
  // is checked, not the app's page.
  if (process.env.PANES_E2E_LINUX) {
    const port2 = await freePort();
    const base2 = `http://127.0.0.1:${port2}`;
    linuxBridge = startBridge(port2, ['--agent', process.env.PANES_E2E_LINUX, '--name', 'linux-box', '--allow-origin', base]);
    await waitForHTTP(base2 + '/machines.json');
    await page.route('**/machines.json', (r) => r.fulfill({
      contentType: 'application/json',
      body: JSON.stringify([{ name: 'This Mac', hosts: [], web: base }, { name: 'linux-box', hosts: [], web: base2 }]),
    }));
    await page.reload();
    await page.waitForFunction(() => window.panes);
    await page.click('#add');
    await page.selectOption('#machine', 'linux-box');
    const calc = page.locator('button.row[data-app="org.gnome.Calculator"]');
    await calc.waitFor({ timeout: 15000 });
    check('Linux picker lists Apps and hides window options', await page.isHidden('#windowOptions'));
    await shot(page, '12-linux-picker');
    const markA = await page.evaluate(() => window.__sent.length);
    await calc.click();
    await until('app tab live', async () => (await tabInfo(page))[0]?.status === 'live', 30000);
    const src = await page.evaluate(() => window.panes.store.current.frameEl.src);
    const launch = await page.evaluate((n) => window.__sent.slice(n).find((m) => m.op === 'launch'), markA);
    check('launch sends app id and a panes- session', launch.app === 'org.gnome.Calculator' && /^panes-[a-z0-9]{6}$/.test(launch.name), JSON.stringify(launch));
    if (/^\/xpra\//.test(new URL(src).pathname) || src.startsWith(base2)) {
      check("app tab's iframe is the machine's web address plus the relative url", src.startsWith(base2 + '/xpra/'), src.replace(/password=[^&]*/, 'password=…'));
    } else {
      // An agent from before docs/WEB.md sends a full http:// address; it's used as is.
      legacyAppURL = true;
      console.log('INFO  this Linux agent sent an absolute app url (pre-WEB.md); the iframe uses it as is: ' + src.replace(/password=[^&]*/, 'password=…'));
      check('absolute app url is used unchanged', /^http:\/\/[^/]+:\d+\/index\.html\?/.test(src));
    }
    await sleep(500);
    await shot(page, '13-linux-app-tab');
    await page.locator('.chip').nth(0).locator('.x').click();
    await sleep(600);
    const ended = await page.evaluate((n) => window.__sent.slice(n).find((m) => m.op === 'end'), markA);
    check('closing an app tab sends end for its session', ended && ended.name === launch.name);
    await page.unroute('**/machines.json');
    linuxBridge.kill();
    linuxBridge = null;
  }

  // An unreachable machine shows a clear error in the picker.
  await page.route('**/machines.json', (r) => r.fulfill({
    contentType: 'application/json',
    body: JSON.stringify([{ name: 'linux-box', hosts: [], web: 'http://127.0.0.1:59' }]),
  }));
  await page.reload();
  await page.waitForFunction(() => window.panes);
  await page.click('#add');
  await page.locator('.problem', { hasText: "Couldn't reach linux-box" }).waitFor({ timeout: 10000 });
  check("unreachable machine says Couldn't reach linux-box", true);
  await shot(page, '14-unreachable');

  const errors = consoleLines.filter((l) => /^(error|pageerror)/.test(l) && !/ERR_CONNECTION_REFUSED|WebSocket connection/.test(l)
    && !(legacyAppURL && /frame-ancestors/.test(l)));
  check('no page errors', errors.length === 0, errors.slice(0, 5).join(' | '));
  if (process.env.PANES_E2E_LOG) console.log(consoleLines.join('\n'));
}

async function cleanup() {
  try { if (browser) await browser.close(); } catch { /* gone */ }
  stopBridge();
  if (toneProc) toneProc.kill();
  if (linuxBridge) linuxBridge.kill();
  try { osa(`tell application "TextEdit" to close (every document whose name starts with "${DOC}") saving no`); } catch (e) { console.log('cleanup: ' + e.message); }
}

try {
  await main();
} catch (e) {
  failures++;
  console.log('FAIL  ' + e.message);
} finally {
  await cleanup();
}
console.log(`\n${results.filter((r) => r.ok).length} passed, ${failures} failed`);
process.exit(failures ? 1 : 0);
