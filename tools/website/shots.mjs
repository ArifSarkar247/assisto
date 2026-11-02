// website.yml: full-page screenshots of the public site at 390px and 1280px,
// light + dark. Usage: node shots.mjs <baseUrl> <outDir>
import { chromium } from 'playwright';
import fs from 'node:fs';

const [base, out] = process.argv.slice(2);
const pages = [
  ['home_bn', '/'], ['home_en', '/?lang=en'], ['pricing', '/pricing'], ['security', '/security'],
  ['help', '/help'], ['get', '/get'], ['cv', '/cv'], ['delete_account', '/delete-account'],
];
fs.mkdirSync(out, { recursive: true });
const browser = await chromium.launch();
for (const scheme of ['light', 'dark']) {
  for (const width of [390, 1280]) {
    const ctx = await browser.newContext({
      viewport: { width, height: width < 600 ? 844 : 800 }, colorScheme: scheme,
      deviceScaleFactor: width < 600 ? 2 : 1, isMobile: width < 600, hasTouch: width < 600,
    });
    const page = await ctx.newPage();
    for (const [name, path] of pages) {
      const r = await page.goto(base + path, { waitUntil: 'networkidle' });
      await page.evaluate(() => document.fonts && document.fonts.ready);
      // lazy images: scroll through so every screenshot in the page is loaded
      await page.evaluate(async () => {
        for (let y = 0; y < document.body.scrollHeight; y += 600) { window.scrollTo(0, y); await new Promise(r => setTimeout(r, 60)); }
        window.scrollTo(0, 0);
      });
      await page.waitForTimeout(300);
      const file = `${out}/${name}_${width}_${scheme}.png`;
      await page.screenshot({ path: file, fullPage: true });
      console.log(r ? r.status() : '?', file);
    }
    await ctx.close();
  }
}
await browser.close();
