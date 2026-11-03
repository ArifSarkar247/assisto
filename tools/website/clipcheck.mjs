// website.yml (sitev3, owner bug 3 Nov 01:35): fails when any screenshot is
// clipped / cropped / squeezed by its container, a frame's round corner sits
// over the top band of a screenshot, or a heading is clipped or covered.
// Widths 360/390/430 + 1280, bn + en.
//   node clipcheck.mjs <base> <outDir> v3       -> checks /preview/ pages, exit 1 on problems
//   node clipcheck.mjs <base> <outDir> before   -> report only + 360 px screenshots of the
//                                                  CURRENT live site (BEFORE proof)
import { chromium } from 'playwright';
import fs from 'node:fs';
import { audit, covered } from './clipaudit.mjs';

const [base, out, mode] = process.argv.slice(2);
const v3 = mode !== 'before';
const groups = ['ai', 'circle', 'safety', 'cctv', 'business', 'work', 'daily'];
const pages = v3
  ? [['home', '/preview/'], ['pricing', '/preview/pricing'], ...groups.map(g => [`group_${g}`, `/preview/features/${g}`])]
  : [['home', '/'], ['pricing', '/pricing']];
const widths = v3 ? [360, 390, 430, 1280] : [360];
fs.mkdirSync(out, { recursive: true });

const browser = await chromium.launch();
const report = [];
let problems = 0;
for (const lang of ['bn', 'en']) {
  for (const width of widths) {
    const ctx = await browser.newContext({ viewport: { width, height: width < 600 ? 800 : 900 },
      deviceScaleFactor: width < 600 ? 2 : 1, isMobile: width < 600, hasTouch: width < 600, reducedMotion: 'reduce' });
    const page = await ctx.newPage();
    for (const [name, path] of pages) {
      await page.goto(`${base}${path}?lang=${lang}`, { waitUntil: 'networkidle' });
      await page.evaluate(async () => {
        for (let y = 0; y < document.body.scrollHeight; y += 400) { window.scrollTo(0, y); await new Promise(r => setTimeout(r, 40)); }
        await Promise.all([...document.images].filter(i => !i.complete).map(i => new Promise(r => { i.onload = i.onerror = r; })));
        window.scrollTo(0, 0);
      });
      const bad = [...await page.evaluate(audit), ...(v3 ? await covered(page) : [])];
      report.push({ lang, width, page: name, problems: bad });
      problems += bad.length;
      if (bad.length) console.log(`${lang} ${width} ${name}:\n  ` + bad.join('\n  '));
      if (!v3) await page.screenshot({ path: `${out}/before_${lang}_360_${name}.png`, fullPage: true });
    }
    await ctx.close();
  }
}
await browser.close();
fs.writeFileSync(`${out}/clipcheck_${v3 ? 'v3' : 'before'}.json`, JSON.stringify(report, null, 1));
console.log(`clipcheck ${v3 ? 'v3' : 'before (report only)'}: ${problems} problem(s)`);
if (v3 && problems) process.exit(1);
