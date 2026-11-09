import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../feature_flags.dart';
import '../l10n/app_localizations.dart';
import '../push/push_service.dart' show appNavigatorKey;
import '../state.dart';
import 'callmoney_screens.dart';
import 'money_notif_parser.dart';
import 'notif_listen_channel.dart';

/// callmoney — glue between the native listener, the user's switches and the
/// khata. Nothing here runs at launch: [maybeOpen] is a cheap guarded check on
/// app open / resume (WorkManager is banned; this is the foreground pattern).
class NotifListenPrefs {
  NotifListenPrefs._();
  static const callNote = 'cm_callnote_on';
  static const money = 'cm_money_on';
  static const moneyAuto = 'cm_money_auto';
  static const consentCall = 'cm_consent_call_v1'; // ISO time the user agreed
  static const consentMoney = 'cm_consent_money_v1';
  static const savedKeys = 'cm_money_saved_keys';
}

/// Wallet slug -> server Account.acc_type (upay has no own type: a named bank row).
const _accType = {'bkash': 'bkash', 'nagad': 'nagad', 'rocket': 'rocket', 'upay': 'bank', 'bank': 'bank'};

String walletLabel(AppLocalizations t, String w) => switch (w) {
      'bkash' => t.clnWalletBkash,
      'nagad' => t.clnWalletNagad,
      'rocket' => t.clnWalletRocket,
      'upay' => t.clnWalletUpay,
      _ => t.clnWalletBank,
    };

class WalletMonth {
  final String wallet;
  final String name;
  num income = 0;
  num expense = 0;
  int count = 0;
  WalletMonth(this.wallet, this.name);
  num get net => income - expense;
}

class NotifListenService {
  NotifListenService._();

  static NotifListenBridge get bridge => NotifListenChannel.instance;

  /// Strings the native prompts show (from the ARB, never hard-coded in Kotlin).
  static Map<String, String> nativeStrings(AppLocalizations t) => {
        'chCall': t.clnChannelCall,
        'chMoney': t.clnChannelMoney,
        'callTitle': t.clnCallEndedTitle,
        'callBody': t.clnCallEndedBody,
        'callSpeak': t.clnSpeak,
        'callType': t.clnType,
        'src_sim': t.clnSrcSim,
        'src_whatsapp': t.clnSrcWhatsapp,
        'src_messenger': t.clnSrcMessenger,
        'moneyTitle': t.clnMoneyPromptTitle,
        'moneyBody': t.clnMoneyPromptBody,
        'moneyBodyAuto': t.clnMoneyPromptBodyAuto,
        'moneyIncome': t.clnIncome,
        'moneyExpense': t.clnExpense,
        for (final w in const ['bkash', 'nagad', 'rocket', 'upay', 'bank']) 'w_$w': walletLabel(t, w),
      };

