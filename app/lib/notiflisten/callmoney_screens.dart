import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../reminders/exact_alarm_ui.dart';
import '../screens/money_common.dart';
import '../services/action_feedback.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import '../widgets/local_counter.dart';
import '../widgets/money_digits.dart';
import '../widgets/rn_bits.dart' show pickCircleMember;
import '../widgets/voice_input.dart';
import 'callnote_drafts.dart';
import 'money_notif_parser.dart';
import 'notif_listen_channel.dart';
import 'notif_listen_service.dart';

/// callmoney — the screens of AFTER CALL NOTE + MONEY FROM NOTIFICATIONS.
///
/// * [CallMoneySettingsScreen]: the two switches (each behind its own
///   prominent disclosure), the Android access status, the easy OFF switch,
///   the monthly summary per wallet and a "write a call note now" button that
///   works even without notification access.
/// * [NotifConsentScreen]: the Play User Data policy disclosure + consent.
/// * [MoneyNotifReviewScreen]: "Save to khata as income or expense?" per item.
/// * [showCallNoteSheet]: "Call ended — anything to remember?" -> drafts ->
///   each saved ONLY after Confirm. Calls are NEVER recorded.

String _d2(int v) => v.toString().padLeft(2, '0');

String _when(BuildContext context, DateTime d, {bool dateOnly = false}) {
  final s = dateOnly ? '${d.day}/${d.month}/${d.year}' : '${d.day}/${d.month}/${d.year} ${_d2(d.hour)}:${_d2(d.minute)}';
  return moneyDigitsFor(context, s);
}

// =====================================================================
// Settings
// =====================================================================

class CallMoneySettingsScreen extends StatefulWidget {
  const CallMoneySettingsScreen({super.key});
  @override
  State<CallMoneySettingsScreen> createState() => _CallMoneySettingsScreenState();
}

