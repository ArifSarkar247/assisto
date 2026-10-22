import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import 'chatnav.dart';

/// One shortcut the user can pin to home. Backed by a stable [ChatNav] route
/// key (never a screen class), with the module's existing sidebar label/icon.
class QuickShortcut {
  final String route;
  final IconData icon;
  final String Function(AppLocalizations t) label;
  const QuickShortcut(this.route, this.icon, this.label);
}

/// Six customizable one-tap shortcuts on home (owner order). The user picks
/// which six and their order; the choice is saved on the device.
class HomeQuickButtons {
  static const prefsKey = 'home_quick_v1';
  static const count = 6;
  static const defaults = [
    'reminders',
    'money',
    'notes',
    'ai_chat',
    'family',
    'documents'
  ];

  /// Everything that can be pinned (a curated, everyday subset of modules).
  static final List<QuickShortcut> catalog = [
    QuickShortcut('reminders', Icons.alarm_outlined, (t) => t.navReminders),
    QuickShortcut(
        'money', Icons.account_balance_wallet_outlined, (t) => t.moduleMoney),
    QuickShortcut('notes', Icons.checklist_outlined, (t) => t.navNotesTasks),
    QuickShortcut('ai_chat', Icons.auto_awesome_outlined, (t) => t.aichatTitle),
    QuickShortcut('family', Icons.diversity_1_outlined, (t) => t.moduleFamily),
    QuickShortcut('documents', Icons.lock_outline, (t) => t.moduleVault),
    QuickShortcut(
        'emergency', Icons.emergency_outlined, (t) => t.moduleEmergency),
    QuickShortcut('safety', Icons.shield_outlined, (t) => t.safetyTitle),
    QuickShortcut('budget', Icons.pie_chart_outline, (t) => t.budgetTitle),
    QuickShortcut('money_voice', Icons.mic_none_outlined, (t) => t.mvoiceTitle),
    QuickShortcut('photo_enhance', Icons.auto_fix_high_outlined,
        (t) => t.b2PhotoStudioTitle), // b2: opens Photo Studio
    QuickShortcut('birthdays', Icons.cake_outlined, (t) => t.birthdaysTitle),
    QuickShortcut('meetings', Icons.event_outlined, (t) => t.meetingsTitle),
    QuickShortcut('memory', Icons.psychology_outlined, (t) => t.navMemory),
    QuickShortcut('contacts', Icons.contacts_outlined, (t) => t.contactsTitle),
    QuickShortcut(
        'medicine_db', Icons.medication_outlined, (t) => t.medicineDbTitle),
    QuickShortcut(
        'health_tips', Icons.favorite_outline, (t) => t.healthTipsTitle),
    QuickShortcut('nearby', Icons.place_outlined, (t) => t.sidebarNearby),
    QuickShortcut('journey', Icons.route_outlined, (t) => t.journeyHubTitle),
    QuickShortcut('scam', Icons.gpp_maybe_outlined, (t) => t.scamTitle),
    QuickShortcut(
        'my_lost_phone', Icons.travel_explore_outlined, (t) => t.mlpTitle),
    QuickShortcut('phone_safety', Icons.phonelink_lock_outlined,
        (t) => t.phoneSafetyTitle),
    QuickShortcut(
        'vehicles', Icons.directions_car_outlined, (t) => t.vehiclesTitle),
    QuickShortcut('subscriptions', Icons.autorenew, (t) => t.subscriptions),
    QuickShortcut('tax', Icons.receipt_long_outlined, (t) => t.taxTitle),
    QuickShortcut(
        'wrapped', Icons.auto_awesome_outlined, (t) => t.wrappedTitle),
    QuickShortcut(
        'business', Icons.storefront_outlined, (t) => t.sidebarBusiness),
    QuickShortcut('crm', Icons.handshake_outlined, (t) => t.crmTitle),
    QuickShortcut('shop_box', Icons.videocam_outlined, (t) => t.shopBoxTitle),
    QuickShortcut('inbox', Icons.mark_email_unread_outlined, (t) => t.aiInbox),
    QuickShortcut('jobs', Icons.work_outline, (t) => t.jobHunter),
    QuickShortcut('dictionary', Icons.translate, (t) => t.dictionaryTitle),
  ];

  static QuickShortcut? byRoute(String r) {
    for (final s in catalog) {
      if (s.route == r) return s;
    }
    return null;
  }

