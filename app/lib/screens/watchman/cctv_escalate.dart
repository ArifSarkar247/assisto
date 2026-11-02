import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../cctvx/cctvx_source.dart';
import '../../cctvx/escalate_source.dart';
import '../../cctvx/warn_recorder.dart';
import '../../l10n/app_localizations.dart';
import '../../messaging/media/voice_player.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/permission_reason.dart';
import 'watchman_source.dart';
import 'watchman_widgets.dart';

/// cctvescalate (owner CCTV order 3 Nov, section C) — the phone side of
/// C4 (999 + police card, NEVER automatic), C5 (camera light / the owner's
/// recorded warning on the camera speaker, confirm first; honest "not on
/// this camera" table) and C6 (two-way talk: honest row). The siren stays
/// in AlertActionsSheet (cctvx).

// ================================================================ C4
/// The dialer opener (tests swap it). `tel:` opens the DIAL screen only.
Future<bool> Function(Uri uri) police999Launch = launchUrl;

/// 999: asks first (with the honest "Assisto does not call the police"),
/// opens the phone's DIALER with 999 (the person presses call), then shows
/// the ready police card (address, time, camera, snapshot) to read out or
/// send.
Future<void> police999Flow(BuildContext context, CctvxSource source,
    Map<String, dynamic> police,
    {Future<bool> Function(Uri uri)? launcher}) async {
  final t = AppLocalizations.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t.cx999ConfirmTitle),
      content: Text(t.cescNoAutoPolice),
      actions: [
        TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.cxCancel)),
        FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.cescOpenDialer)),
      ],
    ),
  );
  if (ok != true) return;
  final uri = Uri(scheme: 'tel', path: '999');
  // the dialer opens on top; the card waits underneath (never blocks on it)
  unawaited((launcher ?? police999Launch)(uri).then((_) {}, onError: (_) {
    // no dialer (tablet): the card below still helps
  }));
  if (!context.mounted || police.isEmpty) return;
  await showAppSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => PoliceCardSheet(source: source, police: police),
  );
}

class PoliceCardSheet extends StatefulWidget {
  final CctvxSource source;
  final Map<String, dynamic> police;
  const PoliceCardSheet({super.key, required this.source, required this.police});

  @override
  State<PoliceCardSheet> createState() => _PoliceCardSheetState();
}

class _PoliceCardSheetState extends State<PoliceCardSheet> {
  bool _busy = false;

  String _card(String lang) =>
      (widget.police[lang == 'en' ? 'card_en' : 'card_bn'] ?? '').toString();

  Future<void> _share() async {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    setState(() => _busy = true);
    final text = _card(lang);
    final url = (widget.police['snapshot_url'] ?? '').toString();
    try {
      Uint8List? photo;
      if (url.isNotEmpty) {
        try {
          photo = await widget.source.download(url);
        } catch (_) {
          photo = null; // the card text still goes
        }
      }
      if (photo != null) {
        final dir = Directory('${(await getTemporaryDirectory()).path}/police_card');
        if (!dir.existsSync()) dir.createSync(recursive: true);
        final f = File('${dir.path}/assisto_cctv.jpg');
        await f.writeAsBytes(photo, flush: true);
        await Share.shareXFiles([XFile(f.path, mimeType: 'image/jpeg')], text: text);
      } else {
        await Share.share(text);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(wmError(e) ?? t.wmGenericError)));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final scheme = Theme.of(context).colorScheme;
    final missing = widget.police['address_missing'] == true;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t.cescCardTitle, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(t.cescCardSub, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          if (missing)
            Card(
              color: scheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(t.cescAddressMissing,
                    style: TextStyle(color: scheme.onErrorContainer)),
              ),
            ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(_card(lang)),
            ),
          ),
          const SizedBox(height: 4),
          Text(t.cescShareWarn, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
            onPressed: _busy ? null : _share,
            icon: const Icon(Icons.ios_share_rounded),
            label: Text(t.cescCardShare),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(64, 48)),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _card(lang)));
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(t.cescCopied)));
              }
            },
            icon: const Icon(Icons.copy_rounded),
            label: Text(t.cescCardCopy),
          ),
        ]),
      ),
    );
  }
}

// ================================================================ C5 / C6
/// The table rows for one camera: {feature: {supported, text}}.
Map<String, Map<String, dynamic>> deterRows(Map<String, dynamic> deter, String lang) {
  final rows = wmList(deter[lang == 'en' ? 'table_en' : 'table_bn']);
  return {for (final r in rows) (r['feature'] ?? '').toString(): r};
}

