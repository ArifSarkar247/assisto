// website.yml (sitefix, owner FIXES 3 Nov 11:10): the home page's mobile menu,
// hero slider and header, checked in a real browser at 360/390/430/1280/1440 px,
// bn + en. CI only, never on the server.
//
//   node uxcheck.mjs <base> <outDir> after    -> exit 1 on any problem
//   node uxcheck.mjs <base> <outDir> before   -> same checks, report only (the
//                                              CURRENT live code = origin/main)
//
// Phones (< 821 px): the menu button opens a FULL-SCREEN menu (covers the
// viewport, >= 10 rows of >= 52 px, current page highlighted, Install button),
// the page behind cannot scroll, and X, Esc and Back each close it (Back stays
// on the page). No dark band under the slider dots.
// Desktop: no menu button, header is one row (<= 80 px) holding logo, chips,
// Install and language; the hero content starts ~48 px under the header and
// the phone frame is top-aligned with the headline.
// Slider (all widths, motion allowed): sampled every 200 ms for 10 s — never
// two screens overlapping, never a visible screen whose image has not loaded
// (naturalWidth 0), at rest at most ONE screen visible; it advances by itself
// (4 s) with the caption + "n / 9" counter following; a swipe moves it; the
// pause button is >= 44 px and stops it. Headings/screenshots: clipaudit.
import { chromium } from 'playwright';
import fs from 'node:fs';
import { audit } from './clipaudit.mjs';

const [base, out, mode] = process.argv.slice(2);
const strict = mode !== 'before';
const tag = strict ? 'after' : 'before';
fs.mkdirSync(out, { recursive: true });
const problems = [];
const report = [];
const fail = (where, msg) => { problems.push(`${where}: ${msg}`); console.log(`FAIL ${where}: ${msg}`); };

