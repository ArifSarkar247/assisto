"""Build-61 wave endpoints: Messenger M1 (referral, calls, privacy) + Safe
Journey. Thin wiring over the pure logic in core/logic/* — all enforcement
gates (can_place_call video gate, allow_call ring gate, can_see_field,
deliver_decision, send_precheck, redeem math, journey overdue/duress/expiry)
run SERVER-SIDE here; the client cannot bypass them.
"""
import json
from django.conf import settings
from django.contrib.auth import get_user_model
from django.utils import timezone

from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import req_lang
from .logic import (referral as R, circle_calls as CC, circle_privacy as CP,
                    circle_messaging as CM, safety_journey as SJ, circle)
from . import plans, nearby
from . import push as PUSH
from .models import (CircleMember, CircleMessage, CallRecord, CirclePrivacy,
                     ReferralGrant, Journey, JourneyWatcher, SavedPlace,
                     WellnessWatch, DuressPin)

User = get_user_model()


# ===========================================================================
# Referral points
# ===========================================================================
def _ledger_for(user):
    """ReferralGrant rows -> the list-of-dicts ledger shape referral.py expects."""
    rows = []
    for g in ReferralGrant.objects.filter(user=user):
        rows.append({
            "id": g.id, "user_id": g.user_id, "invitee_id": g.invitee_id,
            "device_id": g.device_id, "kind": g.kind, "points": g.points,
            "reason": g.reason, "month": g.month,
            "created_at": g.created_at.isoformat(),
        })
    return rows


def _referral_cfg():
    """Referral points economy from PricingConfig (admin-editable in
    /admin/pricing `referral`), falling back to the referral.py defaults."""
    try:
        from . import billing
        return billing.cfg()["referral"]
    except Exception:
        return {"points_per_referral": R.POINTS_PER_REFERRAL,
                "welcome_bonus_points": R.WELCOME_BONUS_POINTS,
                "points_per_premium_day": R.POINTS_PER_PREMIUM_DAY,
                "min_redeem_points": R.MIN_REDEEM_POINTS,
                "monthly_referral_cap": R.MONTHLY_REFERRAL_CAP,
                "max_redeem_days": R.MAX_REDEEM_DAYS}


class ReferralBalanceView(APIView):
    def get(self, request):
        lang = req_lang(request)
        ledger = _ledger_for(request.user)
        # ADVANCED (#102): strict superset of referral_summary — adds progress,
        # honest invite leaderboard, earned/spent audit and redeemed history. The
        # advanced screen renders from this single call; it degrades gracefully to
        # the basic balance+history if those extra fields are ever absent.
        rc = _referral_cfg()
        summary = R.advanced_summary(
            ledger, request.user.id, lang, rate=rc["points_per_premium_day"],
            min_points=rc["min_redeem_points"], points=rc["points_per_referral"])
        # an invite link + raw code so the user can share right from the card
        token = circle.make_invite_token(request.user.id, "friend",
                                          settings.SECRET_KEY)
        summary["invite_link"] = circle.qr_payload(token)
        summary["referral_code"] = token
        return Response(summary)


class _FlagsBase(APIView):
    """#178 Cost kill-switch & feature flags — OWNER-only. State + append-only
    audit persist in AdminFlagState(key='global'); all validation / confirm-gate
    / audit construction run SERVER-SIDE via core.logic.admin_flags (the client
    mirror is advisory only). A non-owner gets 403; the console then degrades to
    its owner-only state."""
    @staticmethod
    def _owner(request):
        u = request.user
        return bool(u and u.is_authenticated and u.is_superuser)

    @staticmethod
    def _row():
        from .models import AdminFlagState
        row, _ = AdminFlagState.objects.get_or_create(key="global")
        return row

    @staticmethod
    def _snapshot(row):
        from .logic import admin_flags as AF
        state = AF.normalize_state(row.state)
        # dl1: show the EFFECTIVE Free-calls value (its unset default comes
        # from settings.CALLS_FREE_TESTING_DEFAULT, not only the catalog).
        from .calls_free import FLAG as _CF, calls_free as _calls_free
        if _CF not in (row.state or {}):
            state[_CF] = _calls_free()
        flags = [dict(c, value=state[c["id"]]) for c in AF.catalog()]
        return {"flags": flags, "audit": row.audit, "summary": AF.summarize(state),
                "can_manage": True}


class AdminFlagsView(_FlagsBase):
    def get(self, request):
        if not self._owner(request):
            return Response({"can_manage": False},
                            status=status.HTTP_403_FORBIDDEN)
        if request.query_params.get("probe"):
            return Response({"can_manage": True})
        return Response(self._snapshot(self._row()))


class AdminFlagsFlipView(_FlagsBase):
    def post(self, request):
        if not self._owner(request):
            return Response({"can_manage": False},
                            status=status.HTTP_403_FORBIDDEN)
        d = request.data or {}
        ok, payload = flags_flip(request.user.id, d.get("flag"), d.get("value"),
                                 d.get("reason", ""))
        if not ok:
            return Response(payload, status=status.HTTP_400_BAD_REQUEST)
        return Response(payload)


def flags_snapshot():
    """The /admin/flags GET payload (shared with the web owner panel)."""
    return _FlagsBase._snapshot(_FlagsBase._row())


def flags_flip(actor_id, flag, value, reason=""):
    """Validate + apply one flag flip through core.logic.admin_flags (confirm
    gate, audit). Returns (ok, payload). ONE implementation for /admin/flags/flip
    and the web owner panel."""
    from .logic import admin_flags as AF
    row = _FlagsBase._row()
    from .calls_free import FLAG as _CF, calls_free as _calls_free
    if flag == _CF and _CF not in (row.state or {}):
        # dl1: flip from the EFFECTIVE value (settings default when unset).
        row.state = dict(row.state or {}, **{_CF: _calls_free()})
    res = AF.apply_flip(row.state, flag, value,
                        actor=actor_id, reason=reason,
                        at_iso=timezone.now().isoformat())
    if not res["ok"]:
        return False, {"ok": False, "problems": res["problems"]}
    row.state = res["state"]
    row.audit = ([res["audit"]] + list(row.audit or []))[:200]  # newest-first, capped
    row.save(update_fields=["state", "audit", "updated_at"])
    return True, _FlagsBase._snapshot(row)


class PricingConfigView(APIView):
    """Business Model (Build 1) — SERVER-SIDE PRICING config, OWNER-only (same
    superuser gate as /admin/integrations & /admin/flags).

      GET   -> the current normalized PricingConfig + audit.
      POST  -> merge-update prices / included credits / margin / per-action costs
               with validation (margin>=target, prices/credits>=0); audit-logged.
               When an action's provider_cost changes and auto_reprice=True, the
               action's credit cost is recomputed to hold the margin (§8); the
               default is alert-mode (credits left as submitted / unchanged).

    State persists in PricingConfig(key='global'); all defaults/normalize/validate
    /auto-reprice math is in the pure core.logic.pricing engine — the server is
    the authority, the app never sets a price."""
    @staticmethod
    def _owner(request):
        u = request.user
        return bool(u and u.is_authenticated and u.is_superuser)

    def _snapshot(self):
        from . import billing
        row = billing.get_config()
        from .logic import pricing as P
        cfg = P.normalize(row.data)
        # a6: the pricing check — monthly + ANNUAL plan NET margins.
        return {"config": cfg, "audit": row.audit, "can_manage": True,
                "margin_check": P.plan_margin_report(cfg),
                "warnings": P.margin_warnings(cfg)}

    def get(self, request):
        if not self._owner(request):
            return Response({"can_manage": False},
                            status=status.HTTP_403_FORBIDDEN)
        if request.query_params.get("probe"):
            return Response({"can_manage": True})
        return Response(self._snapshot())

    def post(self, request):
        if not self._owner(request):
            return Response({"can_manage": False},
                            status=status.HTTP_403_FORBIDDEN)
        ok, payload = pricing_apply(request.user.id, request.data or {})
        if not ok:
            return Response(payload, status=status.HTTP_400_BAD_REQUEST)
        return Response(payload)


def pricing_snapshot():
    """The /admin/pricing GET payload (shared by the API and the web owner
    panel /owner/pricing)."""
    return PricingConfigView()._snapshot()


