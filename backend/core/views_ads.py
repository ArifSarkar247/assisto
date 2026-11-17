"""
GET /ads/config — what the app needs to drive AdMob (slot a6).

Key-gated: until the owner saves REAL AdMob ids in Integrations (and the
format test passes), `configured` is False and the app uses Google's TEST ids
only; billing.ad_event never credits real money in that state.
"""
from rest_framework.response import Response
from rest_framework.views import APIView


def test_ads_account(user, admob_cfg=None):
    """admob-connect (owner 17 Nov): True = this account only ever gets
    Google's TEST ad units, so the owner and testers never make an invalid
    impression/click on Assisto's real ads: the owner / staff accounts
    (core.test_accounts: superuser, staff, ASSISTO_OWNER_PHONES), the Play
    reviewer account (PLAY_REVIEWER_PHONE) and the phones the owner lists in
    Owner Admin -> Integrations -> AdMob -> "Ad test phones". Fails SAFE:
    any error -> test ads."""
    import os
    from .logic import ads as A
    try:
        from .test_accounts import is_real_owner
        if is_real_owner(user):
            return True
        me = A.phone_key(getattr(user, "phone", ""))
        if not me:
            return False
        testers = A.ad_test_phones((admob_cfg or {}).get("ad_test_phones"))
        reviewer = A.phone_key(os.environ.get("PLAY_REVIEWER_PHONE", ""))
        if reviewer:
            testers.add(reviewer)
        return me in testers
    except Exception:
        return True


class AdsConfigView(APIView):
    def get(self, request):
        from . import billing, integrations, plans
        from .logic import ads as A
        user = request.user
        try:
            plan = plans.effective_plan(user)
        except Exception:
            plan = "free"
        paid = plan != "free"
        # playaudit2: a parent-declared child account never sees ads
        from .guardianship import is_known_minor
        minor = (not paid) and is_known_minor(user)
        try:
            admob_cfg = integrations.get("admob")
            working = integrations.is_enabled("admob")
        except Exception:
            admob_cfg, working = {}, False
        try:
            c = billing.cfg()
            caps = c["ad_rewards"]
            hero_refresh = (c.get("home_hero") or {}).get("refresh_sec", 90)
        except Exception:
            caps, hero_refresh = {}, 90
        try:
            ad_control = c.get("ad_control")
        except Exception:
            ad_control = None
        out = A.client_config(
            plan=plan, paid=paid or minor, admob_cfg=admob_cfg, admob_working=working,
            flag_rewarded=billing.flag_on("ads_rewarded"),
            flag_app_open=billing.flag_on("ads_app_open"),
            ad_caps=caps, hero_refresh=hero_refresh,
            ad_control=ad_control,
            test_ads_only=test_ads_account(user, admob_cfg))
        if minor:
            out["ads_enabled"] = False
            out["ads_off_reason"] = "minor"
            for row in (out.get("control") or {}).get("placements", {}).values():
                row["on"] = False
        return Response(out)
