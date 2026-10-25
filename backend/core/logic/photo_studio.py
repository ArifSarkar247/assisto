"""
photo_studio.py — the PURE brain of Photo Studio (ps1-photo).

No Django, no DB, no network, no clock. The stateful layer
(core/photo_studio_service.py) feeds it plain dicts and acts on its decisions.

It owns four things:

1. CONFIG — the admin-editable `photo_studio` block of PricingConfig
   (entry-interstitial cap, HD-enhance ads, max ads per job, daily free prompt
   trials, ad value override, preview size). normalize_cfg() clamps every
   number so a bad admin edit can never make the studio unsafe or free.

2. FUNDING / PROFIT GUARD — how a job is paid for, decided BEFORE any work:

     ad_value_bdt   = override, else ad_rewards.ecpm_bdt / 1000   (৳ per ad)
     ads_needed     = ceil(cost_bdt / (0.70 * ad_value_bdt))
     credits_needed = max(table credits, ceil(cost_bdt / net_floor / credit_bdt))

   If more than `max_ads_per_job` (default 3) ads would be needed the ad route
   is closed and the user is offered credits or Premium instead. A cloud job
   whose provider cost is UNKNOWN (0) is refused outright — we never run
   something we cannot price. funding_options() therefore can never return an
   option whose revenue is below its cost ("a loss-making edit is impossible",
   pinned by tests).

3. SAFETY — classify(prompt, options, flags) refuses sexual/undressing edits,
   putting a real person into a fake/compromising scene, and any editing of ID
   cards / certificates / document text / money / official seals. Children in
   the photo switch off beauty retouch and person-changing generation. Editing
   other people's photos shows a consent reminder. Bangla, Banglish and English
   keyword lists; it is a FIRST line (the cloud provider's own safety filter is
   the second) and is described honestly as keyword-based.

4. OWNER STATS — per-day, per-feature ad revenue vs cost from plain rows.
"""
import math
import re

# ------------------------------------------------------------------ features
# enhance_hd     on-device enhance, full-HD export (no server cost; ads/credits
#                only unlock the export)
# enhance_cloud  heavy-job / weak-phone enhance on a cloud provider
# prompt_edit    edit by prompt / ready option (cloud, generative)
# generate       new image from a prompt (cloud, generative)
# d1-photo restore jobs (no prompt, faithful, identity-checked on the phone):
# colorize / old_restore -> OUR server CPU (core/photo_restore.py);
# deblur -> pay-per-use GPU API behind the Admin key photo_restore_gpu.
RESTORE_FEATURES = ("deblur", "colorize", "old_restore")
# d1-photo v2: HD ENHANCE on OUR photo worker (face detect -> face detail
# pass -> full-image Real-ESRGAN -> FACE LOCK). Cost to us ~0 (own CPU, just
# slower); free users: N per day, each unlocked by 1 SSV rewarded ad; paid:
# no ads, an admin-editable daily fair-use cap (owner asked "unlimited";
# the standing rule is "nothing unlimited" -> high cap, default 100/day).
WORKER_FEATURES = ("enhance_server",)
# photo-final: ULTRA HD — Premium/Business only, a top hosted upscaler
# (fal.ai), monthly per-user quota computed so its cost never exceeds the
# owner-set share of the plan's NET price (server-enforced).
ULTRA_FEATURE = "ultra_hd"
FEATURES = (("enhance_hd", "enhance_cloud", "prompt_edit", "generate") + RESTORE_FEATURES
            + WORKER_FEATURES + (ULTRA_FEATURE,))
CLOUD_FEATURES = ("enhance_cloud", "prompt_edit", "generate") + RESTORE_FEATURES
TRIAL_FEATURES = ("prompt_edit", "generate")

# pricing action ids (core/logic/pricing.py _ACTION_DEFAULTS)
FEATURE_ACTION = {
    "enhance_hd": "photo_enhance_hd",
    "enhance_cloud": "photo_enhance_cloud",
    "prompt_edit": "photo_prompt_edit",
    "generate": "photo_generate",
    "deblur": "photo_deblur",
    "colorize": "photo_colorize",
    "old_restore": "photo_old_restore",
    "enhance_server": "photo_enhance_server",
    "ultra_hd": "photo_ultra_hd",
}

# every way an image can leave the studio — each one goes through ONE gate
EXPORT_KINDS = ("save", "share", "wallpaper", "copy", "open_in")

