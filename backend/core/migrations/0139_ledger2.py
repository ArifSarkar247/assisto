# ledger2 (business accounting phase 2): how a khata payment moved — cash /
# bKash / Nagad / bank. Additive; '' on every existing row (= cash, nothing
# back-filled).
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0138_channels"),
    ]

    operations = [
        migrations.AddField(
            model_name="khataentry",
            name="method",
            field=models.CharField(blank=True, default="", max_length=8),
        ),
    ]
