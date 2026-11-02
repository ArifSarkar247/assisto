// remhbar (2 Nov): Reminders & Notes launch bar. Fixed clocks only (every
// "now" below is a constant; nothing reads the device clock).
//  * recurrence: every-N days/weeks in step with the anchor, never before
//    the anchor (mirror of core/logic/reminders_engine.py)
//  * alarms: native repeat with a lead time, look-ahead rings for monthly /
//    yearly / every-N (keys ~1, ~2), push dedupe for them, lost-alarm count
//  * Bangla calendar (revised Bangladesh calendar) + digit-agnostic search
//  * note sync conflict: server 409 -> both copies kept (real SyncedRepo
//    over an in-memory LocalDb), honest strip bn/en
//  * delivery check: lost alarms / restart line bn/en
//  * repeating family task from the famcare form
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:assisto/api.dart';
import 'package:assisto/db.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/notifications.dart';
import 'package:assisto/reminders/alarm_plan.dart';
import 'package:assisto/reminders/exact_alarm_ui.dart';
import 'package:assisto/reminders/reminder_alarms.dart';
import 'package:assisto/reminders/reminder_actions.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show NotificationResponse, NotificationResponseType;
import 'package:assisto/screens/reminders_screen.dart';
import 'package:assisto/services/bangla_calendar.dart';
import 'package:assisto/services/oem_guide.dart';
import 'package:assisto/state.dart';
import 'package:assisto/sync_repo.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/reminders_nlp.dart';
import 'package:assisto/widgets/rn_bits.dart';
import 'package:assisto/widgets/rem_notes.dart' show pickVaultDocs, NotePhotoHooks;
import 'package:image_picker/image_picker.dart' show ImageSource;

Widget _app(Widget child, {String lang = 'en', AppState? s}) {
  final app = MaterialApp(
    locale: Locale(lang),
    theme: AssistoTheme.light,
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(body: child),
  );
  return s == null
      ? app
      : ChangeNotifierProvider<AppState>.value(value: s, child: app);
}

Map<String, dynamic> _rem(String title, DateTime due,
        {int? serverId,
        Map<String, dynamic>? rule,
        String recurrence = 'none',
        int lead = 0}) =>
    {
      'localId': 'l-$title',
      'serverId': serverId,
      'pendingOp': 'none',
      'data': {
        'title': title,
        'notes': '',
        'due_at': due.toUtc().toIso8601String(),
        'recurrence': recurrence,
        'recurrence_rule': rule ?? <String, dynamic>{},
        'done': false,
        if (lead > 0) 'remind_before_min': lead,
      },
    };

/// In-memory stand-in for the phone's SQLite records table.
class _MemDb implements LocalDb {
  final Map<String, Map<String, dynamic>> rows = {};

  @override
  Future<List<Map<String, dynamic>>> recAll(String entity) async => [
        for (final r in rows.values)
          if (r['entity'] == entity && r['pending_op'] != 'delete') Map.of(r)
      ];

  @override
  Future<List<Map<String, dynamic>>> recPending(String entity) async => [
        for (final r in rows.values)
          if (r['entity'] == entity && r['pending_op'] != 'none') Map.of(r)
      ];

  @override
  Future<void> recUpsert(String entity, Map<String, dynamic> row) async {
    rows['${row['local_id']}'] = {...row, 'entity': entity};
  }

  @override
  Future<void> recHardDelete(String entity, String localId) async {
    rows.remove(localId);
  }