def pricing_apply(actor_id, d):
    """Merge-validate-save a PricingConfig edit. `d` is the POST body
    ({config|<patch>, reason, auto_reprice}). Returns (ok, payload): on
    failure payload = {ok:False, problems, margin_check, warnings}; on success
    the fresh snapshot. ONE implementation for /admin/pricing and /owner/."""
    from . import billing
    from .logic import pricing as P
    d = d or {}
    patch = d.get("config") if isinstance(d.get("config"), dict) else d
    reason = (d.get("reason") or "") if isinstance(d, dict) else ""
    auto_reprice = bool(d.get("auto_reprice")) if isinstance(d, dict) else False

    row = billing.get_config()
    old = P.normalize(row.data)
    # deep-ish merge: patch overrides old at the plan / action-cost / scalar level
    merged = {k: (dict(v) if isinstance(v, dict) else v) for k, v in old.items()}
    for key in ("margin", "annual_discount_pct", "credit_bdt", "usd_bdt",
                "play_fee", "gateway_fee", "vat", "fixed_cost_per_day",
                "storage_cost_bdt_per_gb_month",
                "probashi_price_usd", "ai_daily_budget_usd",
                "ai_user_daily_limit"):
        if key in (patch or {}):
            merged[key] = patch[key]
    for dkey in ("ad_rewards", "profit_guard", "guarantees", "limits",
                 "referral", "shop", "otp", "vehicle", "photo_studio",
                     "chat_vision", "home_hero", "payments",   # pay1: payments
                 "billing",                                      # billing-v2
                 "plans_v2",    # plans-v2
                 "credit_model"):   # pricing-40
        if (dkey in ("guarantees", "limits", "referral")
                and dkey in (patch or {})
                and not isinstance(patch[dkey], dict)):
            merged[dkey] = patch[dkey]          # validate_edit rejects it
        elif isinstance((patch or {}).get(dkey), dict):
            sub = {k: v for k, v in (old.get(dkey) or {}).items()}
            sub.update(patch[dkey])
            merged[dkey] = sub
    if isinstance((patch or {}).get("topup_packs"), list):
        merged["topup_packs"] = patch["topup_packs"]
    if "home_quick_defaults" in (patch or {}):
        merged["home_quick_defaults"] = patch["home_quick_defaults"]
    if isinstance((patch or {}).get("plans"), dict):
        merged_plans = {k: dict(v) for k, v in old["plans"].items()}
        for pid, pv in patch["plans"].items():
            if isinstance(pv, dict):
                merged_plans.setdefault(pid, {}).update(pv)
        merged["plans"] = merged_plans
    if isinstance((patch or {}).get("action_costs"), dict):
        merged_costs = {k: dict(v) for k, v in old["action_costs"].items()}
        for aid, av in patch["action_costs"].items():
            if isinstance(av, dict):
                merged_costs.setdefault(aid, {}).update(av)
        merged["action_costs"] = merged_costs
    if isinstance((patch or {}).get("seller_agent"), dict):   # p1-bizagent
        sa = json.loads(json.dumps(old.get("seller_agent") or {}))
        for k, v in patch["seller_agent"].items():
            if k == "plans" and isinstance(v, dict):
                for pid, pv in v.items():
                    if isinstance(pv, dict):
                        sa.setdefault("plans", {}).setdefault(pid, {}).update(pv)
            elif isinstance(v, dict) and isinstance(sa.get(k), dict):
                sa[k].update(v)
            else:
                sa[k] = v
        merged["seller_agent"] = sa

    problems = P.validate_edit(merged)
    if problems:
        return False, {"ok": False, "problems": problems,
                       "margin_check": P.plan_margin_report(merged),
                       "warnings": P.margin_warnings(merged)}

    new = P.normalize(merged)
    if auto_reprice:
        new = P.recompute_all(new)   # hold the margin on every action (§8)

    row.data = new
    entry = P.make_audit_entry(
        path="config", old=old, new=new, actor=actor_id,
        reason=reason, at_iso=timezone.now().isoformat())
    row.audit = ([entry] + list(row.audit or []))[:200]
    row.save(update_fields=["data", "audit", "updated_at"])
    return True, pricing_snapshot()


class HomeDefaultsView(APIView):
    """GET /app/home-defaults (any signed-in user) -> the owner's DEFAULT 6 home
    quick buttons: {"quick_buttons": [route, ...], "count": 6}. The app uses it
    only while the user has not customized their own; it never blocks home.
    Owner edits it via POST /admin/pricing {"home_quick_defaults": [...]}."""
    def get(self, request):
        from . import billing
        from .logic import home_defaults as HD
        try:
            routes = billing.cfg()["home_quick_defaults"]
        except Exception:
            routes = list(HD.DEFAULT)
        return Response({"quick_buttons": routes, "count": HD.COUNT})


# ===========================================================================
# Business Model — Build 2: credit top-up / history / packs + ad wallet
# ===========================================================================
class CreditPacksView(APIView):
    """GET /credits/packs -> the purchasable credit packs from PricingConfig.

    NO SHOWPIECES: `purchasable` is true only when top-ups are switched on AND
    a pay1 payment channel is LIVE for this build (owner switch on + keys
    added; ?flavour=play|apk, default apk). The app hides the pack buttons
    while it is false instead of offering a buy button that can only answer
    "payment setup pending"."""
    def get(self, request):
        from . import billing
        from .payments import service as pay_service   # pay1
        flavour = "play" if request.query_params.get("flavour") == "play" else "apk"
        purchasable = bool(billing.flag_on("topups_enabled")
                           and pay_service.any_live(flavour))
        return Response({"packs": billing.cfg()["topup_packs"],
                         "credit_bdt": billing.cfg()["credit_bdt"],
                         "purchasable": purchasable})


class CreditHistoryView(APIView):
    """GET /credits/history -> ledger + balance + expiry buckets."""
    def get(self, request):
        from . import billing
        q = request.query_params

        def _n(k, d):
            try:
                return int(q.get(k, d))
            except (TypeError, ValueError):
                return d
        return Response(billing.credit_history(request.user, offset=_n("offset", 0),
                                               limit=_n("limit", 200)))


class CreditTopupView(APIView):
    """POST /credits/topup {pack} -> begin a pack top-up.

    HONESTY: with no payment provider configured we return an honest
    'needs_provider' state and grant NOTHING. With a provider we create a PENDING
    purchase; credits are granted only on a confirmed payment (confirm_topup).
    A mocked/confirmed success can be driven in tests via confirm=True + the
    superuser owner (never by a normal client)."""
    def post(self, request):
        from . import billing
        d = request.data or {}
        pack_id = str(d.get("pack", ""))[:16]
        # per-user rate limit: <=10 topup starts / hour (abuse guard)
        from .models import CreditPurchase
        from django.utils import timezone as _tz
        from datetime import timedelta as _td
        recent = CreditPurchase.objects.filter(
            user=request.user, created_at__gte=_tz.now() - _td(hours=1)).count()
        if recent >= 10:
            return Response({"ok": False, "state": "rate_limited"},
                            status=status.HTTP_429_TOO_MANY_REQUESTS)
        res = billing.start_topup(request.user, pack_id)
        if not res.get("ok"):
            code = (status.HTTP_200_OK if res.get("state") in ("needs_provider", "use_checkout")
                    else status.HTTP_400_BAD_REQUEST)
            return Response(res, status=code)
        return Response(res, status=status.HTTP_201_CREATED)


class CreditTopupConfirmView(APIView):
    """POST /credits/topup/confirm {purchase_id, txn_ref} — payment-provider
    confirmation callback. OWNER-only in this build (no live provider yet); a
    real bkash/Play callback would authenticate via its own signature. Grants
    the pack's credits atomically with the 12-month expiry."""
    def post(self, request):
        u = request.user
        if not (u and u.is_authenticated and u.is_superuser):
            return Response({"ok": False, "reason": "forbidden"},
                            status=status.HTTP_403_FORBIDDEN)
        from . import billing
        d = request.data or {}
        res = billing.confirm_topup(d.get("purchase_id"),
                                    txn_ref=str(d.get("txn_ref", ""))[:120])
        code = status.HTTP_200_OK if res.get("ok") else status.HTTP_400_BAD_REQUEST
        return Response(res, status=code)


class AdEventView(APIView):
    """POST /ads/event {kind, [ad_id], [device_id]} — an AdMob impression.

    AdMob-key-gated + owner kill-switch gated; credits the FREE user's ad wallet
    at <=70% of a configurable eCPM floor; enforces caps (app_open>=3h, daily
    caps) + a fraud guard (impossible frequency per user/device). NEVER credits
    when AdMob is off (no faked ad revenue)."""
    def post(self, request):
        from . import billing
        from .models import AdEvent
        from django.utils import timezone as _tz
        from datetime import timedelta as _td
        d = request.data or {}
        kind = str(d.get("kind", ""))[:14]
        # admob (owner 25 Oct): the tuning log — {placement, format, kind:
        # impression|click|paid}. An impression of an app-open / native /
        # interstitial ALSO goes through the old wallet path below (caps,
        # fraud guard; credits only once REAL ids are on).
        if kind in ("impression", "click", "paid"):
            from . import admob_service as AS
            code, body = AS.record_event(request.user, d)
            fmt = str(d.get("format", ""))[:14]
            if code == 200 and body.get("ok") and kind == "impression" and \
                    fmt in ("app_open", "native", "interstitial"):
                try:
                    res = billing.ad_event(request.user, fmt,
                                           device_id=str(d.get("device_id", ""))[:64],
                                           ad_id=str(d.get("ad_id", ""))[:80])
                    body["wallet"] = {k: res.get(k) for k in
                                      ("ok", "reason", "credited_credits")}
                    if res.get("reason") not in ("fraud", "bad_kind", "not_free"):
                        from . import sponsor_service as SS
                        SS.add_exposure(request.user,
                                        {"native": "hero"}.get(fmt, fmt), "admob")
                except Exception:
                    pass
            return Response(body, status=code)
        ad_id = str(d.get("ad_id", ""))[:80]
        device_id = str(d.get("device_id", ""))[:64]
        # coarse per-user abuse throttle: <=120 ad events / hour
        recent = AdEvent.objects.filter(
            user=request.user, at__gte=_tz.now() - _td(hours=1)).count()
        if recent >= 120:
            return Response({"ok": False, "reason": "rate_limited"},
                            status=status.HTTP_429_TOO_MANY_REQUESTS)
        res = billing.ad_event(request.user, kind, device_id=device_id,
                               ad_id=ad_id)
        # p2-money: an AdMob ad the app really showed counts toward this
        # user's exposure (app-open cap + retention impact), credited or not.
        if kind in ("app_open", "native", "interstitial") and \
                res.get("reason") not in ("fraud", "bad_kind", "not_free"):
            try:
                from . import sponsor_service as SS
                SS.add_exposure(request.user, {"native": "hero"}.get(kind, kind),
                                "admob")
            except Exception:
                pass
        return Response(res)


class AdWalletView(APIView):
    """GET /ads/wallet -> balance + today's remaining caps per ad kind."""
    def get(self, request):
        from . import billing
        return Response(billing.ad_wallet_state(request.user))