# ready (tickable) options — server copy; the app shows the same ids
READY_OPTIONS = (
    "bg_change", "bg_remove", "bg_blur", "sky_replace", "remove_objects",
    "lighting", "passport_bd", "visa_bd", "product_photo", "document_cleanup",
    "crop_straighten", "beauty_retouch",
)
# options that change pixels around a person generatively (need face-lock)
SCENE_OPTIONS = ("bg_change", "bg_remove", "bg_blur", "sky_replace",
                 "remove_objects", "lighting", "product_photo")
# faithful options (no generation) — allowed on documents too
FAITHFUL_OPTIONS = ("document_cleanup", "crop_straighten")

# Beauty retouch: the ONLY allowed operations ("same person, best version").
BEAUTY_ALLOWED = ("skin_smooth", "blemish_remove", "under_eye", "even_tone",
                  "glow", "teeth_whiten", "eye_brighten", "hair_tidy",
                  "light_makeup")
# Never allowed — face shape, feature size/shape, skin colour, age, gender,
# looking like someone else.
BEAUTY_FORBIDDEN = ("face_reshape", "jaw", "cheeks", "eye_size", "nose",
                    "lips", "skin_tone_change", "skin_lighten", "age_change",
                    "gender_change", "look_like")

# Bangladesh photo sizes (mm @ 300 dpi), white background.
BD_PHOTO_SIZES = {
    "passport_bd": {"w_mm": 40, "h_mm": 50, "bg": "#FFFFFF"},   # e-passport
    "visa_bd": {"w_mm": 50, "h_mm": 50, "bg": "#FFFFFF"},       # 2x2 in visa
    "stamp_bd": {"w_mm": 19, "h_mm": 25, "bg": "#FFFFFF"},      # stamp size
}

STRENGTHS = ("light", "natural", "strong")
DEFAULT_STRENGTH = "natural"

# ------------------------------------------------------------------ config
_DEFAULTS = {
    "entry_interstitial_gap_min": 30,   # entry ad at most once per 30 min
    "entry_interstitial_enabled": True,
    "enhance_hd_ads": 2,                # full-HD on-device result = 2 ads
    "enhance_hd_credits": 2,            # ... or this many credits
    "max_ads_per_job": 3,               # > this -> credits / Premium only
    "free_prompt_trials_per_day": 1,    # 1 ad-funded prompt trial per day
    "ad_value_bdt": 0.0,                # 0 -> derive from ad_rewards.ecpm_bdt
    "ad_value_share": 0.70,             # count at most 70% of the real value
    "preview_max_px": 1024,             # free preview long edge
    "ticket_ttl_min": 30,               # an unwatched ad ticket expires
    "provider": "",                     # '' = first connected provider
    # ---- d1-photo v2 pricing (owner order 6; every number editable) ----
    "free_enhance_per_day": 2,          # ad-unlocked free HD enhances per day (photo-final: 2)
    "free_enhance_ads": 1,              # ... each unlocked by this many SSV ads
    "premium_enhance_daily_cap": 100,   # paid fair-use cap (no ads)
    "free_gen_lifetime": 2,             # free AI generations per user, ever
    "free_gen_per_week": 1,             # after that: this many per week ...
    "free_gen_min_ads": 3,              # ... each after at least this many ads
    # ---- photo-final (owner 24 Oct: "beat Remini without losing money") ----
    # FREE HD enhance, server-enforced per account AND device (reinstall-proof):
    "free_enhance_lifetime": 3,         # free enhances per user/device, EVER
    "enhance_unlock_ads": 2,            # then each one = this many SSV ads (AdMob live)
    "free_enhance_per_week_no_ads": 1,  # until AdMob is live: this many free per week
    # (free_enhance_per_day stays: the daily cap on ad-unlocked enhances)
    # provider switch (server-side; % of users routed to each paid provider,
    # deterministic per user; the rest + every fallback = local_worker)
    "rollout_assisto_face": 0,
    "rollout_runpod_serverless": 0,
    "rollout_replicate": 0,
    "rollout_fal_face": 0,
    "provider_timeout_s": 120,          # then fall back to the previous provider
    "daily_spend_cap_usd": 1.0,         # all paid photo providers together, per day
    "cap_fallback_local": False,        # cap hit: False = job waits in the queue
    "face_restore_gfpgan": False,       # LOCKED OFF (owner 25 Oct): GFPGAN weights = FFHQ
                                        # BY-NC-SA -> never used; normalize forces False
    # Real-ESRGAN (code BSD-3; weights' licence silent, trained on academic-
    # only DIV2K/Flickr2K/OST) — OFF until the owner clears it. Off = every
    # Real-ESRGAN use (server local pipeline, old-photo restore, Replicate
    # nightmareai/real-esrgan, the RunPod handler, the phone's downloadable
    # ONNX) is replaced by the clean non-ML path (Lanczos + unsharp + look).
    "realesrgan_allowed": False,
    # face provider (owner to choose; commercial-use terms): '' = none,
    # 'topaz' = fal-ai/topaz/upscale/image, 'crystal' = clarityai/crystal-upscaler.
    # Runs only with the photo_fal key + its price + rollout_fal_face > 0.
    "fal_face_model": "",
    "face_blend_natural_pct": 55,       # fidelity blend of a restored face (Natural)
    "face_blend_strong_pct": 70,        # ... (Strong)
    "max_input_mp": 2,                  # every provider gets at most 2 MP
    # Ultra HD (Premium only, fal.ai): monthly per-user quota so that
    # quota x cost <= this share of the plan's NET price
    "ultra_hd_budget_pct": 25,
}
_BOUNDS = {
    "entry_interstitial_gap_min": (5, 1440),
    "enhance_hd_ads": (1, 3),
    "enhance_hd_credits": (1, 100),
    "max_ads_per_job": (1, 3),
    "free_prompt_trials_per_day": (0, 5),
    "preview_max_px": (256, 2048),
    "ticket_ttl_min": (5, 240),
    "free_enhance_per_day": (0, 20),
    "free_enhance_ads": (1, 3),
    "premium_enhance_daily_cap": (1, 1000),
    "free_gen_lifetime": (0, 10),
    "free_gen_per_week": (0, 7),
    "free_gen_min_ads": (1, 5),
    "free_enhance_lifetime": (0, 20),
    "enhance_unlock_ads": (1, 5),
    "free_enhance_per_week_no_ads": (0, 7),
    "rollout_assisto_face": (0, 100),
    "rollout_runpod_serverless": (0, 100),
    "rollout_replicate": (0, 100),
    "rollout_fal_face": (0, 100),
    "provider_timeout_s": (20, 600),
    "face_blend_natural_pct": (0, 100),
    "face_blend_strong_pct": (0, 100),
    "max_input_mp": (1, 8),
    "ultra_hd_budget_pct": (0, 60),
}
_BOOL_KEYS = ("entry_interstitial_enabled", "cap_fallback_local", "face_restore_gfpgan",
              "realesrgan_allowed")
