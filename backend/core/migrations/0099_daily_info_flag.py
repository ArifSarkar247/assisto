# unseen-rename (owner 27 Oct): the daily info hub's flag key changes from
# `unseen_world` to `daily_info`, and `unseen_world` is given to the new
# (not yet built) Unseen World travel feature, default OFF.
#
# Data only, no schema change:
#   1. the owner's existing `unseen_world` row (on/off, Play, rollout, testers,
#      DoD ticks, notes) is copied to a new `daily_info` row, so the hub keeps
#      exactly the visibility the owner chose;
#   2. the `unseen_world` row is then reset to the new feature's default:
#      hidden for everyone and in Play, no testers, DoD unticked.
# Without step 2 the old row (enabled_all=True) would switch the new travel
# feature ON the moment it ships. Reverse = the opposite copy.
# Numbered 0096 after 0095_billing_v2; renumber at merge if 0096 is taken.
from django.db import migrations

FIELDS = ("enabled_all", "enabled_play", "rollout_pct", "allow_user_ids",
          "note", "note_bn", "dod_status", "dod_checks")


def forward(apps, schema_editor):
    FF = apps.get_model("core", "FeatureFlag")
    old = FF.objects.filter(key="unseen_world").first()
    if old is None:
        return            # never seeded: registry defaults already right
    if not FF.objects.filter(key="daily_info").exists():
        FF.objects.create(key="daily_info", updated_by=old.updated_by,
                          **{f: getattr(old, f) for f in FIELDS})
    old.enabled_all = False
    old.enabled_play = False
    old.rollout_pct = 100
    old.allow_user_ids = []
    old.dod_status = "hidden"
    old.dod_checks = [False] * 9
    old.note = ("NEW travel discovery feature (owner 27 Oct), not built yet. "
                "Plan: owner_actions/UNSEEN_WORLD_PLAN_BN.md.")
    old.note_bn = ("নতুন ভ্রমণ আবিষ্কার ফিচার (মালিক ২৭ অক্টো), এখনো তৈরি হয়নি। "
                   "পরিকল্পনা: owner_actions/UNSEEN_WORLD_PLAN_BN.md।")
    old.updated_by = None
    old.save()


def backward(apps, schema_editor):
    FF = apps.get_model("core", "FeatureFlag")
    new = FF.objects.filter(key="daily_info").first()
    if new is None:
        return
    FF.objects.update_or_create(key="unseen_world",
                                defaults={f: getattr(new, f) for f in FIELDS})
    new.delete()


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0098_ai_router'),
    ]

    operations = [
        migrations.RunPython(forward, backward),
    ]
