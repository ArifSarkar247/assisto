// website.yml job `live` (sitelive, 3 Nov): READ-ONLY check of the LIVE
// https://lifeassisto.com (v3 live since owner OK 3 Nov 03:06). Runs in CI
// only (manual + nightly), never on the server, never a load test: one browser
// context per (lang, width) so assets come from the browser cache; Install /
// APK links are checked with HEAD only (the APK body is never downloaded).
//
// Fails on: HTTP != 200, console errors / page errors, clipped or covered
// headings / screenshots (shared clipaudit.mjs), HTML without
// `Cache-Control: no-cache` + ETag, a versioned asset (?v=) that is not
// `immutable`, an Install / Play / APK link that does not answer 200 to HEAD,
// or an in-page #anchor link whose target is missing.
// Owner HERO + FIXES (3 Nov 03:30), home at 360/390/430 + desktop, bn + en:
// h1 starts "Assisto:" with the slogan under it; the sticky Install bar is
// hidden while the hero Install button is on screen and shows after it
// scrolls away (mobile); the taka-sign font (Taka3, U+09F3) loads on every page.
//   node livecheck.mjs https://lifeassisto.com <outDir>
//   node livecheck.mjs http://127.0.0.1:8000 <outDir> local   (website.yml site job:
//        same checks on the CI server, install links not fetched)
import { chromium } from 'playwright';
import fs from 'node:fs';
import { audit, covered } from './clipaudit.mjs';

const [base, out, mode] = process.argv.slice(2);
const local = mode === 'local';
const origin = new URL(base).origin;
const groups = ['ai', 'circle', 'safety', 'cctv', 'business', 'work', 'daily'];
const pages = [['home', '/'], ...groups.map(g => [`group_${g}`, `/features/${g}`]),
  ['pricing', '/pricing'], ['security', '/security'], ['help', '/help']];
fs.mkdirSync(out, { recursive: true });

const report = { base, when: new Date().toISOString(), pages: [], links: {}, problems: [] };
const fail = (where, msg) => { report.problems.push(`${where}: ${msg}`); console.log(`FAIL ${where}: ${msg}`); };
const installLinks = new Map();   // href -> first page seen on