FAL_FACE_MODELS = ("", "topaz", "crystal")
PROVIDERS = ("photo_gemini", "photo_openai", "photo_replicate")


def defaults():
    return dict(_DEFAULTS)


def _num(v, fb):
    if isinstance(v, bool):
        return fb
    try:
        return float(v)
    except (TypeError, ValueError):
        return fb


def normalize_cfg(raw):
    raw = raw if isinstance(raw, dict) else {}
    out = {}
    for k, (lo, hi) in _BOUNDS.items():
        out[k] = int(max(lo, min(hi, _num(raw.get(k), _DEFAULTS[k]))))
    for k in _BOOL_KEYS:
        out[k] = raw.get(k) if isinstance(raw.get(k), bool) else _DEFAULTS[k]
    # photo-final: global per-day spend cap on paid photo providers (USD)
    out["daily_spend_cap_usd"] = round(max(0.0, min(1000.0, _num(
        raw.get("daily_spend_cap_usd"), _DEFAULTS["daily_spend_cap_usd"]))), 4)
    out["ad_value_bdt"] = max(0.0, _num(raw.get("ad_value_bdt"), 0.0))
    # never count more than 70% of the real ad value (owner order)
    out["ad_value_share"] = max(0.05, min(0.70, _num(raw.get("ad_value_share"),
                                                     _DEFAULTS["ad_value_share"])))
    prov = str(raw.get("provider") or "").strip()
    out["provider"] = prov if prov in PROVIDERS else ""
    # owner decision 25 Oct: GFPGAN never runs, whatever a stored config says
    out["face_restore_gfpgan"] = False
    ff = str(raw.get("fal_face_model") or "").strip().lower()
    out["fal_face_model"] = ff if ff in FAL_FACE_MODELS else ""
    return out


def validate_cfg(raw):
    """Problem codes for an admin edit of the photo_studio block."""
    if raw is None:
        return []
    if not isinstance(raw, dict):
        return ["photo_studio_bad"]
    problems = []
    for k, v in raw.items():
        if k in _BOOL_KEYS or k == "provider":
            continue
        if k == "fal_face_model":
            if str(v or "").strip().lower() not in FAL_FACE_MODELS:
                problems.append("photo_studio_bad")
                break
            continue
        n = _num(v, None)
        if n is None or n < 0:
            problems.append("photo_studio_bad")
            break
    return problems


