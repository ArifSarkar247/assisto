# guardian2 (PART 6 two guardians): one new table (GuardianLink) + one
# nullable column on FamilyAlertDelivery (responding_at). Additive only.
import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0148_mapscost'),
    ]

    operations = [
        migrations.AddField(
            model_name='familyalertdelivery',
            name='responding_at',
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.CreateModel(
            name='GuardianLink',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('code', models.CharField(max_length=12, unique=True)),
                ('state', models.CharField(default='invited', max_length=10)),
                ('expires_at', models.DateTimeField()),
                ('requested_at', models.DateTimeField(blank=True, null=True)),
                ('approved_at', models.DateTimeField(blank=True, null=True)),
                ('ended_at', models.DateTimeField(blank=True, null=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('child', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='guardian_links_as_child', to=settings.AUTH_USER_MODEL)),
                ('decided_by', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
                ('ended_by', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
                ('guardian', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.CASCADE, related_name='guardian_links', to=settings.AUTH_USER_MODEL)),
                ('invited_by', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='guardian_invites_sent', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['-id'],
                'indexes': [models.Index(fields=['child', 'state'], name='core_glink_child_state_idx'), models.Index(fields=['guardian', 'state'], name='core_glink_g_state_idx')],
            },
        ),
    ]
