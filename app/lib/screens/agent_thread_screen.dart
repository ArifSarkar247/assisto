import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
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

  static const _suggestions = [
    'আজ কী কী আছে?',
    'এই মাসে কত খরচ?',
    '৫০০ টাকা খরচ খাবার',
    'কাল সকাল ৮টায় ওষুধ মনে করিয়ে দিও',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _greet());
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _greet() async {
    final app = context.read<AppState>();
    final name = app.user?.name.isNotEmpty == true ? app.user!.name : 'বন্ধু';
    setState(() => _msgs.add(_Msg(false, 'আসসালামু আলাইকুম, $name 👋\nকী করে দিই? লিখে বলুন।')));
    try {
      final alerts = await app.api.alertsList();
      if (alerts.isNotEmpty && mounted) {
        setState(() => _msgs.add(_Msg(false, 'আপনার জন্য কিছু জরুরি:',
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
      setState(() => _msgs.add(_Msg(false, 'দুঃখিত, এখন করা গেল না। পরে চেষ্টা করুন।')));
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
        setState(() => _msgs.add(_Msg(false, 'ফিরিয়ে নিয়েছি ✓')));
        _toBottom();
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
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

  Widget _modulesBar(BuildContext context) {
    final mods = [
      ['💰', 'হিসাব', () => _open(const MoneyScreen())],
      ['🔒', 'ভল্ট', () => _open(const VaultScreen())],
      ['👨‍👩‍👧', 'ফ্যামিলি', () => _open(const FamilyScreen())],
      ['🚑', 'ইমার্জেন্সি', () => _open(const EmergencyScreen())],
    ];
    return SizedBox(
      height: 76,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        children: [
          for (final m in mods)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: InkWell(
                onTap: m[2] as VoidCallback,
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  width: 72,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(m[0] as String, style: const TextStyle(fontSize: 22)),
                    const SizedBox(height: 2),
                    Text(m[1] as String, style: const TextStyle(fontSize: 11)),
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
              label: const Text('ফিরিয়ে নিন'),
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
                hintText: 'Assisto-কে বলুন…',
                filled: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
              ),
            ),
          ),
          const SizedBox(width: 6),
          _sending
              ? const Padding(padding: EdgeInsets.all(10),
                  child: SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2)))
              : IconButton.filled(onPressed: () => _send(), icon: const Icon(Icons.send)),
        ]),
      ),
    );
  }
}
