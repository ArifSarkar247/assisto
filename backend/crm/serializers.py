"""DRF ModelSerializers for the CRM. Computed fields (score/priority/insight)
are read-only — they come from scoring.py / logic.py, never client input."""
from rest_framework import serializers

from .models import CrmOrg, CrmMember, Lead, Conversation, Message, Proposal


class CrmOrgSerializer(serializers.ModelSerializer):
    class Meta:
        model = CrmOrg
        fields = ["id", "name", "owner", "created_at"]
        read_only_fields = ["id", "owner", "created_at"]


class CrmMemberSerializer(serializers.ModelSerializer):
    class Meta:
        model = CrmMember
        fields = ["id", "org", "user", "role", "created_at"]
        read_only_fields = ["id", "created_at"]


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
        fields = ["id", "lead", "body", "pdf_path", "created_at"]
        read_only_fields = ["id", "body", "pdf_path", "created_at"]


class LeadSerializer(serializers.ModelSerializer):
    class Meta:
        model = Lead
        fields = ["id", "org", "name", "company", "industry", "company_size",
                  "source", "phone", "email", "score", "priority", "status",
                  "assigned_to", "score_reason", "created_at", "updated_at"]
        # score/priority/score_reason are deterministic outputs — never trusted
        # from the client, so they are read-only.
        read_only_fields = ["id", "score", "priority", "score_reason",
                            "created_at", "updated_at"]