class _CallMoneySettingsScreenState extends State<CallMoneySettingsScreen>
    with WidgetsBindingObserver {
  NotifListenStatus _st = const NotifListenStatus();
  bool _callNote = false, _money = false, _auto = false, _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh(); // back from Android Settings
  }

  Future<void> _refresh() async {
    final s = await NotifListenService.load();
    final st = await NotifListenService.bridge.status();
    if (!mounted) return;
    setState(() {
      _st = st;
      _callNote = s.callNote;
      _money = s.money;
      _auto = s.auto;
      _loaded = true;
    });
  }

  Future<void> _set({bool? callNote, bool? money, bool? auto}) async {
    final t = AppLocalizations.of(context);
    final lang = Localizations.localeOf(context).languageCode;
    try {
      // turning ON needs the disclosure + consent first
      if (callNote == true && !await NotifListenService.hasConsent(NotifListenPrefs.consentCall)) {
        if (!mounted) return;
        final ok = await Navigator.push<bool>(context,
            MaterialPageRoute(builder: (_) => const NotifConsentScreen(feature: 'call')));
        if (ok != true) return;
      }
      if (money == true && !await NotifListenService.hasConsent(NotifListenPrefs.consentMoney)) {
        if (!mounted) return;
        final ok = await Navigator.push<bool>(context,
            MaterialPageRoute(builder: (_) => const NotifConsentScreen(feature: 'money')));
        if (ok != true) return;
      }
      final r = await NotifListenService.apply(t, lang,
          callNote: callNote ?? _callNote, money: money ?? _money, auto: auto ?? _auto);
      if (!mounted) return;
      setState(() {
        _callNote = r.callNote;
        _money = r.money;
        _auto = r.auto;
      });
      final turnedOn = callNote == true || money == true;
      if (turnedOn && _st.available && !_st.granted) {
        await NotifListenService.bridge.openAccessSettings();
      }
      await _refresh();
    } catch (e) {
      if (mounted) showActionFailed(context, 'callmoney.set', e);
    }
  }

  Future<void> _allOff() => _set(callNote: false, money: false, auto: false);

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final app = context.watch<AppState>();
    final months = _money
        ? NotifListenService.monthlyByWallet(app, t, dhakaNow())
        : const <WalletMonth>[];
    return Scaffold(
      appBar: AppBar(title: Text(t.clnSettingsTitle)),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              key: const ValueKey('cmn_settings_list'),
              padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
              children: [
                Text(t.clnSettingsBenefit, style: Theme.of(context).textTheme.bodyLarge),
                const SizedBox(height: Gap.md),
                _NeverRecorded(text: t.clnNeverRecorded),
                const SizedBox(height: Gap.lg),
                if (!_st.available)
                  _InfoCard(icon: Icons.info_outline_rounded, text: t.clnNotAvailable)
                else
                  _AccessCard(
                    granted: _st.granted,
                    anyOn: _callNote || _money,
                    onOpen: () async {
                      final m = ScaffoldMessenger.of(context);
                      await NotifListenService.bridge.openAccessSettings();
                      m.showSnackBar(SnackBar(content: Text(t.clnDiscAccessNote)));
                    },
                  ),
                const SizedBox(height: Gap.md),
                Card(
                  child: Column(children: [
                    SwitchListTile(
                      key: const ValueKey('cmn_switch_call'),
                      secondary: const Icon(Icons.call_end_rounded),
                      title: Text(t.clnCallNoteTitle),
                      subtitle: Text(t.clnCallNoteSub),
                      value: _callNote,
                      onChanged: (v) => _set(callNote: v),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      key: const ValueKey('cmn_switch_money'),
                      secondary: const Icon(Icons.account_balance_wallet_rounded),
                      title: Text(t.clnMoneyTitle),
                      subtitle: Text(t.clnMoneySub),
                      value: _money,
                      onChanged: (v) => _set(money: v),
                    ),
                    if (_money) ...[
                      const Divider(height: 1),
                      SwitchListTile(
                        key: const ValueKey('cmn_switch_auto'),
                        secondary: const Icon(Icons.bolt_rounded),
                        title: Text(t.clnAutoTitle),
                        subtitle: Text(t.clnAutoSub),
                        value: _auto,
                        onChanged: (v) => _set(auto: v),
                      ),
                    ],
                  ]),
                ),
                if (_callNote || _money) ...[
                  const SizedBox(height: Gap.sm),
                  OutlinedButton.icon(
                    key: const ValueKey('cmn_all_off'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    onPressed: _allOff,
                    icon: const Icon(Icons.power_settings_new_rounded),
                    label: Text(t.clnTurnAllOff),
                  ),
                ],
                const SizedBox(height: Gap.lg),
                FilledButton.icon(
                  key: const ValueKey('cmn_write_now'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  onPressed: () => showCallNoteSheet(context,
                      const NotifLaunch(kind: 'callnote', mode: 'type', source: '')),
                  icon: const Icon(Icons.edit_note_rounded),
                  label: Text(t.clnWriteNow),
                ),
                const SizedBox(height: Gap.xl),
                Text(t.clnMonthTitle, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: Gap.sm),
                if (!_money)
                  _InfoCard(icon: Icons.pie_chart_outline_rounded, text: t.clnMonthOff)
                else if (months.isEmpty)
                  _InfoCard(icon: Icons.pie_chart_outline_rounded, text: t.clnMonthEmpty)
                else
                  for (final w in months) _WalletMonthTile(w: w),
                if (_money) ...[
                  const SizedBox(height: Gap.md),
                  OutlinedButton.icon(
                    key: const ValueKey('cmn_review'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    onPressed: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const MoneyNotifReviewScreen())),
                    icon: const Icon(Icons.fact_check_rounded),
                    label: Text(t.clnReviewWaiting),
                  ),
                ],
                const SizedBox(height: Gap.lg),
                Text(t.clnPrivacyFoot,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
    );
  }
}

class _NeverRecorded extends StatelessWidget {
  final String text;
  const _NeverRecorded({required this.text});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
          color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Icon(Icons.mic_off_rounded, color: scheme.onSecondaryContainer),
        const SizedBox(width: Gap.md),
        Expanded(child: Text(text, style: TextStyle(color: scheme.onSecondaryContainer))),
      ]),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoCard({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Row(children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: Gap.md),
            Expanded(child: Text(text)),
          ]),
        ),
      );
}

