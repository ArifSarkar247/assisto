from django.urls import include, path
from . import views
from .owner.urls import site_robots
from . import views_legal
from . import views_pay1   # pay1
from . import views_booking   # booking-bot
from . import views_journey   # journey100

urlpatterns = [
    path("", views.landing),
    path("get", views.get_app),

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
]
