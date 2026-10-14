import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../home_api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import 'skeleton.dart';

/// Dynamic prompt cards for the HOME chat screen.
///
/// The 4 cards come from the backend rule-engine (GET /home/suggestions?lang=),
/// ranked, in the ACTIVE language only. They are NEVER hard-coded. Tapping a
/// card runs its prompt (via [onRun]). Long-pressing offers "Don't show this"
/// → POST /home/suggestions/dismiss {key} then refresh. A small refresh icon
/// fetches a fresh set. The last good set is cached for offline.
class HomeSuggestions extends StatefulWidget {
  /// Runs a tapped suggestion (route navigation or send-to-agent) — wired by
  /// the home screen so the prompt flows through the normal chat pipeline.
  final void Function(HomeSuggestion s) onRun;

  /// Exposes the loader so the host can refresh on focus/resume.
  final void Function(Future<void> Function() refresh)? onReady;

  const HomeSuggestions({super.key, required this.onRun, this.onReady});

  @override
  State<HomeSuggestions> createState() => _HomeSuggestionsState();
}

class _HomeSuggestionsState extends State<HomeSuggestions> {
  static const _cacheKey = 'home_suggestions_cache';

  List<HomeSuggestion> _items = const [];
  bool _loading = true;
  bool _error = false;
  bool _fromCache = false;

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    widget.onReady?.call(load);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreCache();
      load();
    });
  }

  String get _lang {
    final app = context.read<AppState>();
    return app.locale?.languageCode ?? app.api.lang ?? 'bn';
  }

  Future<void> _restoreCache() async {
    final raw = await Settings.getString(_cacheKey);
    if (raw == null || raw.isEmpty || !mounted) return;
    try {
      final list = (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((m) => HomeSuggestion.fromJson(m.cast<String, dynamic>()))
          .toList();
      if (list.isNotEmpty && _items.isEmpty) {
        setState(() {
          _items = list;
          _fromCache = true;
          _loading = false;
        });
      }
    } catch (_) {/* ignore corrupt cache */}
  }

  Future<void> load() async {
    if (!mounted) return;
    final app = context.read<AppState>();
    setState(() {
      _loading = _items.isEmpty; // keep showing old set while refreshing
      _error = false;
    });
    try {
      final items = await app.api.homeSuggestions(_lang);
      if (!mounted) return;
      setState(() {
        _items = items;
        _fromCache = false;
        _loading = false;
      });
      await Settings.setString(
          _cacheKey, jsonEncode(items.map((e) => e.toCache()).toList()));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // only a hard error when we have nothing to show
        _error = _items.isEmpty;
      });
    }
  }

  Future<void> _dismiss(HomeSuggestion s) async {
    final app = context.read<AppState>();
    try {
      await app.api.homeSuggestionDismiss(s.key);
    } catch (_) {/* best-effort; refresh anyway */}
    if (mounted) await load();
  }

  Future<void> _onLongPress(HomeSuggestion s) async {
    final yes = await showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          ListTile(
            leading: const Icon(Icons.visibility_off_outlined),
            title: Text(t.homeDontShow),
            onTap: () => Navigator.pop(ctx, true),
          ),
        ]),
      ),
    );
    if (yes == true) await _dismiss(s);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // header row: label + refresh
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.xs, 0, 0, Gap.sm),
          child: Row(children: [
            Expanded(
              child: Text(
                t.homeSuggestionsTitle,
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ),
            IconButton(
              tooltip: t.homeRefreshSuggestions,
              visualDensity: VisualDensity.compact,
              onPressed: _loading ? null : load,
              icon: Icon(Icons.refresh, size: 20, color: scheme.primary),
            ),
          ]),
        ),
        _body(),
      ],
    );
  }

  Widget _body() {
    if (_loading && _items.isEmpty) return const _LoadingCards();
    if (_error && _items.isEmpty) {
      return StateMessage(
        icon: Icons.cloud_off_outlined,
        title: t.homeSuggestionsError,
        action: TextButton.icon(
          onPressed: load,
          icon: const Icon(Icons.refresh, size: 18),
          label: Text(t.homeRetry),
        ),
      );
    }
    if (_items.isEmpty) {
      return StateMessage(
        icon: Icons.lightbulb_outline,
        title: t.homeSuggestionsEmpty,
      );
    }
    return Column(
      children: [
        for (final s in _items) ...[
          _Card(
            suggestion: s,
            onTap: () => widget.onRun(s),
            onLongPress: () => _onLongPress(s),
          ),
          const SizedBox(height: Gap.sm),
        ],
      ],
    );
  }
}

class _Card extends StatelessWidget {
  final HomeSuggestion suggestion;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  const _Card({
    required this.suggestion,
    required this.onTap,
    required this.onLongPress,
  });

  // Map an engine icon hint to a Material icon (default: a chat spark).
  IconData get _icon {
    switch (suggestion.icon) {
      case 'today':
      case 'sun':
        return Icons.wb_sunny_outlined;
      case 'money':
      case 'spend':
        return Icons.query_stats_outlined;
      case 'expense':
      case 'receipt':
        return Icons.receipt_long_outlined;
      case 'medicine':
      case 'health':
        return Icons.medication_outlined;
      case 'reminder':
        return Icons.alarm_outlined;
      case 'circle':
        return Icons.diversity_3_outlined;
      default:
        return Icons.auto_awesome_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final route = suggestion.route != null;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(Radii.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Row(children: [
            Icon(_icon, size: 22, color: scheme.primary),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Text(suggestion.text,
                  style: const TextStyle(fontWeight: FontWeight.w500)),
            ),
            Icon(route ? Icons.north_east : Icons.send_outlined,
                size: 16, color: scheme.onSurfaceVariant),
          ]),
        ),
      ),
    );
  }
}

class _LoadingCards extends StatelessWidget {
  const _LoadingCards();
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (var i = 0; i < 4; i++) ...[
          Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            padding: const EdgeInsets.all(Gap.lg),
            child: Row(children: const [
              Skeleton(width: 22, height: 22, radius: 6),
              SizedBox(width: Gap.md),
              Expanded(child: Skeleton(height: 13)),
            ]),
          ),
          const SizedBox(height: Gap.sm),
        ],
      ],
    );
  }
}