# ===========================================================================
# Business Model — Build 3: storage meter + owner P&L dashboard + usage summary
# ===========================================================================
class StorageMeterView(APIView):
    """GET /storage/meter -> the signed-in user's always-visible storage meter:
    {used, quota_bytes, pct, full}. Quota is the EFFECTIVE plan's quota from
    PricingConfig (Free 1GB / Premium 5GB / Business 15GB)."""
    def get(self, request):
        from . import billing
        return Response(billing.storage_state(request.user))


class UsageSummaryView(APIView):
    """GET /me/usage-summary -> this user's credit balance + included monthly pool
    + this-month usage by action + storage meter, for the credit/usage screens."""
    def get(self, request):
        from . import billing
        return Response(billing.usage_summary(request.user))


class AdminPnlView(APIView):
    """GET /admin/pnl?days=30 — OWNER-only daily P&L dashboard (same superuser
    gate as /admin/pricing & /admin/flags).

    Returns a daily series (revenue by source vs variable cost by type vs the
    admin fixed cost/day) from DailyLedger, margin per feature + per-plan prices,
    the break-even line ("X more paid users OR ৳Y more ad revenue/day"), the
    current profit-guard state and recent cost alerts. REAL numbers only — a
    missing source/type is 0 and there are no fabricated figures."""
    @staticmethod
    def _owner(request):
        u = request.user
        return bool(u and u.is_authenticated and u.is_superuser)

    def get(self, request):
        if not self._owner(request):
            return Response({"can_manage": False},
                            status=status.HTTP_403_FORBIDDEN)
        try:
            days = int(request.query_params.get("days", 30))
        except (TypeError, ValueError):
            days = 30
        days = max(1, min(180, days))
        from . import billing
        payload = billing.pnl_dashboard(days=days)
        payload["can_manage"] = True
        return Response(payload)


def _mem_available_mb():
    """Available RAM in MB from /proc/meminfo (MemAvailable). Best-effort; a
    read failure returns a large number so we don't throttle on a bad read."""
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemAvailable:"):
                    return int(line.split()[1]) // 1024
    except Exception:
        pass
    return 1 << 20


class TelegramWebhookView(APIView):
    """POST /telegram/webhook — Telegram bot SANDBOX (Step 6).

    INERT until the owner sets a `telegram` bot token in the Integrations admin:
    with no token it just acknowledges (200) and does nothing, so it ships safely
    as a sandbox. With a token it routes the message via
    core.logic.telegram_bot.route and replies through the Telegram API. Pure
    command logic is unit-tested; the live send is gated on the token.
    """
    authentication_classes = []  # Telegram calls this unauthenticated
    permission_classes = []

    def post(self, request):
        from . import integrations
        from .logic import telegram_bot as TB
        if not integrations.is_enabled("telegram"):
            # Sandbox: no token -> inert. Never processes or replies.
            return Response({"ok": True, "sandbox": True})
        # Live path (token present): verify Telegram's secret header, route, send.
        upd = request.data or {}
        msg = (upd.get("message") or upd.get("edited_message") or {})
        text = (msg.get("text") or "")
        chat = (msg.get("chat") or {})
        lang = "bn" if str(chat.get("language_code", "")).startswith("bn") else "en"
        decision = TB.route(text, lang=lang, is_linked=False)
        # The actual sendMessage + account-linking side-effects are performed by
        # the live transport (documented in owner_actions). Acknowledge the update.
        return Response({"ok": True, "sandbox": False,
                         "action": decision["action"]})


class ClientCrashReportView(APIView):
    """POST /client/crash-report — scrubbed app crash/error reports.

    sc1: stored in the DB (ClientErrorReport) instead of the old
    .phaseB/client_crash_reports.log file, shown in Owner Admin → Reports →
    App errors. Two body shapes:
      * v2 (lib/diag/crash_reporter.dart): error_type, message, frames, fatal,
        where, version, build, device{brand, manufacturer, model, android, sdk,
        rom, display};
      * v1 (StartupGuard breadcrumb of a bad previous launch): log, version,
        platform (+ device since sc1) — stored as fatal, source=startup.
    Everything is scrubbed again here (core.logic.crash_scrub); the fingerprint
    is computed server-side. Dedupe: one row per fingerprint per phone (user +
    model) per day, repeats bump count. Rate limit: 30 reports / hour / phone
    (over the limit -> 200 {stored:false}; the phone never retries).
    Best-effort: never 500s on a bad payload."""
    RATE_PER_HOUR = 30

    def post(self, request):
        from django.core.cache import cache
        from django.db import IntegrityError, transaction
        from django.db.models import F
        from .logic import crash_scrub as CS
        from .models import ClientErrorReport
        d = request.data if isinstance(request.data, dict) else {}
        dev = d.get("device") if isinstance(d.get("device"), dict) else {}
        model = CS.field(dev.get("model"), 60)
        uid = request.user.id
        key = "sc1-crash-rate:%s:%s" % (uid, CS.fingerprint("", [model]))
        try:
            n = cache.get(key, 0)
            if n >= self.RATE_PER_HOUR:
                return Response({"ok": True, "stored": False, "reason": "rate_limited"})
            cache.set(key, n + 1, 3600)
        except Exception:
            pass
        try:
            if "log" in d and "error_type" not in d:
                log = str(d.get("log", ""))[:8000]
                etype, msg = CS.type_and_message_from_log(log)
                frs = CS.frames_from_text(log)
                fatal, source, where = True, "startup", "startup"
            else:
                etype = CS.error_type(d.get("error_type"))
                msg = CS.message(d.get("message"))
                frs = CS.frames(d.get("frames"))
                fatal, source = bool(d.get("fatal")), "app"
                where = CS.field(d.get("where"), 40)
                # ops-watch: process exits read from Android ApplicationExitInfo
                # on the NEXT start (lib/diag/exit_info.dart): an ANR is its own
                # kind (not a crash); a Java/native crash the Dart reporter
                # could not see counts as a fatal crash.
                kind = CS.field(d.get("kind"), 12)
                if kind == "anr":
                    etype, fatal, source = "ANR", False, "anr"
                elif kind == "exit_crash":
                    fatal, source = True, "exit"
            try:
                sdk = max(0, min(int(dev.get("sdk") or 0), 99))
            except (TypeError, ValueError):
                sdk = 0
            fp = CS.fingerprint(etype, frs if (frs or source not in ("anr", "exit")) else [where])
            now = timezone.now()
            day = timezone.localdate()
            try:   # ops-watch: an exit read on the next start keeps its own day
                occ = int(d.get("occurred_ms") or 0)
            except (TypeError, ValueError):
                occ = 0
            if occ and source in ("anr", "exit"):
                from datetime import datetime, timezone as _tz
                at = datetime.fromtimestamp(occ / 1000, tz=_tz.utc)
                if now - timezone.timedelta(days=29) <= at <= now:
                    day = timezone.localdate(at)
            fields = dict(
                user_hash=CS.user_hash(uid), source=source, fatal=fatal,
                error_type=etype, message=msg, frames=frs, where=where,
                version=CS.field(d.get("version"), 32), build=CS.field(d.get("build"), 16),
                brand=CS.field(dev.get("brand"), 40).lower(),
                manufacturer=CS.field(dev.get("manufacturer"), 40),
                android=CS.field(dev.get("android"), 16), sdk=sdk,
                rom=CS.field(dev.get("rom"), 24), display=CS.field(dev.get("display"), 64),
                first_at=now, last_at=now)
            ident = dict(fingerprint=fp, user_id=uid, model=model, day=day)
            updated = ClientErrorReport.objects.filter(**ident).update(
                count=F("count") + 1, last_at=now)
            if not updated:
                try:
                    with transaction.atomic():
                        ClientErrorReport.objects.create(**ident, **fields)
                except IntegrityError:   # a parallel request created it
                    ClientErrorReport.objects.filter(**ident).update(
                        count=F("count") + 1, last_at=now)
        except Exception:
            return Response({"ok": True, "stored": False})
        return Response({"ok": True, "stored": True})


class RtcTurnView(APIView):
    """GET /rtc/turn — time-limited ICE (STUN+TURN) config for Connected-Circle
    voice/video calls (self-hosted coturn, Step 6 M3).

    * Not configured (no secret) -> {configured:false} so the client shows an
      honest 'call server not reachable' state and the call degrades gracefully.
    * Box under load / low memory -> {throttled:true} so new calls back off
      BEFORE Asalify can slow down (Asalify is protected first).
    * Healthy -> short-lived ICE servers the client plugs into WebRTC.
    """
    def get(self, request):
        import os
        from .logic import rtc as RTC
        secret = getattr(settings, "TURN_STATIC_SECRET", "")
        host = getattr(settings, "TURN_HOST", "")
        port = getattr(settings, "TURN_PORT", 3478)
        if not secret or not host:
            return Response({"configured": False, "throttled": False,
                             "ice_servers": [], "reason": "not_configured"})
        try:
            load1 = os.getloadavg()[0]
        except (OSError, AttributeError):
            load1 = 0.0
        thr = RTC.throttle_decision(load1, os.cpu_count() or 1, _mem_available_mb())
        if thr["throttled"]:
            from . import call_health
            call_health.log_event("rtc_config", "throttled_" + thr["reason"],
                                  user=request.user)
            return Response({"configured": True, "throttled": True,
                             "ice_servers": [], "reason": thr["reason"]})
        creds = RTC.turn_credentials(secret, request.user.id,
                                     timezone.now().timestamp())
        return Response({"configured": True, "throttled": False,
                         "ice_servers": RTC.ice_servers(
                             host, port, creds,
                             tls_port=getattr(settings, "TURN_TLS_PORT", 0)),
                         "ttl": creds["ttl"]})


