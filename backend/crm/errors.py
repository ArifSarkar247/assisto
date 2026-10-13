"""CRM error reference codes — real ref-code ↔ server-log correlation.

Every CRM failure the client can see carries a short 6-char REFERENCE CODE. The
*same* code is written to the server log at WARNING/ERROR alongside the
exception and request context, so when a user reports "CRM couldn't load, code
7FK2Q9" support can grep the log for that exact code and find the stack/context.

Two entry points:

  * `ref_code()` + `log_ref(code, ...)` — low-level, for views that build their
    own JSON error envelope.
  * `crm_exception_handler` — a DRF `EXCEPTION_HANDLER` wrapper that catches any
    unhandled/raised exception inside a CRM view, logs it with a fresh ref code,
    and injects `ref` into the JSON response body. Wire it per-view via
    `get_exception_handler` (so it never changes behaviour for non-CRM apps).
"""
import logging
import secrets

from rest_framework.views import exception_handler as drf_exception_handler

logger = logging.getLogger("crm.errors")

# Unambiguous alphabet (no 0/O/1/I) so a user can read the code back over phone.
_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"


def ref_code():
    """A fresh 6-char reference code."""
    return "".join(secrets.choice(_ALPHABET) for _ in range(6))


def log_ref(code, message, *, request=None, exc=None, level=logging.WARNING):
    """Write `code` + context + (optional) exception to the server log so support
    can match the code the user sees. Returns the code for convenience."""
    who = "anon"
    path = "-"
    if request is not None:
        user = getattr(request, "user", None)
        who = getattr(user, "id", None) or "anon"
        path = f"{request.method} {request.get_full_path()}"
    logger.log(
        level, "CRM ref=%s user=%s path=%s :: %s", code, who, path, message,
        exc_info=exc if exc is not None else False,
    )
    return code


def crm_exception_handler(exc, context):
    """DRF exception handler for CRM views. Logs a ref code + the exception, then
    folds `ref` into the response body so the client can surface it. Falls back
    to a clean 500 envelope (still with a ref) for errors DRF won't format."""
    request = context.get("request")
    response = drf_exception_handler(exc, context)
    code = ref_code()
    # 5xx (and anything DRF didn't format) carries the exception into the log so
    # support can see the stack; 4xx (validation/permission) logs at WARNING.
    is_server_error = response is None or response.status_code >= 500
    log_ref(
        code,
        f"{exc.__class__.__name__}: {exc}",
        request=request,
        exc=exc if is_server_error else None,
        level=logging.ERROR if is_server_error else logging.WARNING,
    )
    if response is None:
        # Unhandled: build an honest 500 envelope (never leak the raw trace).
        from rest_framework.response import Response
        return Response(
            {"detail": "সার্ভার সমস্যা / Something went wrong on our side",
             "ref": code},
            status=500,
        )
    data = response.data
    if isinstance(data, dict):
        data.setdefault("ref", code)
    else:
        response.data = {"detail": data, "ref": code}
    return response
