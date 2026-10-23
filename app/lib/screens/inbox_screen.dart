import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../widgets/inbox_mock.dart';
import '../widgets/inbox_item_card.dart';
import '../widgets/inbox_filter_bar.dart';
import '../widgets/inbox_reply_sheet.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// AI Inbox (feature 22, SPEC v2.1 section 21 ADVANCED) - a unified SMART INBOX over
/// email / notifications / messages with deterministic AI triage
/// (urgent/action/FYI/promo), per-item summary + suggested quick replies
/// (MOCK), priority sort, "needs reply" view, category/source filters, snooze,
/// mark-done, convert-to-task/reminder and bulk actions.
///
/// Connecting a REAL email account (Gmail/IMAP) is key-gated; until the owner
/// connects one in Integrations the list runs on MOCK items with a clear,
/// honest "connect account" banner. Triage mirrors backend
/// `core.logic.ai_inbox` (no real AI, no network).
class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key});
  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  Map<String, dynamic>? _s;
  bool _loading = true;
  bool _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

  List<InboxItem> _items = [];
  InboxFilter _filter = const InboxFilter();
  bool _selectMode = false;
  final Set<String> _selected = {};

  bool get _connected => _s?['connected'] == true;

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
      _s = await context.read<AppState>().api.inboxStatus();
      // m2-reality: this used to fill the inbox with MOCK emails (e.g. a fake
      // "bKash: payment failed") for every real user. Never show fake mail:
      // with no connected account the list is empty and the screen says
      // honestly what to connect. (Live fetch arrives with the mail key.)
      final now = DateTime.now();
      _items = <InboxItem>[];
      triage(_items, now);
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  // ---- derived lists -------------------------------------------------------
  List<InboxItem> get _visible {
    final now = DateTime.now();
    var list = activeItems(_items, now);
    if (_filter.needsReplyOnly) list = list.where((i) => i.needsReply).toList();
    if (_filter.category != null) {
      list = list.where((i) => i.category == _filter.category).toList();
    }
    if (_filter.source != null) {
      list = list.where((i) => i.source == _filter.source).toList();
    }
    return sortByPriority(list);
  }

  Map<InboxCategory, int> get _counts {
    final now = DateTime.now();
    final active = activeItems(_items, now);
    return {
      for (final c in InboxCategory.values)
        c: active.where((i) => i.category == c).length,
    };
  }

  int get _needsReplyCount =>
      activeItems(_items, DateTime.now()).where((i) => i.needsReply).length;

  // ---- actions -------------------------------------------------------------
  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _reply(InboxItem it) async {
    final tr = AppLocalizations.of(context);
    final chosen = await InboxReplySheet.show(context, it, _connected);
    if (chosen != null) _toast(tr.inboxReplyDraftReady);
  }

  Future<void> _snooze(InboxItem it) async {
    final tr = AppLocalizations.of(context);
    final hours = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(tr.inboxSnooze1h), leading: const Icon(Icons.snooze),
              onTap: () => Navigator.pop(context, 1)),
          ListTile(title: Text(tr.inboxSnooze3h), leading: const Icon(Icons.snooze),
              onTap: () => Navigator.pop(context, 3)),
          ListTile(title: Text(tr.inboxSnooze1d), leading: const Icon(Icons.snooze),
              onTap: () => Navigator.pop(context, 24)),
          ListTile(title: Text(tr.inboxSnooze3d), leading: const Icon(Icons.snooze),
              onTap: () => Navigator.pop(context, 72)),
        ]),
      ),
    );
    if (hours == null) return;
    setState(() => it.snoozedUntil = DateTime.now().add(Duration(hours: hours)));
    _toast(tr.inboxSnoozedToast);
  }

  void _markDone(InboxItem it) {
    final tr = AppLocalizations.of(context);
    setState(() => it.done = true);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(tr.inboxMarkedDone),
      action: SnackBarAction(
        label: tr.inboxUndo,
        onPressed: () => setState(() => it.done = false),
      ),
    ));
  }

  void _convertTask(InboxItem it) => _toast(AppLocalizations.of(context).inboxTaskCreated);
  void _convertReminder(InboxItem it) =>
      _toast(AppLocalizations.of(context).inboxReminderCreated);

  void _bulk(bool done) {
    final tr = AppLocalizations.of(context);
    setState(() {
      for (final it in _items) {
        if (_selected.contains(it.id)) {
          if (done) {
            it.done = true;
          } else {
            it.snoozedUntil = DateTime.now().add(const Duration(hours: 24));
          }
        }
      }
      _selected.clear();
      _selectMode = false;
    });
    _toast(done ? tr.inboxBulkDone : tr.inboxBulkSnoozed);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(_selectMode
            ? tr.inboxSelectedCount(_selected.length)
            : tr.aiInbox),
        actions: [
          if (!_loading && !_error)
            IconButton(
              tooltip: _selectMode ? tr.inboxCancelSelect : tr.inboxSelect,
              icon: Icon(_selectMode ? Icons.close : Icons.checklist),
              onPressed: () => setState(() {
                _selectMode = !_selectMode;
                _selected.clear();
              }),
            ),
        ],
      ),
      bottomNavigationBar: (_selectMode && _selected.isNotEmpty)
          ? _BulkBar(tr: tr, onDone: () => _bulk(true), onSnooze: () => _bulk(false))
          : null,
      body: _loading
          ? const SkeletonList()
          : _error
              ? _ErrorState(tr: tr, error: _failCause, onRetry: _load)
              : _body(tr, scheme),
    );
  }

  Widget _body(AppLocalizations tr, ColorScheme scheme) {
    final visible = _visible;
    return RefreshIndicator(
      onRefresh: _load,
      child: Column(children: [
        // Honest account state: mock now, real email is key-gated.
        _ConnectBanner(connected: _connected, tr: tr, scheme: scheme),
        InboxFilterBar(
          filter: _filter,
          counts: _counts,
          needsReplyCount: _needsReplyCount,
          onChanged: (f) => setState(() => _filter = f),
        ),
        const Divider(height: 1),
        Expanded(
          child: visible.isEmpty
              ? _EmptyState(tr: tr, connected: _connected, filtered: _filter.category != null ||
                  _filter.source != null || _filter.needsReplyOnly)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xl),
                  children: [
                    for (final it in visible)
                      // Superhuman-style swipe triage: swipe right = Done,
                      // swipe left = Snooze. Both call the SAME handlers as the
                      // existing icon buttons (which are kept). Backgrounds
                      // reuse the inbox action colours/icons/labels — no new ARB
                      // keys (tr.inboxMarkDone / tr.inboxSnooze). Swiping is
                      // disabled in select mode so bulk selection isn't fought.
                      Dismissible(
                        key: ValueKey(it.id),
                        direction: _selectMode
                            ? DismissDirection.none
                            : DismissDirection.horizontal,
                        background: _SwipeBg(
                          align: Alignment.centerLeft,
                          color: Brand.success,
                          icon: Icons.check_circle_outline,
                          label: tr.inboxMarkDone,
                        ),
                        secondaryBackground: _SwipeBg(
                          align: Alignment.centerRight,
                          color: Brand.warning,
                          icon: Icons.snooze,
                          label: tr.inboxSnooze,
                        ),
                        // Done is synchronous (with undo) so we confirm the
                        // dismissal; Snooze opens a sheet that can be cancelled,
                        // so we never confirm the dismissal — we run the handler
                        // and keep the card (its snoozed state hides it on the
                        // next build). The card itself is never structurally
                        // removed here; _visible re-derives from item state.
                        confirmDismiss: (dir) async {
                          if (dir == DismissDirection.startToEnd) {
                            _markDone(it);
                          } else {
                            await _snooze(it);
                          }
                          return false;
                        },
                        child: InboxItemCard(
                          item: it,
                          selectMode: _selectMode,
                          selected: _selected.contains(it.id),
                          onToggleSelect: () => setState(() {
                            _selected.contains(it.id)
                                ? _selected.remove(it.id)
                                : _selected.add(it.id);
                          }),
                          onReply: () => _reply(it),
                          onSnooze: () => _snooze(it),
                          onDone: () => _markDone(it),
                          onTask: () => _convertTask(it),
                          onReminder: () => _convertReminder(it),
                        ),
                      ),
                  ],
                ),
        ),
      ]),
    );
  }
}

