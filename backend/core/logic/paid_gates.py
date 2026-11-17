"""buyinside (owner order 10 Nov + add-on 00:52): the inventory of EVERY
feature a plan or credits unlock, and where its server gate lives. PURE.

The app's twin is app/lib/plans_v2/buy_inside.dart `kPaidFeatures` (the
in-place buy entry of each row). core/tests_buyinside.py fails when:
  * a key is here but not in the app list (no buy entry) or the other way,
  * an entitlements cap (core/logic/entitlements.CAPS) is missing here,
  * a backend file answers 402 (payment required) and is in no row's
    `files` and not in NOT_A_FEATURE_GATE — so a NEW paid gate can never
    ship without its buy entry.
owner_actions/PAID_FEATURES_BUY_BUTTONS_BN.md is the same list in Bangla.

unlock: premium | business | cctv | probashi | safe | credits
BACKGROUND rows have no screen of their own at the moment of the refusal
(automated SMS, the AI web search inside a chat turn, background call notes,
the seller agent's auto-replies): their buy entry is the feature's own
settings / chat screen listed in `entry_note` (the same credits sheet).
"""

PAID_GATES = {
    # ---- Premium
    "crm_write": {"unlock": "premium", "files": ["crm/plan_gate.py", "core/entitlements_service.py"]},
    "crm_contacts": {"unlock": "premium", "files": ["core/entitlements_service.py"]},
    "crm_followup_reminders": {"unlock": "premium", "files": ["crm/plan_gate.py"]},
    "shop_quote": {"unlock": "premium", "files": ["crm/plan_gate.py"]},
    "ledger_ai_addons": {"unlock": "premium", "files": ["core/business_views.py"]},
    "video_call": {"unlock": "premium", "files": ["core/views_c2_calls.py", "core/logic/circle_calls.py",
                                                  "core/views_group_calls.py"]},  # group-calls
    "call_link": {"unlock": "premium", "files": ["core/views_messenger.py"]},
    "chat_themes": {"unlock": "premium", "files": ["core/chat_decor.py"]},
    "ad_free": {"unlock": "premium", "files": ["core/sponsor_service.py"]},
    "storage": {"unlock": "premium", "files": ["core/views.py"]},
    "photo_ultra_hd": {"unlock": "premium", "files": ["core/logic/photo_studio.py"]},
    # ---- Business
    "automation": {"unlock": "business", "files": ["core/views_retention.py", "core/entitlements_service.py"]},
    "ai_sales_agent": {"unlock": "business", "files": ["core/views_bizagent.py", "core/bizagent_service.py"]},
    "business_ai_reply": {"unlock": "business", "files": ["core/business_views.py"]},
    "reports": {"unlock": "business", "files": ["core/business_views.py"]},
    "booking_bot": {"unlock": "business", "files": ["core/booking_views.py"]},
    "mkt_followup": {"unlock": "business", "files": ["core/mktengine_service.py"]},
    "shop_cctv_site": {"unlock": "business", "files": ["core/watchman_views.py"]},
    # ---- CCTV plan (Play subscription, 7-day free trial)
    "cctv": {"unlock": "cctv", "files": ["core/cctv_plan_views.py"]},
    "cctv_camera_cap": {"unlock": "cctv", "files": ["core/shop_views.py", "core/shop_ops_views.py"]},
    "cctv_phonecam": {"unlock": "cctv", "files": ["core/phonecam_views.py", "core/phonecam_clips_views.py"]},
    "cctv_relay": {"unlock": "cctv", "files": ["core/cctv_traffic_views.py"]},
    # ---- Probashi / Safe Family
    "probashi": {"unlock": "probashi", "files": ["core/views_probashi.py"]},
    "carecall_extra": {"unlock": "safe", "files": ["core/views_carecall.py"]},
    # ---- AI credits (the credits sheet inside the task)
    "ai_chat": {"unlock": "credits", "files": ["core/views_chat.py", "core/credits_out.py"]},
    "chat_photo": {"unlock": "credits", "files": ["core/chat_vision_service.py"]},
    "photo_studio": {"unlock": "credits", "files": ["core/photo_studio_service.py"]},
    "world": {"unlock": "credits", "files": ["core/world_service.py"]},
    "jobs": {"unlock": "credits", "files": ["core/jobs.py"]},
    "circle_assisto": {"unlock": "credits", "files": ["core/views_p3_circle.py"]},
    "agent_core": {"unlock": "credits", "files": ["core/ai.py"]},
    "vehicle": {"unlock": "credits", "files": ["core/views_vehicle.py"]},
    "voice_input": {"unlock": "credits", "files": ["core/voice_transcribe.py"]},
    "day_planner": {"unlock": "credits", "files": ["core/views_p2plan.py"]},
    "ielts": {"unlock": "credits", "files": ["core/ielts_views.py"]},
    "learn_roleplay": {"unlock": "credits", "files": ["core/learn_views.py"]},
    "crm_proposal": {"unlock": "credits", "files": ["crm/views.py"]},
    "bizai_winback": {"unlock": "credits", "files": ["core/views_bizai.py"]},
    "bizagent_send": {"unlock": "credits", "files": ["core/views_bizagent.py"]},
    "cctv_extra_pack": {"unlock": "credits", "files": ["core/cctv_traffic_views.py"]},
    "cctv_video_addon": {"unlock": "credits", "files": ["core/cctv_evidence.py"]},
}

# Charged in the background — no refusal screen of their own (see above).
BACKGROUND = {
    "ai_web_search": "ai_chat (the answer still comes, without the web part)",
    "callnote_understand": "notification channel settings -> credits sheet",
    "bizagent_auto_reply": "ai_sales_agent screen (seller agent) -> credits sheet",
    "sms_automated": "khata / retention / booking SMS wallet screens",
}

# Files that answer 402 but are NOT a paid feature of their own: the
# shared out-of-credits builder, the plan-gate machinery and SAFETY credits
# (safe plans / guardian / kids watch keep their own honest safety sheet —
# never a paywall on safety, owner rule).
NOT_A_FEATURE_GATE = {
    "core/credits_out.py": "the shared 402 body every credit feature uses",
    "core/entitlements_service.py": "the shared plan-gate builder",
    "core/safe_plans_views.py": "safety credits: own safety sheet, never a paywall",
    "core/views_guardian.py": "safety credits: own safety sheet, never a paywall",
    "core/kidswatch_views.py": "safety credits: own safety sheet, never a paywall",
    "core/callnote_views.py": "background (BACKGROUND callnote_understand)",
}


def gated_files():
    out = set(NOT_A_FEATURE_GATE)
    for row in PAID_GATES.values():
        out.update(row["files"])
    return out
