import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'msg_ticks.dart';

/// c3-msg — SWIPE TO REPLY. Received messages swipe RIGHT, my own swipe LEFT
/// (WhatsApp). Past [threshold] a reply icon fills in and the phone ticks once
/// (haptic); releasing there calls [onReply]. The bubble springs back.
class SwipeToReply extends StatefulWidget {
  final Widget child;
  final bool mine;
  final VoidCallback onReply;
  final bool enabled;
  final double threshold;
  const SwipeToReply({
    super.key,
    required this.child,
    required this.mine,
    required this.onReply,
    this.enabled = true,
    this.threshold = 64,
  });

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply>
    with SingleTickerProviderStateMixin {
  double _dx = 0;
  bool _armed = false;
  late final AnimationController _back = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 180))
    ..addListener(() => setState(() => _dx = _from * (1 - _back.value)));
  double _from = 0;

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  void _update(DragUpdateDetails d) {
    final dir = widget.mine ? -1.0 : 1.0;
    final next = (_dx + d.delta.dx);
    // only in the allowed direction, with resistance past the threshold
    final along = (next * dir).clamp(0.0, widget.threshold * 1.6);
    setState(() => _dx = along * dir);
    final armed = along >= widget.threshold;
    if (armed && !_armed) HapticFeedback.mediumImpact();
    _armed = armed;
  }

  void _end([DragEndDetails? _]) {
    if (_armed) widget.onReply();
    _armed = false;
    _from = _dx;
    _back.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final progress = (_dx.abs() / widget.threshold).clamp(0.0, 1.0);
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: _update,
      onHorizontalDragEnd: _end,
      onHorizontalDragCancel: _end,
      child: Stack(
        alignment: widget.mine ? Alignment.centerRight : Alignment.centerLeft,
        children: [
          Positioned.fill(
            child: Align(
              alignment:
                  widget.mine ? Alignment.centerRight : Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
                child: Opacity(
                  opacity: progress,
                  child: CircleAvatar(
                    radius: 15,
                    backgroundColor: scheme.primaryContainer,
                    child: Icon(Icons.reply,
                        size: 18, color: scheme.onPrimaryContainer),
                  ),
                ),
              ),
            ),
          ),
          Transform.translate(offset: Offset(_dx, 0), child: widget.child),
        ],
      ),
    );
  }
}

/// The six quick reactions (😂 ❤️ 👍 😮 😢 🙏) — emoji graphemes, not text.
const List<String> kC3QuickReactions = [
  '\u{1F602}',
  '\u{2764}\u{FE0F}',
  '\u{1F44D}',
  '\u{1F62E}',
  '\u{1F622}',
  '\u{1F64F}',
];

/// "+ more" reactions grid.
const List<String> kC3MoreReactions = [
  '\u{1F600}', '\u{1F601}', '\u{1F923}', '\u{1F60A}', '\u{1F60D}', '\u{1F618}',
  '\u{1F60E}', '\u{1F914}', '\u{1F644}', '\u{1F62D}', '\u{1F621}', '\u{1F631}',
  '\u{1F973}', '\u{1F44F}', '\u{1F64C}', '\u{1F4AA}', '\u{1F44C}', '\u{270C}\u{FE0F}',
  '\u{1F525}', '\u{1F389}', '\u{1F4AF}', '\u{2705}', '\u{1F339}', '\u{1F49A}',
  '\u{1F499}', '\u{1F49C}', '\u{1F494}', '\u{1F440}', '\u{1F91D}', '\u{1F64B}',
];

Future<String?> showMoreReactions(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.md),
        child: GridView.count(
          crossAxisCount: 6,
          shrinkWrap: true,
          children: [
            for (final e in kC3MoreReactions)
              InkResponse(
                onTap: () => Navigator.pop(ctx, e),
                child: Center(child: Text(e, style: const TextStyle(fontSize: 26))),
              ),
          ],
        ),
      ),
    ),
  );
}

/// Long-press "Info": per-recipient delivered / seen times (server truth,
/// seen hidden when read receipts are off on either side).
Future<void> showMessageInfoSheet(
    BuildContext context, Future<Map<String, dynamic>> Function() load) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => MessageInfoView(load: load),
  );
}

class MessageInfoView extends StatelessWidget {
  final Future<Map<String, dynamic>> Function() load;
  const MessageInfoView({super.key, required this.load});

  String _fmt(BuildContext context, String? iso) {
    final d = DateTime.tryParse(iso ?? '')?.toLocal();
    if (d == null) return '';
    final loc = Localizations.localeOf(context).languageCode == 'bn' ? 'bn' : 'en';
    final now = DateTime.now();
    final t = AppLocalizations.of(context);
    final time = DateFormat.Hm(loc).format(d);
    final days = DateTime(now.year, now.month, now.day)
        .difference(DateTime(d.year, d.month, d.day))
        .inDays;
    if (days <= 0) return t.c3InfoToday(time);
    if (days == 1) return t.c3InfoYesterday(time);
    return '${DateFormat.yMMMd(loc).format(d)}, $time';
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: FutureBuilder<Map<String, dynamic>>(
        future: load(),
        builder: (ctx, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const SizedBox(
                height: 160, child: Center(child: CircularProgressIndicator()));
          }
          if (snap.hasError || snap.data == null) {
            return Padding(
              padding: const EdgeInsets.all(Gap.xl),
              child: Text(t.grpActionFailed, textAlign: TextAlign.center),
            );
          }
          final d = snap.data!;
          final rows = ((d['recipients'] as List?) ?? const [])
              .whereType<Map>()
              .map((m) => m.cast<String, dynamic>())
              .toList();
          final group = d['group'] == true;
          final tick = tickFrom('${d['status'] ?? ''}');
          return ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.7),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
              children: [
                Row(children: [
                  Expanded(
                    child: Text(t.c3InfoTitle,
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  TickIcon(
                      tick: tick, baseColor: scheme.onSurfaceVariant, size: 18),
                ]),
                const SizedBox(height: Gap.sm),
                for (final r in rows) ...[
                  if (group)
                    Padding(
                      padding: const EdgeInsets.only(top: Gap.md),
                      child: Text('${r['name'] ?? ''}',
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  _line(
                      context,
                      Icons.done_all,
                      r['seen_at'] != null
                          ? readTickColor(context)
                          : scheme.onSurfaceVariant,
                      t.c3InfoRead,
                      r['seen_at'] != null
                          ? _fmt(context, '${r['seen_at']}')
                          // x2-ticks: the EFFECTIVE state, honestly —
                          // reciprocal, either side turned receipts off.
                          : (r['seen_hidden'] == true ||
                                  r['receipts_off'] == true ||
                                  d['my_read_receipts'] == false
                              ? t.c3InfoReadHidden
                              : t.c3InfoPending)),
                  _line(context, Icons.done_all, scheme.onSurfaceVariant,
                      t.c3InfoDelivered,
                      r['delivered_at'] != null
                          ? _fmt(context, '${r['delivered_at']}')
                          : t.c3InfoPending),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _line(BuildContext context, IconData icon, Color color, String label,
      String value) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Wrap(
              spacing: Gap.sm,
              children: [
                Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(value, style: TextStyle(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
