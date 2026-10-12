import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import 'money_screen.dart';
import 'vault_screen.dart';
import 'family_screen.dart';
import 'emergency_screen.dart';

class _Msg {
  final bool user;
  final String text;
  final List<Map<String, dynamic>> cards;
  _Msg(this.user, this.text, [this.cards = const []]);
}

class AgentThreadScreen extends StatefulWidget {
  const AgentThreadScreen({super.key});
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

  List<String> get _suggestions => [
        t.suggestionToday,
        t.suggestionSpendMonth,
        t.suggestionExpense,
        t.suggestionMedicine,
      ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _greet());
  }

  @override
  void dispose() {
    _speech.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _greet() async {
    final app = context.read<AppState>();
    final name = app.user?.name.isNotEmpty == true ? app.user!.name : t.friend;
    setState(() => _msgs.add(_Msg(false, '${t.greeting(name)}\n${t.greetingHelp}')));
    try {
      final alerts = await app.api.alertsList();
      if (alerts.isNotEmpty && mounted) {
        setState(() => _msgs.add(_Msg(false, t.urgentForYou,
            alerts.map((a) => {'type': 'alert', 'title': a['text'],
                'subtitle': '', 'severity': a['severity']}).toList())));
      }
    } catch (_) {}
    _toBottom();
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
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
      // refresh offline repos so the new item appears in modules too
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

  Future<void> _undo(Map<String, dynamic> card, int msgIndex) async {
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
    final loc = context.read<AppState>().locale?.languageCode == 'en'
        ? 'en_US'
        : 'bn_BD';
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
      _header(context),
      _modulesBar(context),
      Expanded(
        child: _msgs.isEmpty
            ? const SizedBox()
            : ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                itemCount: _msgs.length,
                itemBuilder: (_, i) => _bubble(_msgs[i], i),
              ),
      ),
      _suggestionsRow(),
      _inputBar(),
    ]);
  }

  Widget _header(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xs),
      child: Row(children: [
        Container(
          height: 36,
          width: 36,
          decoration: const BoxDecoration(
            gradient: Brand.gradient,
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.psychology_alt_outlined,
              color: Colors.white, size: 20),
        ),
        const SizedBox(width: Gap.md),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Assisto',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          Row(children: [
            Container(
              height: 7,
              width: 7,
              decoration: const BoxDecoration(
                  color: Brand.success, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
            Text(t.assistantSubtitle,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ]),
        ]),
      ]),
    );
  }

  Widget _modulesBar(BuildContext context) {
    final mods = <(IconData, String, Color, Widget)>[
      (Icons.account_balance_wallet_outlined, t.moduleMoney, Brand.gold, const MoneyScreen()),
      (Icons.lock_outline, t.moduleVault, Brand.navy, const VaultScreen()),
      (Icons.diversity_1_outlined, t.moduleFamily, Brand.cyan, const FamilyScreen()),
      (Icons.emergency_outlined, t.moduleEmergency, Brand.danger, const EmergencyScreen()),
    ];
    return SizedBox(
      height: 92,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
        children: [
          for (final m in mods)
            Padding(
              padding: const EdgeInsets.only(right: Gap.md),
              child: InkWell(
                onTap: () {
                  HapticFeedback.selectionClick();
                  _open(m.$4);
                },
                borderRadius: BorderRadius.circular(Radii.md),
                child: SizedBox(
                  width: 68,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                      height: 52,
                      width: 52,
                      decoration: BoxDecoration(
                        color: m.$3.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(Radii.md),
                      ),
                      child: Icon(m.$1, color: m.$3, size: 26),
                    ),
                    const SizedBox(height: Gap.xs),
                    Text(m.$2,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _open(Widget w) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => w));

  Widget _bubble(_Msg m, int i) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: m.user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: m.user ? scheme.primary : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(m.user ? 16 : 4),
            bottomRight: Radius.circular(m.user ? 4 : 16),
          ),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (m.text.isNotEmpty)
            Text(m.text, style: TextStyle(color: m.user ? Colors.white : null)),
          for (final c in m.cards) _card(c, i),
        ]),
      ),
    );
  }

  Widget _card(Map<String, dynamic> c, int msgIndex) {
    final isAlert = c['type'] == 'alert';
    final sev = c['severity'];
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isAlert
            ? (sev == 'high' ? const Color(0xFFFFE2E0) : const Color(0xFFFFF4D6))
            : Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.black12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(c['title'] ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
        if ((c['subtitle'] ?? '').toString().isNotEmpty)
          Text(c['subtitle'], style: const TextStyle(fontSize: 12, color: Colors.grey)),
        if (c['undo'] == true)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => _undo(c, msgIndex),
              icon: const Icon(Icons.undo, size: 16),
              label: Text(t.undo),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            ),
          ),
      ]),
    );
  }

  Widget _suggestionsRow() {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        children: [
          for (final s in _suggestions)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: ActionChip(label: Text(s, style: const TextStyle(fontSize: 12)),
                  onPressed: () => _send(s)),
            ),
        ],
      ),
    );
  }

  Widget _inputBar() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _input,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                hintText: _listening ? t.listening : t.inputHint,
                filled: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            onPressed: _toggleMic,
            tooltip: t.listening,
            icon: Icon(_listening ? Icons.stop_circle : Icons.mic_none,
                color: _listening ? Brand.danger : null),
          ),
          const SizedBox(width: 2),
          _sending
              ? const Padding(padding: EdgeInsets.all(10),
                  child: SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2)))
              : IconButton.filled(onPressed: () => _send(), icon: const Icon(Icons.send)),
        ]),
      ),
    );
  }
}