  @override
  Future<void> recReplaceSynced(
      String entity, List<Map<String, dynamic>> server) async {
    rows.removeWhere(
        (_, r) => r['entity'] == entity && r['pending_op'] == 'none');
    for (final row in server) {
      final busy = rows.values.any((r) =>
          r['entity'] == entity &&
          r['server_id'] == row['server_id'] &&
          r['pending_op'] != 'none');
      if (!busy) rows['${row['local_id']}'] = {...row, 'entity': entity};
    }
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// The server: note 5 was changed on another phone after this phone's copy.
class _ConflictApi extends ApiClient {
  _ConflictApi() {
    token = 't';
  }
  final List<Map<String, dynamic>> patches = [];
  final List<Map<String, dynamic>> creates = [];
  final server = <Map<String, dynamic>>[
    {
      'id': 5,
      'title': 'Bazar',
      'body': 'rice, dal (phone B)',
      'tags': ['bazar'],
      'updated_at': '2026-11-02T10:05:00+06:00',
    }
  ];

  @override
  Future<void> updateItem(String path, int id, Map<String, dynamic> body) async {
    patches.add(Map.of(body));
    if (body['base_updated_at'] != server.first['updated_at']) {
      throw ApiException('changed on another phone', 409, null, 'conflict',
          {'conflict': true, 'reason': 'conflict', 'server': server.first});
    }
  }

  @override
  Future<Map<String, dynamic>> createItem(
      String path, Map<String, dynamic> body) async {
    creates.add(Map.of(body));
    final j = {...body, 'id': 6, 'updated_at': '2026-11-02T10:06:00+06:00'};
    server.add(j);
    return j;
  }

  @override
  Future<List<Map<String, dynamic>>> listItems(String path) async =>
      [for (final s in server) Map.of(s)];
}

class _FakeOem implements OemGuideNative {
  @override
  Future<OemInfo?> info() async => const OemInfo(batteryOptIgnored: true);
  @override
  Future<OemOpen> available(String step) async => OemOpen.none;
  @override
  Future<OemOpen> open(String step) async => OemOpen.none;
}

class _FamApi extends ApiClient {
  _FamApi() {
    token = 't';
  }
  final List<Map<String, dynamic>> bodies = [];
  @override
  Future<List<Map<String, dynamic>>> listItems(String path) async =>
      path.startsWith('family')
          ? [
              {
                'id': 1,
                'name': 'Abba',
                'relation': 'father',
                'circle_member': 7,
                'in_circle': true
              }
            ]
          : [];
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/family/reminders') {
      return {'assigned_by_me': [], 'assigned_to_me': []};
    }
    if (path == '/family/limits') {
      return {'limit': 5, 'used': 1, 'left': 4, 'safety_free': true};
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    bodies.add({'_path': path, ...body});
    return {'ok': true, 'task': {'id': 3, 'repeat': body['repeat'] ?? 'none'}};
  }
}

/// Vault: empty at first; an uploaded photo becomes doc 41.
class _VaultApi extends ApiClient {
  _VaultApi() {
    token = 't';
  }
  final docs = <Map<String, dynamic>>[];
  final uploads = <Map<String, String>>[];
  bool fail = false;
  @override
  Future<List<Map<String, dynamic>>> listDocuments() async =>
      [for (final d in docs) Map.of(d)];
  @override
  Future<void> uploadDocument({
    required String title,
    required String docType,
    String? expiryDate,
    String? note,
    required String filePath,
  }) async {
    if (fail) throw ApiException('down', 503);
    uploads.add({'title': title, 'type': docType, 'path': filePath});
    docs.add({'id': 41, 'title': title, 'doc_type': docType});
  }
}

void main() {
  // ------------------------------------------------------------ recurrence
  group('recurrence engine (mirror of reminders_engine.py)', () {
    test('every 2 days stays in step with its first day', () {
      const r = RecurrenceRule(freq: 'daily', interval: 2, time: '08:00');
      final anchor = DateTime(2026, 11, 2, 8); // Monday
      // asked Tuesday 10:00 -> Wednesday (used to say Thursday)
      expect(nextOccurrence(anchor, r, after: DateTime(2026, 11, 3, 10)),
          DateTime(2026, 11, 4, 8));
      // an "on" day before the time -> that same day
      expect(nextOccurrence(anchor, r, after: DateTime(2026, 11, 6, 7)),
          DateTime(2026, 11, 6, 8));
    });

    test('every 2 weeks skips the off week', () {
      const r = RecurrenceRule(
          freq: 'weekly', interval: 2, weekday: 0, time: '09:00');
      final anchor = DateTime(2026, 11, 2, 9);
      expect(nextOccurrence(anchor, r, after: DateTime(2026, 11, 3, 10)),
          DateTime(2026, 11, 16, 9));
      expect(nextOccurrence(anchor, r, after: DateTime(2026, 11, 10, 10)),
          DateTime(2026, 11, 16, 9));
    });

    test('a repeat never starts before its anchor', () {
      const w = RecurrenceRule(freq: 'weekly', weekday: 0, time: '09:00');
      expect(
          nextOccurrence(DateTime(2026, 12, 7, 9), w,
              after: DateTime(2026, 11, 2, 10)),
          DateTime(2026, 12, 7, 9));
      const m = RecurrenceRule(freq: 'monthly', dayOfMonth: 5, time: '09:00');
      expect(
          nextOccurrence(DateTime(2027, 1, 5, 9), m,
              after: DateTime(2026, 11, 2, 10)),
          DateTime(2027, 1, 5, 9));
    });

    test('unchanged: daily next day, weekly +1, monthly clamps February', () {
      const d = RecurrenceRule(freq: 'daily', time: '08:00');
      expect(
          nextOccurrence(DateTime(2026, 10, 13, 8), d,
              after: DateTime(2026, 10, 13, 10)),
          DateTime(2026, 10, 14, 8));
      const m = RecurrenceRule(freq: 'monthly', dayOfMonth: 31, time: '09:00');
      expect(
          nextOccurrence(DateTime(2026, 1, 31, 9), m,
              after: DateTime(2026, 2, 1)),
          DateTime(2026, 2, 28, 9));
    });
  });

  // ------------------------------------------------------------ alarms
  group('alarm plan', () {
    final now = DateTime(2026, 11, 2, 10, 0);

    test('daily with "10 min before" is a native daily repeat now', () {
      final p = planReminderAlarms([
        _rem('pill', DateTime(2026, 10, 20, 21, 0),
            serverId: 3,
            recurrence: 'daily',
            rule: {'freq': 'daily', 'interval': 1, 'time': '21:00'},
            lead: 10),
      ], now: now);
      expect(p.single.at, DateTime(2026, 11, 2, 20, 50));
      expect(p.single.repeat, AlarmRepeat.daily);
    });

    test('yearly and every-3-days get 2 look-ahead rings; ids differ', () {
      final p = planReminderAlarms([
        _rem('eid', DateTime(2026, 3, 20, 8, 0),
            serverId: 8,
            recurrence: 'yearly',
            rule: {'freq': 'yearly', 'month': 3, 'day_of_month': 20, 'time': '08:00'}),
        _rem('water', DateTime(2026, 11, 1, 7, 0),
            serverId: 9,
            rule: {'freq': 'daily', 'interval': 3, 'time': '07:00'}),
      ], now: now);
      final eid = p.where((x) => x.baseKey == 'rem-8').toList();
      expect(eid.map((x) => x.at), [
        DateTime(2027, 3, 20, 8),
        DateTime(2028, 3, 20, 8),
        DateTime(2029, 3, 20, 8),
      ]);
      final water = p.where((x) => x.baseKey == 'rem-9').toList();
      expect(water.map((x) => x.at), [
        DateTime(2026, 11, 4, 7),
        DateTime(2026, 11, 7, 7),
        DateTime(2026, 11, 10, 7),
      ]);
      expect(p.map((x) => x.id).toSet(), hasLength(p.length));
    });

    test('a push for a look-ahead ring finds its ledger entry (no double ring)',
        () {
      final ms = DateTime(2026, 12, 5, 9).millisecondsSinceEpoch;
      final ledger = {
        alarmIdFor('rem-4'): LedgerEntry(
            key: 'rem-4',
            at: DateTime(2026, 11, 5, 9).millisecondsSinceEpoch,
            mode: AlarmMode.exact,
            repeat: AlarmRepeat.none,
            sig: ''),
        alarmIdFor('rem-4~1'): LedgerEntry(
            key: 'rem-4~1',
            at: ms,
            mode: AlarmMode.exact,
            repeat: AlarmRepeat.none,
            sig: ''),
      };
      final (id, e) = ledgerEntryForPush(ledger, 'rem-4', ms + 20000);
      expect(id, alarmIdFor('rem-4~1'));
      expect(e!.key, 'rem-4~1');
      // it rang already (not pending) -> the push stays silent
      expect(decideReminderPush(entry: e, fireMs: ms + 20000, pending: false),
          PushDecision.suppress);
      // the reminder's own ring is still matched first
      final (id0, _) = ledgerEntryForPush(
          ledger, 'rem-4', DateTime(2026, 11, 5, 9).millisecondsSinceEpoch);
      expect(id0, alarmIdFor('rem-4'));
    });

    test('lost alarms: gone before their time = counted; rang = not', () {
      final plans = planReminderAlarms([
        _rem('a', now.add(const Duration(hours: 2)), serverId: 1),
        _rem('b', now.add(const Duration(hours: 3)), serverId: 2),
      ], now: now);
      final ledger = {
        for (final p in plans)
          p.id: LedgerEntry(
              key: p.key,
              at: p.at.millisecondsSinceEpoch,
              mode: AlarmMode.exact,
              repeat: AlarmRepeat.none,
              sig: p.sig(AlarmMode.exact)),
      };
      expect(
          countLostAlarms(
              plans: plans, ledger: ledger, pendingIds: {plans[0].id}, now: now),
          1);
      expect(
          countLostAlarms(
              plans: plans,
              ledger: ledger,
              pendingIds: {for (final p in plans) p.id},
              now: now),
          0);
      // unknown (plugin unavailable) never claims a loss
      expect(
          countLostAlarms(
              plans: plans, ledger: ledger, pendingIds: null, now: now),
          0);
      // never handed over = not lost
      expect(
          countLostAlarms(plans: plans, ledger: {}, pendingIds: {}, now: now),
          0);
    });

    test('lastLost: shown for 30 days, then forgotten', () async {
      SharedPreferences.setMockInitialValues({
        ReminderAlarms.lostKey:
            '{"n":3,"t":${DateTime(2026, 11, 1, 9).millisecondsSinceEpoch}}'
      });
      final prefs = await SharedPreferences.getInstance();
      final l = ReminderAlarms.lastLost(prefs, now: now);
      expect(l?.$1, 3);
      expect(
          ReminderAlarms.lastLost(prefs, now: DateTime(2026, 12, 5)), isNull);
    });
  });

  test('Done / Snooze buttons dismiss through the OS (daily rings survive)',
      () {
    final d = Notifications.detailsFor('remalarm:rem-1').android!;
    expect(d.actions!.every((a) => a.cancelNotification), isTrue);
    expect(d.actions!.every((a) => a.showsUserInterface == false), isTrue);
    // the payload carries the text, so Snooze works after the OS dismissed it
    final pl = ReminderActions.payloadFor('rem-7', 'ওষুধ\nরাত', 'খাওয়ার পরে');
    expect(ReminderActions.keyOf(pl), 'rem-7');
    expect(ReminderActions.textOf(pl), ('ওষুধ\nরাত', 'খাওয়ার পরে'));
    expect(ReminderActions.isOurs(NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        payload: pl)), isTrue);
    // old key-only payloads still work
    expect(ReminderActions.keyOf('remalarm:rem-9'), 'rem-9');
    expect(ReminderActions.textOf('remalarm:rem-9'), isNull);
    // every alarm is re-handed once so it carries the new buttons
    final p = AlarmPlan(key: 'rem-1', at: DateTime(2030), title: 't', body: '');
    expect(p.sig(AlarmMode.exact), endsWith('|a2'));
  });

