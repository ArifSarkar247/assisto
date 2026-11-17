import 'package:flutter/material.dart';
import '../../widgets/skeleton.dart';
import '../../ds/ds.dart';
import '../../theme.dart' show AType, AFonts;
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../l10n/app_localizations.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/cv_empty.dart';
import '../../widgets/local_counter.dart';
import 'cctv_team_source.dart';
import 'watchman_source.dart';
import 'watchman_widgets.dart';

/// cctvroles (CCTV Guard V3 J) — INSTALLER PARTNERS.
///
/// Owner side ([CctvInstallerScreen]): the site owner makes a one-time code
/// (QR + 8 letters, 48 h) for their local CCTV technician and ends it any
/// time. Technician side ([CctvPartnerScreen]): apply once (Assisto
/// approves), type / scan an owner's code, then see ONLY the setup status of
/// those places — never video, photos or alerts (the server returns nothing
/// else: backend core/cctv_partner_views.py).

class CctvInstallerScreen extends StatefulWidget {
  final CctvTeamSource source;
  final int siteId;
  const CctvInstallerScreen({super.key, required this.source, required this.siteId});

  @override
  State<CctvInstallerScreen> createState() => _CctvInstallerScreenState();
}

class _CctvInstallerScreenState extends State<CctvInstallerScreen> {
  bool _loading = true;
  bool _busy = false;
  String? _error;
  List<Map<String, dynamic>> _links = const [];
  String _note = '';
  int _hours = 48;

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
      final d = await widget.source.installers(widget.siteId);
      _links = wmList(d['links']);
      _note = (d['note'] ?? '').toString();
      _hours = (d['invite_hours'] as num?)?.toInt() ?? 48;
    } catch (e) {
      _error = wmError(e) ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _make() async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final d = await widget.source.makeInstallerCode(widget.siteId);
      if (!mounted) return;
      await showAppSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => CctvInstallerCodeSheet(code: (d['code'] ?? '').toString(), qr: (d['qr'] ?? '').toString(), hours: _hours),
      );
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(wmError(e) ?? t.wmGenericError)));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _end(Map<String, dynamic> link) async {
    final t = AppLocalizations.of(context);
    final ok = await showAppSheet<bool>(
      context: context,
      builder: (c) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t.ctrInstEndConfirm, style: Theme.of(c).textTheme.titleMedium),
          const SizedBox(height: 16),
          FilledButton(
            key: const ValueKey('ctr-inst-end-yes'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
            onPressed: () => Navigator.of(c).pop(true),
            child: Text(t.ctrInstEndYes),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => Navigator.of(c).pop(false),
            child: Text(t.ctrInstKeep),
          ),
        ]),
      ),
    );
    if (ok != true) return;
    try {
      await widget.source.endInstaller((link['id'] as num).toInt());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(wmError(e) ?? t.wmGenericError)));
      }
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.ctrInstTitle)),
      body: _loading
          ? const SkeletonList()
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: withNavBarInset(context, const EdgeInsets.fromLTRB(16, 12, 16, 32)),
                children: [
                  if (_error != null) ...[
                    Text(_error!.isEmpty ? t.wmLoadErrorBody : _error!),
                    const SizedBox(height: 8),
                    OutlinedButton(onPressed: _load, child: Text(t.ctmWatchEmptyRefresh)),
                  ] else if (_links.isEmpty)
                    CvEmptyBlock(
                      icon: Icons.handyman_outlined,
                      title: t.ctrInstEmptyTitle,
                      benefit: t.ctrInstEmptyBenefit,
                      primaryIcon: Icons.qr_code_2_rounded,
                      primaryLabel: t.ctrInstMake,
                      onPrimary: _busy ? null : _make,
                      steps: [t.ctrInstStep1, t.ctrInstStep2, t.ctrInstStep3],
                    )
                  else ...[
                    if (_note.isNotEmpty) _NoteCard(text: _note),
                    const SizedBox(height: 8),
                    for (final l in _links) _linkTile(t, lang, l),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      key: const ValueKey('ctr-inst-make'),
                      style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
                      icon: const Icon(Icons.qr_code_2_rounded),
                      label: Text(t.ctrInstMake),
                      onPressed: _busy ? null : _make,
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _linkTile(AppLocalizations t, String lang, Map<String, dynamic> l) {
    final st = (l['status'] ?? '').toString();
    final p = wmMap(l['partner']);
    final (label, color) = switch (st) {
      'active' => (t.ctrInstStatusActive, wmOk()),
      'expired' => (t.ctrInstStatusExpired, wmBad()),
      _ => (t.ctrInstStatusInvited, wmWarn()),
    };
    final who = p.isEmpty
        ? t.ctrInstNotUsed
        : [p['name'], p['area']].where((x) => (x ?? '').toString().isNotEmpty).join(' · ');
    return Padding(padding: const EdgeInsets.only(bottom: 8), child: DsCard(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(children: [
          Icon(st == 'active' ? Icons.handyman_rounded : Icons.qr_code_2_rounded, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(who, style: Theme.of(context).textTheme.titleSmall),
              Text([label, ctmTime(lang, (l['accepted_at'] ?? l['created'])?.toString())]
                  .where((x) => x.isNotEmpty)
                  .join(' · ')),
            ]),
          ),
          TextButton(
            key: ValueKey('ctr-inst-end-${l['id']}'),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => _end(l),
            child: Text(t.ctrInstEnd),
          ),
        ]),
      ));
  }
}

