# cde-chat (order 6 D + E): shared per-chat theme id + nicknames.
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0072_p4_world'),
    ]

    operations = [
        migrations.CreateModel(
            name='ChatDecor',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('kind', models.CharField(max_length=8)),
                ('key', models.CharField(max_length=40)),
                ('theme', models.CharField(blank=True, default='', max_length=24)),
                ('theme_by', models.IntegerField(blank=True, null=True)),
                ('theme_at', models.DateTimeField(blank=True, null=True)),
                ('nicknames', models.JSONField(blank=True, default=dict)),
                ('updated_at', models.DateTimeField(auto_now=True)),
            ],
            options={
                'unique_together': {('kind', 'key')},
            },
        ),
    ]