# ------------------------------------------------------------------ money
def ad_value_bdt(ps_cfg, ad_rewards):
    """৳ one rewarded ad really earns (the owner override wins, else the eCPM
    floor ÷ 1000)."""
    ps = normalize_cfg(ps_cfg)
    if ps["ad_value_bdt"] > 0:
        return ps["ad_value_bdt"]
    ecpm = _num((ad_rewards or {}).get("ecpm_bdt"), 0.0)
    return max(0.0, ecpm / 1000.0)


def ads_needed(cost_bdt, ad_value, share=0.70):
    """ceil(cost ÷ (share × ad value)). None when ads cannot cover it at all."""
    cost_bdt = max(0.0, float(cost_bdt or 0))
    per_ad = max(0.0, float(ad_value or 0)) * max(0.0, min(0.70, float(share)))
    if cost_bdt <= 0:
        return 0
    if per_ad <= 0:
        return None
    return int(math.ceil(cost_bdt / per_ad - 1e-9))


def credits_needed(cost_bdt, table_credits, net_floor, credit_bdt):
    """Credits that keep the NET-margin floor for this cost: the larger of the
    admin table value and ceil(cost ÷ net_floor ÷ credit_bdt)."""
    cost_bdt = max(0.0, float(cost_bdt or 0))
    floor = 0
    if cost_bdt > 0:
        nf = max(0.10, float(net_floor or 0.60))
        cb = max(0.01, float(credit_bdt or 1.0))
        floor = int(math.ceil(cost_bdt / nf / cb - 1e-9))
    return max(int(table_credits or 0), floor)


def funding_options(*, feature, plan, cost_usd, usd_bdt, table_credits,
                    net_floor, credit_bdt, ps_cfg, ad_rewards,
                    trials_used_today=0, guard_over=False, provider_ready=True,
                    usage=None, ads_live=True):
    """Decide how a job can be paid for, BEFORE any work runs.

    photo-final: `ads_live` False (AdMob still on Google TEST ids — Google's
    SSV never verifies those) marks every "watch ads" option `live: False`:
    the app shows no ad button (it reads the same server flag), the server
    issues NO ad ticket for it (photo_studio_service.issue_ticket), so the
    job can only be unlocked with credits / Premium — never a fake unlock.
    (The option itself stays: released apps create the free export job as
    an ads job and then pay it with credits through the gate.)
    """
    q = _funding_options(feature=feature, plan=plan, cost_usd=cost_usd, usd_bdt=usd_bdt,
                         table_credits=table_credits, net_floor=net_floor,
                         credit_bdt=credit_bdt, ps_cfg=ps_cfg, ad_rewards=ad_rewards,
                         trials_used_today=trials_used_today, guard_over=guard_over,
                         provider_ready=provider_ready, usage=usage)
    if not ads_live and any(o.get("via") == "ads" for o in q.get("options", [])):
        q = dict(q, options=[dict(o, live=False) if o.get("via") == "ads" else o
                             for o in q["options"]], ads_off="test_ids")
    return q


