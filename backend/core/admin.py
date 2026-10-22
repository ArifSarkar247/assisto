from django.contrib import admin
from .models import User, MemoryItem, AuditLog, Device, OTPCode


@admin.register(User)
class UserAdmin(admin.ModelAdmin):
    list_display = ("id", "name", "phone", "email", "autonomy_level", "is_active", "date_joined")
    search_fields = ("name", "phone", "email")


@admin.register(MemoryItem)
class MemoryAdmin(admin.ModelAdmin):
    list_display = ("id", "user", "category", "title", "source", "needs_review", "updated_at")
    list_filter = ("source", "needs_review")


@admin.register(AuditLog)
class AuditAdmin(admin.ModelAdmin):
    list_display = ("id", "user", "action", "created_at")
    list_filter = ("action",)


admin.site.register(Device)
admin.site.register(OTPCode)


# ---- l1-launch: web data-deletion request tickets ----
from .models import WebDeletionRequest  # noqa: E402


@admin.register(WebDeletionRequest)
class WebDeletionRequestAdmin(admin.ModelAdmin):
    """Tickets from lifeassisto.com/delete-account. Creating a ticket never
    deletes anything. Verify the requester FIRST (call/SMS the registered
    number from your own phone), then run "Schedule deletion" — it uses the
    same 7-day-grace AccountDeletionRequest flow as the app."""
    list_display = ("id", "created_at", "contact_kind", "contact", "matched_user",
                    "status")
    list_filter = ("status", "contact_kind")
    search_fields = ("contact", "name")
    readonly_fields = ("contact", "contact_kind", "name", "reason", "lang",
                       "matched_user", "ip_hash", "created_at", "updated_at")
    actions = ["mark_verified", "schedule_deletion", "mark_rejected"]

    @admin.action(description="1) Mark VERIFIED (you confirmed the requester owns the account)")
    def mark_verified(self, request, queryset):
        n = queryset.filter(status=WebDeletionRequest.STATUS_NEW).update(
            status=WebDeletionRequest.STATUS_VERIFIED)
        self.message_user(request, f"{n} ticket(s) marked verified.")

    @admin.action(description="2) Schedule deletion (VERIFIED tickets only, 7-day grace)")
    def schedule_deletion(self, request, queryset):
        from web.legal_deletion import schedule_verified
        done, skipped = schedule_verified(queryset, actor=request.user)
        self.message_user(request, f"scheduled {done}; skipped {skipped} "
                                   f"(not verified or no matching account).")

    @admin.action(description="Mark rejected / could not verify")
    def mark_rejected(self, request, queryset):
        n = queryset.exclude(status=WebDeletionRequest.STATUS_SCHEDULED).update(
            status=WebDeletionRequest.STATUS_REJECTED)
        self.message_user(request, f"{n} ticket(s) marked rejected.")
# ---- /l1-launch ----
