"""
app_update.py — pure, dependency-free version-compare helper for the in-app
updater (#180, §21).

The Flutter app already reports the *latest* installable build via
`GET /app/latest` (fed by publish-apk.sh -> {version_code, version_name,
apk_url, notes}). This module turns the raw "latest" record plus the running
app's version into the honest decision payload the update surface renders:

    {latest, current, update_available, changelog, url}

Design rules (§21, honest states):
  * No network, no Django, no I/O — pure functions, stdlib only, so the
    snippet tests run with `python app_update.py`.
  * NEVER signals "update available" on ambiguous input. If we cannot
    confidently decide that the latest build is strictly newer than the
    running build, `update_available` is False (fail-closed — we would
    rather miss a prompt than nag a user who is already current).
  * The app never auto-downloads/auto-installs; this helper only returns the
    `url` for a user-initiated tap. `url` is "" unless an update is available
    AND a usable http(s) link was provided.
"""

import re

# A dotted version string: 1, 1.0, 1.2.3, 10.4.11 ... up to a few segments.
# Pre-release/build suffixes (e.g. "1.2.3-beta2") are tolerated: we compare the
# numeric core and treat a dangling suffix as NOT part of the ordering (so
# "1.2.3" and "1.2.3-beta" compare equal on the numeric core — fail-closed).
_NUM_CORE = re.compile(r"^\s*v?(\d+(?:\.\d+)*)")


def parse_version(value):
    """Return a tuple of ints for the numeric core of *value*, or None.

    Accepts an int/str. Leading 'v' and surrounding whitespace are ignored.
    A trailing non-numeric suffix (e.g. '-beta', '+build7') is dropped.
    Returns None when no numeric core can be found (so callers fail closed).
    """
    if value is None:
        return None
    if isinstance(value, int):
        return (value,) if value >= 0 else None
    if not isinstance(value, str):
        value = str(value)
    m = _NUM_CORE.match(value)
    if not m:
        return None
    try:
        return tuple(int(p) for p in m.group(1).split("."))
    except ValueError:  # pragma: no cover - regex guarantees digits
        return None


def _pad(a, b):
    """Right-pad the shorter tuple with zeros so 1.2 == 1.2.0."""
    n = max(len(a), len(b))
    return a + (0,) * (n - len(a)), b + (0,) * (n - len(b))


def compare_versions(current, latest):
    """-1 if current < latest, 0 if equal/indeterminate, 1 if current > latest.

    Indeterminate inputs (either side unparseable) return 0 (fail-closed:
    callers treat 0 as "no update").
    """
    c = parse_version(current)
    l = parse_version(latest)
    if c is None or l is None:
        return 0
    c, l = _pad(c, l)
    if c < l:
        return -1
    if c > l:
        return 1
    return 0


def _clean_url(url):
    """Return a safe http(s) url string, or '' if not usable."""
    if not isinstance(url, str):
        return ""
    url = url.strip()
    if url.lower().startswith(("http://", "https://")):
        return url
    return ""


def _clean_changelog(notes):
    """Normalise changelog text to a trimmed string ('' when absent)."""
    if notes is None:
        return ""
    if not isinstance(notes, str):
        notes = str(notes)
    return notes.strip()


def check_update(current_version, latest_record):
    """Build the update-decision payload for the in-app updater.

    Parameters
    ----------
    current_version : str|int
        The running app's version (e.g. the Flutter AppConfig.appVersionLabel
        '1.0', or an int build code).
    latest_record : dict
        The raw `GET /app/latest` record. We read, in priority order, a human
        version from 'version_name' (falling back to the numeric
        'version_code'), the download link from 'apk_url', and the changelog
        from 'notes'. Missing/garbage fields degrade honestly.

    Returns
    -------
    dict with EXACTLY these keys:
        latest            : str  — the latest version label (best-effort, may be '')
        current           : str  — the running version label (echo of input)
        update_available  : bool — True only when latest is strictly newer
        changelog         : str  — notes for the latest build ('' when none)
        url               : str  — http(s) download link, ONLY when an update
                                   is available and a usable link exists; else ''
    """
    rec = latest_record if isinstance(latest_record, dict) else {}

    current = "" if current_version is None else str(current_version).strip()

    name = rec.get("version_name")
    code = rec.get("version_code")
    # Prefer a human name; fall back to the numeric code for the label.
    if isinstance(name, str) and name.strip():
        latest = name.strip()
    elif code is not None:
        latest = str(code)
    else:
        latest = ""

    # Decide using the richest comparable pair we have. Try name-vs-name first;
    # if either side has no parseable name, fall back to code-vs-current.
    cmp = compare_versions(current, latest)
    if cmp == 0 and parse_version(latest) is None and code is not None:
        cmp = compare_versions(current, code)

    update_available = cmp < 0
    changelog = _clean_changelog(rec.get("notes"))
    url = _clean_url(rec.get("apk_url")) if update_available else ""

    return {
        "latest": latest,
        "current": current,
        "update_available": update_available,
        "changelog": changelog,
        "url": url,
    }