  /// Saved choice, cleaned: only known routes, no duplicates, exactly 6
  /// (topped up from the defaults if the saved list is short or stale).
  static List<String> sanitize(List<String> saved) {
    final out = <String>[];
    for (final r in [...saved, ...defaults]) {
      if (out.length == count) break;
      if (!out.contains(r) &&
          byRoute(r) != null &&
          ChatNav.routes.containsKey(r)) {
        out.add(r);
      }
    }
    return out;
  }

  /// Last OWNER default fetched from the server (GET /app/home-defaults),
  /// cached so the next cold start paints it without waiting on the network.
  static const serverPrefsKey = 'home_quick_server_v1';

  static Future<List<String>?> _readList(String key) async {
    try {
      final raw = await Settings.getString(key);
      if (raw == null || raw.isEmpty) return null;
      return (jsonDecode(raw) as List).map((e) => '$e').toList();
    } catch (_) {
      return null;
    }
  }

  /// True once the user saved their own choice (prefs key present).
  static Future<bool> isCustomized() async =>
      (await _readList(prefsKey)) != null;

  /// The default for a user who has not customized: the cached owner default
  /// when we have one, else the shipped [defaults].
  static Future<List<String>> ownerDefault() async {
    final cached = await _readList(serverPrefsKey);
    return cached == null ? List.of(defaults) : sanitize(cached);
  }

  /// What home shows: the user's own six, else the owner default.
  static Future<List<String>> load() async {
    final own = await _readList(prefsKey);
    if (own != null) return sanitize(own);
    return ownerDefault();
  }

  static Future<void> save(List<String> routes) =>
      Settings.setString(prefsKey, jsonEncode(sanitize(routes)));

  /// Fetch the owner default via [fetch] (the `/app/home-defaults` JSON),
  /// cache it, and return the routes home should now show — or null when
  /// nothing changes (user customized, bad payload, or network error).
  /// Never throws; home always painted the hardcoded/cached list first.
  static Future<List<String>?> refreshOwnerDefault(
      Future<Map<String, dynamic>> Function() fetch) async {
    try {
      final res = await fetch();
      final raw = res['quick_buttons'];
      if (raw is! List || raw.isEmpty) return null;
      final routes = sanitize(raw.map((e) => '$e').toList());
      await Settings.setString(serverPrefsKey, jsonEncode(routes));
      if (await isCustomized()) return null;
      return routes;
    } catch (_) {
      return null;
    }
  }
}

/// The home strip of the 6 shortcuts. [compact] = one scrollable chip row
/// (while a conversation is on screen); otherwise a 3×2 grid of tiles.
class HomeQuickBar extends StatefulWidget {
  final bool compact;

  /// Preview/screenshot seed (skips SharedPreferences).
  final List<String>? debugRoutes;
  const HomeQuickBar({super.key, this.compact = false, this.debugRoutes});

  @override
  State<HomeQuickBar> createState() => _HomeQuickBarState();
}

class _HomeQuickBarState extends State<HomeQuickBar> {
  List<String> _routes = HomeQuickButtons.defaults;
  List<String> _ownerDefault = HomeQuickButtons.defaults;

  @override
  void initState() {
    super.initState();
    if (widget.debugRoutes != null) {
      _routes = HomeQuickButtons.sanitize(widget.debugRoutes!);
    } else {
      // Hardcoded defaults paint first; prefs/cache, then the server owner
      // default, swap in afterwards. Nothing here can block or crash home.
      _loadThenRefresh();
    }
  }

  Future<void> _loadThenRefresh() async {
    final local = await HomeQuickButtons.load();
    final owner = await HomeQuickButtons.ownerDefault();
    if (!mounted) return;
    setState(() {
      _routes = local;
      _ownerDefault = owner;
    });
    Future<Map<String, dynamic>> Function()? fetch;
    try {
      fetch = context.read<AppState>().api.homeDefaults;
    } catch (_) {
      return; // no AppState (previews/tests)
    }
    final fresh = await HomeQuickButtons.refreshOwnerDefault(fetch);
    final cached = await HomeQuickButtons.ownerDefault();
    if (!mounted) return;
    setState(() {
      _ownerDefault = cached;
      if (fresh != null) _routes = fresh;
    });
  }

