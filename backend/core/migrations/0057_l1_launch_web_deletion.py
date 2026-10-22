from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0056_b2_badges'),
    ]

    operations = [
        migrations.CreateModel(
            name='WebDeletionRequest',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('contact', models.CharField(max_length=190)),
                ('contact_kind', models.CharField(default='phone', max_length=8)),
                ('name', models.CharField(blank=True, default='', max_length=120)),
                ('reason', models.TextField(blank=True, default='')),
                ('lang', models.CharField(default='bn', max_length=4)),
                ('status', models.CharField(choices=[('new', 'new — verify the requester'), ('verified', 'verified'), ('scheduled', 'deletion scheduled (7-day grace)'), ('rejected', 'rejected / could not verify'), ('no_account', 'no matching account')], default='new', max_length=12)),
                ('owner_note', models.TextField(blank=True, default='')),
                ('ip_hash', models.CharField(blank=True, db_index=True, default='', max_length=64)),
                ('created_at', models.DateTimeField(auto_now_add=True, db_index=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('matched_user', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='web_deletion_requests', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['-created_at'],
            },
        ),
    ]
