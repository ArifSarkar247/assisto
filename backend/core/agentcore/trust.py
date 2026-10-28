"""Trust layer: masking vault, sealing at rest, approvals, audit trail.

Masking (before ANY AI call): Bangladeshi mobile numbers, NID numbers (10/13/
17 digits), bank / card / wallet account numbers (11-19 digits, spaces or
dashes allowed) and e-mail addresses — in Latin OR Bangla digits — become
reversible tokens like ⟦PHONE_1⟧. The token -> original map (the vault) is
Fernet-sealed on the run, server-side only; the same value gets the same
token for the whole run, so a plan can refer to ⟦PHONE_1⟧ and the server puts
the real number back before a tool runs. The audit trail and Owner Admin only
ever see masked text.
"""
import json
import re
from datetime import timedelta

from django.utils import timezone

D = "[0-9০-৯]"
_PATTERNS = (
    ("EMAIL", re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")),
    # BD mobile: optional +88 / 88, then 01[3-9] + 8 digits (one separator ok)
    ("PHONE", re.compile(r"(?<![0-9০-৯])(?:\+?(?:88|৮৮)[ -]?)?[0০][1১][3-9৩-৯]%s{2}[ -]?%s{6}(?![0-9০-৯])"
                         % (D, D))),
    # NID: exactly 10, 13 or 17 contiguous digits
    ("NID", re.compile(r"(?<![0-9০-৯])(?:%s{17}|%s{13}|%s{10})(?![0-9০-৯])" % (D, D, D))),
    # account / card numbers: 11-19 digits, single spaces or dashes between
    ("ACCT", re.compile(r"(?<![0-9০-৯])%s(?:[ -]?%s){10,18}(?![0-9০-৯])" % (D, D))),
)
TOKEN_RX = re.compile(r"⟦(EMAIL|PHONE|NID|ACCT)_([0-9০-৯]+)⟧")
_BN_DIGITS = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")


class Vault:
    """token <-> original for one run. `kinds` (maskall) limits masking to
    some kinds, e.g. Vault(kinds=("PHONE", "EMAIL")) for the bill reader,
    which must read the account number itself."""
    def __init__(self, data=None, kinds=None):
        data = data or {}
        self.kinds = tuple(kinds) if kinds else None
        self.t2v = dict(data.get("t2v") or {})
        self.n = dict(data.get("n") or {})
        self.v2t = {v: t for t, v in self.t2v.items()}

    def to_json(self):
        return {"t2v": self.t2v, "n": self.n}

    def _token(self, kind, value):
        if value in self.v2t:
            return self.v2t[value]
        self.n[kind] = int(self.n.get(kind, 0)) + 1
        tok = "⟦%s_%d⟧" % (kind, self.n[kind])
        self.t2v[tok] = value
        self.v2t[value] = tok
        return tok

    def mask(self, text):
        if not isinstance(text, str) or not text:
            return text
        out = text
        for kind, rx in _PATTERNS:
            if self.kinds is not None and kind not in self.kinds:
                continue
            out = rx.sub(lambda m, k=kind: self._token(k, m.group(0)), out)
        return out

    def unmask(self, text):
        if not isinstance(text, str) or "⟦" not in text:
            return text
        # AF-2: a provider answer turned to Bangla digits (digits="bn") carries
        # ⟦PHONE_১⟧ — still our token
        return TOKEN_RX.sub(lambda m: self.t2v.get(
            "⟦%s_%s⟧" % (m.group(1), m.group(2).translate(_BN_DIGITS)), m.group(0)), text)

    def mask_request(self, task="", data="", history=None, extra_system=""):
        """AF-2: mask EVERY text part of one AI-router request with this vault
        (the same value -> the same token across task, data and history), so
        no raw phone / NID / account / e-mail reaches a provider. Returns
        (task, data, history, extra_system)."""
        hist = None
        if history:
            hist = []
            for h in history:
                if isinstance(h, dict):
                    h = dict(h, content=self.mask_obj(h.get("content")))
                hist.append(h)
        return self.mask(task), self.mask(data), hist, self.mask(extra_system)

    def mask_obj(self, obj):
        return _walk(obj, self.mask)

    def unmask_obj(self, obj):
        return _walk(obj, self.unmask)


def _walk(obj, fn):
    if isinstance(obj, str):
        return fn(obj)
    if isinstance(obj, dict):
        return {k: _walk(v, fn) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [_walk(v, fn) for v in obj]
    return obj


def leftover_tokens(text):
    """AF-2: vault tokens still in a text after unmask (the model invented or
    damaged one) — such a reply is never sent to a customer as is."""
    return [m.group(0) for m in TOKEN_RX.finditer(text or "")] if isinstance(text, str) else []


def has_raw_pii(text, kinds=None):
    """True when `text` still contains an unmasked phone/NID/account/email
    (only the given `kinds` when set)."""
    if not isinstance(text, str):
        text = json.dumps(text, ensure_ascii=False, default=str)
    return any(rx.search(text) for k, rx in _PATTERNS if kinds is None or k in kinds)


# ------------------------------------------------------------------ sealing
def seal(data):
    from .. import remittance_service as RS     # shared finance MultiFernet
    return RS.seal(data)


def unseal(blob):
    from .. import remittance_service as RS
    return RS.unseal(blob) if blob else {}


def vault_of(run):
    return Vault(unseal(run.vault_sealed))


def save_vault(run, vault):
    run.vault_sealed = seal(vault.to_json())


# ------------------------------------------------------------------ audit
def audit(run, event, step=None, credits=0, **detail):
    """Append one MASKED event (callers pass masked detail only)."""
    from ..models import AgentAuditEvent
    return AgentAuditEvent.objects.create(
        user_id=run.user_id, run=run, step=step, event=event[:40],
        detail=detail, credits=int(credits or 0))


# ------------------------------------------------------------------ approvals
APPROVAL_TTL = timedelta(hours=48)


def request_approval(run, step, tool, masked_args, title_bn, title_en):
    from ..models import AgentApproval
    summary = json.dumps(masked_args, ensure_ascii=False, default=str)[:400]
    ap, _ = AgentApproval.objects.get_or_create(
        step=step, defaults=dict(
            run=run, user_id=run.user_id, risk=tool.risk, title_bn=title_bn[:200],
            title_en=title_en[:200], summary=summary,
            expires_at=timezone.now() + APPROVAL_TTL))
    audit(run, "approval.requested", step=step, tool=tool.ref, risk=tool.risk,
          approval=ap.pk)
    return ap
