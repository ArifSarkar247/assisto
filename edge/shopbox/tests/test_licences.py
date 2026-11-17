"""cctvdet3: the About & licences text names every model the box runs, its
licence and (for the vehicle model) the CC BY 4.0 dataset credit — in both
languages, matching the pinned files."""
from shopbox import model_fetch
from shopbox.licences import about_text
from shopbox.strings import STRINGS


def test_both_languages_credit_every_model_and_dataset():
    for lang in ("bn", "en"):
        t = about_text(lang)
        assert "YOLOX-Nano" in t and "Megvii" in t and "Apache License 2.0" in t
        assert "YOLOX-Tiny" in t
        assert "CC BY 4.0" in t and "10.17632/tx6699m24b.2" in t
        assert "Rahman A." in t and "Leading University" in t
        assert "creativecommons.org/licenses/by/4.0" in t
        assert "COCO" in t
        assert model_fetch.BD_VEHICLE_MODEL_SHA256 in t
        assert model_fetch.BD_VEHICLE_MODEL_URL in t


def test_about_text_is_one_language_and_never_identity():
    assert "এই বক্স" in about_text("bn") and "This box" not in about_text("bn")
    assert "This box" in about_text("en") and "এই বক্স" not in about_text("en")
    assert "recognises faces" not in about_text("en").replace("never recognises faces", "")


def test_the_window_has_its_words():
    for lang in ("bn", "en"):
        assert STRINGS[lang]["about_btn"] and STRINGS[lang]["about_title"]
