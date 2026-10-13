"""
CSV import/export for leads (spec §Leads/contacts/companies + data export).

CSV is used because it is universal and opens natively in Excel/Google Sheets —
no extra dependency on this shared server. If `openpyxl` is ever installed, the
`leads_to_xlsx` helper lights up; otherwise callers fall back to CSV cleanly
(never a broken download).

Import is additive + de-dup-aware: a row whose email/phone matches an existing
lead updates that lead instead of creating a duplicate. Scoring is re-run on
import so numbers stay honest (deterministic). Nothing is invented — unknown
columns are ignored, blanks stay blank.
"""
import csv
import io

from .models import Lead, CrmOrg
from . import dupes

LEAD_COLUMNS = ["name", "company", "industry", "company_size", "source",
                "phone", "email", "status", "score", "priority"]

# Characters that make a spreadsheet treat a cell as a formula / command.
_FORMULA_PREFIXES = ("=", "+", "-", "@", "\t", "\r")


def _sanitize_cell(value):
    """Neutralise CSV/XLSX formula injection: any user-derived text starting with
    an Excel/Sheets trigger char (= + - @ tab CR) is prefixed with a single quote
    so the spreadsheet renders it as literal text instead of executing it."""
    if value is None:
        return value
    if isinstance(value, str) and value and value[0] in _FORMULA_PREFIXES:
        return "'" + value
    return value


def leads_to_csv(leads_qs):
    """Serialise a lead queryset to a CSV string (UTF-8, BOM for Excel Bangla)."""
    buf = io.StringIO()
    buf.write("﻿")  # BOM so Excel renders Bangla correctly
    w = csv.writer(buf)
    w.writerow(LEAD_COLUMNS)
    for l in leads_qs:
        w.writerow([_sanitize_cell(l.name), _sanitize_cell(l.company),
                    _sanitize_cell(l.industry), l.company_size,
                    _sanitize_cell(l.source), _sanitize_cell(l.phone),
                    _sanitize_cell(l.email), _sanitize_cell(l.status),
                    l.score, _sanitize_cell(l.priority)])
    return buf.getvalue()


def import_leads_csv(org, file_obj, assigned_to=None):
    """Create/update leads from an uploaded CSV. Returns a summary dict.

    De-dup: a row with an email or phone already present (same org) updates the
    existing lead's blank fields rather than creating a duplicate.
    """
    from . import logic as core_logic  # original P8 scoring helper
    raw = file_obj.read()
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8-sig", errors="replace")
    reader = csv.DictReader(io.StringIO(raw))
    created = updated = skipped = 0
    valid_ind = dict(Lead.INDUSTRIES)
    valid_src = dict(Lead.SOURCES)
    valid_status = dict(Lead.STATUSES)

    for row in reader:
        name = (row.get("name") or "").strip()
        company = (row.get("company") or "").strip()
        email = (row.get("email") or "").strip()
        phone = (row.get("phone") or "").strip()
        if not (name or company or email or phone):
            skipped += 1
            continue

        existing = None
        if email:
            existing = Lead.objects.filter(org=org, email__iexact=email).first()
        if not existing and phone:
            norm = dupes._norm_phone(phone)
            for cand in Lead.objects.filter(org=org):
                if dupes._norm_phone(cand.phone) == norm and norm:
                    existing = cand
                    break

        industry = (row.get("industry") or "other").strip()
        if industry not in valid_ind:
            industry = "other"
        source = (row.get("source") or "manual").strip()
        if source not in valid_src:
            source = "manual"
        status = (row.get("status") or "new").strip()
        if status not in valid_status:
            status = "new"
        try:
            size = int(row.get("company_size") or 0)
        except (TypeError, ValueError):
            size = 0

        if existing:
            for f, v in (("name", name), ("company", company),
                         ("email", email), ("phone", phone)):
                if v and not getattr(existing, f):
                    setattr(existing, f, v)
            if size and not existing.company_size:
                existing.company_size = size
            existing.save()
            updated += 1
            lead = existing
        else:
            lead = Lead.objects.create(
                org=org, name=name, company=company, industry=industry,
                company_size=size, source=source, phone=phone, email=email,
                status=status, assigned_to=assigned_to)
            created += 1
        # Re-score deterministically (uses any captured messages; manual→base).
        try:
            core_logic.score_lead(lead)
        except Exception:
            pass

    return {"ok": True, "created": created, "updated": updated,
            "skipped": skipped}


def leads_to_xlsx(leads_qs):
    """Return (bytes, filename) if openpyxl is available, else None. Callers must
    fall back to CSV when this returns None — we never ship a broken file."""
    try:
        import openpyxl
    except Exception:
        return None
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "Leads"
    ws.append(LEAD_COLUMNS)
    for l in leads_qs:
        ws.append([_sanitize_cell(l.name), _sanitize_cell(l.company),
                   _sanitize_cell(l.industry), l.company_size,
                   _sanitize_cell(l.source), _sanitize_cell(l.phone),
                   _sanitize_cell(l.email), _sanitize_cell(l.status),
                   l.score, _sanitize_cell(l.priority)])
    out = io.BytesIO()
    wb.save(out)
    return out.getvalue(), "leads.xlsx"