class _NoteCard extends StatelessWidget {
  final String text;
  const _NoteCard({required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.ds.primarySoft.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.privacy_tip_outlined, color: cs.ds.primaryInk),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: AType.bodyMedium.copyWith(color: cs.ds.primaryInk))),
      ]),
    );
  }
}

class CctvInstallerCodeSheet extends StatelessWidget {
  final String code;
  final String qr;
  final int hours;
  const CctvInstallerCodeSheet({super.key, required this.code, required this.qr, required this.hours});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.ctrInstCodeTitle, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(t.ctrInstCodeHelp(wmDigits(lang, hours))),
        const SizedBox(height: 12),
        if (qr.isNotEmpty)
          Center(
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(8),
              child: SizedBox.square(dimension: 180, child: QrImageView(data: qr, size: 180)),
            ),
          ),
        const SizedBox(height: 12),
        SelectableText(
          code.length == 8 ? '${code.substring(0, 4)} ${code.substring(4)}' : code,
          key: const ValueKey('ctr-inst-code'),
          textAlign: TextAlign.center,
          style: AType.bodyMedium.copyWith(fontFeatures: AFonts.tabular /* design3: the app font (monospace is not bundled) */, fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: 2),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          icon: const Icon(Icons.copy_rounded),
          label: Text(t.ctrInstCopy),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: code));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.ctrInstCopied)));
            }
          },
        ),
      ]),
    );
  }
}

// ======================================================= technician side
class CctvPartnerScreen extends StatefulWidget {
  final CctvTeamSource source;
  const CctvPartnerScreen({super.key, required this.source});

  @override
  State<CctvPartnerScreen> createState() => _CctvPartnerScreenState();
}

class _CctvPartnerScreenState extends State<CctvPartnerScreen> {
  bool _loading = true;
  bool _busy = false;
  String? _error;
  String? _formError;
  Map<String, dynamic> _me = const {};
  final _name = TextEditingController();
  final _area = TextEditingController();
  final _code = TextEditingController();

