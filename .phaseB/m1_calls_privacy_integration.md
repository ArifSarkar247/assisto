# Messenger M1 — Calls + Privacy — integrator TODO (agent a6712395, 61 tests, calls 9/10 privacy 10/10)
NEW backend/core/logic/circle_calls.py + circle_privacy.py (+ *_tests_snippets 24+37 pass). NEW app screens circle_call_screen.dart, circle_call_history_screen.dart, circle_privacy_screen.dart; widgets circle_call_controls.dart, circle_privacy_controls.dart.
ARB: apply .phaseB/m1_calls_privacy_arb.json (56 keys). Reused circleBackendPending/circleBlock/circleReport/close/save.
api.dart: circleCalls(), circlePlaceCall(id,kind), circleAnswerCall(id,kind), circleCallEvent(callId,event), circlePrivacy(), circleSetPrivacy(body), circleSetMemberControls(id,body).
MIGRATION (core): CallRecord(caller FK, callee FK, circle, kind voice/video, state, started_at, answered_at null, ended_at null, duration_sec, low_data). CirclePrivacy(1/user: visibility JSON, read_receipts bool T, typing bool T, call_policy char 'everyone', call_allow_ids JSON, call_allow_relations JSON, dnd_enabled bool, dnd_start '22:00', dnd_end '07:00', dnd_family_exception bool T). CircleMember += blocked, restricted, muted_until, pinned, chat_lock JSON, archived, video_unlocked(referral). Settings flags CIRCLE_PUSH_READY/CIRCLE_TURN_READY/CIRCLE_TURN.
## ENDPOINTS — MUST call the pure gates server-side (reviewer checks):
- POST /circle/<id>/call + /call/answer → circle_calls.can_place_call(caller,callee,kind) BEFORE WebRTC offer (THE video plan gate — client can't bypass kind='video'); upgrade_required→return no offer.
- POST /circle/calls/<id>/event → circle_calls.finalize_call(record,event); persist.
- signalling ring → circle_privacy.allow_call(owner_privacy,caller,now_local); ring only if ring=True; missed if log_missed.
- **CROSS-CUTTING for agent A message relay**: POST messages view MUST call circle_privacy.deliver_decision(sender,recipient) (inbox/notify/drop) + should_notify(mute). HAND TO A/integrator.
- GET /circle/members serializer → gate each last_seen/active_status/profile_photo/about/status via circle_privacy.can_see_field(owner,viewer,field) — never serialize hidden.
- read-receipt/typing broadcast → can_see_read_receipt / can_see_typing (reciprocal+restrict).
- GET/POST /circle/privacy; ice_config(turn_ready,turn) + transport_status(push_ready,turn_ready) in call payload/banner.
drawer/ChatNav: routes circle_privacy→CirclePrivacyScreen, circle_calls→CircleCallHistoryScreen (+synonyms); CircleCallScreen pushed imperatively. fake_api stubs per report (incl free-caller video {allowed:false,upgrade_required:true}). PENDING M1 reviewer.
