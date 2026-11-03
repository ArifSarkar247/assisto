import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../messaging/media/voice_recorder_sheet.dart' show showVoiceRecorder;
import '../screens/business/bizagent/seller_agent_screen.dart' show baErrorText, bd;
import '../services/error_report.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart' show withNavBarInset;
import '../widgets/local_counter.dart';
import '../widgets/skeleton.dart';
import 'bizai_source.dart';

/// A file the customer picked / recorded for the shop chat.
typedef ShopChatFile = ({String path, String mime});
typedef ShopChatPicker = Future<ShopChatFile?> Function(BuildContext context);

Future<ShopChatFile?> _pickPhoto(BuildContext context) async {
  final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 80,
      maxWidth: 1600);
  if (x == null) return null;
  return (path: x.path, mime: x.mimeType ?? 'image/jpeg');
}

Future<ShopChatFile?> _recordVoice(BuildContext context) async {
  final d = await showVoiceRecorder(context, allowViewOnce: false);
  if (d == null) return null;
  return (path: d.path, mime: d.mime);
}

/// bizai — the customer's chat with a SHOP (not a personal My Circle chat):
/// the shop's AI sales assistant answers from its catalog in seconds. Before
/// the first message the honest disclosure (not end-to-end encrypted,
/// visible to the shop and its AI) is shown; every AI reply carries an "AI"
/// label; "Talk to a person" hands the chat to the shop.
class ShopChatScreen extends StatefulWidget {
  final String code;
  final BizaiSource? source;
  final ShopChatPicker? pickPhoto;
  final ShopChatPicker? recordVoice;
  const ShopChatScreen(
      {super.key, required this.code, this.source, this.pickPhoto, this.recordVoice});

  @override
  State<ShopChatScreen> createState() => _ShopChatScreenState();
}

class _ShopChatScreenState extends State<ShopChatScreen> {
  late final BizaiSource _src = widget.source ?? ApiBizaiSource(context.read<AppState>().api);
  final _text = TextEditingController();
  final _scroll = ScrollController();
  Map<String, dynamic> _shop = const {};
  final List<Map<String, dynamic>> _msgs = [];
  bool _loading = true;
  bool _sending = false;
  Object? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    // a person's reply from the shop arrives without a push too (every 8 s
    // while this screen is open; nothing runs when it is closed)
    _poll = Timer.periodic(const Duration(seconds: 8), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  int get _lastId => _msgs.fold<int>(0, (m, r) {
        final id = (r['id'] as num?)?.toInt() ?? 0;
        return id > m ? id : m;
      });

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = await _src.shop(widget.code);
      if (!mounted) return;
      setState(() {
        _shop = s;
        _msgs
          ..clear()
          ..addAll(bzList(s['messages']));
        _loading = false;
      });
      _toEnd();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _refresh() async {
    if (_loading || _sending || _error != null || _shop['ok'] != true) return;
    try {
      final r = await _src.messages(widget.code, _lastId);
      final rows = bzList(r['messages']);
      if (!mounted) return;
      if (rows.isNotEmpty || (r['with_person'] == true) != (_shop['with_person'] == true)) {
        setState(() {
          _addRows(rows);
          _shop = {..._shop, 'with_person': r['with_person'] == true};
        });
        _toEnd();
      }
    } catch (e) {
      reportNonFatal('bizai.shopchat.poll', e);
    }
  }

  void _addRows(List<Map<String, dynamic>> rows) {
    final have = {for (final m in _msgs) m['id']};
    for (final r in rows) {
      final id = r['id'];
      if (id != 0 && have.contains(id)) continue;
      _msgs.add(r);
    }
  }

  void _toEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _run(Future<Map<String, dynamic>> Function() call) async {
    final t = AppLocalizations.of(context);
    setState(() => _sending = true);
    try {
      final r = await call();
      if (!mounted) return;
      setState(() {
        _msgs.removeWhere((m) => m['dir'] == 'system');
        _addRows(bzList(r['messages']));
        if (r.containsKey('with_person')) {
          _shop = {..._shop, 'with_person': r['with_person'] == true};
        }
      });
      _toEnd();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(baErrorText(t, e))));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendText() async {
    final s = _text.text.trim();
    if (s.isEmpty || _sending) return;
    _text.clear();
    await _run(() => _src.send(widget.code, s));
  }

  Future<void> _sendFile(String kind) async {
    if (_sending) return;
    final f = await (kind == 'image'
        ? (widget.pickPhoto ?? _pickPhoto)(context)
        : (widget.recordVoice ?? _recordVoice)(context));
    if (f == null || !mounted) return;
    await _run(() => _src.sendFile(widget.code, kind, f.path, f.mime));
  }

  Future<void> _person() => _run(() => _src.talkToPerson(widget.code));

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final name = '${_shop['shop'] ?? ''}';
    return Scaffold(
      appBar: AppBar(
        title: Text(name.isEmpty ? t.bizaiShopChatTitleNoName : t.bizaiShopChatTitle(name),
            maxLines: 2, overflow: TextOverflow.ellipsis),
        actions: [
          if (_shop['ok'] == true && _shop['with_person'] != true)
            TextButton.icon(
              key: const ValueKey('bizai-person'),
              onPressed: _sending ? null : _person,
              icon: const Icon(Icons.support_agent_rounded),
              label: Text(t.bizaiTalkToPerson),
            ),
        ],
      ),
      body: _body(t),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const SkeletonList();
    if (_error != null) {
      return StateMessage(
        icon: Icons.storefront_rounded,
        title: t.bizaiShopLoadFailed,
        message: baErrorText(t, _error!),
        action: FilledButton(onPressed: _load, child: Text(t.bizRetry)),
      );
    }
    if (_shop['ok'] != true) {
      return StateMessage(
        icon: Icons.storefront_rounded,
        title: t.bizaiChatOffTitle,
        message: t.bizaiChatOffBody,
        action: FilledButton(
            onPressed: () => Navigator.of(context).maybePop(), child: Text(t.bizaiBack)),
      );
    }
    if (_shop['own_shop'] == true) {
      return StateMessage(
        icon: Icons.storefront_rounded,
        title: t.bizaiOwnShopTitle,
        message: t.bizaiOwnShopBody,
      );
    }
    final firstTime = _msgs.where((m) => m['dir'] == 'in').isEmpty;
    return Column(children: [
      _Disclosure(text: '${_shop['disclosure'] ?? ''}', big: firstTime),
      if (_shop['with_person'] == true)
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
          child: Row(children: [
            const Icon(Icons.support_agent_rounded, size: 20),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text(t.bizaiWithPerson)),
          ]),
        ),
      Expanded(
        child: _msgs.isEmpty
            ? ListView(padding: const EdgeInsets.all(Gap.lg), children: [
                Icon(Icons.chat_bubble_outline_rounded,
                    size: 48, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: Gap.md),
                Text(t.bizaiEmptyBenefit,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: Gap.sm),
                Text(t.bizaiEmptyHow, textAlign: TextAlign.center),
              ])
            : ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.all(Gap.md),
                itemCount: _msgs.length,
                itemBuilder: (_, i) => _Bubble(m: _msgs[i]),
              ),
      ),
      _composer(t),
    ]);
  }

  Widget _composer(AppLocalizations t) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.sm, Gap.xs, Gap.sm, Gap.sm)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          IconButton(
            key: const ValueKey('bizai-photo'),
            tooltip: t.bizaiPhoto,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            onPressed: _sending ? null : () => _sendFile('image'),
            icon: const Icon(Icons.photo_camera_rounded),
          ),
          IconButton(
            key: const ValueKey('bizai-voice'),
            tooltip: t.bizaiVoice,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            onPressed: _sending ? null : () => _sendFile('audio'),
            icon: const Icon(Icons.mic_rounded),
          ),
          Expanded(
            child: TextField(
              key: const ValueKey('bizai-input'),
              controller: _text,
              minLines: 1,
              maxLines: 4,
              maxLength: 1000,
              buildCounter: localCounter,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _sendText(),
              decoration: InputDecoration(hintText: t.bizaiComposerHint),
            ),
          ),
          _sending
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                      width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)))
              : IconButton(
                  key: const ValueKey('bizai-send'),
                  tooltip: t.bizaiSend,
                  constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                  onPressed: _sendText,
                  icon: const Icon(Icons.send_rounded),
                ),
        ]),
      ),
    );
  }
}

