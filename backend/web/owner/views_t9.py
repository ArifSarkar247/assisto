"""t9-turnscale: Owner Admin → Call relay (TURN). Live coturn capacity
(current + 24h peak + recent samples), the editable TURN server list, alert
thresholds, the managed-TURN overflow state and the relay cost per minute."""
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import done, owner_view, page, to_num


def _T(request):
    from .i18n import strings
    return strings(getattr(request, "owner_lang", "bn"))


def _mbit(bps):
    return None if bps is None else round(bps * 8 / 1e6, 1)


@require_http_methods(["GET", "POST"])
@owner_view()
def calls(request):
    from core import turn_monitor as M
    from core import turn_pool as P
    from core.models import TurnConfig
    T = _T(request)
    cfg = TurnConfig.load()
    ctx, status = {}, 200
    if request.method == "POST":
        action = request.POST.get("action")
        if action == "servers":
            text = request.POST.get("servers_text", "").strip()[:4000]
            try:
                P.parse_servers(text)
            except P.ConfigError as e:
                ctx["problems"] = ["%s: %s" % (T["t9_bad_list"], e)]
                ctx["servers_text"] = text
                status = 400
            else:
                before = cfg.servers_text
                cfg.servers_text = text
                cfg.save(update_fields=["servers_text", "updated_at"])
                S.audit(request, request.owner, "turn.servers", "turn:servers",
                        before={"servers": before}, after={"servers": text})
                return done("/owner/calls")
        elif action == "thresholds":
            new, bad = {}, []
            for k, dflt in M.DEFAULT_THRESHOLDS.items():
                raw = request.POST.get(k, "")
                if raw == "":
                    continue
                v = to_num(raw)
                if v is None or v <= 0 or v > 10000:
                    bad.append(k)
                else:
                    new[k] = float(v)
            if bad:
                ctx["problems"] = [T["p_invalid_number"]]
                status = 400
            else:
                before = dict(cfg.thresholds or {})
                cfg.thresholds = new
                cfg.save(update_fields=["thresholds", "updated_at"])
                S.audit(request, request.owner, "turn.thresholds", "turn:thresholds",
                        before=before, after=new)
                return done("/owner/calls")
        else:
            from django.http import Http404
            raise Http404
    summ = M.panel_summary()
    servers, source, _h = P.configured_servers()
    try:
        cost = M.relay_cost(30)
    except Exception:
        cost = None
    ov = P.overflow_settings()
    lim = summ["lim"]
    rows = [{"at": r.at, "alloc": r.allocations, "sess": r.cli_sessions,
             "relay_out": _mbit(r.relay_out_bps), "nic_out": _mbit(r.nic_out_bps),
             "cpu": r.turn_cpu_pct, "steal": r.steal_pct,
             "errs": r.quota_errors + r.bw_quota_errors, "alloc_errs": r.alloc_errors,
             "auth": r.auth_errors} for r in summ["recent"]]
    cur = summ["cur"]
    ctx.update({
        "summ": summ, "cur": cur, "rows": rows, "lim": lim,
        "cur_relay_out": _mbit(cur.relay_out_bps) if cur else None,
        "cur_nic_out": _mbit(cur.nic_out_bps) if cur else None,
        "peak_relay_out": _mbit(summ["peak"]["rout"]),
        "peak_nic_out": _mbit(summ["peak"]["nout"]),
        "runner_in": _mbit((summ.get("runner_bps") or {}).get("in")),
        "runner_out": _mbit((summ.get("runner_bps") or {}).get("out")),
        "budget_mbit": _mbit(lim["bw_budget"]),
        "pct_alloc": None if summ["pct"]["alloc"] is None else round(summ["pct"]["alloc"]),
        "pct_bw": None if summ["pct"]["bw"] is None else round(summ["pct"]["bw"]),
        "servers": [dict(s, h=summ["health"].get("%s:%s" % (s["host"], s["port"])))
                    for s in servers],
        "source": source,
        "quota24": (summ["peak"]["q"] or 0) + (summ["peak"]["bq"] or 0),
        "servers_text": ctx.get("servers_text", cfg.servers_text),
        "health": summ["health"],
        "thresholds": [(k, lim["thresholds"][k], k in (cfg.thresholds or {}))
                       for k in M.DEFAULT_THRESHOLDS],
        "active_alerts": [k for k, v in (summ["alert_state"] or {}).items()
                          if (v or {}).get("active")],
        "overflow_active": ov["active"], "overflow_mode": ov.get("mode", ""),
        "cost": cost,
    })
    # calls-health: last-24h call setup health (attempts, success %, throttles,
    # failures by step) + the same alert as the panel-wide banner.
    try:
        from core import call_health as H
        ch = H.summary(24)
        ctx["ch"] = ch
        ctx["ch_alert"] = H.alert(ch)
        ctx["ch_steps"] = [
            ("rtc_config", T["ch_step_rtc"], ch["failures"]["rtc_config"]),
            ("place", T["ch_step_place"], ch["failures"]["place"]),
            ("push", T["ch_step_push"], ch["failures"]["push"]),
            ("accept", T["ch_step_accept"], ch["failures"]["accept"]),
            ("ice", T["ch_step_ice"], ch["failures"]["ice"]),
            ("dropped", T["ch_step_dropped"], ch["failures"]["dropped"]),
        ]
        f = ch["funnel"]
        ctx["ch_funnel"] = [
            (T["ch_f_placed"], f["placed"]), (T["ch_f_push"], f["push"]),
            (T["ch_f_acked"], f["acked"]), (T["ch_f_answered"], f["answered"]),
            (T["ch_f_connected"], f["connected"]),
        ]
    except Exception:
        ctx["ch"] = None
    # ring-everywhere: ring delivery success by phone brand / model / Android.
    try:
        from core import call_ack
        ctx["rd"] = call_ack.delivery_stats(24 * 7)
    except Exception:
        ctx["rd"] = None
    return page(request, "owner/calls.html", ctx, status=status, nav="calls")
