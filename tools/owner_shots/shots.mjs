// ownershots.yml (adminsafe): Bangla screenshots of the Owner Admin pages,
// signed in with password + TOTP like a real owner / read-only staff member.
// Usage: node shots.mjs <baseUrl> <outDir> <seed.json>
import { chromium } from 'playwright';
import crypto from 'node:crypto';
import fs from 'node:fs';

const [base, out, seedFile] = process.argv.slice(2);
const seed = JSON.parse(fs.readFileSync(seedFile, 'utf8'));
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

async function login(ctx, phone) {
  const page = await ctx.newPage();
  await page.goto(`${base}/owner/login?lang=bn`);
  await page.fill('input[name=phone]', phone);
  await page.fill('input[name=password]', 'shots-pass-123');
  await Promise.all([page.waitForNavigation(), page.click('button.btn.primary')]);
  await page.fill('input[name=code]', totp(seed.secret, Math.floor(Date.now() / 30000)));
  await Promise.all([page.waitForNavigation(), page.click('button.btn.primary')]);
  return page;
}

async function shoot(page, path, name) {
  const r = await page.goto(`${base}${path}`, { waitUntil: 'networkidle' });
  await page.evaluate(() => document.fonts && document.fonts.ready);
  await page.screenshot({ path: `${out}/${name}.png`, fullPage: true });
  console.log(r ? r.status() : '?', name, path);
}

const t = seed.target;
const browser = await chromium.launch();
for (const [w, kind] of [[1280, 'desktop'], [390, 'mobile']]) {
  const ctx = await browser.newContext({ viewport: { width: w, height: w < 600 ? 844 : 900 },
    deviceScaleFactor: w < 600 ? 2 : 1, isMobile: w < 600 });
  const p = await login(ctx, '01700000001');
  await shoot(p, '/owner/?lang=bn', `bn_${kind}_overview`);
  await shoot(p, '/owner/users?lang=bn', `bn_${kind}_users_stats`);
  await shoot(p, '/owner/users?f=active_7&lang=bn', `bn_${kind}_users_filter_active7`);
  await shoot(p, `/owner/users/${t}?lang=bn`, `bn_${kind}_user_detail`);
  await shoot(p, '/owner/appeals?lang=bn', `bn_${kind}_appeals`);
  await shoot(p, '/owner/staff?lang=bn', `bn_${kind}_staff`);
  await shoot(p, '/owner/channel-reports?lang=bn', `bn_${kind}_reports_queue`);
  if (kind === 'desktop') {
    await shoot(p, '/owner/users?lang=en', `en_${kind}_users_stats`);
    await shoot(p, `/owner/users/${t}?lang=en`, `en_${kind}_user_detail`);
  }
  await ctx.close();
  if (kind === 'desktop') {
    // a 30 s step later so the staff code is fresh (anti-replay is per user anyway)
    const sctx = await browser.newContext({ viewport: { width: 1280, height: 900 } });
    const sp = await login(sctx, '01700000002');
    await shoot(sp, `/owner/users/${t}?lang=bn`, 'bn_desktop_readonly_user_masked');
    await shoot(sp, '/owner/pricing?lang=bn', 'bn_desktop_readonly_forbidden');
    await sctx.close();
  }
}
await browser.close();
