"""Build the Facebook page content kit: 30 days x (bn, en) post images +
owner_actions/FB_CONTENT_KIT_BN.md (captions, schedule, rules).

    ~/assisto/.venv/bin/python tools/fb_kit/make_fb_kit.py

Pure Pillow (Bangla shaping via libraqm). Brand: logo C — the white Assisto
logo on the #007AFF -> #10C978 gradient. Fonts: Inter + Noto Sans Bengali from
app/assets/fonts. Output: owner_actions/fb_kit/dayNN_<slug>_<lang>.jpg
(1080 x 1080, Facebook square post).
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
from posts import POSTS, GET  # noqa: E402

FONTS = os.path.join(REPO, "app/assets/fonts")
LOGO = os.path.join(REPO, "app/assets/branding/logo.png")      # white logo, transparent
OUT = os.path.join(REPO, "owner_actions/fb_kit")
MD = os.path.join(REPO, "owner_actions/FB_CONTENT_KIT_BN.md")
SIZE = 1080
BLUE, GREEN = (0x00, 0x7A, 0xFF), (0x10, 0xC9, 0x78)
INK = (0x0A, 0x1A, 0x3D)
LINK_BLUE = (0x00, 0x57, 0xB8)

BANNED = ("bangladesh", "bangladeshi", "বাংলাদেশ")


def font(lang, weight, size):
    if lang == "bn":
        name = {"bold": "NotoSansBengali-Bold.ttf", "semi": "NotoSansBengali-SemiBold.ttf",
                "reg": "NotoSansBengali-Regular.ttf"}[weight]
        return ImageFont.truetype(os.path.join(FONTS, name), size,
                                  layout_engine=ImageFont.Layout.RAQM)
    name = {"bold": "Inter-Bold.ttf", "semi": "Inter-SemiBold.ttf",
            "reg": "Inter-Regular.ttf"}[weight]
    return ImageFont.truetype(os.path.join(FONTS, name), size)


def _is_bn(c):
    return "\u0980" <= c <= "\u09ff" or c in "\u200c\u200d"


def runs(text, lang):
    """Split into (text, is_bengali) runs; spaces join the current run. The
    Bengali font has no Latin letters / punctuation, so those use Inter."""
    if lang != "bn":
        return [(text, False)]
    out, cur, cur_bn = [], "", None
    for c in text:
        b = cur_bn if c == " " and cur_bn is not None else _is_bn(c)
        if cur_bn is None or b == cur_bn:
            cur += c
            cur_bn = b
        else:
            out.append((cur, cur_bn))
            cur, cur_bn = c, b
    if cur:
        out.append((cur, bool(cur_bn)))
    return out


class Mixed:
    """A Bangla font with an Inter fallback for Latin / punctuation."""
    def __init__(self, lang, weight, size):
        self.lang = lang
        self.bn = font("bn", weight, size) if lang == "bn" else None
        self.en = font("en", weight, int(size * 0.92) if lang == "bn" else size)

    def length(self, d, text):
        return sum(d.textlength(t, font=self.bn if b else self.en)
                   for t, b in runs(text, self.lang))

    def draw(self, d, xy, text, fill, anchor="ls"):
        x, y = xy
        if anchor == "rm":
            x -= self.length(d, text)
            anchor = "lm"
        for t, b in runs(text, self.lang):
            f = self.bn if b else self.en
            d.text((x, y), t, font=f, fill=fill, anchor=anchor)
            x += d.textlength(t, font=f)


def gradient(w, h):
    """Diagonal #007AFF (top-left) -> #10C978 (bottom-right)."""
    base = Image.new("RGB", (w, h))
    px = base.load()
    for y in range(h):
        for x in range(w):
            t = (x + y) / float(w + h - 2)
            px[x, y] = tuple(int(BLUE[i] + (GREEN[i] - BLUE[i]) * t) for i in range(3))
    return base


def wrap(draw, text, f, max_w):
    lines = []
    for para in text.split("\n"):
        cur = ""
        for word in para.split(" "):
            test = (cur + " " + word).strip()
            if f.length(draw, test) <= max_w:
                cur = test
            else:
                if cur:
                    lines.append(cur)
                cur = word
        lines.append(cur)
    return lines


