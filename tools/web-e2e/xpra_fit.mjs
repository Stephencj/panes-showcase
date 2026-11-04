// Does a Linux app fill a phone-sized tab exactly? Launches an app on a Linux
// agent, opens its Xpra page in WebKit at the phone tab's size with the
// phone app's own page script (Shared/WebKeys.swift), and checks the app's
// window covers the page: no gap above, nothing cut off below.
//
//   node xpra_fit.mjs [--host linux-box] [--app calc] [--size 402x708] [--shot out.png]
//
// The app session is ended afterwards.
import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { webkit } from 'playwright';

const args = Object.fromEntries(process.argv.slice(2).reduce((a, v, i, all) => (v.startsWith('--') ? [...a, [v.slice(2), all[i + 1]]] : a), []));
const host = args.host || 'linux-box';
const port = Number(args.port || 7890);
const needle = (args.app || 'calc').toLowerCase();
const [vw, vh] = (args.size || '402x708').split('x').map(Number);
const session = 'panes-fit' + Math.random().toString(36).slice(2, 6);
const here = path.dirname(fileURLToPath(import.meta.url));

// The phone app's page script, straight from the Swift source.
const swift = fs.readFileSync(path.join(here, '../../Shared/WebKeys.swift'), 'utf8');
const pageScript = swift.split('static let pageScript = """')[1].split('\n    """')[0]
  .split('\n').map((l) => l.replace(/^ {4}/, '')).join('\n');

function agent() {
  const sock = net.connect(port, host);
  let buf = Buffer.alloc(0);
  const waiting = [];
  sock.on('data', (d) => {
    buf = Buffer.concat([buf, d]);
    while (buf.length >= 5) {
      const n = buf.readUInt32BE(1);
      if (buf.length < 5 + n) break;
      const type = buf[0], body = buf.subarray(5, 5 + n);
      buf = buf.subarray(5 + n);
      if (type !== 1) continue;
      const msg = JSON.parse(body.toString());
      const i = waiting.findIndex((w) => w.op === msg.op || msg.op === 'error');
      if (i >= 0) waiting.splice(i, 1)[0].resolve(msg);
    }
  });
  return {
    send(m) {
      const b = Buffer.from(JSON.stringify(m));
      const h = Buffer.alloc(5);
      h[0] = 1; h.writeUInt32BE(b.length, 1);
      sock.write(Buffer.concat([h, b]));
    },
    wait(op, ms = 30000) {
      return new Promise((resolve, reject) => {
        waiting.push({ op, resolve });
        setTimeout(() => reject(new Error(`no ${op} from ${host}`)), ms);
      });
    },
    close() { sock.end(); },
  };
}

const a = agent();
a.send({ op: 'hello', version: 1 });
const hello = await a.wait('hello');
a.send({ op: 'apps' });
const app = (await a.wait('apps')).apps.find((x) => x.name.toLowerCase().includes(needle) || x.id.toLowerCase().includes(needle));
if (!app) throw new Error(`no app like ${needle}`);
a.send({ op: 'launch', app: app.id, name: session });
const launched = await a.wait('launched', 40000);
if (!launched.url) throw new Error(launched.error || 'no url');
const url = new URL(launched.url + '&keyboard=false', hello.web).href;

let ok = false;
const browser = await webkit.launch();
try {
  const page = await browser.newPage({ viewport: { width: vw, height: vh }, deviceScaleFactor: 3, isMobile: true, hasTouch: true });
  await page.addInitScript(pageScript);
  await page.goto(url);
  // Let the window appear and the page script maximize it.
  let g = null;
  for (let i = 0; i < 60; i++) {
    await page.waitForTimeout(500);
    g = await page.evaluate(() => {
      if (typeof client === 'undefined' || !client.id_to_window) return null;
      const w = Object.values(client.id_to_window).find((w) => !w.override_redirect);
      if (!w) return null;
      const el = w.div instanceof Element ? w.div : (w.div && w.div[0]) || document.getElementById(String(w.wid));
      const r = el ? el.getBoundingClientRect() : null;
      return { maximized: w.maximized, x: w.x, y: w.y, w: w.w, h: w.h, rect: r && { top: r.top, bottom: r.bottom, left: r.left, right: r.right },
               page: { w: innerWidth, h: innerHeight }, desktop: { w: client.desktop_width, h: client.desktop_height } };
    });
    if (g && g.maximized && g.rect && i > 6) break;
  }
  if (args.shot) await page.screenshot({ path: args.shot });
  const r = g?.rect;
  ok = !!r && r.top <= 1 && r.left <= 1 && Math.abs(r.bottom - vh) <= 2 && Math.abs(r.right - vw) <= 2;
  console.log(JSON.stringify({ ok, app: app.name, size: `${vw}x${vh}`, ...g }, null, 2));
} finally {
  await browser.close();
  a.send({ op: 'end', name: session });
  await new Promise((r) => setTimeout(r, 500));
  a.close();
}
process.exit(ok ? 0 : 1);
