import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../notifications.dart';
import '../screens/journey_sos_screen.dart';
import '../state.dart';
import '../widgets/chatnav.dart';
import '../widgets/reminders_nlp.dart';
import 'va_confirm_sheet.dart';
import 'va_native.dart';
import 'voice_intents.dart';

/// A follow-up button on a result card.
class VaButton {
  final String label;
  final IconData icon;
  final Future<void> Function() onTap;
  const VaButton(this.label, this.icon, this.onTap);
}

/// What happened, ready to show as a result card and to speak.
class VaOutcome {
  final String reply; // shown + spoken
  final IconData icon;
  final String? title;
  final String? subtitle;
  final bool ok;
  final bool danger;
  final List<VaButton> buttons;
  final List<Map<String, dynamic>> cards; // server agent cards (ChatCard)
  const VaOutcome(
    this.reply, {
    this.icon = Icons.auto_awesome,
    this.title,
    this.subtitle,
    this.ok = true,
    this.danger = false,
    this.buttons = const [],
    this.cards = const [],
  });
}

/// Runs a parsed [VaIntent]. Every OUTGOING action (call / SMS / WhatsApp /
/// SOS) goes through [VaConfirmSheet] first and only runs after an explicit
/// "yes" (tap or spoken). Internal actions (reminder, expense, torch, alarm,
/// open) run directly and offer Undo where it makes sense.
class VaExecutor {
  final BuildContext context;
  final VaConfirmVoice? confirmVoice;
  VaExecutor(this.context, {this.confirmVoice});

  AppLocalizations get t => AppLocalizations.of(context);
  String get _lang => Localizations.localeOf(context).languageCode;

  static const _agentSessionKey = 'va_agent_session';

  Future<VaOutcome> run(VaIntent i) async {
    try {
      switch (i.action) {
        case VaAction.call:
          return await _call(i);
        case VaAction.sms:
          return await _message(i, whatsapp: false);
        case VaAction.whatsapp:
          return await _message(i, whatsapp: true);
        case VaAction.sos:
          return await _sos();
        case VaAction.youtube:
          return await _youtube(i);
        case VaAction.alarm:
          return await _alarm(i);
        case VaAction.timer:
          return await _timer(i);
        case VaAction.torchOn:
        case VaAction.torchOff:
          return await _torch(i.action == VaAction.torchOn);
        case VaAction.openApp:
          return await _openApp(i);
        case VaAction.openScreen:
          return _openScreen(i.route);
        case VaAction.navigate:
          return await _maps(i.target ?? '', navigate: true);
        case VaAction.mapSearch:
          return await _maps(i.target ?? '', navigate: false);
        case VaAction.reminder:
          return await _reminder(i);
        case VaAction.expense:
          return await _expense(i);
        case VaAction.unknown:
          return await agent(i.raw);
      }
    } catch (_) {
      return VaOutcome(t.vaErrGeneric, icon: Icons.error_outline, ok: false);
    }
  }

  // ---- helpers --------------------------------------------------------------

