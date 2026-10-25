import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'notif_models.dart' show notifLocalizeDigits;

/// wa-polish: WhatsApp's round "scroll to latest" button for a REVERSED chat
/// list (offset 0 = the newest message). It appears once the user has
/// scrolled up more than [showAfter] px and shows how many messages from the
/// other side arrived since they scrolled away. Tap = smooth scroll to the
/// newest message. Self-contained: it watches [controller] itself and counts
/// [incomingIds] that were not there when the user scrolled away.
class ChatJumpToLatest extends StatefulWidget {
  const ChatJumpToLatest({
    super.key,
    required this.controller,
    required this.incomingIds,
    this.showAfter = 320,
  });

  final ScrollController controller;

  /// Ids of messages from the OTHER side currently in the chat.
  final Iterable<String> incomingIds;
  final double showAfter;

  @override
  State<ChatJumpToLatest> createState() => _ChatJumpToLatestState();
}

class _ChatJumpToLatestState extends State<ChatJumpToLatest> {
  bool _away = false;
  Set<String>? _seenWhenAway;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(ChatJumpToLatest old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onScroll);
      widget.controller.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    if (!widget.controller.hasClients) return;
    final away = widget.controller.position.pixels > widget.showAfter;
    if (away == _away) return;
    setState(() {
      _away = away;
      _seenWhenAway = away ? widget.incomingIds.toSet() : null;
    });
  }

  int get _newCount {
    final seen = _seenWhenAway;
    if (seen == null) return 0;
    return widget.incomingIds.where((id) => !seen.contains(id)).length;
  }

  Future<void> _jump() async {
    HapticFeedback.selectionClick();
    final c = widget.controller;
    if (!c.hasClients) return;
    // a long way up: jump most of it, animate the last screen (WhatsApp)
    final vp = c.position.viewportDimension;
    if (c.position.pixels > vp * 3) c.jumpTo(vp);
    await c.animateTo(0, duration: Motion.slow, curve: Motion.curve);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final n = _newCount;
    final label = n > 0
        ? t.waJumpToLatestNew(notifLocalizeDigits(context, '$n'))
        : t.waJumpToLatest;
    final badge = notifLocalizeDigits(context, n > 99 ? '99+' : '$n');
    return IgnorePointer(
      ignoring: !_away,
      child: AnimatedOpacity(
        opacity: _away ? 1 : 0,
        duration: Motion.fast,
        child: Semantics(
          button: true,
          label: label,
          excludeSemantics: true,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.topCenter,
            children: [
              Material(
                key: const Key('wa-jump-latest'),
                color: scheme.surfaceContainerHigh,
                shape: const CircleBorder(),
                elevation: 3,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _jump,
                  child: SizedBox(
                    width: kMinInteractiveDimension,
                    height: kMinInteractiveDimension,
                    child: Icon(Icons.keyboard_double_arrow_down_rounded,
                        color: scheme.onSurface),
                  ),
                ),
              ),
              if (n > 0)
                Positioned(
                  top: -Gap.sm,
                  child: Container(
                    key: const Key('wa-jump-latest-count'),
                    constraints: const BoxConstraints(minWidth: 22),
                    padding: const EdgeInsets.symmetric(
                        horizontal: Gap.xs + 2, vertical: 1),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(Radii.pill),
                    ),
                    child: Text(badge,
                        textAlign: TextAlign.center,
                        style: AType.labelSmall.copyWith(
                            color: scheme.onPrimary,
                            fontWeight: FontWeight.w700)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
