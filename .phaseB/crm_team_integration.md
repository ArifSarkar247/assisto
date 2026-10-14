# CRM gaps — TEAM (#8) · AUTOMATION (#11) · CAPTURE/dedupe (#1) integration

Pure logic (NO Django) lives in three new modules; the views layer feeds them
plain dicts (built from ORM rows) and persists what they return.

| module | purpose | tests (`run_all()`) |
|--------|---------|---------------------|
| `backend/crm/logic_team.py` | round-robin picker, territory/industry router, target progress, **config-driven commission engine**, leaderboard ranking | `logic_team_tests_snippets.py` → **5 groups** |
| `backend/crm/logic_automation.py` | owner rule model {trigger, condition, delay, action} + deterministic `due_actions(rules, events, now)` | `logic_automation_tests_snippets.py` → **7 groups** |
| `backend/crm/logic_capture.py` | dedupe matcher, **merge-plan that never drops an activity**, key-gated card-parse mock, web-form normalizer | `logic_capture_tests_snippets.py` → **7 groups** |

Run all three (no DB, no key, no network):
```
cd backend && python -c "from crm.logic_team_tests_snippets import run_all as a; \
from crm.logic_automation_tests_snippets import run_all as b; \
from crm.logic_capture_tests_snippets import run_all as c; a(); b(); c()"
```
→ 19 test groups pass.

**Guarantees asserted by the suites**
- Commission bakes NO numbers: with no/empty config → `config_set=False`,
  `payout="0.00"`, `note="OWNER_MUST_SET"`. Flat 5 % / marginal tiers / per-deal
  bonus are all fed in by the test (owner inputs), never hard-coded.
