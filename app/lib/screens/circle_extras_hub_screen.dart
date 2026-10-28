import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../state.dart';
import '../theme.dart';
import 'package:share_plus/share_plus.dart';
import '../l10n/app_localizations.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// Per-chat EXTRAS hub (M2 items 9 + 10). Opened from a chat's menu.
///
/// q1-seams (reality audit 22 Oct): only what REALLY works is offered here —
/// the server-enforced disappearing timer and a real on-device export through
/// the share sheet. Scheduled messages (no dispatcher ever sent them, and no
/// envelope was attached), broadcast (sent EMPTY envelopes), backup/restore
/// (claimed "done" without sealing or uploading anything), stickers/GIF (the
/// pick was dropped), wallpaper/theme and the view-once default (never read
/// by the chat) and "link a device" (no linking exists) are hidden behind one
/// honest "not available yet" note until each is wired for real.
///
/// The original M2 design gathered:
///   - Disappearing-messages timer (24h / 7d / 90d) + view-once toggle
///   - Per-chat wallpaper + theme (ON-DEVICE preference, persisted locally)
///   - Sticker + GIF picker entry
///   - Scheduled messages
///   - Broadcast list
///   - Encrypted chat backup + restore
///   - Export this chat
///   - Linked devices (item 10 — design)
///
/// Disappearing timer + wallpaper are the two settings that map to the
/// ChatSettings model (disappearing_sec, wallpaper, theme); the hub POSTs the
/// timer to the server (routing metadata, not content) and persists the
/// wallpaper/theme ON-DEVICE (SharedPreferences, keyed by chat id).
///
/// Backend seam (integrator wires — see MIGRATION NOTE):
///   GET  /circle/{peer}/settings  -> {disappearing_sec}
///   POST /circle/{peer}/settings  -> persist {disappearing_sec}
/// Wallpaper/theme are NOT uploaded here (on-device only).
class CircleExtrasHubScreen extends StatefulWidget {
  final Map<String, dynamic> member; // the peer chat
  /// Accepted circle members (for the broadcast picker). Optional.
  final List<Map<String, dynamic>> circleMembers;
  /// Already-decrypted messages for export (the chat screen passes its cache).
  final List<Map<String, dynamic>> Function()? decryptedMessages;
  /// Owner Tenor/GIPHY key if configured (else GIF picker shows gated state).
  final String? gifProviderKey;
  /// Whether the encrypted media bucket is live (user stickers / view-once media).
  final bool mediaBytesAvailable;
  const CircleExtrasHubScreen({
    super.key,
    required this.member,
    this.circleMembers = const [],
    this.decryptedMessages,
    this.gifProviderKey,
    this.mediaBytesAvailable = false,
  });

  @override
  State<CircleExtrasHubScreen> createState() => _CircleExtrasHubScreenState();
}

class _CircleExtrasHubScreenState extends State<CircleExtrasHubScreen> {
  // Disappearing timer choices mirror circle_extras DISAPPEAR_* (seconds).
  static const _off = 0;
  static const _d24h = 24 * 3600;
  static const _d7d = 7 * 24 * 3600;
  static const _d90d = 90 * 24 * 3600;

  int _disappearing = _off;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  ApiClient get _api => context.read<AppState>().api;
  int get _peer => widget.member['id'] as int;

