"""website v3: line icons (24-unit grid, 1.8 stroke, currentColor). Drawn for
this site; each page inlines only the symbols it uses (one <svg> sprite)."""
from django.utils.html import format_html_join
from django.utils.safestring import mark_safe

_P = {
    "sparkle": '<path d="M12 3l1.8 4.9L19 9.7l-5.2 1.8L12 16.5l-1.8-5L5 9.7l5.2-1.8z"/><path d="M19 15l.7 1.8 1.8.7-1.8.7-.7 1.8-.7-1.8-1.8-.7 1.8-.7z"/>',
    "message": '<path d="M4 5h16v11H9l-5 4z"/><path d="M8 9.5h8M8 12.5h5"/>',
    "chat": '<path d="M3 6h12v8H8l-4 3V6z"/><path d="M15 9h6v8l-3-2h-6v-1"/>',
    "mic": '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5.5 11a6.5 6.5 0 0013 0M12 17.5V21M9 21h6"/>',
    "sunrise": '<path d="M3 18h18M6.5 18a5.5 5.5 0 0111 0M12 4v4M4.6 9.6l2 2M19.4 9.6l-2 2M8.5 21h7"/>',
    "sun": '<circle cx="12" cy="12" r="4"/><path d="M12 2.5v2.5M12 19v2.5M2.5 12H5M19 12h2.5M5.3 5.3l1.8 1.8M16.9 16.9l1.8 1.8M5.3 18.7l1.8-1.8M16.9 7.1l1.8-1.8"/>',
    "bell": '<path d="M6 16V11a6 6 0 0112 0v5l1.5 2h-15z"/><path d="M10 20.5a2.2 2.2 0 004 0"/>',
    "brain": '<path d="M9 4a3 3 0 00-3 3 3 3 0 00-2 5 3 3 0 002 5 3 3 0 006 1V5a2 2 0 00-3-1zM15 4a3 3 0 013 3 3 3 0 012 5 3 3 0 01-2 5 3 3 0 01-6 1"/>',
    "user-tie": '<circle cx="12" cy="7" r="3.5"/><path d="M4.5 21a7.5 7.5 0 0115 0M12 13.5l-1.2 2 1.2 4 1.2-4z"/>',
    "inbox": '<path d="M3 13l3-8h12l3 8v6H3z"/><path d="M3 13h5l1.5 2.5h5L16 13h5"/>',
    "route": '<circle cx="6" cy="18" r="2.5"/><circle cx="18" cy="6" r="2.5"/><path d="M8.5 18H15a3 3 0 000-6H9a3 3 0 010-6h6.5"/>',
    "image": '<rect x="3" y="4" width="18" height="16" rx="2.5"/><circle cx="9" cy="9.5" r="1.8"/><path d="M3.5 18l5.5-5.5 4 4 3-3 4.5 4.5"/>',
    "video": '<rect x="2.5" y="6" width="13" height="12" rx="2.5"/><path d="M15.5 10.5l6-3.5v10l-6-3.5"/>',
    "pip": '<rect x="2.5" y="4" width="19" height="15" rx="2.5"/><rect x="12" y="11" width="7" height="5.5" rx="1.2"/>',
    "bubble": '<circle cx="9" cy="10" r="6"/><circle cx="18" cy="17" r="3.5"/><path d="M6.5 10h5"/>',
    "circle-dot": '<circle cx="12" cy="12" r="9" stroke-dasharray="4 2.5"/><circle cx="12" cy="12" r="4"/>',
    "megaphone": '<path d="M3 10v4h3l9 5V5L6 10z"/><path d="M18.5 9a4 4 0 010 6M7 14.5l1.5 5h2.5l-1-4.5"/>',
    "sos": '<circle cx="12" cy="12" r="9"/><path d="M12 7.5v5.5M12 16.2v.3"/>',
    "alarm": '<circle cx="12" cy="13" r="7"/><path d="M12 9.5V13l2.5 2M4 5l3-2.5M20 5l-3-2.5"/>',
    "train": '<rect x="5" y="3" width="14" height="14" rx="3"/><path d="M5 11h14M9 14.5h.01M15 14.5h.01M8 21l2-4M16 21l-2-4"/>',
    "family": '<circle cx="8" cy="7" r="3"/><circle cx="17" cy="9" r="2.3"/><path d="M2.5 20a5.5 5.5 0 0111 0M13.5 20a3.8 3.8 0 017.5 0"/>',
    "child": '<circle cx="12" cy="6" r="3"/><path d="M7 12l5-2 5 2M12 10v6M9 21l3-5 3 5"/>',
    "watch": '<rect x="6" y="6.5" width="12" height="11" rx="3"/><path d="M8.5 6.5L9 3h6l.5 3.5M8.5 17.5L9 21h6l.5-3.5M12 9.5V12l1.5 1.5"/>',
    "heart-hand": '<path d="M12 9.5c-1.2-2.7-5.5-2.4-5.5.8 0 2.4 3.3 4.4 5.5 6 2.2-1.6 5.5-3.6 5.5-6 0-3.2-4.3-3.5-5.5-.8z"/><path d="M3 15l3 5h7"/>',
    "phone-lock": '<rect x="6" y="2.5" width="12" height="19" rx="2.5"/><rect x="9.5" y="11" width="5" height="4" rx="1"/><path d="M10.3 11V9.6a1.7 1.7 0 013.4 0V11"/>',
    "search-person": '<circle cx="10.5" cy="10.5" r="6.5"/><path d="M15.5 15.5L21 21"/><circle cx="10.5" cy="9" r="2"/><path d="M7 14a4 4 0 017 0"/>',
    "drop": '<path d="M12 3s6 6.5 6 11a6 6 0 01-12 0c0-4.5 6-11 6-11z"/><path d="M9.5 14.5a2.5 2.5 0 002.5 2.5"/>',
    "alert": '<path d="M12 3l9.5 17h-19z"/><path d="M12 10v4.5M12 17.3v.2"/>',
    "cloud": '<path d="M7 18a4.5 4.5 0 01-.6-9 6 6 0 0111.5 1.5A3.8 3.8 0 0117.5 18z"/><path d="M11 14l-1.5 3h3L11 20"/>',
    "key": '<circle cx="8" cy="15" r="4.5"/><path d="M11.2 11.8L20 3M16.5 6.5l2.5 2.5M14 9l2 2"/>',
    "fall": '<circle cx="15" cy="5" r="2.2"/><path d="M13 8l-4 5 4 2-2 6M9 13l-5 1M3 21h18"/>',
    "phone-cam": '<rect x="6" y="2.5" width="12" height="19" rx="2.5"/><circle cx="12" cy="10" r="3"/><path d="M10.5 18h3"/>',
    "camera": '<path d="M3 8h4l2-3h6l2 3h4v12H3z"/><circle cx="12" cy="13.5" r="3.8"/>',
    "eye": '<path d="M2 12s3.6-6.5 10-6.5S22 12 22 12s-3.6 6.5-10 6.5S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>',
    "file-check": '<path d="M6 2.5h8l5 5V21.5H6z"/><path d="M14 2.5v5h5M9 14.5l2 2 4-4.5"/>',
    "file": '<path d="M6 2.5h8l5 5V21.5H6z"/><path d="M14 2.5v5h5M9 13h6M9 16.5h6"/>',
    "cash": '<rect x="2.5" y="6" width="19" height="12" rx="2"/><circle cx="12" cy="12" r="2.8"/><path d="M6 9.5v5M18 9.5v5"/>',
    "shield": '<path d="M12 2.5l8 3v6c0 5-3.5 8.7-8 10-4.5-1.3-8-5-8-10v-6z"/><path d="M8.5 12l2.5 2.5 4.5-5"/>',
    "book": '<path d="M4 4.5A2 2 0 016 2.5h13v16H6a2 2 0 00-2 2z"/><path d="M4 20.5a2 2 0 002 1h13M8 7h7M8 10.5h5"/>',
    "ledger": '<rect x="4" y="2.5" width="16" height="19" rx="2"/><path d="M12 2.5v19M7 7h2.5M7 10.5h2.5M14.5 7H17M14.5 10.5H17"/>',
    "chart": '<path d="M3 3v18h18"/><path d="M7 15l4-4 3 3 6-7"/>',
    "receipt": '<path d="M5 2.5h14v19l-2.3-1.5-2.4 1.5-2.3-1.5-2.3 1.5-2.4-1.5L5 21.5z"/><path d="M8.5 7.5h7M8.5 11h7M8.5 14.5h4"/>',
    "bot": '<rect x="4" y="7.5" width="16" height="12" rx="3"/><path d="M12 3.5v4M9 13h.01M15 13h.01M9.5 16.5h5M2 12.5v3M22 12.5v3"/>',
    "users": '<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20a6.5 6.5 0 0113 0"/><path d="M16 4.6a3.5 3.5 0 010 6.8M18 14a6.5 6.5 0 013.5 6"/>',
    "repeat": '<path d="M17 2.5l3 3-3 3"/><path d="M4 11.5v-2a4 4 0 014-4h12M7 21.5l-3-3 3-3"/><path d="M20 12.5v2a4 4 0 01-4 4H4"/>',
    "store": '<path d="M3.5 9.5L5 3.5h14l1.5 6"/><path d="M3.5 9.5a2.8 2.8 0 005.6 0 2.8 2.8 0 005.8 0 2.8 2.8 0 005.6 0M5 11.5v9.5h14v-9.5M10 21v-5.5h4V21"/>',
    "calendar": '<rect x="3" y="4.5" width="18" height="16.5" rx="2.5"/><path d="M3 9.5h18M8 2.5v4M16 2.5v4M7.5 13.5h3v3h-3z"/>',
    "check": '<rect x="3" y="3" width="18" height="18" rx="3"/><path d="M7.5 12.5l3 3 6-6.5"/>',
    "briefcase": '<rect x="2.5" y="7" width="19" height="13.5" rx="2.5"/><path d="M8.5 7V4.5h7V7M2.5 12.5h19"/>',
    "pen": '<path d="M15 4.5l4.5 4.5L8.5 20H4v-4.5z"/><path d="M13 6.5l4.5 4.5"/>',
    "calc": '<rect x="5" y="2.5" width="14" height="19" rx="2.5"/><path d="M8 6.5h8v3H8zM8.5 13h.01M12 13h.01M15.5 13h.01M8.5 17h.01M12 17h.01M15.5 17h.01"/>',
    "scan": '<path d="M3 8V5a2 2 0 012-2h3M16 3h3a2 2 0 012 2v3M21 16v3a2 2 0 01-2 2h-3M8 21H5a2 2 0 01-2-2v-3M7 12h10"/>',
    "grid": '<rect x="3" y="3" width="7.5" height="7.5" rx="1.5"/><rect x="13.5" y="3" width="7.5" height="7.5" rx="1.5"/><rect x="3" y="13.5" width="7.5" height="7.5" rx="1.5"/><rect x="13.5" y="13.5" width="7.5" height="7.5" rx="1.5"/>',
    "apps": '<rect x="3" y="3" width="7.5" height="7.5" rx="2"/><rect x="13.5" y="3" width="7.5" height="7.5" rx="2"/><rect x="3" y="13.5" width="7.5" height="7.5" rx="2"/><path d="M17.25 13.5v7.5M13.5 17.25H21"/>',
    "note": '<path d="M5 3h14v12l-6 6H5z"/><path d="M13 21v-6h6M8.5 8h7M8.5 11.5h5"/>',
    "cake": '<path d="M4 21v-8a2 2 0 012-2h12a2 2 0 012 2v8M3 21h18M4 15.5c1.5 1.3 3 1.3 4 0 1 1.3 3 1.3 4 0 1 1.3 3 1.3 4 0 1 1.3 2.5 1.3 4 0M12 11V7.5"/><path d="M12 3.5c.8 1 .8 2.2 0 3-.8-.8-.8-2 0-3z"/>',
    "wallet": '<path d="M4 6.5h14a2 2 0 012 2v11H5a2 2 0 01-2-2V5.5a2 2 0 012-2h11v3"/><path d="M15.5 13.5h4.5v-3h-4.5a1.5 1.5 0 000 3z"/>',
    "pie": '<path d="M12 3v9h9A9 9 0 1112 3z"/><path d="M15 3.5a8.5 8.5 0 015.5 5.5H15z"/>',
    "spark-card": '<rect x="4" y="2.5" width="16" height="19" rx="3"/><path d="M12 7l1.2 3.3 3.3 1.2-3.3 1.2L12 16l-1.2-3.3L7.5 11.5l3.3-1.2z"/>',
    "percent": '<path d="M19 5L5 19"/><circle cx="7" cy="7" r="2.5"/><circle cx="17" cy="17" r="2.5"/>',
    "split": '<path d="M12 21v-7L5 7M12 14l7-7M5 12V7h5M19 12V7h-5"/>',
    "home": '<path d="M3 11l9-7.5 9 7.5"/><path d="M5 9.5V21h14V9.5M10 21v-6h4v6"/>',
    "building": '<rect x="4" y="2.5" width="16" height="19" rx="1.5"/><path d="M8 6.5h2M14 6.5h2M8 10.5h2M14 10.5h2M8 14.5h2M14 14.5h2M10.5 21.5v-3h3v3"/>',
    "bolt": '<path d="M13.5 2.5L5 13.5h6l-1 8 8.5-11h-6z"/>',
    "globe": '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c2.5 2.6 3.8 5.6 3.8 9s-1.3 6.4-3.8 9c-2.5-2.6-3.8-5.6-3.8-9S9.5 5.6 12 3z"/>',
    "lock": '<rect x="4.5" y="10.5" width="15" height="11" rx="2.5"/><path d="M8 10.5V7.5a4 4 0 018 0v3M12 14.5v3"/>',
    "car": '<path d="M3.5 16.5v-4l2-5.5h13l2 5.5v4z"/><path d="M3.5 12.5h17M7 19.5v-3M17 19.5v-3"/><circle cx="7.5" cy="14.5" r=".6"/><circle cx="16.5" cy="14.5" r=".6"/>',
    "compass": '<circle cx="12" cy="12" r="9"/><path d="M15.5 8.5l-2 5-5 2 2-5z"/>',
    "school": '<path d="M2.5 9L12 4.5 21.5 9 12 13.5z"/><path d="M6.5 11v5c3 2.3 8 2.3 11 0v-5M21.5 9v6"/>',
    "bike": '<circle cx="5.5" cy="16.5" r="3.5"/><circle cx="18.5" cy="16.5" r="3.5"/><path d="M5.5 16.5l4-7h6l3 7M9.5 9.5L12 16.5h3M14 6h3"/>',
    "moon": '<path d="M20 14.5A8.5 8.5 0 019.5 4a8.5 8.5 0 1010.5 10.5z"/>',
    "tag": '<path d="M3 3h8l10 10-8 8L3 11z"/><circle cx="7.5" cy="7.5" r="1.5"/>',
    "map": '<path d="M3 6l6-2.5 6 2.5 6-2.5V18l-6 2.5-6-2.5-6 2.5z"/><path d="M9 3.5V18M15 6v14.5"/>',
    "leaf": '<path d="M5 19c0-8 5-14 15-14 0 10-6 15-14 15"/><path d="M5 19c3-4 6-6.5 10-8.5"/>',
    "rings": '<circle cx="9" cy="14" r="5.5"/><circle cx="15" cy="14" r="5.5"/><path d="M10 4.5l2-2 2 2-2 2z"/>',
    "steps": '<path d="M7 3.5c2 0 3 2 3 4.5S9 12 7 12 4 10.5 4 8s1-4.5 3-4.5zM17 9.5c2 0 3 2 3 4.5s-1 4-3 4-3-1.5-3-4 1-4.5 3-4.5zM5 15h4M15 21h4"/>',
    "arrow": '<path d="M5 12h14M13 6l6 6-6 6"/>',
    "play": '<path d="M5 3.5l14 8.5-14 8.5z"/>',
    "pause": '<path d="M8 5v14M16 5v14"/>',
}


def sprite(names):
    """One hidden <svg> holding only the symbols used on this page."""
    want = [n for n in sorted(set(names)) if n in _P]
    body = format_html_join("", '<symbol id="i-{}" viewBox="0 0 24 24">{}</symbol>',
                            ((n, mark_safe(_P[n])) for n in want))
    return mark_safe('<svg xmlns="http://www.w3.org/2000/svg" width="0" height="0" style="position:absolute" aria-hidden="true">'
                     + body + "</svg>")


def known(name):
    return name in _P
