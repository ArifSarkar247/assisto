import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import '../widgets/msgr_avatar.dart';
import 'bubble_ask.dart';
import 'bubble_policy.dart';
import 'chat_lock.dart';
import 'chat_opener.dart';
import 'date_separators.dart' show localDigits;
import 'msg_prefs.dart';
import 'receipt_bus.dart';

/// bubbles2 (owner FINAL bubbles order, point 4) — DURING CALLS.
///
/// Over Picture-in-Picture / other apps the SYSTEM bubbles keep working (the
/// normal path). INSIDE the Assisto call screen Android would draw them
/// over our own window, so the call screen shows an in-app overlay with the
/// same look instead: round photos at the side with an unread badge; tap →
/// a row of round photos at the top to pick a chat → a small chat window
/// over the call (the call keeps running: video shrinks to the mini tile,
/// audio stays on the same earphone / Bluetooth route — nothing here
/// touches audio); drag the photos to ✕ at the bottom to close them.
/// While the overlay is up, `c3_call_overlay_until` tells the native helper
/// not to attach a duplicate system bubble (a time, never a stuck flag).

@immutable
class InCallBubble {
  const InCallBubble({
    required this.key,
    this.name = '',
    this.photo = '',
    this.photoV = '',
    this.unread = 1,
    required this.at,
  });

  /// "member:12" / "group:3".
  final String key;
  final String name;
  final String photo;
  final String photoV;
  final int unread;
  final DateTime at;

  bool get isGroup => key.startsWith('group:');

  InCallBubble copyWith(
          {String? name, String? photo, String? photoV, int? unread, DateTime? at}) =>
      InCallBubble(
        key: key,
        name: name ?? this.name,
        photo: photo ?? this.photo,
        photoV: photoV ?? this.photoV,
        unread: unread ?? this.unread,
        at: at ?? this.at,
      );
}

/// Pure list rules (pinned by tests).
class InCallBubbleList {
  InCallBubbleList._();

  /// Most bubbles shown at once (like the system stack).
  static const max = 5;

  /// A new message: that chat moves to the front with one more unread.
  static List<InCallBubble> add(List<InCallBubble> list, String key,
      {String name = '', required DateTime now}) {
    final old = list.where((b) => b.key == key).firstOrNull;
    final rest = list.where((b) => b.key != key);
    final next = old == null
        ? InCallBubble(key: key, name: name, at: now)
        : old.copyWith(
            unread: old.unread + 1,
            at: now,
            name: name.isNotEmpty ? name : old.name);
    return [next, ...rest].take(max).toList(growable: false);
  }

  static List<InCallBubble> remove(List<InCallBubble> list, String key) =>
      list.where((b) => b.key != key).toList(growable: false);

  static List<InCallBubble> read(List<InCallBubble> list, String key) => [
        for (final b in list) b.key == key ? b.copyWith(unread: 0) : b
      ];
}

