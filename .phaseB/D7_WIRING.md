# D7 integrate checklist (do at combined merge)
- [x] referral ARB merged (34 keys, en=bn=5202)
- [ ] WIRE: GET /referral/balance → return referral.advanced_summary(...) (superset; screen degrades to basic if absent). File: backend/core views for referral; logic in core/logic/referral.py. Register referral_tests_snippets 24 tests.
- [ ] social (a1f6ce): merge up_social_arb.json; wire agent_studio_screen socialTitle etc; register tests
- [ ] admin (aa97a1): copy up_admin_arb.json K-entries + PARAMS into .phaseB/merge_arb.py K dict (2 parameterized keys) then run; wire admin_moderation_screen msgrMod*; register tests
- [ ] integrations (a0cea7): web-only, DONE — no ARB. registry 21→28. verify IntegrationsStoreTests still green.
- [ ] #177 admin-analytics: verify-or-drop (owner-analytics shipped build 75)
