import 'package:flutter/material.dart';

import '../calls/ring_checklist.dart';
import '../l10n/app_localizations.dart';
import '../services/oem_guide.dart';
import '../theme.dart';
import 'battery_guidance_screen.dart' show oemStepBody, oemStepTitle;

/// ring-everywhere: "Calls ring setup" — the checklist (logic in
/// calls/ring_checklist.dart). Shown once after login when something is
/// missing ([firstRun]) and always from Settings. Every row: status (OK /
/// Missing / Check) + one Fix button; steps Android can't verify get an
/// "I've done it" tick after opening them. Re-checks on return from Settings.
class RingChecklistScreen extends StatefulWidget {
  const RingChecklistScreen({super.key, this.firstRun = false, this.native});

  final bool firstRun;

  /// Tests / gallery pass a fake.
  final RingCheckNative? native;

  @override
  State<RingChecklistScreen> createState() => _RingChecklistScreenState();
}

class _RingChecklistScreenState extends State<RingChecklistScreen>
    with WidgetsBindingObserver {
  RingCheckNative get _native => widget.native ?? RingChecklist.native;
  RingFacts? _facts;
  bool _loading = true;
  final Map<String, OemOpen> _opened = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final f = await RingChecklist.facts(using: _native);
    if (!mounted) return;
    final rows = ringCheckRows(f);
    RingChecklist.attention.value = ringNeedsAttention(rows);
    setState(() {
      _facts = f;
      _loading = false;
    });
  }

  Future<void> _fix(RingCheckRow r) async {
    switch (r.id) {
      case RingCheckId.notifications:
        await _native.fixNotifications();
      case RingCheckId.callChannel:
        await _native.fixCallChannel();
      case RingCheckId.fullScreen:
        await _native.fixFullScreen();
      case RingCheckId.oemStep:
        final step = r.step?.nativeStep ?? 'app_details';
        final res = await _native.openOemStep(step);
        if (mounted) setState(() => _opened[r.key] = res);
    }
    await _load();
  }

  Future<void> _confirm(RingCheckRow r, bool on) async {
    await RingChecklist.setConfirmed(r.key, on);
    await _load();
  }

  String _title(AppLocalizations t, RingCheckRow r, OemFamily fam) =>
      switch (r.id) {
        RingCheckId.notifications => t.ringCheckNotifTitle,
        RingCheckId.callChannel => t.ringCheckChannelTitle,
        RingCheckId.fullScreen => t.ringCheckFsiTitle,
        RingCheckId.oemStep => oemStepTitle(t, r.step!, fam),
      };

  String _body(AppLocalizations t, RingCheckRow r, OemFamily fam) =>
      switch (r.id) {
        RingCheckId.notifications => t.ringCheckNotifBody,
        RingCheckId.callChannel => t.ringCheckChannelBody,
        RingCheckId.fullScreen => t.ringCheckFsiBody,
        RingCheckId.oemStep => oemStepBody(t, r.step!, fam),
      };

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final f = _facts;
    final fam = f?.oem?.family ?? OemFamily.nearStock;
    final rows = f == null ? const <RingCheckRow>[] : ringCheckRows(f);
    final allOk = f != null && !ringNeedsAttention(rows);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.ringCheckTitle),
        automaticallyImplyLeading: !widget.firstRun,
      ),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(Gap.lg), children: [
          Card(
            color: allOk ? scheme.primaryContainer : scheme.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(allOk ? Icons.check_circle : Icons.ring_volume_rounded,
                    color: allOk
                        ? scheme.onPrimaryContainer
                        : scheme.onTertiaryContainer),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Text(
                    key: const Key('ring-check-summary'),
                    allOk ? t.ringCheckAllOk : t.ringCheckIntro,
                    style: TextStyle(
                        color: allOk
                            ? scheme.onPrimaryContainer
                            : scheme.onTertiaryContainer),
                  ),
                ),
              ]),
            ),
          ),
          if ((f?.oem?.label ?? '').isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Text(f!.oem!.label,
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurfaceVariant)),
          ],
          const SizedBox(height: Gap.md),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(Gap.xl),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            for (final r in rows)
              _RowCard(
                key: Key('ring-row-${r.key}'),
                row: r,
                title: _title(t, r, fam),
                body: _body(t, r, fam),
                opened: _opened[r.key],
                onFix: () => _fix(r),
                onConfirm: (on) => _confirm(r, on),
              ),
          const SizedBox(height: Gap.sm),
          Text(t.ringCheckFooter,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          if (widget.firstRun) ...[
            const SizedBox(height: Gap.lg),
            FilledButton(
              key: const Key('ring-check-done'),
              onPressed: () => Navigator.of(context).maybePop(),
              child: Text(t.done),
            ),
            const SizedBox(height: Gap.xs),
            TextButton(
              key: const Key('ring-check-later'),
              onPressed: () => Navigator.of(context).maybePop(),
              child: Text(t.ringCheckLater),
            ),
          ],
        ]),
      ),
    );
  }
}