  Future<bool> _launch(String url) async {
    try {
      return await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  /// "8:00 AM" in English; "sokal 8:00" (Bangla digits + day-part word)
  /// in Bangla, so no Latin AM/PM appears in the Bangla UI.
  String _time(DateTime at) {
    if (_lang != 'bn') return DateFormat.jm('en').format(at);
    final h = at.hour;
    final part = h < 12 && h >= 4
        ? t.vaPartMorning
        : h >= 12 && h < 15
            ? t.vaPartNoon
            : h >= 15 && h < 18
                ? t.vaPartAfternoon
                : h >= 18 && h < 20
                    ? t.vaPartEvening
                    : t.vaPartNight;
    return '$part ${DateFormat('h:mm', 'bn').format(at)}';
  }

  String _clock(DateTime at) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(at.year, at.month, at.day);
    final time = _time(at);
    if (d == today) return t.vaTodayAt(time);
    if (d == today.add(const Duration(days: 1))) return t.vaTomorrowAt(time);
    return '${DateFormat.MMMd(_lang).format(at)}, $time';
  }

  String _duration(int seconds) {
    final h = seconds ~/ 3600, m = (seconds % 3600) ~/ 60, s = seconds % 60;
    final parts = <String>[
      if (h > 0) t.vaHours(h),
      if (m > 0) t.vaMinutes(m),
      if (s > 0 && h == 0) t.vaSeconds(s),
    ];
    return parts.join(' ');
  }

  // ---- contacts -------------------------------------------------------------

  /// Resolve a spoken name to phonebook matches. Asks READ_CONTACTS only now,
  /// at the moment of use. Returns null when the permission was refused.
  Future<List<Map<String, String>>?> _lookup(String spoken) async {
    final digits = spoken.replaceAll(RegExp(r'[^0-9+]'), '');
    if (digits.replaceAll('+', '').length >= 6) {
      return [
        {'name': spoken, 'phone': digits}
      ];
    }
    var st = await Permission.contacts.status;
    if (!st.isGranted) {
      if (!context.mounted) return null;
      final go = await VaConfirmSheet.reason(context,
          icon: Icons.contacts_outlined, body: t.vaContactsReason);
      if (!go) return null;
      st = await Permission.contacts.request();
      if (!st.isGranted) return null;
    }
    final book = await VaNative.contacts();
    return VaContacts.rank(spoken, book).take(5).toList();
  }

  // ---- outgoing: call / sms / whatsapp / sos --------------------------------

  Future<VaOutcome> _call(VaIntent i) async {
    final who = i.target;
    if (who == null) {
      final ok = await _launch('tel:');
      return VaOutcome(ok ? t.vaDialerOpened : t.vaErrNoApp,
          icon: Icons.dialpad, ok: ok);
    }
    final found = await _lookup(who);
    if (found == null) {
      return VaOutcome(t.vaContactsDenied,
          icon: Icons.contacts_outlined,
          ok: false,
          buttons: [
            VaButton(t.vaOpenDialer, Icons.dialpad, () async {
              await _launch('tel:');
            }),
          ]);
    }
    if (found.isEmpty) {
      return VaOutcome(t.vaNoContact(who),
          icon: Icons.person_search_outlined,
          ok: false,
          buttons: [
            VaButton(t.vaOpenDialer, Icons.dialpad, () async {
              await _launch('tel:');
            }),
          ]);
    }
    if (!context.mounted) return VaOutcome(t.vaCancelled);
    final pick = await VaConfirmSheet.show(
      context,
      icon: Icons.call,
      title: t.vaConfirmCallTitle(found.first['name'] ?? who),
      choices: found,
      confirmLabel: t.vaCallNow,
      voice: confirmVoice,
      spokenQuestion: t.vaConfirmCallSpoken(found.first['name'] ?? who),
    );
    if (pick == null) return VaOutcome(t.vaCancelled, icon: Icons.close);
    final name = pick['name'] ?? who;
    final number = pick['phone'] ?? '';
    // Direct call when CALL_PHONE is (or now gets) granted; otherwise the
    // dialer opens with the number filled in and the user taps call.
    var direct = false;
    try {
      var st = await Permission.phone.status;
      if (!st.isGranted && !st.isPermanentlyDenied) {
        st = await Permission.phone.request();
      }
      if (st.isGranted) direct = (await VaNative.callNow(number)) == 'ok';
    } catch (_) {}
    if (direct) {
      return VaOutcome(t.vaCalling(name),
          icon: Icons.call, title: name, subtitle: number);
    }
    final ok = await _launch('tel:${Uri.encodeComponent(number)}');
    return VaOutcome(ok ? t.vaDialerReady(name) : t.vaErrNoApp,
        icon: Icons.dialpad, title: name, subtitle: number, ok: ok);
  }

  Future<VaOutcome> _message(VaIntent i, {required bool whatsapp}) async {
    final who = i.target;
    final body = i.message ?? '';
    Map<String, String>? pick;
    if (who != null) {
      final found = await _lookup(who);
      if (found == null) {
        return VaOutcome(t.vaContactsDenied,
            icon: Icons.contacts_outlined, ok: false);
      }
      if (found.isEmpty) {
        return VaOutcome(t.vaNoContact(who),
            icon: Icons.person_search_outlined, ok: false);
      }
      if (!context.mounted) return VaOutcome(t.vaCancelled);
      pick = await VaConfirmSheet.show(
        context,
        icon: whatsapp ? Icons.chat_outlined : Icons.sms_outlined,
        title: whatsapp
            ? t.vaConfirmWaTitle(found.first['name'] ?? who)
            : t.vaConfirmSmsTitle(found.first['name'] ?? who),
        detail: body.isEmpty ? t.vaNoMessageBody : '“$body”',
        choices: found,
        confirmLabel: t.vaOpenDraft,
        voice: confirmVoice,
        spokenQuestion: whatsapp
            ? t.vaConfirmWaSpoken(found.first['name'] ?? who)
            : t.vaConfirmSmsSpoken(found.first['name'] ?? who),
      );
      if (pick == null) return VaOutcome(t.vaCancelled, icon: Icons.close);
    } else {
      if (!context.mounted) return VaOutcome(t.vaCancelled);
      final go = await VaConfirmSheet.show(
        context,
        icon: whatsapp ? Icons.chat_outlined : Icons.sms_outlined,
        title: whatsapp ? t.vaConfirmWaAnyone : t.vaConfirmSmsAnyone,
        detail: body.isEmpty ? t.vaNoMessageBody : '“$body”',
        confirmLabel: t.vaOpenDraft,
        voice: confirmVoice,
        spokenQuestion: whatsapp ? t.vaConfirmWaAnyone : t.vaConfirmSmsAnyone,
      );
      if (go == null) return VaOutcome(t.vaCancelled, icon: Icons.close);
    }
    final number = pick?['phone'] ?? '';
    final enc = Uri.encodeComponent(body);
    bool ok;
    if (whatsapp) {
      final n = number.isEmpty ? '' : VaText.waNumber(number);
      ok = await _launch('https://wa.me/$n${body.isEmpty ? '' : '?text=$enc'}');
    } else {
      ok = await _launch(
          'sms:${Uri.encodeComponent(number)}${body.isEmpty ? '' : '?body=$enc'}');
    }
    final name = pick?['name'];
    return VaOutcome(
        ok
            ? (whatsapp ? t.vaWaDraftReady : t.vaSmsDraftReady)
            : (whatsapp ? t.vaErrNoWhatsapp : t.vaErrNoApp),
        icon: whatsapp ? Icons.chat_outlined : Icons.sms_outlined,
        title: name,
        subtitle: body.isEmpty ? null : body,
        ok: ok);
  }

  Future<VaOutcome> _sos() async {
    final go = await VaConfirmSheet.show(
      context,
      icon: Icons.sos,
      title: t.vaConfirmSosTitle,
      detail: t.vaConfirmSosBody,
      confirmLabel: t.vaSendSos,
      danger: true,
      voice: confirmVoice,
      spokenQuestion: t.vaConfirmSosTitle,
    );
    if (go == null) return VaOutcome(t.vaCancelled, icon: Icons.close);
    if (!context.mounted) return VaOutcome(t.vaCancelled);
    // The EXISTING SOS flow: short cancellable countdown, then the same
    // api.journeySos alert + location as the manual SOS button.
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => const JourneySosScreen(countdownSeconds: 5)));
    return VaOutcome(t.vaSosStarted, icon: Icons.sos, danger: true);
  }

  // ---- media / maps / apps --------------------------------------------------

  Future<VaOutcome> _youtube(VaIntent i) async {
    final q = i.target;
    var ok = false;
    if (q != null && q.isNotEmpty) {
      ok = await VaNative.youtubeSearch(q);
      if (!ok) {
        ok = await _launch('https://www.youtube.com/results?search_query='
            '${Uri.encodeQueryComponent(q)}');
      }
      return VaOutcome(ok ? t.vaYoutubeSearching(q) : t.vaErrNoApp,
          icon: Icons.smart_display_outlined,
          title: q,
          subtitle: ok ? t.vaYoutubeTapToPlay : null,
          ok: ok);
    }
    ok = await VaNative.launchApp('com.google.android.youtube') ||
        await _launch('https://www.youtube.com');
    return VaOutcome(ok ? t.vaOpeningApp('YouTube') : t.vaErrNoApp,
        icon: Icons.smart_display_outlined, ok: ok);
  }

  Future<VaOutcome> _maps(String place, {required bool navigate}) async {
    if (place.isEmpty) return agentFallback();
    final enc = Uri.encodeComponent(place);
    var ok = false;
    if (navigate) {
      ok = await _launch('google.navigation:q=$enc') ||
          await _launch(
              'https://www.google.com/maps/dir/?api=1&destination=$enc');
    } else {
      ok = await _launch('geo:0,0?q=$enc') ||
          await _launch('https://www.google.com/maps/search/?api=1&query=$enc');
    }
    final shown = place.replaceAll(' near me', '');
    return VaOutcome(
        ok
            ? (navigate ? t.vaNavigating(shown) : t.vaMapSearching(shown))
            : t.vaErrNoApp,
        icon: navigate ? Icons.navigation_outlined : Icons.map_outlined,
        title: shown,
        ok: ok);
  }

  Future<VaOutcome> _openApp(VaIntent i) async {
    final name = i.target ?? '';
    final apps = await VaNative.listApps();
    final pkg = VaApps.best(name, apps);
    if (pkg != null && await VaNative.launchApp(pkg)) {
      final label = apps.firstWhere((a) => a['package'] == pkg,
          orElse: () => {'label': name})['label']!;
      return VaOutcome(t.vaOpeningApp(label), icon: Icons.apps, title: label);
    }
    // Maybe it is an Assisto screen said in Bangla — the server knows.
    return agent(i.raw, notFoundApp: name);
  }

  VaOutcome _openScreen(String? route) {
    if (route != null && ChatNav.push(context, route)) {
      return VaOutcome(t.vaOpening, icon: Icons.open_in_new);
    }
    return VaOutcome(t.vaErrGeneric, icon: Icons.error_outline, ok: false);
  }

  // ---- clock / torch --------------------------------------------------------

  Future<VaOutcome> _alarm(VaIntent i) async {
    final at = i.clock?.resolve(DateTime.now());
    final r = await VaNative.setAlarm(at?.hour, at?.minute, t.vaAlarmLabel);
    if (r == 'ok') {
      return VaOutcome(
          at == null ? t.vaAlarmPickTime : t.vaAlarmSet(_clock(at)),
          icon: Icons.alarm,
          title: at == null ? null : _time(at));
    }
    if (at != null) {
      // The phone's Clock app refused — keep the promise with an Assisto
      // reminder instead, and say so plainly.
      await _createReminder(t.vaAlarmLabel, at);
      return VaOutcome(t.vaAlarmFallback(_clock(at)),
          icon: Icons.notifications_active_outlined);
    }
    return VaOutcome(t.vaErrNoClock, icon: Icons.alarm_off, ok: false);
  }

  Future<VaOutcome> _timer(VaIntent i) async {
    final s = i.seconds;
    final r = await VaNative.setTimer(s, t.vaTimerLabel);
    if (r == 'ok') {
      return VaOutcome(s == null ? t.vaTimerPick : t.vaTimerSet(_duration(s)),
          icon: Icons.timer_outlined);
    }
    if (s != null) {
      final at = DateTime.now().add(Duration(seconds: s));
      await _createReminder(t.vaTimerLabel, at);
      return VaOutcome(t.vaAlarmFallback(_clock(at)),
          icon: Icons.notifications_active_outlined);
    }
    return VaOutcome(t.vaErrNoClock, icon: Icons.timer_off_outlined, ok: false);
  }

  Future<VaOutcome> _torch(bool on) async {
    final r = await VaNative.torch(on);
    switch (r) {
      case 'ok':
        return VaOutcome(on ? t.vaTorchOn : t.vaTorchOff,
            icon: on ? Icons.flashlight_on : Icons.flashlight_off,
            buttons: [
              VaButton(on ? t.vaTurnOff : t.vaTurnOn,
                  on ? Icons.flashlight_off : Icons.flashlight_on, () async {
                await VaNative.torch(!on);
              }),
            ]);
      case 'no_flash':
        return VaOutcome(t.vaTorchNone,
            icon: Icons.flashlight_off, ok: false);
      default:
        return VaOutcome(t.vaTorchError,
            icon: Icons.flashlight_off, ok: false);
    }
  }

  // ---- own data: reminder / expense -----------------------------------------

  Future<Map<String, dynamic>> _createReminder(String title, DateTime? at,
      {RecurrenceRule? rule}) async {
    final app = context.read<AppState>();
    final created = await app.reminders.add({
      'title': title,
      'notes': '',
      'due_at': at?.toUtc().toIso8601String(),
      'recurrence': rule?.freq ?? 'none',
      'recurrence_rule': rule?.toJson(),
      'date_only': at == null,
      'done': false,
      'source': 'voice',
    });
    final lid = created['localId'];
    if (at != null && lid != null) {
      try {
        await Notifications.schedule(lid, title, '', at);
      } catch (_) {}
    }
    return created;
  }

  Future<VaOutcome> _reminder(VaIntent i) async {
    final parsed = parseReminder(i.raw);
    DateTime? at;
    if (i.clock != null) {
      at = i.clock!.resolve(DateTime.now());
      // keep a spoken date ("on friday") with the spoken clock time
      final pd = parsed.dateTime;
      if (pd != null && !i.clock!.tomorrow && parsed.dateOnly == false) {
        at = pd;
      } else if (pd != null && !i.clock!.tomorrow) {
        final cand = DateTime(pd.year, pd.month, pd.day, at.hour, at.minute);
        if (cand.isAfter(DateTime.now())) at = cand;
      }
    } else {
      at = parsed.dateTime;
    }
    final title = (i.message ?? '').isNotEmpty
        ? i.message!
        : (parsed.cleanTitle.isNotEmpty ? parsed.cleanTitle : t.vaReminderDefault);
    final created =
        await _createReminder(title, at, rule: parsed.recurrence);
    return VaOutcome(
      at == null ? t.vaReminderSetNoTime(title) : t.vaReminderSet(title, _clock(at)),
      icon: Icons.notifications_active_outlined,
      title: title,
      subtitle: at == null ? t.vaNoTime : _clock(at),
      buttons: [_undoButton(created, reminder: true)],
    );
  }

  String _categoryLabel(String? key) => switch (key) {
        'groceries' => t.vaCatGroceries,
        'food' => t.vaCatFood,
        'transport' => t.vaCatTransport,
        'bills' => t.vaCatBills,
        'recharge' => t.vaCatRecharge,
        'health' => t.vaCatHealth,
        'shopping' => t.vaCatShopping,
        'education' => t.vaCatEducation,
        _ => '',
      };

  Future<VaOutcome> _expense(VaIntent i) async {
    final app = context.read<AppState>();
    final accs =
        app.accounts.items.where((a) => a['serverId'] != null).toList();
    final acc = accs.isEmpty ? null : accs.first['serverId'];
    final cat = _categoryLabel(i.category);
    final created = await app.txns.add({
      if (acc != null) 'account': acc,
      'kind': 'expense',
      'amount': i.amount.toString(),
      'category': cat,
      'note': i.message ?? '',
      'date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
      'source': 'voice',
    });
    final amount = NumberFormat.decimalPattern(_lang).format(i.amount);
    return VaOutcome(
      t.vaExpenseLogged('৳$amount', cat.isEmpty ? t.vaCatOther : cat),
      icon: Icons.receipt_long_outlined,
      title: '৳$amount',
      subtitle: cat.isEmpty ? (i.message ?? t.vaCatOther) : cat,
      buttons: [_undoButton(created, reminder: false)],
    );
  }

  VaButton _undoButton(Map<String, dynamic> created, {required bool reminder}) {
    return VaButton(t.vaUndo, Icons.undo, () async {
      final app = context.read<AppState>();
      try {
        if (reminder) {
          final lid = created['localId'];
          if (lid != null) await Notifications.cancel(lid);
          await app.reminders.remove(created);
        } else {
          await app.txns.remove(created);
        }
      } catch (_) {}
    });
  }

  // ---- server agent fallback ------------------------------------------------

  Future<VaOutcome> agentFallback() =>
      Future.value(VaOutcome(t.vaNotUnderstood, icon: Icons.help_outline, ok: false));

  /// Send the words to the Assisto agent (bn/en brain on the server). It may
  /// create the user's own rows (loan, medicine, memory…) and returns cards.
  Future<VaOutcome> agent(String text, {String? notFoundApp}) async {
    final app = context.read<AppState>();
    if (!app.loggedIn) {
      return VaOutcome(t.vaNotUnderstood, icon: Icons.help_outline, ok: false);
    }
    try {
      final sid = await Settings.getString(_agentSessionKey);
      final r = await app.api.agent(text, sessionId: sid);
      final newSid = r['session_id']?.toString();
      if (newSid != null && newSid.isNotEmpty) {
        await Settings.setString(_agentSessionKey, newSid);
      }
      final reply = (r['reply'] ?? '').toString();
      final cards = ((r['cards'] ?? const []) as List)
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
      final route = r['route']?.toString();
      final intent = r['intent']?.toString() ?? '';
      if (notFoundApp != null && route == null && intent == 'ambiguous') {
        return VaOutcome(t.vaNoApp(notFoundApp), icon: Icons.apps, ok: false);
      }
      return VaOutcome(
        reply.isEmpty ? t.vaNotUnderstood : reply,
        icon: Icons.auto_awesome,
        cards: cards,
        buttons: [
          if (route != null && ChatNav.routes.containsKey(route))
            VaButton(t.vaOpen, Icons.open_in_new, () async {
              if (context.mounted) ChatNav.push(context, route);
            }),
        ],
      );
    } catch (_) {
      return VaOutcome(t.vaErrOffline, icon: Icons.cloud_off_outlined, ok: false);
    }
  }
}
