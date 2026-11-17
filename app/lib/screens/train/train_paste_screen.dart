import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../api.dart'; // train-e2e: ApiException
import '../../ds/ds.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../train/train_api.dart';
import '../../train/train_offline.dart';
import '../../train/train_onboard.dart' show trainForegroundFix;
import '../../train/train_sms_parse.dart';
import '../../train/train_v2_native.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset;
import '../../widgets/local_counter.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;

/// train-app (Train Tracker V2, F): "Share a train update". The user pastes
/// — or shares from another app with Android's Share → Assisto — ANY text:
/// the 16318 SMS reply, a Facebook / Telegram / WhatsApp group post. We show
/// at once what we understood (train, station, reached / left, time,
/// delay), and send it to the server, which parses it again and checks it
/// against riders and other reports before it updates everyone.
/// Assisto NEVER reads SMS (no READ_SMS) or any other app by itself.
class TrainPasteScreen extends StatefulWidget {
  const TrainPasteScreen({super.key, this.no, this.date, this.initialText, this.stations = const []});

  /// the train screen it was opened from (null = from the share sheet)
  final String? no, date;
  final String? initialText;

  /// stations the on-phone preview can recognise (the train's line, or
  /// every station of the offline pack)
  final List<TrainSmsStation> stations;

  static const int maxLen = 2000;

  @override
  State<TrainPasteScreen> createState() => _TrainPasteScreenState();
}

class _TrainPasteScreenState extends State<TrainPasteScreen> {
  late final TextEditingController _c = TextEditingController(text: widget.initialText ?? '');
  bool _busy = false;
  String? _result;
  bool _resultOk = false;
  List<TrainSmsStation> _stations = const [];

  @override
  void initState() {
    super.initState();
    _stations = widget.stations;
    if (_stations.isEmpty) unawaited(_loadStations());
    _c.addListener(() => setState(() => _result = null));
  }

  /// No line given (opened from the share sheet): every station of the
  /// offline pack, when the phone has it.
  Future<void> _loadStations() async {
    final p = await TrainOfflineStore.I.load();
    if (p == null || !mounted) return;
    final seen = <String>{};
    final out = <TrainSmsStation>[];
    for (final tr in p.trains.values) {
      for (final s in tr.stops) {
        if (seen.add(s.id)) out.add(TrainSmsStation(s.id, s.bn, s.en));
      }
    }
    setState(() => _stations = out);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  TrainSmsReply? get _preview =>
      parseTrain16318(_c.text, stations: _stations, expectNo: widget.no);

  Future<void> _paste() async {
    try {
      final d = await Clipboard.getData(Clipboard.kTextPlain);
      final s = d?.text ?? '';
      if (s.isEmpty) return;
      _c.text = s.length > TrainPasteScreen.maxLen ? s.substring(0, TrainPasteScreen.maxLen) : s;
    } catch (_) {
      // best-effort: long-press paste in the box still works
    }
  }

  Future<void> _send() async {
    final t = AppLocalizations.of(context);
    final text = _c.text.trim();
    if (text.isEmpty || _busy) return;
    final body = <String, dynamic>{
      'text': text,
      if (widget.no != null) 'no': widget.no,
      if (widget.date != null) 'date': widget.date,
      'source': widget.initialText != null && widget.no == null ? 'share' : 'paste',
      'at': DateTime.now().toUtc().toIso8601String(),
    };
    setState(() => _busy = true);
    final api = context.read<AppState>().api;
    // at the station? the position lets the report count on its own
    // (only when location is already allowed; never asked here)
    final fix = TrainNative.disabledForTests ? null : await trainForegroundFix();
    if (fix != null && !fix.mock) {
      body.addAll({'lat': fix.lat, 'lng': fix.lng, 'acc': fix.acc});
    }
    if (!mounted) return;
    String msg;
    var ok = false;
    try {
      final r = await api.trainText(body);
      if (r['parsed'] == null) {
        msg = t.tr2TextUnparsed;
      } else {
        ok = true;
        msg = r['applied'] == true ? t.tr2TextApplied : t.tr2TextChecking;
      }
    } on ApiException catch (e) {
      // train-e2e: the server answered "no" (too many reports, switch off) —
      // never "saved, sent later" for a report the outbox would then drop
      if ((e.status ?? 500) >= 500) {
        await TrainOutbox.I.add(TrainOutItem('text', widget.no ?? _preview?.no ?? '', body));
        ok = true;
        msg = t.tr2Queued;
      } else {
        msg = t.tr2ReportNotTaken;
      }
    } catch (_) {
      // no internet: kept on the phone, sent later (never lost)
      await TrainOutbox.I.add(TrainOutItem('text', widget.no ?? _preview?.no ?? '', body));
      ok = true;
      msg = t.tr2Queued;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = msg;
      _resultOk = ok;
    });
  }