  static Future<({bool callNote, bool money, bool auto})> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      return (
        callNote: p.getBool(NotifListenPrefs.callNote) ?? false,
        money: p.getBool(NotifListenPrefs.money) ?? false,
        auto: p.getBool(NotifListenPrefs.moneyAuto) ?? false,
      );
    } catch (_) {
      return (callNote: false, money: false, auto: false);
    }
  }

  static Future<bool> hasConsent(String key) async {
    try {
      return ((await SharedPreferences.getInstance()).getString(key) ?? '').isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static Future<void> recordConsent(String key, bool agreed) async {
    final p = await SharedPreferences.getInstance();
    if (agreed) {
      await p.setString(key, DateTime.now().toUtc().toIso8601String());
    } else {
      await p.remove(key);
    }
  }

  /// Saves the switches and hands them to the native side. A feature can only
  /// be ON after its consent was recorded (consent gating, tested).
  static Future<({bool callNote, bool money, bool auto})> apply(
      AppLocalizations t, String lang,
      {required bool callNote, required bool money, required bool auto}) async {
    final cn = callNote && await hasConsent(NotifListenPrefs.consentCall);
    final mo = money && await hasConsent(NotifListenPrefs.consentMoney);
    final au = mo && auto;
    final p = await SharedPreferences.getInstance();
    await p.setBool(NotifListenPrefs.callNote, cn);
    await p.setBool(NotifListenPrefs.money, mo);
    await p.setBool(NotifListenPrefs.moneyAuto, au);
    await bridge.setConfig(
        callNote: cn, money: mo, moneyAuto: au, lang: lang, strings: nativeStrings(t));
    return (callNote: cn, money: mo, auto: au);
  }

  // ------------------------------------------------------------ money
  static String _day(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// The wallet's account server id (created once, named in the UI language).
  static Future<int?> walletAccount(AppState app, String wallet, String name) async {
    final type = _accType[wallet] ?? 'bank';
    int? find() {
      for (final a in app.accounts.items) {
        final d = a['data'] as Map? ?? const {};
        final sameType = d['acc_type'] == type;
        final sameName = '${d['name'] ?? ''}'.toLowerCase() == name.toLowerCase();
        if (a['serverId'] != null && (wallet == 'upay' ? sameName : sameType || sameName)) {
          return a['serverId'] as int?;
        }
      }
      return null;
    }

    final have = find();
    if (have != null) return have;
    await app.accounts.add({'name': name, 'acc_type': type, 'opening_balance': '0'});
    return find(); // null when offline: the entry stays waiting, never lost
  }

  static Future<Set<String>> _savedKeys() async {
    try {
      final p = await SharedPreferences.getInstance();
      return (p.getStringList(NotifListenPrefs.savedKeys) ?? const []).toSet();
    } catch (_) {
      return {};
    }
  }

  static Future<void> _rememberKey(String k) async {
    final p = await SharedPreferences.getInstance();
    final l = p.getStringList(NotifListenPrefs.savedKeys) ?? <String>[];
    l.add(k);
    await p.setStringList(NotifListenPrefs.savedKeys, l.length > 300 ? l.sublist(l.length - 300) : l);
  }

  /// Already in the khata? (this phone's saved keys, or the same TrxID on the server)
  static Future<bool> isDuplicate(AppState app, MoneyNotif p) async {
    if ((await _savedKeys()).contains(p.dedupeKey)) return true;
    final ref = p.trxId;
    if (ref == null || ref.isEmpty) return false;
    return app.txns.items.any((x) => '${(x['data'] as Map?)?['ref'] ?? ''}'.toUpperCase() == ref);
  }

  /// The txn row written for a CONFIRMED entry — parsed fields only, never the
  /// raw message (tested: no 'raw' / 'text' key, ref = TrxID only).
  static Map<String, dynamic> txnPayload(MoneyNotif p, int account, String kind, String note) => {
        'account': account,
        'kind': kind,
        'amount': '${p.amount}',
        'category': '',
        'note': note.length > 200 ? note.substring(0, 200) : note,
        'date': _day(p.date ?? DateTime.now()),
        'source': 'notification',
        'ref': (p.trxId ?? '').length > 40 ? p.trxId!.substring(0, 40) : (p.trxId ?? ''),
      };

  /// Writes ONE confirmed entry. [kind] is what the user tapped (income /
  /// expense). Returns false when it could not be saved (offline / no account).
  static Future<bool> saveConfirmed(AppState app, AppLocalizations t, MoneyNotif p, String kind,
      {required int queueId}) async {
    if (p.amount == null || (kind != 'income' && kind != 'expense')) return false;
    final name = walletLabel(t, p.wallet);
    final acc = await walletAccount(app, p.wallet, name);
    if (acc == null) return false;
    final who = (p.counterparty ?? '').trim();
    final note = who.isEmpty ? name : '$name · $who';
    await app.txns.add(txnPayload(p, acc, kind, note));
    await _rememberKey(p.dedupeKey);
    await bridge.moneyDone([queueId]);
    return true;
  }

  /// Auto-save (only after the user turned it on): every clearly parsed,
  /// non-duplicate item is saved; OTP / promo items are dropped; unclear ones
  /// stay for review. Returns how many were saved.
  static Future<int> autoSave(AppState app, AppLocalizations t) async {
    final s = await load();
    if (!s.money || !s.auto || !app.loggedIn) return 0;
    var n = 0;
    final drop = <int>[];
    for (final q in await bridge.takeMoneyQueue()) {
      final p = MoneyNotifParser.parse(q.text, wallet: q.wallet, postedAt: q.at);
      if (!p.ok) {
        if (p.reason == 'otp' || p.reason == 'promo' || p.reason == 'no_proof') drop.add(q.id);
        continue;
      }
      if (await isDuplicate(app, p)) {
        drop.add(q.id);
        continue;
      }
      if (await saveConfirmed(app, t, p, p.type!, queueId: q.id)) n++;
    }
    if (drop.isNotEmpty) await bridge.moneyDone(drop);
    return n;
  }

  /// This month, per wallet, from the khata the user confirmed.
  static List<WalletMonth> monthlyByWallet(AppState app, AppLocalizations t, DateTime now) {
    final month = '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}';
    final byAcc = <int, WalletMonth>{};
    for (final a in app.accounts.items) {
      final d = a['data'] as Map? ?? const {};
      final id = a['serverId'];
      if (id is! int) continue;
      final type = '${d['acc_type'] ?? ''}';
      if (!const ['bkash', 'nagad', 'rocket', 'bank'].contains(type)) continue;
      byAcc[id] = WalletMonth(type, '${d['name'] ?? walletLabel(t, type)}');
    }
    for (final x in app.txns.items) {
      final d = x['data'] as Map? ?? const {};
      final w = byAcc[d['account']];
      if (w == null || !'${d['date'] ?? ''}'.startsWith(month)) continue;
      final amt = num.tryParse('${d['amount'] ?? ''}') ?? 0;
      if (d['kind'] == 'income') {
        w.income += amt;
      } else if (d['kind'] == 'expense') {
        w.expense += amt;
      } else {
        continue;
      }
      w.count++;
    }
    return byAcc.values.where((w) => w.count > 0).toList()
      ..sort((a, b) => (b.income + b.expense).compareTo(a.income + a.expense));
  }

  // ------------------------------------------------------------ launch
  static bool _busy = false;

  /// App open / resume: a tapped prompt opens its card; auto-save runs.
  static Future<void> maybeOpen(BuildContext context) async {
    if (_busy) return;
    _busy = true;
    try {
      final app = context.read<AppState>();
      final t = AppLocalizations.of(context);
      final l = await bridge.takeLaunch();
      final nav = appNavigatorKey.currentContext;
      if (l != null && nav != null && nav.mounted) {
        if (l.kind == 'callnote' && FeatureFlags.instance.isOn('reminders')) {
          unawaited(showCallNoteSheet(nav, l));
        } else if (l.kind == 'money' && FeatureFlags.instance.isOn('money')) {
          unawaited(Navigator.of(nav).push(MaterialPageRoute<void>(
              builder: (_) => MoneyNotifReviewScreen(
                  focusId: l.id,
                  presetKind: l.mode == 'income' || l.mode == 'expense' ? l.mode : null))));
        }
      }
      if (FeatureFlags.instance.isOn('money')) await autoSave(app, t);
    } catch (_) {
      // best-effort: a resume check must never disturb the app
    } finally {
      _busy = false;
    }
  }
}
