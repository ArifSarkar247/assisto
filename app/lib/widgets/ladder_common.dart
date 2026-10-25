import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// Shared logic + small helpers for the advanced Payment / Auto-pay Ladder
/// module. Mirrors backend/core/logic/payment_ladder.py so the client renders
/// the same escalation decisions OFFLINE, straight off the list-endpoint shape.
///
/// HARD RULES, same as the engine:
///   * NEVER HOLD MONEY — this file custodies no balance. `kHoldsMoney` = false.
///   * NO AUTO-CHARGE — no code path moves money. `kChargesMoney` = false.
///   * KEY-GATED PAY — a `pay_key` action downgrades to `pay_manual` unless the
///     owner supplied a licensed payment key. `canExecutePay()` is the gate.
///
/// ALL money is INTEGER POISHA (1 taka = 100 poisha) — never a float, so sums /
/// comparisons never drift. Digits render Bangla via code points (no Bangla
/// literal in source — keeps the language gate strict). Every user-facing string
/// comes from AppLocalizations.

// ---------------------------------------------------------------- invariants
const bool kHoldsMoney = false; // we are not a wallet
const bool kChargesMoney = false; // nothing ever auto-charges

const kKindReceivable = 'receivable';
const kKindPayable = 'payable';

const kChannels = ['in_app', 'whatsapp_share', 'sms'];

const kReceivableActions = [
  'remind_gentle', 'remind_firm', 'final_notice', 'escalate_owner', 'pause_service',
];
const kPayableActions = [
  'heads_up', 'due_today', 'overdue', 'final_warning', 'pay_manual', 'pay_key',
];

// ---------------------------------------------------------------- money (poisha)

int takaToPoisha(String? input) {
  if (input == null) return 0;
  final cleaned = _ascii(input).replaceAll(RegExp(r'[^0-9.]'), '').trim();
  if (cleaned.isEmpty) return 0;
  final dot = cleaned.indexOf('.');
  if (dot < 0) return (int.tryParse(cleaned) ?? 0) * 100;
  final whole = int.tryParse(cleaned.substring(0, dot)) ?? 0;
  var frac = cleaned.substring(dot + 1).replaceAll('.', '');
  if (frac.length > 2) frac = frac.substring(0, 2);
  frac = frac.padRight(2, '0');
  return whole * 100 + (int.tryParse(frac) ?? 0);
}

int poishaOf(Map s, {String poishaKey = 'amount_poisha', String takaKey = 'amount'}) {
  if (s[poishaKey] != null) return int.tryParse('${s[poishaKey]}') ?? 0;
  return takaToPoisha('${s[takaKey]}');
}

int outstandingPoisha(Map debt) {
  final amount = poishaOf(debt);
  final paid = poishaOf(debt, poishaKey: 'paid_poisha', takaKey: 'paid');
  final left = amount - paid;
  return left < 0 ? 0 : left;
}

bool isPaid(Map debt) => outstandingPoisha(debt) <= 0;

// ---------------------------------------------------------------- key gate

bool canExecutePay(Map ladder, {bool? hasKey}) =>
    hasKey ?? (ladder['has_payment_key'] == true);

/// Downgrade a key-only `pay_key` to the honest `pay_manual` when no licensed
/// key is present. This is how the client stays honest with no key.
String resolvePayAction(String action, Map ladder, {bool? hasKey}) =>
    (action == 'pay_key' && !canExecutePay(ladder, hasKey: hasKey))
        ? 'pay_manual'
        : action;

// ---------------------------------------------------------------- dates / steps

DateTime? parseDate(dynamic v) {
  if (v == null || v == '') return null;
  if (v is DateTime) return v;
  final s = '$v';
  return DateTime.tryParse(s.length >= 10 ? s.substring(0, 10) : s);
}

String iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// Steps sorted by offset ascending, re-indexed 1-based. Malformed steps dropped.
List<Map<String, dynamic>> normalisedSteps(Map ladder) {
  final raw = (ladder['steps'] as List?) ?? const [];
  final out = <Map<String, dynamic>>[];
  for (var i = 0; i < raw.length; i++) {
    final s = raw[i];
    if (s is! Map || s['offset_days'] == null) continue;
    final off = int.tryParse('${s['offset_days']}');
    if (off == null) continue;
    out.add({
      'index': i,
      'offset_days': off,
      'action': s['action'] ?? 'remind_gentle',
      'channel': s['channel'] ?? 'in_app',
    });
  }
  out.sort((a, b) {
    final c = (a['offset_days'] as int).compareTo(b['offset_days'] as int);
    return c != 0 ? c : (a['index'] as int).compareTo(b['index'] as int);
  });
  for (var n = 0; n < out.length; n++) {
    out[n]['step'] = n + 1;
  }
  return out;
}

