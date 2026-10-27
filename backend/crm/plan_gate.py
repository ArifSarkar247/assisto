"""plans-v2 — the CRM's ONE server gate (owner order 27 Oct).

Called from CrmErrorMixin.initial() for EVERY CRM API view, after auth and
before the handler runs, so no endpoint can skip it. The plan that counts is
the CRM ORG OWNER's (CrmOrg.owner) — never the acting team member's.

    Free      contacts up to the limit (default 20); leads, deals, pipeline,
              tasks and the rest are VIEW ONLY (nothing new); no follow-up
              reminders; no automation
    Premium   contacts up to 500; full leads / deals / pipeline / tasks;
              follow-up reminders; no automation
    Business  everything incl. automation; contacts "Unlimited" in the app,
              a high hidden safety cap on the server (default 50,000)

"Contacts" = CRM people = leads + contacts, summed over every org the owner
has. NO DATA LOSS: reading, editing, moving, completing and deleting
EXISTING records always works, over a limit too — only NEW records (and new
follow-up dates / automations) are refused, with a structured 402
(core.logic.entitlements.upgrade_body).

With the plans_v2 flag OFF for the org owner this module does nothing.
"""
# view class -> family
#   people      creates a lead: needs crm_write AND contact room
#   contact     creates a contact: contact room only (Free may add these)
#   write       leads/deals/pipeline/tasks/after-sale/price book: crm_write
#   automation  rules, evaluator, bulk WhatsApp: automation (Business)
FAMILY = {
    "LeadViewSet": "people",
    "CaptureWebhookView": "people",
    "ContactViewSet": "contact",
    "CompanyViewSet": "write", "PipelineViewSet": "write", "StageViewSet": "write",
    "DealViewSet": "write", "ActivityViewSet": "write", "ProposalViewSet": "write",
    "TagViewSet": "write", "TaggedItemViewSet": "write",
    "CustomFieldDefViewSet": "write", "OrderViewSet": "write",
    "InstallmentViewSet": "write", "AMCViewSet": "write",
    "ComplaintViewSet": "write", "ProductViewSet": "write",
    "WhatsAppTemplateViewSet": "write", "RoutingRuleViewSet": "write",
    "TerritoryViewSet": "write", "TargetViewSet": "write",
    "ErpHandoffView": "write", "CommissionConfigView": "write",
    "CaptureMergeView": "write",
    "AutomationRuleViewSet": "automation", "AutomationEvaluateView": "automation",
    "WhatsAppBulkSendView": "automation",
}

# (view, custom action) -> op. Standard actions map by name below; an
# unlisted custom action counts as an edit of an existing record.
ACTION_OP = {
    ("LeadViewSet", "followup"): "followup",
    ("LeadViewSet", "proposal"): "create",
    ("LeadViewSet", "quote"): "create",
    ("LeadViewSet", "message"): "create_child",
    ("LeadViewSet", "log_action"): "create_child",
    ("LeadViewSet", "whatsapp_send"): "create_child",
    ("LeadViewSet", "whatsapp_receive"): "create_child",
    ("DealViewSet", "set_next_step"): "followup",
    ("ProposalViewSet", "convert_to_order"): "create",
    ("OrderViewSet", "build_schedule"): "create",
    ("InstallmentViewSet", "collect"): "create",
    ("AMCViewSet", "schedule_reminder"): "followup",
    ("AMCViewSet", "renew"): "create",
    ("AutomationRuleViewSet", "delete"): "delete",
}
_STD = {"list": "read", "retrieve": "read", "create": "create",
        "update": "update", "partial_update": "update", "destroy": "delete",
        "metadata": "read"}
# APIView method -> op (non-ViewSet views)
_APIVIEW_POST = {"CaptureWebhookView": "create", "AutomationEvaluateView": "create",
                 "WhatsAppBulkSendView": "create", "CommissionConfigView": "update",
                 "ErpHandoffView": "update", "CaptureMergeView": "update"}
# fields whose new value sets a follow-up / reminder date
FOLLOWUP_FIELDS = {"LeadViewSet": ("next_follow_up",),
                   "DealViewSet": ("next_step_due",)}


def op_for(view, request):
    name = type(view).__name__
    act = getattr(view, "action", None)
    if act is not None:
        if (name, act) in ACTION_OP:
            return ACTION_OP[(name, act)]
        if act in _STD:
            return _STD[act]
        return "read" if request.method in ("GET", "HEAD", "OPTIONS") else "update"
    if request.method in ("GET", "HEAD", "OPTIONS"):
        return "read"
    if request.method == "DELETE":
        return "delete"
    return _APIVIEW_POST.get(name, "update")


def _org_of(obj):
    for path in ("org", "pipeline.org", "order.org", "tag.org", "lead.org",
                 "installment.order.org"):
        cur = obj
        for part in path.split("."):
            cur = getattr(cur, part, None)
            if cur is None:
                break
        if cur is not None and type(cur).__name__ == "CrmOrg":
            return cur
    return None


def _data(request, key):
    try:
        v = request.data.get(key)
    except Exception:
        v = None
    return v if v not in (None, "") else request.query_params.get(key)


