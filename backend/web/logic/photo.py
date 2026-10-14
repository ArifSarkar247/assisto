"""W3 — passport / visa / NID / stamp photo maker. Crop + resize to standard specs.

Honest scope (SPEC v2.1 §21, web-adapted):
  - WORKS NOW, offline, CPU-light: precise crop + resize to the official mm/px specs,
    plus a 4×6 inch print sheet for the local printer.
  - NEVER alters identity: no face-swap, no beautify, no skin edits.
  - KEY-GATED (honest): automatic background removal/replacement needs an image-AI
    key. Without a key we say so plainly and give the user a guidance checklist
    instead of silently producing a wrong result.

All specs below are standard published sizes (BD passport 45×35 mm, US/DV visa
600×600 px, etc.) — rendered at 300 DPI. No facts invented.
"""
import io
from PIL import Image

# key -> (label_bn, label_en, width_px, height_px, physical, needs_white_bg)  @300dpi
PRESETS = {
    "bd_passport": ("বাংলাদেশ পাসপোর্ট (45×35 mm)", "Bangladesh Passport (45×35 mm)",
                    413, 531, "35×45 mm", True),
    "bd_nid": ("জাতীয় পরিচয়পত্র (NID)", "National ID (NID)", 300, 360, "~25×30 mm", True),
    "passport_2x2": ("পাসপোর্ট / ভিসা (2×2 inch)", "Passport / Visa (2×2 inch)",
                     600, 600, "2×2 inch", True),
    "us_visa": ("US/DV ভিসা (600×600)", "US/DV Visa (600×600)", 600, 600, "600×600 px", True),
    "schengen": ("শেঞ্জেন ভিসা (35×45 mm)", "Schengen Visa (35×45 mm)",
                 413, 531, "35×45 mm", True),
    "job": ("চাকরির আবেদন ছবি (300×400)", "Job application photo (300×400)",
            300, 400, "portrait", False),
    "stamp": ("স্ট্যাম্প সাইজ (300×360)", "Stamp size (300×360)", 300, 360, "stamp", False),
}

GUIDANCE = {
    "bn": [
        "সোজা হয়ে ক্যামেরার দিকে তাকান, মুখ পরিষ্কার দেখা যাক।",
        "সাদা বা হালকা একরঙা ব্যাকগ্রাউন্ডে ছবি তুলুন।",
        "চশমার ঝলক, টুপি বা ছায়া এড়িয়ে চলুন (ধর্মীয় কারণে হলে ভিন্ন)।",
        "মাথা ও কাঁধ ফ্রেমে থাকুক; মুখ ফ্রেমের ৭০-৮০% জুড়ে থাকা ভালো।",
    ],
    "en": [
        "Face the camera straight-on with a clear, neutral expression.",
        "Use a plain white or light, single-colour background.",
        "Avoid glare on glasses, hats, or shadows (religious head-cover is fine).",
        "Keep head and shoulders in frame; the face should fill ~70–80%.",
    ],
}

# Honest key-gated note, shown whenever a preset wants a white background.
BG_NOTE = {
    "bn": "ব্যাকগ্রাউন্ড স্বয়ংক্রিয়ভাবে সাদা করা এখন সম্ভব নয় (এর জন্য ইমেজ-AI কী লাগে)। "
          "আপাতত ক্রপ ও মাপ ঠিক করা হয়েছে — সাদা ব্যাকগ্রাউন্ডে তোলা ছবি দিলে ফল সবচেয়ে ভালো।",
    "en": "Automatic background whitening isn't available yet (it needs an image-AI key). "
          "For now we crop and size precisely — for best results, shoot against a white wall.",
}


def preset_label(preset_key, lang="bn"):
    p = PRESETS.get(preset_key, PRESETS["bd_passport"])
    return (p[0] if lang == "bn" else p[1]), p[4], p[5]


def make_photo(file_bytes, preset_key, lang="bn"):
    label_bn, label_en, tw, th, phys, _wb = PRESETS.get(preset_key, PRESETS["bd_passport"])
    label = label_bn if lang == "bn" else label_en
    img = Image.open(io.BytesIO(file_bytes)).convert("RGB")
    w, h = img.size
    target_ar = tw / th
    ar = w / h
    if ar > target_ar:
        new_w = int(round(h * target_ar))
        left = (w - new_w) // 2
        box = (left, 0, left + new_w, h)
    else:
        new_h = int(round(w / target_ar))
        top = int((h - new_h) * 0.30)  # upward bias keeps the head
        box = (0, top, w, top + new_h)
    img = img.crop(box).resize((tw, th), Image.LANCZOS)
    out = io.BytesIO()
    img.save(out, "JPEG", quality=92)
    return out.getvalue(), f"{label} · {phys}"


def print_sheet(photo_jpeg, cols=2, rows=2, dpi_w=1200, dpi_h=1800):
    """Tile copies on a 4×6 inch sheet (300dpi) for printing."""
    cell = Image.open(io.BytesIO(photo_jpeg)).convert("RGB")
    sheet = Image.new("RGB", (dpi_w, dpi_h), "white")
    margin = 30
    cw = (dpi_w - margin * (cols + 1)) // cols
    ch = (dpi_h - margin * (rows + 1)) // rows
    cell_ar = cell.width / cell.height
    if cw / ch > cell_ar:
        cw = int(ch * cell_ar)
    else:
        ch = int(cw / cell_ar)
    thumb = cell.resize((cw, ch), Image.LANCZOS)
    for r in range(rows):
        for c in range(cols):
            x = margin + c * (cw + margin)
            y = margin + r * (ch + margin)
            sheet.paste(thumb, (x, y))
    out = io.BytesIO()
    sheet.save(out, "JPEG", quality=92)
    return out.getvalue()