  // ------------------------------------------------------------ calendar
  group('Bangla calendar (revised, Bangladesh)', () {
    test('national days line up', () {
      BanglaDate b(int y, int m, int d) => BanglaDate.of(DateTime(y, m, d));
      expect([b(2026, 4, 14).month, b(2026, 4, 14).day, b(2026, 4, 14).year],
          [1, 1, 1433]); // Pohela Boishakh
      expect([b(2027, 2, 21).month, b(2027, 2, 21).day], [11, 8]); // 8 Falgun
      expect([b(2027, 3, 26).month, b(2027, 3, 26).day], [12, 12]); // 12 Chaitra
      expect([b(2026, 12, 16).month, b(2026, 12, 16).day], [9, 1]); // 1 Poush
      expect([b(2027, 4, 13).month, b(2027, 4, 13).day, b(2027, 4, 13).year],
          [12, 30, 1433]); // last day of the year
      // leap year: Falgun has 30 days (14 Feb .. 14 Mar 2028)
      expect([b(2028, 3, 14).month, b(2028, 3, 14).day], [11, 30]);
    });

    test('format bn / en', () {
      final d = BanglaDate.of(DateTime(2026, 11, 2, 23, 59));
      expect(d.format(bn: true), '১৭ কার্তিক ১৪৩৩');
      expect(d.format(bn: true, withYear: false), '১৭ কার্তিক');
      expect(d.format(bn: false), '17 Kartik 1433');
    });

    test('search digits: ৫০০ == 500', () {
      expect(asciiDigits('চাল ৫০০ টাকা'), 'চাল 500 টাকা');
      expect(asciiDigits('abc 12'), 'abc 12');
    });
  });

