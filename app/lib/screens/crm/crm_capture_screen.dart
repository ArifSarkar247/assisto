import 'package:flutter/material.dart';
import '../../theme.dart';
import '../../l10n/app_localizations.dart';
import 'crm_common.dart';
import 'crm_advanced_api.dart';
import '../../widgets/crm_card_scan.dart';
import '../../widgets/crm_form_import.dart';
import '../../widgets/crm_dedupe_review.dart';

/// CAPTURE (CRM spec #1): three ways to get a lead IN, plus duplicate cleanup.
///  * SCAN — business-card capture (OCR is key-gated mock; user reviews a draft)
///  * IMPORT — paste a website lead-form submission → normalised draft
///  * DEDUPE — duplicate detection + MERGE with a review step that guarantees
///    no timeline/activity is ever lost.
/// Benchmarked vs. best B2B CRM lead capture (card scan, web-to-lead, dedupe).
class CrmCaptureScreen extends StatelessWidget {
  final int org;
  const CrmCaptureScreen({super.key, required this.org});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.crmCapture),
          bottom: TabBar(tabs: [
            Tab(icon: const Icon(Icons.badge_rounded), child: Text(t.crmScanCard, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
            Tab(icon: const Icon(Icons.dynamic_form_rounded), child: Text(t.crmImportForm, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
            Tab(icon: const Icon(Icons.merge_type_rounded), child: Text(t.crmDedupe, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
          ]),
        ),
        body: TabBarView(children: [
          CrmCardScan(org: org),
          CrmFormImport(org: org),
          CrmDedupeReview(org: org),
        ]),
      ),
    );
  }
}
