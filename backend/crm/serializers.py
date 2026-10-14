"""DRF ModelSerializers for the CRM. Computed fields (score/priority/insight)
are read-only — they come from scoring.py / logic.py, never client input.

This module exposes the WHOLE in-app CRM surface: leads (with every manual-entry
field), deals, pipelines + stages, activities (timeline + quick-log), members/
team + routing, companies, contacts, proposals and the price book. Every write
serializer keeps server-computed values read-only so the client can never spoof
a score, a weighted value, or an audit field.
"""
from rest_framework import serializers

from .models import (CrmOrg, CrmMember, Lead, Conversation, Message, Proposal,
                     Company, Contact, Pipeline, Stage, Deal, Activity,
                     Product, Territory, RoutingRule, WhatsAppTemplate,
                     Tag, TaggedItem, CustomFieldDef, Order, Installment,
                     AMC, Complaint, ErpHandoff, Target, CommissionRule,
                     AutomationRule)


class CrmOrgSerializer(serializers.ModelSerializer):
    # industry / team_size are the first-run "Start your CRM" inputs. invite_code
    # is deliberately NOT exposed here — it is owner-only and served through the
    # dedicated /orgs/<id>/invite/ action, so a plain org read never leaks the
    # team join code.
    class Meta:
        model = CrmOrg
        fields = ["id", "name", "industry", "team_size", "owner", "created_at"]
        read_only_fields = ["id", "owner", "created_at"]


class CrmMemberSerializer(serializers.ModelSerializer):
    # A friendly display name for the person behind the membership.
    user_name = serializers.SerializerMethodField()

    class Meta:
        model = CrmMember
        fields = ["id", "org", "user", "user_name", "role", "created_at"]
        read_only_fields = ["id", "user_name", "created_at"]

    def get_user_name(self, obj):
        u = obj.user
        return (getattr(u, "name", None) or getattr(u, "username", None)
                or str(obj.user_id))


class MessageSerializer(serializers.ModelSerializer):
    class Meta:
        model = Message
        fields = ["id", "conversation", "direction", "text", "sentiment", "at"]
        # sentiment is derived in logic.add_message, not set by the client.
        read_only_fields = ["id", "sentiment", "at"]


class ConversationSerializer(serializers.ModelSerializer):
    messages = MessageSerializer(many=True, read_only=True)

    class Meta:
        model = Conversation
        fields = ["id", "lead", "channel", "insight", "created_at", "messages"]
        read_only_fields = ["id", "insight", "created_at", "messages"]


class ProposalSerializer(serializers.ModelSerializer):
    class Meta:
        model = Proposal
        fields = ["id", "lead", "deal", "version", "title", "body",
                  "requirements", "line_items", "subtotal", "discount_pct",
                  "discount_amount", "tax_pct", "tax_amount", "total",
                  "prices_reviewed", "status", "discount_needs_approval",
                  "approved_at", "sent_at", "viewed_at", "accepted_at",
                  "pdf_path", "created_at"]
        # Money + status transitions are driven by quoting.py / the workflow
        # actions, never trusted from the client.
        read_only_fields = ["id", "version", "body", "line_items", "subtotal",
                            "discount_amount", "tax_amount", "total",
                            "prices_reviewed", "discount_needs_approval",
                            "approved_at", "sent_at", "viewed_at",
                            "accepted_at", "pdf_path", "created_at"]


class LeadSerializer(serializers.ModelSerializer):
    # Human-readable choice labels help the app render badges without a second
    # round-trip; they are read-only mirrors of the stored code.
    industry_display = serializers.CharField(source="get_industry_display", read_only=True)
    source_display = serializers.CharField(source="get_source_display", read_only=True)
    status_display = serializers.CharField(source="get_status_display", read_only=True)

    class Meta:
        model = Lead
        fields = ["id", "org", "name", "company", "industry", "industry_display",
                  "company_size", "source", "source_display", "phone", "email",
                  # rich manual-entry fields (work without AI)
                  "phones", "whatsapp", "designation", "required_modules",
                  "budget_range", "timeline", "decision_maker", "notes",
                  "next_follow_up",
                  # computed / workflow
                  "score", "priority", "status", "status_display", "assigned_to",
                  "score_reason", "created_at", "updated_at"]
        # score/priority/score_reason are deterministic outputs — never trusted
        # from the client, so they are read-only.
        read_only_fields = ["id", "score", "priority", "score_reason",
                            "industry_display", "source_display",
                            "status_display", "created_at", "updated_at"]

    def validate_status(self, value):
        """The won/lost transitions must go through the dedicated mark_won /
        mark_lost actions so the backing Deal, loss reason and audit trail stay
        consistent (CRM_SPEC §6). A plain lead update may move the lead through
        the EARLY stages only — it can never set 'won' or 'lost' directly."""
        if value in ("won", "lost"):
            raise serializers.ValidationError(
                "won/lost শুধু mark_won / mark_lost দিয়ে সেট হয় / "
                "Use the mark_won / mark_lost action to close a lead")
        return value