def _funding_options(*, feature, plan, cost_usd, usd_bdt, table_credits,
                     net_floor, credit_bdt, ps_cfg, ad_rewards,
                     trials_used_today=0, guard_over=False, provider_ready=True,
                     usage=None):
    """The rules behind funding_options (ads assumed live).

    Returns {ok, reason, cost_bdt, paid_plan, options:[...]} where each option is
      {"via": "pool"}                       Premium/Business: monthly pool credits
      {"via": "free"}                       no cost, nothing to unlock (paid enhance_hd)
      {"via": "ads", "ads": n, "trial": b}  free users: n rewarded ads first
      {"via": "credits", "credits": m}
    reason ∈ ok | unknown_feature | provider_missing | unpriced | guard_over |
             trial_used (informational: ads route closed, credits still offered)
    """
    if feature not in FEATURES:
        return {"ok": False, "reason": "unknown_feature", "options": []}
    paid = (plan or "free") != "free"
    ps = normalize_cfg(ps_cfg)
    cost_bdt = max(0.0, float(cost_usd or 0)) * max(0.01, float(usd_bdt or 0))
    base = {"cost_bdt": round(cost_bdt, 4), "paid_plan": paid}

    # ---- on-device enhance: no server cost, only the export is gated ----
    if feature == "enhance_hd":
        if paid:
            return {**base, "ok": True, "reason": "ok", "options": [{"via": "free"}]}
        return {**base, "ok": True, "reason": "ok", "options": [
            {"via": "ads", "ads": ps["enhance_hd_ads"], "trial": False},
            {"via": "credits", "credits": ps["enhance_hd_credits"]}]}

    # ---- photo-final: Ultra HD (paid plans, monthly quota) ----
    if feature == ULTRA_FEATURE:
        u = usage or {}
        if not paid:
            return {**base, "ok": False, "reason": "premium_only", "options": [],
                    "paywall": True}
        if not provider_ready or cost_bdt <= 0:
            return {**base, "ok": False, "reason": "provider_missing", "options": []}
        quota = int(u.get("ultra_quota", 0))
        used = int(u.get("ultra_month", 0))
        if used >= quota:
            return {**base, "ok": False, "reason": "ultra_quota", "options": [],
                    "quota": quota, "used": used}
        return {**base, "ok": True, "reason": "ok", "options": [{"via": "free"}],
                "quota": quota, "used": used, "left_month": quota - used}

    # ---- d1-photo v2: HD enhance on our worker ----
    if feature in WORKER_FEATURES:
        u = usage or {}
        if not provider_ready:
            return {**base, "ok": False, "reason": "provider_missing", "options": []}
        if paid:
            if int(u.get("enhance_today", 0)) >= ps["premium_enhance_daily_cap"]:
                return {**base, "ok": False, "reason": "fair_use_cap", "options": []}
            return {**base, "ok": True, "reason": "ok", "options": [{"via": "free"}]}
        return free_enhance_options(base, ps, u)

    # ---- cloud features ----
    if not provider_ready:
        return {**base, "ok": False, "reason": "provider_missing", "options": []}
    if cost_bdt <= 0:
        # never run a cloud job we cannot price
        return {**base, "ok": False, "reason": "unpriced", "options": []}
    credits = credits_needed(cost_bdt, table_credits, net_floor, credit_bdt)
    if paid:
        return {**base, "ok": True, "reason": "ok",
                "options": [{"via": "pool", "credits": credits}]}
    if guard_over:
        return {**base, "ok": False, "reason": "guard_over", "options": []}
    options = []
    reason = "ok"
    ad_val = ad_value_bdt(ps, ad_rewards)
    n = ads_needed(cost_bdt, ad_val, ps["ad_value_share"])
    ads_ok = n is not None and 0 < n <= ps["max_ads_per_job"]
    if feature in TRIAL_FEATURES and usage is not None:
        # d1-photo v2: lifetime gifts first (an owner-approved marketing cost,
        # tracked per free user by the free-tier Profit Guard), then N per
        # week, each only after >= free_gen_min_ads SSV-verified ads.
        if int(usage.get("gen_lifetime", 0)) < ps["free_gen_lifetime"]:
            return {**base, "ok": True, "reason": "ok", "options": [
                {"via": "gift", "trial": True},
                {"via": "credits", "credits": credits}],
                "gifts_left": ps["free_gen_lifetime"] - int(usage.get("gen_lifetime", 0))}
        if int(usage.get("gen_week", 0)) >= ps["free_gen_per_week"]:
            ads_ok = False
            reason = "week_used"
        elif n is not None:
            n = max(n, ps["free_gen_min_ads"])
            ads_ok = 0 < n <= max(ps["max_ads_per_job"], ps["free_gen_min_ads"])
    elif feature in TRIAL_FEATURES:
        if trials_used_today >= ps["free_prompt_trials_per_day"]:
            ads_ok = False
            reason = "trial_used"
    if ads_ok:
        options.append({"via": "ads", "ads": n,
                        "trial": feature in TRIAL_FEATURES})
    elif reason == "ok":
        reason = "too_many_ads"
    options.append({"via": "credits", "credits": credits})
    return {**base, "ok": True, "reason": reason, "options": options,
            "ads_if_open": n}


def free_enhance_options(base, ps, u):
    """photo-final (owner 24 Oct) — FREE users' HD enhance, decided on the
    server from counters taken per account AND per device (the larger wins,
    so a reinstall or a second account on the same phone cannot reset them):

      1. `free_enhance_lifetime` (3) free enhances, ever       -> via "gift"
      2. then, once AdMob is live: each enhance = `enhance_unlock_ads` (2)
         SSV-verified rewarded ads, at most `free_enhance_per_day` a day
      3. until AdMob is live: `free_enhance_per_week_no_ads` (1) free a week
      4. otherwise -> Premium paywall.
    `u` keys: lifetime_free, week_free, enhance_today, ads_live.
    (`free_enhance_ads` is kept for older configs but no longer used.)"""
    life = int(u.get("lifetime_free", 0))
    if life < ps["free_enhance_lifetime"]:
        return {**base, "ok": True, "reason": "ok", "free_kind": "lifetime",
                "options": [{"via": "gift", "trial": False}],
                "free_left": ps["free_enhance_lifetime"] - life}
    if u.get("ads_live"):
        if int(u.get("enhance_today", 0)) >= ps["free_enhance_per_day"]:
            return {**base, "ok": False, "reason": "daily_limit", "options": [],
                    "paywall": True}
        return {**base, "ok": True, "reason": "ok", "options": [
            {"via": "ads", "ads": ps["enhance_unlock_ads"], "trial": False}],
            "left_today": ps["free_enhance_per_day"] - int(u.get("enhance_today", 0))}
    week = int(u.get("week_free", 0))
    if week < ps["free_enhance_per_week_no_ads"]:
        return {**base, "ok": True, "reason": "ok", "free_kind": "week",
                "options": [{"via": "gift", "trial": False}],
                "free_left": ps["free_enhance_per_week_no_ads"] - week}
    return {**base, "ok": False, "reason": "week_free_used", "options": [], "paywall": True}


