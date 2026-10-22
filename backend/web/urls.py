from django.urls import include, path
from . import views
from .owner.urls import site_robots

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

    path("festival", views.festival),
    path("festival/card.png", views.festival_card),

    path("made30", views.made30),
    path("made30/card.png", views.made30_card),

    path("wrapped/card.png", views.wrapped_card),

    # m3-circle: My Circle invite link landing (QR / share / SMS)
    path("i/<str:token>", views.circle_invite),
]