/// THE core decision, mirroring payment_ladder.due_step: the highest rung whose
/// fire date has arrived, or null when nothing is due / the ladder is stopped.
Map<String, dynamic>? dueStep(Map debt, Map ladder, DateTime now) {
  final n = _day(now);
  if (isPaid(debt) && (ladder['stop_on_payment'] ?? true) == true) return null;
  if (debt['paused'] == true) return null;
  final steps = normalisedSteps(ladder);
  final due = parseDate(debt['due_date']);
  if (steps.isEmpty || due == null) return null;
  final due0 = _day(due);

  Map<String, dynamic>? curStep;
  DateTime? curFire;
  for (final s in steps) {
    final fire = due0.add(Duration(days: s['offset_days'] as int));
    if (!fire.isAfter(n)) {
      curStep = s;
      curFire = fire;
    } else {
      break;
    }
  }
  if (curStep == null || curFire == null) return null;
  final action = resolvePayAction('${curStep['action']}', ladder);
  return {
    'step': curStep['step'],
    'step_index': curStep['index'],
    'action': action,
    'channel': curStep['channel'],
    'fire_date': iso(curFire),
    'days_overdue': n.difference(due0).inDays,
    'outstanding_poisha': outstandingPoisha(debt),
    'is_final': curStep['step'] == steps.length,
    'holds_money': kHoldsMoney,
    'charges_money': kChargesMoney,
  };
}

/// The next rung that has not yet fired (for "next reminder in N days").
Map<String, dynamic>? nextStep(Map debt, Map ladder, DateTime now) {
  final n = _day(now);
  if (isPaid(debt) && (ladder['stop_on_payment'] ?? true) == true) return null;
  if (debt['paused'] == true) return null;
  final steps = normalisedSteps(ladder);
  final due = parseDate(debt['due_date']);
  if (steps.isEmpty || due == null) return null;
  final due0 = _day(due);
  for (final s in steps) {
    final fire = due0.add(Duration(days: s['offset_days'] as int));
    if (fire.isAfter(n)) {
      return {
        'step': s['step'],
        'action': resolvePayAction('${s['action']}', ladder),
        'channel': s['channel'],
        'fire_date': iso(fire),
        'days_until': fire.difference(n).inDays,
      };
    }
  }
  return null;
}

/// Full timeline with past|due|upcoming status for the builder/preview.
List<Map<String, dynamic>> scheduleOf(Map debt, Map ladder, {DateTime? now}) {
  final steps = normalisedSteps(ladder);
  final due = parseDate(debt['due_date']);
  final n = now != null ? _day(now) : null;
  final cur = n != null ? dueStep(debt, ladder, n) : null;
  final curIndex = cur?['step_index'];
  return [
    for (final s in steps)
      () {
        final fire = due != null
            ? _day(due).add(Duration(days: s['offset_days'] as int))
            : null;
        String status;
        if (n == null || fire == null) {
          status = 'upcoming';
        } else if (s['index'] == curIndex) {
          status = 'due';
        } else if (!fire.isAfter(n)) {
          status = 'past';
        } else {
          status = 'upcoming';
        }
        return {
          'step': s['step'],
          'action': resolvePayAction('${s['action']}', ladder),
          'channel': s['channel'],
          'offset_days': s['offset_days'],
          'fire_date': fire != null ? iso(fire) : null,
          'status': status,
        };
      }()
  ];
}