- Targets: no owner amount → `target_set=False`, `pct=None`, `note=OWNER_MUST_SET`.
- Merge plan: `activity_count_after == activity_count_before` (union of all
  duplicates' activities re-pointed onto the survivor; a loss trips a warning).
- Card OCR: no key → `{available:False, needs_key:True}`, extracts nothing from
  an image; only already-OCR'd / typed TEXT is structured into a draft.

---

## (A) Django models to ADD (all additive; nothing above in models.py changes)

Several already exist and are **reused** (do NOT recreate): `Target`,
`RoutingRule`, `Territory`, `CrmMember`, `Lead`, `Activity`, `Conversation`,
`Deal`, `Proposal`, `AuditEntry`.

### 1. `CommissionRule` (NEW) — owner-defined commission config, per org
```python
class CommissionRule(models.Model):
    org = models.OneToOneField(CrmOrg, on_delete=models.CASCADE,
                               related_name="commission_rule")
    # kind: "none" | "flat" | "tiered"  (NO default rate baked in)
    kind = models.CharField(max_length=10, default="none")
    flat_pct = models.DecimalField(max_digits=6, decimal_places=3, default=0)  # owner-set
    tiers = models.JSONField(default=list, blank=True)  # [{"upto":amount|null,"pct":n}]
    per_deal_bonus = models.DecimalField(max_digits=14, decimal_places=2, default=0)
    updated_by = models.ForeignKey(CrmMember, on_delete=models.SET_NULL,
                                   null=True, blank=True)
    updated_at = models.DateTimeField(auto_now=True)
```
The JSON shape maps 1:1 to `logic_team.commission(won, config)`. Owner-review:
the serializer must surface `config_set=False` when `kind=="none"` or the rate
is 0 so the app shows the "owner must set" state.

### 2. `AutomationRule` (NEW) — owner trigger→action rules (#11)
```python
class AutomationRule(models.Model):
    org = models.ForeignKey(CrmOrg, on_delete=models.CASCADE,
                            related_name="automation_rules")
    name = models.CharField(max_length=120, blank=True)
    trigger = models.CharField(max_length=24)          # logic_automation.KNOWN_TRIGGERS
    condition = models.JSONField(default=dict, blank=True)  # {"no_reply":true, ...}
    delay_days = models.PositiveSmallIntegerField(default=0)
    action = models.JSONField(default=dict)            # {"kind":..., "subject":...}
    active = models.BooleanField(default=True)
    created_by = models.ForeignKey(CrmMember, on_delete=models.SET_NULL,
                                   null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["id"]
        indexes = [models.Index(fields=["org", "active"])]
```

### 3. `AutomationFire` (NEW) — idempotency marker for fired actions
```python
class AutomationFire(models.Model):
    """One row per (rule, trigger-entity, due_at) the evaluator has acted on, so
    re-running due_actions() never double-creates a task. logic_automation is
    intentionally memoryless; this table is the memory."""
    rule = models.ForeignKey(AutomationRule, on_delete=models.CASCADE,
                             related_name="fires")
    entity_kind = models.CharField(max_length=8)   # "deal" | "lead"
    entity_id = models.PositiveIntegerField()
    due_at = models.DateTimeField()
    created_activity = models.ForeignKey(Activity, on_delete=models.SET_NULL,
                                         null=True, blank=True)
    fired_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = [("rule", "entity_kind", "entity_id", "due_at")]
```

### 4. `RoutingRule` — ADD two fields for the router + round-robin
- `match_region` CharField(max_length=120, blank, default="") — used by
  `logic_team.route_by_rules(region=...)`.
- Round-robin fallback needs a persisted cursor on the org:
  `CrmOrg.round_robin_cursor` IntegerField(default=0) — the view passes it to
  `logic_team.round_robin_pick(member_ids, cursor)` and saves the returned
  cursor. Deterministic, fair, no RNG.

### 5. `Target` — ADD (optional) `commission_paid` cache for audit
- `commission_paid` DecimalField(max_digits=14, decimal_places=2, default=0) —
  snapshot written when the owner finalises a period (computed via the engine,
  never invented).

---

## (B) Endpoints to ADD (DRF, mounted under the existing `api/v1/crm/` prefix)

All are org-scoped via the existing `_member_org_ids` / `_OrgScopedViewSet`
pattern; writes require owner/manager (targets, commission, routing, automation)
exactly like the existing `prices_reviewed` / approval gates.

### TEAM (#8)
| method · path | body / query | returns | logic |
|---|---|---|---|
| `GET  crm/targets/?org=&period=` | — | `[{id,member,member_name,period,target_amount,deals_target, won_amount,pct,attained,on_pace,target_set,note}]` | `logic_team.target_progress` per row |
| `POST crm/targets/` | `{org,member?,period,amount,deals_target}` | target | upsert on (org,member,period) |
| `GET  crm/leaderboard/?org=&period=` | — | `{rows:[{member_id,name,calls,meetings,proposals,deals_won,won_amount,score,rank}]}` | aggregate Activity counts → `logic_team.leaderboard` |
| `GET  crm/commission-config/?org=` | — | `{config:{kind,flat_pct,tiers,per_deal_bonus}, preview:[{member_name,won_amount,payout,config_set}]}` | `CommissionRule` + `logic_team.commission` preview per member |
| `POST crm/commission-config/` | `{org,config}` | config | owner/manager only; validate kind/rate |

Routing reuses the existing `crm/routing-rules/` + `crm/territories/`
ViewSets (now writable for owner/manager): `POST`/`PATCH` a `RoutingRule`. The
**lead-assignment path** (on lead create / capture) calls
`logic_team.route_by_rules(rules, …)`; if `assign_to is None` it falls back to
`logic_team.round_robin_pick(active_member_ids, org.round_robin_cursor)` and
persists the new cursor.

### AUTOMATION (#11)
| method · path | body | returns |
|---|---|---|
| `GET  crm/automation-rules/?org=` | — | `[{id,name,trigger,condition,delay_days,action,active}]` |
| `POST crm/automation-rules/` | `{org,name,trigger,condition,delay_days,action,active}` | rule (run `logic_automation.validate_rule` first; 400 on problems) |
| `PATCH crm/automation-rules/{id}/` | partial | rule |
| `POST crm/automation-rules/{id}/delete/` | — | `{ok:true}` |

**Evaluator job (server-side, e.g. a management command / cron):** build
`events` from the Activity + audit timeline, call
`logic_automation.due_actions(active_rules, events, now=timezone.now())`, and for
each returned action that has no matching `AutomationFire` row: create the
Activity (task/followup draft/notification) and write the `AutomationFire`
marker. Consistent with the existing "cadence drafts, human approves, nothing
auto-sends" rule — actions are create-task / draft / notify only.

### CAPTURE / dedupe (#1)
| method · path | body / query | returns | logic |
|---|---|---|---|
| `POST crm/capture/card` | `{org,text}` | `{available,needs_key,draft,found,duplicate_of:[ids]}` | `logic_capture.card_parse(text, has_ocr_key=bool(OCR key))` then `is_duplicate_of` against org leads |
| `POST crm/capture/form` | `{org,payload:{...}}` | `{draft,unmapped}` | `logic_capture.form_intake(payload)` |
| `GET  crm/capture/duplicates/?org=` | — | `{groups:[{match_on,lead_ids}], leads:[{id,name,company,phone,email}]}` | `logic_capture.find_duplicates(org_lead_dicts)` (or reuse `dupes.find_lead_duplicates`) |
| `POST crm/capture/merge_preview` | `{org,survivor,duplicates:[ids]}` | the merge PLAN incl. `activity_count_before/after`, `reassign`, `backfill`, `warnings` | `logic_capture.merge_plan(survivor, dups)` — **no DB write** |
| `POST crm/capture/merge` | `{org,survivor,duplicates:[ids]}` | `{ok,survivor}` | validate plan (before==after) then reuse existing `dupes.merge_leads(survivor, dups, org)` which re-points conversations/activities/deals/proposals and deletes dups |

OCR is KEY-GATED: the view sets `has_ocr_key = bool(settings.OCR_API_KEY or
org key)`. With no key, `card_parse` returns `needs_key=True`, invents nothing,
and the app lets the user type the card text (still parsed into a draft). The
new-lead save path (card/form) runs the same dedupe check as any create.

---

## (C) Flutter — screens & widgets added (all NEW files)

Screens (`app/lib/screens/crm/`):
- `crm_team_advanced_screen.dart` — 4 tabs: Targets · Leaderboard · Commission · Routing.
- `crm_automation_screen.dart` — rule list + plain-language "WHEN…IF…THEN…" cards.
- `crm_capture_screen.dart` — 3 tabs: Scan card · Import form · Dedupe.
- `crm_advanced_api.dart` — thin wrapper over the existing public `ApiClient`
  helpers for the new endpoints (no change to `api.dart`).

Widgets (`app/lib/widgets/crm_*`):
- `crm_target_editor.dart`, `crm_commission_config.dart`, `crm_leaderboard_list.dart`,
  `crm_routing_editor.dart` (team)
- `crm_rule_builder.dart` (automation)
- `crm_card_scan.dart`, `crm_form_import.dart`, `crm_dedupe_review.dart` (capture)

Wiring note: add entries for these three screens to the CRM navigation
(`crm_home_screen.dart` drawer/sections) passing the current `org` id.

**Localization:** every string goes through `AppLocalizations`. New keys emitted
to `.phaseB/crm_team_arb.json` → **115 keys**, each `{key:[bn,en]}` camelCase.
Zero Bangla in any `.dart` (only the ৳ sign, which is allowed). Merge the ARB
into `app_bn.arb` / `app_en.arb` (not done here per constraints).

---

## (D) Benchmark vs. best-in-class B2B CRM

- **Team (HubSpot/Salesforce/Zoho):** quota/target tracking w/ pace → ✅
  (`target_progress`); rep leaderboard → ✅ (`leaderboard`, dense ranks + ties);
  commission plans flat/tiered/bonus → ✅ (`commission`, but **owner-review,
  no baked numbers**, unlike vendors who ship sample plans); territory +
  round-robin assignment → ✅ (`route_by_rules` + `round_robin_pick`).
- **Workflow automation (HubSpot Workflows / Zoho Blueprint):** owner-built
  trigger→condition→delay→action rules → ✅ (`due_actions`), with the deliberate
  safety line that nothing auto-sends to a customer (draft/task/notify only).
- **Lead capture (Salesforce Web-to-Lead, card scanners):** web-form intake → ✅
  (`form_intake`, unmapped fields surfaced); business-card scan → ✅ key-gated
  honest mock; duplicate detection + merge with no-loss guarantee → ✅
  (`merge_plan`), which is stronger than many vendors who silently drop
  activity history on merge.
```