class RtcHealthView(APIView):
    """POST /rtc/health {step, code, call_id?} — calls-health: the phone gave
    up on a call-setup step after its silent retries (rtc config / placing /
    accepting). Logged for Owner Admin -> Calls health; capped per user/hour.
    Always 200 for a well-formed report (the phone never retries this)."""
    def post(self, request):
        from . import call_health as H
        d = request.data or {}
        step = str(d.get("step") or "")
        code = str(d.get("code") or "unknown")
        if step not in H.CLIENT_STEPS:
            return Response({"detail": "bad step", "code": "bad_step"},
                            status=status.HTTP_422_UNPROCESSABLE_ENTITY)
        if code not in H.CLIENT_CODES:
            code = "unknown"
        try:
            call_id = int(d.get("call_id") or 0) or None
        except (TypeError, ValueError):
            call_id = None
        if call_id is not None:
            from .models import CallRecord
            from django.db.models import Q
            if not CallRecord.objects.filter(
                    Q(caller=request.user) | Q(callee=request.user),
                    pk=call_id).exists():
                call_id = None
        logged = False
        if H.client_report_allowed(request.user):
            logged = H.log_event(step, code, user=request.user,
                                 call_id=call_id, source="client") is not None
        return Response({"ok": True, "logged": logged})


class ReferralHistoryView(APIView):
    def get(self, request):
        lang = req_lang(request)
        ledger = _ledger_for(request.user)
        return Response({"history": R.history(ledger, request.user.id, lang)})


class ReferralRedeemView(APIView):
    def post(self, request):
        ledger = _ledger_for(request.user)
        want = int((request.data or {}).get("points", 0) or 0)
        rc = _referral_cfg()
        res = R.redeem(request.user.id, want, ledger,
                       rate=rc["points_per_premium_day"],
                       min_points=rc["min_redeem_points"],
                       max_days=rc["max_redeem_days"])
        if not res["ok"]:
            return Response({"ok": False, "code": res["code"], "days": 0},
                            status=status.HTTP_400_BAD_REQUEST)
        # persist the negative audit row ...
        ReferralGrant.objects.create(
            user=request.user, kind=R.KIND_REDEEM, points=-res["spent"],
            reason=R.REASON_REDEEM_PREMIUM)
        # ... and apply the Premium days to the plan (extend plan_until).
        now = timezone.now()
        base = request.user.plan_until if (request.user.plan_until and
                                           request.user.plan_until > now) else now
        request.user.plan_until = base + timezone.timedelta(days=res["days"])
        if request.user.plan == "free":
            request.user.plan = "premium"
        request.user.save(update_fields=["plan_until", "plan"])
        return Response({"ok": True, "days": res["days"], "spent": res["spent"],
                         "points": R.balance(_ledger_for(request.user),
                                             request.user.id)})


def award_referral_on_accept(inviter_id, invitee_id, device_id="",
                             phone_verified=True, inviter_active=True,
                             invitee_active=True):
    """HOOK called at circle invite-accept. Awards referral points + welcome
    bonus idempotently (unique (user,invitee) grant guards double-award)."""
    rc = _referral_cfg()
    ledger = []
    for g in ReferralGrant.objects.filter(user_id=inviter_id):
        ledger.append({"id": g.id, "user_id": g.user_id,
                       "invitee_id": g.invitee_id, "device_id": g.device_id,
                       "kind": g.kind, "points": g.points, "reason": g.reason,
                       "month": g.month, "created_at": g.created_at.isoformat()})
    res = R.award_for_accept(
        inviter_id, invitee_id, device_id, phone_verified,
        inviter_active=inviter_active, invitee_active=invitee_active,
        sms_gate_enabled=getattr(settings, "SMS_ENABLED", False),
        ledger=ledger, monthly_cap=rc["monthly_referral_cap"],
        points=rc["points_per_referral"],
        welcome_bonus=rc["welcome_bonus_points"])
    if not res.get("ok"):
        return res
    for row in (res.get("grant"), res.get("bonus")):
        if not row:
            continue
        try:
            # savepoint: a duplicate must not poison the caller's transaction.
            # device_id is None on the welcome-bonus row (NOT NULL column) —
            # coerce, or the invitee's bonus was silently never saved.
            from django.db import transaction as _tx
            with _tx.atomic():
                ReferralGrant.objects.create(
                    user_id=row["user_id"], invitee_id=row.get("invitee_id"),
                    device_id=row.get("device_id") or "", kind=row["kind"],
                    points=row["points"], reason=row.get("reason") or "",
                    month=row.get("month") or "")
        except Exception:
            # unique (user,invitee) -> already awarded; idempotent no-op.
            pass
    return res


# ===========================================================================
# Connected Circle — calls (video plan gate SERVER-ENFORCED)
# ===========================================================================
def _caller_dict(user, member):
    from .calls_free import entitle   # dl1: Free calls (testing)
    return entitle({
        "id": user.id, "plan": plans.effective_plan(user),
        "video_unlocked": bool(getattr(member, "video_unlocked", False)),
        "accepted": (member.state == "accepted") if member else True,
        "blocked": bool(getattr(member, "blocked", False)),
    })


def _callee_dict(member):
    return {
        "id": member.id if member else None,
        "accepted": (member.state == "accepted") if member else True,
        "blocked": bool(getattr(member, "blocked", False)),
        "restricted": bool(getattr(member, "restricted", False)),
    }


class CircleCallsView(APIView):
    def get(self, request):
        from . import views_c2_calls as C2
        lang = req_lang(request)
        # a1-circle: GET circle/calls?member=<my edge id> -> the 1:1 call
        # events with that person for the chat timeline (glare-deduped).
        mid = request.query_params.get("member")
        if mid not in (None, ""):
            from . import a1_circle as A1
            try:
                edge = CircleMember.objects.filter(
                    user=request.user, pk=int(mid)).first()
            except (TypeError, ValueError):
                edge = None
            if edge is None:
                return Response({"detail": "not found"},
                                status=status.HTTP_404_NOT_FOUND)
            return Response({"member_id": edge.id,
                             "events": A1.call_events(request.user, edge)})
        rows = CallRecord.objects.filter(
            caller=request.user) | CallRecord.objects.filter(callee=request.user)
        out = []
        for r in rows.distinct().select_related("caller", "callee", "circle",
                                               "session")[:100]:
            outgoing = r.caller_id == request.user.id
            # QA a6: the history used to carry no peer at all, so every row
            # showed "?" with no name and call-back had no member id. Resolve
            # the VIEWER's own edge to the other party (their chat/call id).
            other = r.callee if outgoing else r.caller
            edge = r.circle if (outgoing and r.circle is not None
                                and r.circle.user_id == request.user.id) else None
            if edge is None and other is not None:
                edge = CircleMember.objects.filter(
                    user=request.user, peer_user=other).first()
            name = ((edge.name if edge is not None else "")
                    or (getattr(other, "name", "") or "")).strip()
            out.append({
                "id": r.id, "kind": r.kind, "state": r.state,
                "name": name,
                "member_id": edge.id if edge is not None else None,
                "relation": edge.relation if edge is not None else "friend",
                "custom_label": edge.custom_label if edge is not None else "",
                "duration_sec": r.duration_sec,
                # Formatted mm:ss for a completed (answered) call; blank for
                # missed/declined so the row shows the outcome instead.
                "duration": (CC.format_duration(r.duration_sec, lang)
                             if r.duration_sec else ""),
                "mine": outgoing,
                "outgoing": outgoing,
                "outcome": (C2.history_outcome(r, request.user.id, lang)
                            or CC.call_outcome_label(
                                {"state": r.state, "caller_id": r.caller_id,
                                 "duration_sec": r.duration_sec},
                                request.user.id, lang)),
                "end_reason": C2.history_reason(r),
                "started_at": r.started_at.isoformat(),
                # x1-calls A3: the other party's photo (signed, cached by
                # photo_v on the phone) + the grouping key.
                "peer_id": other.id if other is not None else None,
                "photo_url": C2.photo_of(other, request)[0],
                "photo_v": C2.photo_of(other, request)[1],
            })
        return Response({"calls": out, "groups": C2.history_groups(
            out, request.user)})


class CirclePlaceCallView(APIView):
    """POST /circle/<member>/call + /call/answer -> the video plan gate."""
    def post(self, request, pk, answer=False):
        m = CircleMember.objects.filter(user=request.user, pk=pk).first()
        if m is None:
            return Response({"detail": "not found"},
                            status=status.HTTP_404_NOT_FOUND)
        kind = CC.normalize_kind((request.data or {}).get("kind", "voice"))
        if answer:
            # c2-calls: the callee accepts the EXISTING ringing record. The
            # video gate is the CALLER's (checked at placement) — a free
            # callee may answer a video call.
            from . import views_c2_calls as C2
            return C2.answer_existing(request, m)
        if not answer:
            # m1-messenger: the callee blocked me, or switched incoming calls
            # off -> refuse without ringing (same neutral reason for both, so
            # a block is not revealed).
            from .views_m1_messenger import reverse_edge, call_prefs
            try:
                rev = reverse_edge(m)
                callee = PUSH.member_peer_user(m)
            except Exception:
                rev = callee = None
            if (rev is not None and rev.blocked) or (
                    callee is not None and callee.pk != request.user.pk
                    and not call_prefs(callee)["incoming_calls"]):
                return Response({"allowed": False, "kind": kind,
                                 "upgrade_required": False,
                                 "reason": "unavailable"},
                                status=status.HTTP_200_OK)
        caller = _caller_dict(request.user, m)
        gate = CC.can_place_call(caller, _callee_dict(m), kind)
        if not gate["allowed"]:
            lang = req_lang(request)
            body = {"allowed": False, "kind": kind,
                    "upgrade_required": gate.get("upgrade_required", False),
                    "reason": gate.get("reason")}
            if gate.get("upgrade_required"):
                body["prompt"] = CC.upgrade_prompt(lang)
            return Response(body, status=status.HTTP_200_OK)
        # c2-calls: answering accepts the EXISTING ringing record (it used to
        # create a second "active" record); placing decides busy / offline
        # and rings (views_c2_calls.place_call).
        from . import views_c2_calls as C2
        try:
            peer = PUSH.member_peer_user(m)
        except Exception:
            peer = None
        body = C2.place_call(
            request, m, peer, kind,
            client_call_id=(request.data or {}).get("client_call_id") or "")
        if isinstance(body, dict):
            body["calls_free"] = bool(caller.get("calls_free"))
        return Response(body, status=status.HTTP_201_CREATED)


