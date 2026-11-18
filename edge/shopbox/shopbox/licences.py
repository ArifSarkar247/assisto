"""cctvdet3: "About & licences" — what the Shop Box runs and whose work it is
built on, shown to the user in the app window (ui.AboutWindow), next to the
models it describes. The same text as the model card published with the
vehicle model (tools/e2e/cctv_vehicle_model_card.md).

Names, licence names, DOIs and links stay as written by their owners; the
explanations are in the user's language.
"""
from __future__ import annotations

from . import model_fetch

PERSON_MODEL = {
    "name": "YOLOX-Nano",
    "file": model_fetch.MODEL_FILENAME,
    "sha256": model_fetch.MODEL_SHA256,
    "by": "Megvii",
    "licence": "Apache License 2.0",
    "source": "https://github.com/Megvii-BaseDetection/YOLOX",
}

VEHICLE_MODEL = {
    "name": "Assisto Bangladesh vehicle model",
    "file": model_fetch.BD_VEHICLE_MODEL_FILENAME,
    "sha256": model_fetch.BD_VEHICLE_MODEL_SHA256,
    "url": model_fetch.BD_VEHICLE_MODEL_URL,
    "base": "YOLOX-Nano + YOLOX 0.3.0 code by Megvii (Apache License 2.0)",
    "data": ('"Multi-Class Vehicle Detection Dataset for Dense and Heterogeneous Urban Traffic '
             'in Bangladesh", Rahman A., Munim Shahriar S., Awsaf S.A., Jahan I., Ferdous J., '
             'Chowdhury M.J.U. (Leading University, Sylhet), Mendeley Data v2, '
             'DOI 10.17632/tx6699m24b.2 — CC BY 4.0 '
             '(https://creativecommons.org/licenses/by/4.0/)'),
    "negatives": ("COCO train2017 pictures with their own CC BY 2.0 / CC BY-SA 2.0 / "
                  "no-known-copyright / US Government licence; COCO annotations CC BY 4.0 "
                  "(https://cocodataset.org)"),
}

FALLBACK_VEHICLE_MODEL = {
    "name": "YOLOX-Tiny",
    "file": model_fetch.VEHICLE_MODEL_FILENAME,
    "by": "Megvii",
    "licence": "Apache License 2.0",
    "source": "https://github.com/Megvii-BaseDetection/YOLOX",
}

_TEXT = {
    "en": {
        "intro": "This box finds people and vehicles on your own cameras. It never recognises "
                 "faces and never tells who a person is. These are the models it uses and "
                 "whose work they are built on.",
        "person": "People: {name} by {by}, {licence} — {source}",
        "vehicle": "Vehicles (only for parking, no-parking and vehicle gate-line zones): {name}.",
        "vbase": "Built from: {base}.",
        "vdata": "Trained on: {data}. Changes made: photos resized and augmented, local "
                 "classes mapped to COCO vehicle classes. The dataset's authors do not endorse "
                 "this model.",
        "vneg": "Vehicle-free example pictures: {negatives}.",
        "vfile": "File: {file} (SHA-256 {sha256}), published at {url}",
        "fallback": "Until that file is downloaded: {name} by {by}, {licence} — {source}",
    },
    "bn": {
        "intro": "এই বক্স আপনার নিজের ক্যামেরায় মানুষ ও গাড়ি খোঁজে। এটি কখনো মুখ চেনে না, কে মানুষটি "
                 "তা বলে না। নিচে এটি কোন মডেল ব্যবহার করে আর সেগুলো কাদের কাজের ওপর তৈরি, তা দেওয়া হলো।",
        "person": "মানুষ: {name}, তৈরি করেছে {by}, লাইসেন্স {licence} — {source}",
        "vehicle": "গাড়ি (শুধু পার্কিং, নো-পার্কিং ও গাড়ির গেট-রেখা জোনে): {name}।",
        "vbase": "যার ওপর তৈরি: {base}।",
        "vdata": "যে ছবিতে শেখানো: {data}। যা বদলানো হয়েছে: ছবি ছোট করা ও শেখানোর সময় নানা "
                 "পরিবর্তন, স্থানীয় গাড়ির ধরন COCO-র গাড়ির ধরনে মেলানো। ডেটাসেটের লেখকেরা এই মডেলকে "
                 "সমর্থন বা অনুমোদন করেননি।",
        "vneg": "গাড়ি-ছাড়া উদাহরণ ছবি: {negatives}।",
        "vfile": "ফাইল: {file} (SHA-256 {sha256}), প্রকাশিত: {url}",
        "fallback": "ওই ফাইল নামানোর আগে পর্যন্ত: {name}, তৈরি করেছে {by}, লাইসেন্স {licence} — {source}",
    },
}


def about_text(lang: str = "bn") -> str:
    """The whole About & licences text in ONE language (bn / en)."""
    s = _TEXT.get(lang, _TEXT["en"])
    lines = [s["intro"], "", s["person"].format(**PERSON_MODEL), "",
             s["vehicle"].format(**VEHICLE_MODEL),
             s["vbase"].format(**VEHICLE_MODEL),
             s["vdata"].format(**VEHICLE_MODEL),
             s["vneg"].format(**VEHICLE_MODEL),
             s["vfile"].format(**VEHICLE_MODEL),
             "", s["fallback"].format(**FALLBACK_VEHICLE_MODEL)]
    return "\n".join(lines)
