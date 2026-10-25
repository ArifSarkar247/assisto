import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../messaging/chat_actions.dart';
import '../state.dart';
import '../theme.dart';
import 'chat_menu_pickers.dart' show showDisappearingPicker;

/// chat-actions — Settings ▸ Privacy ▸ "Default message timer": the
/// disappearing timer every NEW chat I start begins with (server-stored, so
/// the server applies it on the first message; existing chats never change).
class DefaultTimerRow extends StatefulWidget {
  /// Tests inject the client; the app reads it from [AppState].
  final ApiClient? api;
  const DefaultTimerRow({super.key, this.api});

  @override
  State<DefaultTimerRow> createState() => _DefaultTimerRowState();
}

class _DefaultTimerRowState extends State<DefaultTimerRow> {
  int? _sec; // null = not loaded yet
  bool _failed = false;

  ApiClient get _api => widget.api ?? context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final r = await _api.defaultTimer();
      if (mounted) {
        setState(() {
          _sec = (r['disappearing_sec'] as num?)?.toInt() ?? 0;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _pick() async {
    final t = AppLocalizations.of(context);
    final sec = await showDisappearingPicker(context, _sec ?? 0);
    if (sec == null || !mounted || sec == _sec) return;
    final prev = _sec;
    setState(() => _sec = sec);
    try {
      await _api.setDefaultTimer(sec);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.caDefaultTimerSaved)));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _sec = prev);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.grpActionFailed)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final sec = _sec;
    return ListTile(
      key: const Key('ca-default-timer'),
      leading: Icon(Icons.timer_outlined, color: scheme.onSurfaceVariant),
      title: Text(t.caDefaultTimer),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: Gap.xxs),
        child: Text(
          _failed
              ? t.grpActionFailed
              : sec == null
                  ? '…'
                  : '${t.caDefaultTimerSub(timerLabel(t, sec))}\n${t.caDefaultTimerHint}',
          style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
        ),
      ),
      isThreeLine: true,
      trailing: Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
      onTap: _failed ? _load : (sec == null ? null : _pick),
    );
  }
}