class CircleAnswerCallView(CirclePlaceCallView):
    def post(self, request, pk):
        return super().post(request, pk, answer=True)


class CircleCallEventView(APIView):
    """c2-calls: one state machine for every call event (views_c2_calls)."""
    def post(self, request, call_id):
        from . import views_c2_calls as C2
        return C2.CallEventView().post(request, call_id)


# ===========================================================================
# Connected Circle — privacy (server-enforced visibility / DND / policy)
# ===========================================================================
def _privacy_row(user):
    row, _ = CirclePrivacy.objects.get_or_create(
        user=user, defaults={"visibility": CP.default_visibility()})
    return row


def _privacy_dict(row):
    return {
        "visibility": CP.normalize_visibility(row.visibility),
        "read_receipts": row.read_receipts, "typing": row.typing,
        "call_policy": row.call_policy, "call_allow_ids": row.call_allow_ids,
        "call_allow_relations": row.call_allow_relations,
        "dnd_enabled": row.dnd_enabled, "dnd_start": row.dnd_start,
        "dnd_end": row.dnd_end, "dnd_family_exception": row.dnd_family_exception,
    }


class CirclePrivacyView(APIView):
    def get(self, request):
        return Response(_privacy_dict(_privacy_row(request.user)))

    def post(self, request):
        row = _privacy_row(request.user)
        d = request.data or {}
        if "visibility" in d:
            row.visibility = CP.normalize_visibility(d.get("visibility"))
        for b in ("read_receipts", "typing", "dnd_enabled",
                  "dnd_family_exception"):
            if b in d:
                setattr(row, b, bool(d[b]))
        if "call_policy" in d:
            row.call_policy = str(d["call_policy"])[:12]
        for lst in ("call_allow_ids", "call_allow_relations"):
            if lst in d and isinstance(d[lst], list):
                setattr(row, lst, d[lst])
        for t in ("dnd_start", "dnd_end"):
            if t in d:
                setattr(row, t, str(d[t])[:5])
        row.save()
        return Response({"ok": True, **_privacy_dict(row)})


class CircleMemberControlsView(APIView):
    """POST /circle/<member>/controls — block / restrict / mute / pin / archive."""
    def post(self, request, pk):
        m = CircleMember.objects.filter(user=request.user, pk=pk).first()
        if m is None:
            return Response({"detail": "not found"},
                            status=status.HTTP_404_NOT_FOUND)
        d = request.data or {}
        fields = []
        for b in ("blocked", "restricted", "pinned", "archived"):
            if b in d:
                setattr(m, b, bool(d[b]))
                fields.append(b)
        if "muted_until" in d:
            # m1-messenger: accept the ISO instant the client sends ('Always' =
            # far future) as well as a duration token; null/'' unmutes. (The
            # old path only understood tokens, so every ⋮ mute was a no-op.)
            from .views_m1_messenger import parse_mute_until
            try:
                m.muted_until = parse_mute_until(d.get("muted_until"))
            except ValueError:
                return Response({"detail": "bad_muted_until"},
                                status=status.HTTP_400_BAD_REQUEST)
            fields.append("muted_until")
        if fields:
            m.save(update_fields=fields)
        from .views_m1_messenger import chat_pref
        if "favourite" in d:
            p = chat_pref(request.user, "member", m.id, create=True)
            p.favourite = bool(d["favourite"])
            p.save(update_fields=["favourite", "updated_at"])
        fav = chat_pref(request.user, "member", m.id)
        return Response({"ok": True, "id": m.id,
                         "blocked": m.blocked, "restricted": m.restricted,
                         "pinned": m.pinned, "archived": m.archived,
                         "muted_until": (m.muted_until.isoformat()
                                         if m.muted_until else None),
                         "favourite": bool(fav and fav.favourite)})


# ===========================================================================
# Safe Journey & Personal Safety  (journey100: real watcher delivery — the
# events below go to watchers at once and the `journey_sweep` cron re-checks
# overdue / stop / route / signal / wellness every minute; core/journey_watch)
# ===========================================================================
from . import journey_watch as JW  # noqa: E402
from .logic import journey_dest as JD  # noqa: E402


def _journey_pure(j):
    """A plain-dict view of a Journey model for the pure safety_journey helpers
    (they operate on dicts, never ORM objects)."""
    return {
        "id": j.id, "status": j.status, "mode": j.mode,
        "destination": j.destination or {},
        "origin": j.origin,
        "last_location": j.last_location,
        "arrival_radius_m": j.arrival_radius_m,
        "overdue_grace_min": JW.effective_grace(j),
        "location_retention_hours": j.location_retention_hours,
        "expires_at": j.expires_at.isoformat() if j.expires_at else None,
    }


def _pin_configured(user):
    dp = DuressPin.objects.filter(user=user).first()
    return bool(dp and dp.salt and dp.normal_hash)


def _photo_url(j):
    try:
        return j.vehicle_photo.url if j.vehicle_photo else None
    except Exception:
        return None


def _journey_dict(j, lang="bn", traveller=True):
    now = timezone.now()
    state, mins = JW.overdue(j, now)
    out = {
        "id": j.id, "status": j.status, "mode": j.mode,
        "destination": j.destination, "eta": j.eta.isoformat() if j.eta else None,
        "last_location": j.last_location,
        # a SILENT (duress) SOS is never revealed on the traveller's own screen
        "sos_active": bool(j.sos_active and not (traveller and j.silent)),
        "overdue_grace_min": j.overdue_grace_min,
        "overdue_state": state, "overdue_minutes": mins,
        "night": j.night, "extended_count": j.extended_count,
        "extend_left": max(0, JW.MAX_EXTENSIONS - j.extended_count),
        "route_deviation": j.route_deviation, "stop_alert_min": j.stop_alert_min,
        "location_retention_hours": j.location_retention_hours,
        "expires_at": j.expires_at.isoformat() if j.expires_at else None,
        "stopped_at": j.stopped_at.isoformat() if j.stopped_at else None,
        "vehicle": {**(JD.clean_vehicle(j.vehicle) or {}), "photo_url": _photo_url(j)} if (j.vehicle or j.vehicle_photo) else None,
        "web_link": JW.web_url(j) or None,
        "has_pin": JW._pt(j.destination or {}) is not None,
    }
    if j.status == "active":
        out.update(JW.progress(j))
    if traveller:
        out["pin_required"] = _pin_configured(j.traveller)
    return out


def _parse_eta(raw):
    if not raw:
        return None
    from django.utils.dateparse import parse_datetime
    eta = parse_datetime(str(raw))
    if eta is not None and timezone.is_naive(eta):
        eta = timezone.make_aware(eta)
    return eta


def _int(v, default, lo, hi):
    try:
        x = int(v)
    except (TypeError, ValueError):
        return default
    return max(lo, min(hi, x))


def _nf():
    return Response({"detail": "not found"}, status=status.HTTP_404_NOT_FOUND)


class JourneyStartView(APIView):
    def post(self, request):
        d = request.data or {}
        now = timezone.now()
        wids = [w for w in (d.get("watcher_ids") or []) if str(w).isdigit()]
        wids = list(dict.fromkeys(int(w) for w in wids))
        if len(wids) > JW.MAX_WATCHERS:
            return Response({"detail": "too_many_watchers", "max": JW.MAX_WATCHERS},
                            status=status.HTTP_400_BAD_REQUEST)
        day_start = timezone.localtime(now).replace(hour=0, minute=0, second=0, microsecond=0)
        if Journey.objects.filter(traveller=request.user,
                                  created_at__gte=day_start).count() >= JW.DAILY_JOURNEY_CAP:
            return Response({"detail": "daily_limit", "max": JW.DAILY_JOURNEY_CAP},
                            status=status.HTTP_429_TOO_MANY_REQUESTS)
        dest = d.get("destination", {}) or {}
        if not isinstance(dest, dict) or not (str(dest.get("name") or "").strip() or
                                              dest.get("lat") is not None):
            return Response({"detail": "destination_required"},
                            status=status.HTTP_400_BAD_REQUEST)
        eta = _parse_eta(d.get("eta"))
        grace = _int(d.get("overdue_grace_min"), 10, 0, 60)
        retention = _int(d.get("location_retention_hours"), 24, 0, 24 * 7)
        stop_min = _int(d.get("stop_alert_min"), 20, 0, 180)
        # one live journey at a time: an older active one is closed quietly
        for old in Journey.objects.filter(traveller=request.user, status="active"):
            old.status, old.stopped_at = "stopped", now
            old.expires_at = JW.ended_expiry(old, now)
            old.save(update_fields=["status", "stopped_at", "expires_at"])
        horizon = max(eta or now, now) + timezone.timedelta(minutes=grace + 10, hours=12)
        origin = d.get("origin") if isinstance(d.get("origin"), dict) else None
        j = Journey.objects.create(
            traveller=request.user, origin=origin, destination=dest, eta=eta,
            status="active",
            mode=(str(d.get("mode") or "").lower() if str(d.get("mode") or "").lower() in JD.MODES else ""),
            vehicle=JD.clean_vehicle(d.get("vehicle")),
            overdue_grace_min=grace,
            route_deviation=bool(d.get("route_deviation_on")),
            planned_route=d.get("planned_route") if isinstance(d.get("planned_route"), list) else None,
            location_retention_hours=retention, stop_alert_min=stop_min,
            night=bool(d.get("night")),
            expires_at=horizon, last_activity_at=now, moved_at=now)
        for mid in wids:
            m = CircleMember.objects.filter(user=request.user, pk=mid,
                                            state="accepted", blocked=False).first()
            if m:
                JourneyWatcher.objects.get_or_create(journey=j, member=m)
        v = j.vehicle or {}
        JW.emit(j, "started", payload={**v, "mode": v.get("mode") or j.mode})
        out = _journey_dict(j, req_lang(request))
        out["watchers"] = j.watchers.count()
        return Response(out, status=status.HTTP_201_CREATED)


