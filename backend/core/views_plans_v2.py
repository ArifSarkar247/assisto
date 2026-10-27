"""plans-v2 — GET /plans/v2: the caller's plan tier, trial, the live
matrix, and (for a CRM org / shop the caller belongs to) the OWNER's tier +
CRM contact usage, so the app can lock buttons honestly and show
"18/20 contacts". The server gates enforce the same rules on every write
(core.entitlements_service); this endpoint only describes them."""
from rest_framework.response import Response
from rest_framework.views import APIView

from . import entitlements_service as ES
from .i18n import req_lang


class PlansV2View(APIView):
    def get(self, request):
        u = request.user
        crm_owner = shop_owner = None
        org_id = request.query_params.get("org")
        if org_id:
            from crm.models import CrmMember
            try:
                m = (CrmMember.objects.filter(user=u, org_id=int(org_id))
                     .select_related("org__owner").first())
            except (TypeError, ValueError):
                m = None
            if m is not None:
                crm_owner = m.org.owner
        bid = request.query_params.get("business")
        from .models import BusinessProfile, BusinessStaff
        if bid:
            try:
                prof = BusinessProfile.objects.filter(pk=int(bid)).first()
            except (TypeError, ValueError):
                prof = None
            if prof is not None and (prof.user_id == u.id or BusinessStaff.objects.filter(
                    business=prof, member=u, active=True).exists()):
                shop_owner = prof.user
        else:
            prof = BusinessProfile.objects.filter(user=u).first()
            if prof is not None:
                shop_owner = u
        out = ES.payload(u, req_lang(request), crm_owner=crm_owner,
                         shop_owner=shop_owner)
        return Response(out)
