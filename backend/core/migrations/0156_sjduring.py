from django.db import migrations, models


class Migration(migrations.Migration):
    """sjduring: Journey.during (DURING-trip state + private alert ladder)
    and DuressPin.arrive_always (PIN on every arrival)."""

    dependencies = [("core", "0155_bizai")]

    operations = [
        migrations.AddField(model_name="journey", name="during",
                            field=models.JSONField(blank=True, default=dict)),
        migrations.AddField(model_name="duresspin", name="arrive_always",
                            field=models.BooleanField(default=False)),
    ]
