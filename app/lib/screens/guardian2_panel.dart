import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import '../widgets/local_digits.dart';

/// guardian2 — PART 6 TWO GUARDIANS (owner 3 Nov 18:40). Lives inside the
/// Guardians page (CircleGuardiansScreen), which is reachable from the
/// sidebar (Family & Safety), Family Care, Safe Journey and the child's
/// School Mode screen.
///
///   invite   an existing guardian -> code + link (48 h, one use)
///   join     the second person types the code -> waits; sees NOTHING yet
///   approve  an existing guardian taps Approve / Reject
///   remove   any guardian removes the co-guardian, or the co-guardian leaves
///            (both guardians + the child are told)
/// Server rules: backend/core/guardian_links.py. Always free; the plan only
/// sets how many guardians a child may have.

/// Tests / gallery: replace the network ({method, path, body} -> json).
Future<Map<String, dynamic>> Function(String method, String path, Map<String, dynamic>? body)?
    guardian2ApiOverride;

Future<Map<String, dynamic>> _call(
    BuildContext context, String method, String path, [Map<String, dynamic>? body]) {
  if (guardian2ApiOverride != null) return guardian2ApiOverride!(method, path, body);
  final api = context.read<AppState>().api;
  return method == 'GET' ? api.getJson(path) : api.postJson(path, body ?? const {});
}

bool _bn(BuildContext c) => Localizations.localeOf(c).languageCode == 'bn';

/// "3/11/2026" in the app's digits ('' when unknown).
String g2Date(BuildContext context, Object? iso) {
  final d = DateTime.tryParse('${iso ?? ''}');
  if (d == null) return '';
  final l = d.toLocal();
  return toLocalDigits('${l.day}/${l.month}/${l.year}', _bn(context));
}

String _errText(AppLocalizations t, BuildContext context, Object e) {
  if (e is ApiException) {
    final code = '${e.body?['detail'] ?? ''}';
    switch (code) {
      case 'limit':
        return t.g2Limit(toLocalDigits('${e.body?['max'] ?? 2}', _bn(context)));
      case 'bad_code':
        return t.g2ErrBadCode;
      case 'expired':
        return t.g2ErrExpired;
      case 'code_used':
      case 'already_pending':
        return t.g2ErrUsed;
      case 'already_guardian':
        return t.g2ErrAlready;
      case 'self':
        return t.g2ErrSelf;
    }
  }
  return t.g2ActionFailed;
}

void _snack(BuildContext context, String s) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(s)));

/// Invite a second guardian for one child: creates the code, then shows it
/// with Copy + Share and the honest rule (nothing is seen until you approve).
Future<bool> showGuardianInvite(BuildContext context, int childId, String childName) async {
  final t = AppLocalizations.of(context);
  Map<String, dynamic> inv;
  try {
    inv = await _call(context, 'POST', '/guardians/invites', {'child_id': childId});
  } catch (e) {
    if (context.mounted) _snack(context, _errText(t, context, e));
    return false;
  }
  if (!context.mounted) return false;
  final code = '${inv['code'] ?? ''}';
  final link = '${inv['link'] ?? ''}';
  await showAppSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.g2InviteTitle(childName),
            style: AType.titleLarge.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.sm),
        Text(t.g2InviteBody, style: AType.bodyMedium),
        const SizedBox(height: Gap.md),
        Semantics(
          label: code.split('').join(' '),
          child: SelectableText(code,
              key: const Key('g2-invite-code'),
              textAlign: TextAlign.center,
              style: AType.headlineMedium
                  .copyWith(fontWeight: FontWeight.w800, letterSpacing: 4)),
        ),
        const SizedBox(height: Gap.xs),
        Text(t.g2InviteExpires,
            textAlign: TextAlign.center,
            style: AType.bodySmall
                .copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
        const SizedBox(height: Gap.md),
        FilledButton.icon(
          key: const Key('g2-invite-share'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: () => Share.share(t.g2ShareText(childName, code, link)),
          icon: const Icon(Icons.share_rounded),
          label: Text(t.g2Share),
        ),
        const SizedBox(height: Gap.sm),
        OutlinedButton.icon(
          key: const Key('g2-invite-copy'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: code));
            if (ctx.mounted) _snack(ctx, t.g2Copied);
          },
          icon: const Icon(Icons.copy_rounded),
          label: Text(t.g2Copy),
        ),
      ]),
    ),
  );
  return true;
}

/// Requests to approve, my unused codes, the co-guardians (remove), my own
/// requests (waiting / leave) and "Join with a code".
class Guardian2Panel extends StatefulWidget {
  const Guardian2Panel({super.key, required this.onChanged, this.getOverride});

