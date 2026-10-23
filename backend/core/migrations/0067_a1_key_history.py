from django.db import migrations, models


class Migration(migrations.Migration):
    """a1-circle: UserPublicKey.history — a user's EARLIER public keys so a
    contact's phone can still decrypt what was sent under a replaced key."""

    dependencies = [
        ('core', '0066_md1_circle_media_blobs'),
    ]

    operations = [
        migrations.AddField(
            model_name='userpublickey',
            name='history',
            field=models.JSONField(blank=True, default=list),
        ),
    ]
