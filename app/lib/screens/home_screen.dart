import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../updater.dart';
import '../theme.dart';
import 'agent_thread_screen.dart';
import 'app_drawer.dart';
import '../l10n/app_localizations.dart';

/// The app is chat-first: the home is only the conversation. Everything else
/// lives in the left drawer (opened via the ☰ button). No bottom nav.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Changing this key starts a fresh chat (New chat).
  Key _threadKey = UniqueKey();

  void _newChat() => setState(() => _threadKey = UniqueKey());

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.asset('assets/branding/new_logo.png',
                width: 30, height: 30, fit: BoxFit.cover),
          ),
          const SizedBox(width: Gap.sm),
          const Text('Assisto', style: TextStyle(fontWeight: FontWeight.w800)),
        ]),
        actions: [
          IconButton(
            tooltip: t.newChat,
            onPressed: _newChat,
            icon: const Icon(Icons.add_comment_outlined),
          ),
          const SizedBox(width: Gap.xs),
        ],
      ),
      drawer: AppDrawer(onNewChat: _newChat),
      body: Column(children: [
        const _UpdateBanner(),
        Expanded(child: AgentThreadScreen(key: _threadKey)),
      ]),
    );
  }
}

class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner();
  @override
  Widget build(BuildContext context) {
    final up = context.watch<Updater>();
    if (up.available == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final t = AppLocalizations.of(context);
    return Material(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.sm, Gap.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.system_update, color: scheme.onPrimaryContainer, size: 20),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(t.updateAvailable,
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: scheme.onPrimaryContainer)),
              ),
              if (!up.downloading)
                IconButton(
                    onPressed: up.dismiss,
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.close, size: 18, color: scheme.onPrimaryContainer)),
            ]),
            if (up.downloading) ...[
              const SizedBox(height: Gap.xs),
              LinearProgressIndicator(value: up.progress > 0 ? up.progress : null),
              const SizedBox(height: Gap.xs),
              Text('${(up.progress * 100).toStringAsFixed(0)}%',
                  style: TextStyle(fontSize: 12, color: scheme.onPrimaryContainer)),
            ] else
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: up.downloadAndInstall,
                  icon: const Icon(Icons.download, size: 18),
                  label: Text(t.update),
                ),
              ),
            if (up.error != null)
              Text('${up.error}',
                  style: TextStyle(color: scheme.error, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