class CompanySerializer(serializers.ModelSerializer):
    industry_display = serializers.CharField(source="get_industry_display",
                                             read_only=True)

    class Meta:
        model = Company
        fields = ["id", "org", "name", "parent", "industry", "industry_display",
                  "size", "website", "phone", "address", "territory", "owner",
                  "custom", "created_at", "updated_at"]
        read_only_fields = ["id", "industry_display", "created_at", "updated_at"]


class ContactSerializer(serializers.ModelSerializer):
    role_display = serializers.CharField(source="get_role_display", read_only=True)

    class Meta:
        model = Contact
        fields = ["id", "org", "company", "name", "title", "role",
                  "role_display", "phone", "email",
                  "whatsapp", "is_primary", "owner", "custom",
                  "created_at", "updated_at"]
        read_only_fields = ["id", "role_display", "created_at", "updated_at"]


class StageSerializer(serializers.ModelSerializer):
    class Meta:
        model = Stage
        fields = ["id", "pipeline", "name", "order", "probability",
                  "is_won", "is_lost", "stuck_after_days"]
        read_only_fields = ["id"]


class PipelineSerializer(serializers.ModelSerializer):
    stages = StageSerializer(many=True, read_only=True)

    class Meta:
        model = Pipeline
        fields = ["id", "org", "name", "is_default", "created_at", "stages"]
        read_only_fields = ["id", "created_at", "stages"]


class DealSerializer(serializers.ModelSerializer):
    weighted_value = serializers.SerializerMethodField()
    stage_name = serializers.CharField(source="stage.name", read_only=True)

    class Meta:
        model = Deal
        fields = ["id", "org", "title", "company", "contact", "lead",
                  "pipeline", "stage", "stage_name", "owner", "value",
                  "probability", "expected_close", "state", "next_step",
                  "next_step_due", "loss_reason", "loss_note", "competitor",
                  "source", "custom", "weighted_value", "stage_entered_at",
                  "created_at", "updated_at", "closed_at"]
        # state + closed_at change only through the move/win/lose actions so the
        # audit log and stage clock stay consistent.
        read_only_fields = ["id", "state", "stage_name", "weighted_value",
                            "stage_entered_at", "created_at", "updated_at",
                            "closed_at"]

    def get_weighted_value(self, obj):
        try:
            return float(obj.weighted_value)
        except Exception:
            return 0.0


class ActivitySerializer(serializers.ModelSerializer):
    kind_display = serializers.CharField(source="get_kind_display", read_only=True)
    actor_name = serializers.SerializerMethodField()
    # Documents tab (Company 360): surface the attachment + a download URL so the
    # client can link to the file, not just flag that one exists.
    attachment_url = serializers.SerializerMethodField()

    class Meta:
        model = Activity
        fields = ["id", "org", "kind", "kind_display", "subject", "body",
                  "deal", "lead", "contact", "company", "due_at", "done",
                  "done_at", "attachment", "attachment_url",
                  "actor", "actor_name", "created_at"]
        read_only_fields = ["id", "kind_display", "actor_name", "attachment_url",
                            "done_at", "created_at"]

    def get_actor_name(self, obj):
        if not obj.actor:
            return None
        u = obj.actor.user
        return (getattr(u, "name", None) or getattr(u, "username", None)
                or str(obj.actor.user_id))

    def get_attachment_url(self, obj):
        if not obj.attachment:
            return None
        try:
            url = obj.attachment.url
        except Exception:
            return None
        request = self.context.get("request")
        return request.build_absolute_uri(url) if request else url


class ProductSerializer(serializers.ModelSerializer):
    class Meta:
        model = Product
        fields = ["id", "org", "sku", "name", "description", "unit_price",
                  "billing", "price_reviewed", "active"]
        read_only_fields = ["id"]


class TerritorySerializer(serializers.ModelSerializer):
    class Meta:
        model = Territory
        fields = ["id", "org", "name", "region", "industries", "created_at"]
        read_only_fields = ["id", "created_at"]