def option_revenue_bdt(option, *, ad_value, share, credit_bdt):
    """What an option is worth to us in ৳ (for the loss test + dashboard)."""
    via = option.get("via")
    if via == "ads":
        return option["ads"] * ad_value * share
    if via in ("credits", "pool"):
        return option.get("credits", 0) * credit_bdt
    return 0.0   # "free" (paid plan / on-device) and "gift" (owner-approved free AI)


# ------------------------------------------------------------------ safety
def _norm_text(s):
    s = (s or "").lower()
    s = re.sub(r"\s+", " ", s)
    return s


# sexual / undressing (en, Banglish, Bangla)
_SEXUAL = (
    "nude", "naked", "nudity", "undress", "undressed", "remove clothes",
    "remove her clothes", "remove his clothes", "without clothes", "no clothes",
    "take off clothes", "topless", "bikini", "lingerie", "underwear", "sexy",
    "seductive", "porn", "nsfw", "erotic", "see through", "see-through",
    "cleavage", "xxx", "boobs", "breasts",
    "nangta", "nengta", "jama khulo", "kapor khulo", "kapor chara", "jama chara",
    "উলঙ্গ", "ন্যাংটা", "নগ্ন", "কাপড় খুল", "জামা খুল", "কাপড় ছাড়া",
    "জামা ছাড়া", "অশ্লীল", "সেক্সি", "যৌন",
)
# real person into a fake or compromising scene
_FAKE_SCENE = (
    "with a celebrity", "with celebrity", "with shakib", "with the prime minister",
    "with a politician", "kissing", "kiss", "hugging a stranger", "in bed with",
    "in jail", "behind bars", "arrested", "handcuff", "in handcuffs",
    "drunk", "drinking alcohol", "smoking weed", "holding a gun", "with a gun",
    "with drugs", "taking a bribe", "bribe", "crime scene", "make him a criminal",
    "make her a criminal", "fake proof", "fake evidence", "deepfake",
    "face swap", "swap face", "swap faces", "put my face on", "put her face",
    "put his face", "replace face", "make him look like", "make her look like",
    "make me look like",
    "jail e", "grefter", "ghush", "mod khacche", "mod khawa", "chumu",
    "জেলে", "গ্রেফতার", "হাতকড়া", "ঘুষ", "মদ খা", "চুমু", "নেশা",
    "মুখ বদল", "ফেস সোয়াপ", "অন্যের মুখ", "ভুয়া প্রমাণ", "নকল প্রমাণ",
)
# ID / certificate / document text / money / official seals (fraud)
_DOCUMENT_FRAUD = (
    "nid", "national id", "id card", "passport number", "passport page",
    "birth certificate", "certificate", "marksheet", "mark sheet", "transcript",
    "result sheet", "change the date", "change date", "change the name",
    "change name on", "edit the text", "change the text", "change text",
    "signature", "forge", "forged", "seal", "stamp on", "official stamp",
    "fake money", "banknote", "bank note", "currency note", "taka note", "cheque",
    "check amount",
    "bank statement", "salary slip", "payslip", "invoice amount", "receipt amount",
    "license number", "licence number", "driving licence", "driving license",
    "trade license", "visa sticker", "land deed", "dolil",
    "jatiyo porichoy", "porichoy potro", "sonod", "shil mohor", "takar note",
    "জাতীয় পরিচয়", "পরিচয়পত্র", "এনআইডি", "সার্টিফিকেট", "সনদ", "মার্কশিট",
    "জন্ম নিবন্ধন", "স্বাক্ষর", "সিলমোহর", "সিল মোহর", "সীলমোহর", "টাকার নোট",
    "চেকের", "দলিল", "লাইসেন্স", "তারিখ বদল", "নাম বদল", "লেখা বদল",
)
# beauty changes that alter identity (shape / size / skin colour / age / gender)
_IDENTITY_CHANGE = (
    "slim face", "slimmer face", "thin face", "v shape", "v-shape", "jawline",
    "smaller nose", "bigger eyes", "big eyes", "bigger lips", "fuller lips",
    "thinner lips", "change nose", "nose job", "reshape", "face shape",
    "fair skin", "fairer", "make me fair", "make me white", "whiter skin",
    "lighten skin", "skin whitening", "darker skin", "change skin colour",
    "change skin color", "look younger", "look older", "make me younger",
    "make me older", "age me", "de-age", "change gender", "make me a girl",
    "make me a boy", "gender swap",
    "forsa", "pholsha", "chikon mukh", "boro chokh", "nak choto",
    "ফর্সা", "সাদা করে", "গায়ের রং", "চিকন মুখ", "মুখ চিকন", "নাক ছোট",
    "চোখ বড়", "ঠোঁট বড়", "ঠোঁট মোটা", "বয়স কম", "বয়স বেশি", "মেয়ে বানাও", "ছেলে বানাও",
)
# children in the photo
_CHILD = ("child", "kid", "baby", "toddler", "boy of", "girl of", "my son",
          "my daughter", "school boy", "schoolgirl", "minor",
          "bachcha", "baccha", "shishu",
          "বাচ্চা", "শিশু", "ছোট্ট")
