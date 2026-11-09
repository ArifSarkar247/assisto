from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0163_lpcore'),
    ]

    operations = [
        migrations.CreateModel(
            name='AdMoneyDay',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('date', models.DateField(unique=True)),
                ('ads_per_answer', models.PositiveSmallIntegerField(default=2)),
                ('data', models.JSONField(blank=True, default=dict)),
                ('updated_at', models.DateTimeField(auto_now=True)),
            ],
            options={
                'ordering': ['-date'],
            },
        ),
    ]
