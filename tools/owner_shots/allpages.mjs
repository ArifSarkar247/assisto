// ownershots.yml (owneradmin): every crawled Owner Admin page at 360 px in a
// real headless Chromium — the page must not scroll sideways (wide tables live
// in their own scroll box). Plus bn/en screenshots of the key pages at 360 px
// and desktop. Usage: node allpages.mjs <baseUrl> <outDir> <seed.json> <crawl.json>
import { chromium } from 'playwright';
import crypto from 'node:crypto';
import fs from 'node:fs';

const [base, out, seedFile, crawlFile] = process.argv.slice(2);
const seed = JSON.parse(fs.readFileSync(seedFile, 'utf8'));
const crawl = JSON.parse(fs.readFileSync(crawlFile, 'utf8'));
fs.mkdirSync(out, { recursive: true });

function b32(s) {
  const A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'; let bits = '';
  for (const c of s.replace(/=+$/, '')) bits += A.indexOf(c).toString(2).padStart(5, '0');
  const bytes = []; for (let i = 0; i + 8 <= bits.length; i += 8) bytes.push(parseInt(bits.slice(i, i + 8), 2));
  return Buffer.from(bytes);
}
function totp(secret, step) {
  const buf = Buffer.alloc(8); buf.writeBigUInt64BE(BigInt(step));
  const mac = crypto.createHmac('sha1', b32(secret)).update(buf).digest();
  const off = mac[mac.length - 1] & 15;
  return String((mac.readUInt32BE(off) & 0x7fffffff) % 1000000).padStart(6, '0');
}
async function login(ctx) {
  const page = await ctx.newPage();
  await page.goto(`${base}/owner/login?lang=bn`);
  await page.fill('input[name=phone]', '01700000001');
  await page.fill('input[name=password]', 'shots-pass-123');
  await Promise.all([page.waitForNavigation(), page.click('button.btn.primary')]);
  await page.fill('input[name=code]', totp(seed.secret, Math.floor(Date.now() / 30000)));
  await Promise.all([page.waitForNavigation(), page.click('button.btn.primary')]);
  return page;
}

const KEY = ['/owner/', '/owner/users', '/owner/integrations', '/owner/ai', '/owner/calls',
  '/owner/payments', '/owner/features', '/owner/system', '/owner/reports/errors', '/owner/quality',
  '/owner/pricing', '/owner/plans', '/owner/money', '/owner/cctv-traffic', '/owner/security'];
const urls = [...new Set(crawl.pages.filter(p => p.lang === 'bn' && p.status === 200)
  .map(p => p.url))];
const browser = await chromium.launch();
const report = { overflow: [], checked: 0 };

const mob = await browser.newContext({ viewport: { width: 360, height: 780 },
  deviceScaleFactor: 2, isMobile: true, hasTouch: true });
const mp = await login(mob);
for (const u of urls) {
  const sep = u.includes('?') ? '&' : '?';
  const r = await mp.goto(`${base}${u}${sep}lang=bn`, { waitUntil: 'load' });
  if (!r || r.status() !== 200 || !(r.headers()['content-type'] || '').includes('text/html')) continue;
  report.checked++;
  const o = await mp.evaluate(() => {
    const W = window.innerWidth;
    if (document.documentElement.scrollWidth <= W + 1) return null;
    const scrollBox = el => { for (let e = el.parentElement; e; e = e.parentElement) {
      const s = getComputedStyle(e); if (/(auto|scroll|hidden)/.test(s.overflowX)) return true; } return false; };
    const bad = [];
    for (const el of document.querySelectorAll('body *')) {
      const r = el.getBoundingClientRect();
      if (r.right > W + 1 && !scrollBox(el)) {
        bad.push(`${el.tagName.toLowerCase()}${el.className ? '.' + String(el.className).split(' ')[0] : ''} ${Math.round(r.right)}px "${(el.textContent || '').trim().slice(0, 40)}"`);
        if (bad.length >= 4) break;
      }
    }
    return { width: document.documentElement.scrollWidth, bad };
  });
  if (o) { report.overflow.push({ url: u, ...o }); console.log('OVERFLOW', u, JSON.stringify(o)); }
  if (KEY.includes(u)) await mp.screenshot({ path: `${out}/bn_360_${u.replace(/\W+/g, '_')}.png`, fullPage: true });
}
for (const u of KEY.slice(0, 8)) {
  await mp.goto(`${base}${u}?lang=en`, { waitUntil: 'load' });
  await mp.screenshot({ path: `${out}/en_360_${u.replace(/\W+/g, '_')}.png`, fullPage: true });
}
await mob.close();

await new Promise(r => setTimeout(r, 31000));   // a fresh TOTP step (anti-replay)
const desk = await browser.newContext({ viewport: { width: 1280, height: 900 } });
const dp = await login(desk);
for (const u of KEY) {
  for (const lang of ['bn', 'en']) {
    if (lang === 'en' && !KEY.slice(0, 8).includes(u)) continue;
    await dp.goto(`${base}${u}?lang=${lang}`, { waitUntil: 'load' });
    await dp.screenshot({ path: `${out}/${lang}_desktop_${u.replace(/\W+/g, '_')}.png`, fullPage: true });
  }
}
await desk.close();
await browser.close();
fs.writeFileSync(`${out}/overflow_360.json`, JSON.stringify(report, null, 1));
console.log(`checked ${report.checked} pages at 360px; ${report.overflow.length} scroll sideways`);
