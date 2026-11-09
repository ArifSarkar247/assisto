import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../screens/watchman/camera_label.dart';
import '../screens/watchman/watchman_source.dart' show wmDigits, wmError, wmList, wmMap;
import '../screens/watchman/watchman_widgets.dart' show wmLang, wmOk, wmWarn, WmPill;
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import '../widgets/cv_empty.dart';
import '../widgets/local_counter.dart';
import 'cctv_connect_source.dart';
import 'link_devices_screen.dart';

/// cctvconnect (CCTV Guard V3 A1) — "Connect your DVR / camera brand":
/// the brand clouds the owner switched on (EZVIZ, Imou, Hik-Connect,
/// DoLynk), this place's links, and — always — the same-Wi-Fi path, so the
/// screen is never a dead end when no brand cloud is on yet.
class CctvConnectScreen extends StatefulWidget {
  final int siteId;
  final String siteName;
  final CctvConnectSource? source;

  /// The same-Wi-Fi discovery flow (the add-camera screen). Null hides it.
  final VoidCallback? onFindOnWifi;
  const CctvConnectScreen(
      {super.key, required this.siteId, this.siteName = '', this.source, this.onFindOnWifi});

  @override
  State<CctvConnectScreen> createState() => _CctvConnectScreenState();
}

class _CctvConnectScreenState extends State<CctvConnectScreen> {
  late final CctvConnectSource _src =
      widget.source ?? ApiCctvConnectSource(context.read<AppState>().api);
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _d = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _d = await _src.providers(widget.siteId);
    } catch (e) {
      _error = wmError(e) ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _openDevices(int linkId, String name) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => CctvLinkDevicesScreen(source: _src, linkId: linkId, title: name)));
    await _load();
  }

  Future<void> _connect(Map<String, dynamic> p) async {
    final res = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => CctvLinkSheet(source: _src, siteId: widget.siteId, provider: p),
    );
    if (!mounted || res == null) return;
    final link = wmMap(res['link']);
    final id = (link['id'] as num?)?.toInt();
    if (id != null) await _openDevices(id, (link['name'] ?? p['name'] ?? '').toString());
  }

  Future<void> _remove(Map<String, dynamic> l) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(t.ccnRemoveTitle),
        content: Text(t.ccnRemoveBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.ccnCancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.ccnRemove)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final msg = ScaffoldMessenger.of(context);
    try {
      await _src.revoke((l['id'] as num).toInt());
      msg.showSnackBar(SnackBar(content: Text(t.ccnRemoved)));
    } catch (e) {
      msg.showSnackBar(SnackBar(content: Text(wmError(e) ?? t.ccnLoadError)));
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.ccnTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorBody(text: _error!.isEmpty ? t.ccnLoadError : _error!, onRetry: _load)
              : RefreshIndicator(onRefresh: _load, child: _body(context, t)),
    );
  }

  Widget _body(BuildContext context, AppLocalizations t) {
    final lang = wmLang(context);
    final providers = wmList(_d['providers']);
    final links = wmList(_d['links']);
    final th = Theme.of(context).textTheme;
    return ListView(
      key: const Key('ccnList'),
      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xl)),
      children: [
        Text(t.ccnIntro, style: th.bodyLarge),
        if (links.isNotEmpty) ...[
          const SizedBox(height: Gap.lg),
          Text(t.ccnLinkedTitle, style: th.titleMedium),
          for (final l in links)
            Card(
              margin: const EdgeInsets.only(top: Gap.sm),
              child: Padding(
                padding: const EdgeInsets.all(Gap.md),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const Icon(Icons.cloud_done_rounded),
                    const SizedBox(width: Gap.sm),
                    Expanded(child: Text((l['name'] ?? '').toString(), style: th.titleSmall)),
                  ]),
                  const SizedBox(height: Gap.xs),
                  Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
                    WmPill(
                      label: l['status'] == 'active' ? t.ccnStatusActive : t.ccnStatusError,
                      icon: l['status'] == 'active'
                          ? Icons.check_circle_rounded
                          : Icons.error_outline_rounded,
                      color: l['status'] == 'active' ? wmOk() : wmWarn(),
                    ),
                    WmPill(
                      label: t.ccnDevices(wmDigits(lang, (l['devices'] as num?)?.toInt() ?? 0)),
                      icon: Icons.dvr_rounded,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ]),
                  const SizedBox(height: Gap.sm),
                  Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                    FilledButton.tonalIcon(
                      key: ValueKey('ccnChoose-${l['id']}'),
                      style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                      icon: const Icon(Icons.video_settings_rounded),
                      label: Text(t.ccnChoose),
                      onPressed: () =>
                          _openDevices((l['id'] as num).toInt(), (l['name'] ?? '').toString()),
                    ),
                    OutlinedButton.icon(
                      key: ValueKey('ccnRemove-${l['id']}'),
                      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                      icon: const Icon(Icons.link_off_rounded),
                      label: Text(t.ccnRemove),
                      onPressed: () => _remove(l),
                    ),
                  ]),
                ]),
              ),
            ),
        ],
        const SizedBox(height: Gap.lg),
        if (providers.isNotEmpty) ...[
          Text(t.ccnAddBrandTitle, style: th.titleMedium),
          for (final p in providers)
            Card(
              margin: const EdgeInsets.only(top: Gap.sm),
              child: ListTile(
                key: ValueKey('ccnBrand-${p['id']}'),
                minVerticalPadding: Gap.md,
                leading: const Icon(Icons.videocam_rounded),
                title: Text((p['name'] ?? '').toString()),
                subtitle: Text(t.ccnBrandSub),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _connect(p),
              ),
            ),
          if (widget.onFindOnWifi != null)
            Padding(
              padding: const EdgeInsets.only(top: Gap.md),
              child: OutlinedButton.icon(
                key: const Key('ccnWifi'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.wifi_find_rounded),
                label: Text(t.ccnFindOnWifi),
                onPressed: widget.onFindOnWifi,
              ),
            ),
        ] else
          CvEmptyBlock(
            key: const Key('ccnEmpty'),
            icon: Icons.wifi_find_rounded,
            title: t.ccnNoCloudTitle,
            benefit: t.ccnNoCloudBenefit,
            primaryIcon: Icons.wifi_find_rounded,
            primaryLabel: widget.onFindOnWifi == null ? null : t.ccnFindOnWifi,
            onPrimary: widget.onFindOnWifi,
            steps: [t.ccnStep1, t.ccnStep2, t.ccnStep3],
          ),
        const SizedBox(height: Gap.lg),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.lock_rounded, size: 20),
          const SizedBox(width: Gap.sm),
          Expanded(child: Text(t.ccnPrivacy, style: th.bodySmall)),
        ]),
      ],
    );
  }
}

