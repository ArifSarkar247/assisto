import 'package:flutter/material.dart';

import '../../cctvx/cctv_evidence_source.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset;
import 'watchman_source.dart';
import 'watchman_widgets.dart';

/// cctvevidence (W7, owner CCTV order 3 Nov part D) — one camera's
/// RECORDING & EVIDENCE: the SD card's health and "about N days" (only where
/// the camera's maker reports it — otherwise said honestly), the per-camera
/// video add-on (10-s SD clip per person alert, 30 a day, 7 / 30 days),
/// today's clips, whether this camera can hand an SD clip over at all, and
/// the address printed in the evidence pack. Owner only.
class CctvRecordingScreen extends StatefulWidget {
  final CctvEvidenceSource source;
  final int cameraId;
  final String cameraName;

  /// Tests / gallery: show this state without the network.
  final Map<String, dynamic>? preview;
  const CctvRecordingScreen(
      {super.key,
      required this.source,
      required this.cameraId,
      this.cameraName = '',
      this.preview});

  @override
  State<CctvRecordingScreen> createState() => _CctvRecordingScreenState();
}

class _CctvRecordingScreenState extends State<CctvRecordingScreen> {
  Map<String, dynamic>? _d;
  String? _error;
  bool _busy = false;
  final _addr = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.preview != null) {
      _set(widget.preview!);
    } else {
      Future.microtask(_load);
    }
  }

  @override
  void dispose() {
    _addr.dispose();
    super.dispose();
  }

  void _set(Map<String, dynamic> d) {
    _d = d;
    _error = null;
    _addr.text = (d['address'] ?? '').toString();
  }

  Future<void> _load({bool refresh = false, bool byUser = false}) async {
    if (!mounted) return;
    setState(() {
      _error = null;
      if (!refresh) _d = null;
      _busy = refresh;
    });
    try {
      final d = await widget.source.recording(widget.cameraId, refresh: refresh);
      if (mounted) {
        setState(() => _set(d));
        // a manual check says what it found and when
        if (refresh) {
          final t = AppLocalizations.of(context);
          final lang = wmLang(context);
          final sd = wmMap(d['sd']);
          _snack('${sd['label'] ?? ''} · ${t.cevSdChecked(_time(lang, sd['checked_at']))}');
        }
      }
    } catch (e) {
      if (mounted) {
        // a failed manual re-check keeps what is on screen
        if (!refresh) setState(() => _error = wmError(e) ?? '');
        if (byUser || refresh) {
          _snack(wmError(e) ?? AppLocalizations.of(context).wmLoadErrorBody);
        }
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  void _snack(String s) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<void> _buy(Map<String, dynamic> tier) async {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.cevBuyConfirmTitle),
        content: Text(t.cevBuyConfirmBody(
            wmDigits(lang, tier['credits'] ?? 0), wmDigits(lang, tier['days'] ?? 0))),
        actions: [
          TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cxCancel)),
          FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.cevBuy)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final d = await widget.source.buyAddon(widget.cameraId, (tier['tier'] ?? '').toString());
      if (mounted) {
        setState(() => _set(d));
        _snack(t.cevBought);
      }
    } catch (e) {
      if (mounted) _snack(wmError(e) ?? t.wmGenericError);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _saveAddress() async {
    final t = AppLocalizations.of(context);
    final siteId = (_d?['site_id'] as num?)?.toInt();
    if (siteId == null) return;
    setState(() => _busy = true);
    try {
      final r = await widget.source.saveAddress(siteId, _addr.text.trim());
      _addr.text = (r['address'] ?? _addr.text).toString();
      if (mounted) _snack(t.cevAddressSaved);
    } catch (e) {
      if (mounted) _snack(wmError(e) ?? t.wmGenericError);
    }
    if (mounted) setState(() => _busy = false);
  }

  String _date(String lang, Object? iso) {
    final d = DateTime.tryParse((iso ?? '').toString())?.toLocal();
    if (d == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return wmDigits(lang, '${two(d.day)}/${two(d.month)}/${d.year}');
  }

  String _time(String lang, Object? iso) {
    final d = DateTime.tryParse((iso ?? '').toString())?.toLocal();
    if (d == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return wmDigits(lang, '${two(d.hour)}:${two(d.minute)}');
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final title = widget.cameraName.isEmpty
        ? t.cevTitle
        : '${t.cevTitle} — ${widget.cameraName}';
    Widget body;
    if (_error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_error!.isEmpty ? t.wmLoadErrorBody : _error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
                onPressed: () => _load(byUser: true),
                child: Text(t.wmRetry)),
          ]),
        ),
      );
    } else if (_d == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = _content(t, _d!);
    }
    return Scaffold(
      appBar: AppBar(title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis)),
      body: body,
    );
  }

  Widget _content(AppLocalizations t, Map<String, dynamic> d) {
    final lang = wmLang(context);
    final theme = Theme.of(context);
    final sd = wmMap(d['sd']);
    final addon = wmMap(d['addon']);
    final clips = wmMap(d['clips']);
    final support = wmMap(d['clip_support']);
    final state = (sd['state'] ?? 'unknown').toString();
    final (Color c, IconData icon) = switch (state) {
      'ok' => (wmOk(), Icons.sd_card_rounded),
      'formatting' => (wmWarn(), Icons.sd_card_rounded),
      'unknown' => (wmWarn(), Icons.help_outline_rounded),
      _ => (wmBad(), Icons.sd_card_alert_rounded),
    };
    final days = sd['days'];
    final active = addon['active'] == true;
    final tiers = wmList(addon['tiers']);
    final activeTier = (addon['tier'] ?? '').toString();
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(16, 8, 16, 32)),
      children: [
        // ---------------------------------------------------------- SD card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.cevSdTitle, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              WmPill(label: (sd['label'] ?? '').toString(), icon: icon, color: c),
              const SizedBox(height: 8),
              Text(days is num
                  ? t.cevSdDays(wmDigits(lang, days.toStringAsFixed(days >= 10 ? 0 : 1)))
                  : t.cevSdDaysUnknown),
              if ((sd['checked_at'] ?? '').toString().isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(t.cevSdChecked(_time(lang, sd['checked_at'])),
                    style: theme.textTheme.bodySmall),
              ],
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: _busy ? null : () => _load(refresh: true),
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(t.cevRefresh),
                ),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        // ---------------------------------------------------------- add-on
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.cevAddonTitle, style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(t.cevAddonWhat),
              const SizedBox(height: 8),
              WmPill(
                label: active
                    ? t.cevAddonActive(
                        wmDigits(lang, activeTier == '30d' ? 30 : 7),
                        _date(lang, addon['active_until']))
                    : t.cevAddonOff(wmDigits(lang, addon['photo_days'] ?? 7)),
                icon: active ? Icons.check_circle_rounded : Icons.photo_outlined,
                color: active ? wmOk() : wmWarn(),
              ),
              const SizedBox(height: 8),
              // a Wrap, not a ListTile trailing: the button drops below the
              // words at 200 % text instead of squeezing them
              for (final tier in tiers)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text(
                              t.cevTierLine(wmDigits(lang, tier['days'] ?? 0),
                                  wmDigits(lang, tier['price_tk'] ?? 0)),
                              style: theme.textTheme.titleSmall),
                          Text(t.cevTierCredits(wmDigits(lang, tier['credits'] ?? 0)),
                              style: theme.textTheme.bodySmall),
                        ]),
                        FilledButton(
                          style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
                          onPressed: _busy ? null : () => _buy(tier),
                          child: Text(
                              active && tier['tier'] == activeTier ? t.cevExtend : t.cevBuy),
                        ),
                      ],
                    ),
                  ),
                ),
              Text(
                  t.cevClipsToday(wmDigits(lang, clips['today'] ?? 0),
                      wmDigits(lang, clips['max_per_day'] ?? 30)),
                  style: theme.textTheme.bodySmall),
              const SizedBox(height: 8),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(support['supported'] == true ? Icons.check_rounded : Icons.info_outline_rounded,
                    size: 20,
                    color: support['supported'] == true ? wmOk() : theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(support['supported'] == true
                        ? t.cevClipSupportOk
                        : (support['text'] ?? '').toString())),
              ]),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        // ---------------------------------------------------------- address
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.cevAddressTitle, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              TextField(
                controller: _addr,
                maxLength: 200,
                minLines: 1,
                maxLines: 3,
                decoration: InputDecoration(
                    labelText: t.cevAddressHint, border: const OutlineInputBorder()),
              ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FilledButton.tonal(
                  style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
                  onPressed: _busy ? null : _saveAddress,
                  child: Text(t.cevAddressSave),
                ),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.lock_rounded, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(child: Text(t.cevStorageNote, style: theme.textTheme.bodySmall)),
        ]),
      ],
    );
  }
}
