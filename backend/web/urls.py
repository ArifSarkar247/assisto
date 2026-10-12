from django.urls import path
from . import views

urlpatterns = [
    path("", views.landing),
    path("get", views.get_app),

    path("cv", views.cv),
    path("cv/r", views.cv_share),
    path("cv/card.png", views.cv_card),

    path("scam", views.scam),
    path("scam/r", views.scam_share),
    path("scam/card.png", views.scam_card),

    path("photo", views.photo),

    path("festival", views.festival),
    path("festival/card.png", views.festival_card),
]