class RoutingRuleSerializer(serializers.ModelSerializer):
    class Meta:
        model = RoutingRule
        fields = ["id", "org", "order", "match_industry", "match_source",
                  "match_region", "min_company_size", "assign_to", "territory",
                  "active"]
        read_only_fields = ["id"]


class WhatsAppTemplateSerializer(serializers.ModelSerializer):
    # Owner-defined templates. `body` is the owner's own copy — the CRM never
    # invents template content, so nothing here is server-generated.
    class Meta:
        model = WhatsAppTemplate
        fields = ["id", "org", "name", "meta_name", "language", "body",
                  "approved", "active", "created_at"]
        read_only_fields = ["id", "created_at"]


# ------------------------------------------------- Company 360: tags + defs
class TagSerializer(serializers.ModelSerializer):
    class Meta:
        model = Tag
        fields = ["id", "org", "name", "color"]
        read_only_fields = ["id"]


class TaggedItemSerializer(serializers.ModelSerializer):
    class Meta:
        model = TaggedItem
        fields = ["id", "tag", "lead", "company", "contact", "deal"]
        read_only_fields = ["id"]


class CustomFieldDefSerializer(serializers.ModelSerializer):
    field_type_display = serializers.CharField(source="get_field_type_display",
                                               read_only=True)
    entity_display = serializers.CharField(source="get_entity_display",
                                           read_only=True)

    class Meta:
        model = CustomFieldDef
        fields = ["id", "org", "entity", "entity_display", "key", "label",
                  "field_type", "field_type_display", "options", "order"]
        read_only_fields = ["id", "entity_display", "field_type_display"]


# ------------------------------------------------- after-sale (§7) serializers
class OrderSerializer(serializers.ModelSerializer):
    class Meta:
        model = Order
        fields = ["id", "org", "lead", "deal", "source_proposal",
                  "total_poisha", "created_at"]
        # The total is carried from the accepted quote, never set by the client.
        read_only_fields = ["id", "total_poisha", "created_at"]


class InstallmentSerializer(serializers.ModelSerializer):
    class Meta:
        model = Installment
        fields = ["id", "order", "seq", "amount_poisha", "due_date",
                  "collected_poisha", "status"]
        # Amounts/status are server-authoritative (built + updated by the logic).
        read_only_fields = ["id", "seq", "amount_poisha", "collected_poisha",
                            "status"]


class AMCSerializer(serializers.ModelSerializer):
    class Meta:
        model = AMC
        fields = ["id", "org", "company", "order", "title", "start_date",
                  "term_days", "reminder_lead_days", "last_renewed_at",
                  "created_at"]
        read_only_fields = ["id", "last_renewed_at", "created_at"]


class ComplaintSerializer(serializers.ModelSerializer):
    priority_display = serializers.CharField(source="get_priority_display",
                                             read_only=True)

    class Meta:
        model = Complaint
        fields = ["id", "org", "company", "lead", "subject", "details",
                  "priority", "priority_display", "state", "opened_at",
                  "resolved_at"]
        # State transitions go through the dedicated action; never set directly.
        read_only_fields = ["id", "priority_display", "state", "opened_at",
                            "resolved_at"]


class ErpHandoffSerializer(serializers.ModelSerializer):
    class Meta:
        model = ErpHandoff
        fields = ["id", "deal", "company_name", "module_codes",
                  "order_total_poisha", "state", "erp_link_connected",
                  "created_at", "updated_at"]
        read_only_fields = ["id", "state", "created_at", "updated_at"]


# ------------------------------------------------- team (#8) serializers
class TargetSerializer(serializers.ModelSerializer):
    class Meta:
        model = Target
        fields = ["id", "org", "member", "period", "amount", "deals_target",
                  "commission_paid"]
        # commission_paid is a snapshot written by the engine, never by client.
        read_only_fields = ["id", "commission_paid"]


class CommissionRuleSerializer(serializers.ModelSerializer):
    class Meta:
        model = CommissionRule
        fields = ["id", "org", "kind", "flat_pct", "tiers", "per_deal_bonus",
                  "updated_at"]
        read_only_fields = ["id", "updated_at"]


class AutomationRuleSerializer(serializers.ModelSerializer):
    class Meta:
        model = AutomationRule
        fields = ["id", "org", "name", "trigger", "condition", "delay_days",
                  "action", "active", "created_at"]
        read_only_fields = ["id", "created_at"]
