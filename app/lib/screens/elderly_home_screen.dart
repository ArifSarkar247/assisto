import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../state.dart';
import '../feature_gates.dart' show kMedicalFeaturesAllowed;
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/chatnav.dart';
import '../widgets/elderly_mode.dart';
import '../widgets/elderly_tile.dart';
import '../widgets/skeleton.dart';
import '../widgets/voice_command_sheet.dart';
import 'package:assisto/widgets/app_sheet.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// SPEC v2.1 feature 29 — ELDERLY SIMPLE-MODE home.
///
/// A deliberately minimal launcher for elderly Bangladeshi users, benchmarked
/// against the best senior/accessibility launchers (Big Launcher, GrandPad,
/// Jitterbug, Google's "Simple" mode):
///
///   * VERY large text + high contrast (WCAG AAA): body glyphs >= 24sp, solid
///     dark tiles with white text (>= 7:1), a thick white border per tile.
///   * FEW essential actions only: Call family, My medicines, Emergency/SOS,
///     Messages, Money, Help. No clutter, no nested menus, minimal depth.
///   * VOICE-FIRST: a big always-visible microphone (reuses the on-device
///     voice-command sheet -> same routing as chat).
///   * BIG one-tap "Call [family member]" buttons (reuse emergency/circle
///     contacts). A LARGE back button is present on every pushed screen (the
///     reused screens carry their own AppBar back; this home itself is the root
///     of simple mode and offers an explicit, confirmed EXIT instead).
///   * EMERGENCY/SOS is one tap, always on screen, in alarm red.
///   * Confirmations on anything disruptive (placing a call, leaving simple
///     mode). Destructive/irreversible actions are gated.
///
/// SPEC §21 (all 10): empty / loading (skeleton) / error (retry) states,
/// OFFLINE fallback (last-known contacts/meds, a clear offline banner),
/// BILINGUAL (every string via AppLocalizations), WCAG AAA sizes/contrast,
/// large >=56dp touch targets, and the real elderly scenario (a senior taps
/// one tile to call their child / take a medicine / hit SOS). Zero Bangla
/// literals in this file (language gate).
class ElderlyHomeScreen extends StatefulWidget {
  /// Called when the user confirms EXIT simple mode, so the router can rebuild
  /// and send them back to the normal chat home.
  final VoidCallback? onExit;
  const ElderlyHomeScreen({super.key, this.onExit});

  @override
  State<ElderlyHomeScreen> createState() => _ElderlyHomeScreenState();
}

