# train (owner priority C, 2 Nov): crowdsourced train tracker + per-train chat.
# Agent number 0128 — the integrator renumbers after the current leaf.
import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0124_placesafe"),
    ]

    operations = [
        migrations.CreateModel(
            name="TrainShare",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("train_no", models.CharField(max_length=8)),
                ("service_date", models.DateField()),
                ("status", models.CharField(default="active", max_length=10)),
                ("started_at", models.DateTimeField(auto_now_add=True)),
                ("stopped_at", models.DateTimeField(blank=True, null=True)),
                ("ends_at", models.DateTimeField()),
                ("last_chainage", models.FloatField(blank=True, null=True)),
                ("last_lat", models.FloatField(blank=True, null=True)),
                ("last_lng", models.FloatField(blank=True, null=True)),
                ("last_fix_at", models.DateTimeField(blank=True, null=True)),
                ("last_speed", models.FloatField(blank=True, null=True)),
                ("accepted", models.IntegerField(default=0)),
                ("rejected", models.IntegerField(default=0)),
                ("reasons", models.JSONField(blank=True, default=dict)),
                ("user", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="train_shares", to=settings.AUTH_USER_MODEL)),
            ],
            options={
                "indexes": [models.Index(fields=["train_no", "service_date", "status"], name="core_trainsh_room_idx"),
                            models.Index(fields=["ends_at"], name="core_trainsh_ends_idx")],
            },
        ),
        migrations.CreateModel(
            name="TrainChatMember",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("train_no", models.CharField(max_length=8)),
                ("service_date", models.DateField()),
                ("nickname", models.CharField(max_length=24)),
                ("joined_at", models.DateTimeField(auto_now_add=True)),
                ("ends_at", models.DateTimeField()),
                ("user", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="train_chat_members", to=settings.AUTH_USER_MODEL)),
            ],
            options={
                "indexes": [models.Index(fields=["ends_at"], name="core_trainmem_ends_idx")],
                "constraints": [models.UniqueConstraint(fields=("user", "train_no", "service_date"), name="core_trainchat_member_uniq")],
            },
        ),
        migrations.CreateModel(
            name="TrainChatMessage",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("train_no", models.CharField(max_length=8)),
                ("service_date", models.DateField()),
                ("text", models.CharField(max_length=520)),
                ("emergency", models.BooleanField(default=False)),
                ("hidden", models.BooleanField(default=False)),
                ("reporters", models.JSONField(blank=True, default=list)),
                ("at", models.DateTimeField(auto_now_add=True)),
                ("ends_at", models.DateTimeField()),
                ("member", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="messages", to="core.trainchatmember")),
            ],
            options={
                "indexes": [models.Index(fields=["train_no", "service_date", "id"], name="core_trainmsg_room_idx"),
                            models.Index(fields=["ends_at"], name="core_trainmsg_ends_idx")],
            },
        ),
        migrations.CreateModel(
            name="TrainCircleRequest",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("state", models.CharField(default="pending", max_length=10)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("acted_at", models.DateTimeField(blank=True, null=True)),
                ("from_member", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="circle_sent", to="core.trainchatmember")),
                ("to_member", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="circle_received", to="core.trainchatmember")),
            ],
        ),
        migrations.CreateModel(
            name="TrainChatBlock",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("blocker", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="train_blocks", to=settings.AUTH_USER_MODEL)),
                ("blocked", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="train_blocked_by", to=settings.AUTH_USER_MODEL)),
            ],
            options={
                "constraints": [models.UniqueConstraint(fields=("blocker", "blocked"), name="core_trainblock_uniq")],
            },
        ),
        migrations.CreateModel(
            name="TrainChatReport",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("train_no", models.CharField(max_length=8)),
                ("service_date", models.DateField()),
                ("text", models.CharField(max_length=520)),
                ("reason", models.CharField(default="other", max_length=30)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("reporter", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="train_reports", to=settings.AUTH_USER_MODEL)),
                ("reported", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="train_reported", to=settings.AUTH_USER_MODEL)),
            ],
        ),
    ]
