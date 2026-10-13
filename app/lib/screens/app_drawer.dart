import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/sidebar_sections.dart';
import 'settings_screen.dart';

/// Left sidebar — the app's navigation hub (modern AI-chat style). The main
/// screen is only the chat; everything else lives here.
///
/// Modules are grouped into collapsible [SidebarSections] (Money / Family /
/// Health / Life / Work / Business / Settings) with a search box on top, so the
/// long flat list is discoverable. Settings + profile stay pinned in the footer.
class AppDrawer extends StatefulWidget {
  final VoidCallback onNewChat;
  const AppDrawer({super.key, required this.onNewChat});

  @override
  State<AppDrawer> createState() => _AppDrawerState();
}

class _AppDrawerState extends State<AppDrawer> {
  final _searchCtrl = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _openItem(SidebarItem item) {
    Navigator.pop(context);
    Navigator.push(
        context, MaterialPageRoute(builder: (ctx) => item.builder(ctx)));
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
        // ---- new chat ----
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
                        key: PageStorageKey('sidebar_${s.title(t)}_$searching'),
                        initiallyExpanded: searching,
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
                              onTap: () => _openItem(item),
                            ),
                        ],
                      ),
                  ],
                ),
        ),
        const Divider(height: 1),
        // ---- settings + profile ----
        ListTile(
          leading: Icon(Icons.settings_outlined, color: scheme.onSurfaceVariant),
          title: Text(t.settingsTitle),
          onTap: () {
            Navigator.pop(context);
            Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()));
          },
        ),
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
        ),
        SizedBox(height: MediaQuery.of(context).padding.bottom + Gap.sm),
      ]),
    );
  }

  Widget _logoMark(double size) => ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.24),
        child: Image.asset('assets/branding/new_logo.png',
            width: size, height: size, fit: BoxFit.cover),
      );
}
