import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import '../../services/error_kind.dart' show honestFailText; // qa2

/// PA Secretary Mode · CELEBRITY tier — Unified social inbox / DM triage
/// (#123, §14).
///
/// A MANUAL triage board for a public figure's PA: the PA logs important
/// DMs/mentions (platform, from, message, priority, status) and works them
/// open-first → priority → newest. Deterministic counts (open, urgent,
/// per-platform).
///
/// LIVE Instagram / Facebook-Page DM fetch is a DOCUMENTED, key-gated seam — it
/// needs the owner's own `instagram` + `messenger` (FB Page) accounts connected
/// via Integrations (Meta Graph). Until then an honest "connect your Page /
/// Instagram account" card is shown and the board stays manual. We NEVER
/// fabricate a DM or a sender. This is Assisto's own tool — NOT a Meta client.
///
/// Mirrors backend/core/logic/pa_socialinbox.py. ZERO Bangla literals.
/// Endpoints: listItems('star/socialinbox') / createItem / updateItem / delete.
class SocialInboxScreen extends StatefulWidget {
  const SocialInboxScreen({super.key});
  @override
  State<SocialInboxScreen> createState() => _SocialInboxScreenState();
}

// ---- constants (mirror pa_socialinbox.py) ---------------------------------
const List<String> _platforms = [
  'instagram', 'facebook', 'messenger', 'twitter', 'youtube', 'other'
];
const String _prUrgent = 'urgent';
const String _prNormal = 'normal';
const String _prLow = 'low';
const List<String> _priorities = [_prUrgent, _prNormal, _prLow];
const Map<String, int> _prRank = {_prUrgent: 0, _prNormal: 1, _prLow: 2};

const String _stNew = 'new';
const String _stReplied = 'replied';
const String _stArchived = 'archived';
const List<String> _statuses = [_stNew, _stReplied, _stArchived];

