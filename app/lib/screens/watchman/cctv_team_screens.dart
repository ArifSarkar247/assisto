import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/app_localizations.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/cv_empty.dart';
import '../../widgets/local_counter.dart';
import 'cctv_grid_screen.dart' show ctmRoleName;
import 'cctv_team_source.dart';
import 'watchman_source.dart';
import 'watchman_widgets.dart';

/// cctvteam (W11, audit F3) — what ONE person may see at this place. The
/// server enforces it on every CCTV endpoint (alerts, photos, live, clips,
/// evidence, grid, pushes); this sheet only sets it.
///   family  — every camera (or chosen ones), view only
///   manager — every camera (or chosen ones), may mark alerts checked
///   guard   — ONLY the chosen cameras (e.g. the gate)
/// Live view per person is off until the owner turns it on.
Future<bool> showCctvRoleSheet(BuildContext context, CctvTeamSource source,
    {required int siteId, required Map<String, dynamic> viewer}) async {
  final ok = await showAppSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => CctvRoleSheet(source: source, siteId: siteId, viewer: viewer),
  );
  return ok == true;
}

class CctvRoleSheet extends StatefulWidget {
  final CctvTeamSource source;
  final int siteId;
  final Map<String, dynamic> viewer;
  const CctvRoleSheet({super.key, required this.source, required this.siteId, required this.viewer});

  @override
  State<CctvRoleSheet> createState() => _CctvRoleSheetState();
}

class _CctvRoleSheetState extends State<CctvRoleSheet> {
  bool _loading = true;
  bool _saving = false;
  String? _error;
  List<Map<String, dynamic>> _cams = const [];
  late String _role = (widget.viewer['role'] ?? 'family').toString();
  late bool _all = widget.viewer['all_cameras'] != false;
  late final Set<int> _picked = {
    for (final c in (widget.viewer['cameras'] is List ? widget.viewer['cameras'] as List : const []))
      (c as num).toInt()
  };
  late bool _live = widget.viewer['live_ok'] == true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.source.roles(widget.siteId);
      _cams = wmList(d['cameras']);
    } catch (e) {
      _error = wmError(e) ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  bool get _valid => _role != 'guard' || _picked.isNotEmpty;

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    final restricted = _role == 'guard' || !_all;
    try {
      await widget.source.setRole(widget.siteId, (widget.viewer['user_id'] as num).toInt(), {
        'role': _role,
        'cameras': restricted ? _picked.toList() : <int>[],
        'live_ok': _live,
      });
      if (!mounted) return;
      Navigator.of(context).pop(true);
      return;
    } catch (e) {
      _error = wmError(e) ?? t.wmGenericError;
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_loading) {
      return const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()));
    }
    final name = (widget.viewer['name'] ?? '').toString();
    final roles = {
      'family': t.ctmRoleFamilyHelp,
      'manager': t.ctmRoleManagerHelp,
      'guard': t.ctmRoleGuardHelp,
    };
    final pickCams = _role == 'guard' || !_all;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.ctmRoleTitle(name.isEmpty ? t.wmFamilyNoName : name),
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(t.ctmRoleServerNote, style: Theme.of(context).textTheme.bodySmall),
        for (final e in roles.entries)
          RadioListTile<String>(
            key: ValueKey('ctm-role-${e.key}'),
            value: e.key,
            groupValue: _role,
            title: Text(ctmRoleName(t, e.key)),
            subtitle: Text(e.value),
            onChanged: (v) => setState(() => _role = v ?? 'family'),
          ),
        const Divider(),
        if (_role != 'guard')
          SwitchListTile(
            value: _all,
            title: Text(t.ctmAllCameras),
            onChanged: (v) => setState(() => _all = v),
          ),
        if (pickCams) ...[
          Text(_role == 'guard' ? t.ctmGuardPick : t.ctmPickCameras,
              style: Theme.of(context).textTheme.labelLarge),
          if (_cams.isEmpty) Text(t.cvvNoCamBenefit),
          for (final c in _cams)
            CheckboxListTile(
              key: ValueKey('ctm-cam-${c['id']}'),
              value: _picked.contains((c['id'] as num).toInt()),
              title: Text((c['name'] ?? '').toString()),
              controlAffinity: ListTileControlAffinity.leading,
              onChanged: (v) => setState(() {
                final id = (c['id'] as num).toInt();
                v == true ? _picked.add(id) : _picked.remove(id);
              }),
            ),
        ],
        const Divider(),
        SwitchListTile(
          key: const ValueKey('ctm-live-ok'),
          value: _live,
          title: Text(t.ctmLiveOk),
          subtitle: Text(t.ctmLiveOkHelp),
          onChanged: (v) => setState(() => _live = v),
        ),
        if (_error != null && _error!.isNotEmpty)
          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        if (!_valid) Text(t.ctmGuardPick, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        const SizedBox(height: 8),
        FilledButton(
          key: const ValueKey('ctm-role-save'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
          onPressed: _saving || !_valid || (pickCams && _picked.isEmpty) ? null : _save,
          child: Text(t.ctmSave),
        ),
      ]),
    );
  }
}

