# Owner AI chat rebuild (4 Nov 01:02): AI answer levels ON in the live
# pricing config (Normal = Gemini Flash / Better = Claude Haiku / Best =
# Claude Sonnet, worst-case 40 % credit prices). The old pricing-40 "smart"
# mode (Sonnet for 2 credits) fails the 40 % rule in the worst case and must
# not run any more. Only an existing config row is touched; an owner who
# already saved the levels block keeps their choice. Reversible.
from django.db import migrations


def levels_on(apps, schema_editor):
    PricingConfig = apps.get_model("core", "PricingConfig")
    row = PricingConfig.objects.filter(key="global").first()
    if row is None:
        return
    data = dict(row.data or {})
    lv = dict(data.get("ai_levels") or {})
    if "enabled" in lv and lv.get("_owner_saved"):
        return
    lv["enabled"] = True
    data["ai_levels"] = lv
    row.data = data
    row.save(update_fields=["data"])


def levels_off(apps, schema_editor):
    PricingConfig = apps.get_model("core", "PricingConfig")
    row = PricingConfig.objects.filter(key="global").first()
    if row is None:
        return
    data = dict(row.data or {})
    lv = dict(data.get("ai_levels") or {})
    lv["enabled"] = False
    data["ai_levels"] = lv
    row.data = data
    row.save(update_fields=["data"])


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0151_aifinal'),
    ]

    operations = [
        migrations.RunPython(levels_on, levels_off),
    ]