def render(day, slug, lang, head, sub, bg, logo):
    for s in (head, sub):
        assert not any(b in s.lower() for b in BANNED), (day, s)
    img = bg.copy()
    d = ImageDraw.Draw(img)
    # brand row
    img.paste(logo, (80, 80), logo)
    d.text((80 + logo.width + 22, 80 + logo.height // 2), "Assisto",
           font=font("en", "bold", 64), fill="white", anchor="lm")
    # white content card
    card = (60, 300, SIZE - 60, 840)
    d.rounded_rectangle(card, radius=48, fill="white")
    max_w = card[2] - card[0] - 120
    size = 92 if lang == "bn" else 84
    while True:
        fh = Mixed(lang, "bold", size)
        lines = wrap(d, head, fh, max_w)
        lh = int(size * (1.45 if lang == "bn" else 1.2))
        if len(lines) * lh <= 300 or size <= 52:
            break
        size -= 4
    fs = Mixed(lang, "semi", 46 if lang == "bn" else 42)
    sub_lines = wrap(d, sub, fs, max_w)
    sub_lh = int((46 if lang == "bn" else 42) * (1.45 if lang == "bn" else 1.25))
    total = len(lines) * lh + 30 + len(sub_lines) * sub_lh
    y = card[1] + (card[3] - card[1] - total) // 2
    for ln in lines:
        fh.draw(d, (card[0] + 60, y + int(lh * 0.78)), ln, INK)
        y += lh
    y += 30
    for ln in sub_lines:
        fs.draw(d, (card[0] + 60, y + int(sub_lh * 0.78)), ln, LINK_BLUE)
        y += sub_lh
    # footer pill
    foot = ("অ্যাপ নিন · " if lang == "bn" else "Get the app · ") + GET
    ff = Mixed(lang, "semi", 40 if lang == "bn" else 38)
    tw = ff.length(d, foot)
    pill = (80, 900, 80 + int(tw) + 70, 990)
    d.rounded_rectangle(pill, radius=45, fill="white")
    ff.draw(d, (pill[0] + 35, (pill[1] + pill[3]) // 2), foot, LINK_BLUE, anchor="lm")
    # day tag
    tag = ("দিন %s" % str(day).translate(str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯"))
           if lang == "bn" else "Day %d" % day)
    Mixed(lang, "semi", 40).draw(d, (SIZE - 80, 80 + logo.height // 2), tag, "white",
                                 anchor="rm")
    name = "day%02d_%s_%s.jpg" % (day, slug, lang)
    img.save(os.path.join(OUT, name), "JPEG", quality=88, optimize=True)
    return name


def md(rows):
    bn = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")
    out = [
        "# Assisto — ফেসবুক পেজ কনটেন্ট কিট (৩০ দিন)",
        "",
        "প্রতিদিন একটি পোস্ট। প্রতিটি দিনের জন্য বাংলা ও ইংরেজি ক্যাপশন আর তৈরি ছবি "
        "(`owner_actions/fb_kit/`, ১০৮০×১০৮০)। ছবি আবার বানাতে: "
        "`~/assisto/.venv/bin/python tools/fb_kit/make_fb_kit.py` (লেখা বদলাতে `tools/fb_kit/posts.py`)।",
        "",
        "## পোস্ট করার আগে নিয়ম (Meta ও Google Play নীতি)",
        "",
        "1. **শুধু সত্য দাবি।** প্রতিটি পোস্টের ফিচার পোস্টের আগে নিজের ফোনে একবার খুলে দেখুন। "
        "\"অন্য অ্যাপের চেয়ে ভালো\", \"সেরা\", \"১০০% নিরাপদ\" — এসব লিখবেন না।",
        "2. **\"শর্ত\" কলামে কিছু থাকলে** সেটি আগে নিশ্চিত করুন (যেমন Business প্ল্যান, Meta অনুমোদন)। "
        "যে ফিচার চাবি/অনুমোদন ছাড়া চলে না, সেটিকে চালু বলে পোস্ট করবেন না।",
        "3. **ক্রেডিট টাকা নয়।** আমন্ত্রণ বা ফাউন্ডিং পোস্টে কখনো \"টাকা আয় করুন\" লিখবেন না — "
        "ক্রেডিট শুধু অ্যাপের AI সুবিধার জন্য, তোলা যায় না।",
        "4. **ভুয়া তাড়া নয়।** \"আর মাত্র ১০টি আসন\" লিখবেন শুধু যদি Owner Admin → Founders-এ আসল সংখ্যা তাই দেখায়।",
        "5. **স্বাস্থ্য/নিরাপত্তা পোস্টে** \"এটি চিকিৎসা নয়, জরুরি হলে ৯৯৯\" লাইনটি রাখুন। SOS কখনো পুলিশের বিকল্প বলবেন না।",
        "6. **কারো ছবি/নম্বর ব্যবহার করবেন না** তাঁর অনুমতি ছাড়া; স্ক্রিনশটে আসল গ্রাহকের তথ্য থাকলে ঝাপসা করুন।",
        "7. বুস্ট/বিজ্ঞাপন করলে Meta-র বিজ্ঞাপন নীতি মেনে চলুন: আগে-পরে তুলনার দাবি, ব্যক্তিগত বৈশিষ্ট্য ধরে কথা বলা "
        "(\"আপনি কি অসুস্থ?\") — এসব এড়িয়ে চলুন।",
        "8. লিংক: অ্যাপ পেতে `https://" + GET + "`; কারো আমন্ত্রণ কোড থাকলে তাঁর নিজের লিংক `lifeassisto.com/i/<কোড>`।",
        "",
        "## সাপ্তাহিক ছন্দ (প্রস্তাব)",
        "",
        "- সকাল ৯টা বা রাত ৯টা (আপনার পেজ ইনসাইটে যখন বেশি মানুষ থাকে)।",
        "- সপ্তাহে একদিন \"কমেন্টে বলুন\" ধরনের প্রশ্ন — এতে রিচ বাড়ে, কিন্তু \"শেয়ার করলে পুরস্কার\" দেবেন না (Meta নীতিতে এনগেজমেন্ট-বেইট নিষেধ)।",
        "- প্রতিটি কমেন্টের উত্তর ২৪ ঘণ্টার মধ্যে।",
        "",
        "## ৩০ দিনের তালিকা",
        "",
        "| দিন | ফিচার | শর্ত | ছবি (বাংলা / English) |",
        "|---|---|---|---|",
    ]
    for r in rows:
        (day, slug, feat, needs, *_rest), bn_img, en_img = r
        out.append("| %s | %s | %s | [বাংলা](fb_kit/%s) · [English](fb_kit/%s) |"
                   % (str(day).translate(bn), feat, needs or "—", bn_img, en_img))
    out += ["", "## ক্যাপশন", ""]
    for r in rows:
        (day, slug, feat, needs, bh, bs, bc, eh, es, ec), bn_img, en_img = r
        out += [
            "### দিন %s — %s" % (str(day).translate(bn), feat),
            "",
            ("> শর্ত: %s — পোস্টের আগে নিশ্চিত করুন।" % needs) if needs else "",
            "**বাংলা:** %s" % bc,
            "",
            "**English:** %s" % ec,
            "",
            "ছবি: `fb_kit/%s`, `fb_kit/%s`" % (bn_img, en_img),
            "",
        ]
    return "\n".join(x for x in out if x is not None) + "\n"


def main():
    os.makedirs(OUT, exist_ok=True)
    bg = gradient(SIZE, SIZE)
    logo = Image.open(LOGO).convert("RGBA").resize((150, 150), Image.LANCZOS)
    rows = []
    for p in POSTS:
        day, slug, feat, needs, bh, bs, bc, eh, es, ec = p
        for txt in (bc, ec):
            assert not any(b in txt.lower() for b in BANNED), (day, txt)
        bn_img = render(day, slug, "bn", bh, bs, bg, logo)
        en_img = render(day, slug, "en", eh, es, bg, logo)
        rows.append((p, bn_img, en_img))
        print("day", day, bn_img, en_img)
    with open(MD, "w", encoding="utf-8") as f:
        f.write(md(rows))
    print("wrote", MD)


if __name__ == "__main__":
    main()
