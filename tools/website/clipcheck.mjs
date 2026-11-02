// website.yml (sitev3, owner bug 3 Nov 01:35): fails when any screenshot is
// clipped / cropped / squeezed by its container, a frame's round corner sits
// over the top band of a screenshot, or a heading is clipped or covered.
// Widths 360/390/430 + 1280, bn + en.
//   node clipcheck.mjs <base> <outDir> v3       -> checks /preview/ pages, exit 1 on problems
//   node clipcheck.mjs <base> <outDir> before   -> report only + 360 px screenshots of the
//                                                  CURRENT live site (BEFORE proof)
import { chromium } from 'playwright';
import fs from 'node:fs';

const [base, out, mode] = process.argv.slice(2);
const v3 = mode !== 'before';
const groups = ['ai', 'circle', 'safety', 'cctv', 'business', 'work', 'daily'];
const pages = v3
  ? [['home', '/preview/'], ['pricing', '/preview/pricing'], ...groups.map(g => [`group_${g}`, `/preview/features/${g}`])]
  : [['home', '/'], ['pricing', '/pricing']];
const widths = v3 ? [360, 390, 430, 1280] : [360];
fs.mkdirSync(out, { recursive: true });

const audit = () => {
  const bad = [];
  const desc = el => (el.tagName.toLowerCase() + (el.className && typeof el.className === 'string' ? '.' + el.className.trim().split(/\s+/).join('.') : '') + (el.getAttribute('alt') ? `[alt="${el.getAttribute('alt').slice(0, 50)}"]` : ''));
  const visible = el => {
    for (let e = el; e && e !== document.body; e = e.parentElement) {
      const cs = getComputedStyle(e);
      if (cs.display === 'none' || cs.visibility === 'hidden' || parseFloat(cs.opacity) < 0.05) return false;
      if (e.tagName === 'DIALOG' && !e.open) return false;
    }
    const r = el.getBoundingClientRect();
    return r.width > 2 && r.height > 2;
  };
  for (const img of document.querySelectorAll('main img, header img')) {
    if (!visible(img) || !img.naturalWidth) continue;
    const r = img.getBoundingClientRect();
    const nat = img.naturalWidth / img.naturalHeight, box = r.width / r.height;
    const fit = getComputedStyle(img).objectFit;
    if (Math.abs(nat - box) / nat > 0.015) bad.push(`${fit === 'cover' ? 'CROPPED' : 'SQUEEZED'} ${desc(img)} natural ${nat.toFixed(3)} vs box ${box.toFixed(3)}`);
    const own = parseFloat(getComputedStyle(img).borderTopLeftRadius) || 0;
    if (own > 16 && r.width > 120) bad.push(`RADIUS ${own}px eats the top band of ${desc(img)}`);
    for (let e = img.parentElement, depth = 0; e && e !== document.body && depth < 8; e = e.parentElement, depth++) {
      const cs = getComputedStyle(e);
      const clips = /(hidden|clip)/.test(cs.overflowX + cs.overflowY);
      const scroller = /(auto|scroll)/.test(cs.overflowX + cs.overflowY);
      if (scroller) break;                     // a carousel: off-screen slides are not clipped
      const a = e.getBoundingClientRect();
      const R = parseFloat(cs.borderTopLeftRadius) || 0;
      if (clips && (r.left < a.left - 1 || r.right > a.right + 1 || r.top < a.top - 1 || r.bottom > a.bottom + 1))
        bad.push(`CLIPPED ${desc(img)} by ${desc(e)}`);
      // a clipping container, or a visible device frame (big radius), must keep its
      // corner curve clear of the screenshot's top band
      if ((clips ? R > 0 : R > 20) && (r.top - a.top) < R * 0.3 && (r.left - a.left) < R * 0.3)
        bad.push(`CORNER of ${desc(e)} (radius ${R}px) over the top of ${desc(img)}`);
    }
  }
  for (const h of document.querySelectorAll('main h1, main h2, main h3')) {
    if (!visible(h)) continue;
    if (h.scrollWidth > h.clientWidth + 1) bad.push(`HEADING CLIPPED (overflow-x) "${h.textContent.trim().slice(0, 60)}"`);
    for (let e = h.parentElement, depth = 0; e && e !== document.body && depth < 6; e = e.parentElement, depth++) {
      const cs = getComputedStyle(e);
      if (!/(hidden|clip)/.test(cs.overflowX + cs.overflowY)) continue;
      const a = e.getBoundingClientRect(), r = h.getBoundingClientRect();
      if (r.left < a.left - 1 || r.right > a.right + 1 || r.top < a.top - 1 || r.bottom > a.bottom + 1)
        bad.push(`HEADING CLIPPED "${h.textContent.trim().slice(0, 60)}" by ${desc(e)}`);
    }
  }
  return bad;
};

const covered = async (page) => {
  // each heading scrolled to the middle of the screen must be on top there
  return page.evaluate(async () => {
    const bad = [];
    for (const h of document.querySelectorAll('main h1, main h2, main h3')) {
      const r0 = h.getBoundingClientRect();
      if (r0.width < 2) continue;
      h.scrollIntoView({ block: 'center' });
      await new Promise(r => requestAnimationFrame(r));
      const r = h.getBoundingClientRect();
      const x = r.left + Math.min(r.width / 2, 40), y = r.top + r.height / 2;
      const top = document.elementFromPoint(x, y);
      if (top && !h.contains(top) && !top.contains(h)) bad.push(`HEADING COVERED "${h.textContent.trim().slice(0, 60)}" by ${top.tagName.toLowerCase()}.${top.className}`);
    }
    return bad;
  });
};

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
