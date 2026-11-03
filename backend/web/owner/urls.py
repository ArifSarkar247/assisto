from django.http import Http404, HttpResponse, HttpResponseRedirect
from django.urls import path
from pathlib import Path

from . import security as S
from . import views_auth as A
from . import views_sections as V
from . import views_f1 as F1
from . import views_pay1 as PAY1   # pay1
from . import views_t9 as T9
from . import views_cctvtraffic as CCTVT   # cctvguard
from . import views_mapsusage as MAPSU   # mapscost
from . import views_sc1 as SC1   # sc1 app errors
from . import views_p1 as P1     # p1-bizagent sellers
from . import views_p2 as P2     # p2-money
from . import views_p4 as P4     # p4-world
from . import views_d1photo as D1P   # d1-photo v2
from . import views_p5 as P5         # p5-growth funnel
from . import views_pv1 as PV1       # play-vitals
from . import views_ff1 as FF1       # feature-flags
from . import views_bill2 as B2      # billing-v2
from . import views_air as AIR       # ai-report
from . import views_chrep as CHREP   # channels
from . import views_ai as AIRT       # ai-router
from . import views_ops as OPS       # ops-watch
from . import views_agent as AGR     # agent-core
from . import views_train as TRS     # flagprep: train timetable check
from . import views_crisis as CRH    # af-crisis
from . import views_missing as MIS   # missing
from . import views_blood as BLD     # blood
from . import views_site3 as WS3     # sitev3: website go-live switch
from . import views_market as MKT     # amarket
from . import views_safety as SAF    # adminsafe: stats, actions, appeals, staff
from . import views_buylinks as BUY   # chipbuy2: own-shop buy links

_ASSETS = {"owner.css": "text/css; charset=utf-8",
           "owner.js": "application/javascript; charset=utf-8"}
_DIR = Path(__file__).resolve().parent / "assets"


def asset(request, name):
    if name not in _ASSETS:
        raise Http404
    resp = HttpResponse((_DIR / name).read_bytes(), content_type=_ASSETS[name])
    S.harden(resp)
    resp["Cache-Control"] = "private, max-age=3600"
    return resp


def robots(request):
    return S.harden(HttpResponse("User-agent: *\nDisallow: /\n",
                                 content_type="text/plain; charset=utf-8"))


def site_robots(request):
    """Root /robots.txt: keep crawlers off the owner panel. l1-launch: points
    crawlers at /sitemap.xml (privacy/terms/delete-account are listed there)."""
    from django.conf import settings
    site = getattr(settings, "WEB_PUBLIC_SITE", "https://lifeassisto.com").rstrip("/")
    return HttpResponse("User-agent: *\nDisallow: /owner/\n\nSitemap: %s/sitemap.xml\n" % site,
                        content_type="text/plain; charset=utf-8")


