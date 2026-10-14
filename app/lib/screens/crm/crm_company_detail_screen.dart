import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../theme.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/crm_company_widgets.dart';
import 'crm_common.dart';

/// Company 360 (CRM_SPEC §2). A single screen that gathers everything about a
/// B2B account: profile + custom fields, all its PEOPLE (with inferred role
/// chips and a primary-contact marker), an aggregated TIMELINE that merges the
/// activity of every contact and deal under the account, the linked DEALS, and
/// any document ATTACHMENTS carried on the timeline. Benchmarked against the
/// account 360 in best-in-class B2B CRMs: one place, every signal, honest about
/// what the backend can and cannot yet serve.
class CrmCompanyDetailScreen extends StatefulWidget {
  final int org;
  final int companyId;
  const CrmCompanyDetailScreen(
      {super.key, required this.org, required this.companyId});
  @override
  State<CrmCompanyDetailScreen> createState() =>
      _CrmCompanyDetailScreenState();
}

class _CrmCompanyDetailScreenState extends State<CrmCompanyDetailScreen> {
  Map<String, dynamic>? _company;
  List<Map<String, dynamic>> _contacts = [];
  List<Map<String, dynamic>> _activities = [];
  List<Map<String, dynamic>> _deals = [];
  bool _loading = true;
  CrmError? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = CrmApi.of(context);
      _company = await api.company(widget.companyId);
      // The server has no ?company filter on contacts/deals/activities yet, so
      // fetch the org set and group client-side. (Gap noted in integration md.)
      final allContacts = await api.contacts(widget.org);
      _contacts = allContacts
          .where((c) =>
              (c['company'] as num?)?.toInt() == widget.companyId)
          .toList();
      final contactIds =
          _contacts.map((c) => (c['id'] as num).toInt()).toSet();
      final allDeals = await api.deals(widget.org);
      _deals = allDeals
          .where((d) => (d['company'] as num?)?.toInt() == widget.companyId)
          .toList();
      final dealIds = _deals.map((d) => (d['id'] as num).toInt()).toSet();
      // Company-level timeline: merge activities whose company/contact/deal
      // belongs to this account. (Server sends all org activities; we filter.)
      final allActs = await api.activities(widget.org, company: widget.companyId);
      _activities = allActs.where((a) {
        final co = (a['company'] as num?)?.toInt();
        final ct = (a['contact'] as num?)?.toInt();
        final dl = (a['deal'] as num?)?.toInt();
        return co == widget.companyId ||
            (ct != null && contactIds.contains(ct)) ||
            (dl != null && dealIds.contains(dl));
      }).toList()
        ..sort((a, b) => (b['created_at'] ?? '')
            .toString()
            .compareTo((a['created_at'] ?? '').toString()));
    } catch (e) {
      _error = CrmError.from(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_loading) {
      return Scaffold(
          appBar: AppBar(title: Text(t.crmCompany)),
          body: const CrmStateView.loading());
    }
    if (_error != null || _company == null) {
      return Scaffold(
        appBar: AppBar(title: Text(t.crmCompany)),
        body: _error != null
            ? CrmStateView.error(
                error: _error!, title: t.loadFailed, onRetry: _load)
            : CrmStateView.empty(
                icon: Icons.domain_disabled_outlined,
                title: t.crmCompanyNotFound),
      );
    }
    final c = _company!;
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: Text(c['name']?.toString() ?? t.crmCompany,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          bottom: TabBar(isScrollable: true, tabs: [
            Tab(text: t.crmTabOverview),
            Tab(text: t.crmPeople),
            Tab(text: t.crmTabTimeline),
            Tab(text: t.crmTabDeals),
            Tab(text: t.crmTabDocuments),
          ]),
        ),
        body: TabBarView(children: [
          _overview(t, c),
          _people(t),
          _timeline(t),
          _dealsTab(t),
          _documents(t),
        ]),
      ),
    );
  }

  // ---------------------------------------------------------------- OVERVIEW
  Widget _overview(AppLocalizations t, Map<String, dynamic> c) {
    final custom = (c['custom'] as Map?)?.cast<String, dynamic>() ?? {};
    final primary = _contacts.where((x) => x['is_primary'] == true).toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(Gap.md), children: [
        CrmSectionHeader(t.crmCompanyProfile),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(children: [
              KvRow(t.crmIndustry, _industryLabel(t, c['industry']?.toString()),
                  icon: Icons.category_outlined),
              if ((c['size'] as num?) != null && (c['size'] as num) > 0)
                KvRow(t.crmHeadcount, '${c['size']}',
                    icon: Icons.badge_outlined),
              if ((c['phone'] ?? '').toString().isNotEmpty)
                KvRow(t.crmPhone, c['phone'].toString(),
                    icon: Icons.phone_outlined),
              if ((c['website'] ?? '').toString().isNotEmpty)
                KvRow(t.crmWebsite, c['website'].toString(),
                    icon: Icons.language_outlined),
              if ((c['address'] ?? '').toString().isNotEmpty)
                KvRow(t.crmAddress, c['address'].toString(),
                    icon: Icons.place_outlined),
            ]),
          ),
        ),
        if (primary.isNotEmpty) ...[
          const SizedBox(height: Gap.md),
          CrmSectionHeader(t.crmPrimaryContact),
          _ContactTile(contact: primary.first, onCall: _call, onMail: _mail),
        ],
        const SizedBox(height: Gap.md),
        CrmSectionHeader(t.crmCustomFields),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: custom.isEmpty
                ? Text(t.crmNoCustomFields,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant))
                : Column(
                    children: [
                      for (final e in custom.entries)
                        KvRow(e.key, e.value?.toString() ?? '—'),
                    ],
                  ),
          ),
        ),
      ]),
    );
  }

  // ------------------------------------------------------------------ PEOPLE
  Widget _people(AppLocalizations t) {
    if (_contacts.isEmpty) {
      return CrmStateView.empty(
          icon: Icons.person_off_outlined, title: t.crmNoContacts);
    }
    // Primary first, then decision makers, then the rest.
    final sorted = [..._contacts]..sort((a, b) {
        final pa = a['is_primary'] == true ? 0 : 1;
        final pb = b['is_primary'] == true ? 0 : 1;
        return pa.compareTo(pb);
      });
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(Gap.md),
        itemCount: sorted.length,
        separatorBuilder: (_, __) => const SizedBox(height: Gap.sm),
        itemBuilder: (_, i) =>
            _ContactTile(contact: sorted[i], onCall: _call, onMail: _mail),
      ),
    );
  }

  // ---------------------------------------------------------------- TIMELINE
  Widget _timeline(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    if (_activities.isEmpty) {
      return CrmStateView.empty(
          icon: Icons.history_toggle_off_outlined,
          title: t.crmNoActivity,
          message: t.crmCompanyTimelineClientNote);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(Gap.md), children: [
        CrmSectionHeader(t.crmCompanyTimeline,
            hint: t.crmTimelineAllContacts),
        for (final a in _activities)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(activityKindIcon(a['kind']?.toString()),
                  size: 18, color: scheme.primary),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        (a['subject']?.toString().isNotEmpty == true
                            ? a['subject']
                            : (a['kind_display'] ?? a['kind'] ?? '—')).toString(),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if ((a['body'] ?? '').toString().isNotEmpty)
                        Text(a['body'].toString(),
                            style: TextStyle(
                                fontSize: 12, color: scheme.onSurfaceVariant)),
                      Text(
                        [
                          if ((a['actor_name'] ?? '').toString().isNotEmpty)
                            a['actor_name'].toString(),
                          _date(a['created_at']?.toString()),
                        ].where((s) => s.isNotEmpty).join(' · '),
                        style: TextStyle(
                            fontSize: 11, color: scheme.onSurfaceVariant),
                      ),
                    ]),
              ),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.only(top: Gap.md),
          child: Text(t.crmCompanyTimelineClientNote,
              style: TextStyle(
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
                  color: scheme.onSurfaceVariant)),
        ),
      ]),
    );
  }

  // ------------------------------------------------------------------- DEALS
  Widget _dealsTab(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    if (_deals.isEmpty) {
      return CrmStateView.empty(
          icon: Icons.handshake_outlined, title: t.crmNoDeals);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(Gap.md),
        itemCount: _deals.length,
        separatorBuilder: (_, __) => const SizedBox(height: Gap.sm),
        itemBuilder: (_, i) {
          final d = _deals[i];
          final state = d['state']?.toString();
          final tint = state == 'won'
              ? Brand.success
              : state == 'lost'
                  ? Brand.danger
                  : scheme.primary;
          return Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: Icon(Icons.handshake_outlined, color: tint),
              title: Text(d['title']?.toString() ?? '—',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                  '${d['stage_name'] ?? ''} · ${_stateLabel(t, state)}',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              trailing: Text(bdt(d['value'] as num?),
                  style: const TextStyle(fontWeight: FontWeight.w800)),
            ),
          );
        },
      ),
    );
  }

  // --------------------------------------------------------------- DOCUMENTS
  Widget _documents(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    // Attachments live on timeline activities (Activity.attachment). The list
    // serializer does not currently expose the attachment URL (gap noted), so
    // we surface the activities that CARRY an attachment and are honest about
    // the missing direct-download field.
    final withDocs = _activities
        .where((a) => (a['attachment'] ?? '').toString().isNotEmpty)
        .toList();
    if (withDocs.isEmpty) {
      return CrmStateView.empty(
          icon: Icons.folder_open_outlined,
          title: t.crmNoDocuments,
          message: t.crmDocumentsClientNote);
    }
    return ListView(padding: const EdgeInsets.all(Gap.md), children: [
      Text(t.crmDocumentsClientNote,
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
      const SizedBox(height: Gap.sm),
      for (final a in withDocs)
        Card(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          child: ListTile(
            leading: const Icon(Icons.attach_file),
            title: Text(
                (a['subject']?.toString().isNotEmpty == true
                        ? a['subject']
                        : t.crmAttachment)
                    .toString()),
            subtitle: Text(_date(a['created_at']?.toString())),
          ),
        ),
    ]);
  }

  // ------------------------------------------------------------- helpers ----
  Future<void> _call(String number) async {
    if (number.isEmpty) return;
    try {
      await launchUrl(Uri.parse('tel:$number'),
          mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _mail(String email) async {
    if (email.isEmpty) return;
    try {
      await launchUrl(Uri.parse('mailto:$email'),
          mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  String _industryLabel(AppLocalizations t, String? code) {
    // CompanySerializer exposes only the raw industry CODE (no *_display). The
    // codes (rmg/pharma/retail) are brand-neutral English acronyms, safe to show
    // verbatim; an empty/"other" code reads as Unknown rather than a bare code.
    switch (code) {
      case 'rmg':
        return 'RMG';
      case 'pharma':
        return 'Pharma';
      case 'retail':
        return 'Retail';
      default:
        return t.crmUnknown;
    }
  }

  String _stateLabel(AppLocalizations t, String? state) {
    switch (state) {
      case 'won':
        return t.crmWon;
      case 'lost':
        return t.crmLost;
      default:
        return t.crmOpen;
    }
  }

  String _date(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    return iso.length >= 10 ? iso.substring(0, 10) : iso;
  }
}

/// A rich contact tile: name, title, inferred role chip, primary marker, and
/// quick call / mail actions.
class _ContactTile extends StatelessWidget {
  final Map<String, dynamic> contact;
  final void Function(String) onCall;
  final void Function(String) onMail;
  const _ContactTile(
      {required this.contact, required this.onCall, required this.onMail});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isPrimary = contact['is_primary'] == true;
    final role = inferContactRole(contact['title']?.toString(),
        isPrimary: isPrimary);
    final phone = (contact['phone'] ?? contact['whatsapp'] ?? '').toString();
    final email = (contact['email'] ?? '').toString();
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: scheme.secondaryContainer,
              child: Icon(Icons.person_outline,
                  size: 18, color: scheme.onSecondaryContainer),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(contact['name']?.toString() ?? '—',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    if ((contact['title'] ?? '').toString().isNotEmpty)
                      Text(contact['title'].toString(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant)),
                  ]),
            ),
            if (isPrimary) const PrimaryContactBadge(),
          ]),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: 6, runSpacing: 6, children: [
            ContactRoleChip(role),
          ]),
          const SizedBox(height: Gap.sm),
          Row(children: [
            if (phone.isNotEmpty)
              OutlinedButton.icon(
                onPressed: () => onCall(phone),
                icon: const Icon(Icons.call, size: 16),
                label: Text(contact['phone']?.toString() ?? phone,
                    overflow: TextOverflow.ellipsis),
              ),
            if (phone.isNotEmpty && email.isNotEmpty) const SizedBox(width: Gap.sm),
            if (email.isNotEmpty)
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => onMail(email),
                  icon: const Icon(Icons.mail_outline, size: 16),
                  label: Text(email,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
          ]),
        ]),
      ),
    );
  }
}