class _ErrorBody extends StatelessWidget {
  final String text;
  final Future<void> Function() onRetry;
  const _ErrorBody({required this.text, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.all(Gap.xl)),
      children: [
        const Icon(Icons.cloud_off_rounded, size: 48),
        const SizedBox(height: Gap.md),
        Text(text, textAlign: TextAlign.center),
        const SizedBox(height: Gap.md),
        Center(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.refresh_rounded),
            label: Text(t.ccnRetry),
            onPressed: onRetry,
          ),
        ),
      ],
    );
  }
}

/// Serial + label code (used once, never stored) -> the link row.
class CctvLinkSheet extends StatefulWidget {
  final CctvConnectSource source;
  final int siteId;
  final Map<String, dynamic> provider;
  const CctvLinkSheet({super.key, required this.source, required this.siteId, required this.provider});

  @override
  State<CctvLinkSheet> createState() => CctvLinkSheetState();
}

class CctvLinkSheetState extends State<CctvLinkSheet> {
  final _serial = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  String _msg = '';
  bool _info = false;

  @override
  void dispose() {
    _serial.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final t = AppLocalizations.of(context);
    ClipboardData? data;
    try {
      data = await Clipboard.getData(Clipboard.kTextPlain);
    } catch (_) {
      data = null;
    }
    final lab = parseCameraLabel(data?.text);
    if (!mounted) return;
    setState(() {
      _info = true;
      if (lab == null) {
        _msg = t.wmPasteLabelNone;
        return;
      }
      _serial.text = lab.serial;
      if (lab.code.isNotEmpty) _code.text = lab.code;
      _msg = lab.code.isNotEmpty ? t.wmPasteLabelBoth : t.wmPasteLabelSerial;
    });
  }

  Future<void> _go() async {
    final t = AppLocalizations.of(context);
    final serial = _serial.text.trim();
    final code = _code.text.trim();
    if (serial.isEmpty || code.isEmpty) {
      setState(() {
        _msg = t.ccnNeedBoth;
        _info = false;
      });
      return;
    }
    setState(() {
      _busy = true;
      _msg = '';
    });
    try {
      final res = await widget.source
          .link((widget.provider['id'] ?? '').toString(), widget.siteId, serial, code);
      if (mounted) Navigator.of(context).pop(res);
      return;
    } catch (e) {
      _msg = wmError(e) ?? t.ccnLoadError;
      _info = false;
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final bn = wmLang(context) == 'bn';
    final p = widget.provider;
    final codeLabel = ((bn ? p['code_label_bn'] : p['code_label_en']) ?? '').toString();
    return Padding(
      padding: EdgeInsets.fromLTRB(
          Gap.lg, 0, Gap.lg, Gap.lg + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(t.ccnSheetTitle((p['name'] ?? '').toString()),
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: Gap.xs),
              Text(t.ccnSheetHelp),
              const SizedBox(height: Gap.md),
              TextField(
                key: const Key('ccnSerial'),
                controller: _serial,
                maxLength: 40,
                buildCounter: localCounter,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                    labelText: t.ccnSerial, border: const OutlineInputBorder()),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: _busy ? null : _paste,
                  icon: const Icon(Icons.qr_code_2_rounded),
                  label: Text(t.wmPasteLabel),
                ),
              ),
              TextField(
                key: const Key('ccnCode'),
                controller: _code,
                maxLength: 32,
                buildCounter: localCounter,
                decoration: InputDecoration(
                    labelText: codeLabel.isEmpty ? t.ccnCodeFallback : codeLabel,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.sm),
              FilledButton.icon(
                key: const Key('ccnConnect'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _busy ? null : _go,
                icon: _busy
                    ? const SizedBox(
                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.link_rounded),
                label: Text(t.ccnConnect),
              ),
              if (_msg.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.sm),
                  child: Text(_msg,
                      key: const Key('ccnMsg'),
                      style: TextStyle(
                          color: _info ? null : Theme.of(context).colorScheme.error)),
                ),
              const SizedBox(height: Gap.sm),
              Text(t.ccnPrivacy, style: Theme.of(context).textTheme.bodySmall),
            ]),
      ),
    );
  }
}
