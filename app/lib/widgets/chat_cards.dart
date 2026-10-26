import '../feature_flags.dart' show FeatureFlags; // feature-flags
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../screens/nearby_screen.dart';
import '../services/action_feedback.dart'; // db1

/// THE single rich-card renderer shared by every chat surface (the HOME
/// [AgentThreadScreen] and the full-history [AiChatScreen]). Previously the
/// card/approval/action rendering lived privately inside the agent thread;
/// it now lives here so the AI Chat screen reuses the EXACT same bubbles
/// (music / navigate / call / nearby / alert / approval) instead of
/// duplicating them.
///
/// Rendered from the backend's `cards` list — each card is a `{type, ...}`
/// map. `onUndo` is invoked for undo-able alert cards (the agent thread wires
/// it to `api.deleteByModel` + local sync); pass null to hide the Undo action.
class ChatCard extends StatelessWidget {
  final Map<String, dynamic> card;

  /// Called when an undo-able card's Undo button is tapped. The card map is
  /// passed back so the caller can read `model` + `id`.
  final void Function(Map<String, dynamic> card)? onUndo;

  const ChatCard(this.card, {super.key, this.onUndo});

  Future<void> _launch(BuildContext context, String url,
      {bool external = true}) async {
    try {
      final ok = await launchUrl(Uri.parse(url),
          mode: external
              ? LaunchMode.externalApplication
              : LaunchMode.platformDefault);
      if (!ok) throw StateError('no app for $url'); // db1
    } catch (e) {
      // db1: tell the user instead of a silent dead tap.
      if (context.mounted) {
        showActionFailed(context, 'chatCard.launch', e, open: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final c = card;

    // m2-reality: an 'approval' card used to render Approve / Edit / Cancel
    // buttons wired to `() {}` (they did nothing). The backend never emits
    // this type today; if it ever does, show it as information only — never
    // buttons that pretend to act.
    if (c['type'] == 'approval') {
      return _actionCard(context, c, Icons.verified_user_rounded, const []);
    }
    if (c['type'] == 'music') {
      return _actionCard(context, c, Icons.music_note_rounded, [
        FilledButton.icon(
            onPressed: () => _launch(context, c['youtube'] ?? ''),
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: const Text('YouTube')),
        if (c['spotify'] != null)
          OutlinedButton(
              onPressed: () => _launch(context, c['spotify']),
              child: const Text('Spotify')),
      ]);
    }
    if (c['type'] == 'navigate') {
      return _actionCard(context, c, Icons.navigation_rounded, [
        FilledButton.icon(
            onPressed: () => _launch(context, c['maps'] ?? ''),
            icon: const Icon(Icons.map_rounded, size: 18),
            label: Text(t.open)),
      ]);
    }
    if (c['type'] == 'call') {
      final phone = (c['phone'] ?? '').toString();
      return _actionCard(context, c, Icons.call_rounded, [
        FilledButton.icon(
            onPressed:
                phone.isEmpty ? null : () => _launch(context, 'tel:$phone', external: false),
            icon: const Icon(Icons.call_rounded, size: 18),
            label: Text(t.call)),
      ]);
    }
    if (c['type'] == 'nearby') {
      return _actionCard(context, c, Icons.place_rounded, [
        if (FeatureFlags.instance.isOn('nearby')) // feature-flags
        FilledButton.icon(
            onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => NearbyScreen(
                        placeType: c['place_type'] ?? 'restaurant'))),
            icon: const Icon(Icons.search_rounded, size: 18),
            label: Text(t.open)),
      ]);
    }

    final isAlert = c['type'] == 'alert';
    final sev = c['severity'];
    final bg = isAlert
        ? (sev == 'high' ? scheme.errorContainer : scheme.tertiaryContainer)
        : scheme.surface;
    final fg = isAlert
        ? (sev == 'high' ? scheme.onErrorContainer : scheme.onTertiaryContainer)
        : scheme.onSurface;
    return Container(
      margin: const EdgeInsets.only(top: Gap.sm),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(c['title'] ?? '',
            style: TextStyle(fontWeight: FontWeight.w700, color: fg)),
        if ((c['subtitle'] ?? '').toString().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(c['subtitle'],
                style:
                    TextStyle(fontSize: 12, color: fg.withValues(alpha: 0.75))),
          ),
        if (c['undo'] == true && onUndo != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => onUndo!(c),
              icon: const Icon(Icons.undo_rounded, size: 16),
              label: Text(t.undo),
              // a11y1: no compact density — a text-only button, so the 48 dp
              // hit area is invisible padding.
            ),
          ),
      ]),
    );
  }

  Widget _actionCard(BuildContext context, Map<String, dynamic> c,
      IconData icon, List<Widget> actions) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: Gap.sm),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 18, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Expanded(
              child: Text(c['title'] ?? '',
                  style: const TextStyle(fontWeight: FontWeight.w700))),
        ]),
        if ((c['subtitle'] ?? '').toString().isNotEmpty)
          Padding(
              padding: const EdgeInsets.only(top: 2, left: 26),
              child: Text(c['subtitle'],
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant))),
        const SizedBox(height: Gap.sm),
        Wrap(spacing: Gap.sm, children: actions),
      ]),
    );
  }
}