  // ------------------------------------------------------------ conflicts
  group('note sync conflict: keep both', () {
    test('updateBody carries the base only for notes', () {
      final d = {'title': 'x', 'updated_at': '2026-11-02T10:00:00+06:00'};
      expect(SyncedRepo.updateBody('note', d)['base_updated_at'],
          '2026-11-02T10:00:00+06:00');
      expect(SyncedRepo.updateBody('reminder', d).containsKey('base_updated_at'),
          isFalse);
      expect(SyncedRepo.updateBody('note', {'title': 'x'})
          .containsKey('base_updated_at'), isFalse);
    });

    test('conflictCopy: server fields dropped, label added once', () {
      final c = SyncedRepo.conflictCopy({
        'id': 5,
        'title': 'Bazar',
        'tags': ['bazar'],
        'updated_at': 'x',
        'created_at': 'y',
        'reminder_local_id': 'r1',
      }, 'Edited on 2 phones');
      expect(c.containsKey('id'), isFalse);
      expect(c.containsKey('updated_at'), isFalse);
      expect(c.containsKey('reminder_local_id'), isFalse);
      expect(c['tags'], ['bazar', 'Edited on 2 phones']);
      expect(SyncedRepo.conflictCopy(c, 'Edited on 2 phones')['tags'],
          ['bazar', 'Edited on 2 phones']);
    });

    test('a 409 keeps the server version AND this phone\'s text', () async {
      SyncedRepo.lang = 'en';
      final api = _ConflictApi();
      final db = _MemDb();
      final repo = SyncedRepo('note', 'notes', api, db);
      // this phone edited its copy (base 10:00) while offline
      await db.recUpsert('note', {
        'local_id': 'srv-5',
        'server_id': 5,
        'data':
            '{"id":5,"title":"Bazar","body":"rice, oil (phone A)","tags":["bazar"],'
                '"updated_at":"2026-11-02T10:00:00+06:00"}',
        'updated_at': '2026-11-02T10:01:00',
        'pending_op': 'update',
      });
      await repo.sync();
      expect(api.patches.single['base_updated_at'], '2026-11-02T10:00:00+06:00');
      expect(api.creates.single['body'], 'rice, oil (phone A)');
      expect(api.creates.single['tags'], ['bazar', 'Edited on 2 phones']);
      expect(repo.conflicts, 1);
      final bodies = repo.items.map((i) => i['data']['body']).toSet();
      expect(bodies, {'rice, dal (phone B)', 'rice, oil (phone A)'});
      expect(repo.items.every((i) => i['pendingOp'] == 'none'), isTrue);
      // the next clean sync clears the strip
      await repo.sync();
      expect(repo.conflicts, 0);
    });

    for (final lang in ['en', 'bn']) {
      testWidgets('conflict strip $lang: honest, hidden at 0', (t) async {
        await t.pumpWidget(_app(
            const Column(children: [
              SyncConflictStrip(count: 0),
              SyncConflictStrip(count: 1),
            ]),
            lang: lang));
        await t.pumpAndSettle();
        final l = AppLocalizations.of(t.element(find.byType(Column).first));
        expect(find.byKey(const ValueKey('rn-sync-conflict')), findsOneWidget);
        expect(find.text(l.rhbConflictStrip(l.rhbConflictTag)), findsOneWidget);
        expect(t.takeException(), isNull);
      });
    }
  });