# words that refer to people other than the user
_OTHERS = ("my friend", "friend", "my wife", "my husband", "my mother",
           "my father", "someone", "her photo", "his photo", "this girl",
           "this boy", "this man", "this woman", "girlfriend", "boyfriend",
           "bondhu", "bou", "jamai", "ammu", "abbu",
           "বন্ধু", "বউ", "স্বামী", "স্ত্রী", "আম্মু", "আব্বু", "মেয়েটি", "ছেলেটি")


def _hit(text, words):
    for w in words:
        if not w:
            continue
        if re.fullmatch(r"[a-z0-9 \-]+", w):
            # whole-word match for latin words (so "kissan" != "kiss",
            # "nidhi" != "nid", "seal" in "sealant" is still rare enough)
            if re.search(r"(?<![a-z])" + re.escape(w) + r"(?![a-z])", text):
                return w
        elif w in text:
            return w
    return None


_SKIN_RE = (
    re.compile(r"(?<![a-z])(skin|complexion)(?![a-z]).{0,24}(?<![a-z])"
               r"(fair|fairer|white|whiter|lighter|darker|brown|black)(?![a-z])"),
    re.compile(r"(?<![a-z])(fair|fairer|white|whiter|lighter|darker)(?![a-z]).{0,12}"
               r"(?<![a-z])(skin|complexion)(?![a-z])"),
)


def _skin_colour_change(text):
    for rx in _SKIN_RE:
        m = rx.search(text)
        if m:
            return m.group(0)
    return None


_SUGGESTIVE = (
    "hot", "sexy", "seductive", "sensual", "romantic", "bold look", "kiss",
    "lipstick", "heavy makeup", "short dress", "mini skirt", "crop top", "flirty",
    "বোল্ড", "হট", "রোমান্টিক", "চুমু",
)


def classify(prompt="", options=None, *, beauty_ops=None, photo_kind="",
             child_in_photo=False, others_in_photo=False, own_photo=True,
             feature="prompt_edit", consent=None):
    """Server-side safety decision for a job. Pure.

    Returns {allowed, reason, matched, flags:{child_caution, consent_reminder,
    face_lock, ai_edited}}. reason ∈ ok | sexual | fake_scene | document_fraud |
    identity_change | beauty_not_allowed | child_beauty | child_generation |
    bad_option."""
    text = _norm_text(prompt)
    opts = [o for o in (options or []) if isinstance(o, str)]
    beauty = [b for b in (beauty_ops or []) if isinstance(b, str)]
    kind = (photo_kind or "").strip().lower()
    child = bool(child_in_photo) or bool(_hit(text, _CHILD))
    others = bool(others_in_photo) or (not own_photo) or bool(_hit(text, _OTHERS))
    flags = {
        "child_caution": child,
        "consent_reminder": others,
        "face_lock": any(o in SCENE_OPTIONS for o in opts) or feature != "enhance_hd",
        "ai_edited": feature != "enhance_hd" or bool(opts),
    }

    def no(reason, matched=None):
        return {"allowed": False, "reason": reason, "matched": matched,
                "flags": flags}

    for o in opts:
        if o not in READY_OPTIONS:
            return no("bad_option", o)
    m = _hit(text, _SEXUAL)
    if m:
        return no("sexual", m)
    m = _hit(text, _FAKE_SCENE)
    if m:
        return no("fake_scene", m)
    # documents: only faithful cleanup/crop is ever allowed, never text edits
    doc_kind = kind in ("document", "id_card", "nid", "passport_doc",
                        "certificate", "money", "official")
    m = _hit(text, _DOCUMENT_FRAUD)
    if m:
        return no("document_fraud", m)
    if doc_kind:
        generative = bool(text.strip()) or any(o not in FAITHFUL_OPTIONS for o in opts) \
            or feature in ("prompt_edit", "generate")
        if generative:
            return no("document_fraud", kind)
    m = _hit(text, _IDENTITY_CHANGE) or _skin_colour_change(text)
    if m:
        return no("identity_change", m)
    for b in beauty:
        if b in BEAUTY_FORBIDDEN:
            return no("identity_change", b)
        if b not in BEAUTY_ALLOWED:
            return no("beauty_not_allowed", b)
    if child:
        if beauty or "beauty_retouch" in opts:
            return no("child_beauty")
        if feature == "generate":
            return no("child_generation")
        m = _hit(text, _SUGGESTIVE)
        if m:
            return no("child_suggestive", m)
    # d1-photo v2: a realistic AI edit of OTHER real people needs their consent
    if others and consent is False and feature in ("prompt_edit", "generate"):
        return no("consent_needed")
    return {"allowed": True, "reason": "ok", "matched": None, "flags": flags}