/// cctvteam (W11, audit F4) — view-only, time-limited links for someone
/// without the app: chosen cameras, 1 h / 24 h / custom (up to 3 days),
/// "shared until …", revoke any time, never sound. Opens in any browser.
class CctvShareLinksScreen extends StatefulWidget {
  final CctvTeamSource source;
  final int siteId;
  final String siteName;
  const CctvShareLinksScreen({super.key, required this.source, required this.siteId, this.siteName = ''});

  @override
  State<CctvShareLinksScreen> createState() => _CctvShareLinksScreenState();
}

class _CctvShareLinksScreenState extends State<CctvShareLinksScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _links = const [];
  List<Map<String, dynamic>> _cams = const [];
  int _maxHours = 72;

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
      final d = await widget.source.shareLinks(widget.siteId);
      _links = wmList(d['links']);
      _maxHours = (d['max_hours'] as num?)?.toInt() ?? 72;
      _cams = wmList((await widget.source.roles(widget.siteId))['cameras']);
    } catch (e) {
      _error = wmError(e) ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _create() async {
    final made = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _NewLinkSheet(
          source: widget.source, siteId: widget.siteId, cameras: _cams, maxHours: _maxHours),
    );
    await _load();
    if (made == null || !mounted) return;
    await showAppSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _LinkReadySheet(link: made, siteName: widget.siteName),
    );
  }

  Future<void> _revoke(Map<String, dynamic> l) async {
    final t = AppLocalizations.of(context);
    try {
      await widget.source.revokeShareLink((l['id'] as num).toInt());
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.ctmLinkRevoked)));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(wmError(e) ?? t.wmGenericError)));
      }
    }
    await _load();
  }

  String _camNames(List ids) {
    final byId = {for (final c in _cams) (c['id'] as num).toInt(): (c['name'] ?? '').toString()};
    return [for (final i in ids) byId[(i as num).toInt()] ?? '#$i'].join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.ctmLinksTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: withNavBarInset(context, const EdgeInsets.fromLTRB(16, 12, 16, 32)),
                children: [
                  if (_error != null) Text(_error!.isEmpty ? t.wmLoadErrorBody : _error!),
                  if (_error == null && _links.isEmpty)
                    CvEmptyBlock(
                      icon: Icons.link_rounded,
                      title: t.ctmLinksEmptyTitle,
                      benefit: t.ctmLinksEmptyBenefit,
                      primaryIcon: Icons.add_link_rounded,
                      primaryLabel: t.ctmNewLink,
                      onPrimary: _cams.isEmpty ? null : _create,
                      steps: [t.ctmLinksStep1, t.ctmLinksStep2, t.ctmLinksStep3],
                    )
                  else if (_error == null) ...[
                    Text(t.ctmLinksIntro),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      key: const ValueKey('ctm-new-link'),
                      style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
                      icon: const Icon(Icons.add_link_rounded),
                      label: Text(t.ctmNewLink),
                      onPressed: _cams.isEmpty ? null : _create,
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (_cams.isEmpty && _error == null) Text(t.cvvNoCamBenefit),
                  for (final l in _links)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text((l['label'] ?? '').toString().isEmpty ? t.ctmLinkNoLabel : l['label'].toString(),
                              style: Theme.of(context).textTheme.titleSmall),
                          const SizedBox(height: 4),
                          WmPill(
                            label: switch ((l['state'] ?? '').toString()) {
                              'active' => t.ctmLinkUntil(ctmTime(lang, l['expires_at']?.toString())),
                              'revoked' => t.ctmLinkStateRevoked,
                              _ => t.ctmLinkStateExpired,
                            },
                            icon: l['state'] == 'active' ? Icons.timer_outlined : Icons.link_off_rounded,
                            color: l['state'] == 'active' ? wmOk() : wmBad(),
                          ),
                          const SizedBox(height: 4),
                          Text(_camNames(l['cameras'] is List ? l['cameras'] as List : const [])),
                          Text(t.ctmLinkViews(wmDigits(lang, (l['views'] as num?)?.toInt() ?? 0)),
                              style: Theme.of(context).textTheme.bodySmall),
                          if (l['state'] == 'active')
                            Align(
                              alignment: AlignmentDirectional.centerEnd,
                              child: TextButton.icon(
                                key: ValueKey('ctm-revoke-${l['id']}'),
                                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                                icon: const Icon(Icons.link_off_rounded),
                                label: Text(t.ctmRevoke),
                                onPressed: () => _revoke(l),
                              ),
                            ),
                        ]),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _NewLinkSheet extends StatefulWidget {
  final CctvTeamSource source;
  final int siteId;
  final List<Map<String, dynamic>> cameras;
  final int maxHours;
  const _NewLinkSheet({required this.source, required this.siteId, required this.cameras, required this.maxHours});

  @override
  State<_NewLinkSheet> createState() => _NewLinkSheetState();
}

class _NewLinkSheetState extends State<_NewLinkSheet> {
  final Set<int> _picked = {};
  int _hours = 1;
  bool _custom = false;
  bool _busy = false;
  String? _error;
  final _label = TextEditingController();

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Future<void> _make() async {
    final t = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final d = await widget.source.createShareLink(widget.siteId, {
        'cameras': _picked.toList(),
        'hours': _hours,
        'label': _label.text.trim(),
      });
      if (!mounted) return;
      Navigator.of(context).pop(d);
      return;
    } catch (e) {
      _error = wmError(e) ?? t.wmGenericError;
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.ctmNewLink, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(t.ctmPickCameras, style: Theme.of(context).textTheme.labelLarge),
        for (final c in widget.cameras)
          CheckboxListTile(
            key: ValueKey('ctm-link-cam-${c['id']}'),
            value: _picked.contains((c['id'] as num).toInt()),
            title: Text((c['name'] ?? '').toString()),
            controlAffinity: ListTileControlAffinity.leading,
            onChanged: (v) => setState(() {
              final id = (c['id'] as num).toInt();
              v == true ? _picked.add(id) : _picked.remove(id);
            }),
          ),
        const SizedBox(height: 8),
        Text(t.ctmLinkHowLong, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        Wrap(spacing: 8, runSpacing: 8, children: [
          ChoiceChip(
              label: Text(t.ctmHours(wmDigits(lang, 1))),
              selected: !_custom && _hours == 1,
              onSelected: (_) => setState(() {
                    _custom = false;
                    _hours = 1;
                  })),
          ChoiceChip(
              label: Text(t.ctmHours(wmDigits(lang, 24))),
              selected: !_custom && _hours == 24,
              onSelected: (_) => setState(() {
                    _custom = false;
                    _hours = 24;
                  })),
          ChoiceChip(
              label: Text(t.ctmCustom),
              selected: _custom,
              onSelected: (_) => setState(() {
                    _custom = true;
                    if (_hours == 1 || _hours == 24) _hours = 4;
                  })),
        ]),
        if (_custom) ...[
          Slider(
            value: _hours.toDouble(),
            min: 1,
            max: widget.maxHours.toDouble(),
            divisions: widget.maxHours - 1,
            label: t.ctmHours(wmDigits(lang, _hours)),
            onChanged: (v) => setState(() => _hours = v.round()),
          ),
          Text(t.ctmHours(wmDigits(lang, _hours)), textAlign: TextAlign.center),
        ],
        const SizedBox(height: 8),
        TextField(
          controller: _label,
          maxLength: 40,
          buildCounter: localCounter,
          decoration: InputDecoration(
              labelText: t.ctmLinkLabel, hintText: t.ctmLinkLabelHint, border: const OutlineInputBorder()),
        ),
        Text(t.ctmLinkWarning),
        if (_error != null && _error!.isNotEmpty)
          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        const SizedBox(height: 8),
        FilledButton(
          key: const ValueKey('ctm-link-make'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
          onPressed: _busy || _picked.isEmpty ? null : _make,
          child: Text(t.ctmMakeLink),
        ),
      ]),
    );
  }
}

