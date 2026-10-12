"""W3 — passport / visa / job photo maker. Crop + resize to standard specs.
User's own photo only. No face-swap, no ML background removal (CPU-light, honest).
Background replacement needs an image-AI key → shown as a separate option."""
import io
from PIL import Image

# key -> (label_bn, width_px, height_px, physical)  @300dpi
PRESETS = {
    "passport_2x2": ("পাসপোর্ট / ভিসা (2x2 inch)", 600, 600, "2×2 inch"),
    "bd_passport": ("বাংলাদেশ পাসপোর্ট (45×35 mm)", 413, 531, "35×45 mm"),
    "us_visa": ("US/DV ভিসা (600×600)", 600, 600, "600×600 px"),
    "job": ("চাকরির আবেদন ছবি (300×400)", 300, 400, "পোর্ট্রেট"),
    "stamp": ("স্ট্যাম্প সাইজ (300×360)", 300, 360, "স্ট্যাম্প"),
}


def make_photo(file_bytes, preset_key):
    label, tw, th, phys = PRESETS.get(preset_key, PRESETS["passport_2x2"])
    img = Image.open(io.BytesIO(file_bytes))
    img = img.convert("RGB")
    w, h = img.size
    target_ar = tw / th
    ar = w / h
    if ar > target_ar:
        new_w = int(round(h * target_ar))
        left = (w - new_w) // 2
        box = (left, 0, left + new_w, h)
    else:
        new_h = int(round(w / target_ar))
        # slight upward bias so the head/top is kept
        top = int((h - new_h) * 0.30)
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
    # fit cell preserving aspect
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