/// Apply a payment, returning a NEW debt map (never mutates). Rolls a recurring
/// payable bill forward when fully settled. Bookkeeping only — moves no money.
Map<String, dynamic> recordPayment(Map debt, int amountPoisha, {DateTime? now}) {
  final out = Map<String, dynamic>.from(debt);
  final amount = poishaOf(debt);
  final paid = poishaOf(debt, poishaKey: 'paid_poisha', takaKey: 'paid');
  final add = amountPoisha < 0 ? 0 : amountPoisha;
  var newPaid = paid + add;
  if (newPaid > amount) newPaid = amount;
  out['paid_poisha'] = newPaid;
  out.remove('paid');
  out['amount_poisha'] = amount;

  final recurring = int.tryParse('${debt['recurring_days'] ?? 0}') ?? 0;
  if (newPaid >= amount && amount > 0 && recurring > 0) {
    final base = parseDate(debt['due_date']);
    final anchor = now != null ? _day(now) : base;
    if (base != null) {
      var nxt = _day(base);
      var guard = 0;
      while (anchor != null && !nxt.isAfter(anchor) && guard < 3650) {
        nxt = nxt.add(Duration(days: recurring));
        guard++;
      }
      out['due_date'] = iso(nxt);
      out['paid_poisha'] = 0;
    }
  }
  return out;
}

Map<String, dynamic> markPaid(Map debt, {DateTime? now}) =>
    recordPayment(debt, outstandingPoisha(debt), now: now);

// ---------------------------------------------------------------- defaults

const List<Map<String, dynamic>> kDefaultReceivableSteps = [
  {'offset_days': 0, 'action': 'remind_gentle', 'channel': 'in_app'},
  {'offset_days': 3, 'action': 'remind_firm', 'channel': 'whatsapp_share'},
  {'offset_days': 7, 'action': 'final_notice', 'channel': 'sms'},
  {'offset_days': 14, 'action': 'escalate_owner', 'channel': 'in_app'},
];
const List<Map<String, dynamic>> kDefaultPayableSteps = [
  {'offset_days': -3, 'action': 'heads_up', 'channel': 'in_app'},
  {'offset_days': 0, 'action': 'due_today', 'channel': 'in_app'},
  {'offset_days': 3, 'action': 'overdue', 'channel': 'in_app'},
  {'offset_days': 7, 'action': 'final_warning', 'channel': 'in_app'},
];

Map<String, dynamic> defaultLadder(String kind) {
  final k = (kind == kKindPayable) ? kKindPayable : kKindReceivable;
  final steps = k == kKindReceivable ? kDefaultReceivableSteps : kDefaultPayableSteps;
  return {
    'kind': k,
    'stop_on_payment': true,
    'has_payment_key': false,
    'steps': [for (final s in steps) Map<String, dynamic>.from(s)],
  };
}

/// Problem codes (empty ⇒ valid), mirroring payment_ladder.validate_ladder.
List<String> validateLadder(Map ladder) {
  final problems = <String>[];
  final kind = ladder['kind'];
  if (kind != kKindReceivable && kind != kKindPayable) problems.add('bad_kind');
  final steps = (ladder['steps'] as List?) ?? const [];
  if (steps.isEmpty) problems.add('no_steps');
  final offs = <int>[];
  for (final s in steps) {
    if (s is! Map || s['offset_days'] == null) {
      problems.add('bad_step');
      continue;
    }
    final o = int.tryParse('${s['offset_days']}');
    if (o == null) {
      problems.add('bad_step');
      continue;
    }
    offs.add(o);
    if (s['channel'] != null && !kChannels.contains(s['channel'])) {
      problems.add('bad_channel');
    }
    if (s['action'] == 'auto_charge' || s['action'] == 'auto_pay') {
      problems.add('no_auto_charge');
    }
  }
  if (offs.toSet().length != offs.length) problems.add('duplicate_offset');
  final seen = <String>[];
  for (final p in problems) {
    if (!seen.contains(p)) seen.add(p);
  }
  return seen;
}

// ---------------------------------------------------------------- labels / icons

List<String> actionsFor(String kind) =>
    kind == kKindPayable ? kPayableActions : kReceivableActions;

String actionLabel(AppLocalizations t, String? a) {
  switch (a) {
    case 'remind_gentle':
      return t.plActRemindGentle;
    case 'remind_firm':
      return t.plActRemindFirm;
    case 'final_notice':
      return t.plActFinalNotice;
    case 'escalate_owner':
      return t.plActEscalateOwner;
    case 'pause_service':
      return t.plActPauseService;
    case 'heads_up':
      return t.plActHeadsUp;
    case 'due_today':
      return t.plActDueToday;
    case 'overdue':
      return t.plActOverdue;
    case 'final_warning':
      return t.plActFinalWarning;
    case 'pay_key':
      return t.plActPayKey;
    case 'pay_manual':
    default:
      return t.plActPayManual;
  }
}