  Future<void> _edit() async {
    HapticFeedback.selectionClick();
    final picked = await showQuickButtonsPicker(context, _routes,
        resetTo: _ownerDefault);
    if (picked == null || !mounted) return;
    setState(() => _routes = HomeQuickButtons.sanitize(picked));
    await HomeQuickButtons.save(_routes);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final items = _routes
        .map(HomeQuickButtons.byRoute)
        .whereType<QuickShortcut>()
        .toList();
    if (widget.compact) {
      return SizedBox(
        height: 44,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: Gap.md),
          children: [
            for (final s in items)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: Gap.xs),
                child: ActionChip(
                  avatar: Icon(s.icon, size: 18),
                  label: Text(s.label(t),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  onPressed: () => ChatNav.push(context, s.route),
                ),
              ),
            IconButton(
              tooltip: t.quickEdit,
              onPressed: _edit,
              icon: const Icon(Icons.tune, size: 20),
            ),
          ],
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: Text(t.quickTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
        ),
        TextButton.icon(
          onPressed: _edit,
          icon: const Icon(Icons.tune, size: 18),
          label: Text(t.quickEdit),
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
        ),
      ]),
      GridView(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: Gap.sm,
          crossAxisSpacing: Gap.sm,
          // tile height follows the font size: icon + 2 label lines never clip
          mainAxisExtent: math.max(67.0,
              40 + 28 * math.min(1.2, MediaQuery.textScalerOf(context).scale(1))),
        ),
        // Labels cap at 1.2x so a word never breaks mid-word in a 1/3-width
        // tile (large-font QA); the tile itself still grows with the font.
        children: [
          for (final s in items)
            MediaQuery.withClampedTextScaling(
                maxScaleFactor: 1.2, child: _tile(context, t, s))
        ],
      ),
    ]);
  }

  Widget _tile(BuildContext context, AppLocalizations t, QuickShortcut s) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(Radii.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: () => ChatNav.push(context, s.route),
        onLongPress: _edit,
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(s.icon, size: 22, color: scheme.primary),
            const SizedBox(height: 4),
            Text(s.label(t),
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12, height: 1.15, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
}

/// Bottom sheet to choose + order the 6 home shortcuts. Returns the new list,
/// or null when cancelled.
Future<List<String>?> showQuickButtonsPicker(
    BuildContext context, List<String> current,
    {List<String>? resetTo}) {
  return showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => QuickButtonsPicker(current: current, resetTo: resetTo),
  );
}

/// The picker body (public so the screenshot gallery can render it).
class QuickButtonsPicker extends StatefulWidget {
  final List<String> current;

  /// What "Reset" restores — the owner default (falls back to shipped).
  final List<String>? resetTo;
  const QuickButtonsPicker({super.key, required this.current, this.resetTo});
  @override
  State<QuickButtonsPicker> createState() => QuickButtonsPickerState();
}

class QuickButtonsPickerState extends State<QuickButtonsPicker> {
  late final List<String> _sel = List.of(widget.current);
  String _q = '';

  void _toggle(String r) {
    setState(() {
      if (_sel.contains(r)) {
        _sel.remove(r);
      } else if (_sel.length < HomeQuickButtons.count) {
        _sel.add(r);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final q = _q.trim().toLowerCase();
    final options = HomeQuickButtons.catalog
        .where((s) => q.isEmpty || s.label(t).toLowerCase().contains(q))
        .toList();
    final full = _sel.length == HomeQuickButtons.count;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.85,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.quickPickTitle,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(t.quickPickHint(_sel.length),
                  style:
                      TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
            ]),
          ),
          // chosen, in order — drag to reorder
          SizedBox(
            height: 52,
            child: ReorderableListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Gap.md),
              onReorderItem: (a, b) =>
                  setState(() => _sel.insert(b, _sel.removeAt(a))),
              children: [
                for (final r in _sel)
                  Padding(
                    key: ValueKey('sel_$r'),
                    padding: const EdgeInsetsDirectional.only(end: Gap.xs),
                    child: InputChip(
                      avatar: Icon(HomeQuickButtons.byRoute(r)!.icon, size: 18),
                      label: Text(HomeQuickButtons.byRoute(r)!.label(t)),
                      onDeleted: () => _toggle(r),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.xs),
            child: TextField(
              onChanged: (v) => setState(() => _q = v),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: t.search,
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          Expanded(
            child: ListView(children: [
              for (final s in options)
                CheckboxListTile(
                  value: _sel.contains(s.route),
                  onChanged: (!_sel.contains(s.route) && full)
                      ? null
                      : (_) => _toggle(s.route),
                  secondary: Icon(s.icon, color: scheme.primary),
                  title: Text(s.label(t),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  dense: true,
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.sm),
            child: Row(children: [
              TextButton(
                onPressed: () => setState(() {
                  _sel
                    ..clear()
                    ..addAll(HomeQuickButtons.sanitize(
                        widget.resetTo ?? HomeQuickButtons.defaults));
                }),
                child: Text(t.quickReset),
              ),
              const Spacer(),
              FilledButton(
                onPressed:
                    full ? () => Navigator.pop(context, List.of(_sel)) : null,
                child: Text(t.aichatSave),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
