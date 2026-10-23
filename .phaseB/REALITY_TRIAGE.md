# Reality triage (rt1): every C and D flow of run 39859999833

Source run: `reality.yml` run **39859999833** on `agent/qa1` (31 flows: A=9, C=18, D=4).
Evidence: artifact `reality-evidence` of that run (`shots/*.png`, `live_logcat.txt`, `django.log`, `drive.log`).
Each verdict below comes from the flow's REALITY_RESULT JSON (steps + every HTTP call), its screenshots and the drive log.

Classes:
- **a**: real app bug
- **b**: UX gap
- **c**: stale flow step (the test expected an old UI)
- **d**: CI or emulator artifact

Re-runs on `agent/rt1`: **39878171841** (all groups) and **39884806316** (start, personal, family, business, docs). Results are at the bottom.

## Triage table

| flow | was | class | evidence (run 39859999833) | root cause | fix (branch `agent/rt1`) |
|---|---|---|---|---|---|
| 04_home_chat | C | **a** | `04_home_chat_02_after-send.png`: the field is empty, there is no bubble and no `POST /agent`. The HTTP log shows home-defaults, discover/cards and alerts re-fetched (the New-chat signature). | The home **New chat FAB** (`endFloat`) sat exactly on top of the input bar's **Send** button. Once the input had focus the FAB appeared, so tapping Send started a NEW chat and dropped the typed message. | `home_screen.dart`: the same FAB, lifted above the input bar (`_AboveInputBarFab`). This is the only home change and the layout is otherwise untouched. Run 2: **B** (honest no-AI-key reply). |
| 05_home_restore | C | a (follows 04) | `05_home_restore_02_FAILED.png` | Nothing was ever sent (04). | Fixed by 04. Run 2: **A**. |
| 06_sidebar_history | C | **c** | `06_sidebar_history_01_drawer.png`: the drawer has no history list. | History moved to drawer → "Assisto AI" (the chats page). | The flow now goes drawer → Assisto AI and checks `GET /chat/sessions`, the row, and that tapping it reopens on home. Run 2: **A**. |
| 07_quick_buttons | C | **c** | `07_quick_buttons_02_changed.png` / `_03_FAILED.png`: the same 6 shortcuts, reordered. | The step unchecked "Reminders" and then re-checked the first free box, which was Reminders itself. | Check a different free shortcut. Run 2: **A**. |
| 08_reminders | C | **a** (already fixed) | `POST /reminders/ 400` | `recurrence_rule: null` was rejected (fixed on main in faa15f3 before this branch). | None needed. Run 2: **A** (quick-add and form both reach the server). |
| 09_notes | C | **b** + c | `09_notes_02_FAILED.png`: the drawer search for "Notes/Tasks" shows only "Reminders & Memory" and "Work". | **UX gap:** a search that narrows a group to ONE hit rendered the GROUP name, not the item found. Also, the harness `find.text(label)` matched the search box's own text and "tapped" it. | `app_drawer.dart`: one-hit groups show the item (its icon and name, with the group as subtitle). The harness only taps drawer **rows**. Run 2 found a second harness bug: `ensureVisible` on the Notes FAB scrolled the TabBarView towards To-Do (`09_notes_03_FAILED.png`, run 2). Now an on-screen target is never scrolled. |
| 10_todos | C | b (follows 09) | `10_todos_01_FAILED.png` | Same drawer search. | Fixed by 09. Run 2: **A**. |
| 11_money | C | **c** + **a** | `11_money_02_FAILED.png`: Money opens on Summary, which has no FAB. | Adding now lives on the Transaction tab. Run 2 also showed a real bug: `MoneyScreen.initState → repo.sync() → notifyListeners` = "markNeedsBuild() called during build" (drive.log, flutter_test `[E]`). | The flow taps the Transaction tab. `money_screen.dart` and `money_budget_screen.dart` start their sync after the first frame. The harness now FAILS a flow on any Flutter framework error (before this, the flow passed while flutter_test printed `[E]`). |
| 12_budget | C | b (follows 09) | `12_budget_02_FAILED.png` | Same drawer search ("Budget" → shown as "Account & Finance"). | Fixed by 09. Run 2: did not run (the emulator died, see d). |
| 13_family | C | **c** | `13_family_02_FAILED.png`: Family Care opens on "Today's medicines". | The members list is the "Family" tab. | The flow taps that tab. Run 2: **A** (seeded "Ammu" shown). |
| 14_sos_countdown | C | b (follows 09) | `14_sos_countdown_01_emergency.png`: the search shows only "Family & Safety". | Same drawer search. | Fixed by 09. Run 2: **A** (countdown, then Cancel, nothing sent). |
| 15_circle_message | C | **d** | `15_circle_message_02_chat.png`: "Update Assisto to use My Circle". | The CI test APK was **build 1** (`pubspec 1.0.0+1`), below My Circle's minimum version (183). | `reality.yml` sets version `1.0.(9000+run)` before building. Run 2: **A** (E2E both ways). |
| 16_circle_call | C | **d** + c | `16_circle_call_02_FAILED.png`: "Couldn't reach Assisto". django.log: `POST /circle/1/call 500, sqlite3.OperationalError: database is locked`. | The throw-away backend used a sqlite file under the threaded dev server. The failed-call screen has a Close button, not a back arrow. | `reality.yml` now runs a **Postgres service container** (production's engine). `settings_ci` falls back to sqlite with WAL + IMMEDIATE. The flow taps Close and asserts no 5xx. Run 2: **B** (call screen opens and ends; TURN and a second phone are needed for media). |
| 17_circle_add_whatsapp | C | a (follows 04) | `17_circle_add_whatsapp_01_FAILED.png`: home, nothing sent. | "circle" typed in the home chat; Send hit the New-chat FAB. | Fixed by 04. Run 2: the first step passed (`17_..._01_chat-circle-opens-add.png`), then the emulator died. |
| 19_circle_ticks | C | **d** | `19_circle_ticks_04_FAILED.png`: the "Update Assisto to use My Circle" banner. Typing and online are gated for old builds. | Build 1 (see 15). | Fixed by the version. Run 2: did not run (emulator died). |
| 18_circle_real_call | C | **d** | `django.log`: A polls `rt/events?after=46` and gets nothing. The B→A call returned 201, but `call.incoming` was never queued for A. | `rt_publish()` and `touch_presence()` swallow DB errors. Under sqlite "database is locked" the event write was lost. | Postgres (see 16). The flow now reports B's phase and end reason on failure. Run 2: did not run (emulator died). |
| 21_documents | C | **c** | `21_documents_01_vault.png`: "Set a PIN for your documents". | The vault is PIN-locked now. | The flow sets the PIN, or enters it on a later open. Run 2: **A**. |
| 22_voice_screen | A (false) | **c** (false pass) | `22_voice_screen_01_voice.png` (run 1): the drawer search, not the voice screen. The flow passed with "no Type-instead button". | The step returned quietly when the button was missing. Run 2 (`22_voice_screen_01_voice.png`): the first open shows the microphone-reason dialog, and the tap only dismissed it. | "Type instead" is now REQUIRED. The flow answers the mic dialog "Not now" first. |
| 23_settings_language | C | **c** | `23_settings_language_03_FAILED.png`: About is below the fold. | The lazily built last row was never scrolled to. | Scroll to About, open it, and assert the app version text. Run 2: **A**. |
| 17_pos_sale_void | D | **d**, then **a** + c | Run 1: emulator died ("Service has disappeared"). Run 2: `17_pos_sale_void_03_in-cart.png` shows the variant sheet open and no `POST /business/cart/add`. Run 3 (39884806316) drive.log: `_TypeError: type 'Null' is not a subtype of type 'int'` at `_VariantPicker` (`quick_sell_screen.dart`). | **Real bug: Quick Sell could not add ANY product to the cart.** Every product has at least its base variant, so the picker always opened. Tapping a variant cast `v['id'] as int`, but variants have a string `key` and no id, so it threw. The client also posted `variant` while the server reads `variant_key`. Also, the product card showed **৳0** (the price lives on the variants). | `quick_sell_screen.dart`: a one-variant product goes straight into the cart, and the picker returns the variant **key**. `business_selling_api.dart` sends `variant_key`. The card shows the lowest variant price. New test `test/rt1_cart_variant_test.dart`. The flow waits for the sheet. **Not CI-proven yet (CI budget used).** |
| 18_khata / 19_crm_lead / 20_shop_box | D | **d** | drive.log: "Service has disappeared", `emulator_restart.log`. | The hosted swiftshader emulator dies a few minutes after a (re)boot. | `run_flows.sh` restarts a dead emulator and gives the group ONE retry. Still D in run 2: the retries also died. |

### Also found (not fixed here)
- A failed call placement that gets an HTTP **500** shows "Couldn't reach Assisto. Please check your internet" (`CallEndReason.network`). This blames the user's internet for a server error. `call_controller.dart` keeps no ApiException status. Follow-up: map a 5xx to `circleCallServerBusy`.
- `rt_publish()` / `touch_presence()` / `publish_state()` swallow every DB error. On production Postgres this should not lock, but a lost `call.incoming` is silent. Follow-up: log it.

## CI runs (agent/rt1)

| run | scope | result |
|---|---|---|
| 39876993060 | all | Infrastructure only: `seed_reality` refused Postgres (sqlite-only guard). It is now allowed only inside GitHub Actions, on the settings_ci DB on localhost. |
| 39878171841 | all | **A=19, B=2, C=3, D=7** (was A=9, C=18, D=4). C: 09_notes (harness scroll), 17_pos (variant sheet), 22_voice (mic dialog). D: the emulator died in personal, family and business, and again on each retry. |
| 39884806316 | start, personal, family, business, docs | **A=12, B=1, C=1, D=12** (11 of the D rows are home and sweep, which were not selected). Newly A: 09_notes, 22_voice_screen, plus 13, 14, 15, 21 and 23 again. C: 17_pos (the real cart bug above, fixed after this run). D: the emulator died in personal (both attempts during 11_money), family (17_circle_add / 13) and business (18_khata). |

## Final state (best evidence per flow, runs 39878171841 + 39884806316)

- **A (15 + sweep):** 01_language, 02_login, 03_onboarding, 05_home_restore, 06_sidebar_history, 07_quick_buttons, 08_reminders, 09_notes, 10_todos, 13_family, 14_sos_countdown, 15_circle_message, 21_documents, 22_voice_screen, 23_settings_language, plus sweep S001-S005.
- **B (2):** 04_home_chat (honest "needs the AI key" reply), 16_circle_call (screen opens and ends; TURN and a second phone are needed for media).
- **Steps passed, not counted as A:** 11_money. In run 2 the expense reached the server, but flutter_test logged the "markNeedsBuild during build" error. That is fixed, and the harness now fails on such errors, but the flow has not been re-run (the emulator died both times in run 3).
- **C (1):** 17_pos_sale_void. The root cause (the cart bug) is fixed and unit-tested, but not re-run on the emulator.
- **D (emulator died, no verdict):** 12_budget, 17_circle_add_whatsapp (its first step passed in run 2), 19_circle_ticks, 18_circle_real_call, 18_khata, 19_crm_lead, 20_shop_box.

### Why D is still D
The hosted API-33 swiftshader emulator exits a few minutes after every (re)boot ("Service has disappeared", `Failed to find ColorBuffer` in `emulator_restart.log`). In run 3 both personal attempts died during 11_money. One retry per group (now in `run_flows.sh`) was not enough. Next steps, in this order:
1. Run each flow group as its own job, so every group gets a fresh runner and emulator.
2. Build the test APK once and use `flutter drive --use-application-binary`. Today every group rebuilds with Gradle while the emulator runs.
3. Try `-gpu guest` or `-gpu host` instead of `swiftshader_indirect`.