class _RowCard extends StatelessWidget {
  const _RowCard({
    super.key,
    required this.row,
    required this.title,
    required this.body,
    required this.opened,
    required this.onFix,
    required this.onConfirm,
  });
  final RingCheckRow row;
  final String title;
  final String body;
  final OemOpen? opened;
  final VoidCallback onFix;
  final ValueChanged<bool> onConfirm;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final note = TextStyle(fontSize: 13, color: scheme.onSurfaceVariant);
    final (IconData icon, Color color, String label) = switch (row.state) {
      RingCheckState.ok => (Icons.check_circle, scheme.primary, t.ringCheckStatusOk),
      RingCheckState.missing => (Icons.error, scheme.error, t.ringCheckStatusMissing),
      RingCheckState.check => (Icons.help, scheme.tertiary, t.ringCheckStatusCheck),
    };
    // a confirmed by-hand step keeps its "Not done" undo
    final confirmable = row.id == RingCheckId.oemStep &&
        row.step != null &&
        !row.step!.checkable;
    final byHandOnly = row.step != null && row.step!.nativeStep == null;
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ExcludeSemantics(child: Icon(icon, color: color, size: 28)),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              const SizedBox(height: Gap.xs),
              Text(label,
                  key: Key('ring-state-${row.key}'),
                  style: TextStyle(color: color, fontWeight: FontWeight.w700)),
              if (row.state != RingCheckState.ok) ...[
                const SizedBox(height: Gap.xs),
                Text(body),
                if (row.state == RingCheckState.check) ...[
                  const SizedBox(height: Gap.xs),
                  Text(byHandOnly ? t.ringCheckByHand : t.ringCheckManualHint,
                      style: note),
                ],
                if (opened == OemOpen.details) ...[
                  const SizedBox(height: Gap.xs),
                  Text(t.oemGuideOpenedDetails, style: note),
                ],
                if (opened == OemOpen.none) ...[
                  const SizedBox(height: Gap.xs),
                  Text(t.oemGuideNoScreen, style: note),
                ],
                const SizedBox(height: Gap.sm),
                Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
                  if (!byHandOnly)
                    FilledButton.tonalIcon(
                      key: Key('ring-fix-${row.key}'),
                      onPressed: onFix,
                      icon: const Icon(Icons.build_rounded, size: 18),
                      label: Text(t.ringCheckFix),
                    ),
                  if (confirmable)
                    OutlinedButton.icon(
                      key: Key('ring-confirm-${row.key}'),
                      onPressed: () => onConfirm(true),
                      icon: const Icon(Icons.check, size: 18),
                      label: Text(t.ringCheckMarkDone),
                    ),
                ]),
              ] else if (confirmable) ...[
                const SizedBox(height: Gap.xs),
                TextButton(
                  key: Key('ring-undo-${row.key}'),
                  onPressed: () => onConfirm(false),
                  child: Text(t.ringCheckUndo),
                ),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

/// My Circle: a small banner while something is missing (snooze 7 days).
class RingCheckBanner extends StatefulWidget {
  const RingCheckBanner({super.key});

  @override
  State<RingCheckBanner> createState() => _RingCheckBannerState();
}

class _RingCheckBannerState extends State<RingCheckBanner> {
  bool _allowed = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final ok = await RingChecklist.bannerAllowed();
    if (!ok) return;
    await RingChecklist.refresh();
    if (mounted) setState(() => _allowed = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_allowed) return const SizedBox.shrink();
    return ValueListenableBuilder<bool>(
      valueListenable: RingChecklist.attention,
      builder: (context, need, _) {
        if (!need) return const SizedBox.shrink();
        final t = AppLocalizations.of(context);
        final scheme = Theme.of(context).colorScheme;
        return Card(
          key: const Key('ring-check-banner'),
          margin: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.xs),
          color: scheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, Gap.xs),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.notifications_off_rounded,
                    color: scheme.onErrorContainer, size: 20),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(t.ringCheckBanner,
                      style: TextStyle(color: scheme.onErrorContainer)),
                ),
              ]),
              Wrap(alignment: WrapAlignment.end, spacing: Gap.xs, children: [
                TextButton(
                  key: const Key('ring-banner-later'),
                  onPressed: () async {
                    await RingChecklist.snoozeBanner();
                    if (mounted) setState(() => _allowed = false);
                  },
                  child: Text(t.ringCheckLater,
                      style: TextStyle(color: scheme.onErrorContainer)),
                ),
                FilledButton(
                  key: const Key('ring-banner-fix'),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const RingChecklistScreen())),
                  child: Text(t.ringCheckBannerFix),
                ),
              ]),
            ]),
          ),
        );
      },
    );
  }
}

/// A warning dot on an icon while [RingChecklist.attention] is true
/// (drawer Settings entry, Settings tile).
class RingCheckBadge extends StatelessWidget {
  const RingCheckBadge({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: RingChecklist.attention,
      builder: (context, need, c) => need
          ? Badge(
              key: const Key('ring-check-badge'),
              label: Semantics(
                  label: AppLocalizations.of(context).ringCheckBadge,
                  child: const Text('!')),
              child: c,
            )
          : c!,
      child: child,
    );
  }
}