/// Swipe-reveal background for the inbox Dismissible: a tinted panel with an
/// icon + label, mirroring the icon-button action it triggers. Used for both
/// Done (lead) and Snooze (trailing) by varying alignment/colour/icon/label.
class _SwipeBg extends StatelessWidget {
  final Alignment align;
  final Color color;
  final IconData icon;
  final String label;
  const _SwipeBg({
    required this.align,
    required this.color,
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final lead = align == Alignment.centerLeft;
    return Container(
      margin: const EdgeInsets.only(bottom: Gap.md),
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
      alignment: align,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (lead) ...[
            Icon(icon, color: color),
            const SizedBox(width: Gap.sm),
          ],
          Text(label,
              style: TextStyle(color: color, fontWeight: FontWeight.w700)),
          if (!lead) ...[
            const SizedBox(width: Gap.sm),
            Icon(icon, color: color),
          ],
        ],
      ),
    );
  }
}

class _ConnectBanner extends StatelessWidget {
  final bool connected;
  final AppLocalizations tr;
  final ColorScheme scheme;
  const _ConnectBanner({required this.connected, required this.tr, required this.scheme});

  @override
  Widget build(BuildContext context) {
    final color = connected ? scheme.secondaryContainer : scheme.tertiaryContainer;
    final onColor = connected ? scheme.onSecondaryContainer : scheme.onTertiaryContainer;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 0),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(Radii.md)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(connected ? Icons.mark_email_read_outlined : Icons.link,
            size: 20, color: onColor),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(
            connected ? tr.inboxConnectedLive : tr.realityInboxConnectNeeded,
            style: TextStyle(fontSize: 12.5, color: onColor),
          ),
        ),
      ]),
    );
  }
}

