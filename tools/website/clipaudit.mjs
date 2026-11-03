// Shared clip audit (website.yml clipcheck.mjs + livecheck.mjs): screenshots
// clipped / cropped / squeezed / under a frame corner; headings clipped or covered.
export const audit = () => {
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

export const covered = async (page) => {
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

