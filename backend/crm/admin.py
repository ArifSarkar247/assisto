"""Django admin for the Axon Dynamics CRM — lets the owner inspect/fix data and
configure the price book, pipelines, routing, targets and cadences directly."""
from django.contrib import admin

from .models import (CrmOrg, CrmMember, Lead, Conversation, Message, Proposal,
                     Company, Contact, Pipeline, Stage, Deal, Activity, Mention,
                     Tag, TaggedItem, CustomFieldDef, Territory, RoutingRule,
                     Target, Product, Cadence, CadenceStep, AuditEntry)


@admin.register(CrmOrg)
class CrmOrgAdmin(admin.ModelAdmin):
    list_display = ("name", "owner", "created_at")
    search_fields = ("name",)


@admin.register(CrmMember)
class CrmMemberAdmin(admin.ModelAdmin):
    list_display = ("user", "org", "role")
    list_filter = ("role",)


@admin.register(Lead)
class LeadAdmin(admin.ModelAdmin):
    list_display = ("name", "company", "org", "industry", "score", "priority", "status")
    list_filter = ("priority", "status", "industry", "source")
    search_fields = ("name", "company", "email", "phone")


@admin.register(Company)
class CompanyAdmin(admin.ModelAdmin):
    list_display = ("name", "org", "industry", "size", "parent")
    search_fields = ("name",)


@admin.register(Contact)
class ContactAdmin(admin.ModelAdmin):
    list_display = ("name", "company", "title", "phone", "email")
    search_fields = ("name", "email", "phone")


class StageInline(admin.TabularInline):
    model = Stage
    extra = 0


@admin.register(Pipeline)
class PipelineAdmin(admin.ModelAdmin):
    list_display = ("name", "org", "is_default")
    inlines = [StageInline]


@admin.register(Deal)
class DealAdmin(admin.ModelAdmin):
    list_display = ("title", "org", "stage", "value", "probability", "state",
                    "expected_close")
    list_filter = ("state", "pipeline")
    search_fields = ("title",)


@admin.register(Activity)
class ActivityAdmin(admin.ModelAdmin):
    list_display = ("kind", "subject", "org", "actor", "done", "due_at", "created_at")
    list_filter = ("kind", "done")


@admin.register(Proposal)
class ProposalAdmin(admin.ModelAdmin):
    list_display = ("id", "lead", "version", "total", "status",
                    "prices_reviewed", "discount_needs_approval")
    list_filter = ("status", "prices_reviewed")


@admin.register(Product)
class ProductAdmin(admin.ModelAdmin):
    list_display = ("sku", "name", "org", "unit_price", "billing", "price_reviewed", "active")
    list_filter = ("billing", "price_reviewed", "active")
    search_fields = ("sku", "name")


class CadenceStepInline(admin.TabularInline):
    model = CadenceStep
    extra = 0


@admin.register(Cadence)
class CadenceAdmin(admin.ModelAdmin):
    list_display = ("name", "org", "active")
    inlines = [CadenceStepInline]


@admin.register(Target)
class TargetAdmin(admin.ModelAdmin):
    list_display = ("org", "member", "period", "amount", "deals_target")


@admin.register(RoutingRule)
class RoutingRuleAdmin(admin.ModelAdmin):
    list_display = ("org", "order", "match_industry", "match_source",
                    "min_company_size", "assign_to", "active")


@admin.register(AuditEntry)
class AuditEntryAdmin(admin.ModelAdmin):
    list_display = ("at", "org", "member", "action", "entity")
    list_filter = ("action",)
    search_fields = ("entity", "detail")


admin.site.register([Conversation, Message, Mention, Tag, TaggedItem,
                     CustomFieldDef, Territory])
