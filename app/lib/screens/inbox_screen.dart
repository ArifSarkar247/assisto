import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';

/// AI Inbox (feature 22): red/yellow/green triage. Fetching email needs Gmail
/// (owner connects it in Integrations) — clean "Available when ___" state here.
class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key});
  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  Map<String, dynamic>? _s;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _s = await context.read<AppState>().api.inboxStatus();
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final connected = _s?['connected'] == true;
    Widget legendRow(Color c, String label) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Container(width: 12, height: 12,
              decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: Gap.sm),
          Text(label),
        ]));
    return Scaffold(
      appBar: AppBar(title: Text(tr.aiInbox)),
      body: _loading
          ? const SkeletonList()
          : ListView(padding: const EdgeInsets.all(Gap.lg), children: [
              if (!connected)
                Card(
                  color: scheme.tertiaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.lg),
                    child: Row(children: [
                      Icon(Icons.mark_email_unread_outlined,
                          color: scheme.onTertiaryContainer),
                      const SizedBox(width: Gap.md),
                      Expanded(
                        child: Text(
                          tr.availableWhenGmailIsConnected,
                          style: TextStyle(color: scheme.onTertiaryContainer),
                        ),
                      ),
                    ]),
                  ),
                ),
              const SizedBox(height: Gap.lg),
              Text(tr.howAiTriages,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              const SizedBox(height: Gap.sm),
              Card(child: Padding(
                padding: const EdgeInsets.all(Gap.lg),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  legendRow(const Color(0xFFE0485A), tr.redUrgentNeedsAction),
                  legendRow(const Color(0xFFE0A500), tr.yellowReplySoon),
                  legendRow(const Color(0xFF2E9E6B), tr.greenJustInfo),
                ]),
              )),
              const SizedBox(height: Gap.md),
              Text(
                tr.onceConnectedYourEmailsAppear,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ]),
    );
  }
}
