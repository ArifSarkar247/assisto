import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/sidebar_sections.dart';
import 'settings_screen.dart';
import 'plans_screen.dart';
import 'messenger/messenger_home_screen.dart';

/// Left sidebar — the app's navigation hub (modern AI-chat style). The main
/// screen is only the chat; everything else lives here.
///
/// Layout (owner-final): the WHOLE drawer is ONE scroll list — nothing pinned
/// below it.
///   TOP of scroll: brand header, profile card (name + phone), New chat,
///     Messages hub quick-link ([MessengerHomeScreen]), search box.
///   SECTIONS: 8 collapsible [SidebarSections] (My Circle, Reminders & Memory,
///     My Account, Family & Safety, Contacts & Profile, Daily Life, Work,
///     Business) — open/closed state is remembered across drawer opens.
///   END of scroll: Settings (In-progress / Connected apps / Battery / Legal
///     live inside it), Plans & points.
class AppDrawer extends StatefulWidget {
  final VoidCallback onNewChat;
  const AppDrawer({super.key, required this.onNewChat});

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
    final app = context.watch<AppState>();
    final u = app.user;

    final searching = _q.trim().isNotEmpty;
    final sections = SidebarSections.filter(t, _q);

    return Drawer(
      child: Column(children: [
        // ---- brand header ----
        Container(
          width: double.infinity,
          decoration: const BoxDecoration(gradient: Brand.heroDark),
          padding: EdgeInsets.fromLTRB(
              Gap.lg, MediaQuery.of(context).padding.top + Gap.lg, Gap.lg, Gap.lg),
          child: Row(children: [
            _logoMark(44),
            const SizedBox(width: Gap.md),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Assisto',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800)),
              Text(t.tagline,
                  style: const TextStyle(color: Colors.white70, fontSize: 11)),
            ]),
          ]),
        ),
        const SizedBox(height: Gap.sm),
        // ---- TOP of scroll: profile card (moved up from the old pinned
        // bottom) under the logo for a cleaner layout ----
        ListTile(
          leading: CircleAvatar(
            radius: 16,
            backgroundColor: scheme.primaryContainer,
            child: Text(
              (u?.name.isNotEmpty == true ? u!.name[0] : 'A').toUpperCase(),
              style: TextStyle(
                  color: scheme.onPrimaryContainer, fontWeight: FontWeight.w700),
            ),
          ),
          title: Text(u?.name.isNotEmpty == true ? u!.name : 'Assisto',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [u?.phone, u?.email].where((e) => e != null && e!.isNotEmpty).join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => _push((_) => const SettingsScreen()),
        ),
        // ---- new chat + Messages hub quick-link ----
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.md),
          child: FilledButton.tonalIcon(
            onPressed: () {
              Navigator.pop(context);
              widget.onNewChat();
            },
            icon: const Icon(Icons.add_comment_outlined, size: 20),
            label: Row(children: [Text(t.newChat), const Spacer()]),
            style: FilledButton.styleFrom(
              alignment: Alignment.centerLeft,
              minimumSize: const Size.fromHeight(46),
            ),
          ),
        ),
        const SizedBox(height: Gap.xs),
        // The ONLY entry point to the Messenger hub (Chats · Updates ·
        // Communities · Calls). The "My Circle" sidebar group is separate.
        ListTile(
          dense: true,
          leading: Icon(Icons.forum_outlined, color: scheme.onSurfaceVariant),
          title: Text(t.msgrTitle),
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
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12)),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            ),
          ),
        ),
        const Divider(height: Gap.md),
        // ---- grouped modules ----
        Expanded(
          child: sections.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(t.sidebarNoResults,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                  children: [
                    for (final s in sections)
                      ExpansionTile(
                        key: PageStorageKey('sidebar_${s.id}_$searching'),
                        // Searching force-opens matches; otherwise honour the
                        // remembered open/closed state.
                        initiallyExpanded:
                            searching || _expanded.contains(s.id),
                        onExpansionChanged: (open) {
                          if (searching) return;
                          if (open) {
                            _expanded.add(s.id);
                          } else {
                            _expanded.remove(s.id);
                          }
                        },
                        leading:
                            Icon(s.icon, color: scheme.onSurfaceVariant),
                        title: Text(s.title(t),
                            style: const TextStyle(
                                fontWeight: FontWeight.w600)),
                        childrenPadding:
                            const EdgeInsets.only(left: Gap.sm),
                        children: [
                          for (final item in s.items)
                            ListTile(
                              leading: Icon(item.icon,
                                  color: scheme.onSurfaceVariant, size: 22),
                              title: Text(item.label(t)),
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
                          height: MediaQuery.of(context).padding.bottom +
                              Gap.sm),
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
