# journey2 (28 Oct): the traveller can turn the shared watcher link OFF.
# Journey.web_gen is baked into the signed /j/<token>; bumping it kills every
# link handed out so far (a fresh one can be shared again). Additive only.

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0118_famcare"),
    ]

    operations = [
        migrations.AddField(
            model_name="journey",
            name="web_gen",
            field=models.IntegerField(default=0),
        ),
    ]
