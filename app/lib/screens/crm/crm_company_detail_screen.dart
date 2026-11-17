import 'package:flutter/material.dart';
import '../../ds/ds.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset;
import '../../widgets/ladder_common.dart' show fmtInt;
import '../../l10n/app_localizations.dart';
import '../../widgets/crm_company_widgets.dart';
import 'crm_common.dart';
import '../../services/action_feedback.dart'; // db1

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
                icon: Icons.domain_disabled_rounded,
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
          // scrollable tabs size to their label: nothing cut at any font size
          bottom: TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
            Tab(child: Text(t.crmTabOverview, softWrap: false)),
            Tab(child: Text(t.crmPeople, softWrap: false)),
            Tab(child: Text(t.crmTabTimeline, softWrap: false)),
            Tab(child: Text(t.crmTabDeals, softWrap: false)),
            Tab(child: Text(t.crmTabDocuments, softWrap: false)),
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

  /// The company at a glance: the soft DS hero — industry bubble, name, and
  /// the real counts (contacts, deals and their total value).
  Widget _hero(AppLocalizations t, Map<String, dynamic> c) {
    final ds = Theme.of(context).colorScheme.ds;
    final dealTotal = _deals.fold<num>(0, (a, d) => a + ((d['value'] as num?) ?? 0));
    return DsHeroCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          DsAvatar(
              size: 48,
              child: Icon(industryIcon(c['industry']?.toString()), color: ds.primaryInk)),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c['name']?.toString() ?? t.crmCompany,
                  style: AType.titleLarge.copyWith(color: ds.text, fontWeight: FontWeight.w800)),
              Text(_industryLabel(t, c['industry']?.toString()),
                  style: AType.bodyMedium.copyWith(color: ds.muted)),
            ]),
          ),
        ]),
        const SizedBox(height: Gap.md),
        Wrap(spacing: Gap.xl, runSpacing: Gap.sm, children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            DsNumber(fmtInt(context, _contacts.length), small: true),
            Text(t.crmPeople, style: AType.bodySmall.copyWith(color: ds.muted)),
          ]),
          if (_deals.isNotEmpty)
            Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              DsNumber(bdt(context, dealTotal), small: true),
              Text('${t.crmTabDeals} · ${fmtInt(context, _deals.length)}',
                  style: AType.bodySmall.copyWith(color: ds.muted)),
            ]),
        ]),
      ]),
    );
  }

  // ---------------------------------------------------------------- OVERVIEW
  Widget _overview(AppLocalizations t, Map<String, dynamic> c) {
    final custom = (c['custom'] as Map?)?.cast<String, dynamic>() ?? {};
    final primary = _contacts.where((x) => x['is_primary'] == true).toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: withNavBarInset(context, const EdgeInsets.all(Gap.md)), children: [
        _hero(t, c),
        const SizedBox(height: Gap.md),
        CrmSectionHeader(t.crmCompanyProfile),
        DsCard(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(children: [
              KvRow(t.crmIndustry, _industryLabel(t, c['industry']?.toString()),
                  icon: Icons.category_rounded),
              if ((c['size'] as num?) != null && (c['size'] as num) > 0)
                KvRow(t.crmHeadcount, fmtInt(context, (c['size'] as num).toInt()),
                    icon: Icons.badge_rounded),
              if ((c['phone'] ?? '').toString().isNotEmpty)
                KvRow(t.crmPhone, c['phone'].toString(),
                    icon: Icons.phone_rounded),
              if ((c['website'] ?? '').toString().isNotEmpty)
                KvRow(t.crmWebsite, c['website'].toString(),
                    icon: Icons.language_rounded),
              if ((c['address'] ?? '').toString().isNotEmpty)
                KvRow(t.crmAddress, c['address'].toString(),
                    icon: Icons.place_rounded),
            ]),
        ),
        if (primary.isNotEmpty) ...[
          const SizedBox(height: Gap.md),
          CrmSectionHeader(t.crmPrimaryContact),
          _ContactTile(contact: primary.first, onCall: _call, onMail: _mail),
        ],
        const SizedBox(height: Gap.md),
        CrmSectionHeader(t.crmCustomFields),
        DsCard(
          padding: const EdgeInsets.all(Gap.md),
          child: custom.isEmpty
                ? Text(t.crmNoCustomFields,
                    style: AType.bodyMedium.copyWith(
                        color: Theme.of(context).colorScheme.ds.muted))
                : Column(
                    children: [
                      for (final e in custom.entries)
                        KvRow(e.key, e.value?.toString() ?? '—'),
                    ],
                  ),
        ),
      ]),
    );
  }

  // ------------------------------------------------------------------ PEOPLE
  Widget _people(AppLocalizations t) {
    if (_contacts.isEmpty) {
      return CrmStateView.empty(
          icon: Icons.person_off_rounded, title: t.crmNoContacts);
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
          icon: Icons.history_toggle_off_rounded,
          title: t.crmNoActivity,
          message: t.crmCompanyTimelineClientNote);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(Gap.md), children: [
        CrmSectionHeader(t.crmCompanyTimeline,
            hint: t.crmTimelineAllContacts),
        DsCard(
          padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final a in _activities)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.xs),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              DsAvatar(
                  size: 32,
                  child: Icon(activityKindIcon(a['kind']?.toString()),
                      size: 16, color: scheme.ds.primaryInk)),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        (a['subject']?.toString().isNotEmpty == true
                            ? a['subject']
                            : (a['kind_display'] ?? a['kind'] ?? '—')).toString(),
                        style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w600),
                      ),
                      if ((a['body'] ?? '').toString().isNotEmpty)
                        Text(a['body'].toString(),
                            style: AType.bodySmall.copyWith(color: scheme.ds.muted)),
                      Text(
                        [
                          if ((a['actor_name'] ?? '').toString().isNotEmpty)
                            a['actor_name'].toString(),
                          _date(a['created_at']?.toString()),
                        ].where((s) => s.isNotEmpty).join(' · '),
                        style: AType.labelSmall.copyWith(color: scheme.ds.muted),
                      ),
                    ]),
              ),
            ]),
          ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.only(top: Gap.md),
          child: Text(t.crmCompanyTimelineClientNote,
              style: AType.labelSmall.copyWith(fontStyle: FontStyle.italic,
                  color: scheme.ds.muted)),
        ),
      ]),
    );
  }

  // ------------------------------------------------------------------- DEALS
  Widget _dealsTab(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    if (_deals.isEmpty) {
      return CrmStateView.empty(
          icon: Icons.handshake_rounded, title: t.crmNoDeals);
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
              ? AssistoTokens.of(context).success
              : state == 'lost'
                  ? Theme.of(context).colorScheme.error
                  : scheme.primary;
          return DsCard(
            padding: const EdgeInsets.all(Gap.md),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              DsAvatar(
                  size: 40,
                  color: tint,
                  child: Icon(Icons.handshake_rounded, size: 20, color: Brand.onTint(context, tint))),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // title wraps (never "…"), the value under it
                  Text(d['title']?.toString() ?? '—',
                      style: AType.bodyLarge.copyWith(
                          color: scheme.ds.text, fontWeight: FontWeight.w700)),
                  Text('${d['stage_name'] ?? ''} · ${_stateLabel(t, state)}',
                      style: AType.bodySmall.copyWith(color: scheme.ds.muted)),
                  const SizedBox(height: Gap.xxs),
                  Text(bdt(context, d['value'] as num?),
                      style: AType.titleMedium.copyWith(
                          fontWeight: FontWeight.w800, fontFeatures: AFonts.tabular)),
                ]),
              ),
            ]),
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
          icon: Icons.folder_open_rounded,
          title: t.crmNoDocuments,
          message: t.crmDocumentsClientNote);
    }
    return ListView(padding: const EdgeInsets.all(Gap.md), children: [
      Text(t.crmDocumentsClientNote,
          style: AType.labelSmall.copyWith(color: scheme.ds.muted)),
      const SizedBox(height: Gap.sm),
      for (final a in withDocs)
        Padding(padding: const EdgeInsets.only(bottom: Gap.sm), child: DsCard(
            padding: EdgeInsets.zero,
            child: ListTile(
            leading: const Icon(Icons.attach_file_rounded),
            title: Text(
                (a['subject']?.toString().isNotEmpty == true
                        ? a['subject']
                        : t.crmAttachment)
                    .toString()),
            subtitle: Text(_date(a['created_at']?.toString())),
          ),
          )),
    ]);
  }

  // ------------------------------------------------------------- helpers ----
  Future<void> _call(String number) async {
    if (number.isEmpty) return;
    try {
      await launchUrl(Uri.parse('tel:$number'),
          mode: LaunchMode.externalApplication);
    } catch (e) {
      showActionFailed(context, 'crm.call', e, open: true); // db1
    }
  }

  Future<void> _mail(String email) async {
    if (email.isEmpty) return;
    // bizbar: a phone with no mail app used to fail silently
    await openForUser(context, Uri.parse('mailto:$email'), where: 'crm.mail');
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
    return DsCard(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            DsAvatar(name: contact['name']?.toString() ?? '', size: 40),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // name + job title wrap (never "…") at 200% font
                    Text(contact['name']?.toString() ?? '—',
                        style: AType.bodyLarge.copyWith(
                            color: scheme.ds.text, fontWeight: FontWeight.w700)),
                    if ((contact['title'] ?? '').toString().isNotEmpty)
                      Text(contact['title'].toString(),
                          style: AType.bodySmall.copyWith(color: scheme.ds.muted)),
                  ]),
            ),
            if (isPrimary) const PrimaryContactBadge(),
          ]),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: 6, runSpacing: 6, children: [
            ContactRoleChip(role),
          ]),
          const SizedBox(height: Gap.sm),
          // call + mail as DS buttons on a Wrap: a long e-mail drops to its
          // own line instead of being cut
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            if (phone.isNotEmpty)
              DsButton.secondary(
                onPressed: () => onCall(phone),
                icon: Icons.call_rounded,
                label: contact['phone']?.toString() ?? phone,
              ),
            if (email.isNotEmpty)
              DsButton.secondary(
                onPressed: () => onMail(email),
                icon: Icons.mail_outline_rounded,
                label: email,
              ),
          ]),
        ]),
      );
  }
}
