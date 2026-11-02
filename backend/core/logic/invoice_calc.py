"""invoices — pure invoice logic: templates, settings normalisation, VAT/SD
math in integer POISHA, invoice numbers and the signed verification token.

Bangladesh VAT — sources (no rate is invented here):
  * Standard VAT rate 15 % — Value Added Tax and Supplementary Duty Act, 2012
    (মূল্য সংযোজন কর ও সম্পূরক শুল্ক আইন, ২০১২), section 15(3). This is the
    ONLY rate pre-filled.
  * Reduced / truncated rates are item-specific and live in the Act's THIRD
    SCHEDULE (changed by each Finance Act), so the OWNER types their own rate
    (0–15 %); the app never guesses a product's rate.
  * Supplementary duty (SD) — the Act's SECOND SCHEDULE; owner-entered, default
    0. VAT is charged on (value + SD).
  * Tax invoice "Mushak-6.3" — VAT & SD Rules 2016, rule 40(1)(c),(f): seller
    name, address, BIN; buyer name, address, BIN; invoice number; date and
    time of issue; description, quantity, unit price, value; SD rate+amount;
    VAT rate+amount; total including all taxes; authorised person.
  * MRP goods: NBR says VAT is not charged on top of the MRP — the
    "inclusive" mode (VAT shown inside the price; the total does not grow).
Assisto is not an NBR EFD/SDC device and gives no tax advice; the invoice
carries "VAT rate entered by the business".
"""
from django.core import signing

SALT = "core.invoice.v1"
STANDARD_VAT_BP = 1500          # 15.00 % — VAT & SD Act 2012 s.15(3)
MAX_VAT_BP = 1500               # no VAT rate above the standard rate
MAX_SD_BP = 50000               # SD can be large (Second Schedule); cap 500 %
MAX_SERVICE_BP = 2000           # restaurant service charge cap 20 %
MAX_LINES = 60
MAX_QTY = 100000
MAX_UNIT = 10 ** 11             # poisha (Tk 1,000,000,000)

TEMPLATES = ("cafe", "restaurant", "fine_dining", "ecommerce", "retail",
             "electronics", "lawyer", "tax_consultant", "service")
SERVICE_TEMPLATES = ("lawyer", "tax_consultant", "service")
FOOD_TEMPLATES = ("cafe", "restaurant", "fine_dining")
VAT_MODES = ("none", "exclusive", "inclusive")
SIZES = ("58", "80", "a4")

# Extra per-invoice fields each template prints (keys only; labels are in the
# app's bn/en strings).
TEMPLATE_FIELDS = {
    "cafe": ("table", "token"),
    "restaurant": ("table", "server", "guests"),
    "fine_dining": ("table", "server", "guests"),
    "ecommerce": ("order_ref", "delivery_address", "courier"),
    "retail": (),
    "electronics": ("serial", "warranty"),
    "lawyer": ("case_ref", "court", "period"),
    "tax_consultant": ("tax_year", "tin", "period"),
    "service": ("period",),
}
TEXT_MAX = {"name": 120, "address": 300, "phone": 40, "bin": 20,
            "signatory": 120, "payment_link": 300, "footer": 200}
EXTRA_MAX = 160


def _clip(v, n):
    return str(v or "").strip()[:n]


def _int(v, lo, hi, default=0):
    try:
        x = int(round(float(v)))
    except (TypeError, ValueError):
        return default
    return max(lo, min(hi, x))


def bin_ok(raw):
    """BIN as printed: 9 digits + optional 4-digit branch suffix (old style
    '000000000-0101') or the 13-digit e-BIN. Blank is allowed (not registered).
    """
    d = "".join(ch for ch in str(raw or "") if ch.isdigit())
    if not d:
        return True
    return len(d) in (9, 13) and len(str(raw).strip()) <= 20


def payment_link_ok(raw):
    s = str(raw or "").strip()
    return (not s) or (s.startswith("https://") and " " not in s and len(s) <= 300)


def default_settings(shop_name=""):
    return {"template": "retail", "name": shop_name or "", "address": "",
            "phone": "", "bin": "", "signatory": "", "payment_link": "",
            "footer": "", "vat_mode": "none", "vat_bp": STANDARD_VAT_BP,
            "sd_bp": 0, "service_bp": 0, "verify_qr": True, "size": "80",
            "lang": "bn"}


