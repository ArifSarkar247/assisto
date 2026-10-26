"""feature-flags: Owner Admin → Features. One row per user-facing feature
(core.feature_flags.REGISTRY): on/off for everyone, on/off in the Google Play
build, rollout %, tester allow-list, the 9 Definition-of-Done checkboxes +
status (DONE needs all 9), notes in English and Bangla, and the audit trail
of every change (OwnerAudit action "feature_flag")."""
from django.http import Http404
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import diff, done, owner_view, page

AUDIT_ACTION = "feature_flag"


def _T(request):
    from .i18n import strings
    return strings(getattr(request, "owner_lang", "bn"))


def _row_dict(f):
    return {"enabled_all": f.enabled_all, "enabled_play": f.enabled_play,
            "rollout_pct": f.rollout_pct, "allow_user_ids": list(f.allow_user_ids or []),
            "dod_status": f.dod_status, "dod_checks": list(f.dod_checks or []),
            "note": f.note, "note_bn": f.note_bn}


@require_http_methods(["GET"])
@owner_view()
def features(request):
    from core import feature_audit as FA
    from core import feature_flags as FF
    from core.models import FeatureFlag, OwnerAudit
    lang = getattr(request, "owner_lang", "bn")
    FF.ensure_seeded()
    rows = {f.key: f for f in FeatureFlag.objects.filter(key__in=FF.KEYS)}
    sec_filter = request.GET.get("section") or ""
    q = (request.GET.get("q") or "").strip().lower()
    labels = [(en if lang == "en" else bn) for en, bn in FF.DOD_CHECKS]
    sections, totals = [], {"all": 0, "on": 0, "play_hidden": 0, "done": 0, "hidden": 0}
    for sid, s_en, s_bn in FF.SECTIONS:
        items = []
        for key in FF.KEYS:
            m = FF.meta(key)
            if m["section"] != sid:
                continue
            f = rows.get(key)
            if f is None:
                continue
            label = m["label_en"] if lang == "en" else m["label_bn"]
            checks = [bool(x) for x in (f.dod_checks or [])][:FF.N_CHECKS]
            checks += [False] * (FF.N_CHECKS - len(checks))
            a = FA.AUDIT.get(key) or {}
            totals["all"] += 1
            totals["on"] += int(f.enabled_all)
            totals["play_hidden"] += int(not (f.enabled_all and f.enabled_play))
            totals["done"] += int(f.dod_status == "done")
            totals["hidden"] += int(f.dod_status == "hidden")
            if sec_filter and sec_filter != sid:
                continue
            if q and q not in key and q not in label.lower():
                continue
            items.append({
                "key": key, "label": label, "f": f,
                "checks": [(i, labels[i], checks[i]) for i in range(FF.N_CHECKS)],
                "passed": sum(checks), "pct": FF.status_pct(checks),
                "testers": len(f.allow_user_ids or []),
                "allow": ", ".join(str(i) for i in (f.allow_user_ids or [])),
                "proposed": a.get("play", ""),
                "reason": a.get("reason_en" if lang == "en" else "reason_bn", ""),
                "codes": a.get("codes", ""),
                "routes": ", ".join(m["routes"]),
            })
        if items:
            sections.append({"id": sid, "title": s_en if lang == "en" else s_bn,
                             "items": items})
    log = list(OwnerAudit.objects.filter(action=AUDIT_ACTION)
               .select_related("actor")[:60])
    ctx = {"sections": sections, "totals": totals, "n_checks": FF.N_CHECKS,
           "section_choices": [(sid, en if lang == "en" else bn)
                               for sid, en, bn in FF.SECTIONS],
           "section": sec_filter, "q": q, "log": log, "dod_labels": labels}
    return page(request, "owner/features.html", ctx, nav="features")


@require_http_methods(["POST"])
@owner_view()
def feature_save(request, key):
    from core import feature_flags as FF
    from core.models import FeatureFlag
    if not FF.is_known(key):
        raise Http404
    FF.ensure_seeded()
    f = FeatureFlag.objects.get(key=key)
    clean, problems = FF.validate(request.POST)
    back = "/owner/features"
    sec = request.POST.get("section") or ""
    if sec in {s[0] for s in FF.SECTIONS}:
        back += "?section=" + sec
    if problems:
        S.audit(request, request.owner, AUDIT_ACTION, key,
                after={"rejected": problems}, ok=False)
        return done(back, "ff_dod" if "dod_not_complete" in problems else "invalid")
    old = _row_dict(f)
    for k, v in clean.items():
        setattr(f, k, v)
    new = _row_dict(f)
    if old == new:
        return done(back, "nothing")
    f.updated_by = request.owner
    f.save()
    FF.invalidate()
    b, a = diff(old, new)
    S.audit(request, request.owner, AUDIT_ACTION, key, before=b, after=a)
    return done(back)