class _SocialInboxScreenState extends State<SocialInboxScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true, _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  bool _hideHandled = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      _rows = await context.read<AppState>().api.listItems('star/socialinbox');
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  // ---- mirror helpers ------------------------------------------------------
  String _platform(Map<String, dynamic> r) {
    final v = (r['platform'] ?? '').toString().toLowerCase();
    return _platforms.contains(v) ? v : 'other';
  }

  String _priority(Map<String, dynamic> r) {
    final v = (r['priority'] ?? '').toString().toLowerCase();
    return _priorities.contains(v) ? v : _prNormal;
  }

  String _status(Map<String, dynamic> r) {
    final v = (r['status'] ?? _stNew).toString().toLowerCase();
    return _statuses.contains(v) ? v : _stNew;
  }

  bool _isOpen(Map<String, dynamic> r) => _status(r) == _stNew;

  DateTime? _parseAt(Map<String, dynamic> r) {
    final s = (r['at'] ?? '').toString().trim();
    if (s.isEmpty) return null;
    return DateTime.tryParse(s.endsWith('Z') ? s.substring(0, s.length - 1) : s);
  }

  List<Map<String, dynamic>> get _ordered {
    final list = _rows.where((r) {
      if (_hideHandled && !_isOpen(r)) return false;
      return true;
    }).toList();
    list.sort((a, b) {
      final oa = _isOpen(a) ? 0 : 1;
      final ob = _isOpen(b) ? 0 : 1;
      if (oa != ob) return oa - ob;
      final pa = _prRank[_priority(a)] ?? 1;
      final pb = _prRank[_priority(b)] ?? 1;
      if (pa != pb) return pa - pb;
      final ta = _parseAt(a);
      final tb = _parseAt(b);
      if (ta == null && tb == null) return 0;
      if (ta == null) return 1;
      if (tb == null) return -1;
      return tb.compareTo(ta); // newest first
    });
    return list;
  }

  int get _openCount => _rows.where(_isOpen).length;
  int get _urgentCount =>
      _rows.where((r) => _isOpen(r) && _priority(r) == _prUrgent).length;

  // ---- actions -------------------------------------------------------------
  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _setStatus(Map<String, dynamic> r, String to) async {
    final id = r['id'];
    try {
      if (id is int) {
        await context.read<AppState>().api.updateItem('star/socialinbox', id, {'status': to});
      }
      await _load();
    } catch (_) {
      if (mounted) _toast(AppLocalizations.of(context).saveFailed);
    }
  }

  Future<void> _addOrEdit(AppLocalizations tr, {Map<String, dynamic>? existing}) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _TriageForm(existing: existing),
    );
    if (result == null) return;
    try {
      if (existing != null && existing['id'] is int) {
        await context.read<AppState>().api.updateItem('star/socialinbox', existing['id'] as int, result);
      } else {
        await context.read<AppState>().api.createItem('star/socialinbox', result);
      }
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _delete(Map<String, dynamic> r, AppLocalizations tr) async {
    final id = r['id'];
    try {
      if (id is int) await context.read<AppState>().api.deleteItem('star/socialinbox', id);
      await _load();
    } catch (_) {
      if (mounted) _toast(tr.deleteFailed);
    }
  }

  void _showConnect(AppLocalizations tr) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xl),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.link, color: scheme.primary),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(tr.socialInboxConnectTitle,
                    style: Theme.of(ctx).textTheme.titleLarge),
              ),
            ]),
            const SizedBox(height: Gap.md),
            Text(tr.socialInboxConnectBody,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
            const SizedBox(height: Gap.md),
            Container(
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Radii.sm),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.shield_outlined, size: 18, color: scheme.primary),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(tr.socialInboxConnectKeys,
                      style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.4)),
                ),
              ]),
            ),
            const SizedBox(height: Gap.md),
            Text(tr.socialInboxNeverFabricate,
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.3)),
            const SizedBox(height: Gap.md),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr.ok),
              ),
            ),
          ]),
        );
      },
    );
  }

  // ---- build ---------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr.socialInboxTitle), actions: [
        IconButton(
          tooltip: tr.socialInboxConnectTitle,
          icon: const Icon(Icons.link),
          onPressed: () => _showConnect(tr),
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading ? null : () => _addOrEdit(tr),
        icon: const Icon(Icons.add),
        label: Text(tr.socialInboxAdd),
      ),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off,
                  tint: scheme.error,
                  title: tr.loadFailed,
                  message: honestFailText(tr, _failCause, otherwise: tr.socialInboxLoadError),
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: Text(tr.retry)),
                )
              : _rows.isEmpty
                  ? _welcome(tr)
                  : _bodyView(tr, scheme),
    );
  }

  Widget _welcome(AppLocalizations tr) => ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          const SizedBox(height: Gap.xl),
          StateMessage(
            icon: Icons.forum_outlined,
            title: tr.socialInboxWelcomeTitle,
            message: tr.socialInboxWelcomeBody,
            action: FilledButton.icon(
              onPressed: () => _addOrEdit(tr),
              icon: const Icon(Icons.add),
              label: Text(tr.socialInboxAdd),
            ),
          ),
          const SizedBox(height: Gap.lg),
          _connectSeamCard(tr, Theme.of(context).colorScheme),
        ],
      );

  Widget _connectSeamCard(AppLocalizations tr, ColorScheme scheme) => Container(
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.lock_outline, size: 18, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr.socialInboxConnectTitle,
                  style: const TextStyle(fontWeight: FontWeight.w700, height: 1.4)),
              const SizedBox(height: Gap.xxs),
              Text(tr.socialInboxConnectBody,
                  style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.4)),
            ]),
          ),
        ]),
      );

  Widget _bodyView(AppLocalizations tr, ColorScheme scheme) {
    final list = _ordered;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 0),
        child: Row(children: [
          _stat(Icons.mark_email_unread_outlined, tr.socialInboxStatOpen('$_openCount'), scheme),
          const SizedBox(width: Gap.sm),
          _stat(Icons.priority_high, tr.socialInboxStatUrgent('$_urgentCount'),
              scheme, tint: _urgentCount > 0 ? scheme.error : null),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
        child: Row(children: [
          FilterChip(
            label: Text(tr.socialInboxHideHandled),
            selected: _hideHandled,
            onSelected: (_) => setState(() => _hideHandled = !_hideHandled),
          ),
        ]),
      ),
      Expanded(
        child: list.isEmpty
            ? StateMessage(
                icon: Icons.inbox_outlined,
                title: tr.socialInboxAllClearTitle,
                message: tr.socialInboxAllClearBody,
              )
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 96),
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const SizedBox(height: Gap.sm),
                  itemBuilder: (_, i) => _card(list[i], tr, scheme),
                ),
              ),
      ),
    ]);
  }

  Widget _stat(IconData icon, String text, ColorScheme scheme, {Color? tint}) =>
      Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.sm),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: tint ?? scheme.onSurfaceVariant),
            const SizedBox(width: Gap.xs),
            Flexible(
              child: Text(text,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: AType.bodySmall.copyWith(color: tint ?? scheme.onSurface)),
            ),
          ]),
        ),
      );

  Color _priorityColor(String p, ColorScheme scheme) {
    switch (p) {
      case _prUrgent:
        return scheme.error;
      case _prLow:
        return scheme.onSurfaceVariant;
      default:
        return scheme.primary;
    }
  }

  String _priorityLabel(AppLocalizations tr, String p) {
    switch (p) {
      case _prUrgent:
        return tr.socialInboxPriorityUrgent;
      case _prLow:
        return tr.socialInboxPriorityLow;
      default:
        return tr.socialInboxPriorityNormal;
    }
  }

  IconData _platformIcon(String p) {
    switch (p) {
      case 'instagram':
        return Icons.camera_alt_outlined;
      case 'facebook':
      case 'messenger':
        return Icons.chat_bubble_outline;
      case 'twitter':
        return Icons.alternate_email;
      case 'youtube':
        return Icons.play_circle_outline;
      default:
        return Icons.public;
    }
  }

  String _platformLabel(AppLocalizations tr, String p) {
    switch (p) {
      case 'instagram':
        return tr.socialInboxPlatInstagram;
      case 'facebook':
        return tr.socialInboxPlatFacebook;
      case 'messenger':
        return tr.socialInboxPlatMessenger;
      case 'twitter':
        return tr.socialInboxPlatTwitter;
      case 'youtube':
        return tr.socialInboxPlatYoutube;
      default:
        return tr.socialInboxPlatOther;
    }
  }

  Widget _card(Map<String, dynamic> r, AppLocalizations tr, ColorScheme scheme) {
    final platform = _platform(r);
    final priority = _priority(r);
    final status = _status(r);
    final from = (r['from_handle'] ?? r['from'] ?? '').toString().trim();
    final message = (r['message'] ?? '').toString().trim();
    final handled = status != _stNew;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(_platformIcon(platform), size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(from.isEmpty ? _platformLabel(tr, platform) : from,
                  style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700, color: handled ? scheme.onSurfaceVariant : scheme.onSurface),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            _pill(_priorityLabel(tr, priority), _priorityColor(priority, scheme)),
          ]),
          const SizedBox(height: Gap.xxs),
          Text(_platformLabel(tr, platform),
              style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          if (message.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Text(message,
                style: AType.bodyMedium.copyWith(color: scheme.onSurface, height: 1.35),
                maxLines: 4, overflow: TextOverflow.ellipsis),
          ],
          const Divider(height: Gap.xl),
          Row(children: [
            if (status == _stNew)
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () => _setStatus(r, _stReplied),
                  icon: const Icon(Icons.reply, size: 18),
                  label: Text(tr.socialInboxMarkReplied,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              )
            else
              Expanded(
                child: Text(
                    status == _stReplied ? tr.socialInboxStatusReplied : tr.socialInboxStatusArchived,
                    style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
              ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (v) {
                if (v == 'edit') _addOrEdit(tr, existing: r);
                if (v == 'archive') _setStatus(r, _stArchived);
                if (v == 'new') _setStatus(r, _stNew);
                if (v == 'delete') _delete(r, tr);
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'edit', child: Text(tr.edit)),
                if (status != _stArchived)
                  PopupMenuItem(value: 'archive', child: Text(tr.socialInboxArchive)),
                if (status != _stNew)
                  PopupMenuItem(value: 'new', child: Text(tr.socialInboxReopen)),
                PopupMenuItem(value: 'delete', child: Text(tr.delete)),
              ],
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _pill(String text, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Text(text,
            style: AType.bodySmall.copyWith(color: c, fontWeight: FontWeight.w700)),
      );
}

/// Add / edit a triage item (the PA's own log — never fabricated).
class _TriageForm extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _TriageForm({this.existing});
  @override
  State<_TriageForm> createState() => _TriageFormState();
}

class _TriageFormState extends State<_TriageForm> {
  late final TextEditingController _from = TextEditingController(
      text: (widget.existing?['from_handle'] ?? widget.existing?['from'] ?? '').toString());
  late final TextEditingController _message =
      TextEditingController(text: widget.existing?['message']?.toString() ?? '');
  late final TextEditingController _at =
      TextEditingController(text: widget.existing?['at']?.toString() ?? '');
  late String _platform = _platforms.contains((widget.existing?['platform'] ?? '').toString())
      ? widget.existing!['platform'].toString()
      : 'instagram';
  late String _priority = _priorities.contains((widget.existing?['priority'] ?? '').toString())
      ? widget.existing!['priority'].toString()
      : _prNormal;

  @override
  void dispose() {
    _from.dispose();
    _message.dispose();
    _at.dispose();
    super.dispose();
  }

  String _platformLabel(AppLocalizations tr, String p) {
    switch (p) {
      case 'instagram':
        return tr.socialInboxPlatInstagram;
      case 'facebook':
        return tr.socialInboxPlatFacebook;
      case 'messenger':
        return tr.socialInboxPlatMessenger;
      case 'twitter':
        return tr.socialInboxPlatTwitter;
      case 'youtube':
        return tr.socialInboxPlatYoutube;
      default:
        return tr.socialInboxPlatOther;
    }
  }

  String _priorityLabel(AppLocalizations tr, String p) {
    switch (p) {
      case _prUrgent:
        return tr.socialInboxPriorityUrgent;
      case _prLow:
        return tr.socialInboxPriorityLow;
      default:
        return tr.socialInboxPriorityNormal;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final valid = _from.text.trim().isNotEmpty || _message.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.existing == null ? tr.socialInboxAdd : tr.socialInboxEdit,
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.lg),
          Text(tr.socialInboxPlatformLabel, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            for (final p in _platforms)
              ChoiceChip(
                label: Text(_platformLabel(tr, p)),
                selected: _platform == p,
                onSelected: (_) => setState(() => _platform = p),
              ),
          ]),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _from,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
                labelText: tr.socialInboxFromField, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _message,
            maxLines: 4,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
                labelText: tr.socialInboxMessageField,
                border: const OutlineInputBorder(),
                alignLabelWithHint: true),
          ),
          const SizedBox(height: Gap.md),
          Text(tr.socialInboxPriorityLabel, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, children: [
            for (final p in _priorities)
              ChoiceChip(
                label: Text(_priorityLabel(tr, p)),
                selected: _priority == p,
                onSelected: (_) => setState(() => _priority = p),
              ),
          ]),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _at,
            decoration: InputDecoration(
                labelText: tr.socialInboxAtField,
                hintText: 'YYYY-MM-DD HH:MM',
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.lg),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                child: Text(tr.cancel),
              ),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: FilledButton(
                onPressed: valid
                    ? () => Navigator.pop(context, <String, dynamic>{
                          'platform': _platform,
                          'from_handle': _from.text.trim(),
                          'message': _message.text.trim(),
                          'priority': _priority,
                          'at': _at.text.trim(),
                          'status': (widget.existing?['status'] ?? _stNew).toString(),
                        })
                    : null,
                child: Text(tr.save),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}
