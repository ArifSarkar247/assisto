import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/skeleton.dart';
import '../widgets/support_widgets.dart';
import 'legal_screen.dart';

/// IN-APP SUPPORT CENTER (#181, SPEC v2.1 §21, advanced).
///
/// Two tabs:
///   • Get help — categorized issue submission (Help / Bug / Account /
///     Payment), self-help FAQ, and a contact fallback (email + legal/help).
///   • My tickets — the user's own submitted tickets with an honest status
///     (open / answered / resolved), loaded from `GET /support/`, with the
///     full loading → empty → error+retry state machine.
///
/// Persistence uses the EXISTING support endpoint set (ApiClient.listItems /
/// createItem against the `support` collection -> SupportViewSet). To store a
/// richer per-ticket category beyond the backend's current {support,bug} kinds,
/// the integrator can add a `category` field — see
/// .phaseB/up_support_integration.md. Until then the extra categories are
/// folded into the message body so nothing is silently dropped (honest).
class SupportCenterScreen extends StatelessWidget {
  const SupportCenterScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.supportCenterTitle),
          bottom: TabBar(tabs: [
            Tab(text: t.supportTabGetHelp),
            Tab(text: t.supportTabMyTickets),
          ]),
        ),
        body: const TabBarView(children: [
          _GetHelpTab(),
          _MyTicketsTab(),
        ]),
      ),
    );
  }
}

// ----------------------------------------------------------------- Get help

/// Categories offered for a new ticket. The first two map directly to the
/// backend `kind`; account/payment are sent as kind='support' with a tagged
/// body (see _submit) until a dedicated `category` field exists.
enum _Category { help, bug, account, payment }

class _GetHelpTab extends StatefulWidget {
  const _GetHelpTab();
  @override
  State<_GetHelpTab> createState() => _GetHelpTabState();
}

class _GetHelpTabState extends State<_GetHelpTab> {
  final _msg = TextEditingController();
  _Category _cat = _Category.help;
  bool _sending = false;
  bool _sent = false;
  String? _error;

  @override
  void dispose() {
    _msg.dispose();
    super.dispose();
  }

  String _kindFor(_Category c) =>
      c == _Category.bug ? 'bug' : 'support';

  String _catLabel(AppLocalizations t, _Category c) => switch (c) {
        _Category.help => t.supportCatHelp,
        _Category.bug => t.supportCatBug,
        _Category.account => t.supportCatAccount,
        _Category.payment => t.supportCatPayment,
      };

  Future<void> _submit() async {
    final text = _msg.text.trim();
    if (text.isEmpty || _sending) return;
    final t = AppLocalizations.of(context);
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      String appVersion = AppConfig.appVersionLabel;
      try {
        final info = await PackageInfo.fromPlatform();
        if (info.version.isNotEmpty) {
          appVersion = '${info.version}+${info.buildNumber}';
        }
      } catch (_) {}

      // Fold the category into the message so no choice is silently lost until
      // a dedicated `category` field is wired by the integrator.
      final body = (_cat == _Category.account || _cat == _Category.payment)
          ? '[${_catLabel(t, _cat)}] $text'
          : text;

      await context.read<AppState>().api.createItem('support', {
        'kind': _kindFor(_cat),
        'message': body,
        'app_version': appVersion,
      });
      if (!mounted) return;
      setState(() {
        _sent = true;
        _msg.clear();
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _contactEmail() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final uri = Uri(
      scheme: 'mailto',
      path: t.supportContactEmail,
      query: 'subject=${Uri.encodeComponent(t.supportCenterTitle)}',
    );
    var ok = false;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!ok) {
      messenger.showSnackBar(SnackBar(content: Text(t.supportContactFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    if (_sent) {
      return StateMessage(
        icon: Icons.check_circle_outline,
        title: t.supportSentTitle,
        message: t.supportSentBody,
        tint: Brand.success,
        action: FilledButton(
          onPressed: () => setState(() => _sent = false),
          child: Text(t.supportSendAnother),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(Gap.lg),
      children: [
        // --- categorized submission ---
        Text(t.supportNewRequest,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.sm),
        Wrap(
          spacing: Gap.sm,
          runSpacing: Gap.xs,
          children: [
            for (final c in _Category.values)
              ChoiceChip(
                label: Text(_catLabel(t, c)),
                selected: _cat == c,
                onSelected: (_) => setState(() => _cat = c),
              ),
          ],
        ),
        const SizedBox(height: Gap.md),
        TextField(
          controller: _msg,
          maxLines: 5,
          textInputAction: TextInputAction.newline,
          decoration: InputDecoration(
            labelText: t.supportMessageLabel,
            hintText: t.supportMessageHint,
            alignLabelWithHint: true,
            border: const OutlineInputBorder(),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: Gap.sm),
          Text(t.supportSendFailed(_error!),
              style: const TextStyle(color: Brand.danger, fontSize: 13)),
        ],
        const SizedBox(height: Gap.md),
        FilledButton.icon(
          onPressed: _sending ? null : _submit,
          icon: _sending
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.send_outlined),
          label: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(_sending ? t.supportSending : t.supportSend),
          ),
        ),
        const SizedBox(height: Gap.xl),

        // --- self-help FAQ ---
        Text(t.supportSelfHelp,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.sm),
        FaqTile(question: t.supportFaqRemindersQ, answer: t.supportFaqRemindersA),
        const SizedBox(height: Gap.sm),
        FaqTile(question: t.supportFaqBackupQ, answer: t.supportFaqBackupA),
        const SizedBox(height: Gap.sm),
        FaqTile(question: t.supportFaqAccountQ, answer: t.supportFaqAccountA),
        const SizedBox(height: Gap.xl),

        // --- contact fallback ---
        Text(t.supportContactTitle,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.sm),
        Card(
          margin: EdgeInsets.zero,
          child: Column(children: [
            ListTile(
              leading: Icon(Icons.email_outlined, color: scheme.primary),
              title: Text(t.supportContactEmailTitle),
              subtitle: Text(t.supportContactEmail),
              trailing: const Icon(Icons.open_in_new, size: 18),
              onTap: _contactEmail,
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.gavel_outlined, color: scheme.primary),
              title: Text(t.supportContactLegal),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const LegalScreen())),
            ),
          ]),
        ),
      ],
    );
  }
}

// ----------------------------------------------------------------- My tickets

class _MyTicketsTab extends StatefulWidget {
  const _MyTicketsTab();
  @override
  State<_MyTicketsTab> createState() => _MyTicketsTabState();
}

class _MyTicketsTabState extends State<_MyTicketsTab> {
  List<Map<String, dynamic>> _tickets = [];
  bool _loading = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final rows = await context.read<AppState>().api.listItems('support');
      if (!mounted) return;
      setState(() {
        _tickets = rows;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = true;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_loading) return const SkeletonList();
    if (_error) {
      return StateMessage(
        icon: Icons.cloud_off_outlined,
        title: t.supportTicketsErrorTitle,
        message: t.supportTicketsErrorBody,
        tint: Brand.warning,
        action: FilledButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh),
          label: Text(t.updateRetry),
        ),
      );
    }
    if (_tickets.isEmpty) {
      return StateMessage(
        icon: Icons.inbox_outlined,
        title: t.supportTicketsEmptyTitle,
        message: t.supportTicketsEmptyBody,
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(Gap.lg),
        itemCount: _tickets.length,
        separatorBuilder: (_, __) => const SizedBox(height: Gap.md),
        itemBuilder: (_, i) => TicketCard(ticket: _tickets[i]),
      ),
    );
  }
}
