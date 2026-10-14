import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/sec_engine.dart';
import '../widgets/skeleton.dart';

/// DIGITAL SECURITY CHECK-UP (#198, SPEC v2.1 §20, ADVANCED).
///
/// A guided self-audit: a checklist of the security practices that actually
/// protect an ordinary user's phone, money and accounts (screen lock, app lock,
/// a strong wallet PIN, 2FA, strong passwords, backups, scam-awareness, app
/// permissions). The user marks each DONE; we compute a DETERMINISTIC security
/// SCORE (% + grade), show an honest list of weak areas, and give a concrete
/// tip for each item.
///
/// HONEST BY DESIGN. Nothing here probes the device or claims a protection is
/// on — the check-up is ENTIRELY SELF-REPORTED, and a banner says so. Scoring is
/// the pure Dart mirror ([scoreSecurity]) of `core/logic/security_checkup.py`.
///
/// PERSISTENCE. The checklist is one row in the generic REST collection
/// 'security/checklist':
///   { "id": <int>, "answers": {"screen_lock": true, ...}, "updated_at": "<iso>" }
/// We read the first row on open; on each toggle we PATCH it (or POST once if
/// none exists). All state is sanitised through [secSanitize] so the stored row
/// never drifts. Offline edits stay on screen; the save is best-effort.
class SecurityCheckupScreen extends StatefulWidget {
  const SecurityCheckupScreen({super.key});
  @override
  State<SecurityCheckupScreen> createState() => _SecurityCheckupScreenState();
}

class _SecurityCheckupScreenState extends State<SecurityCheckupScreen> {
  static const _collection = 'security/checklist';

  Map<String, bool> _answers = {for (final id in kSecItemIds) id: false};
  int? _rowId; // the single persisted row's id (null ⇒ not created yet)
  bool _loading = true;
  String? _error;
  bool _saving = false;

  AppLocalizations get t => AppLocalizations.of(context);

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
      final rows =
          await context.read<AppState>().api.listItems(_collection);
      if (!mounted) return;
      setState(() {
        if (rows.isNotEmpty) {
          _rowId = rows.first['id'] as int?;
          _answers = secAnswersFromRow(rows.first);
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _toggle(String id, bool v) async {
    setState(() {
      _answers = {..._answers, id: v};
      _saving = true;
    });
    final api = context.read<AppState>().api;
    final body = {
      'answers': secSanitize(_answers),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    try {
      if (_rowId == null) {
        final created = await api.createItem(_collection, body);
        _rowId = created['id'] as int?;
      } else {
        await api.updateItem(_collection, _rowId!, body);
      }
    } catch (_) {
      // best-effort: keep the optimistic on-screen state; it re-saves next toggle
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _resetConfirm() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.secResetTitle),
        content: Text(t.secResetBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.secResetConfirm)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _answers = {for (final id in kSecItemIds) id: false});
    final api = context.read<AppState>().api;
    final body = {
      'answers': secSanitize(_answers),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    try {
      if (_rowId == null) {
        final created = await api.createItem(_collection, body);
        _rowId = created['id'] as int?;
      } else {
        await api.updateItem(_collection, _rowId!, body);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final score = scoreSecurity(_answers);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.secTitle),
        actions: [
          if (!_loading)
            IconButton(
              tooltip: t.secResetTitle,
              icon: const Icon(Icons.restart_alt),
              onPressed: _resetConfirm,
            ),
        ],
      ),
      body: _loading
          ? ListView(
              padding: const EdgeInsets.all(Gap.lg),
              children: const [
                Skeleton(height: 110, radius: 14),
                SizedBox(height: Gap.lg),
                Skeleton(height: 60, radius: 14),
                SizedBox(height: Gap.lg),
                Skeleton(height: 60, radius: 14),
                SizedBox(height: Gap.md),
                Skeleton(height: 60, radius: 14),
              ],
            )
          : _error != null
              ? _ErrorState(message: _error!, onRetry: _load, t: t)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 32),
                    children: [
                      _SecScoreCard(score: score, t: t),
                      const SizedBox(height: Gap.md),
                      _SelfReportedBanner(t: t),
                      if (score.weak.isNotEmpty) ...[
                        const SizedBox(height: Gap.lg),
                        _WeakAreasCard(score: score, t: t),
                      ],
                      const SizedBox(height: Gap.lg),
                      Text(t.secChecklistHeading,
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: Gap.sm),
                      for (final item in kSecItems)
                        _SecItemTile(
                          item: item,
                          done: _answers[item.id] ?? false,
                          onChanged: (v) => _toggle(item.id, v),
                          t: t,
                        ),
                      const SizedBox(height: Gap.md),
                      if (_saving)
                        Row(children: [
                          const SizedBox(
                              width: 14,
                              height: 14,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2)),
                          const SizedBox(width: Gap.sm),
                          Text(t.secSaving,
                              style: Theme.of(context).textTheme.bodySmall),
                        ]),
                    ],
                  ),
                ),
    );
  }
}

// --------------------------------------------------------------------------- //
// Score header — big ring + grade verdict + earned/max.
// --------------------------------------------------------------------------- //
class _SecScoreCard extends StatelessWidget {
  const _SecScoreCard({required this.score, required this.t});
  final SecScore score;
  final AppLocalizations t;

