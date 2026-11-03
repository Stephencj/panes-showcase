// Smoke test of the REAL agent's Panes Web (no bridge): http://127.0.0.1:7891,
// served and carried by Panes Agent itself. A fitted Mac window (virtual
// display path), typing into it, and a terminal tab.
//   node agent_smoke.mjs        (needs the agent running and a free TextEdit)
import { chromium } from 'playwright';
import { execFileSync } from 'node:child_process';

const base = process.env.PANES_WEB || 'http://127.0.0.1:7891';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const osa = (s) => execFileSync('osascript', ['-e', s], { encoding: 'utf8' }).trim();
let failures = 0;
const check = (name, ok, detail = '') => { if (!ok) failures++; console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  — ' + detail : ''}`); };
async function until(fn, timeout = 15000) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeout) { try { const v = await fn(); if (v) return v; } catch {} await sleep(200); }
  return null;
}
// Untitled documents autosave properly (named ones put up a permission sheet),
// so the test document is found by a marker in its text.
const marker = 'smoke' + Math.random().toString(36).slice(2, 8);
const docText = () => osa(`tell application "TextEdit"
  repeat with d in documents
    if (text of d) contains "${marker}" then return text of d
  end repeat
  return ""
end tell`);
osa(`tell application "TextEdit" to make new document with properties {text:"${marker}"}`);
await sleep(1000);
const title = osa('tell application "TextEdit" to get name of window 1');
osa('tell application "Finder" to activate');

const browser = await chromium.launch({ channel: 'chrome', headless: true });
try {
  const page = await (await browser.newContext({ viewport: { width: 1280, height: 800 } })).newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.goto(base + '/');
  await page.waitForFunction(() => window.panes);
  check('agent serves the client, in a secure context', await page.evaluate(() => isSecureContext && !!window.VideoDecoder));

  await page.click('#add');
  const row = page.locator('button.row.window', { hasText: title });
  check('picker lists the test window from the agent', !!(await until(async () => (await row.count()) === 1)), title);
  if (!(await page.isChecked('#fit'))) await page.click('#fit');
  await row.click();
  // A still window sends only a frame or two (capture sends on change).
  const frames = await until(() => page.evaluate(() => window.panes.store.current?.framesDecoded || 0), 20000);
  check('fitted window streams over /ws and decodes', !!frames, `${frames} frames`);
  await sleep(1000);
  const box = await page.locator('.pane:not([hidden]) canvas').boundingBox();
  await page.mouse.click(box.x + box.width / 2, box.y + box.height * 0.9);
  await sleep(400);
  await page.keyboard.type(' via-agent-web', { delay: 25 });
  const t = await until(() => { const s = docText(); return s.includes('via-agent-web') ? s : ''; }, 8000);
  check('typing in the browser reaches the fitted Mac window', !!t, JSON.stringify(t || docText()));

  await page.click('#add');
  await page.click('button[data-action="terminal"]');
  await until(() => page.evaluate(() => window.panes.store.current?.status === 'live'), 15000);
  await sleep(1200);
  await page.keyboard.type('echo PANES_$((6*7))\n');
  const term = await until(() => page.evaluate(() => {
    const b = window.panes.store.current.term.buffer.active;
    for (let i = 0; i < b.length; i++) if (b.getLine(i)?.translateToString().includes('PANES_42')) return true;
    return false;
  }), 8000);
  check('terminal tab runs a real shell over /ws', !!term);
  check('no page errors', errors.length === 0, errors.join('; '));
  // Close both tabs (✕), which ends the terminal's tmux session.
  // The chips re-render after each close, so take the first one each time.
  for (let i = 0; i < 4 && (await page.locator('.chip .x').count()) > 0; i++) {
    await page.locator('.chip .x').first().click();
    await sleep(800);
  }
  check('closing the tabs leaves none open', (await page.locator('.chip').count()) === 0);
} finally {
  await browser.close();
  // Close the test document without saving, then move TextEdit's autosave of
  // it (in iCloud Drive's TextEdit folder, recognised by the marker) to the Trash.
  osa(`tell application "TextEdit"
    repeat with d in documents
      if (text of d) contains "${marker}" then
        close d saving no
        exit repeat
      end if
    end repeat
  end tell`);
  const dir = process.env.HOME + '/Library/Mobile Documents/com~apple~TextEdit/Documents';
  for (const f of (() => { try { return execFileSync('ls', [dir], { encoding: 'utf8' }).split('\n'); } catch { return []; } })()) {
    if (!f.endsWith('.rtf')) continue;
    const text = execFileSync('textutil', ['-convert', 'txt', '-stdout', `${dir}/${f}`], { encoding: 'utf8' });
    if (text.includes(marker)) execFileSync('mv', [`${dir}/${f}`, `${process.env.HOME}/.Trash/${marker}.rtf`]);
  }
}
console.log(failures ? `${failures} FAILED` : 'ALL PASSED');
process.exit(failures ? 1 : 0);