  Future<void> _load() async {
    // Disappearing timer is server routing metadata (enforced server-side).
    try {
      final r = await _api.getJson('messenger/chat/$_peer/settings');
      final s = (r['disappearing_sec'] as num?)?.toInt() ?? 0;
      _disappearing = const [_off, _d24h, _d7d, _d90d].contains(s) ? s : _off;
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _saveDisappearing(int sec) async {
    final before = _disappearing;
    setState(() => _disappearing = sec);
    try {
      await _api.postJson('messenger/chat/$_peer/settings', {'disappearing_sec': sec});
    } catch (_) {
      // m3-circle: never silent — roll back and say so.
      if (mounted) {
        setState(() => _disappearing = before);
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).grpActionFailed)));
      }
    }
  }

  void _openTimerSheet(AppLocalizations t) {
    showAppSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final opt in [
              [_off, t.circleExtrasTimerOff],
              [_d24h, t.circleExtrasTimer24h],
              [_d7d, t.circleExtrasTimer7d],
              [_d90d, t.circleExtrasTimer90d],
            ])
              RadioListTile<int>(
                value: opt[0] as int,
                groupValue: _disappearing,
                title: Text(opt[1] as String),
                onChanged: (v) {
                  if (v != null) _saveDisappearing(v);
                  Navigator.of(context).maybePop();
                },
              ),
          ],
        ),
      ),
    );
  }

  /// Real export: the transcript is built ON-DEVICE from the chat's already
  /// decrypted messages and handed to the OS share sheet (q1-seams: this used
  /// to show "export ready" without sharing anything).
  Future<void> _exportChat(AppLocalizations t) async {
    final msgs = widget.decryptedMessages?.call() ?? const [];
    if (msgs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.q1ExtrasExportEmpty)));
      return;
    }
    final name = '${widget.member['name'] ?? ''}';
    final buf = StringBuffer()..writeln('Assisto — $name');
    for (final m in msgs) {
      final who = m['mine'] == true ? '→' : '←';
      buf.writeln('[${m['at'] ?? ''}] $who ${m['text'] ?? ''}');
    }
    try {
      await Share.share(buf.toString(), subject: t.circleExtrasExportChat);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(t.grpActionFailed)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.circleExtrasHubTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: Gap.xxl),
              children: [
                _header(t, scheme),

                // --- disappearing (server-enforced) ---
                _sectionHeader(t.circleExtrasDisappearing, scheme),
                ListTile(
                  leading: const Icon(Icons.timer_rounded),
                  title: Text(t.circleExtrasDisappearing),
                  subtitle: Text(t.circleExtrasDisappearingHint,
                      style: const TextStyle(fontSize: 12)),
                  trailing: Text(_timerLabel(t),
                      style: TextStyle(color: scheme.primary)),
                  onTap: () => _openTimerSheet(t),
                ),
                const Divider(),

                // --- export (on-device, real share sheet) ---
                ListTile(
                  key: const ValueKey('q1-extras-export'),
                  leading: const Icon(Icons.ios_share_rounded),
                  title: Text(t.circleExtrasExportChat),
                  subtitle: Text(t.circleExtrasExportHint,
                      style: const TextStyle(fontSize: 12)),
                  onTap: () => _exportChat(t),
                ),
                const Divider(),

                // NO SHOWPIECES: tools that don't work yet are simply not
                // listed (no "not available yet" row).

                Padding(
                  padding: const EdgeInsets.all(Gap.lg),
                  child: Row(
                    children: [
                      Icon(Icons.verified_user_rounded,
                          size: 16, color: scheme.primary),
                      const SizedBox(width: Gap.sm),
                      Expanded(
                        child: Text(t.circleExtrasE2eNote,
                            style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant,
                                height: 1.3)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  String _timerLabel(AppLocalizations t) {
    switch (_disappearing) {
      case _d24h:
        return t.circleExtrasTimer24h;
      case _d7d:
        return t.circleExtrasTimer7d;
      case _d90d:
        return t.circleExtrasTimer90d;
      default:
        return t.circleExtrasTimerOff;
    }
  }

  Widget _header(AppLocalizations t, ColorScheme scheme) => Container(
        margin: const EdgeInsets.all(Gap.lg),
        padding: const EdgeInsets.all(Gap.lg),
        decoration: BoxDecoration(
          gradient: Brand.gradient,
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        child: Row(
          children: [
            const Icon(Icons.tune_rounded, color: Colors.white),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Text(t.circleExtrasHubSubtitle,
                  style: const TextStyle(color: Colors.white, height: 1.35)),
            ),
          ],
        ),
      );

  Widget _sectionHeader(String text, ColorScheme scheme) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xs),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: scheme.primary)),
      );
}
