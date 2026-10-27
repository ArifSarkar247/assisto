# pricing-40: Play-verified gate for NEW skus (Plus, Premium Pro, new packs,
# Probashi): one row per sku with the last Play Developer API result.
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0100_aiusage_credits"),
    ]

    operations = [
        migrations.CreateModel(
            name="PlaySkuCheck",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False,
                                           verbose_name="ID")),
                ("sku", models.CharField(max_length=40, unique=True)),
                ("product_id", models.CharField(blank=True, default="", max_length=80)),
                ("base_plan", models.CharField(blank=True, default="", max_length=40)),
                ("state", models.CharField(blank=True, default="", max_length=24)),
                ("ok", models.BooleanField(default=False)),
                ("detail", models.CharField(blank=True, default="", max_length=160)),
                ("checked_at", models.DateTimeField(blank=True, null=True)),
            ],
        ),
    ]