urlpatterns = [
    path("", V.dashboard),
    path("robots.txt", robots),
    path("assets/<str:name>", asset),
    path("login", A.login_view),
    path("2fa", A.mfa_view),
    path("enrol", A.enrol_view),
    path("logout", A.logout_view),
    path("discover", V.discover_list),
    path("discover/new", V.discover_new),
    path("discover/reorder", V.discover_reorder),
    path("discover/<int:pk>", V.discover_edit),
    path("discover/<int:pk>/toggle", V.discover_toggle),
    path("discover/<int:pk>/delete", V.discover_delete),
    path("discover/<int:pk>/report", V.discover_report),
    path("discover/<int:pk>/report.<str:fmt>", V.discover_report),
    path("pricing", V.pricing),
    path("pnl", V.pnl),
    path("ads", V.ads),
    path("integrations", V.integrations),
    path("users", SAF.users),                          # adminsafe (stats + filters)
    path("users/<int:pk>", V.user_detail),
    path("users/<int:pk>/act", SAF.user_act),          # adminsafe
    path("appeals", SAF.appeals),                      # adminsafe
    path("appeals/<int:pk>/decide", SAF.appeal_decide),  # adminsafe
    path("staff", SAF.staff),                          # adminsafe
    path("reports", V.reports),
    path("reports/errors", SC1.app_errors),                 # sc1
    path("reports/errors/<str:fp>", SC1.app_error_detail),  # sc1
    path("audit", V.audit_log),
    path("security", V.security),
    # ---- f1-founders ----
    path("founders", F1.founders),
    path("feedback", F1.feedback_list),
    path("feedback.csv", F1.feedback_csv),
    path("feedback/<int:pk>", F1.feedback_detail),
    # ---- /f1-founders ----
    path("payments", PAY1.payments),   # pay1
    path("payments/refunds", B2.refunds),        # billing-v2
    path("payments/flagged", B2.flagged),        # billing-v2
    path("payments/reports", B2.reports),        # billing-v2
    path("payments/unverified", B2.unverified),  # billing-v2
    path("calls", T9.calls),          # t9-turnscale: Call relay (TURN)
    path("cctv-traffic", CCTVT.cctv_traffic),   # cctvguard: CCTV live traffic
    path("maps-usage", MAPSU.maps_usage),       # mapscost: Maps usage + caps
    path("sellers", P1.sellers),      # p1-bizagent: Sellers (AI agent)
    # ---- p2-money ---- direct sponsors, campaigns, reports, ad impact
    path("sponsors", P2.sponsors),
    path("sponsors/<int:pk>", P2.sponsor_edit),
    path("campaigns/new", P2.campaign_new),
    path("campaigns/<int:pk>", P2.campaign_edit),
    path("campaigns/<int:pk>/report", P2.campaign_report),
    path("campaigns/<int:pk>/report.<str:fmt>", P2.campaign_report),
    path("impact", P2.ad_impact),
    path("world", P4.world),          # p4-world: Unseen World data sources
    path("estimate-rates", P4.estimate_rates),  # p2plan: estimator rates
    path("photo", D1P.photo),                                   # d1-photo v2
    path("photo/ab/<int:pk>/<str:tag>", D1P.photo_ab_image),     # d1-photo v2
    path("funnel", P5.funnel),                                   # p5-growth
    path("vitals", PV1.vitals),                                  # play-vitals
    path("vitals/issues/<int:pk>/known", PV1.issue_known),       # play-vitals
    path("features", FF1.features),                              # feature-flags
    path("website", WS3.website),                                # sitev3
    path("ai", AIRT.ai_page),                                     # ai-router
    path("features/<str:key>", FF1.feature_save),                # feature-flags
    path("ai-reports", AIR.ai_reports),                          # ai-report
    path("ai-reports/<int:pk>/resolve", AIR.ai_report_resolve),  # ai-report
    path("channel-reports", CHREP.channel_reports),                      # channels
    path("channel-reports/<int:pk>/act", CHREP.channel_report_act),      # channels
    path("market", MKT.market),                                          # amarket
    path("market/sellers/<int:pk>/act", MKT.market_seller_act),          # amarket
    path("market/reports/<int:pk>/act", MKT.market_report_act),          # amarket
    path("system", OPS.system_health),                           # ops-watch
    path("vitals/crash-rate", OPS.crash_rate_page),              # ops-watch
    path("agent-runs", AGR.agent_runs),                          # agent-core
    path("agent-runs/thresholds", AGR.agent_obs_save),           # af-8
    path("agent-runs/brief-rollout", AGR.agent_brief_rollout_save),  # flagprep
    path("train-schedule", TRS.train_schedule),                  # flagprep
    path("buy-links", BUY.buy_links),                            # chipbuy2
    path("agent-runs/feedback", AGR.agent_feedback_queue),       # af-12
    path("agent-runs/feedback/<int:pk>", AGR.agent_feedback_decide),  # af-12
    path("agent-runs/<int:pk>", AGR.agent_run_detail),           # agent-core
    path("crisis-helplines", CRH.crisis_helplines),                # af-crisis
    path("crisis-helplines/<str:key>", CRH.crisis_helpline_save),  # af-crisis
    path("missing", MIS.missing),                                  # missing
    path("missing/<int:pk>/act", MIS.missing_action),              # missing
    path("blood", BLD.blood),                                      # blood
    path("blood/<int:pk>/act", BLD.blood_action),                  # blood
    path("blood/slip/<int:pk>", BLD.blood_slip),                   # blood
]