const browser = await chromium.launch();
for (const lang of ['bn', 'en']) {
  for (const width of [360, 390, 430, 1280, 1440]) {
    const mobile = width < 821;
    const where = `${tag} ${lang} ${width}`;
    const ctx = await browser.newContext({ viewport: { width, height: mobile ? 800 : 900 },
      deviceScaleFactor: mobile ? 2 : 1, isMobile: mobile, hasTouch: mobile, reducedMotion: 'no-preference' });
    const page = await ctx.newPage();
    const errs = [];
    page.on('pageerror', e => errs.push(String(e).slice(0, 200)));
    const url = `${base}/preview/?lang=${lang}`;
    await page.goto(url, { waitUntil: 'load' });
    await page.waitForTimeout(600);
    const row = { lang, width, checks: {} };

    // ---------------------------------------------------------- slider
    const sample = () => page.evaluate(() => {
      const ph = document.querySelector('[data-rot]');
      if (!ph) return { none: true };
      const vp = ph.querySelector('.rot-vp') || ph.querySelector('.track') || ph;
      const V = vp.getBoundingClientRect();
      const moving = document.getAnimations().some(a => a.playState === 'running' && a.effect && a.effect.target
        && ph.contains(a.effect.target) && /transform|opacity|visibility/.test(a.transitionProperty || ''));
      const vis = [];
      [...ph.querySelectorAll('.slide')].forEach((s, i) => {
        const cs = getComputedStyle(s);
        if (cs.visibility === 'hidden' || cs.display === 'none' || parseFloat(cs.opacity) < 0.05) return;
        const r = s.getBoundingClientRect();
        const x1 = Math.max(r.left, V.left), x2 = Math.min(r.right, V.right);
        const y1 = Math.max(r.top, V.top), y2 = Math.min(r.bottom, V.bottom);
        if (x2 - x1 < 2 || y2 - y1 < 2) return;
        const img = s.querySelector('img');
        vis.push({ i, x1, x2, y1, y2, ok: !!(img && img.complete && img.naturalWidth > 0) });
      });
      let overlap = false;
      for (let a = 0; a < vis.length; a++) for (let b = a + 1; b < vis.length; b++) {
        const w = Math.min(vis[a].x2, vis[b].x2) - Math.max(vis[a].x1, vis[b].x1);
        const h = Math.min(vis[a].y2, vis[b].y2) - Math.max(vis[a].y1, vis[b].y1);
        if (w > 2 && h > 2) overlap = true;
      }
      const on = [...ph.querySelectorAll('.slide')].findIndex(s => s.classList.contains('on'));
      const t = ph.querySelector('.rot-t'), n = ph.querySelector('.rot-n');
      return { on, moving, vis: vis.map(v => v.i), empty: vis.filter(v => !v.ok).map(v => v.i), overlap,
               cap: t ? t.textContent : '', pos: n ? n.textContent : '' };
    });
    const first = await sample();
    if (first.none) fail(where, 'no hero slider');
    else {
      await page.evaluate(() => document.querySelector('[data-rot]').scrollIntoView({ block: 'center' }));
      const seen = new Set(), caps = new Set();
      let overl = 0, empty = 0, two = 0;
      const t0 = Date.now();
      while (Date.now() - t0 < 10000) {
        const s = await sample();
        if (s.on >= 0) seen.add(s.on);
        caps.add(`${s.cap}|${s.pos}`);
        if (s.overlap) overl++;
        if (s.empty.length) empty++;
        if (!s.moving && s.vis.length > 1) two++;
        await page.waitForTimeout(200);
      }
      row.checks.slides_seen = [...seen];
      if (overl) fail(where, `slider: two screens overlapped in ${overl} sample(s)`);
      if (empty) fail(where, `slider: an empty frame (image not loaded) was visible in ${empty} sample(s)`);
      if (two) fail(where, `slider: more than one screen visible at rest in ${two} sample(s)`);
      if (seen.size < 2) fail(where, `slider did not advance by itself in 10 s (saw ${[...seen].join(',')})`);
      if (caps.size < 2 || [...caps].some(c => !/\S\|\S/.test(c))) fail(where, `slider caption / "n / 9" counter missing or not following (${[...caps].slice(0, 3).join(' ; ')})`);
      await page.screenshot({ path: `${out}/${tag}_${lang}_${width}_hero.png` });
      // swipe left = next screen
      const box = await page.locator('[data-rot] .rot-vp, [data-rot] .track').first().boundingBox();
      if (box) {
        const before = (await sample()).on;
        const y = box.y + box.height / 2;
        await page.mouse.move(box.x + box.width * 0.8, y);
        await page.mouse.down();
        for (let k = 1; k <= 8; k++) await page.mouse.move(box.x + box.width * (0.8 - 0.07 * k), y);
        await page.mouse.up();
        await page.waitForTimeout(900);
        const after = (await sample()).on;
        if (after === before) fail(where, `swipe did not move the slider (stayed on ${before})`);
        row.checks.swipe = [before, after];
        await page.keyboard.press('Escape');                    // a stray click may open the viewer
        await page.evaluate(() => { const z = document.getElementById('zv'); if (z && z.open) z.close(); });
      }
      // pause: >= 44 px and stops the auto-advance
      const pb = await page.evaluate(() => { const b = document.querySelector('[data-rot] .rot-btn'); if (!b) return null; const r = b.getBoundingClientRect(); return { w: r.width, h: r.height }; });
      if (!pb || pb.w < 44 || pb.h < 44) fail(where, `pause button smaller than 44 px (${pb ? `${pb.w}x${pb.h}` : 'missing'})`);
      else {
        await page.click('[data-rot] .rot-btn');
        await page.waitForTimeout(600);
        const a = (await sample()).on;
        await page.waitForTimeout(5000);
        const b = (await sample()).on;
        if (a !== b) fail(where, `pause button did not stop the slider (${a} -> ${b})`);
        await page.click('[data-rot] .rot-btn');
      }
    }

    // ---------------------------------------------------------- header / layout
    // html has scroll-behavior:smooth — jump, or the header is measured mid-scroll
    await page.evaluate(() => window.scrollTo({ top: 0, behavior: 'instant' }));
    await page.waitForTimeout(500);
    const lay = await page.evaluate(() => {
      const r = s => { const e = document.querySelector(s); return e ? e.getBoundingClientRect() : null; };
      const shown = s => { const e = document.querySelector(s); if (!e) return false; const cs = getComputedStyle(e); const b = e.getBoundingClientRect(); return cs.display !== 'none' && cs.visibility !== 'hidden' && b.width > 0 && b.height > 0; };
      return { hd: r('.hd'), heroIn: r('.hero-in'), left: r('.hero-in > div'), shot: r('.hero-shot'), dots: r('[data-rot] .dots'),
               hero: r('#hero'), burger: shown('.burger'), chips: r('.hd .chips') || r('.chips'), logo: r('.hd .logo'),
               install: shown('.hd .play-top'), lang: shown('.hd .lang') };
    });
    if (mobile) {
      if (lay.dots && lay.hero) {
        const band = lay.hero.bottom - lay.dots.bottom;
        row.checks.band_under_dots = Math.round(band);
        if (band > 32) fail(where, `empty dark band of ${Math.round(band)} px under the slider dots`);
      }
    } else {
      if (lay.burger) fail(where, 'desktop shows the mobile menu button');
      if (lay.hd && lay.hd.height > 80) fail(where, `desktop header is ${Math.round(lay.hd.height)} px tall (want one compact row <= 80)`);
      if (lay.chips && lay.logo && Math.abs((lay.chips.top + lay.chips.height / 2) - (lay.logo.top + lay.logo.height / 2)) > 8) fail(where, 'desktop chips are not on the logo row');
      if (!lay.install || !lay.lang) fail(where, 'desktop header lacks Install now / language');
      if (lay.hd && lay.heroIn) {
        const gap = lay.heroIn.top - lay.hd.bottom;
        row.checks.hero_gap = Math.round(gap);
        if (Math.abs(gap - 48) > 6) fail(where, `hero starts ${Math.round(gap)} px under the header (want 48)`);
      }
      if (lay.left && lay.shot && Math.abs(lay.left.top - lay.shot.top) > 8) fail(where, `phone frame not top-aligned with the headline (${Math.round(lay.shot.top - lay.left.top)} px)`);
    }

    // ---------------------------------------------------------- mobile menu
    if (mobile) {
      const st = () => page.evaluate(() => {
        const m = document.getElementById('mm') || document.querySelector('.mm-p');
        if (!m) return { none: true };
        const cs = getComputedStyle(m), r = m.getBoundingClientRect();
        const rows = [...m.querySelectorAll('.mm-p a, a')].filter(a => a.closest('.mm-p'))
          .map(a => { const b = a.getBoundingClientRect(); return { h: b.height, on: a.classList.contains('on'), vis: b.bottom > 0 && b.top < innerHeight }; });
        return { open: cs.display !== 'none' && cs.visibility !== 'hidden' && r.width > 0 && r.height > 0,
                 full: r.left <= 1 && r.top <= 1 && r.width >= innerWidth - 1 && r.height >= innerHeight - 1,
                 rows: rows.length, small: rows.filter(x => x.h < 52 - 0.5).length, hi: rows.some(x => x.on),
                 install: !!m.querySelector('.install') || !!(m.parentElement && m.parentElement.querySelector('.mm-get .install')),
                 lock: getComputedStyle(document.documentElement).overflow === 'hidden' || getComputedStyle(document.body).overflow === 'hidden',
                 url: location.pathname + location.search, y: scrollY };
      });
      const s0 = await st();
      if (s0.none) fail(where, 'no mobile menu');
      else if (s0.open) fail(where, 'menu is open before the button is tapped');
      else {
        // open with the button
        await page.click('.burger');
        await page.waitForTimeout(400);
        let s = await st();
        await page.screenshot({ path: `${out}/${tag}_${lang}_${width}_menu.png` });
        if (!s.open) fail(where, 'menu button: menu did not open');
        if (!s.full) fail(where, 'menu is not full-screen (does not cover the viewport)');
        if (s.rows < 10) fail(where, `menu has ${s.rows} rows (want 10: Home .. language)`);
        if (s.small) fail(where, `${s.small} menu row(s) shorter than 52 px`);
        if (!s.hi) fail(where, 'current page (Home) not highlighted in the menu');
        if (!s.install) fail(where, 'menu has no Install now button');
        if (!s.lock) fail(where, 'page behind the open menu can still scroll (overflow not hidden)');
        const y0 = s.y;
        await page.mouse.move(width / 2, 400);
        await page.mouse.wheel(0, 700);
        await page.waitForTimeout(300);
        s = await st();
        if (s.y !== y0) fail(where, `page scrolled behind the open menu (${y0} -> ${s.y})`);
        // close with X
        const x = await page.$('.mm-x');
        if (!x) fail(where, 'menu has no X button');
        else {
          await x.click();
          await page.waitForTimeout(400);
          s = await st();
          if (s.open) fail(where, 'X did not close the menu');
          if (s.lock) fail(where, 'page still scroll-locked after X');
        }
        // close with Back (stays on the page)
        await page.click('.burger');
        await page.waitForTimeout(400);
        await page.evaluate(() => history.back());
        await page.waitForTimeout(700);
        s = await st();
        if (s.open) fail(where, 'Back did not close the menu');
        if (s.url !== new URL(url).pathname + new URL(url).search) fail(where, `Back left the page (${s.url})`);
        // close with Esc
        await page.click('.burger');
        await page.waitForTimeout(400);
        await page.keyboard.press('Escape');
        await page.waitForTimeout(400);
        s = await st();
        if (s.open) fail(where, 'Esc did not close the menu');
      }
    }

    // ---------------------------------------------------------- titles / shots
    await page.evaluate(() => { const b = document.querySelector('[data-rot] .rot-btn'); if (b && b.getAttribute('aria-pressed') !== 'true') b.click(); });
    await page.waitForTimeout(800);                             // audit a slider at rest
    for (const c of await page.evaluate(audit)) fail(where, c);
    for (const e of errs) fail(where, `pageerror ${e}`);
    if (!mobile) await page.screenshot({ path: `${out}/${tag}_${lang}_${width}_top.png` });
    report.push(row);
    await ctx.close();
  }
}
await browser.close();
fs.writeFileSync(`${out}/uxcheck_${tag}.json`, JSON.stringify({ base, report, problems }, null, 1));
console.log(`uxcheck ${tag}: ${problems.length} problem(s)`);
if (strict && problems.length) process.exit(1);