  /// The page's own test loader (guardiansLoaderOverride) — used for the GET
  /// when [guardian2ApiOverride] is not set, so older tests/shots stay offline.
  final Future<Map<String, dynamic>> Function(String path)? getOverride;

  /// The parent page reloads its lists (who sees me / children) after a change.
  final VoidCallback onChanged;

  @override
  State<Guardian2Panel> createState() => Guardian2PanelState();
}

class Guardian2PanelState extends State<Guardian2Panel> {
  Map<String, dynamic> _d = const {};
  bool _loading = true;
  bool _failed = false;
  int? _busy;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => reload());
  }

  List<Map<String, dynamic>> _rows(String k) => [
        for (final x in (_d[k] as List? ?? const []))
          if (x is Map) x.cast<String, dynamic>()
      ];

  Future<void> reload() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final d = (guardian2ApiOverride == null && widget.getOverride != null)
          ? await widget.getOverride!('/guardians/links')
          : await _call(context, 'GET', '/guardians/links');
      if (!mounted) return;
      setState(() {
        _d = d;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  Future<void> _act(Map<String, dynamic> link, String action, String okText) async {
    final t = AppLocalizations.of(context);
    final id = (link['id'] as num).toInt();
    setState(() => _busy = id);
    try {
      final r = await _call(context, 'POST', '/guardians/links/$id/$action');
      if (!mounted) return;
      setState(() {
        _d = r;
        _busy = null;
      });
      _snack(context, okText);
      widget.onChanged();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = null);
      _snack(context, _errText(t, context, e));
    }
  }

  Future<bool> _confirm(String title, String body, String yes) async {
    final ok = await showAppSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: AType.titleLarge.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.sm),
          Text(body, style: AType.bodyMedium),
          const SizedBox(height: Gap.lg),
          FilledButton(
            key: const Key('g2-confirm-yes'),
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                backgroundColor: Theme.of(ctx).colorScheme.error,
                foregroundColor: Theme.of(ctx).colorScheme.onError),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(yes),
          ),
          const SizedBox(height: Gap.sm),
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppLocalizations.of(ctx).cancel),
          ),
        ]),
      ),
    );
    return ok == true;
  }

  Future<void> _join() async {
    final t = AppLocalizations.of(context);
    final ctrl = TextEditingController();
    final code = await showAppSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(t.g2JoinTitle, style: AType.titleLarge.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.sm),
            Text(t.g2JoinBody, style: AType.bodyMedium),
            const SizedBox(height: Gap.md),
            TextField(
              key: const Key('g2-join-field'),
              controller: ctrl,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                  labelText: t.g2JoinHint, border: const OutlineInputBorder()),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
            const SizedBox(height: Gap.md),
            FilledButton(
              key: const Key('g2-join-send'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: Text(t.g2JoinSend),
            ),
          ]),
        ),
      ),
    );
    ctrl.dispose();
    if (!mounted || code == null || code.trim().isEmpty) return;
    try {
      await _call(context, 'POST', '/guardians/join', {'code': code.trim()});
      if (!mounted) return;
      _snack(context, t.g2JoinSent);
      await reload();
    } catch (e) {
      if (mounted) _snack(context, _errText(t, context, e));
    }
  }

  Widget _busyIcon(int id, IconData icon) => _busy == id
      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
      : Icon(icon);

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final toApprove = _rows('to_approve');
    final invites = _rows('invites');
    final co = _rows('co_guardians');
    final mine = _rows('my_requests');
    final muted = AType.bodySmall.copyWith(color: scheme.onSurfaceVariant);
    return Column(
      key: const Key('g2-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_failed)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: Row(children: [
              Expanded(child: Text(t.cgaLoadFailed, style: AType.bodyMedium)),
              TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: reload,
                  child: Text(t.retry)),
            ]),
          ),
        if (_loading && _d.isEmpty) const LinearProgressIndicator(),
        // ---- requests waiting for MY approval (highest priority)
        for (final l in toApprove)
          Card(
            key: ValueKey('g2-approve-card-${l['id']}'),
            color: scheme.tertiaryContainer,
            margin: const EdgeInsets.only(bottom: Gap.sm),
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(t.g2ToApprove,
                    style: AType.labelLarge.copyWith(
                        fontWeight: FontWeight.w700, color: scheme.onTertiaryContainer)),
                const SizedBox(height: Gap.xs),
                Text(t.g2WantsToGuard('${l['guardian_name']}', '${l['child_name']}'),
                    style: AType.titleMedium.copyWith(color: scheme.onTertiaryContainer)),
                const SizedBox(height: Gap.xs),
                Text(t.g2ApproveNote('${l['child_name']}'),
                    style: AType.bodyMedium.copyWith(color: scheme.onTertiaryContainer)),
                const SizedBox(height: Gap.sm),
                Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
                  FilledButton.icon(
                    key: ValueKey('g2-approve-${l['id']}'),
                    style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: _busy != null
                        ? null
                        : () => _act(l, 'approve', t.g2Approved('${l['guardian_name']}')),
                    icon: _busyIcon((l['id'] as num).toInt(), Icons.check_rounded),
                    label: Text(t.g2Approve),
                  ),
                  OutlinedButton.icon(
                    key: ValueKey('g2-reject-${l['id']}'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: _busy != null ? null : () => _act(l, 'reject', t.g2Rejected),
                    icon: const Icon(Icons.close_rounded),
                    label: Text(t.g2Reject),
                  ),
                ]),
              ]),
            ),
          ),
        // ---- approved co-guardians of my children (remove)
        for (final l in co)
          Card(
            key: ValueKey('g2-co-${l['id']}'),
            margin: const EdgeInsets.only(bottom: Gap.sm),
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  const Icon(Icons.verified_user_rounded),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                      child: Text(t.g2CoGuardianOf('${l['guardian_name']}', '${l['child_name']}'),
                          style: AType.titleMedium)),
                ]),
                if (g2Date(context, l['approved_at']).isNotEmpty)
                  Text(t.g2Since(g2Date(context, l['approved_at'])), style: muted),
                const SizedBox(height: Gap.xs),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: OutlinedButton.icon(
                    key: ValueKey('g2-remove-${l['id']}'),
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size(48, 48), foregroundColor: scheme.error),
                    onPressed: _busy != null
                        ? null
                        : () async {
                            final name = '${l['guardian_name']}';
                            final child = '${l['child_name']}';
                            if (await _confirm(t.g2RemoveCoTitle(name),
                                t.g2RemoveCoBody(name, child), t.cgaRemoveYes)) {
                              await _act(l, 'remove', t.g2Removed);
                            }
                          },
                    icon: _busyIcon((l['id'] as num).toInt(), Icons.person_remove_rounded),
                    label: Text(t.g2RemoveCo('${l['guardian_name']}')),
                  ),
                ),
              ]),
            ),
          ),
        // ---- my unused codes
        for (final l in invites)
          Card(
            key: ValueKey('g2-invite-${l['id']}'),
            margin: const EdgeInsets.only(bottom: Gap.sm),
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(t.g2InviteActive('${l['code']}', '${l['child_name']}'),
                    style: AType.bodyLarge),
                const SizedBox(height: Gap.xs),
                Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: () => Share.share(t.g2ShareText(
                        '${l['child_name']}', '${l['code']}', '${l['link']}')),
                    icon: const Icon(Icons.share_rounded),
                    label: Text(t.g2Share),
                  ),
                  TextButton(
                    key: ValueKey('g2-cancel-${l['id']}'),
                    style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: _busy != null ? null : () => _act(l, 'remove', t.g2Removed),
                    child: Text(t.g2CancelInvite),
                  ),
                ]),
              ]),
            ),
          ),
        // ---- my own requests (as the second guardian)
        for (final l in mine)
          Card(
            key: ValueKey('g2-mine-${l['id']}'),
            margin: const EdgeInsets.only(bottom: Gap.sm),
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Icon(l['state'] == 'approved'
                      ? Icons.verified_user_rounded
                      : Icons.hourglass_top_rounded),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(
                        l['state'] == 'approved'
                            ? t.g2YouGuard('${l['child_name']}')
                            : t.g2WaitingFor('${l['child_name']}'),
                        style: AType.titleMedium),
                  ),
                ]),
                if (l['state'] == 'approved' && g2Date(context, l['approved_at']).isNotEmpty)
                  Text(t.g2Since(g2Date(context, l['approved_at'])), style: muted),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    key: ValueKey('g2-leave-${l['id']}'),
                    style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48), foregroundColor: scheme.error),
                    onPressed: _busy != null
                        ? null
                        : () async {
                            final child = '${l['child_name']}';
                            if (l['state'] != 'approved' ||
                                await _confirm(t.g2LeaveTitle(child), t.g2LeaveBody(child),
                                    t.g2Leave)) {
                              await _act(l, 'remove', t.g2Removed);
                            }
                          },
                    child: Text(l['state'] == 'approved' ? t.g2Leave : t.g2CancelInvite),
                  ),
                ),
              ]),
            ),
          ),
        OutlinedButton.icon(
          key: const Key('g2-join'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: _join,
          icon: const Icon(Icons.vpn_key_rounded),
          label: Text(t.g2JoinBtn),
        ),
      ],
    );
  }
}