class _LinkReadySheet extends StatelessWidget {
  final Map<String, dynamic> link;
  final String siteName;
  const _LinkReadySheet({required this.link, required this.siteName});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final url = (link['url'] ?? '').toString();
    final until = ctmTime(lang, link['expires_at']?.toString());
    final msg = t.ctmShareMessage(siteName, until, url);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.ctmLinkReady, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        SelectableText(url),
        const SizedBox(height: 4),
        Text(t.ctmLinkUntil(until)),
        Text(t.ctmLinkOnce, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const ValueKey('ctm-link-share'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
          icon: const Icon(Icons.share_rounded),
          label: Text(t.ctmShareLink),
          onPressed: () => Share.share(msg),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const ValueKey('ctm-link-copy'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 52)),
          icon: const Icon(Icons.copy_rounded),
          label: Text(t.ctmCopyLink),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: url));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.ctmCopied)));
            }
          },
        ),
      ]),
    );
  }
}

/// cctvteam (audit I) — who (family, guard, manager, a share link) looked at
/// which camera and when; the owner only. Assisto staff never appear here
/// because they have no way in.
class CctvAccessLogScreen extends StatefulWidget {
  final CctvTeamSource source;
  final int siteId;
  const CctvAccessLogScreen({super.key, required this.source, required this.siteId});