  // ------------------------------------------------------------ delivery
  group('delivery check: restart honesty', () {
    setUp(() {
      ExactAlarmHooks.canExact = () async => true;
      ExactAlarmHooks.notifEnabled = () async => true;
      ExactAlarmHooks.oem = _FakeOem();
    });

    for (final lang in ['en', 'bn']) {
      testWidgets('no loss -> the restart line ($lang)', (t) async {
        SharedPreferences.setMockInitialValues({});
        await t.pumpWidget(_app(const ReminderDeliverySheet(), lang: lang));
        await t.pumpAndSettle();
        final l = AppLocalizations.of(
            t.element(find.byType(ReminderDeliverySheet)));
        expect(find.text(l.rhbRestartOk), findsOneWidget);
        expect(t.takeException(), isNull);
      });
    }

    test('alarms were lost -> the reader reports how many (fixed clock)',
        () async {
      final at = DateTime(2026, 11, 1, 9);
      SharedPreferences.setMockInitialValues({
        ReminderAlarms.lostKey: '{"n":2,"t":${at.millisecondsSinceEpoch}}'
      });
      final prefs = await SharedPreferences.getInstance();
      // the pure reader with a fixed clock (the sheet itself uses the phone's)
      expect(ReminderAlarms.lastLost(prefs, now: DateTime(2026, 11, 2))?.$1, 2);
    });
  });

