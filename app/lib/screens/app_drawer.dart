import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/sidebar_sections.dart';
import 'settings_screen.dart';
import 'plans_screen.dart';
import 'messenger/messenger_home_screen.dart';
import 'assisto_chats_screen.dart';

/// Left sidebar — the app's navigation hub (modern AI-chat style). The main
/// screen is only the chat; everything else lives here.
///
/// Layout (owner-final): the WHOLE drawer is ONE scroll list — nothing pinned
/// below it.
///   TOP of scroll: brand header, "Assisto AI" (-> [AssistoChatsScreen]:
///     New chat + every saved chat; owner order after build 146 replaced the
///     sidebar New-chat button + growing chat list with this one entry),
///     Messages hub quick-link ([MessengerHomeScreen]), search box.
///   SECTIONS: 8 collapsible [SidebarSections] (My Circle, Reminders & Memory,
///     My Account, Family & Safety, Contacts & Profile, Daily Life, Work,
///     Business) — open/closed state is remembered across drawer opens.
///   END of scroll: Settings (In-progress / Connected apps / Battery / Legal
///     live inside it), Plans & points.
class AppDrawer extends StatefulWidget {
  /// Start a fresh HOME chat (used by the chats page's "New chat").
  final VoidCallback? onNewChat;

  /// Reopen a saved HOME conversation on the home screen (chats page rows).
  final void Function(String sessionId)? onOpenHomeChat;
  const AppDrawer({super.key, this.onNewChat, this.onOpenHomeChat});

  @override
  State<AppDrawer> createState() => _AppDrawerState();
}

class _AppDrawerState extends State<AppDrawer> {
  final _searchCtrl = TextEditingController();
  String _q = '';

  /// Persisted open/closed state per section id (survives drawer re-opens for
  /// the app session). Defaults to collapsed.
  static final Set<String> _expanded = <String>{};

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _push(WidgetBuilder builder) {
    Navigator.pop(context);
    Navigator.push(context, MaterialPageRoute(builder: builder));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    context.watch<AppState>();

    final searching = _q.trim().isNotEmpty;
    final sections = SidebarSections.filter(t, _q);

    return Drawer(
      child: Column(children: [
        // ---- brand header ----
        Container(
          width: double.infinity,
          decoration: const BoxDecoration(gradient: Brand.heroDark),
          padding: EdgeInsets.fromLTRB(Gap.lg,
              MediaQuery.of(context).padding.top + Gap.lg, Gap.lg, Gap.lg),
          child: Row(children: [
            _logoMark(44),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Assisto',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w800)),
                    Text(t.tagline,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 11)),
                  ]),
            ),
          ]),
        ),
        const SizedBox(height: Gap.sm),
        // Profile card REMOVED from the sidebar (OWNER UI FIX v2 §4) — the
        // profile now lives as a card at the top of SettingsScreen and in the
        // Messenger hub-settings. The sidebar opens straight into the quick
        // actions below.
        // ---- Assisto AI (chats page) + My Circle hub quick-link ----
        // ONE entry for all chats: the page has New chat at the top and every
        // saved chat (home + AI) below, so the sidebar never fills up.
        ListTile(
          key: const ValueKey('drawer_assisto_ai'),
          dense: true,
          leading: Icon(Icons.auto_awesome, color: scheme.primary),
          title: Text(t.aichatTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(t.p1ChatsSidebarSub,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () {
            // Capture the home hooks before the drawer closes.
            final onNew = widget.onNewChat;
            final onOpen = widget.onOpenHomeChat;
            _push((_) => AssistoChatsScreen(
                onNewHomeChat: onNew, onOpenHomeChat: onOpen));
          },
        ),
        // The ONLY entry point to the Messenger hub (Chats · Updates ·
        // Communities · Calls). Labelled "My Circle" — the old expandable
        // "My Circle" sidebar group is gone; circle management (people,
        // privacy, calls) now lives INSIDE the hub (OWNER UI FIX v2 §1–2).
        ListTile(
          dense: true,
          leading:
              Icon(Icons.diversity_3_outlined, color: scheme.onSurfaceVariant),
          title: Text(t.sidebarMyCircle),
          onTap: () => _push((_) => const MessengerHomeScreen()),
        ),
        // ---- search box ----
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.xs),
          child: TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _q = v),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 20),
              hintText: t.search,
              suffixIcon: searching
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _q = '');
                      },
                    )
                  : null,
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            ),
          ),
        ),
        const Divider(height: Gap.md),
        // ---- grouped modules ----
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: Gap.xs),
            children: [
              if (sections.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(t.sidebarNoResults,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
              for (final s in sections)
                // OWNER UI FIX: a group with exactly ONE item is NOT an
                // expandable group — render it as a single direct entry
                // (tap opens that item). Applies to every section now and
                // in future (e.g. Contacts).
                if (s.items.length == 1)
                  ListTile(
                    leading: Icon(s.icon, color: scheme.onSurfaceVariant),
                    title: Text(s.title(t),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    onTap: () => _push(s.items.first.builder),
                  )
                else
                  ExpansionTile(
                    key: PageStorageKey('sidebar_${s.id}_$searching'),
                    // Searching force-opens matches; otherwise honour the
                    // remembered open/closed state.
                    initiallyExpanded: searching || _expanded.contains(s.id),
                    onExpansionChanged: (open) {
                      if (searching) return;
                      if (open) {
                        _expanded.add(s.id);
                      } else {
                        _expanded.remove(s.id);
                      }
                    },
                    leading: Icon(s.icon, color: scheme.onSurfaceVariant),
                    title: Text(s.title(t),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    childrenPadding: const EdgeInsets.only(left: Gap.sm),
                    children: [
                      for (final item in s.items)
                        ListTile(
                          leading: Icon(item.icon,
                              color: scheme.onSurfaceVariant, size: 22),
                          title: Text(item.label(t),
                              maxLines: 2, overflow: TextOverflow.ellipsis),
                          visualDensity: VisualDensity.compact,
                          onTap: () => _push(item.builder),
                        ),
                    ],
                  ),
              // ---- END of scroll: Settings + Plans & points (moved in
              // from the old pinned bottom; nothing is pinned now) ----
              if (!searching) ...[
                const Divider(height: Gap.md),
                ListTile(
                  leading: Icon(Icons.settings_outlined,
                      color: scheme.onSurfaceVariant),
                  title: Text(t.settingsTitle),
                  onTap: () => _push((_) => const SettingsScreen()),
                ),
                ListTile(
                  leading: Icon(Icons.workspace_premium_outlined,
                      color: scheme.onSurfaceVariant),
                  title: Text(t.sidebarPlansPoints),
                  onTap: () => _push((_) => const PlansScreen()),
                ),
                SizedBox(
                    height: MediaQuery.of(context).padding.bottom + Gap.sm),
              ],
            ],
          ),
        ),
      ]),
    );
  }

  Widget _logoMark(double size) => ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.24),
        child: Image.asset('assets/branding/new_logo.png',
            width: size, height: size, fit: BoxFit.cover),
      );
}