def normalize_settings(raw, base=None):
    """Merge [raw] onto [base] (or the defaults). Returns (settings, errors)
    where errors is a list of field keys that were rejected."""
    out = dict(base or default_settings())
    errors = []
    raw = raw if isinstance(raw, dict) else {}
    if "template" in raw:
        if raw["template"] in TEMPLATES:
            out["template"] = raw["template"]
        else:
            errors.append("template")
    for k, n in TEXT_MAX.items():
        if k in raw:
            out[k] = _clip(raw[k], n)
    if not bin_ok(out.get("bin")):
        errors.append("bin")
    if not payment_link_ok(out.get("payment_link")):
        errors.append("payment_link")
    if "vat_mode" in raw:
        if raw["vat_mode"] in VAT_MODES:
            out["vat_mode"] = raw["vat_mode"]
        else:
            errors.append("vat_mode")
    if "vat_bp" in raw:
        out["vat_bp"] = _int(raw["vat_bp"], 0, MAX_VAT_BP, STANDARD_VAT_BP)
    if "sd_bp" in raw:
        out["sd_bp"] = _int(raw["sd_bp"], 0, MAX_SD_BP, 0)
    if "service_bp" in raw:
        out["service_bp"] = _int(raw["service_bp"], 0, MAX_SERVICE_BP, 0)
    if "verify_qr" in raw:
        out["verify_qr"] = bool(raw["verify_qr"])
    if "size" in raw and raw["size"] in SIZES:
        out["size"] = raw["size"]
    if "lang" in raw and raw["lang"] in ("bn", "en"):
        out["lang"] = raw["lang"]
    # A VAT invoice needs the seller's BIN (Mushak-6.3); without it we fall
    # back to a plain receipt rather than print a tax line we cannot back.
    if out["vat_mode"] != "none" and not "".join(
            c for c in out.get("bin", "") if c.isdigit()):
        errors.append("bin_required")
    return out, errors


def _div_round(num, den):
    """Integer num/den rounded half-up (num, den >= 0)."""
    return (2 * num + den) // (2 * den)


def compute(lines, *, vat_mode="none", vat_bp=0, sd_bp=0, discount=0,
            service_bp=0):
    """VAT/SD math in integer poisha.

    lines: [{qty, unit}] (unit = poisha per unit as the business priced it).
    exclusive: taxable = subtotal - discount + service; SD on taxable; VAT on
               taxable + SD; total grows by SD + VAT.
    inclusive: the gross (subtotal - discount + service) already holds SD +
               VAT; taxable = gross / ((1+sd)(1+vat)); VAT is the remainder so
               taxable + SD + VAT == gross exactly.
    none:      no tax lines.
    """
    subtotal = sum(int(l["qty"]) * int(l["unit"]) for l in lines)
    discount = max(0, min(int(discount or 0), subtotal))
    net = subtotal - discount
    service = _div_round(net * int(service_bp or 0), 10000) if service_bp else 0
    gross = net + service
    sd_bp = int(sd_bp or 0)
    vat_bp = int(vat_bp or 0)
    if vat_mode == "exclusive":
        taxable = gross
        sd = _div_round(taxable * sd_bp, 10000)
        vat = _div_round((taxable + sd) * vat_bp, 10000)
        total = taxable + sd + vat
    elif vat_mode == "inclusive":
        den = (10000 + sd_bp) * (10000 + vat_bp)
        taxable = _div_round(gross * 10000 * 10000, den)
        sd = _div_round(taxable * sd_bp, 10000)
        vat = gross - taxable - sd
        total = gross
    else:
        taxable, sd, vat, total = gross, 0, 0, gross
        vat_bp = sd_bp = 0
    return {"subtotal": subtotal, "discount": discount, "service": service,
            "service_bp": int(service_bp or 0), "taxable": taxable,
            "sd": sd, "sd_bp": sd_bp, "vat": vat, "vat_bp": vat_bp,
            "total": total, "vat_mode": vat_mode}


def clean_lines(raw):
    """Manual-invoice lines → [{desc, qty, unit}] or None when invalid."""
    if not isinstance(raw, list) or not raw or len(raw) > MAX_LINES:
        return None
    out = []
    for l in raw:
        if not isinstance(l, dict):
            return None
        desc = _clip(l.get("desc"), 200)
        qty = _int(l.get("qty", 1), 0, MAX_QTY, -1)
        unit = _int(l.get("unit"), 0, MAX_UNIT, -1)
        if not desc or qty <= 0 or unit < 0:
            return None
        out.append({"desc": desc, "qty": qty, "unit": unit})
    return out


def clean_extras(template, raw):
    keys = TEMPLATE_FIELDS.get(template, ())
    raw = raw if isinstance(raw, dict) else {}
    return {k: _clip(raw.get(k), EXTRA_MAX) for k in keys if _clip(raw.get(k), EXTRA_MAX)}


def number(prefix, serial):
    return "%s-%04d" % (prefix, int(serial))


# ---- verification token: "<kind><id>.<sig>" (django signing, own salt) ----

def _signer():
    return signing.Signer(salt=SALT, sep=".")


def token_for(kind, pk):
    assert kind in ("s", "m")
    return _signer().sign("%s%d" % (kind, int(pk)))


def parse_token(token):
    """(kind, id) of a valid token, else None (forged / edited / guessed)."""
    try:
        val = _signer().unsign(str(token or ""))
    except signing.BadSignature:
        return None
    if len(val) < 2 or val[0] not in ("s", "m") or not val[1:].isdigit():
        return None
    return val[0], int(val[1:])


def verify_path(kind, pk):
    return "/r/" + token_for(kind, pk)