class _ElderlyHomeScreenState extends State<ElderlyHomeScreen>
    with WidgetsBindingObserver {
  bool _loading = true;
  bool _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  bool _offline = false;

  List<Map<String, dynamic>> _contacts = const [];
  int _medsDueToday = 0;

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
    // Same foreground-refresh pattern as the rest of the app.
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    setState(() {
      _error = false;
    });
    try {
      final c = await app.api.getEmergency();
      _contacts = ((c['contacts'] ?? []) as List)
          .cast<Map<String, dynamic>>()
          .where((e) => '${e['phone'] ?? ''}'.trim().isNotEmpty)
          .toList();
      if (kMedicalFeaturesAllowed) {
        try {
          final meds = await app.api.medicinesToday();
          _medsDueToday = meds
              .where((m) => m['taken'] != true && m['skipped'] != true)
              .length;
        } catch (_) {
          _medsDueToday = 0;
        }
      }
      _offline = false;
    } catch (e) {
      // Keep last-known contacts; show a clear offline/error banner. If we have
      // nothing cached this is a hard error with a retry.
      if (_contacts.isEmpty) {
        _error = true;
        _failCause = e;
      } else {
        _offline = true;
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  AppLocalizations get _t => AppLocalizations.of(context);

  // ---- actions --------------------------------------------------------------

  Future<void> _call(String phone, String who) async {
    final t = _t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        icon: const Icon(Icons.call_rounded, color: Brand.success, size: 32),
        title: Text(t.elderlyCallConfirmTitle(who),
            style: AType.headlineSmall),
        content:
            Text(t.elderlyCallConfirmBody(who), style: AType.titleLarge),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cancel, style: AType.titleLarge)),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.call_rounded),
            label: Text(t.elderlyCallNow, style: AType.titleLarge),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final uri = Uri.parse('tel:$phone');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  void _open(String route) => ChatNav.push(context, route);

  Future<void> _voice() async {
    final text = await showVoiceCommandSheet(context);
    if (text == null || !mounted) return;
    // Route the confirmed phrase the SAME way chat does (agent_thread_screen):
    //   layer 1 — local English fast-path (offline, zero latency);
    //   layer 2 — backend /agent, the ONLY path that understands Bangla
    //             open-phrases (the Dart language gate forbids Bangla literals),
    //             reading resp['route'] exactly as the chat does.
    final local = ChatNav.detectRoute(text);
    if (local != null && ChatNav.push(context, local)) return;
    try {
      final app = context.read<AppState>();
      final r = await app.api.agent(text);
      if (!mounted) return;
      if (ChatNav.push(context, r['route'] as String?)) return;
    } catch (_) {
      // best-effort: fall through to the snackbar below; never crash on offline/AI failure.
    }
    if (!mounted) return;
    // Nothing resolved: give honest, localized feedback (same copy chat uses
    // when it can't act on the input).
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_t.sendFailed)),
    );
  }

  Future<void> _exit() async {
    final t = _t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        icon: const Icon(Icons.elderly_rounded, color: Brand.blue),
        title: Text(t.elderlyExitConfirmTitle),
        content: Text(t.elderlyExitConfirmBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.elderlyExitConfirmCta)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await EldersModeController.set(context, false);
    if (!mounted) return;
    widget.onExit?.call();
  }

  // ---- call-family picker ---------------------------------------------------

  Future<void> _callFamily() async {
    final t = _t;
    if (_contacts.isEmpty) {
      // Empty state: no saved contact -> send them to add one.
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.person_add_alt_rounded, color: Brand.blue, size: 32),
          title: Text(t.elderlyNoContactTitle, style: AType.headlineSmall),
          content:
              Text(t.elderlyNoContactBody, style: AType.titleLarge),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(t.cancel, style: AType.titleLarge)),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _open('emergency');
              },
              child:
                  Text(t.elderlyAddContactCta, style: AType.titleLarge),
            ),
          ],
        ),
      );
      return;
    }
    // One callable contact -> call it straight away (after the confirm).
    if (_contacts.length == 1) {
      final c = _contacts.first;
      await _call('${c['phone']}', _who(c));
      return;
    }
    // Several -> a big-row picker.
    await showAppSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, Gap.xs, 20, Gap.md),
              child: Text(t.elderlyChooseWhoToCall,
                  style: AType.headlineSmall.copyWith(fontWeight: FontWeight.bold)),
            ),
            for (final c in _contacts)
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 72),
                child: ListTile(
                  leading: const CircleAvatar(
                      radius: 26,
                      backgroundColor: Brand.success,
                      child: Icon(Icons.call_rounded, color: Colors.white, size: 28)),
                  title: Text(_who(c),
                      style: AType.headlineSmall.copyWith(fontWeight: FontWeight.w600)),
                  subtitle:
                      Text('${c['phone']}', style: AType.titleLarge),
                  onTap: () {
                    Navigator.pop(ctx);
                    _call('${c['phone']}', _who(c));
                  },
                ),
              ),
            const SizedBox(height: Gap.sm),
          ],
        ),
      ),
    );
  }

  String _who(Map<String, dynamic> c) {
    final name = '${c['name'] ?? ''}'.trim();
    final rel = '${c['relation'] ?? ''}'.trim();
    if (name.isNotEmpty) return name;
    if (rel.isNotEmpty) return rel;
    return _t.elderlyFamilyGeneric;
  }

  // ---- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final t = _t;
    // A single large active-language title (never "bn / en").
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        toolbarHeight: 72,
        title: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(t.elderlyHomeTitle,
                maxLines: 1,
                style:
                    AType.headlineMedium.copyWith(fontWeight: FontWeight.bold))),
        actions: [
          // The large, always-present way OUT of simple mode.
          Padding(
            padding: const EdgeInsets.only(right: Gap.sm),
            child: TextButton.icon(
              onPressed: _exit,
              icon: const Icon(Icons.close_rounded, size: 26),
              label:
                  Text(t.elderlyExitCta, style: AType.titleLarge),
            ),
          ),
        ],
      ),
      body: SafeArea(child: _body(t)),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(Gap.lg),
        child: Column(
          children: [
            Skeleton(height: 110),
            SizedBox(height: Gap.lg),
            Skeleton(height: 320),
          ],
        ),
      );
    }
    if (_error) {
      return _ErrorRetry(message: honestFailText(t, _failCause, otherwise: t.elderlyLoadError), cta: t.retry, onRetry: () {
        setState(() => _loading = true);
        _load();
      });
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 28),
        children: [
          if (_offline) _offlineBanner(t),
          // SOS always first, always one tap, full width, alarm red.
          ElderlyTile(
            icon: Icons.sos_rounded,
            label: t.elderlyTileSos,
            sublabel: t.elderlyTileSosSub,
            color: Brand.dangerFill, // white 5.6:1 — AAA at these large sizes
            wide: true,
            onTap: () => _open('emergency'),
          ),
          const SizedBox(height: Gap.lg),
          GridView.count(
            crossAxisCount: 2,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: 0.82,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              ElderlyTile(
                icon: Icons.call_rounded,
                label: t.elderlyTileCall,
                sublabel: _callSub(t),
                color: Brand.successFill,
                onTap: _callFamily,
              ),
              // play-nomed: no medicine tile in the Play flavour — the same
              // slot becomes a plain Reminders tile (2x2 grid unchanged).
              ElderlyTile(
                icon: kMedicalFeaturesAllowed ? Icons.medication_rounded : Icons.alarm_rounded,
                label: kMedicalFeaturesAllowed
                    ? t.elderlyTileMeds
                    : t.navReminders,
                sublabel: !kMedicalFeaturesAllowed
                    ? null
                    : _medsDueToday > 0
                        ? t.elderlyMedsDue(_digits(_medsDueToday))
                        : t.elderlyMedsNoneDue,
                color: Brand.blueDeep,
                onTap: () => _open(
                    kMedicalFeaturesAllowed ? 'medicine_db' : 'reminders'),
              ),
              ElderlyTile(
                icon: Icons.chat_bubble_rounded,
                label: t.elderlyTileMessages,
                color: const Color(0xFF4A148C),
                onTap: () => _open('messages'),
              ),
              ElderlyTile(
                icon: Icons.account_balance_wallet_rounded,
                label: t.elderlyTileMoney,
                color: const Color(0xFF004D40),
                onTap: () => _open('money'),
              ),
            ],
          ),
          const SizedBox(height: Gap.lg),
          // Help spans full width.
          ElderlyTile(
            icon: Icons.help_outline_rounded,
            label: t.elderlyTileHelp,
            sublabel: t.elderlyTileHelpSub,
            color: const Color(0xFF37474F),
            wide: true,
            onTap: () => _open('guide'),
          ),
          const SizedBox(height: Gap.xl),
          _voiceButton(t),
        ],
      ),
    );
  }

  String _digits(int n) {
    // Active-locale digits without a Bangla literal in source.
    final latin = n.toString();
    if (!_t.localeName.startsWith('bn')) return latin;
    const bnZero = 0x09E6;
    final b = StringBuffer();
    for (final ch in latin.runes) {
      b.writeCharCode(ch >= 0x30 && ch <= 0x39 ? bnZero + (ch - 0x30) : ch);
    }
    return b.toString();
  }

  String? _callSub(AppLocalizations t) {
    if (_contacts.isEmpty) return t.elderlyCallSubAdd;
    if (_contacts.length == 1) return _who(_contacts.first);
    return t.elderlyCallSubCount(_digits(_contacts.length));
  }

  Widget _voiceButton(AppLocalizations t) => Center(
        child: Column(
          children: [
            Semantics(
              button: true,
              label: t.elderlyVoice,
              child: Material(
                color: Brand.blue,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _voice,
                  child: const Padding(
                    padding: EdgeInsets.all(26),
                    child: Icon(Icons.mic_rounded, size: 56, color: Colors.white),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(t.elderlyVoice,
                style: AType.titleLarge.copyWith(fontWeight: FontWeight.w600)),
          ],
        ),
      );

  Widget _offlineBanner(AppLocalizations t) => Container(
        margin: const EdgeInsets.only(bottom: Gap.lg),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Brand.warning.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Brand.warning, width: 2),
        ),
        child: Row(
          children: [
            const Icon(Icons.wifi_off_rounded, size: 28, color: Brand.warning),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Text(t.elderlyOffline,
                  style: AType.titleLarge.copyWith(height: 1.2)),
            ),
          ],
        ),
      );
}

class _ErrorRetry extends StatelessWidget {
  final String message;
  final String cta;
  final VoidCallback onRetry;
  const _ErrorRetry(
      {required this.message, required this.cta, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 64, color: Brand.danger),
            const SizedBox(height: Gap.lg),
            Text(message,
                textAlign: TextAlign.center,
                style: AType.titleLarge.copyWith(height: 1.3)),
            const SizedBox(height: 20),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56, minWidth: 180),
              child: FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 26),
                label: Text(cta, style: AType.titleLarge),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
