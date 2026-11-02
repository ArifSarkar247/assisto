// website.yml (sitev3): owner review screenshots of the v3 PREVIEW —
// desktop (1280) + phones (360/390/430) x bn/en, light (+ dark for home and
// the Safety page), plus the Play-button proof (play_proof.json + the
// https details page screenshot).
// Usage: node shots_v3.mjs <baseUrl> <outDir>
import { chromium } from 'playwright';
import fs from 'node:fs';

const [base, out] = process.argv.slice(2);
const groups = ['ai', 'circle', 'safety', 'cctv', 'business', 'work', 'daily'];
const pages = [['home', '/preview/'], ['features', '/preview/features'], ['pricing', '/preview/pricing'],
  ['security', '/preview/security'], ['help', '/preview/help'],
  ...groups.map(g => [`group_${g}`, `/preview/features/${g}`])];
fs.mkdirSync(out, { recursive: true });
const browser = await chromium.launch();
for (const lang of ['bn', 'en']) {
  for (const width of [360, 390, 430, 1280]) {
    for (const scheme of ['light', 'dark']) {
      const ctx = await browser.newContext({
        viewport: { width, height: width < 600 ? 844 : 800 }, colorScheme: scheme,
        deviceScaleFactor: width < 600 ? 2 : 1, isMobile: width < 600, hasTouch: width < 600,
      });
      const page = await ctx.newPage();
      for (const [name, path] of pages) {
        const key = name === 'home' || name === 'group_safety';
        if (scheme === 'dark' && !key) continue;
        if ((width === 360 || width === 430) && !key) continue;
        const r = await page.goto(`${base}${path}?lang=${lang}`, { waitUntil: 'networkidle' });
        await page.evaluate(() => document.fonts && document.fonts.ready);
        await page.evaluate(async () => {
          for (let y = 0; y < document.body.scrollHeight; y += 500) { window.scrollTo(0, y); await new Promise(r => setTimeout(r, 80)); }
          window.scrollTo(0, 0);
        });
        await page.waitForTimeout(700);
        const kind = width < 600 ? `mobile${width}` : 'desktop';
        const file = `${out}/${lang}_${kind}_${name}${scheme === 'dark' ? '_dark' : ''}.png`;
        await page.screenshot({ path: file, fullPage: true });
        console.log(r ? r.status() : '?', file);
      }
      await ctx.close();
    }
  }
}
// Play buttons: on Android they must become an intent:// to the Play Store
// app at OUR details page (browser fallback = the https details page).
const proof = {};
const actx = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true,
  userAgent: 'Mozilla/5.0 (Linux; Android 13; RMX3491) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Mobile Safari/537.36' });
const ap = await actx.newPage();
await ap.goto(`${base}/preview/?lang=bn`, { waitUntil: 'networkidle' });
proof.android = await ap.$$eval('a[data-play]', as => as.map(a => a.getAttribute('href')));
const dctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
const dp = await dctx.newPage();
await dp.goto(`${base}/preview/?lang=en`, { waitUntil: 'networkidle' });
proof.desktop = await dp.$$eval('a[data-play]', as => as.map(a => a.href));
try {
  const r = await dp.goto(proof.desktop[0], { waitUntil: 'domcontentloaded', timeout: 30000 });
  proof.details_status = r ? r.status() : null;
  proof.details_url = dp.url();
  proof.details_title = await dp.title();
  await dp.waitForTimeout(2500);
  await dp.screenshot({ path: `${out}/play_details_desktop.png` });
} catch (e) { proof.details_error = String(e); }
fs.writeFileSync(`${out}/play_proof.json`, JSON.stringify(proof, null, 2));
console.log(JSON.stringify(proof, null, 2));
await browser.close();