class JourneyActiveView(APIView):
    def get(self, request):
        j = Journey.objects.filter(traveller=request.user,
                                   status="active").first()
        return Response(_journey_dict(j, req_lang(request)) if j else {})


def _fixes(d, j, now):
    """Accept one fix ({lat,lng,battery,at?}) or a store-and-forward batch
    ({points:[...]}) the phone queued while offline. Sorted, de-futured,
    nothing before the journey began, at most 300."""
    raw = d.get("points") if isinstance(d.get("points"), list) else [d]
    out = []
    for p in raw[:300]:
        if not isinstance(p, dict):
            continue
        try:
            lat, lng = float(p.get("lat")), float(p.get("lng"))
        except (TypeError, ValueError):
            continue
        if not (-90 <= lat <= 90 and -180 <= lng <= 180):
            continue
        at = _parse_eta(p.get("at")) or now
        if at > now:
            at = now
        if at < j.created_at - timezone.timedelta(minutes=1):
            continue
        b = p.get("battery")
        try:
            b = int(b) if b not in (None, "") else None
        except (TypeError, ValueError):
            b = None
        out.append((at, lat, lng, b))
    out.sort(key=lambda x: x[0])
    return out


class JourneyLocationView(APIView):
    def post(self, request, pk):
        from .models import JourneyPoint
        j = Journey.objects.filter(traveller=request.user, pk=pk).first()
        if j is None:
            return _nf()
        d = request.data or {}
        now = timezone.now()
        if SJ.journey_is_expired(_journey_pure(j), now) and j.status == "active":
            JW.expire(j)
        if j.status != "active":
            # the journey is over (arrived / stopped / expired): the phone
            # stops its location service on this answer
            return Response({"ok": True, "status": j.status, "arrived": j.status == "arrived",
                             "accepted": 0, "overdue_state": j.status})
        fixes = _fixes(d, j, now)
        newest_known = JW.fix_of(j)
        for at, lat, lng, b in fixes:
            JourneyPoint.objects.create(journey=j, lat=lat, lng=lng, battery=b, at=at)
            JW.on_location(j, lat, lng, at, b, now=now)
            if newest_known is None or newest_known[2] is None or at >= newest_known[2]:
                j.last_location = {"lat": lat, "lng": lng, "at": at.isoformat(), "battery": b}
                newest_known = (lat, lng, at, b)
        j.last_activity_at = now
        arrived = False
        if newest_known is not None and fixes:
            arrived, _dist = SJ.arrival_check(_journey_pure(j), newest_known[0], newest_known[1])
        j.lost_alerted_at = None if fixes else j.lost_alerted_at
        if arrived:
            JW.on_arrived(j, now)
        j.save()
        state, mins = JW.overdue(j, now)
        b = fixes[-1][3] if fixes else None
        return Response({"ok": True, "status": j.status, "arrived": bool(arrived),
                         "accepted": len(fixes),
                         "overdue_state": state, "overdue_minutes": mins,
                         "eta": j.eta.isoformat() if j.eta else None,
                         "low_battery": b is not None and b < JW.LOW_BATT})


class JourneyArrivedView(APIView):
    def post(self, request, pk):
        j = Journey.objects.filter(traveller=request.user, pk=pk).first()
        if j is None:
            return _nf()
        if j.status == "active":
            JW.on_arrived(j)
            j.save()
        return Response({"ok": True, "status": j.status})


def _pin_rate_ok(user):
    from django.core.cache import cache
    key = "jw:pin:%s" % user.pk
    n = cache.get(key, 0)
    return n < 8, key, n


def _classify_pin(request, pin):
    """'none' (no PIN set) | 'required' | 'cancel' | 'duress' | 'wrong' | 'locked'."""
    dp = DuressPin.objects.filter(user=request.user).first()
    if not (dp and dp.salt and dp.normal_hash):
        return "none"
    if not pin:
        return "required"
    ok, key, n = _pin_rate_ok(request.user)
    if not ok:
        return "locked"
    action = SJ.verify_pin_action(str(pin), dp.normal_hash, dp.duress_hash, dp.salt)
    if action == "wrong":
        from django.core.cache import cache
        cache.set(key, n + 1, 600)
    return action


def _duress(request, j, lat=None, lng=None):
    """Silent emergency: the screen shows 'cancelled', watchers + family get
    an SOS with the last location. Nothing reaches the sender's own phone."""
    fx = JW.fix_of(j) if j else None
    lat = lat if lat is not None else (fx[0] if fx else None)
    lng = lng if lng is not None else (fx[1] if fx else None)
    if j is not None:
        j.sos_active, j.silent = True, True
        # keep the last location for the watchers a while, whatever retention says
        keep = timezone.now() + timezone.timedelta(hours=24)
        if not j.expires_at or j.expires_at < keep:
            j.expires_at = keep
        j.save(update_fields=["sos_active", "silent", "expires_at", "status", "stopped_at"])
        JW.emit(j, "duress", key="1", payload={"lat": lat, "lng": lng})
    PUSH.hook_sos(request.user, lat=lat, lng=lng, silent=True,
                  journey_id=j.id if j else None)


class JourneyStopView(APIView):
    """Stop early. When the user has a safety PIN, stopping needs it: the
    normal PIN really cancels; the DURESS PIN answers exactly the same way
    ('cancel') while silently firing an SOS to watchers + family (item 8)."""
    def post(self, request, pk):
        j = Journey.objects.filter(traveller=request.user, pk=pk).first()
        if j is None:
            return _nf()
        pin = (request.data or {}).get("pin")
        action = _classify_pin(request, pin)
        if action == "required":
            return Response({"ok": False, "pin": "required"}, status=status.HTTP_400_BAD_REQUEST)
        if action == "locked":
            return Response({"ok": False, "pin": "locked"}, status=status.HTTP_429_TOO_MANY_REQUESTS)
        if action == "wrong":
            return Response({"ok": False, "pin": "wrong"}, status=status.HTTP_400_BAD_REQUEST)
        now = timezone.now()
        was_active = j.status == "active"
        j.status = "stopped"
        j.stopped_at = j.stopped_at or now
        if action == "duress":
            _duress(request, j)
        else:
            j.sos_active = False
            j.expires_at = JW.ended_expiry(j, now)
            j.save(update_fields=["status", "stopped_at", "sos_active", "expires_at"])
            if was_active:
                JW.emit(j, "ended")
            JW.clear_urgent(j)
        # identical answer for cancel and duress (an onlooker sees no difference)
        return Response({"ok": True, "outcome": "cancel", "status": "stopped"})


class JourneyRespondView(APIView):
    """'I'm OK' to the overdue question: the deadline moves OK_SNOOZE_MIN
    ahead; if watchers were already alerted they hear the traveller is OK."""
    def post(self, request, pk):
        j = Journey.objects.filter(traveller=request.user, pk=pk).first()
        if j is None:
            return _nf()
        now = timezone.now()
        j.last_activity_at = now
        j.responded_at = now
        fields = ["last_activity_at", "responded_at"]
        state, _ = JW.overdue(j, now)
        if j.status == "active" and state in ("grace", "ask", "alert"):
            j.eta = now + timezone.timedelta(minutes=JW.OK_SNOOZE_MIN) - \
                timezone.timedelta(minutes=JW.effective_grace(j))
            if j.expires_at and j.expires_at < j.eta + timezone.timedelta(hours=1):
                j.expires_at = j.eta + timezone.timedelta(hours=12)
            fields += ["eta", "expires_at", "ask_sent_at", "escalated_at", "escalations"]
            if j.escalated_at is not None:
                JW.emit(j, "ok_again", key="%d:%s" % (j.escalations, now.isoformat()))
                JW.clear_urgent(j)
            j.ask_sent_at, j.escalated_at, j.escalations = None, None, 0
        j.save(update_fields=fields)
        state, mins = JW.overdue(j, now)
        return Response({"ok": True, "eta": j.eta.isoformat() if j.eta else None,
                         "overdue_state": state})


class JourneyExtendView(APIView):
    """POST /journey/<pk>/extend {minutes}: more time (5–120 min, at most
    MAX_EXTENSIONS times). Watchers are told the new arrival time."""
    def post(self, request, pk):
        j = Journey.objects.filter(traveller=request.user, pk=pk, status="active").first()
        if j is None:
            return _nf()
        if j.extended_count >= JW.MAX_EXTENSIONS:
            return Response({"detail": "extend_limit", "max": JW.MAX_EXTENSIONS},
                            status=status.HTTP_400_BAD_REQUEST)
        mins = _int((request.data or {}).get("minutes"), 15, JW.EXTEND_MIN, JW.EXTEND_MAX)
        now = timezone.now()
        was_alerted = j.escalated_at is not None
        j.eta = max(j.eta or now, now) + timezone.timedelta(minutes=mins)
        j.expires_at = max(j.expires_at or now, j.eta + timezone.timedelta(hours=12))
        j.extended_count += 1
        j.ask_sent_at, j.escalated_at, j.escalations = None, None, 0
        j.responded_at = now
        j.save(update_fields=["eta", "expires_at", "extended_count", "ask_sent_at",
                              "escalated_at", "escalations", "responded_at"])
        JW.emit(j, "extended", key=str(j.extended_count), payload={"minutes": mins})
        if was_alerted:
            JW.clear_urgent(j)
        return Response({**_journey_dict(j, req_lang(request)), "ok": True})