String featureLabel(AppLocalizations t, String f) => switch (f) {
      'siren' => t.cescFeatSiren,
      'light' => t.cescFeatLight,
      'voice' => t.cescFeatVoice,
      _ => t.cescFeatTalk,
    };

/// Light + recorded warning tiles for AlertActionsSheet (hidden when the
/// camera has neither — the table tile says why), and the table tile.
class DeterTiles extends StatefulWidget {
  final EscalateSource? escalate;
  final int eventId;
  final Map<String, dynamic> deter;
  const DeterTiles(
      {super.key, required this.escalate, required this.eventId, required this.deter});

  @override
  State<DeterTiles> createState() => _DeterTilesState();
}

class _DeterTilesState extends State<DeterTiles> {
  bool _busy = false;
  late bool _hasClip = widget.deter['warn_clip'] == true;

  void _snack(String s) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  Future<void> _run(String feature) async {
    final t = AppLocalizations.of(context);
    final esc = widget.escalate;
    if (esc == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.cescConfirmTitle),
        content: Text(feature == 'light' ? t.cescConfirmLight : t.cescConfirmVoice),
        actions: [
          TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cxCancel)),
          FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.cescDoIt)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await esc.deter(widget.eventId, feature,
          cameraId: (widget.deter['camera_id'] as num?)?.toInt());
      _snack(feature == 'light' ? t.cescLightOn : t.cescVoicePlaying);
    } catch (e) {
      _snack(wmError(e) ?? t.wmGenericError);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _record() async {
    final esc = widget.escalate;
    final site = (widget.deter['site_id'] as num?)?.toInt();
    if (esc == null || site == null) return;
    final saved = await WarnClipSheet.show(context, esc, site);
    if (saved != null && mounted) setState(() => _hasClip = saved);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final rows = deterRows(widget.deter, lang);
    final allowed = widget.deter['allowed'] == true && widget.escalate != null;
    final light = rows['light'] ?? const {};
    final voice = rows['voice'] ?? const {};
    final secs = (widget.deter['light_seconds'] as num?)?.toInt() ?? 30;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (allowed && light['supported'] == true)
        _tile(Icons.light_mode_rounded, t.cescLight, t.cescLightSub(wmDigits(lang, secs)),
            _busy ? null : () => _run('light')),
      if (allowed && voice['supported'] == true)
        _tile(
            Icons.record_voice_over_rounded,
            t.cescVoice,
            _hasClip ? t.cescVoiceSub : t.cescVoiceNeedClip,
            _busy ? null : (_hasClip ? () => _run('voice') : _record)),
      _tile(Icons.fact_check_outlined, t.cescWhatCamCan, t.cescWhatCamCanSub,
          () => showAppSheet<void>(
                context: context,
                showDragHandle: true,
                builder: (_) => CapabilityTable(rows: rows),
              )),
    ]);
  }

  Widget _tile(IconData icon, String label, String sub, VoidCallback? onTap) => Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          minTileHeight: 56,
          enabled: onTap != null,
          leading: Icon(icon),
          title: Text(label),
          subtitle: Text(sub),
          onTap: onTap,
        ),
      );
}

/// Per-camera table: siren / light / message / two-way talk — available or
/// the honest reason ("not on this camera ...").
class CapabilityTable extends StatelessWidget {
  final Map<String, Map<String, dynamic>> rows;
  const CapabilityTable({super.key, required this.rows});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t.cescWhatCamCan, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final f in const ['siren', 'light', 'voice', 'talk'])
            ListTile(
              minTileHeight: 56,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                  rows[f]?['supported'] == true
                      ? Icons.check_circle_rounded
                      : Icons.remove_circle_outline_rounded,
                  color: rows[f]?['supported'] == true ? scheme.primary : scheme.outline),
              title: Text(featureLabel(t, f)),
              subtitle: Text(rows[f]?['supported'] == true
                  ? t.cescFeatYes
                  : ((rows[f]?['text'] ?? '').toString().isNotEmpty
                      ? rows[f]!['text'].toString()
                      : t.cescNotOnCam)),
            ),
        ]),
      ),
    );
  }
}

/// The owner records ONE warning in their own voice (≤ 20 s), listens, keeps
/// it. Pops true (a clip is kept) / false (deleted) / null (unchanged).
class WarnClipSheet extends StatefulWidget {
  final EscalateSource source;
  final int siteId;