class _Disclosure extends StatelessWidget {
  final String text;
  final bool big;
  const _Disclosure({required this.text, required this.big});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: t.bizaiDisclosureTitle,
      child: Container(
        key: const ValueKey('bizai-disclosure'),
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.lock_open_rounded, color: scheme.onSecondaryContainer),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (big)
                Text(t.bizaiDisclosureTitle,
                    style: TextStyle(
                        fontWeight: FontWeight.w700, color: scheme.onSecondaryContainer)),
              Text(text,
                  maxLines: big ? null : 2,
                  overflow: big ? null : TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSecondaryContainer)),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final Map<String, dynamic> m;
  const _Bubble({required this.m});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final dir = '${m['dir']}';
    if (dir == 'system') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
        child: Text(bd(context, m['text']),
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, fontStyle: FontStyle.italic)),
      );
    }
    final mine = dir == 'in';
    final ai = m['ai'] == true;
    final txt = '${m['text'] ?? ''}';
    final shown = txt == '[image]'
        ? t.bizaiSentPhoto
        : (txt == '[voice]' || txt == '[audio]')
            ? t.bizaiSentVoice
            : txt;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: mine ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (ai)
            Semantics(
              label: t.bizaiAiLabelA11y,
              excludeSemantics: true,
              child: Container(
                key: const ValueKey('bizai-ai-label'),
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                    color: scheme.tertiary, borderRadius: BorderRadius.circular(8)),
                child: Text(t.bizaiAiLabel,
                    style: TextStyle(
                        color: scheme.onTertiary, fontWeight: FontWeight.w700, fontSize: 12)),
              ),
            ),
          if (m['voice'] == true && mine)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.mic_rounded, size: 16, color: scheme.onPrimaryContainer),
              const SizedBox(width: 4),
              Flexible(child: Text(t.bizaiVoiceHeard)),
            ]),
          SelectableText(bd(context, shown),
              style: TextStyle(
                  color: mine ? scheme.onPrimaryContainer : scheme.onSurface)),
        ]),
      ),
    );
  }
}