class _AccessCard extends StatelessWidget {
  final bool granted;
  final bool anyOn;
  final VoidCallback onOpen;
  const _AccessCard({required this.granted, required this.anyOn, required this.onOpen});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final ok = granted;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(ok ? Icons.check_circle_rounded : Icons.notifications_off_rounded,
                color: ok ? AssistoTokens.of(context).success : scheme.error),
            const SizedBox(width: Gap.md),
            Expanded(
                child: Text(ok ? t.clnAccessOn : t.clnAccessOff,
                    style: Theme.of(context).textTheme.titleSmall)),
          ]),
          const SizedBox(height: Gap.sm),
          Text(ok ? t.clnAccessOnHelp : t.clnAccessOffHelp),
          const SizedBox(height: Gap.sm),
          TextButton.icon(
            key: const ValueKey('cmn_open_access'),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: onOpen,
            icon: const Icon(Icons.open_in_new_rounded),
            label: Text(ok ? t.clnAccessManage : t.clnAccessOpen),
          ),
        ]),
      ),
    );
  }
}

class _WalletMonthTile extends StatelessWidget {
  final WalletMonth w;
  const _WalletMonthTile({required this.w});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final tk = AssistoTokens.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(w.name, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.lg, runSpacing: Gap.xs, children: [
            Text(t.clnMonthIncome(tkOf(context, w.income)), style: TextStyle(color: tk.success)),
            Text(t.clnMonthExpense(tkOf(context, w.expense)), style: TextStyle(color: tk.warning)),
            Text(t.clnMonthNet(tkOf(context, w.net))),
            Text(t.clnMonthCount(moneyDigitsFor(context, '${w.count}'))),
          ]),
        ]),
      ),
    );
  }
}

// =====================================================================
// Prominent disclosure + consent
// =====================================================================

class NotifConsentScreen extends StatelessWidget {
  /// 'call' (after-call note) or 'money' (money from notifications)
  final String feature;
  const NotifConsentScreen({super.key, required this.feature});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final money = feature == 'money';
    final points = money
        ? [t.clnDiscMoney1, t.clnDiscMoney2, t.clnDiscMoney3, t.clnDiscMoney4, t.clnDiscMoney5]
        : [t.clnDiscCall1, t.clnDiscCall2, t.clnDiscCall3, t.clnDiscCall4, t.clnDiscCall5];
    final key = money ? NotifListenPrefs.consentMoney : NotifListenPrefs.consentCall;
    return Scaffold(
      appBar: AppBar(title: Text(t.clnDiscTitle)),
      body: ListView(
        key: ValueKey('cmn_consent_$feature'),
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          Icon(money ? Icons.account_balance_wallet_rounded : Icons.call_end_rounded,
              size: 48, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: Gap.md),
          Text(money ? t.clnMoneyTitle : t.clnCallNoteTitle,
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: Gap.sm),
          Text(money ? t.clnDiscMoneyLead : t.clnDiscCallLead,
              style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: Gap.lg),
          for (final p in points)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.md),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Icon(Icons.check_rounded, size: 20),
                ),
                const SizedBox(width: Gap.sm),
                Expanded(child: Text(p)),
              ]),
            ),
          const SizedBox(height: Gap.sm),
          Text(t.clnDiscAccessNote, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: Gap.xl),
          FilledButton(
            key: ValueKey('cmn_agree_$feature'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: () async {
              try {
                await NotifListenService.recordConsent(key, true);
                if (context.mounted) Navigator.pop(context, true);
              } catch (e) {
                if (context.mounted) showActionFailed(context, 'callmoney.consent', e);
              }
            },
            child: Text(t.clnDiscAgree),
          ),
          const SizedBox(height: Gap.sm),
          TextButton(
            key: ValueKey('cmn_decline_$feature'),
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.clnDiscNotNow),
          ),
        ],
      ),
    );
  }
}

// =====================================================================
// Money review: "Save to khata as income or expense?"
// =====================================================================

