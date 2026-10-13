# Plans/Onboarding/Sidebar/Chat — integrator TODO (agent a32ccfc9)

Owned files in tree: app/lib/screens/plans_screen.dart (rebuilt), onboarding_screen.dart (rebuilt), app/lib/widgets/chatnav.dart (NEW route→widget map + detectRoute/push), app/lib/widgets/sidebar_sections.dart (NEW grouped config + filter). No backend model changes.

## ARB: apply .phaseB/plans_arb.json (45 keys). Placeholder @-metadata: plansChoose{name} (and existing aiCreditsCount{count}).

## api.dart add:
    Future<List<Map<String,dynamic>>> plansPublic() async {
      final r = await _c.get(AppConfig.api('/plans'), headers: _headers());
      if (r.statusCode == 200) return (jsonDecode(r.body) as List).cast<Map<String,dynamic>>();
      _fail(r);
    }

## Backend endpoints:
- GET /plans -> plans.plans_public(req_lang(request)) (JSON list; plans_public already exists in core/plans.py). Add APIView in views.py + path("plans", ...) in urls.py. No migration.
- AgentView.post final Response: add `"route": screen_synonyms.resolve(text)` so Bangla open-phrases ("আম্মুর ওষুধ দেখাও") navigate. (import core.screen_synonyms)

## app_drawer.dart (integrator-owned): replace flat modules with SidebarSections.all; add search TextField (_q) → SidebarSections.filter(t,_q); render ExpansionTile per section (expanded when searching) → ListTile per item (pop+push(item.builder)). Section→module map (in sidebar_sections.dart): Money[money,finance,subscriptions,vault] Family[family,emergency,nominee] Health[medicines→family,reminders] Life[notes,memory,watch,inbox,nearby] Work[agent_studio,guide,jobs,sources] Business[business,crm_contacts] Settings[plans,in_progress]. Keep Settings/Profile pinned footer.

## open-from-chat wiring (home_screen.dart / agent_thread_screen.dart send handler):
1. local = ChatNav.detectRoute(text) (English fast-path, needs open-verb+subject, won't hijack data entry) → if non-null ChatNav.push(context, local).
2. else api.agent(text) then `if (ChatNav.push(context, resp['route'])) {}` — backend route authoritative (only path for Bangla). Still render reply/cards when no route.

## fake_api: add plansPublic() stub (localized list mirroring plans_public); optionally add 'route' to agent() fake. (See agent report for body.)

## Self-grade: all advanced. PENDING plans reviewer.

## PLANS REVIEWER = GOOD → integrator fixes to reach advanced:
- Add @plansChoose placeholder metadata {name} when applying ARB (else codegen non-parameterized → compile fail). plans_screen uses t.plansChoose('<name>').
- chatnav 'plans' route: backend screen_synonyms 'plans' entry ADDED (done) → symmetry ok.
- plans_screen.dart:170 guard '${p['name'] ?? p['plan']}' → avoid literal "null".
- plans_screen.dart ~109-135 add empty state when /plans returns [] (success-but-empty).
- plans_screen current-plan match: _p?['plan'] vs card p['id'] — ensure /me/plan 'plan' == /plans 'id' (both are plan slugs; OK — verify at wire).
- onboarding_screen.dart:58 _open nav mount — verify onboarding is a gate (not pushed route) so opened screen lands on home shell.