class _BulkBar extends StatelessWidget {
  final AppLocalizations tr;
  final VoidCallback onDone, onSnooze;
  const _BulkBar({required this.tr, required this.onDone, required this.onSnooze});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.snooze),
              label: Text(tr.inboxSnooze),
              onPressed: onSnooze,
            ),
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: FilledButton.icon(
              icon: const Icon(Icons.check_circle_outline),
              label: Text(tr.inboxMarkDone),
              onPressed: onDone,
            ),
          ),
        ]),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final AppLocalizations tr;
  final bool filtered;
  final bool connected;
  const _EmptyState({required this.tr, required this.filtered, this.connected = true});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(filtered ? Icons.filter_alt_off : Icons.inbox_outlined,
              size: 56, color: scheme.onSurfaceVariant),
          const SizedBox(height: Gap.md),
          Text(filtered ? tr.inboxNoneInFilter
              : (connected ? tr.inboxAllClear : tr.realityInboxNotConnectedTitle),
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: Gap.sm),
          Text(filtered ? tr.inboxTryAnotherFilter
              : (connected ? tr.inboxAllClearHint : tr.realityInboxNotConnectedHint),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final AppLocalizations tr;
  final VoidCallback onRetry;
  final Object? error; // qa2: a 5xx is our server, not the internet
  const _ErrorState({required this.tr, required this.onRetry, this.error});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.cloud_off, size: 56, color: scheme.error),
          const SizedBox(height: Gap.md),
          Text(tr.inboxLoadFailed,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: Gap.sm),
          Text(honestFailText(tr, error, otherwise: tr.checkInternetRetry),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.lg),
          FilledButton.icon(
            icon: const Icon(Icons.refresh),
            label: Text(tr.retry),
            onPressed: onRetry,
          ),
        ]),
      ),
    );
  }
}