  /// Tests / gallery: skip the network.
  final Map<String, dynamic>? preview;
  const WarnClipSheet(
      {super.key, required this.source, required this.siteId, this.preview});

  static Future<bool?> show(BuildContext context, EscalateSource source, int siteId) =>
      showAppSheet<bool>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => WarnClipSheet(source: source, siteId: siteId),
      );

  @override
  State<WarnClipSheet> createState() => _WarnClipSheetState();
}

class _WarnClipSheetState extends State<WarnClipSheet> {
  Map<String, dynamic>? _d;
  WarnRecorder? _rec;
  String? _path;
  bool _recording = false;
  bool _busy = false;
  int _secs = 0;
  Timer? _timer;
  bool? _result;

  @override
  void initState() {
    super.initState();
    if (widget.preview != null) {
      _d = widget.preview;
    } else {
      widget.source.warnClip(widget.siteId).then((d) {
        if (mounted) setState(() => _d = d);
      }, onError: (_) {
        if (mounted) setState(() => _d = const {});
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (_recording) unawaited(_rec?.stop());
    super.dispose();
  }

  void _snack(String s) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<void> _start() async {
    final t = AppLocalizations.of(context);
    if (!await warnMicGranted()) {
      if (!mounted) return;
      if (!await showPermissionReason(context, PermKind.mic)) return;
    }
    _rec ??= warnRecorderFactory();
    final ok = await _rec!.start();
    if (!mounted) return;
    if (!ok) {
      _snack(t.cescWarnMicNo);
      return;
    }
    setState(() {
      _recording = true;
      _secs = 0;
      _path = null;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (tm) {
      if (!mounted) return;
      setState(() => _secs++);
      if (_secs >= kWarnMaxClip.inSeconds) unawaited(_stop());
    });
  }

  Future<void> _stop() async {
    _timer?.cancel();
    final p = await _rec?.stop();
    if (mounted) {
      setState(() {
        _recording = false;
        _path = p;
      });
    }
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    final p = _path;
    if (p == null) return;
    setState(() => _busy = true);
    try {
      final raw = await (_rec ?? warnRecorderFactory()).read(p);
      if (raw == null) throw StateError('read');
      final d = await widget.source.saveWarnClip(widget.siteId, raw);
      _result = true;
      if (mounted) {
        setState(() {
          _d = d;
          _path = null;
        });
        _snack(t.cescWarnSaved);
      }
    } catch (e) {
      if (mounted) _snack(wmError(e) ?? t.wmGenericError);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _delete() async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final d = await widget.source.deleteWarnClip(widget.siteId);
      _result = false;
      if (mounted) setState(() => _d = d);
    } catch (e) {
      if (mounted) _snack(wmError(e) ?? t.wmGenericError);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final d = _d;
    final lines = [
      for (final e in (d?['lines'] is List ? d!['lines'] as List : const []))
        e.toString()
    ];
    final has = d?['has_clip'] == true;
    final secs = (d?['seconds'] as num?)?.round() ?? 0;
    return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: d == null
              ? const Padding(
                  padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(t.cescWarnTitle, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(has ? t.cescWarnHave(wmDigits(lang, secs)) : t.cescWarnNone),
                  const SizedBox(height: 12),
                  Text(t.cescWarnHow),
                  const SizedBox(height: 8),
                  for (final l in lines)
                    Card(
                        child: Padding(
                            padding: const EdgeInsets.all(12), child: Text('“$l”'))),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
                    onPressed: _busy ? null : (_recording ? _stop : _start),
                    icon: Icon(_recording ? Icons.stop_rounded : Icons.mic_rounded),
                    label: Text(_recording
                        ? t.cescWarnStop(wmDigits(lang, _secs))
                        : (_path == null ? t.cescWarnRecord : t.cescWarnRedo)),
                  ),
                  if (_path != null) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(minimumSize: const Size(64, 48)),
                      onPressed: () => VoicePlayer.instance.toggle(_path!),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text(t.cescWarnListen),
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
                      onPressed: _busy ? null : _save,
                      child: Text(t.cescWarnSave),
                    ),
                  ],
                  if (has && _path == null && !_recording) ...[
                    const SizedBox(height: 8),
                    TextButton(
                      style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
                      onPressed: _busy ? null : _delete,
                      child: Text(t.cescWarnDelete),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(t.cescWarnPrivacy, style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  TextButton(
                    style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
                    onPressed: () => Navigator.pop(context, _result),
                    child: Text(t.cescDone),
                  ),
                ]),
      ),
    );
  }
}
