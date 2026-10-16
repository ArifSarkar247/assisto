import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';

/// NOTIFICATION CENTRE — pure data models + localisation helpers.
///
/// No Bangla string literals live here: dynamic bn/en text comes from the API
/// as {"bn","en"} pairs (rendered by [pickText]); static UI labels come from
/// [AppLocalizations]; digits are localised via codepoints in [notifLocaleNum].

// ---------------------------------------------------------------------------
// Localised text / numbers
// ---------------------------------------------------------------------------

/// Render the active-language side of a dynamic value that the API may send as
/// a `{"bn": ..., "en": ...}` pair OR as an already-picked plain String.
String pickText(BuildContext context, Object? value) {
  final isBn = Localizations.localeOf(context).languageCode == 'bn';
  if (value == null) return '';
  if (value is String) return value;
  if (value is Map) {
    final primary = value[isBn ? 'bn' : 'en'];
    if (primary != null && '$primary'.isNotEmpty) return '$primary';
    final fallback = value[isBn ? 'en' : 'bn'];
    if (fallback != null) return '$fallback';
  }
  return '$value';
}

/// Western digits in [s] -> Bangla digits when locale is bn. Codepoints only
/// (no Bangla glyphs in source).
String notifLocalizeDigits(BuildContext context, String s) {
  final isBn = Localizations.localeOf(context).languageCode == 'bn';
  if (!isBn) return s;
  const zeroBn = 0x09E6; // Bengali digit zero
  final buf = StringBuffer();
  for (final r in s.runes) {
    if (r >= 0x30 && r <= 0x39) {
      buf.writeCharCode(zeroBn + (r - 0x30));
    } else {
      buf.writeCharCode(r);
    }
  }
  return buf.toString();
}

/// Human "when" for an ISO instant: today -> time (3:40 PM), this week ->
/// weekday + time, else short date. Digits localised. Never throws.
String notifWhen(BuildContext context, String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final dt = DateTime.tryParse(iso)?.toLocal();
  if (dt == null) return '';
  final now = DateTime.now();
  DateTime d0(DateTime d) => DateTime(d.year, d.month, d.day);
  final days = d0(dt).difference(d0(now)).inDays;
  // Localise weekday/month/AM-PM too (not just digits): in Bangla mode an
  // unlocalised DateFormat leaks "Wed"/"PM". bn locale data is loaded app-wide.
  final loc = Localizations.localeOf(context).languageCode;
  String raw;
  if (days == 0) {
    raw = DateFormat.jm(loc).format(dt);
  } else if (days == 1) {
    raw = DateFormat.jm(loc).format(dt); // tomorrow — label added by caller
  } else if (days.abs() < 7) {
    raw = '${DateFormat.E(loc).format(dt)} ${DateFormat.jm(loc).format(dt)}';
  } else {
    raw = DateFormat.MMMd(loc).format(dt);
  }
  return notifLocalizeDigits(context, raw);
}

/// Relative "ago" for feed events (just now / Nm / Nh / Nd / date).
String notifAgo(BuildContext context, String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final dt = DateTime.tryParse(iso)?.toLocal();
  if (dt == null) return '';
  final diff = DateTime.now().difference(dt);
  final t = AppLocalizations.of(context);
  String raw;
  if (diff.inMinutes < 1) {
    return t.notifJustNow;
  } else if (diff.inMinutes < 60) {
    raw = t.notifMinutesAgo('${diff.inMinutes}');
  } else if (diff.inHours < 24) {
    raw = t.notifHoursAgo('${diff.inHours}');
  } else if (diff.inDays < 7) {
    raw = t.notifDaysAgo('${diff.inDays}');
  } else {
    raw = DateFormat.MMMd().format(dt);
  }
  return notifLocalizeDigits(context, raw);
}

// ---------------------------------------------------------------------------
// Reminder model
// ---------------------------------------------------------------------------

enum ReminderSection { today, upcoming, missed }

class NotifReminder {
  final String id;
  final Object? title; // {bn,en} | String
  final String? whenIso;
  final String? route;
  final String? module;
  final bool done;

  NotifReminder({
    required this.id,
    this.title,
    this.whenIso,
    this.route,
    this.module,
    this.done = false,
  });

  factory NotifReminder.fromJson(Map m) => NotifReminder(
        id: '${m['id']}',
        title: m['title'],
        whenIso: m['when'] as String?,
        route: m['route'] as String?,
        module: m['module'] as String?,
        done: m['done'] == true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'when': whenIso,
        'route': route,
        'module': module,
        'done': done,
      };
}

// ---------------------------------------------------------------------------
// Feed-event model
// ---------------------------------------------------------------------------

/// Canonical feed event types. The backend `type` string maps here; anything
/// unknown falls back to [NotifType.other].
enum NotifType {
  circle,
  community,
  channel,
  family,
  scam,
  watch,
  business,
  crm,
  security,
  plan,
  points,
  update,
  other,
}

