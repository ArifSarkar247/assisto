import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:url_launcher/url_launcher.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/permission_reason.dart';
import 'nearby_screen.dart';

class _Msg {
  final bool user;
  final String text;
  final List<Map<String, dynamic>> cards;
  _Msg(this.user, this.text, [this.cards = const []]);
}

/// The heart of the app: a conversation with Assisto. The screen is only the
/// thread — modules live in the drawer. Rich cards appear inline with actions.
class AgentThreadScreen extends StatefulWidget {
  /// Preview/screenshot seed: a list of {user: bool, text: String, cards: [...]}.
  /// When set, the thread renders this conversation instead of polling alerts.
  final List<Map<String, dynamic>>? debugSeed;
  final bool debugListening;
  const AgentThreadScreen(
      {super.key, this.debugSeed, this.debugListening = false});
  @override
  State<AgentThreadScreen> createState() => _AgentThreadScreenState();
}

class _AgentThreadScreenState extends State<AgentThreadScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<_Msg> _msgs = [];
  bool _sending = false;

  final SpeechToText _speech = SpeechToText();
  bool _speechReady = false;
  bool _listening = false;

  AppLocalizations get t => AppLocalizations.of(context);

  List<(IconData, String)> get _suggestions => [
        (Icons.wb_sunny_outlined, t.suggestionToday),
        (Icons.query_stats_outlined, t.suggestionSpendMonth),
        (Icons.receipt_long_outlined, t.suggestionExpense),
        (Icons.medication_outlined, t.suggestionMedicine),
      ];

  @override
  void initState() {
    super.initState();
    if (widget.debugSeed != null) {
      _listening = widget.debugListening;
      for (final m in widget.debugSeed!) {
        _msgs.add(_Msg(
            m['user'] == true,
            (m['text'] ?? '').toString(),
            ((m['cards'] ?? []) as List).cast<Map<String, dynamic>>()));
      }
      return; // previews don't poll
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAlerts());
  }

  @override
  void dispose() {
    _speech.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // Surface anything urgent proactively as the first assistant message. If
  // nothing's urgent, the beautiful welcome state stays.
  Future<void> _loadAlerts() async {
    final app = context.read<AppState>();
    try {
      final alerts = await app.api.alertsList();
      final urgent = alerts.where((a) => a['severity'] == 'high').toList();
      if (urgent.isNotEmpty && mounted) {
        setState(() => _msgs.add(_Msg(false, t.urgentForYou,
            urgent
                .map((a) => {
                      'type': 'alert',
                      'title': a['text'],
                      'subtitle': '',
                      'severity': a['severity']
                    })
                .toList())));
        _toBottom();
      }
    } catch (_) {}
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: Motion.base, curve: Curves.easeOut);
      }
    });
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty || _sending) return;
    HapticFeedback.selectionClick();
    _input.clear();
    setState(() {
      _msgs.add(_Msg(true, text));
      _sending = true;
    });
    _toBottom();
    final app = context.read<AppState>();
    try {
      final r = await app.api.agent(text);
      final cards = ((r['cards'] ?? []) as List).cast<Map<String, dynamic>>();
      setState(() => _msgs.add(_Msg(false, r['reply'] ?? '', cards)));
      app.reminders.sync();
      app.txns.sync();
      app.loans.sync();
    } catch (e) {
      setState(() => _msgs.add(_Msg(false, t.sendFailed)));
    } finally {
      setState(() => _sending = false);
      _toBottom();
    }
  }

  Future<void> _undo(Map<String, dynamic> card) async {
    final app = context.read<AppState>();
    try {
      await app.api.deleteByModel(card['model'], card['id']);
      app.reminders.sync();
      app.txns.sync();
      app.loans.sync();
      if (mounted) {
        setState(() => _msgs.add(_Msg(false, t.undone)));
        _toBottom();
      }
    } catch (_) {}
  }

  Future<void> _toggleMic() async {
    if (_listening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    if (!_speechReady) {
      final okReason = await showPermissionReason(context, PermKind.mic);
      if (!okReason || !mounted) return;
      _speechReady = await _speech.initialize(
        onStatus: (s) {
          if ((s == 'done' || s == 'notListening') && mounted) {
            setState(() => _listening = false);
          }
        },
        onError: (_) {
          if (mounted) setState(() => _listening = false);
        },
      );
    }
    if (!_speechReady) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.micUnavailable)));
      }
      return;
    }
    HapticFeedback.selectionClick();
    final loc =
        context.read<AppState>().locale?.languageCode == 'en' ? 'en_US' : 'bn_BD';
    setState(() => _listening = true);
    await _speech.listen(
      localeId: loc,
      onResult: (r) {
        if (mounted) {
          setState(() {
            _input.text = r.recognizedWords;
            _input.selection = TextSelection.fromPosition(
                TextPosition(offset: _input.text.length));
          });
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Expanded(
        child: _msgs.isEmpty
            ? _welcome()
            : ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.sm),
                itemCount: _msgs.length,
                itemBuilder: (_, i) => _bubble(_msgs[i]),
              ),
      ),
      _inputBar(),
    ]);
  }

  // ---------------- welcome / empty state ----------------
  Widget _welcome() {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.xxl, Gap.xl, Gap.md),
      children: [
        const SizedBox(height: Gap.xl),
        Center(child: _logoMark(76)),
        const SizedBox(height: Gap.lg),
        Text(t.welcomeHeadline,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: Gap.sm),
        Text(t.welcomeBody,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
        const SizedBox(height: Gap.xl),
        for (final s in _suggestions) ...[
          _suggestionCard(s.$1, s.$2),
          const SizedBox(height: Gap.sm),
        ],
      ],
    );
  }

  Widget _suggestionCard(IconData icon, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(Radii.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: () => _send(text),
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Row(children: [
            Icon(icon, size: 22, color: scheme.primary),
            const SizedBox(width: Gap.md),
            Expanded(
                child: Text(text, style: const TextStyle(fontWeight: FontWeight.w500))),
            Icon(Icons.north_east, size: 16, color: scheme.onSurfaceVariant),
          ]),
        ),
      ),
    );
  }

  // ---------------- bubbles ----------------
  Widget _bubble(_Msg m) {
    final scheme = Theme.of(context).colorScheme;
    final bubble = Container(
      constraints:
          BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.md),
      decoration: BoxDecoration(
        color: m.user ? scheme.primary : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(m.user ? 18 : 4),
          bottomRight: Radius.circular(m.user ? 4 : 18),
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (m.text.isNotEmpty)
          Text(m.text,
              style: TextStyle(
                  color: m.user ? Colors.white : scheme.onSurface, height: 1.4)),
        for (final c in m.cards) _card(c),
      ]),
    );

    if (m.user) {
      return Align(
        alignment: Alignment.centerRight,
        child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.xs), child: bubble),
      );
    }
    // assistant: avatar + bubble
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _logoMark(28),
        const SizedBox(width: Gap.sm),
        Flexible(child: bubble),
      ]),
    );
  }

  Future<void> _launch(String url, {bool external = true}) async {
    try {
      await launchUrl(Uri.parse(url),
          mode: external ? LaunchMode.externalApplication : LaunchMode.platformDefault);
    } catch (_) {}
  }

  Widget _actionCard(Map<String, dynamic> c, IconData icon, List<Widget> actions) {
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
          Expanded(child: Text(c['title'] ?? '',
              style: const TextStyle(fontWeight: FontWeight.w700))),
        ]),
        if ((c['subtitle'] ?? '').toString().isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 2, left: 26),
              child: Text(c['subtitle'],
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant))),
        const SizedBox(height: Gap.sm),
        Wrap(spacing: Gap.sm, children: actions),
      ]),
    );
  }

  Widget _card(Map<String, dynamic> c) {
    final scheme = Theme.of(context).colorScheme;
    if (c['type'] == 'approval') return _approvalCard(c);
    if (c['type'] == 'music') {
      return _actionCard(c, Icons.music_note, [
        FilledButton.icon(
            onPressed: () => _launch(c['youtube'] ?? ''),
            icon: const Icon(Icons.play_arrow, size: 18),
            label: const Text('YouTube')),
        if (c['spotify'] != null)
          OutlinedButton(onPressed: () => _launch(c['spotify']), child: const Text('Spotify')),
      ]);
    }
    if (c['type'] == 'navigate') {
      return _actionCard(c, Icons.navigation_outlined, [
        FilledButton.icon(
            onPressed: () => _launch(c['maps'] ?? ''),
            icon: const Icon(Icons.map_outlined, size: 18),
            label: Text(t.open)),
      ]);
    }
    if (c['type'] == 'call') {
      final phone = (c['phone'] ?? '').toString();
      return _actionCard(c, Icons.call, [
        FilledButton.icon(
            onPressed: phone.isEmpty ? null : () => _launch('tel:$phone', external: false),
            icon: const Icon(Icons.call, size: 18),
            label: Text(t.call)),
      ]);
    }
    if (c['type'] == 'nearby') {
      return _actionCard(c, Icons.place_outlined, [
        FilledButton.icon(
            onPressed: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => NearbyScreen(placeType: c['place_type'] ?? 'restaurant'))),
            icon: const Icon(Icons.search, size: 18),
            label: Text(t.open)),
      ]);
    }
    final isAlert = c['type'] == 'alert';
    final sev = c['severity'];
    final bg = isAlert
        ? (sev == 'high'
            ? scheme.errorContainer
            : scheme.tertiaryContainer)
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
                style: TextStyle(fontSize: 12, color: fg.withValues(alpha: 0.75))),
          ),
        if (c['undo'] == true)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => _undo(c),
              icon: const Icon(Icons.undo, size: 16),
              label: Text(t.undo),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            ),
          ),
      ]),
    );
  }

  Widget _approvalCard(Map<String, dynamic> c) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: Gap.sm),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.verified_user_outlined, size: 18, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(c['title'] ?? '',
                style: TextStyle(
                    fontWeight: FontWeight.w700, color: scheme.onSurface)),
          ),
        ]),
        if ((c['subtitle'] ?? '').toString().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 26),
            child: Text(c['subtitle'],
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          ),
        const SizedBox(height: Gap.sm),
        Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
          FilledButton.icon(
            onPressed: () {},
            icon: const Icon(Icons.check, size: 18),
            label: Text(t.approve),
            style: FilledButton.styleFrom(
                minimumSize: const Size(0, 38),
                visualDensity: VisualDensity.compact),
          ),
          OutlinedButton(
              onPressed: () {},
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 38)),
              child: Text(t.edit)),
          TextButton(onPressed: () {}, child: Text(t.cancel)),
        ]),
      ]),
    );
  }

  // ---------------- input ----------------
  Widget _inputBar() {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.sm),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _input,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              minLines: 1,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: _listening ? t.listening : t.inputHint,
                filled: true,
                fillColor: scheme.surfaceContainerHighest,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.md),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Radii.pill),
                    borderSide: BorderSide.none),
              ),
            ),
          ),
          const SizedBox(width: Gap.xs),
          IconButton(
            onPressed: _toggleMic,
            tooltip: t.listening,
            icon: Icon(_listening ? Icons.stop_circle : Icons.mic_none,
                color: _listening ? Brand.danger : scheme.onSurfaceVariant),
          ),
          _sending
              ? const Padding(
                  padding: EdgeInsets.all(10),
                  child: SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(strokeWidth: 2)))
              : IconButton.filled(
                  onPressed: () => _send(), icon: const Icon(Icons.arrow_upward)),
        ]),
      ),
    );
  }

  Widget _logoMark(double size) => ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.26),
        child: Image.asset('assets/branding/new_logo.png',
            width: size, height: size, fit: BoxFit.cover),
      );
}
