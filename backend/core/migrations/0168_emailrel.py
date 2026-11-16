# emailrel (16 Nov): email failure kinds + suppression list (hard bounces,
# complaints, unsubscribes). Additive only.
from django.db import migrations, models
import django.utils.timezone


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0167_discms'),
    ]

    operations = [
        migrations.AddField(
            model_name='emaillog',
            name='error_kind',
            field=models.CharField(blank=True, default='', max_length=10),
        ),
        migrations.AddField(
            model_name='emaillog',
            name='category',
            field=models.CharField(blank=True, default='critical', max_length=10),
        ),
        migrations.AddField(
            model_name='emaillog',
            name='attempts',
            field=models.PositiveSmallIntegerField(default=1),
        ),
        migrations.CreateModel(
            name='EmailSuppression',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('to_hash', models.CharField(max_length=64, unique=True)),
                ('to_masked', models.CharField(blank=True, default='', max_length=80)),
                ('reason', models.CharField(default='hard_bounce', max_length=12)),
                ('code', models.CharField(blank=True, default='', max_length=12)),
                ('detail', models.CharField(blank=True, default='', max_length=200)),
                ('hits', models.PositiveIntegerField(default=1)),
                ('created_at', models.DateTimeField(db_index=True, default=django.utils.timezone.now)),
                ('last_at', models.DateTimeField(default=django.utils.timezone.now)),
            ],
        ),
    ]
