"""sosat — the SOS escalation ladder (pure, no DB). Mirrored in
app/lib/services/sos_ladder.dart (keep in sync; both are unit-tested).

After an SOS the sender's screen must always say honestly WHERE the alert is
and WHAT TO DO NEXT. Stages, in order:

  none          no SOS in the last LADDER_WINDOW_S
  no_one        the SOS reached nobody (no accepted circle member with the
                app) -> call / SMS your emergency numbers, 999
  waiting       sent, nobody has opened it yet, < RERING_AFTER_S
  rerung        nobody opened it after RERING_AFTER_S -> the server rang every
                silent phone once more; you should call / SMS now
  call_999      still nobody after SUGGEST_999_AFTER_S -> suggest 999 (the
                user taps; Assisto never dials by itself)
  seen          at least one person opened it (they know) — keep the line open
  resolved      the sender pressed "I'm safe now"
"""

LADDER_WINDOW_S = 30 * 60
RERING_AFTER_S = 120
SUGGEST_999_AFTER_S = 300

DELIVERED = ("sent", "held")


def stage(recipients, age_s, resolved=False):
    """recipients: [{"status", "received", "seen"}]; age_s: seconds since the
    SOS (None = no SOS in the window)."""
    if age_s is None or age_s > LADDER_WINDOW_S:
        return "none"
    if resolved:
        return "resolved"
    rs = list(recipients or [])
    if any(r.get("seen") for r in rs):
        return "seen"
    reachable = [r for r in rs if r.get("status") in DELIVERED or r.get("received")]
    if not reachable:
        return "no_one"
    if age_s >= SUGGEST_999_AFTER_S:
        return "call_999"
    if age_s >= RERING_AFTER_S:
        return "rerung"
    return "waiting"


def counts(recipients):
    rs = list(recipients or [])
    return {"total": len(rs),
            "received": sum(1 for r in rs if r.get("received") or r.get("seen")),
            "seen": sum(1 for r in rs if r.get("seen"))}


def needs_rering(status, seen, age_s, rerung):
    """Server sweep: ring a still-unopened SOS once more."""
    return (status == "sent" and not seen and not rerung
            and RERING_AFTER_S <= age_s <= LADDER_WINDOW_S)
