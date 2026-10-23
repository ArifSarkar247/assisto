"""p2-money: apply the owner's P2 order to the STORED pricing row — only where
the stored value is still the OLD shipped default (an owner edit is never
overwritten):

  ad_rewards.appopen_daily_cap  4 -> 3   ("max 3 per day")
  limits.trial_days             7 -> 3   ("3-day free trial")

New keys (appopen_start_day, appopen_skip_after_s, community_sponsored_*,
offer_notif_daily_cap, offers_*, sponsors_enabled, limits.trial_on_signup)
need no data change — normalize() fills their defaults. The annual discount
is NOT touched (sold price is clamped in code; Owner Admin warns).
Reversible: the reverse puts back 4 / 7 where the value is still 3.
"""
from django.db import migrations

CHANGES = (("ad_rewards", "appopen_daily_cap", 4, 3),
           ("limits", "trial_days", 7, 3))


def _apply(apps, frm_idx, to_idx, actor):
    PricingConfig = apps.get_model("core", "PricingConfig")
    row = PricingConfig.objects.filter(key="global").first()
    if row is None or not isinstance(row.data, dict):
        return
    data = dict(row.data)
    changed = []
    for sect, key, old, new in CHANGES:
        vals = (old, new)
        blk = data.get(sect)
        if isinstance(blk, dict) and blk.get(key) == vals[frm_idx]:
            blk = dict(blk)
            blk[key] = vals[to_idx]
            data[sect] = blk
            changed.append("%s.%s" % (sect, key))
    if changed:
        row.data = data
        audit = list(row.audit or [])
        audit.insert(0, {"path": "migration", "actor": actor, "changed": changed,
                         "note": "p2-money owner order: app-open max 3/day, 3-day trial"})
        row.audit = audit[:200]
        row.save(update_fields=["data", "audit", "updated_at"])


def forward(apps, schema_editor):
    _apply(apps, 0, 1, "migration:0069")


def backward(apps, schema_editor):
    _apply(apps, 1, 0, "migration:0069-reverse")


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0068_p2_money_sponsors"),
    ]

    operations = [migrations.RunPython(forward, backward)]
