from django.urls import path
from . import views
from .integrations_admin import integrations_admin

urlpatterns = [
    path("", views.landing),
    path("get", views.get_app),

    # Owner-only Integrations admin (Django session auth)
    path("owner/integrations", integrations_admin),

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
]