const browser = await chromium.launch();
// bare "/" (no ?lang) once: the default language must load too
{
  const ctx = await browser.newContext();
  const p = await ctx.newPage();
  const r = await p.goto(`${base}/`, { waitUntil: 'domcontentloaded' });
  if (!r || r.status() !== 200) fail('/', `HTTP ${r ? r.status() : 'none'}`);
  await ctx.close();
}
for (const lang of ['bn', 'en']) {
  for (const width of [360, 390, 430, 1280]) {
    const mobile = width < 600;
    const ctx = await browser.newContext({ viewport: { width, height: mobile ? 800 : 900 },
      deviceScaleFactor: mobile ? 2 : 1, isMobile: mobile, hasTouch: mobile, reducedMotion: 'reduce' });
    const page = await ctx.newPage();
    let where = '';
    const consoleErrs = [];
    page.on('console', m => { if (m.type() === 'error') consoleErrs.push(m.text().slice(0, 200)); });
    page.on('pageerror', e => consoleErrs.push('pageerror ' + String(e).slice(0, 200)));
    page.on('requestfailed', rq => {
      if (rq.url().startsWith(origin)) consoleErrs.push(`request failed ${rq.url()} ${rq.failure() && rq.failure().errorText}`);
    });
    page.on('response', res => {
      const u = new URL(res.url());
      if (u.origin !== origin || res.status() >= 300) return;
      const cc = res.headers()['cache-control'] || '';
      if (u.searchParams.has('v') && !/immutable/.test(cc)) fail(where, `asset not immutable: ${u.pathname} (${cc || 'no Cache-Control'})`);
    });
    for (const [name, path] of pages) {
      if ((width === 390 || width === 430) && name !== 'home') continue;   // extra phone widths: home only
      where = `${lang} ${width} ${path}`;
      consoleErrs.length = 0;
      const url = `${base}${path}?lang=${lang}`;
      const r = await page.goto(url, { waitUntil: 'networkidle' });
      const status = r ? r.status() : 0;
      const h = r ? r.headers() : {};
      if (status !== 200) fail(where, `HTTP ${status}`);
      if (!/no-cache/.test(h['cache-control'] || '')) fail(where, `HTML Cache-Control is "${h['cache-control'] || ''}" (want no-cache)`);
      if (!h['etag']) fail(where, 'HTML has no ETag');
      await page.evaluate(async () => {
        for (let y = 0; y < document.body.scrollHeight; y += 400) { window.scrollTo(0, y); await new Promise(r => setTimeout(r, 40)); }
        await Promise.all([...document.images].filter(i => !i.complete).map(i => new Promise(r => { i.onload = i.onerror = r; })));
        window.scrollTo(0, 0);
      });
      const clip = [...await page.evaluate(audit), ...await covered(page)];
      // taka sign: the Taka3 face must load (Noto's ৳ reads as "b")
      const taka = await page.evaluate(async () => {
        try { return (await document.fonts.load('600 20px Taka3', '৳')).length; } catch (e) { return -1; }
      });
      if (taka < 1) fail(where, 'taka font (Taka3, U+09F3) did not load');
      if (name === 'home') {
        const hero = await page.evaluate(() => ({
          h1: (document.querySelector('#hero-h') || {}).textContent || '',
          slogan: !!document.querySelector('.hero .slogan'),
          slides: document.querySelectorAll('[data-rot] .slide').length,
        }));
        if (!/^\s*Assisto:/.test(hero.h1)) fail(where, `hero h1 does not start with "Assisto:" (${hero.h1.trim().slice(0, 60)})`);
        if (!hero.slogan) fail(where, 'hero slogan missing');
        if (hero.slides < 9) fail(where, `hero has ${hero.slides} slides (want 9)`);
        if (mobile) {
          const shown = () => page.evaluate(() => {
            const b = document.querySelector('.pbar');
            if (!b) return null;
            const cs = getComputedStyle(b), r = b.getBoundingClientRect();
            return cs.display !== 'none' && cs.visibility !== 'hidden' && r.top < innerHeight - 4;
          });
          await page.evaluate(() => window.scrollTo(0, 0));
          await page.waitForTimeout(400);
          if (await shown()) fail(where, 'sticky Install bar shows while the hero Install button is on screen');
          await page.evaluate(() => { const b = document.querySelector('#hero .install'); window.scrollTo(0, b.getBoundingClientRect().bottom + scrollY + 200); });
          await page.waitForTimeout(600);
          if (!await shown()) fail(where, 'sticky Install bar does not appear after the hero Install button scrolls away');
          await page.evaluate(() => window.scrollTo(0, 0));
          await page.waitForTimeout(300);
        }
      }
      for (const c of clip) fail(where, c);
      // tplfix (owner 3 Nov 16:33): no leaked Django template syntax on any public page
      const leak = await page.evaluate(() => {
        const raw = document.documentElement.outerHTML, txt = document.body.innerText;
        const hits = [];
        for (const t of ['{#', '{%']) if (raw.includes(t)) hits.push('html ' + t);
        for (const t of ['{#', '#}', '{%', '%}', '{{', '}}']) if (txt.includes(t)) hits.push('text ' + t);
        return hits;
      });
      for (const l of leak) fail(where, `leaked template syntax (${l})`);
      for (const e of consoleErrs) fail(where, `console: ${e}`);
      const links = await page.$$eval('a[data-play], a.install, a[href$=".apk"], a[href*=".apk?"]',
        as => as.map(a => ({ href: a.href, raw: a.getAttribute('href') })));
      for (const l of links) {
        if (l.raw && l.raw.startsWith('#')) {
          const ok = await page.evaluate(id => !!document.getElementById(id), l.raw.slice(1));
          if (!ok) fail(where, `install link ${l.raw} points to a missing section`);
        } else if (!local && /^https?:/.test(l.href) && !installLinks.has(l.href)) {
          installLinks.set(l.href, where);
        }
      }
      report.pages.push({ lang, width, page: name, status, cache: h['cache-control'] || '', etag: !!h['etag'], clip: clip.length, console: consoleErrs.length });
      await page.screenshot({ path: `${out}/${lang}_${mobile ? 'mobile360' : 'desktop'}_${name}.png`, fullPage: true });
    }
    await ctx.close();
  }
}
await browser.close();

// Install / Play / APK links: HEAD only, follow redirects, never the body.
for (const [href, seen] of installLinks) {
  let status = 0, err = '';
  try {
    const r = await fetch(href, { method: 'HEAD', redirect: 'follow' });
    status = r.status;
    report.links[href] = { status, type: r.headers.get('content-type'), length: r.headers.get('content-length') };
  } catch (e) { err = String(e); report.links[href] = { error: err }; }
  if (status !== 200) fail(seen, `install link ${href} -> ${status || err}`);
}
if (!local && !installLinks.size) fail('site', 'no Install / Play / APK link found on any page');

fs.writeFileSync(`${out}/livecheck.json`, JSON.stringify(report, null, 1));
console.log(`live check ${base}: ${report.pages.length} page loads, ${installLinks.size} install link(s), ${report.problems.length} problem(s)`);
if (report.problems.length) process.exit(1);
