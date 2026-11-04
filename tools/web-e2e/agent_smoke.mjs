// Smoke test of a REAL Mac agent's Panes Web (no bridge): the page, machines.json
// and /ws all served and carried by Panes Agent itself. Run it against a side
// agent built from this checkout, not the installed one:
//   PANES_PORT=17890 PANES_WEB_PORT=17891 PANES_STATE_DIR=<scratch> "<dd>/Build/Products/Debug/Panes Agent.app/Contents/MacOS/Panes Agent" &
//   PANES_WEB=http://127.0.0.1:17891 node agent_smoke.mjs
// It streams only a window of its own (tone_window.swift, silent), and the page
// only sees that one: window lists are cut down to the test's windows first.
// machines.json is cut down to this Mac, so nothing reaches another machine.
import { chromium } from 'playwright';
import { execFileSync, spawn } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const base = process.env.PANES_WEB || 'http://127.0.0.1:17891';
const PROBE = 'panes-web-probe';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
let passed = 0;
const check = (name, ok, detail = '') => { if (!ok) failures++; else passed++; console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  — ' + detail : ''}`); };
async function until(fn, timeout = 15000) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeout) { try { const v = await fn(); if (v) return v; } catch {} await sleep(200); }
  return null;
}
const TMUX = ['/opt/homebrew/bin/tmux', '/usr/local/bin/tmux'].find((p) => { try { execFileSync('test', ['-x', p]); return true; } catch { return false; } });
const sessions = () => { try { return execFileSync(TMUX, ['ls', '-F', '#{session_name}'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).split('\n'); } catch { return []; } };

function onlyProbeWindows(data) {
  const b = Buffer.isBuffer(data) ? data : Buffer.from(data);
  if (b[0] !== 1) return data;
  let msg;
  try { msg = JSON.parse(b.subarray(5).toString('utf8')); } catch { return data; }
  if (msg.op !== 'windows') return data;
  msg.windows = (msg.windows || []).filter((w) => (w.title || '').startsWith(PROBE));
  const json = Buffer.from(JSON.stringify(msg));
  const out = Buffer.alloc(5 + json.length);
  out[0] = 1;
  out.writeUInt32BE(json.length, 1);
  json.copy(out, 5);
  return out;
}

// The agent's own machines.json, with this Mac's address turned into its local one.
const served = await (await fetch(base + '/machines.json')).json();
const me = served.filter((m) => m.web === base);
check("the agent's machines.json points this Mac at its local address", me.length === 1, JSON.stringify(served.map((m) => m.web)));
const manifest = await fetch(base + '/manifest.webmanifest');
check('the agent serves the install manifest', manifest.ok && manifest.headers.get('content-type') === 'application/manifest+json');

mkdirSync(join(here, 'shots'), { recursive: true });
const bin = join(here, 'shots', 'tone_window_smoke');
execFileSync('swiftc', ['-O', join(here, 'tone_window.swift'), '-o', bin]);
const title = `${PROBE}-smoke-${Date.now().toString(36)}`;
let text = '';
const win = spawn(bin, [title, '300', 'silent'], { stdio: ['ignore', 'pipe', 'ignore'] });
win.stdout.on('data', (d) => { for (const l of String(d).split('\n')) if (l.startsWith('TEXT ')) try { text = JSON.parse(l.slice(5))[0]; } catch {} });
await sleep(1500);

const browser = await chromium.launch({ channel: process.env.PANES_BROWSER_CHANNEL || 'chrome', headless: true });
let session = null;
try {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  await context.route('**/machines.json', (r) => r.fulfill({ contentType: 'application/json', body: JSON.stringify(me) }));
  await context.routeWebSocket(/\/ws$/, (ws) => {
    const server = ws.connectToServer();
    server.onMessage((m) => ws.send(onlyProbeWindows(m)));
    ws.onMessage((m) => server.send(m));
  });
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.goto(base + '/');
  await page.waitForFunction(() => window.panes);
  check('agent serves the client, in a secure context', await page.evaluate(() => isSecureContext && !!window.VideoDecoder));

  // Typing into an unfitted window (the agent can't yet type into fitted ones).
  await page.evaluate(() => localStorage.setItem('panes.fit', 'false'));
  await page.keyboard.press('Meta+K');
  await page.fill('#query', title);
  const row = page.locator('#results .result', { hasText: title });
  check('the palette lists the test window from the agent', !!(await until(async () => (await row.count()) === 1)), title);
  await row.click();
  const frames = await until(() => page.evaluate(() => window.panes.store.current?.framesDecoded || 0), 20000);
  check('the window streams over /ws and decodes', !!frames, `${frames} frames`);
  await sleep(800);
  const box = await page.locator('.pane.active canvas').boundingBox();
  const vr = await page.evaluate(() => window.panes.store.current.videoRect);
  await page.mouse.click(box.x + vr.x + vr.width / 2, box.y + vr.y + vr.height * 0.7);
  await sleep(400);
  await page.keyboard.type(' via-agent-web', { delay: 25 });
  check('typing in the browser reaches the Mac window', !!(await until(() => text.includes('via-agent-web'), 8000)), JSON.stringify(text));

  // A fitted window: the agent's virtual display path.
  await page.evaluate(() => localStorage.setItem('panes.fit', 'true'));
  await page.locator('#tabs .tab .x').first().click();
  await sleep(500);
  await page.keyboard.press('Meta+K');
  await page.fill('#query', title);
  await page.locator('#results .result', { hasText: title }).click();
  const fitted = await until(() => page.evaluate(() => window.panes.store.current?.framesDecoded || 0), 20000);
  check('a fitted window streams too', !!fitted, `${fitted} frames`);
  const line = await page.evaluate(() => getComputedStyle(document.querySelector('#tabs .tab[aria-selected="true"]')).borderBottomColor);
  const hex = (me[0].color || '#A3A8B3').replace('#', '');
  const rgb = `rgb(${parseInt(hex.slice(0, 2), 16)}, ${parseInt(hex.slice(2, 4), 16)}, ${parseInt(hex.slice(4, 6), 16)})`;
  check("the current tab's line is the machine's colour from machines.json", !!me[0].color && line === rgb, `${me[0].color} → ${line}`);

  await page.keyboard.press('Meta+K');
  await page.fill('#query', 'terminal');
  await page.locator('#results .result', { hasText: 'New terminal' }).click();
  await until(() => page.evaluate(() => window.panes.store.current?.status === 'live'), 15000);
  session = await page.evaluate(() => window.panes.store.current.kind.session);
  await sleep(1200);
  await page.keyboard.type('echo PANES_$((6*7))\n');
  const term = await until(() => page.evaluate(() => {
    const b = window.panes.store.current.term.buffer.active;
    for (let i = 0; i < b.length; i++) if (b.getLine(i)?.translateToString().includes('PANES_42')) return true;
    return false;
  }), 8000);
  check('terminal tab runs a real shell over /ws', !!term);
  const reported = await page.evaluate(async () => { await window.panes.devices.report(); return window.panes.devices.reports; });
  check('the agent answers the device report', reported > 0);
  await page.evaluate(() => window.panes.devices.forget());
  check('no page errors', errors.length === 0, errors.join('; '));
  for (let i = 0; i < 4 && (await page.locator('#tabs .tab .x').count()) > 0; i++) {
    await page.locator('#tabs .tab .x').first().click();
    await sleep(600);
  }
  check('closing the tabs leaves none open', (await page.locator('#tabs .tab').count()) === 0);
  check("closing the terminal ends its tmux session", !!(await until(() => !sessions().includes(session), 5000)));
} finally {
  await browser.close();
  win.kill();
  if (session && TMUX && sessions().includes(session)) try { execFileSync(TMUX, ['kill-session', '-t', session]); } catch {}
}
console.log(failures ? `${passed} passed, ${failures} FAILED` : `ALL ${passed} PASSED`);
process.exit(failures ? 1 : 0);