class _Row {
  final MoneyQueueItem q;
  final MoneyNotif p;
  String? kind; // the user's choice; preselected from the parse
  bool dup;
  _Row(this.q, this.p, this.dup) : kind = p.type;
}

class MoneyNotifReviewScreen extends StatefulWidget {
  /// From a prompt tap: highlight this queue item and pre-pick its kind.
  final int focusId;
  final String? presetKind;
  const MoneyNotifReviewScreen({super.key, this.focusId = 0, this.presetKind});
  @override
  State<MoneyNotifReviewScreen> createState() => _MoneyNotifReviewScreenState();
}

class _MoneyNotifReviewScreenState extends State<MoneyNotifReviewScreen> {
  List<_Row>? _rows;
  bool _on = true;
  final _busy = <int>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    final s = await NotifListenService.load();
    final rows = <_Row>[];
    final drop = <int>[];
    for (final q in await NotifListenService.bridge.takeMoneyQueue()) {
      final p = MoneyNotifParser.parse(q.text, wallet: q.wallet, postedAt: q.at);
      if (!p.ok && (p.reason == 'otp' || p.reason == 'promo' || p.reason == 'no_proof')) {
        drop.add(q.id); // not a transaction: never shown, never saved
        continue;
      }
      final r = _Row(q, p, p.ok && await NotifListenService.isDuplicate(app, p));
      if (q.id == widget.focusId && widget.presetKind != null) r.kind = widget.presetKind;
      rows.add(r);
    }
    if (drop.isNotEmpty) await NotifListenService.bridge.moneyDone(drop);
    rows.sort((a, b) => (b.q.id == widget.focusId ? 1 : 0) - (a.q.id == widget.focusId ? 1 : 0));
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _on = s.money;
    });
  }

  Future<void> _save(_Row r) async {
    final t = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final kind = r.kind;
    if (kind == null) return;
    setState(() => _busy.add(r.q.id));
    try {
      final ok = await NotifListenService.saveConfirmed(app, t, r.p, kind, queueId: r.q.id);
      if (!mounted) return;
      if (ok) {
        setState(() => _rows!.remove(r));
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.clnSaved)));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.clnSaveOffline)));
      }
    } catch (e) {
      if (mounted) showActionFailed(context, 'callmoney.save', e);
    } finally {
      if (mounted) setState(() => _busy.remove(r.q.id));
    }
  }

  Future<void> _ignore(_Row r) async {
    try {
      await NotifListenService.bridge.moneyDone([r.q.id]);
      if (mounted) setState(() => _rows!.remove(r));
    } catch (e) {
      if (mounted) showActionFailed(context, 'callmoney.ignore', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final rows = _rows;
    return Scaffold(
      appBar: AppBar(title: Text(t.clnReviewTitle)),
      body: rows == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              key: const ValueKey('cmn_review_list'),
              padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
              children: [
                if (rows.isEmpty) ...[
                  _InfoCard(
                      icon: Icons.account_balance_wallet_rounded,
                      text: _on ? t.clnReviewEmpty : t.clnReviewOff),
                  const SizedBox(height: Gap.md),
                  Text(t.clnReviewHowTo),
                  const SizedBox(height: Gap.lg),
                  FilledButton.icon(
                    key: const ValueKey('cmn_review_settings'),
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    onPressed: () => Navigator.pushReplacement(context,
                        MaterialPageRoute(builder: (_) => const CallMoneySettingsScreen())),
                    icon: const Icon(Icons.tune_rounded),
                    label: Text(_on ? t.clnOpenSettings : t.clnTurnOn),
                  ),
                ] else ...[
                  Text(t.clnReviewLead),
                  const SizedBox(height: Gap.md),
                  for (final r in rows) _rowCard(context, r),
                ],
              ],
            ),
    );
  }

  Widget _rowCard(BuildContext context, _Row r) {
    final t = AppLocalizations.of(context);
    final tk = AssistoTokens.of(context);
    final p = r.p;
    final busy = _busy.contains(r.q.id);
    final focus = r.q.id == widget.focusId;
    return Card(
      key: ValueKey('cmn_row_${r.q.id}'),
      shape: focus
          ? RoundedRectangleBorder(
              side: BorderSide(color: Theme.of(context).colorScheme.primary, width: 2),
              borderRadius: BorderRadius.circular(12))
          : null,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Chip(label: Text(walletLabel(t, p.wallet))),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(p.amount == null ? t.clnAmountUnknown : tkOf(context, p.amount),
                  style: Theme.of(context).textTheme.titleLarge),
            ),
          ]),
          if ((p.counterparty ?? '').isNotEmpty)
            Text(t.clnWith(p.counterparty!)),
          if (p.date != null) Text(_when(context, p.date!)),
          if (p.fee != null && p.fee! > 0) Text(t.clnFee(tkOf(context, p.fee))),
          if ((p.trxId ?? '').isNotEmpty) Text(t.clnTrx(p.trxId!)),
          const SizedBox(height: Gap.xs),
          Text(r.q.text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall),
          if (!p.ok) ...[
            const SizedBox(height: Gap.xs),
            Text(t.clnUnclear, style: TextStyle(color: Brand.warnInk(context))),
          ],
          if (r.dup) ...[
            const SizedBox(height: Gap.xs),
            Text(t.clnDuplicate, style: TextStyle(color: Brand.warnInk(context))),
          ],
          const SizedBox(height: Gap.sm),
          Text(t.clnSaveAsQ, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            ChoiceChip(
              key: ValueKey('cmn_inc_${r.q.id}'),
              avatar: Icon(Icons.south_west_rounded, color: tk.success, size: 18),
              label: Text(t.clnIncome),
              selected: r.kind == 'income',
              onSelected: p.amount == null ? null : (_) => setState(() => r.kind = 'income'),
            ),
            ChoiceChip(
              key: ValueKey('cmn_exp_${r.q.id}'),
              avatar: Icon(Icons.north_east_rounded, color: tk.warning, size: 18),
              label: Text(t.clnExpense),
              selected: r.kind == 'expense',
              onSelected: p.amount == null ? null : (_) => setState(() => r.kind = 'expense'),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          Row(children: [
            Expanded(
              child: FilledButton(
                key: ValueKey('cmn_save_${r.q.id}'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: busy || r.kind == null || p.amount == null ? null : () => _save(r),
                child: Text(t.clnSaveToKhata),
              ),
            ),
            const SizedBox(width: Gap.sm),
            TextButton(
              key: ValueKey('cmn_ignore_${r.q.id}'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: busy ? null : () => _ignore(r),
              child: Text(t.clnIgnore),
            ),
          ]),
        ]),
      ),
    );
  }
}