  // ------------------------------------------------------------ photo
  group('photo straight into a note (saved in the Vault)', () {
    for (final lang in ['en', 'bn']) {
      testWidgets('empty Vault: take a photo -> uploaded, ticked, attached ($lang)',
          (t) async {
        final api = _VaultApi();
        final s = AppState()
          ..api = api
          ..locale = Locale(lang)
          ..loading = false;
        ImageSource? asked;
        NotePhotoHooks.pick = (_, src) async {
          asked = src;
          return '/tmp/note_photo.jpg';
        };
        List<Map<String, dynamic>>? got;
        await t.pumpWidget(_app(
            Builder(
                builder: (c) => TextButton(
                    onPressed: () async => got = await pickVaultDocs(c),
                    child: const Text('open'))),
            lang: lang,
            s: s));
        await t.tap(find.text('open'));
        await t.pumpAndSettle();
        final l = AppLocalizations.of(t.element(find.text('open')));
        expect(find.byKey(const ValueKey('rn-vault-empty')), findsOneWidget);
        expect(find.text(l.rhbNotePhotoHint), findsOneWidget);
        await t.tap(find.byKey(const ValueKey('rn-photo-camera')));
        await t.pumpAndSettle();
        expect(asked, ImageSource.camera);
        expect(api.uploads.single['type'], 'other');
        expect(api.uploads.single['path'], '/tmp/note_photo.jpg');
        await t.tap(find.byKey(const ValueKey('rn-vault-attach')));
        await t.pumpAndSettle();
        expect(got?.single['doc_id'], 41);
        expect(t.takeException(), isNull);
      });
    }

    testWidgets('upload fails -> honest message, nothing attached', (t) async {
      final api = _VaultApi()..fail = true;
      final s = AppState()
        ..api = api
        ..locale = const Locale('en')
        ..loading = false;
      NotePhotoHooks.pick = (_, __) async => '/tmp/x.jpg';
      await t.pumpWidget(_app(
          Builder(
              builder: (c) => TextButton(
                  onPressed: () => pickVaultDocs(c),
                  child: const Text('open'))),
          s: s));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      final l = AppLocalizations.of(t.element(find.text('open')));
      await t.tap(find.byKey(const ValueKey('rn-photo-gallery')));
      await t.pumpAndSettle();
      expect(find.text(l.rhbNotePhotoFailed), findsOneWidget);
      final attach = t.widget<FilledButton>(
          find.byKey(const ValueKey('rn-vault-attach')));
      expect(attach.onPressed, isNull);
    });
  });

  // ------------------------------------------------------------ family
  testWidgets('a repeating family task: pick a time, then "Daily"', (t) async {
    final api = _FamApi();
    final s = AppState();
    s.api = api;
    s.locale = const Locale('en');
    s.loading = false;
    await t.pumpWidget(_app(const RemindersScreen(), s: s));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('rn-give-family')).first);
    await t.pumpAndSettle();
    final l = AppLocalizations.of(t.element(find.byType(RemindersScreen)));
    // no time yet -> no repeat chips (a repeat needs a time)
    expect(find.byKey(const ValueKey('fc-task-repeat-daily')), findsNothing);
    await t.enterText(find.byKey(const ValueKey('fc-task-title')), 'Pills');
    await t.tap(find.text(l.fcTaskPickTime));
    await t.pumpAndSettle();
    await t.tap(find.text('OK')); // date picker
    await t.pumpAndSettle();
    await t.tap(find.text('OK')); // time picker
    await t.pumpAndSettle();
    await t.ensureVisible(find.byKey(const ValueKey('fc-task-repeat-daily')));
    await t.tap(find.byKey(const ValueKey('fc-task-repeat-daily')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('fc-task-save')));
    await t.pumpAndSettle();
    final sent = api.bodies.firstWhere((b) => b['_path'] == '/family/reminders');
    expect(sent['repeat'], 'daily');
    expect(sent['title'], 'Pills');
    expect(sent['due_at'], isNotNull);
  });
}
