# ads-nine (row 54): ad REQUESTS and failed loads (no fill / error /
# timeout) per placement per day, so Owner Admin shows requests ->
# impressions -> fill rate. Additive counters, default 0; no user id.
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0173_ads_guard'),
    ]

    operations = [
        migrations.AddField(
            model_name='adplacementstat',
            name='requests',
            field=models.PositiveIntegerField(default=0),
        ),
        migrations.AddField(
            model_name='adplacementstat',
            name='no_fill',
            field=models.PositiveIntegerField(default=0),
        ),
    ]
