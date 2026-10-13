"""
Axon Dynamics CRM web app URLs (server-rendered, session auth).

INTEGRATOR: include this from the root urls.py as:
    path("crm/", include("crm.weburls"))
so the web UI lives at /crm/ (login at /crm/login). The existing DRF API at
/api/crm/ (crm.urls) is untouched.
"""
from django.urls import path

from . import webviews as v

urlpatterns = [
    # auth + home
    path("login", v.crm_login, name="crm_login"),
    path("logout", v.crm_logout, name="crm_logout"),
    path("", v.dashboard, name="crm_dashboard"),
    path("org/new", v.org_create, name="crm_org_create"),

    # pipeline kanban
    path("pipeline", v.pipeline_board, name="crm_pipeline"),
    path("pipeline/move", v.deal_move, name="crm_deal_move"),

    # leads
    path("leads", v.lead_list, name="crm_leads"),
    path("leads/new", v.lead_create, name="crm_lead_create"),
    path("leads/import", v.lead_import, name="crm_lead_import"),
    path("leads/export", v.lead_export, name="crm_lead_export"),
    path("leads/<int:pk>", v.lead_detail, name="crm_lead_detail"),
    path("leads/<int:pk>/update", v.lead_update, name="crm_lead_update"),
    path("leads/<int:pk>/message", v.lead_message, name="crm_lead_message"),
    path("leads/<int:lead_pk>/proposal", v.proposal_build, name="crm_proposal_build"),

    # companies & contacts
    path("companies", v.company_list, name="crm_companies"),
    path("companies/new", v.company_create, name="crm_company_create"),
    path("contacts", v.contact_list, name="crm_contacts"),
    path("contacts/new", v.contact_create, name="crm_contact_create"),

    # deals
    path("deals", v.deal_list, name="crm_deals"),
    path("deals/new", v.deal_create, name="crm_deal_create"),
    path("deals/<int:pk>", v.deal_detail, name="crm_deal_detail"),
    path("deals/<int:pk>/update", v.deal_update, name="crm_deal_update"),
    path("deals/<int:pk>/stage", v.deal_stage, name="crm_deal_stage"),
    path("deals/<int:pk>/onboard", v.deal_onboard, name="crm_deal_onboard"),
    path("deals/<int:pk>/enroll", v.deal_enroll, name="crm_deal_enroll"),

    # activities
    path("activities", v.activity_list, name="crm_activities"),
    path("activities/log", v.activity_log, name="crm_activity_log"),
    path("activities/<int:pk>/done", v.activity_done, name="crm_activity_done"),

    # proposals / quotes
    path("proposals", v.proposal_list, name="crm_proposals"),
    path("proposals/<int:pk>", v.proposal_detail, name="crm_proposal_detail"),
    path("proposals/<int:pk>/action", v.proposal_action, name="crm_proposal_action"),
    path("proposals/<int:pk>/pdf", v.proposal_pdf, name="crm_proposal_pdf"),

    # price book, reports, team, audit, duplicates
    path("products", v.product_list, name="crm_products"),
    path("reports", v.reports, name="crm_reports"),
    path("team", v.team, name="crm_team"),
    path("audit", v.audit_view, name="crm_audit"),
    path("duplicates", v.duplicates, name="crm_duplicates"),
]
