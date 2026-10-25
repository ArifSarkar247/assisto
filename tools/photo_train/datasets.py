#!/usr/bin/env python3
"""Phase 2 "Assisto Face" — the ONLY data sources allowed for training
(commercial use permitted). Checked 24 Oct 2026; re-check before downloading.
NOT RUN. Writes nothing by itself; `build_face_crops.py` reads SOURCES.

Excluded on purpose (non-commercial / unclear): FFHQ, CelebA(-HQ),
CelebAMask-HQ, VGGFace2, MS1M, UTKFace, FaceSynthetics, DigiFace-1M,
LAION-Face, SFHQ, Casual Conversations, DIV2K, Flickr2K.
"""

SOURCES = [
    {"id": "unsplash_lite", "url": "https://github.com/unsplash/datasets",
     "licence": "Unsplash Dataset Commercial terms (TERMS.md): 'internally use the Commercial "
                "Licensed Data to train machine learning models … for your internal business purposes'; "
                "no redistribution", "commercial": True,
     "use": "portrait photos -> face crops (high quality targets)"},
    {"id": "open_images_v7_person", "url": "https://storage.googleapis.com/openimages/web/factsfigures_v7.html",
     "licence": "images listed as CC BY 2.0 (Google makes no warranty per image); annotations CC BY 4.0",
     "commercial": True, "use": "person boxes -> face crops; keep the per-image attribution list"},
    {"id": "wikimedia_pd_cc0_ccby", "url": "https://commons.wikimedia.org",
     "licence": "per file: Public domain / CC0 / CC BY (attribution) — read extmetadata LicenseShortName "
                "like tools/photo_eval/fetch_50.py does; personality rights are separate",
     "commercial": True, "use": "portraits incl. South Asian subjects (Category searches), old album photos"},
    {"id": "fairface", "url": "https://github.com/joojs/fairface", "licence": "CC BY 4.0 (repo)",
     "commercial": True, "use": "OPTIONAL, low-res, image provenance unclear (YFCC) — evaluation only by default",
     "caution": True},
    {"id": "assisto_opt_in", "url": "in-app consent (see PHOTO_OWN_MODEL_PLAN_BN.md)",
     "licence": "explicit, revocable user consent + privacy-policy update", "commercial": True,
     "use": "real BD phone / WhatsApp / album photos; never without the consent row"},
]


def allowed():
    return [s for s in SOURCES if s["commercial"] and not s.get("caution")]


if __name__ == "__main__":
    for s in SOURCES:
        print("%-22s %-5s %s" % (s["id"], "OK" if s["commercial"] else "NO", s["licence"][:90]))