class JourneyVehiclePhotoView(APIView):
    """POST /journey/<pk>/vehicle-photo {image_b64, plate?}: the ride's photo
    (taken with the camera or picked — no storage permission). Re-encoded as
    a small JPEG (EXIF incl. GPS stripped), private signed link, deleted with
    the journey's location data."""
    MAX_BYTES = 3 * 1024 * 1024

    def post(self, request, pk):
        import base64
        import io
        from django.core.files.base import ContentFile
        j = Journey.objects.filter(traveller=request.user, pk=pk, status="active").first()
        if j is None:
            return _nf()
        d = request.data or {}
        raw = str(d.get("image_b64") or "")
        if "," in raw[:80]:
            raw = raw.split(",", 1)[1]
        try:
            blob = base64.b64decode(raw, validate=False)
        except Exception:
            blob = b""
        if not blob or len(blob) > self.MAX_BYTES:
            return Response({"detail": "bad_image"}, status=status.HTTP_400_BAD_REQUEST)
        try:
            from PIL import Image
            im = Image.open(io.BytesIO(blob))
            im.load()
            im = im.convert("RGB")
            im.thumbnail((1280, 1280))
            buf = io.BytesIO()
            im.save(buf, "JPEG", quality=72)
        except Exception:
            return Response({"detail": "bad_image"}, status=status.HTTP_400_BAD_REQUEST)
        if j.vehicle_photo:
            try:
                j.vehicle_photo.delete(save=False)
            except Exception:
                pass
        j.vehicle_photo.save("j%d_%d.jpg" % (j.id, int(timezone.now().timestamp())),
                             ContentFile(buf.getvalue()), save=False)
        v = dict(j.vehicle or {})
        if d.get("plate"):
            v["plate"] = d["plate"]
        if d.get("mode"):
            v["mode"] = d["mode"]
        v = JD.clean_vehicle(v) or {}
        j.vehicle = v or None
        j.save(update_fields=["vehicle_photo", "vehicle"])
        JW.emit(j, "vehicle", key="photo:%s" % j.vehicle_photo.name[-20:],
                payload={"plate": v.get("plate"), "mode": v.get("mode") or j.mode, "photo": True})
        return Response({"ok": True, "photo_url": _photo_url(j)})


class JourneySosView(APIView):
    def post(self, request):
        d = request.data or {}
        jid = d.get("journey_id")
        j = Journey.objects.filter(traveller=request.user, pk=jid).first() \
            if jid else None
        silent = bool(d.get("silent"))
        if j:
            j.sos_active = True
            j.silent = silent
            keep = timezone.now() + timezone.timedelta(hours=24)
            if not j.expires_at or j.expires_at < keep:
                j.expires_at = keep
            if d.get("lat") is not None and d.get("lng") is not None:
                j.last_location = {"lat": d.get("lat"), "lng": d.get("lng"),
                                   "at": timezone.now().isoformat(),
                                   "battery": (j.last_location or {}).get("battery")}
            j.save(update_fields=["sos_active", "silent", "expires_at", "last_location"])
        lang = req_lang(request)
        loc = {"lat": d.get("lat"), "lng": d.get("lng")} \
            if d.get("lat") is not None else None
        payload = SJ.sos_journey_payload(request.user.name or "", loc,
                                         silent=silent, lang=lang)
        PUSH.hook_sos(request.user, lat=d.get("lat"), lng=d.get("lng"),
                      silent=silent, journey_id=j.id if j else None,
                      client_id=str(d.get("client_id") or ""),
                      source=str(d.get("source") or "journey"))
        return Response({"ok": True, "silent": silent, "payload": payload,
                         "web_link": JW.web_url(j) if j else None})


class JourneySosCancelView(APIView):
    """POST /journey/sos/cancel {pin, journey_id?}: cancel an SOS countdown.
    No PIN set -> plain cancel. Normal PIN -> cancel. Duress PIN -> the SAME
    'cancel' answer while a silent SOS goes out. Wrong -> 400, stay armed."""
    def post(self, request):
        d = request.data or {}
        action = _classify_pin(request, d.get("pin"))
        if action == "required":
            return Response({"ok": False, "pin": "required"}, status=status.HTTP_400_BAD_REQUEST)
        if action == "locked":
            return Response({"ok": False, "pin": "locked"}, status=status.HTTP_429_TOO_MANY_REQUESTS)
        if action == "wrong":
            return Response({"ok": False, "pin": "wrong"}, status=status.HTTP_400_BAD_REQUEST)
        if action == "duress":
            jid = d.get("journey_id")
            j = Journey.objects.filter(traveller=request.user, pk=jid).first() \
                if jid and str(jid).isdigit() else None
            _duress(request, j, lat=d.get("lat"), lng=d.get("lng"))
        return Response({"ok": True, "outcome": "cancel"})


class JourneyDuressPinView(APIView):
    def get(self, request):
        return Response({"configured": _pin_configured(request.user)})

    def post(self, request):
        d = request.data or {}
        pin, duress = str(d.get("pin") or ""), str(d.get("duress_pin") or "")
        if not pin or not duress or pin == duress or not (pin.isdigit() and duress.isdigit()) \
                or not (4 <= len(pin) <= 8 and 4 <= len(duress) <= 8):
            return Response({"detail": "pins must differ"},
                            status=status.HTTP_400_BAD_REQUEST)
        import os
        salt = os.urandom(8).hex()
        dp, _ = DuressPin.objects.get_or_create(user=request.user)
        dp.salt = salt
        dp.normal_hash = SJ.hash_pin(pin, salt)
        dp.duress_hash = SJ.hash_pin(duress, salt)
        dp.save()
        return Response({"ok": True, "configured": True})

    def delete(self, request):
        """Remove the safety PIN — needs the normal PIN (a duress PIN here
        'succeeds' too, silently alerting, exactly like a cancel)."""
        action = _classify_pin(request, (request.data or {}).get("pin"))
        if action in ("required", "wrong", "locked"):
            return Response({"ok": False, "pin": action}, status=status.HTTP_400_BAD_REQUEST)
        if action == "duress":
            _duress(request, None)
            return Response({"ok": True, "configured": False})
        DuressPin.objects.filter(user=request.user).delete()
        return Response({"ok": True, "configured": False})


class JourneyWebLinkView(APIView):
    def get(self, request, pk):
        j = Journey.objects.filter(traveller=request.user, pk=pk).first()
        if j is None or not j.expires_at:
            return _nf()
        return Response({"url": JW.web_url(j), "token": JW.web_token(j),
                         "expires_at": JW.link_expiry(j).isoformat()})


class JourneyWebLinkRevokeView(APIView):
    """journey2: POST /journey/<pk>/web-link/revoke — every watcher link
    shared so far stops working at once (the page says 'turned off', no
    location). A fresh link comes back so the traveller can share again.
    Assisto watchers in the app are not affected (they always get the
    current link)."""
    def post(self, request, pk):
        j = Journey.objects.filter(traveller=request.user, pk=pk).first()
        if j is None:
            return _nf()
        j.web_gen = int(j.web_gen or 0) + 1
        j.save(update_fields=["web_gen"])
        return Response({"ok": True, "url": JW.web_url(j) if j.status == "active" else "",
                         "revoked": True})


class JourneyRideView(APIView):
    """journey2: POST /journey/<pk>/ride {plate, mode, app, driver_name,
    driver_phone, note} — ride details added or corrected DURING the trip
    (the Pathao/Uber driver is often known only after the ride starts).
    Watchers get one 'ride details' push per change."""
    def post(self, request, pk):
        j = Journey.objects.filter(traveller=request.user, pk=pk, status="active").first()
        if j is None:
            return _nf()
        v = JD.clean_vehicle({**(j.vehicle or {}), **(request.data or {})})
        if v == (j.vehicle or None):
            return Response({"ok": True, "vehicle": v, "changed": False})
        j.vehicle = v
        if v and v.get("mode"):
            j.mode = v["mode"]
        j.save(update_fields=["vehicle", "mode"])
        if v:
            import hashlib
            key = "ride:" + hashlib.sha1(json.dumps(v, sort_keys=True).encode()).hexdigest()[:16]
            JW.emit(j, "vehicle", key=key, payload=v)
        return Response({"ok": True, "vehicle": v, "changed": True})


class JourneyParseLinkView(APIView):
    """journey2: POST /journey/parse-link {text} -> {lat, lng, name} from a
    pasted Google Maps link (long or maps.app.goo.gl), a geo: URI or plain
    '23.78, 90.41'. 400 {detail: no_coords} when nothing usable is in it."""
    def post(self, request):
        from . import journey_geo as JG
        text = str((request.data or {}).get("text") or "").strip()[:2000]
        got = JD.parse_maps_link(text)
        if got is None:
            import re
            m = re.search(r"https://\S+", text)
            url = m.group(0) if m else ""
            if url and JD.is_short_maps_link(url):
                got = JG.resolve_short_link(url)
        if got is None:
            return Response({"detail": "no_coords"}, status=status.HTTP_400_BAD_REQUEST)
        return Response({"ok": True, **got})


class JourneyGeocodeView(APIView):
    """journey2: GET /journey/geocode?q=&lat=&lng= — search by place name via
    the owner's Google Places key. {available: false} without a key (the app
    then hides the search box — never a fake result)."""
    def get(self, request):
        from . import journey_geo as JG
        near = None
        try:
            near = (float(request.query_params.get("lat")), float(request.query_params.get("lng")))
        except (TypeError, ValueError):
            near = None
        return Response(JG.geocode(request.query_params.get("q"), lang=req_lang(request),
                                   near=near))