IconData actionIcon(String? a) {
  switch (a) {
    case 'remind_gentle':
    case 'heads_up':
      return Icons.notifications_none_rounded;
    case 'remind_firm':
    case 'due_today':
      return Icons.notifications_active_rounded;
    case 'final_notice':
    case 'final_warning':
      return Icons.priority_high_rounded;
    case 'escalate_owner':
      return Icons.campaign_rounded;
    case 'pause_service':
      return Icons.pause_circle_outline_rounded;
    case 'overdue':
      return Icons.error_outline_rounded;
    case 'pay_key':
    case 'pay_manual':
      return Icons.account_balance_wallet_rounded;
    default:
      return Icons.notifications_none_rounded;
  }
}

Color actionTint(String? a) {
  switch (a) {
    case 'remind_gentle':
    case 'heads_up':
      return Brand.blue;
    case 'remind_firm':
    case 'due_today':
      return Brand.cyan;
    case 'final_notice':
    case 'overdue':
      return Brand.warning;
    case 'escalate_owner':
    case 'final_warning':
    case 'pause_service':
      return Brand.danger;
    default:
      return Brand.purple;
  }
}

String channelLabel(AppLocalizations t, String? c) {
  switch (c) {
    case 'whatsapp_share':
      return t.plChannelWhatsapp;
    case 'sms':
      return t.plChannelSms;
    case 'in_app':
    default:
      return t.plChannelInApp;
  }
}

IconData channelIcon(String? c) {
  switch (c) {
    case 'whatsapp_share':
      return Icons.chat_bubble_outline_rounded;
    case 'sms':
      return Icons.sms_rounded;
    default:
      return Icons.notifications_none_rounded;
  }
}

String offsetLabel(AppLocalizations t, BuildContext context, int offset) {
  if (offset == 0) return t.plOffsetOnDue;
  if (offset > 0) return t.plOffsetAfter(fmtInt(context, offset));
  return t.plOffsetBefore(fmtInt(context, -offset));
}

// ---------------------------------------------------------------- date relative

int? daysUntil(dynamic due, DateTime now) {
  final d = parseDate(due);
  if (d == null) return null;
  return _day(d).difference(_day(now)).inDays;
}

String dueRelative(BuildContext context, AppLocalizations t, dynamic due) {
  final n = daysUntil(due, DateTime.now());
  if (n == null) return '';
  if (n == 0) return t.plDueToday;
  if (n < 0) return t.plDaysOverdue(fmtInt(context, -n));
  return t.plDueInDays(fmtInt(context, n));
}

// ---------------------------------------------------------------- bn digits

String _ascii(String s) {
  const bnZero = 0x09E6;
  final b = StringBuffer();
  for (final ch in s.runes) {
    if (ch >= bnZero && ch <= bnZero + 9) {
      b.write(ch - bnZero);
    } else {
      b.writeCharCode(ch);
    }
  }
  return b.toString();
}

String _toBn(String ascii, bool bn) {
  if (!bn) return ascii;
  const bnZero = 0x09E6;
  final b = StringBuffer();
  for (final cu in ascii.codeUnits) {
    if (cu >= 0x30 && cu <= 0x39) {
      b.writeCharCode(bnZero + (cu - 0x30));
    } else {
      b.writeCharCode(cu);
    }
  }
  return b.toString();
}

String fmtInt(BuildContext context, int n) {
  final bn = Localizations.localeOf(context).languageCode == 'bn';
  final neg = n < 0;
  final s = n.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return (neg ? '-' : '') + _toBn(buf.toString(), bn);
}

/// The Bangladeshi taka sign (U+09F3), via code point so no Bangla-block literal
/// lives in source (keeps the language gate strict).
const _takaSign = '\u09F3';

String taka(BuildContext context, int poisha) {
  final bn = Localizations.localeOf(context).languageCode == 'bn';
  final whole = poisha ~/ 100;
  final frac = poisha % 100;
  final base = frac == 0
      ? fmtInt(context, whole)
      : '${fmtInt(context, whole)}.${_toBn(frac.toString().padLeft(2, '0'), bn)}';
  return '$_takaSign$base';
}

/// A deterministic brand-family tint for a party chip (stable per name).
Color partyColor(String key) {
  const palette = [Brand.blue, Brand.cyan, Brand.purple, Brand.success, Brand.warning];
  var h = 0;
  for (final c in key.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return palette[h % palette.length];
}
