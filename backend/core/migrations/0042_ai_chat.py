"""AI Chat (Part 3) — ChatGPT-like multi-turn chat with history.

Additive only: two new tables (ChatSession, ChatMessage) owned by the user. No
data migration, no touch to any existing table — safe on the Assisto-owned DB.
A ChatSession is one conversation thread; ChatMessage rows are its turns. The
reply is produced by core/ai.py (keyed, charged) or the no-key Brain (free); this
only persists the transcript + per-session pin/archive/title state.
"""
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0041_storageusage"),
    ]

    operations = [
        migrations.CreateModel(
            name="ChatSession",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name="ID")),
                ("title", models.CharField(blank=True, default="", max_length=120)),
                ("title_custom", models.BooleanField(default=False)),
                ("pinned", models.BooleanField(default=False)),
                ("archived", models.BooleanField(default=False)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                ("user", models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name="chat_sessions", to="core.user")),
            ],
            options={
                "ordering": ["-pinned", "-updated_at"],
            },
        ),
        migrations.CreateModel(
            name="ChatMessage",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name="ID")),
                ("role", models.CharField(
                    choices=[("user", "user"), ("assistant", "assistant"),
                             ("system", "system")], max_length=10)),
                ("text", models.TextField(blank=True, default="")),
                ("meta", models.JSONField(blank=True, default=dict)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("session", models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name="messages", to="core.chatsession")),
            ],
            options={
                "ordering": ["created_at", "id"],
            },
        ),
        migrations.AddIndex(
            model_name="chatsession",
            index=models.Index(fields=["user", "-pinned", "-updated_at"],
                               name="core_chatse_user_id_8e7cd8_idx"),
        ),
        migrations.AddIndex(
            model_name="chatmessage",
            index=models.Index(fields=["session", "created_at"],
                               name="core_chatme_session_76a3ef_idx"),
        ),
    ]
