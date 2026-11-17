import 'package:flutter/material.dart';
import '../../ds/ds.dart';
import '../../theme.dart';
import '../../widgets/ladder_common.dart' show fmtInt;
import '../../l10n/app_localizations.dart';
import '../../widgets/crm_company_widgets.dart';
import 'crm_common.dart';
import 'crm_company_detail_screen.dart';

/// Company directory (CRM_SPEC §2 — Company/Contact 360). Lists the org's B2B
/// accounts with their contact count, industry and a tag filter, then drills
/// into the 360 view. Benchmarked against the account list in best-in-class B2B
/// CRMs: searchable, each row shows the primary signal (industry + people), and
/// the tag filter segments the book of business.
class CrmCompaniesScreen extends StatefulWidget {
  final int org;
  const CrmCompaniesScreen({super.key, required this.org});
  @override
  State<CrmCompaniesScreen> createState() => _CrmCompaniesScreenState();
}

class _CrmCompaniesScreenState extends State<CrmCompaniesScreen> {
  List<Map<String, dynamic>> _companies = [];
  List<Map<String, dynamic>> _contacts = [];
  bool _loading = true;
  CrmError? _error;
  String _query = '';

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
      _companies = await api.companies(widget.org);
      // Contacts are fetched once for the whole org so each row can show its
      // contact count without an N+1 fan-out (no ?company filter server-side).
      _contacts = await api.contacts(widget.org);
    } catch (e) {
      _error = CrmError.from(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  int _contactCount(int companyId) =>
      _contacts.where((c) => (c['company'] as num?)?.toInt() == companyId).length;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_loading) return const CrmStateView.loading();
    if (_error != null) {
      return CrmStateView.error(error: _error!, title: t.loadFailed, onRetry: _load);
    }
    final q = _query.trim().toLowerCase();
    final list = q.isEmpty
        ? _companies
        : _companies
            .where((c) => (c['name'] ?? '').toString().toLowerCase().contains(q))
            .toList();

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.sm),
        child: TextField(
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search_rounded),
            hintText: t.crmSearchCompanies,
          ),
          onChanged: (v) => setState(() => _query = v),
        ),
      ),
      Expanded(
        child: _companies.isEmpty
            ? CrmStateView.empty(
                icon: Icons.domain_rounded,
                title: t.crmNoCompanies,
                message: t.crmNoCompaniesHint,
              )
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.xl),
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const SizedBox(height: Gap.sm),
                  itemBuilder: (_, i) {
                    final c = list[i];
                    final id = (c['id'] as num).toInt();
                    return _CompanyRow(
                      company: c,
                      contactCount: _contactCount(id),
                      onTap: () async {
                        await Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => CrmCompanyDetailScreen(
                              org: widget.org, companyId: id),
                        ));
                        _load();
                      },
                    );
                  },
                ),
              ),
      ),
    ]);
  }
}

class _CompanyRow extends StatelessWidget {
  final Map<String, dynamic> company;
  final int contactCount;
  final VoidCallback onTap;
  const _CompanyRow(
      {required this.company, required this.contactCount, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final ind = company['industry']?.toString();
    final size = (company['size'] as num?)?.toInt() ?? 0;
    // one alive DS card per company: industry bubble, the name (wraps,
    // never "…"), contacts + headcount (Bangla digits in bn) on a Wrap
    return DsCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.sm, Gap.md),
      child: Row(children: [
        DsAvatar(child: Icon(industryIcon(ind), size: 22, color: scheme.ds.primaryInk)),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(company['name']?.toString() ?? '—',
                style: AType.bodyLarge.copyWith(
                    color: scheme.ds.text, fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.xxs),
            Wrap(spacing: Gap.md, runSpacing: Gap.xxs, children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.people_alt_rounded, size: 14, color: scheme.ds.muted),
                const SizedBox(width: Gap.xs),
                Text(t.crmContactCount(contactCount),
                    style: AType.bodySmall.copyWith(color: scheme.ds.muted)),
              ]),
              if (size > 0)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.badge_rounded, size: 14, color: scheme.ds.muted),
                  const SizedBox(width: Gap.xs),
                  Text('${fmtInt(context, size)} ${t.crmHeadcount}',
                      style: AType.bodySmall.copyWith(color: scheme.ds.muted)),
                ]),
            ]),
          ]),
        ),
        Icon(Icons.chevron_right_rounded, color: scheme.ds.muted),
      ]),
    );
  }
}
