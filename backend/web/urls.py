from django.urls import include, path
from . import views
from .owner.urls import site_robots
from . import views_legal
from . import views_pay1   # pay1
from . import views_booking   # booking-bot
from . import views_journey   # journey100
from . import views_quote   # crm100
from . import views_invoice   # invoices
from . import views_vehicle_share   # veh100
from . import views_at_watch   # antitheft2
from . import views_site   # website (owner 2 Nov)
from . import views_site3  # sitev3: website v3 behind the go-live switch

urlpatterns = [
    # sitev3: the go-live switch picks the current site (OFF) or v3 (ON)
    path("", views_site3.home),
    path("pricing", views_site3.pricing),
    path("security", views_site3.security),
    path("help", views_site3.help_page),
    path("features", views_site3.features_index),
    path("features/<str:gid>", views_site3.feature_group),
    path("preview/", views_site3.preview),                       # noindex review
    path("download/apk", views_site3.download_apk),               # sitev3: owner-chosen APK
    path("preview/features", views_site3.preview, {"page": "features"}),
    path("preview/features/<str:gid>", views_site3.preview_group),
    path("preview/pricing", views_site3.preview, {"page": "pricing"}),
    path("preview/security", views_site3.preview, {"page": "security"}),
    path("preview/help", views_site3.preview, {"page": "help"}),
    path("site/<path:name>", views_site.site_asset),
    path("favicon.ico", views_site.favicon_ico),
    path("apple-touch-icon.png", views_site.apple_touch_icon),
    path("site.webmanifest", views_site.webmanifest),
    path("get", views.get_app),
    path("khata-free", views.khata_free),   # ledger100
    # antitheft2: a trusted contact's signed web view of a protected phone
    path("w/phone/<str:token>", views_at_watch.phone_page),

    # ---- o2-admin: web owner admin panel (2FA, own session cookie) ----
    # Replaces the old password-only /owner/integrations page (same URL now
    # lives inside the panel). robots.txt keeps crawlers off /owner/.
    path("owner/", include("web.owner.urls")),
    path("robots.txt", site_robots),
    # ---- /o2-admin ----

    path("cv", views.cv),
    path("cv/r", views.cv_share),
    path("cv/card.png", views.cv_card),

    path("scam", views.scam),
    path("scam/r", views.scam_share),
    path("scam/card.png", views.scam_card),

    path("photo", views.photo),
    path("photo/app", views.photo_app),          # w1-webphoto App Link target (no image bytes)
    path(".well-known/assetlinks.json", views.assetlinks),

    path("festival", views.festival),
    path("festival/card.png", views.festival_card),

    path("made30", views.made30),
    path("made30/card.png", views.made30_card),

    path("wrapped/card.png", views.wrapped_card),

    # ---- l1-launch: Play/AdMob legal pages, app-ads.txt, sitemap ----
    path("privacy", views_legal.privacy),
    path("terms", views_legal.terms),
    path("refund-policy", views_legal.refund_policy),   # billing-v2
    path("delete-account", views_legal.delete_account),
    path("app-ads.txt", views_legal.app_ads_txt),
    path("sitemap.xml", views_legal.sitemap_xml),
    # ---- /l1-launch ----

    # ---- pay1: website checkout (phone OTP) + gateway browser return ----
    path("premium", views_pay1.premium),
    path("pay/return", views_pay1.pay_return),
    # ---- /pay1 ----

    # booking-bot: a business' public booking page + the guest's manage link
    path("b/m/<str:token>", views_booking.booking_manage),
    path("b/<slug:slug>", views_booking.booking_page),

    # m3-circle: My Circle invite link landing (QR / share / SMS)
    path("i/<str:token>", views.circle_invite),

    # journey100: Safe Journey watcher page (signed expiring token, noindex)
    path("j/<str:token>/data", views_journey.watch_data),
    path("j/<str:token>", views_journey.watch_page),

    # crm100: a shop's price quote — the customer accepts / declines (signed
    # link, no login, noindex, rate-limited, bn/en)
    path("r/<str:token>", views_invoice.verify_page),   # invoices QR check
    path("q/<str:token>", views_quote.quote_page),
    path("qp/<str:token>", views_quote.proposal_page),
    # veh100: vehicle live-location share link (random token, expiring, revocable)
    path("v/<str:token>/data", views_vehicle_share.share_data),
    path("v/<str:token>", views_vehicle_share.share_page),
]