# ------------------------------------------------------------------ SSV
def ssv_split(raw_query):
    """Split an AdMob SSV callback query string into (message, signature,
    key_id). The signed message is everything BEFORE '&signature=' (Google's
    documented scheme); key_id is the last parameter."""
    q = raw_query or ""
    idx = q.find("&signature=")
    if idx < 0:
        return None, None, None
    message = q[:idx]
    rest = q[idx + 1:]
    sig = None
    key_id = None
    for part in rest.split("&"):
        if part.startswith("signature="):
            sig = part[len("signature="):]
        elif part.startswith("key_id="):
            key_id = part[len("key_id="):]
    return message, sig, key_id


# ------------------------------------------------------------------ stats
def feature_stats(rows):
    """rows: [{date, feature, ad_revenue_bdt, credit_revenue_bdt, cost_bdt,
    jobs, ads}] -> {days:[...oldest first], features:[{feature, revenue, cost,
    margin}], totals}. All ৳ values are also given in poisha (int) for the app."""
    by_day = {}
    by_feat = {}
    for r in rows or []:
        d = str(r.get("date") or "")
        f = str(r.get("feature") or "")
        rev = float(r.get("ad_revenue_bdt") or 0) + float(r.get("credit_revenue_bdt") or 0)
        cost = float(r.get("cost_bdt") or 0)
        day = by_day.setdefault((d, f), {"date": d, "feature": f, "ad_revenue_bdt": 0.0,
                                         "credit_revenue_bdt": 0.0, "cost_bdt": 0.0,
                                         "jobs": 0, "ads": 0})
        day["ad_revenue_bdt"] += float(r.get("ad_revenue_bdt") or 0)
        day["credit_revenue_bdt"] += float(r.get("credit_revenue_bdt") or 0)
        day["cost_bdt"] += cost
        day["jobs"] += int(r.get("jobs") or 0)
        day["ads"] += int(r.get("ads") or 0)
        ft = by_feat.setdefault(f, {"feature": f, "revenue_bdt": 0.0, "cost_bdt": 0.0})
        ft["revenue_bdt"] += rev
        ft["cost_bdt"] += cost

    def p(x):
        return int(round(float(x) * 100))

    days = []
    for (_d, _f), v in sorted(by_day.items()):
        rev = v["ad_revenue_bdt"] + v["credit_revenue_bdt"]
        days.append({**{k: (round(x, 4) if isinstance(x, float) else x)
                        for k, x in v.items()},
                     "revenue": p(rev), "cost": p(v["cost_bdt"]),
                     "margin": p(rev - v["cost_bdt"])})
    feats = []
    for f in sorted(by_feat):
        v = by_feat[f]
        feats.append({"feature": f, "revenue": p(v["revenue_bdt"]),
                      "cost": p(v["cost_bdt"]),
                      "margin": p(v["revenue_bdt"] - v["cost_bdt"])})
    tot_rev = sum(v["revenue_bdt"] for v in by_feat.values())
    tot_cost = sum(v["cost_bdt"] for v in by_feat.values())
    return {"days": days, "features": feats,
            "totals": {"revenue": p(tot_rev), "cost": p(tot_cost),
                       "margin": p(tot_rev - tot_cost)}}
