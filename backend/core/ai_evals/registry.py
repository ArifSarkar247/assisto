"""
Inventory of every AI feature (owner order G) and how it is evaluated.

kind "llm"  — the answer comes from a model through core.ai.generate (or the
              vision provider). CI replays RECORDED outputs through the
              product's own prompt builder + post-processing + guards, then
              grades deterministically. A live run (owner, with keys and a
              budget) calls the real router.
kind "rule" — deterministic code (no model). CI checks exact expected outputs;
              these must pass (known gaps are listed per case and may not grow).

`router_feature` / `tier` are what the product passes to ai.generate();
model_class() derives MAIN / CHEAP exactly the way the router does.
"""
from .. import ai_config as C

LLM, RULE = "llm", "rule"

FEATURES = [
    # ------------------------------------------------------------- model features
    dict(id="home_chat", kind=LLM, router_feature="chat", tier="cheap",
         title_bn="হোম Assisto চ্যাট + মেমরি", call_site="core/views_chat.py _produce_reply()"),
    dict(id="agent_qa", kind=LLM, router_feature="agent_qa", tier="cheap",
         title_bn="হোম এজেন্টের প্রশ্নের উত্তর (নিজের তথ্য থেকে)", call_site="core/views.py AgentView (intent=question)"),
    dict(id="chat_vision", kind=LLM, router_feature="chat_vision", tier="vision",
         title_bn="ছবি দেখে উত্তর (ওষুধ/বিল/ফসল/প্রেসক্রিপশন)", call_site="core/chat_vision_service.py answer()"),
    dict(id="bizagent_reply", kind=LLM, router_feature="bizagent.reply", tier="cheap",
         title_bn="AI সেলস অ্যাসিস্ট্যান্ট — গ্রাহকের ফ্রি প্রশ্নের উত্তর", call_site="core/bizagent_service.py _llm_draft()"),
    dict(id="business_reply", kind=LLM, router_feature="business.reply", tier="cheap",
         title_bn="ব্যবসার অটো-রিপ্লাই (ক্যাটালগ থেকে)", call_site="core/business.py reply_for()"),
    dict(id="business_ai_reply", kind=LLM, router_feature="business.ai_reply", tier="cheap",
         title_bn="ব্যবসার AI ড্রাফট রিপ্লাই", call_site="core/business_views.py _llm_provider()"),
    dict(id="world_web_answer", kind=LLM, router_feature="world_web_answer", tier="cheap",
         title_bn="World — যেকোনো প্রশ্ন (ওয়েব সূত্রসহ)", call_site="core/world_service.py web_answer()"),
    dict(id="world_hub", kind=LLM, router_feature="world_<hub>", tier="cheap",
         title_bn="World হাব AI সাহায্য (প্রবাসী/ছাত্র/কৃষক/সরকারি)", call_site="core/world_service.py hub_ai()"),
    dict(id="circle_assisto", kind=LLM, router_feature="circle_assisto_<action>", tier="cheap",
         title_bn="My Circle @Assisto (জিজ্ঞাসা/সারাংশ/অনুবাদ)", call_site="core/views_p3_circle.py AssistoRunView"),
    dict(id="group_ai", kind=LLM, router_feature="group_ai_<task>", tier="cheap",
         title_bn="গ্রুপ চ্যাট সারাংশ/অনুবাদ/রিমাইন্ডার", call_site="core/views_m1_messenger.py GroupAiView"),
    dict(id="jobs_cv", kind=LLM, router_feature="jobs.cv / jobs.cover", tier="medium",
         title_bn="CV ও কভার লেটার", call_site="core/jobs.py tailor_documents()"),
    dict(id="studio", kind=LLM, router_feature="studio.<kind>", tier="medium",
         title_bn="AI টুলস স্টুডিও (চিঠি/ক্যাপশন/ইমেইল/এক্সেল)", call_site="core/views.py AgentStudioView"),
    dict(id="bill_guide", kind=LLM, router_feature="bill_guide", tier="cheap",
         title_bn="বিল পড়া (JSON)", call_site="core/bills.py parse_bill()"),
    dict(id="briefing", kind=LLM, router_feature="briefing / briefing.batch", tier="cheap",
         title_bn="দৈনিক সকালের ব্রিফিং", call_site="core/views.py _briefing_payload + generate_briefings"),
    dict(id="vehicle_summary", kind=LLM, router_feature="vehicle_summary", tier="cheap",
         title_bn="গাড়ির অস্বাভাবিক ট্রিপের সারাংশ", call_site="core/views_vehicle.py"),
    # ------------------------------------------------------------- rule features
    dict(id="reminders_nlp", kind=RULE, router_feature="", tier="",
         title_bn="রিমাইন্ডারের তারিখ/সময় বোঝা (বাংলা NLP)", call_site="core/logic/nlp_datetime.py parse()"),
    dict(id="home_intent", kind=RULE, router_feature="", tier="",
         title_bn="হোম চ্যাট/ভয়েস ইনটেন্ট (খরচ/আয়/ধার/রিমাইন্ডার/কল)", call_site="core/agent.py parse()"),
    dict(id="expense_parse", kind=RULE, router_feature="", tier="",
         title_bn="মুখে বলা খরচ/আয় বোঝা", call_site="core/logic/money_parse.py parse_money_voice()"),
    dict(id="money_sms", kind=RULE, router_feature="", tier="",
         title_bn="বিকাশ/নগদ/ব্যাংক SMS থেকে লেনদেন", call_site="core/logic/money_parse.py parse_sms()"),
    dict(id="voice_commands", kind=RULE, router_feature="", tier="",
         title_bn="ভয়েস কমান্ড", call_site="core/logic/voice_commands.py map_command()"),
    dict(id="bizagent_rules", kind=RULE, router_feature="", tier="",
         title_bn="সেলস অ্যাসিস্ট্যান্ট নিয়ম-উত্তর (দাম/স্টক/ডেলিভারি)", call_site="core/logic/bizagent_rules.py answer()"),
    dict(id="bargaining", kind=RULE, router_feature="", tier="",
         title_bn="দর-কষাকষি (সর্বনিম্ন দাম কোডে)", call_site="core/logic/business_ai.py negotiate() + bizagent.find_offer()"),
    dict(id="order_capture", kind=RULE, router_feature="", tier="",
         title_bn="চ্যাট থেকে অর্ডার নেওয়া", call_site="core/logic/bizagent.py extract_order()"),
    dict(id="contract_analyzer", kind=RULE, router_feature="", tier="",
         title_bn="চুক্তি বিশ্লেষণ (ঝুঁকির ধারা)", call_site="core/logic/contract_analyzer.py analyze()"),
    dict(id="crm_extract", kind=RULE, router_feature="", tier="",
         title_bn="CRM — পেস্ট থেকে যোগাযোগ বের করা", call_site="crm/views.py extract_contact()"),
    # AF-2 / AF-4 / AF-10 (Agentforce trust parity, 28 Oct)
    dict(id="sales_pii_mask", kind=RULE, router_feature="", tier="",
         title_bn="সেলস এজেন্ট — AI-কে পাঠানোর আগে ফোন/NID/অ্যাকাউন্ট/ইমেইল লুকানো",
         call_site="core/ai.py mask_for_provider() (bizagent_service._llm_draft pii=True)"),
    dict(id="toxicity", kind=RULE, router_feature="", tier="",
         title_bn="গালি / হুমকি / ঘৃণা / যৌন হয়রানি শনাক্ত (বাংলা, Banglish, English)",
         call_site="core/ai_guard.py toxicity()"),
    dict(id="handoff_card", kind=RULE, router_feature="", tier="",
         title_bn="বিক্রেতার কাছে হস্তান্তরের সারাংশ কার্ড",
         call_site="core/logic/bizagent_handoff.py build()"),
]

BY_ID = {f["id"]: f for f in FEATURES}
MIN_CASES = 200


def model_class(feature, cfg=None):
    """MAIN | CHEAP | VISION | RULE, the way the router decides it."""
    if feature["kind"] == RULE:
        return "rule"
    if feature["tier"] == "vision":
        return "vision"
    name = feature["router_feature"].split(" ")[0].replace("<action>", "ask") \
        .replace("<task>", "summarise").replace("<hub>", "expat").replace("<kind>", "letter")
    return C.task_class(feature["tier"], name, cfg or C.normalize({}))


def model_class_for_case(feature, case, cfg=None):
    """Per-case class (circle @Assisto 'ask' is MAIN, summarise is CHEAP)."""
    if feature["kind"] == RULE or feature["tier"] == "vision":
        return model_class(feature, cfg)
    from .llm_specs import router_feature_for
    return C.task_class(feature["tier"], router_feature_for(feature["id"], case),
                        cfg or C.normalize({}))