  @override
  void initState() {
    super.initState();
    _name.addListener(_changed);
    _area.addListener(_changed);
    _code.addListener(_changed);
    _load();
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _name.dispose();
    _area.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _me = await widget.source.partnerMe();
    } catch (e) {
      _error = wmError(e) ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _apply() async {
    final t = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _formError = null;
    });
    try {
      await widget.source.partnerApply(_name.text.trim(), _area.text.trim());
      await _load();
    } catch (e) {
      _formError = wmError(e) ?? t.wmGenericError;
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _join() async {
    final t = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _formError = null;
    });
    try {
      await widget.source.partnerJoin(_code.text.trim());
      _code.clear();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.ctrPartJoined)));
      await _load();
    } catch (e) {
      _formError = wmError(e) ?? t.wmGenericError;
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.ctrPartTitle)),
      body: _loading
          ? const SkeletonList()
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: withNavBarInset(context, const EdgeInsets.fromLTRB(16, 12, 16, 32)),
                children: _error != null
                    ? [
                        Text(_error!.isEmpty ? t.wmLoadErrorBody : _error!),
                        const SizedBox(height: 8),
                        OutlinedButton(onPressed: _load, child: Text(t.ctmWatchEmptyRefresh)),
                      ]
                    : _body(t),
              ),
            ),
    );
  }

  List<Widget> _body(AppLocalizations t) {
    final p = wmMap(_me['partner']);
    final status = (p['status'] ?? '').toString();
    final note = (_me['note'] ?? '').toString();
    final err = _formError == null
        ? const <Widget>[]
        : [Text(_formError!, style: AType.bodyMedium.copyWith(color: Theme.of(context).colorScheme.error))];
    if (p.isEmpty) {
      final ok = _name.text.trim().length >= 2 && _area.text.trim().length >= 2;
      return [
        _NoteCard(text: t.ctrPartIntro),
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey('ctr-part-name'),
          controller: _name,
          maxLength: 80,
          buildCounter: localCounter,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(labelText: t.ctrPartName, border: const OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('ctr-part-area'),
          controller: _area,
          maxLength: 80,
          buildCounter: localCounter,
          decoration: InputDecoration(labelText: t.ctrPartArea, border: const OutlineInputBorder()),
        ),
        ...err,
        const SizedBox(height: 8),
        FilledButton(
          key: const ValueKey('ctr-part-apply'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
          onPressed: _busy || !ok ? null : _apply,
          child: Text(t.ctrPartApply),
        ),
      ];
    }
    if (status != 'approved') {
      return [
        _NoteCard(text: status == 'suspended' ? t.ctrPartSuspended : t.ctrPartPending),
        const SizedBox(height: 12),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const CircleAvatar(child: Icon(Icons.handyman_outlined)),
          title: Text((p['name'] ?? '').toString()),
          subtitle: Text((p['area'] ?? '').toString()),
        ),
      ];
    }
    final sites = wmList(_me['sites']);
    final canJoin = _code.text.replaceAll(RegExp(r'[\s-]'), '').length >= 8;
    return [
      if (note.isNotEmpty) _NoteCard(text: note),
      const SizedBox(height: 16),
      TextField(
        key: const ValueKey('ctr-part-code'),
        controller: _code,
        maxLength: 60,
        buildCounter: localCounter,
        textCapitalization: TextCapitalization.characters,
        decoration: InputDecoration(
            labelText: t.ctrPartCode, helperText: t.ctrPartCodeHint, helperMaxLines: 3,
            border: const OutlineInputBorder()),
      ),
      ...err,
      const SizedBox(height: 8),
      FilledButton.icon(
        key: const ValueKey('ctr-part-join'),
        style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
        icon: const Icon(Icons.add_business_outlined),
        label: Text(t.ctrPartJoin),
        onPressed: _busy || !canJoin ? null : _join,
      ),
      const SizedBox(height: 16),
      if (sites.isEmpty)
        CvEmptyBlock(
          compact: true,
          icon: Icons.storefront_outlined,
          title: t.ctrPartEmptyTitle,
          benefit: t.ctrPartEmptyBenefit,
          primaryIcon: Icons.refresh_rounded,
          primaryLabel: t.ctmWatchEmptyRefresh,
          onPrimary: _load,
        ),
      for (final s in sites) _SiteSetupCard(site: s),
      const SizedBox(height: 8),
      Text(t.ctrPartCommission, style: Theme.of(context).textTheme.bodySmall),
    ];
  }
}

class _SiteSetupCard extends StatelessWidget {
  final Map<String, dynamic> site;
  const _SiteSetupCard({required this.site});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final done = site['done'] == true;
    String stepName(String k) => switch (k) {
          'cameras_added' => t.ctrStepCamerasAdded,
          'cameras_online' => t.ctrStepCamerasOnline,
          'gateway_connected' => t.ctrStepGateway,
          'hours_set' => t.ctrStepHours,
          _ => t.ctrStepZones,
        };
    return Padding(padding: const EdgeInsets.only(bottom: 12), child: DsCard(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(done ? Icons.verified_rounded : Icons.build_circle_outlined, color: done ? wmOk() : wmWarn()),
            const SizedBox(width: 8),
            Expanded(
              child: Text((site['name'] ?? '').toString(), style: Theme.of(context).textTheme.titleMedium),
            ),
          ]),
          const SizedBox(height: 4),
          Text([
            done ? t.ctrPartDone : t.ctrPartTodo,
            t.ctrPartCams(wmDigits(lang, site['online'] ?? 0), wmDigits(lang, site['cameras'] ?? 0)),
          ].join(' · ')),
          const SizedBox(height: 8),
          for (final st in wmList(site['steps']))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                Icon(st['ok'] == true ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                    size: 20, color: st['ok'] == true ? wmOk() : Theme.of(context).colorScheme.ds.muted),
                const SizedBox(width: 8),
                Expanded(child: Text(stepName((st['key'] ?? '').toString()))),
              ]),
            ),
          const Divider(),
          for (final c in wmList(site['camera_rows']))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                Icon(Icons.videocam_outlined, size: 18, color: c['online'] == true ? wmOk() : wmBad()),
                const SizedBox(width: 8),
                Expanded(child: Text((c['name'] ?? '').toString())),
                Text(c['online'] == true ? t.ctmStatusOnline : t.ctmStatusOffline),
              ]),
            ),
        ]),
      ));
  }
}