  Color _gradeColor(BuildContext context) {
    switch (score.grade) {
      case 'strong':
        return Brand.success;
      case 'good':
        return const Color(0xFF4CAF50);
      case 'fair':
        return Brand.warning;
      default:
        return Brand.danger;
    }
  }

  String _gradeLabel() {
    switch (score.grade) {
      case 'strong':
        return t.secGradeStrong;
      case 'good':
        return t.secGradeGood;
      case 'fair':
        return t.secGradeFair;
      default:
        return t.secGradeAtRisk;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _gradeColor(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Row(
          children: [
            SizedBox(
              width: 96,
              height: 96,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 96,
                    height: 96,
                    child: CircularProgressIndicator(
                      value: score.percent / 100,
                      strokeWidth: 9,
                      backgroundColor:
                          Theme.of(context).colorScheme.surfaceContainerHighest,
                      valueColor: AlwaysStoppedAnimation(color),
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('${score.percent}%',
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: Gap.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: Gap.md, vertical: 4),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(Radii.pill),
                    ),
                    child: Text(_gradeLabel(),
                        style: TextStyle(
                            color: color, fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(height: Gap.sm),
                  Text(
                    t.secDoneOfTotal(score.doneCount, score.totalCount),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    t.secGradeHint,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color:
                            Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --------------------------------------------------------------------------- //
// Honest "self-reported" banner — we never probe the device.
// --------------------------------------------------------------------------- //
class _SelfReportedBanner extends StatelessWidget {
  const _SelfReportedBanner({required this.t});
  final AppLocalizations t;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: cs.secondaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 20, color: cs.onSecondaryContainer),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(t.secSelfReportedNote,
                style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

// --------------------------------------------------------------------------- //
// Weak-areas card — honest "fix these first", worst-weight first.
// --------------------------------------------------------------------------- //
class _WeakAreasCard extends StatelessWidget {
  const _WeakAreasCard({required this.score, required this.t});
  final SecScore score;
  final AppLocalizations t;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final top = score.weak.take(3).toList();
    return Card(
      color: Brand.warning.withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.priority_high, color: Brand.warning),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(t.secWeakHeading,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
            ]),
            const SizedBox(height: Gap.sm),
            for (final id in top)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('•  '),
                    Expanded(
                      child: Text(secItemTitle(t, id),
                          style: TextStyle(color: cs.onSurface)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// --------------------------------------------------------------------------- //
// One checklist row: switch + title + expandable tip.
// --------------------------------------------------------------------------- //
class _SecItemTile extends StatelessWidget {
  const _SecItemTile({
    required this.item,
    required this.done,
    required this.onChanged,
    required this.t,
  });
  final SecItem item;
  final bool done;
  final ValueChanged<bool> onChanged;
  final AppLocalizations t;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Theme(
        data: Theme.of(context)
            .copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding:
              const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 2),
          childrenPadding:
              const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.md),
          leading: Icon(
            done ? Icons.check_circle : Icons.radio_button_unchecked,
            color: done ? Brand.success : cs.onSurfaceVariant,
          ),
          title: Text(secItemTitle(t, item.id),
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(
            done ? t.secMarkedDone : t.secTapToExpand,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          trailing: Switch(
            value: done,
            onChanged: onChanged,
          ),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(secItemTip(t, item.id),
                  style: Theme.of(context).textTheme.bodyMedium),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState(
      {required this.message, required this.onRetry, required this.t});
  final String message;
  final VoidCallback onRetry;
  final AppLocalizations t;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined,
                size: 48,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: Gap.md),
            Text(t.secLoadFailed, textAlign: TextAlign.center),
            const SizedBox(height: Gap.lg),
            FilledButton.tonal(onPressed: onRetry, child: Text(t.retry)),
          ],
        ),
      ),
    );
  }
}

// --------------------------------------------------------------------------- //
// Localised title + tip per item id. Kept here (not in the pure engine) so the
// engine stays string-free and deterministic; every string flows through ARB.
// --------------------------------------------------------------------------- //
String secItemTitle(AppLocalizations t, String id) {
  switch (id) {
    case 'screen_lock':
      return t.secItemScreenLock;
    case 'app_lock':
      return t.secItemAppLock;
    case 'wallet_pin':
      return t.secItemWalletPin;
    case 'two_factor':
      return t.secItemTwoFactor;
    case 'strong_passwords':
      return t.secItemStrongPasswords;
    case 'backup_enabled':
      return t.secItemBackup;
    case 'scam_awareness':
      return t.secItemScamAwareness;
    case 'permissions_review':
      return t.secItemPermissions;
    default:
      return id;
  }
}

String secItemTip(AppLocalizations t, String id) {
  switch (id) {
    case 'screen_lock':
      return t.secTipScreenLock;
    case 'app_lock':
      return t.secTipAppLock;
    case 'wallet_pin':
      return t.secTipWalletPin;
    case 'two_factor':
      return t.secTipTwoFactor;
    case 'strong_passwords':
      return t.secTipStrongPasswords;
    case 'backup_enabled':
      return t.secTipBackup;
    case 'scam_awareness':
      return t.secTipScamAwareness;
    case 'permissions_review':
      return t.secTipPermissions;
    default:
      return '';
  }
}