// =====================================================================
// After-call note sheet
// =====================================================================

Future<void> showCallNoteSheet(BuildContext context, NotifLaunch l) => showAppSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => CallNoteSheet(launch: l),
    );

class CallNoteSheet extends StatefulWidget {
  final NotifLaunch launch;
  /// Tests: skip the network and use the on-device rules only.
  final bool offline;
  const CallNoteSheet({super.key, required this.launch, this.offline = false});
  @override
  State<CallNoteSheet> createState() => _CallNoteSheetState();
}

class _CallNoteSheetState extends State<CallNoteSheet> {
  final _text = TextEditingController();
  final _voice = VoiceDictation();
  List<CallNoteDraft>? _drafts;
  final _saved = <CallNoteDraft>{};
  final _skipped = <CallNoteDraft>{};
  bool _thinking = false;
  String? _aiNote; // honest line when the phone's rules were used

  @override
  void initState() {
    super.initState();
    if (widget.launch.mode == 'voice') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_voice.start(context, _text));
      });
    }
  }

  @override
  void dispose() {
    _voice.dispose();
    _text.dispose();
    super.dispose();
  }

  String _src(AppLocalizations t) => switch (widget.launch.source) {
        'sim' => t.clnSrcSim,
        'whatsapp' => t.clnSrcWhatsapp,
        'messenger' => t.clnSrcMessenger,
        _ => '',
      };

  Future<void> _understand() async {
    final t = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final text = _text.text.trim();
    if (text.isEmpty) return;
    unawaited(_voice.stop());
    setState(() {
      _thinking = true;
      _aiNote = null;
    });
    List<CallNoteDraft>? drafts;
    String? note;
    if (!widget.offline && app.loggedIn) {
      try {
        final now = dhakaNow();
        final r = await app.api.callNoteUnderstand(text,
            '${now.year}-${_d2(now.month)}-${_d2(now.day)}T${_d2(now.hour)}:${_d2(now.minute)}');
        if (r['ok'] == true && r['items'] is List) {
          drafts = CallNoteUnderstand.fromServer(r['items'] as List, fallbackTitle: text);
        } else {
          note = '${r['detail'] ?? t.clnPhoneRules}';
        }
      } catch (_) {
        note = t.clnPhoneRules; // offline: the on-device rules below
      }
    } else {
      note = t.clnPhoneRules;
    }
    if (drafts == null || drafts.isEmpty) {
      drafts = CallNoteUnderstand.onDevice(text, now: dhakaNow());
    }
    if (!mounted) return;
    setState(() {
      _drafts = drafts;
      _aiNote = note;
      _thinking = false;
    });
  }

  /// The ONLY place a call-note item is written — on the user's Confirm tap.
  Future<void> _confirm(CallNoteDraft d) async {
    final t = AppLocalizations.of(context);
    final app = context.read<AppState>();
    try {
      switch (d.kind) {
        case CallNoteKind.reminder:
          await app.reminders.add(CallNoteSaver.reminderPayload(d));
          if (d.dueAt != null && !d.dateOnly && mounted) await maybeAskExactAlarms(context);
        case CallNoteKind.note:
          await app.notes.add(CallNoteSaver.notePayload(d));
        case CallNoteKind.due:
          await app.loans.add(CallNoteSaver.duePayload(d, dhakaNow()));
      }
      if (!mounted) return;
      setState(() => _saved.add(d));
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(t.clnSaved)));
    } catch (e) {
      if (mounted) showActionFailed(context, 'callmoney.callnote', e);
    }
  }

  Future<void> _pickTime(CallNoteDraft d) async {
    final now = DateTime.now();
    final day = await showDatePicker(
        context: context,
        initialDate: d.dueAt ?? now,
        firstDate: DateTime(now.year, now.month, now.day),
        lastDate: DateTime(now.year + 3));
    if (day == null || !mounted) return;
    final tm = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(d.dueAt ?? now.add(const Duration(hours: 1))));
    if (!mounted) return;
    setState(() {
      d.dueAt = DateTime(day.year, day.month, day.day, tm?.hour ?? 9, tm?.minute ?? 0);
      d.dateOnly = tm == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final src = _src(t);
    final drafts = _drafts;
    final allDone = drafts != null && drafts.every((d) => _saved.contains(d) || _skipped.contains(d));
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            left: Gap.lg, right: Gap.lg, top: Gap.lg,
            bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg),
        child: SingleChildScrollView(
          key: const ValueKey('cmn_callnote_sheet'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Text(t.clnCallEndedTitle, style: Theme.of(context).textTheme.titleLarge),
            if (src.isNotEmpty) Text(t.clnCallFrom(src)),
            const SizedBox(height: Gap.sm),
            _NeverRecorded(text: t.clnNeverRecordedShort),
            const SizedBox(height: Gap.md),
            if (drafts == null) ...[
              TextField(
                key: const ValueKey('cmn_callnote_text'),
                controller: _text,
                minLines: 2,
                maxLines: 5,
                maxLength: 600,
                buildCounter: localCounter,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: t.clnCallNoteHint,
                  border: const OutlineInputBorder(),
                  suffixIcon: VoiceMicButton(voice: _voice, input: _text),
                ),
              ),
              const SizedBox(height: Gap.sm),
              Text(t.clnCallNoteExamples, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: Gap.md),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _text,
                builder: (context, v, _) => FilledButton.icon(
                  key: const ValueKey('cmn_callnote_go'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  onPressed: _thinking || v.text.trim().isEmpty ? null : _understand,
                  icon: _thinking
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.auto_awesome_rounded),
                  label: Text(t.clnCallNoteGo),
                ),
              ),
            ] else ...[
              if (_aiNote != null) ...[
                Text(_aiNote!, style: TextStyle(color: Brand.warnInk(context))),
                const SizedBox(height: Gap.sm),
              ],
              Text(t.clnConfirmLead),
              const SizedBox(height: Gap.sm),
              for (var i = 0; i < drafts.length; i++) _draftCard(context, drafts[i], i),
              const SizedBox(height: Gap.sm),
              if (allDone)
                FilledButton(
                  key: const ValueKey('cmn_callnote_done'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: Text(t.clnDone),
                )
              else
                TextButton(
                  key: const ValueKey('cmn_callnote_back'),
                  style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  onPressed: () => setState(() {
                    _drafts = null;
                    _saved.clear();
                    _skipped.clear();
                  }),
                  child: Text(t.clnEditWords),
                ),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _draftCard(BuildContext context, CallNoteDraft d, int i) {
    final t = AppLocalizations.of(context);
    final saved = _saved.contains(d);
    final skipped = _skipped.contains(d);
    final (icon, label) = switch (d.kind) {
      CallNoteKind.reminder => (Icons.alarm_rounded, t.clnKindReminder),
      CallNoteKind.note => (Icons.sticky_note_2_rounded, t.clnKindNote),
      CallNoteKind.due => (Icons.menu_book_rounded, t.clnKindDue),
    };
    return Card(
      key: ValueKey('cmn_draft_$i'),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text(label, style: Theme.of(context).textTheme.titleSmall)),
          ]),
          const SizedBox(height: Gap.xs),
          Text(d.title),
          if (d.kind == CallNoteKind.reminder)
            TextButton.icon(
              key: ValueKey('cmn_draft_time_$i'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: saved || skipped ? null : () => _pickTime(d),
              icon: const Icon(Icons.schedule_rounded),
              label: Text(d.dueAt == null ? t.clnPickTime : _when(context, d.dueAt!, dateOnly: d.dateOnly)),
            ),
          if (d.kind == CallNoteKind.due) ...[
            const SizedBox(height: Gap.xs),
            Text(d.amount == null ? t.clnAmountUnknown : tkOf(context, d.amount)),
            Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
              ChoiceChip(
                key: ValueKey('cmn_draft_they_$i'),
                label: Text(t.clnTheyOwe),
                selected: d.theyOwe,
                onSelected: saved || skipped ? null : (_) => setState(() => d.theyOwe = true),
              ),
              ChoiceChip(
                key: ValueKey('cmn_draft_i_$i'),
                label: Text(t.clnIOwe),
                selected: !d.theyOwe,
                onSelected: saved || skipped ? null : (_) => setState(() => d.theyOwe = false),
              ),
            ]),
            TextButton.icon(
              key: ValueKey('cmn_draft_person_$i'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: saved || skipped
                  ? null
                  : () async {
                      final m = await pickCircleMember(context, title: t.clnPickPerson);
                      final n = '${m?['name'] ?? ''}'.trim();
                      if (n.isNotEmpty && mounted) setState(() => d.person = n);
                    },
              icon: const Icon(Icons.diversity_1_rounded),
              label: Text((d.person ?? '').isEmpty ? t.clnPickPerson : d.person!),
            ),
          ],
          const SizedBox(height: Gap.sm),
          if (saved)
            Text(t.clnSaved, style: TextStyle(color: AssistoTokens.of(context).success))
          else if (skipped)
            Text(t.clnSkipped)
          else
            Row(children: [
              Expanded(
                child: FilledButton(
                  key: ValueKey('cmn_draft_ok_$i'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  onPressed: d.complete ? () => _confirm(d) : null,
                  child: Text(t.clnConfirm),
                ),
              ),
              const SizedBox(width: Gap.sm),
              TextButton(
                key: ValueKey('cmn_draft_skip_$i'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => setState(() => _skipped.add(d)),
                child: Text(t.clnSkip),
              ),
            ]),
          if (d.kind == CallNoteKind.due && !d.complete && !saved && !skipped)
            Text(t.clnDueNeedsPerson, style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    );
  }
}
