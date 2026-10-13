"""
Job hunter agent (feature 37). Deterministic match score from the overlap
between a job description and the user's own skills/experience (from memory +
a profile blob). AI only *tailors* a CV/cover letter when a key is present —
never fabricates qualifications. NEVER auto-applies: the user approves and
sends from their own Gmail (gated on the google_oauth integration).
"""
import re

from . import ai
from .i18n import pick

_WORD = re.compile(r"[a-zA-Zঀ-৿]{3,}")
_STOP = {"and", "the", "for", "with", "you", "are", "will", "have", "job",
         "work", "team", "এবং", "জন্য", "করতে", "আপনি", "হবে", "কাজ"}


def _tokens(text):
    return {w.lower() for w in _WORD.findall(text or "") if w.lower() not in _STOP}


def user_skills(user):
    """Gather the user's skills/keywords from their own memory items + profile."""
    from .models import MemoryItem
    blob = " ".join(m.title + " " + (m.detail or "")
                    for m in MemoryItem.objects.filter(user=user)[:200])
    return _tokens(blob)


# NOTE for integrator: core/views.py JobViewSet.perform_create calls match()
# without a lang; thread it through, e.g.:
#   from .i18n import req_lang
#   score, reason = jobs.match(jd, skills, lang=req_lang(self.request))
def match(jd, skills, lang="bn"):
    """Return (score 0-100, reason). Overlap of JD terms with user's skills."""
    jd_tokens = _tokens(jd)
    if not jd_tokens:
        return (0, pick(lang, "চাকরির বিবরণ নেই", "No job description"))
    overlap = jd_tokens & skills
    ratio = len(overlap) / max(1, len(jd_tokens))
    score = min(100, int(ratio * 140))     # scaled; capped
    top = ", ".join(sorted(overlap)[:6]) or "—"
    if score >= 70:
        reason = pick(lang,
                      f"ভালো মিল: {top} — আপনার দক্ষতার সাথে মেলে।",
                      f"Good match: {top} — fits your skills.")
    elif score >= 40:
        reason = pick(lang,
                      f"আংশিক মিল: {top}। কিছু দক্ষতা জোর দিন।",
                      f"Partial match: {top}. Emphasise a few skills.")
    else:
        reason = pick(lang,
                      f"কম মিল। মিল পাওয়া গেছে: {top}।",
                      f"Low match. Matched: {top}.")
    return (score, reason)


# NOTE for integrator: core/views.py JobTailorView.post calls tailor_documents()
# without a lang; pass lang=req_lang(request).
def tailor_documents(user, jd, extra="", lang="bn"):
    """AI-tailored CV + cover letter from the user's OWN data. needs-key state
    otherwise. Never invents qualifications the user didn't provide."""
    if not ai.available():
        return {"needs_key": True,
                "msg": pick(lang,
                            "চালু হবে যখন AI key যোগ হবে",
                            "Available when an AI key is added")}
    skills = ", ".join(sorted(user_skills(user))[:40])
    data = pick(
        lang,
        f"ব্যবহারকারীর দক্ষতা/অভিজ্ঞতা: {skills}\n\nঅতিরিক্ত: {extra}\n\nচাকরি: {jd}",
        f"User's skills/experience: {skills}\n\nExtra: {extra}\n\nJob: {jd}")
    try:
        cv, _ = ai.generate(
            task=pick(
                lang,
                ("ব্যবহারকারীর দেওয়া দক্ষতা/অভিজ্ঞতা দিয়ে এই চাকরির জন্য একটি CV-এর "
                 "মূল অংশ বুলেট পয়েন্টে লেখো। যা নেই তা বানাবে না।"),
                ("Using the skills/experience the user provided, write the main "
                 "body of a CV for this job as bullet points. Do not invent "
                 "anything they did not provide.")),
            data=data, tier="medium", feature="jobs.cv", max_tokens=700, user=user)
        cover, _ = ai.generate(
            task=pick(
                lang,
                "এই চাকরির জন্য একটি সংক্ষিপ্ত, আন্তরিক কভার লেটার লেখো (ব্যবহারকারীর তথ্যের মধ্যে থেকে)।",
                "Write a short, sincere cover letter for this job, staying within the user's own information."),
            data=data, tier="medium", feature="jobs.cover", max_tokens=500, user=user)
        return {"cv_text": cv, "cover_letter": cover, "ai_used": True}
    except ai.AIUnavailable as e:
        return {"needs_key": e.reason == "no_key", "reason": e.reason}