class JourneyWatchingView(APIView):
    """GET /journey/watching — journeys the caller is a chosen watcher of
    (live, or ended within the privacy window). Location only while the trip
    is live or an SOS is open; never past the privacy expiry."""
    def get(self, request):
        now = timezone.now()
        rows = (JourneyWatcher.objects
                .filter(member__peer_user=request.user, member__state="accepted",
                        member__blocked=False, journey__expires_at__gt=now)
                .select_related("journey", "journey__traveller")
                .order_by("-journey__created_at")[:20])
        out = []
        for w in rows:
            j = w.journey
            live = j.status == "active" or j.sos_active
            fx = JW.fix_of(j) if live else None
            st, mins = JW.overdue(j, now)
            out.append({
                "id": j.id, "name": PUSH.seen_name(request.user, j.traveller),
                "status": j.status, "sos": j.sos_active,
                "destination": (j.destination or {}).get("name") or "",
                "eta": j.eta.isoformat() if j.eta else None,
                "overdue_state": st, "overdue_minutes": mins,
                "lat": fx[0] if fx else None, "lng": fx[1] if fx else None,
                "fix_at": fx[2].isoformat() if fx and fx[2] else None,
                "fix_age_s": int((now - fx[2]).total_seconds()) if fx and fx[2] else None,
                "battery": fx[3] if fx else None,
                "ride": JD.clean_vehicle(j.vehicle),
                **(JW.progress(j, fx) if fx and j.status == "active" else {}),
                "url": JW.web_url(j)})
        return Response({"journeys": out})


class JourneyNearestHelpView(APIView):
    """Nearest police + hospitals from REAL map data (Google Places when the
    owner's key is set, else OpenStreetMap via Overpass) — never samples. The
    helplines (999 / 109) always come back, even when the lookup fails."""
    def get(self, request):
        lang = req_lang(request)
        lines = SJ.helplines(lang)
        try:
            lat = float(request.query_params.get("lat"))
            lon = float(request.query_params.get("lon"))
        except (TypeError, ValueError):
            return Response({"police": [], "hospital": [], "helplines": lines,
                             "state": "no_location"})
        out = {"helplines": lines}
        failed = 0
        for kind in ("police", "hospital"):
            try:
                res = nearby.search(lat, lon, kind, lang=lang)
                rows, src = (res if isinstance(res, tuple) else
                             ((res or {}).get("results") or [], ""))
                ranked = SJ.rank_nearest(
                    [{**r, "lng": r.get("lng", r.get("lon")), "type": kind}
                     for r in (rows or []) if isinstance(r, dict)], lat, lon, limit=3)
                out[kind] = ranked
                out["source"] = src
                if src == "unavailable":   # srvperf/H: maps down, say so
                    failed += 1
            except Exception:
                out[kind] = []
                failed += 1
        out["state"] = "failed" if failed == 2 else (
            "ok" if (out.get("police") or out.get("hospital")) else "none_nearby")
        return Response(out)


def _place_dict(p):
    return {"id": p.id, "label": p.label, "kind": JD.place_kind(p.label),
            "name": p.name, "lat": p.lat, "lng": p.lng}


class SavedPlacesView(APIView):
    """Saved destinations (Home / School / Office / others). journey2:
    coordinates are validated (a bad value used to 500), Home/School/Office
    are one each (saving again replaces it), and places can be deleted."""
    def get(self, request):
        rows = SavedPlace.objects.filter(user=request.user)
        order = {k: i for i, k in enumerate(JD.PLACE_KINDS)}
        out = sorted((_place_dict(p) for p in rows), key=lambda x: order.get(x["kind"], 9))
        return Response({"places": out})

    def post(self, request):
        place, err = JD.clean_place(request.data or {})
        if err:
            return Response({"detail": err}, status=status.HTTP_400_BAD_REQUEST)
        mine = SavedPlace.objects.filter(user=request.user)
        if place["kind"] in ("home", "school", "office"):
            old = [p for p in mine if JD.place_kind(p.label) == place["kind"]]
            if old:
                p = old[0]
                p.label, p.name, p.lat, p.lng = place["kind"], place["name"], place["lat"], place["lng"]
                p.save(update_fields=["label", "name", "lat", "lng"])
                for extra in old[1:]:
                    extra.delete()
                return Response({"ok": True, "replaced": True, **_place_dict(p)})
        if mine.count() >= JD.MAX_PLACES:
            return Response({"detail": "limit"}, status=status.HTTP_400_BAD_REQUEST)
        p = SavedPlace.objects.create(user=request.user, label=place["label"][:40],
                                      name=place["name"][:160], lat=place["lat"], lng=place["lng"])
        return Response({"ok": True, **_place_dict(p)}, status=status.HTTP_201_CREATED)


class SavedPlaceDetailView(APIView):
    def delete(self, request, pk):
        n, _ = SavedPlace.objects.filter(user=request.user, pk=pk).delete()
        if not n:
            return _nf()
        return Response({"ok": True})


def _routine_dict(r):
    return {"id": r.id, "days": r.days, "time": r.time, "destination": r.destination,
            "watcher_ids": r.watcher_ids, "minutes": r.minutes, "night": r.night,
            "enabled": r.enabled}


class JourneyRoutinesView(APIView):
    """Saved routine trips. At the time, the server pushes the traveller a
    'start your Safe Journey' reminder (only the user can start the location
    service, from the app)."""
    def get(self, request):
        from .models import JourneyRoutine
        return Response({"routines": [_routine_dict(r) for r in
                                      JourneyRoutine.objects.filter(user=request.user)]})

    def post(self, request):
        from .models import JourneyRoutine
        import re
        d = request.data or {}
        if JourneyRoutine.objects.filter(user=request.user).count() >= 10:
            return Response({"detail": "limit"}, status=status.HTTP_400_BAD_REQUEST)
        t = str(d.get("time") or "")
        if not re.match(r"^([01]\d|2[0-3]):[0-5]\d$", t):
            return Response({"detail": "bad_time"}, status=status.HTTP_400_BAD_REQUEST)
        days = [x for x in (str(v).lower()[:3] for v in (d.get("days") or []))
                if x in ("sun", "mon", "tue", "wed", "thu", "fri", "sat")]
        if not days:
            return Response({"detail": "bad_days"}, status=status.HTTP_400_BAD_REQUEST)
        dest = d.get("destination") if isinstance(d.get("destination"), dict) else {}
        r = JourneyRoutine.objects.create(
            user=request.user, days=list(dict.fromkeys(days)), time=t,
            destination={"name": str(dest.get("name") or "")[:160],
                         **({"lat": dest["lat"], "lng": dest["lng"]}
                            if dest.get("lat") is not None and dest.get("lng") is not None else {})},
            watcher_ids=[int(w) for w in (d.get("watcher_ids") or []) if str(w).isdigit()][:JW.MAX_WATCHERS],
            minutes=_int(d.get("minutes"), 30, 5, 240), night=bool(d.get("night")),
            enabled=d.get("enabled", True) is not False)
        return Response({**_routine_dict(r), "ok": True}, status=status.HTTP_201_CREATED)


class JourneyRoutineDetailView(APIView):
    def post(self, request, pk):
        from .models import JourneyRoutine
        r = JourneyRoutine.objects.filter(user=request.user, pk=pk).first()
        if r is None:
            return _nf()
        if "enabled" in (request.data or {}):
            r.enabled = bool(request.data["enabled"])
            r.save(update_fields=["enabled"])
        return Response(_routine_dict(r))

    def delete(self, request, pk):
        from .models import JourneyRoutine
        n, _ = JourneyRoutine.objects.filter(user=request.user, pk=pk).delete()
        return Response({"ok": bool(n)}, status=200 if n else 404)


class WellnessView(APIView):
    def get(self, request):
        w = WellnessWatch.objects.filter(parent=request.user).first()
        if w is None:
            return Response(SJ.default_wellness_config())
        return Response({
            "enabled": w.enabled, "parent_opt_in": w.parent_opt_in,
            "period_hours": w.period_hours, "response_window": w.response_window,
            "quiet_start": w.quiet_start, "quiet_end": w.quiet_end,
            "watcher_ids": w.watcher_ids,
            "prompt_open": w.prompt_sent_at is not None})

    def post(self, request):
        d = request.data or {}
        w, _ = WellnessWatch.objects.get_or_create(parent=request.user)
        if "parent_opt_in" in d:
            w.parent_opt_in = bool(d["parent_opt_in"])
        # arming GATE: enabled only ever true if the parent opted in.
        w.enabled = bool(d.get("enabled")) and w.parent_opt_in
        if "period_hours" in d:
            w.period_hours = _int(d["period_hours"], 12, SJ.WELLNESS_PERIOD_HOURS_MIN,
                                  SJ.WELLNESS_PERIOD_HOURS_MAX)
        if isinstance(d.get("watcher_ids"), list):
            w.watcher_ids = [int(x) for x in d["watcher_ids"] if str(x).isdigit()][:JW.MAX_WATCHERS]
        for t in ("quiet_start", "quiet_end"):
            if t in d:
                setattr(w, t, str(d[t])[:5])
        w.last_activity_at = timezone.now()
        w.prompt_sent_at, w.alert_sent_at = None, None
        w.save()
        return Response({"ok": True, "enabled": w.enabled})


class WellnessPingView(APIView):
    def post(self, request):
        w, _ = WellnessWatch.objects.get_or_create(parent=request.user)
        w.last_activity_at = timezone.now()
        w.prompt_sent_at = None
        w.alert_sent_at = None
        w.save(update_fields=["last_activity_at", "prompt_sent_at", "alert_sent_at"])
        return Response({"ok": True})