  @override
  State<CctvAccessLogScreen> createState() => _CctvAccessLogScreenState();
}

class _CctvAccessLogScreenState extends State<CctvAccessLogScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _rows = const [];
  String _note = '';

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
      final d = await widget.source.accessLog(widget.siteId);
      _rows = wmList(d['rows']);
      _note = (d['note'] ?? '').toString();
    } catch (e) {
      _error = wmError(e) ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    String what(Map<String, dynamic> r) => switch ((r['action'] ?? '').toString()) {
          'alerts' => t.ctmLogAlerts,
          'alert' => t.ctmLogAlert,
          'live' => t.ctmLogLive,
          'link' => t.ctmLogLink,
          _ => t.ctmLogStill,
        };
    IconData icon(String a) => switch (a) {
          'live' => Icons.live_tv_rounded,
          'link' => Icons.link_rounded,
          'still' => Icons.photo_camera_outlined,
          _ => Icons.notifications_none_rounded,
        };
    return Scaffold(
      appBar: AppBar(title: Text(t.ctmLogTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: withNavBarInset(context, const EdgeInsets.fromLTRB(16, 12, 16, 32)),
                children: [
                  if (_note.isNotEmpty) Text(_note),
                  const SizedBox(height: 8),
                  if (_error != null) Text(_error!.isEmpty ? t.wmLoadErrorBody : _error!),
                  if (_error == null && _rows.isEmpty)
                    CvEmptyBlock(
                      compact: true,
                      icon: Icons.history_rounded,
                      title: t.ctmLogEmptyTitle,
                      benefit: t.ctmLogEmptyBenefit,
                      primaryIcon: Icons.refresh_rounded,
                      primaryLabel: t.ctmWatchEmptyRefresh,
                      onPrimary: _load,
                      steps: [t.ctmLogStep1, t.ctmLogStep2],
                    ),
                  for (final r in _rows)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(child: Icon(icon((r['action'] ?? '').toString()))),
                      title: Text(r['link_id'] != null
                          ? t.ctmLogByLink((r['link_label'] ?? '').toString().isEmpty
                              ? t.ctmLinkNoLabel
                              : r['link_label'].toString())
                          : ((r['name'] ?? '').toString().isEmpty ? t.wmFamilyNoName : r['name'].toString())),
                      subtitle: Text([
                        what(r),
                        if ((r['camera_name'] ?? '').toString().isNotEmpty) r['camera_name'].toString(),
                        ctmTime(lang, r['at']?.toString()),
                      ].join(' · ')),
                    ),
                ],
              ),
            ),
    );
  }
}
