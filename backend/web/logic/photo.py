"""W3 — passport / visa / NID / stamp photo maker. Crop + resize to standard specs.

Honest scope (SPEC v2.1 §21, web-adapted):
  - WORKS NOW, offline, CPU-light: precise crop + resize to the official mm/px specs,
    plus a 4×6 inch print sheet for the local printer.
  - NEVER alters identity: no face-swap, no beautify, no skin edits.
  - KEY-GATED (honest): automatic background removal/replacement needs an image-AI
    key. Without a key we say so plainly and give the user a guidance checklist
    instead of silently producing a wrong result.

All specs below are standard published sizes (BD e-passport 35×45 mm, US/DV visa
600×600 px, etc.) — rendered at 300 DPI. No facts invented.
"""
import io
from PIL import Image

# key -> (label_bn, label_en, width_px, height_px, physical, needs_white_bg)  @300dpi
PRESETS = {
    "bd_passport": ("বাংলাদেশ ই-পাসপোর্ট (35×45 mm)", "Bangladesh e-Passport (35×45 mm)",
                    413, 531, "35×45 mm", True),
    "bd_mrp": ("বাংলাদেশ MRP / ফর্মের ছবি (45×55 mm)", "Bangladesh MRP / form photo (45×55 mm)",
               531, 650, "45×55 mm", True),
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

# Honest per-size notes (w1-webphoto SEO table). Verified 21 Oct 2026 against
# public guides; official rules can change and missions abroad may differ, so
# the page always says "confirm with the office before printing".
PRESET_NOTES = {
    "bn": {
        "bd_passport": "ই-পাসপোর্টের বায়োমেট্রিক ছবি সাধারণত পাসপোর্ট অফিসেই তোলা হয়; সত্যায়ন/অন্য কাগজে ৩৫×৪৫ মিমি ছবি লাগে।",
        "bd_mrp": "পুরনো MRP আবেদন ও কিছু দূতাবাসের ফর্মে ৪৫×৫৫ মিমি ছবি চাওয়া হয়।",
        "bd_nid": "NID সংশোধন/আবেদনের ছোট ছবি — অফিসের নির্দেশনা মিলিয়ে নিন।",
        "passport_2x2": "যেসব দেশ ২×২ ইঞ্চি (৫১×৫১ মিমি) ছবি চায়।",
        "us_visa": "যুক্তরাষ্ট্রের ভিসা ও DV লটারি: ৬০০×৬০০ পিক্সেল, সাদা ব্যাকগ্রাউন্ড।",
        "schengen": "শেঞ্জেন (ইউরোপ) ভিসা: ৩৫×৪৫ মিমি।",
        "job": "চাকরির অনলাইন আবেদনের সাধারণ ছবি (৩০০×৪০০ পিক্সেল)।",
        "stamp": "স্ট্যাম্প সাইজ ছবি (৩০০×৩৬০ পিক্সেল)।",
    },
    "en": {
        "bd_passport": "The e-Passport biometric photo is usually taken at the passport office; 35×45 mm prints are used for attestation and other papers.",
        "bd_mrp": "Older MRP forms and some missions abroad still ask for 45×55 mm.",
        "bd_nid": "Small photo for NID applications/corrections — check the office's instructions.",
        "passport_2x2": "For countries that ask for a 2×2 inch (51×51 mm) photo.",
        "us_visa": "US visa and DV lottery: 600×600 pixels, white background.",
        "schengen": "Schengen (Europe) visa: 35×45 mm.",
        "job": "Common online job-application photo (300×400 pixels).",
        "stamp": "Stamp-size photo (300×360 pixels).",
    },
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