def resolve_org(view, request, kwargs):
    """The CrmOrg this write targets (None = let the view handle it)."""
    from .models import CrmOrg, Deal, Pipeline, Tag
    pk = kwargs.get("pk")
    if pk is not None and hasattr(view, "get_queryset"):
        try:
            obj = view.get_queryset().filter(pk=pk).first()
        except Exception:
            obj = None
        return _org_of(obj) if obj is not None else None
    if kwargs.get("deal") is not None:
        d = Deal.objects.filter(pk=kwargs["deal"]).select_related("org").first()
        return d.org if d else None
    org_id = _data(request, "org")
    if org_id:
        try:
            return CrmOrg.objects.filter(pk=int(org_id)).first()
        except (TypeError, ValueError):
            return None
    pid = _data(request, "pipeline")
    if pid:
        try:
            p = Pipeline.objects.filter(pk=int(pid)).select_related("org").first()
        except (TypeError, ValueError):
            p = None
        return p.org if p else None
    tid = _data(request, "tag")
    if tid:
        try:
            t = Tag.objects.filter(pk=int(tid)).select_related("org").first()
        except (TypeError, ValueError):
            t = None
        return t.org if t else None
    return None


def _sets_followup(view, request, op, kwargs=None):
    """An edit that sets a NEW follow-up date (re-sending the date the record
    already has is not a new reminder, so legacy records stay editable)."""
    if op != "update":
        return False
    fields = FOLLOWUP_FIELDS.get(type(view).__name__, ())
    if not fields:
        return False
    try:
        wanted = {f: request.data.get(f) for f in fields
                  if request.data.get(f) not in (None, "")}
    except Exception:
        return False
    if not wanted:
        return False
    obj = None
    pk = (kwargs or {}).get("pk")
    if pk is not None:
        try:
            obj = view.get_queryset().filter(pk=pk).first()
        except Exception:
            obj = None
    if obj is None:
        return True
    for f, v in wanted.items():
        cur = getattr(obj, f, None)
        cur = cur.isoformat() if hasattr(cur, "isoformat") else cur
        if str(cur or "") != str(v)[:10]:
            return True
    return False


def _creates_followup(view, request, op):
    """A new record that carries a follow-up date (e.g. a lead with
    next_follow_up, a task with due_at counts as a task = crm_write)."""
    if op != "create":
        return False
    fields = FOLLOWUP_FIELDS.get(type(view).__name__, ())
    try:
        return any(request.data.get(f) not in (None, "") for f in fields)
    except Exception:
        return False


def check(view, request, kwargs):
    """Raise core.entitlements_service.UpgradeRequired when the org owner's
    plan does not allow this write. Never blocks a read, edit or delete of an
    existing record (except setting a follow-up date, a Premium feature)."""
    name = type(view).__name__
    fam = FAMILY.get(name)
    if fam is None:
        return
    op = op_for(view, request)
    if op in ("read", "delete"):
        return
    if op == "update" and fam != "automation" and not _sets_followup(view, request, op, kwargs):
        return
    if fam == "automation" and op == "update":
        return          # editing / switching off an existing rule always works
    org = resolve_org(view, request, kwargs)
    if org is None:
        return
    from .models import CrmMember
    if not CrmMember.objects.filter(org=org, user=request.user).exists():
        return          # the view's own membership check answers (403/404)
    from core import entitlements_service as ES
    from core.i18n import req_lang
    owner = org.owner
    if not ES.on(owner):
        return
    lang = req_lang(request)
    c = ES.cfg()
    if fam == "automation":
        if not ES.allows(owner, "automation", c):
            ES.refuse("automation", owner, lang)
        return
    if op in ("followup", "update"):
        # update here = an edit that sets a follow-up date (see above)
        if not ES.allows(owner, "crm_followup_reminders", c):
            ES.refuse("crm_followup_reminders", owner, lang)
        return
    if fam == "contact":
        ES.require_contact_room(owner, lang)
        return
    # people / write: a new record (or a new child record on a lead)
    if not ES.allows(owner, "crm_write", c):
        ES.refuse("crm_write", owner, lang)
    if _creates_followup(view, request, op) and \
            not ES.allows(owner, "crm_followup_reminders", c):
        ES.refuse("crm_followup_reminders", owner, lang)
    if fam == "people" and op == "create":
        ES.require_contact_room(owner, lang)


# ------------------------------------------------------------ web CRM (/crm/)
def web_refusal(request, org, kind, adding=1, json=False):
    """The same rules for the server-rendered web CRM (crm/webviews.py).
    kind: "lead" (crm_write + contact room), "contact" (room only), "write"
    (crm_write), "followup" (crm_followup_reminders). Returns a 402 response
    to send back, or None when allowed / plans_v2 is off for the owner."""
    from core import entitlements_service as ES
    from django.http import HttpResponse, JsonResponse
    owner = getattr(org, "owner", None)
    if owner is None or not ES.on(owner):
        return None
    try:
        lang = "en" if request.session.get("crm_lang") == "en" else "bn"
    except Exception:
        lang = "bn"
    c = ES.cfg()
    body = None
    if kind == "followup":
        if not ES.allows(owner, "crm_followup_reminders", c):
            body = ES.body("crm_followup_reminders", owner, lang, c=c)
    elif kind in ("lead", "write") and not ES.allows(owner, "crm_write", c):
        body = ES.body("crm_write", owner, lang, c=c)
    if body is None and kind in ("lead", "contact"):
        st = ES.crm_contacts(owner, c)
        if st["used"] + max(1, int(adding or 1)) > st["limit"]:
            body = ES.body("crm_contacts", owner, lang, limit=st["limit"],
                           used=st["used"], c=c)
    if body is None:
        return None
    if json:
        return JsonResponse(body, status=402)
    return HttpResponse(body["detail"], status=402,
                        content_type="text/plain; charset=utf-8")
