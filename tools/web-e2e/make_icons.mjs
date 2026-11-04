// Renders web/icons/icon.svg to the PNG sizes the manifest lists.
//   node tools/web-e2e/make_icons.mjs
import { chromium } from 'playwright';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const icons = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'web', 'icons');
const svg = readFileSync(join(icons, 'icon.svg'), 'utf8');
const browser = await chromium.launch({ channel: process.env.PANES_BROWSER_CHANNEL || 'chrome', headless: true });
try {
  for (const size of [192, 512]) {
    const page = await browser.newPage({ viewport: { width: size, height: size } });
    await page.setContent(`<style>html,body{margin:0;background:transparent}svg{display:block;width:${size}px;height:${size}px}</style>${svg}`);
    await page.screenshot({ path: join(icons, `icon-${size}.png`), omitBackground: true });
    await page.close();
  }
} finally {
  await browser.close();
}
console.log('wrote icon-192.png and icon-512.png');