NotifType notifTypeFrom(String? s) {
  switch (s) {
    case 'circle':
    case 'circle_request':
    case 'circle_activity':
      return NotifType.circle;
    case 'community':
    case 'community_request':
      return NotifType.community;
    case 'channel':
      return NotifType.channel;
    case 'family':
    case 'family_alert':
      return NotifType.family;
    case 'scam':
      return NotifType.scam;
    case 'watch':
    case 'watch_feed':
      return NotifType.watch;
    case 'business':
    case 'crm_business':
      return NotifType.business;
    case 'crm':
      return NotifType.crm;
    case 'security':
    case 'new_device':
      return NotifType.security;
    case 'plan':
      return NotifType.plan;
    case 'points':
    case 'reward':
      return NotifType.points;
    case 'update':
    case 'app_update':
      return NotifType.update;
    default:
      return NotifType.other;
  }
}

/// Icon + accent colour for a feed type (brand-aligned, high contrast).
({IconData icon, Color tint}) notifTypeVisual(
    NotifType type, ColorScheme scheme) {
  switch (type) {
    case NotifType.circle:
      return (icon: Icons.group_outlined, tint: Brand.blue);
    case NotifType.community:
      return (icon: Icons.groups_2_outlined, tint: Brand.purple);
    case NotifType.channel:
      return (icon: Icons.campaign_outlined, tint: Brand.cyan);
    case NotifType.family:
      return (icon: Icons.favorite_outline, tint: Brand.danger);
    case NotifType.scam:
      return (icon: Icons.gpp_maybe_outlined, tint: Brand.warning);
    case NotifType.watch:
      return (icon: Icons.visibility_outlined, tint: Brand.blue);
    case NotifType.business:
      return (icon: Icons.storefront_outlined, tint: Brand.purple);
    case NotifType.crm:
      return (icon: Icons.handshake_outlined, tint: Brand.blue);
    case NotifType.security:
      return (icon: Icons.security_outlined, tint: Brand.danger);
    case NotifType.plan:
      return (icon: Icons.workspace_premium_outlined, tint: Brand.cyan);
    case NotifType.points:
      return (icon: Icons.stars_outlined, tint: Brand.warning);
    case NotifType.update:
      return (icon: Icons.system_update_outlined, tint: scheme.primary);
    case NotifType.other:
      return (icon: Icons.notifications_none, tint: scheme.primary);
  }
}

/// Localised filter-chip label for a type.
String notifTypeLabel(AppLocalizations t, NotifType type) {
  switch (type) {
    case NotifType.circle:
      return t.notifTypeCircle;
    case NotifType.community:
      return t.notifTypeCommunity;
    case NotifType.channel:
      return t.notifTypeChannel;
    case NotifType.family:
      return t.notifTypeFamily;
    case NotifType.scam:
      return t.notifTypeScam;
    case NotifType.watch:
      return t.notifTypeWatch;
    case NotifType.business:
      return t.notifTypeBusiness;
    case NotifType.crm:
      return t.notifTypeCrm;
    case NotifType.security:
      return t.notifTypeSecurity;
    case NotifType.plan:
      return t.notifTypePlan;
    case NotifType.points:
      return t.notifTypePoints;
    case NotifType.update:
      return t.notifTypeUpdate;
    case NotifType.other:
      return t.notifTypeOther;
  }
}

class NotifEvent {
  final String id;
  final NotifType type;
  final Object? title; // {bn,en} | String
  final Object? body; // {bn,en} | String
  final String? timeIso;
  final String? route;
  bool seen;

  NotifEvent({
    required this.id,
    required this.type,
    this.title,
    this.body,
    this.timeIso,
    this.route,
    this.seen = false,
  });

  factory NotifEvent.fromJson(Map m) => NotifEvent(
        id: '${m['id']}',
        type: notifTypeFrom(m['type'] as String?),
        title: m['title'],
        body: m['body'],
        timeIso: m['time'] as String?,
        route: m['route'] as String?,
        seen: m['seen'] == true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': _typeKey(type),
        'title': title,
        'body': body,
        'time': timeIso,
        'route': route,
        'seen': seen,
      };
}

String _typeKey(NotifType t) => t.name;

// ---------------------------------------------------------------------------
// Offline cache (SharedPreferences via Settings). Last fetched payloads are
// stored verbatim so an offline open renders the saved view instantly.
// ---------------------------------------------------------------------------

class NotifCache {
  static const remindersKey = 'notif_reminders_cache_v1';
  static const feedKey = 'notif_feed_cache_v1';

  static String encode(Object payload) => jsonEncode(payload);

  static Map<String, dynamic>? decodeMap(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final v = jsonDecode(raw);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }
}
