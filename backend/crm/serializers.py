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
                     Product, Territory, RoutingRule)


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
    class Meta:
        model = Company
        fields = ["id", "org", "name", "parent", "industry", "size", "website",
                  "phone", "address", "territory", "owner", "custom",
                  "created_at", "updated_at"]
        read_only_fields = ["id", "created_at", "updated_at"]


class ContactSerializer(serializers.ModelSerializer):
    class Meta:
        model = Contact
        fields = ["id", "org", "company", "name", "title", "phone", "email",
                  "whatsapp", "is_primary", "owner", "custom",
                  "created_at", "updated_at"]
        read_only_fields = ["id", "created_at", "updated_at"]


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

    class Meta:
        model = Activity
        fields = ["id", "org", "kind", "kind_display", "subject", "body",
                  "deal", "lead", "contact", "company", "due_at", "done",
                  "done_at", "actor", "actor_name", "created_at"]
        read_only_fields = ["id", "kind_display", "actor_name", "done_at",
                            "created_at"]

    def get_actor_name(self, obj):
        if not obj.actor:
            return None
        u = obj.actor.user
        return (getattr(u, "name", None) or getattr(u, "username", None)
                or str(obj.actor.user_id))


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
                  "min_company_size", "assign_to", "territory", "active"]
        read_only_fields = ["id"]
