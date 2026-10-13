# ROUND-2 BATCHED INTEGRATION — ordered recipe (integrator)

Modules in tree (all reviewer-passed/advanced except CRM pending review aa94987):
plans/onboarding/sidebar/chat, vault/scam/safety, reminders/memory, CRM in-app.

## DONE
- [x] ARB merged → 874 balanced keys (CRM 122 + plans 45 + vault/scam/safety 76 + reminders 45 + base), placeholder @-meta auto-added, gen-l10n clean.

## TODO (order; one heavy job at a time; DB backup before migrations; cleanup after build)
1. **api.dart methods** (CRM uses CrmApi wrapper over generic getJson/postJson/listItems → NO api.dart change needed for CRM). Add:
   - plans: `plansPublic()` GET /plans (see .phaseB/plans_integration.md)
   - reminders: `parseReminder(text)` POST /reminders/parse, `searchMemoryApi(q)` GET /memory/search?q=
   - vault/scam/safety: fold widgets/scam_safety_api.dart extension OR add: scamDetect/scamLibrary/scamReportFamily/govtGuides/safetyCheckinStart/safetyCheckinArrived/createDocumentWithDetails/uploadDocumentWithDetails (see .phaseB/vault_scam_safety_integration.md). (The extension already compiles via public surface — can leave as extension.)
2. **backend models** (core): Reminder += recurrence_rule(JSON dict), date_only(Bool), link(JSON dict); Document += details(JSONField dict); + ReminderSerializer/DocumentSerializer fields. Document serializer: accept `details` as JSON object (body) AND json-encoded string (multipart upload) → json.loads. Optional SafetyCheckin model (user,place,eta,arrived,created_at).
   **crm**: Lead += phones(JSON list), whatsapp, designation, required_modules(JSON list), budget_range, timeline, decision_maker, notes(Text), next_follow_up(Date null) — all nullable/defaulted. (CRM serializers/views/urls already added by agent.)
3. **backend endpoints** (core/views.py + urls.py): POST /reminders/parse (nlp_datetime.parse); GET /memory/search (reminders_engine.search_memory); rewire ScamCheckView→core.logic.scam.check_message(msg,lang) [new contract adds patterns/summary]; GET /scam/library; POST /scam/report; POST /safety/checkin + /safety/checkin/arrived; GET /plans→plans.plans_public(req_lang); AgentView.post add `"route": screen_synonyms.resolve(text)`. (CRM endpoints already in crm/urls.py under /api/crm/ — already mounted.) Plans screen fixes: guard '${p['name'] ?? p['plan']}' "null", empty-state when /plans==[], @plansChoose{name} meta (DONE in ARB merge).
4. **app_drawer.dart** (grouped sidebar, integrator-owned): implement SidebarSections.all + search (see .phaseB/plans_integration.md sidebar spec). Business section: Contacts (t.contactsTitle, CrmContactsScreen) + Sales CRM (t.crmTitle, CrmHomeScreen, import screens/crm/crm_home_screen.dart). Health: add scam→? Life: safety_screen. Add scam_screen + safety_screen somewhere sensible (Family/Health). Repoint old t.crmContacts → t.contactsTitle.
5. **open-from-chat** (home_screen.dart/agent_thread_screen.dart): ChatNav.detectRoute local + resp['route'] from backend (see plans spec). Route map incl crm→CrmHomeScreen.
6. **fake_api.dart**: CRM fakes DONE by agent. Add plans plansPublic() + reminders (recurrence_rule/date_only/link rows) + vault/scam/safety stubs (scamDetect/scamLibrary/govtGuides/safetyCheckin*) — see per-module specs. (reminders case already partly extended.)
7. **DB BACKUP** → `makemigrations core` + `makemigrations crm` → migrate. (2 migrations.)
8. **gen-l10n** (if ARB touched) → **flutter analyze** (fix to 0) → **lang gate CLEAN** → **backend tests** (manage.py test — core+crm; add reminders_golden_test.dart Dart test loading reminders_golden.json for parity; crm scenario crm_scenario --cleanup).
9. Apply recorded reviewer fixes already in specs (plans P2/P3). Address CRM reviewer (aa94987) gaps when it returns.
10. **Build + ship APK** (flip public→push→build→flip private→publish-apk.sh→cleanup). Re-render gallery (now incl crm_today/leads/pipeline/dashboard/team + advanced reminders/vault) both langs; republish.
11. Deploy backend (restart assisto.service; 12-tenant Asalify check). Update report. Then module 5 (P13+).