/// The bus: fed by foreground message pushes (PushService) and the realtime
/// `msg.new` events; only records while a call screen shows the overlay.
class InCallBubbles {
  InCallBubbles({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  static final InCallBubbles instance = InCallBubbles();

  final DateTime Function() _clock;
  final ValueNotifier<List<InCallBubble>> items =
      ValueNotifier<List<InCallBubble>>(const []);
  int _holders = 0;
  bool get active => _holders > 0;

  // the same message can arrive by push AND realtime: by id, else by time
  final List<String> _seenIds = [];
  final Map<String, DateTime> _lastAt = {};
  static const _sameWindow = Duration(seconds: 4);

  void attach() => _holders++;

  void detach() {
    if (_holders > 0) _holders--;
    if (_holders == 0) clear();
  }

  void clear() {
    items.value = const [];
    _seenIds.clear();
    _lastAt.clear();
  }

  /// One incoming message for [key]. [msgId] (push) de-duplicates exactly;
  /// without it (realtime) an event within 4 s of the last one for the same
  /// chat is the same message.
  void onMessage(String key, {String name = '', String? msgId}) {
    if (!active || ChatOpener.parse(key) == null) return;
    final now = _clock();
    if (msgId != null && msgId.isNotEmpty) {
      if (_seenIds.contains(msgId)) return;
      _seenIds.add(msgId);
      if (_seenIds.length > 64) _seenIds.removeAt(0);
    } else {
      final last = _lastAt[key];
      if (last != null && now.difference(last) < _sameWindow) return;
    }
    _lastAt[key] = now;
    items.value = InCallBubbleList.add(items.value, key, name: name, now: now);
  }

  void remove(String key) =>
      items.value = InCallBubbleList.remove(items.value, key);

  /// Fill in the name / photo once resolved.
  void update(String key, {String? name, String? photo, String? photoV}) {
    items.value = [
      for (final b in items.value)
        b.key == key
            ? b.copyWith(
                name: (name ?? '').isNotEmpty ? name : b.name,
                photo: photo,
                photoV: photoV)
            : b
    ];
  }
}

/// A round photo with an unread badge — the bubble look shared by the
/// in-call overlay and My Circle's bubble row.
class BubbleFace extends StatelessWidget {
  const BubbleFace({
    super.key,
    required this.name,
    this.photo = '',
    this.photoV = '',
    this.group = false,
    this.unread = 0,
    this.size = 56,
    this.hideName = false,
  });

  final String name;
  final String photo;
  final String photoV;
  final bool group;
  final int unread;
  final double size;

  /// "Hide message content" mode: a generic face, no name / photo.
  final bool hideName;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lang = Localizations.localeOf(context).languageCode;
    final Widget face = (group || hideName)
        ? Container(
            width: size,
            height: size,
            decoration: const BoxDecoration(
                shape: BoxShape.circle, gradient: Brand.gradient),
            child: Icon(
                hideName ? Icons.chat_bubble_rounded : Icons.groups_2_rounded,
                color: Colors.white,
                size: size * 0.5),
          )
        : MsgrAvatar(
            name: name, photoUrl: photo, photoV: photoV, radius: size / 2);
    return SizedBox(
      width: size + 6,
      height: size + 6,
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned(
          left: 3,
          top: 3,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: scheme.surface, width: 2),
              boxShadow: const [
                BoxShadow(
                    color: Colors.black38, blurRadius: 8, offset: Offset(0, 3))
              ],
            ),
            child: face,
          ),
        ),
        if (unread > 0)
          PositionedDirectional(
            end: 0,
            top: 0,
            child: Container(
              constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
              padding: const EdgeInsets.symmetric(horizontal: 5),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.error,
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: scheme.surface, width: 2),
              ),
              child: MediaQuery.withNoTextScaling(
                child: Text(localDigits(unread > 99 ? '99+' : '$unread', lang),
                    style: AType.labelSmall.copyWith(
                        color: scheme.onError, fontWeight: FontWeight.w700)),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Wraps the call screen: shows the in-app bubbles over it while [enabled]
/// (not in PiP). [onOpen] gets the chat key the user picked.
class InCallBubbleHost extends StatefulWidget {
  const InCallBubbleHost({
    super.key,
    required this.child,
    required this.enabled,
    required this.onOpen,
    this.bus,
    this.resolve,
    this.initiallyExpanded = false,
  });

  final Widget child;
  final bool enabled;

  /// Gallery: start with the row of round photos open.
  final bool initiallyExpanded;
  final void Function(String key) onOpen;

  /// Test seams.
  final InCallBubbles? bus;
  final Future<({String name, String photo, String photoV})?> Function(
      String key)? resolve;

  @override
  State<InCallBubbleHost> createState() => _InCallBubbleHostState();
}

class _InCallBubbleHostState extends State<InCallBubbleHost> {
  InCallBubbles get _bus => widget.bus ?? InCallBubbles.instance;
  StreamSubscription<String>? _rt;
  Timer? _ttl;
  AppLifecycleListener? _life;
  bool _foreground = true;
  late bool _expanded = widget.initiallyExpanded;
  bool _dragging = false;
  bool _globalOn = true;
  bool _hide = false;
  Set<String> _offChats = const {};
  final Map<String, ({String name, String photo, String photoV})?> _people = {};
  Map<String, dynamic>? _members;

  @override
  void initState() {
    super.initState();
    _bus.attach();
    _bus.items.addListener(_onItems);
    _rt = ReceiptBus.instance.newMessages.listen((k) => _bus.onMessage(k));
    _life = AppLifecycleListener(
      onResume: () {
        _foreground = true;
        _syncNative();
      },
      onPause: () {
        _foreground = false;
        _syncNative();
      },
    );
    _ttl = Timer.periodic(const Duration(seconds: 60), (_) => _syncNative());
    _syncNative();
    unawaited(_loadPrefs());
  }

  Future<void> _loadPrefs() async {
    try {
      final on = await MsgPrefs.bubblesOn();
      final hide = await MsgPrefs.hideContent();
      final off = await MsgPrefs.bubbleOffChats();
      if (mounted) {
        setState(() {
          _globalOn = on;
          _hide = hide;
          _offChats = off;
        });
      }
      _syncNative();
    } catch (_) {}
  }

  @override
  void didUpdateWidget(InCallBubbleHost old) {
    super.didUpdateWidget(old);
    if (old.enabled != widget.enabled) {
      _syncNative();
      if (!widget.enabled) _expanded = false;
    }
  }

  /// In-app overlay on top → no duplicate system bubble (TTL refreshed
  /// every minute); PiP / background / bubbles off → system bubbles again.
  void _syncNative() {
    unawaited(BubbleAsk.setCallOverlay(
        widget.enabled && _foreground && _globalOn && mounted));
  }

  @override
  void dispose() {
    _ttl?.cancel();
    _rt?.cancel();
    _life?.dispose();
    _bus.items.removeListener(_onItems);
    _bus.detach();
    unawaited(BubbleAsk.setCallOverlay(false));
    super.dispose();
  }

  void _onItems() {
    if (!mounted) return;
    for (final b in _bus.items.value) {
      if (!_people.containsKey(b.key)) unawaited(_resolve(b.key));
    }
    setState(() {});
  }

  Future<void> _resolve(String key) async {
    _people[key] = null; // in flight
    try {
      final r = await (widget.resolve ?? _defaultResolve)(key);
      if (r == null) return;
      _people[key] = r;
      _bus.update(key, name: r.name, photo: r.photo, photoV: r.photoV);
    } catch (_) {}
  }

  Future<({String name, String photo, String photoV})?> _defaultResolve(
      String key) async {
    final p = ChatOpener.parse(key);
    if (p == null || p.kind == 'group') return null;
    ApiClient api;
    try {
      api = context.read<AppState>().api;
    } catch (_) {
      return null;
    }
    _members ??= await api.getJson('/circle/members');
    final list = ((_members!['results'] ?? _members!['members'] ?? const []) as List)
        .whereType<Map>();
    final m = list.where((m) => '${m['id']}' == '${p.id}').firstOrNull;
    if (m == null) return null;
    return (
      name: '${m['name'] ?? ''}',
      photo: '${m['photo_link'] ?? m['photo'] ?? ''}',
      photoV: '${m['photo_v'] ?? ''}',
    );
  }

  /// Same gates as the system bubbles: app switch, per-chat off, locked chats.
  List<InCallBubble> get _visible => _bus.items.value
      .where((b) => _globalOn)
      .where((b) => BubblePolicy.chatOn(b.key, _offChats))
      .where((b) => !ChatLockStore.instance.isLockedSync(b.key))
      .toList();

  void _open(String key) {
    setState(() => _expanded = false);
    _bus.items.value = InCallBubbleList.read(_bus.items.value, key);
    widget.onOpen(key);
  }

  String _label(AppLocalizations t, InCallBubble b) {
    final lang = Localizations.localeOf(context).languageCode;
    final name = _hide || b.name.isEmpty ? t.bbl2NewMessage : b.name;
    return t.bbl2FaceA11y(name, localDigits('${b.unread}', lang));
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.enabled ? _visible : const <InCallBubble>[];
    // ALWAYS the same Stack with the call body first: the first bubble must
    // never remount the call screen (video views, controls).
    if (items.isEmpty) {
      return Stack(fit: StackFit.expand, children: [widget.child]);
    }
    final t = AppLocalizations.of(context);
    final pad = MediaQuery.paddingOf(context);
    final total = items.fold<int>(0, (s, b) => s + b.unread);
    final top = items.first;
    final shown = items.length > 3 ? 3 : items.length;
    final stack = SizedBox(
      width: 70,
      height: 62.0 + (shown - 1) * 8.0,
      child: Stack(clipBehavior: Clip.none, children: [
        for (var i = shown - 1; i >= 0; i--)
          Positioned(
            top: i * 8.0,
            right: 0,
            child: BubbleFace(
              name: items[i].name,
              photo: items[i].photo,
              photoV: items[i].photoV,
              group: items[i].isGroup,
              hideName: _hide,
              unread: i == 0 ? total : 0,
            ),
          ),
      ]),
    );
    return Stack(fit: StackFit.expand, children: [
      widget.child,
      if (_expanded) ...[
        // tap outside closes the row
        Positioned.fill(
          child: Semantics(
            button: true,
            label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
            child: GestureDetector(
              key: const Key('bbl2-call-scrim'),
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _expanded = false),
              child: const ColoredBox(color: Colors.black45),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: pad.top + Gap.sm,
          child: Material(
           type: MaterialType.transparency, // ink for the photos
           child: SizedBox(
            height: 96,
            child: ListView(
              key: const Key('bbl2-call-row'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
              children: [
                for (final b in items)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: Gap.md),
                    child: Semantics(
                      button: true,
                      label: _label(t, b),
                      excludeSemantics: true,
                      child: InkResponse(
                        key: ValueKey('bbl2-call-face-${b.key}'),
                        onTap: () => _open(b.key),
                        radius: 36,
                        child: BubbleFace(
                          name: b.name,
                          photo: b.photo,
                          photoV: b.photoV,
                          group: b.isGroup,
                          hideName: _hide,
                          unread: b.unread,
                          size: 60,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
           ),
          ),
        ),
      ] else
        PositionedDirectional(
          end: Gap.sm,
          top: pad.top + 72,
          child: Semantics(
            button: true,
            label: _label(t, top),
            hint: t.bbl2DragToClose,
            excludeSemantics: true,
            // TalkBack: the drag has a plain action too
            customSemanticsActions: {
              CustomSemanticsAction(label: t.bbl2CloseBubbles): _bus.clear,
            },
            child: Draggable<String>(
              key: const Key('bbl2-call-stack'),
              data: 'bbl2',
              feedback: Material(type: MaterialType.transparency, child: stack),
              childWhenDragging: const SizedBox(width: 70, height: 62),
              onDragStarted: () => setState(() => _dragging = true),
              onDragEnd: (_) => setState(() => _dragging = false),
              child: GestureDetector(
                onTap: () => items.length == 1
                    ? _open(top.key)
                    : setState(() => _expanded = true),
                child: stack,
              ),
            ),
          ),
        ),
      if (_dragging)
        Positioned(
          left: 0,
          right: 0,
          bottom: pad.bottom + Gap.xl,
          child: Center(
            child: DragTarget<String>(
              onAcceptWithDetails: (_) {
                _bus.clear();
                setState(() => _dragging = false);
              },
              builder: (context, cand, _) => AnimatedContainer(
                key: const Key('bbl2-call-x'),
                duration: Motion.fast,
                width: cand.isEmpty ? 64 : 80,
                height: cand.isEmpty ? 64 : 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: cand.isEmpty
                      ? Colors.black54
                      : Theme.of(context).colorScheme.error,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: const Icon(Icons.close_rounded,
                    color: Colors.white, size: 34),
              ),
            ),
          ),
        ),
    ]);
  }
}

/// The small chat window over the call (bottom sheet, ~80 % high): the
/// chat in its compact bubble form (no call buttons — a call is running),
/// and a row of the other bubbles' round photos on top to switch chats.
Future<void> showInCallChatSheet(BuildContext context, ApiClient api,
    String key, List<InCallBubble> others,
    {Future<Widget> Function(ApiClient api, String kind, int id)? build}) async {
  await showAppSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    builder: (ctx) => SizedBox(
      height: MediaQuery.sizeOf(ctx).height * 0.8,
      child: _InCallChat(api: api, initial: key, others: others, build: build),
    ),
  );
}

class _InCallChat extends StatefulWidget {
  const _InCallChat(
      {required this.api, required this.initial, required this.others, this.build});
  final ApiClient api;
  final String initial;
  final List<InCallBubble> others;
  final Future<Widget> Function(ApiClient api, String kind, int id)? build;

  @override
  State<_InCallChat> createState() => _InCallChatState();
}

class _InCallChatState extends State<_InCallChat> {
  late String _key = widget.initial;
  late Future<Widget> _screen = _load(_key);

  Future<Widget> _load(String key) {
    final p = ChatOpener.parse(key);
    if (p == null) return Future.error(StateError('bad key'));
    return (widget.build ??
            (a, k, i) => ChatOpener.buildScreen(a, k, i, bubble: true))(
        widget.api, p.kind, p.id);
  }

  void _switch(String key) {
    if (key == _key) return;
    InCallBubbles.instance.remove(key);
    setState(() {
      _key = key;
      _screen = _load(key);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = Localizations.localeOf(context).languageCode;
    return Column(children: [
      if (widget.others.length > 1)
        SizedBox(
          height: 84,
          child: ListView(
            key: const Key('bbl2-sheet-row'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.xs),
            children: [
              for (final b in widget.others)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: Gap.md),
                  child: Semantics(
                    button: true,
                    selected: b.key == _key,
                    label: t.bbl2FaceA11y(
                        b.name.isEmpty ? t.bbl2NewMessage : b.name,
                        localDigits('${b.key == _key ? 0 : b.unread}', lang)),
                    excludeSemantics: true,
                    child: InkResponse(
                      onTap: () => _switch(b.key),
                      radius: 34,
                      child: Opacity(
                        opacity: b.key == _key ? 1 : 0.7,
                        child: BubbleFace(
                          name: b.name,
                          photo: b.photo,
                          photoV: b.photoV,
                          group: b.isGroup,
                          unread: b.key == _key ? 0 : b.unread,
                          size: 52,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      Expanded(
        child: FutureBuilder<Widget>(
          key: ValueKey(_key),
          future: _screen,
          builder: (context, snap) {
            if (snap.hasData) return snap.data!;
            if (snap.hasError) {
              return Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(Gap.xl),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(t.bblCantOpen,
                        key: const Key('bbl2-sheet-error'),
                        textAlign: TextAlign.center,
                        style: AType.titleMedium),
                    const SizedBox(height: Gap.sm),
                    Text(t.bblCantOpenHow, textAlign: TextAlign.center),
                    const SizedBox(height: Gap.lg),
                    FilledButton(
                      style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
                      onPressed: () => setState(() => _screen = _load(_key)),
                      child: Text(t.retry),
                    ),
                  ]),
                ),
              );
            }
            return const Center(child: CircularProgressIndicator());
          },
        ),
      ),
    ]);
  }
}