  String _kindLine(AppLocalizations t, TrainSmsReply r) {
    final st = r.stationName(Localizations.localeOf(context).languageCode == 'bn');
    if (st.isEmpty) return '';
    return switch (r.kind) {
      'reached' => t.tr2KindReached(st),
      'left' => t.tr2KindLeft(st),
      _ => t.tr2KindAt(st),
    };
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final ds = Theme.of(context).colorScheme.ds;
    String d(String s) => notifLocalizeDigits(context, s);
    final p = _preview;
    final hasText = _c.text.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: Text(t.tr2PasteTitle)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl)),
        children: [
          Text(t.tr2PasteBody, style: AType.bodyMedium),
          const SizedBox(height: Gap.md),
          TextField(
            key: const ValueKey('tr2_paste_box'),
            controller: _c,
            minLines: 4,
            maxLines: 10,
            maxLength: TrainPasteScreen.maxLen,
            buildCounter: localCounter,
            decoration: InputDecoration(
              hintText: t.tr2PasteHint,
              suffixIcon: IconButton(
                tooltip: t.tr2PastePaste,
                icon: const Icon(Icons.content_paste_rounded),
                onPressed: _paste,
              ),
            ),
          ),
          const SizedBox(height: Gap.sm),
          if (hasText)
            DsCard(
              key: const ValueKey('tr2_paste_preview'),
              padding: const EdgeInsets.all(Gap.md),
              child: p == null
                  ? Text(t.tr2PreviewNone, style: AType.bodyMedium.copyWith(color: ds.muted))
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(t.tr2PreviewTitle, style: AType.labelLarge.copyWith(color: ds.muted)),
                      const SizedBox(height: Gap.xs),
                      Text(d(t.tr2PreviewTrain(p.no)), style: AType.titleMedium),
                      if (_kindLine(t, p).isNotEmpty) Text(_kindLine(t, p), style: AType.bodyLarge),
                      if (p.at != null)
                        Text(
                            d(t.tr2PreviewTime(
                                '${p.at!.hour.toString().padLeft(2, '0')}:${p.at!.minute.toString().padLeft(2, '0')}')),
                            style: AType.bodyMedium),
                      if (p.lateMin != null)
                        Text(p.lateMin! <= 2 ? t.sjtOnTimeChip : d(t.sjtLateChip('${p.lateMin}')),
                            style: AType.bodyMedium.copyWith(
                                color: p.lateMin! > 2 ? ds.dangerInk : ds.successInk,
                                fontWeight: FontWeight.w700)),
                      const SizedBox(height: Gap.xs),
                      Text(t.tr2PreviewChecked, style: AType.bodySmall.copyWith(color: ds.muted)),
                    ]),
            ),
          const SizedBox(height: Gap.md),
          DsButton(
            buttonKey: const ValueKey('tr2_paste_send'),
            expand: true,
            busy: _busy,
            icon: Icons.send_rounded,
            label: t.tr2PasteSend,
            onPressed: hasText ? _send : null,
          ),
          if (_result != null)
            Padding(
              padding: const EdgeInsets.only(top: Gap.sm),
              child: Semantics(
                liveRegion: true,
                child: Text(_result!,
                    key: const ValueKey('tr2_paste_result'),
                    style: AType.bodyMedium.copyWith(
                        color: _resultOk ? ds.successInk : ds.dangerInk, fontWeight: FontWeight.w700)),
              ),
            ),
          const SizedBox(height: Gap.lg),
          Text(t.tr2PasteHowTitle, style: AType.titleSmall),
          const SizedBox(height: Gap.xs),
          Text(d(t.tr2PasteHow), style: AType.bodySmall.copyWith(color: ds.muted)),
          const SizedBox(height: Gap.xs),
          Text(t.tr2PasteNever, style: AType.bodySmall.copyWith(color: ds.muted)),
        ],
      ),
    );
  }
}
