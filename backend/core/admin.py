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
